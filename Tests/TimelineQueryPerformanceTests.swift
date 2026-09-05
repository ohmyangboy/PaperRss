import XCTest
import GRDB
@testable import PaperRssCore

final class TimelineQueryPerformanceTests: XCTestCase {
    var tempDir: URL!
    var database: LibraryDatabase!
    var provider: LocalAccountProvider!
    var queryService: TimelineQueryService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssPerfTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("library.sqlite")
        database = try LibraryDatabase(databaseURL: dbURL)
        provider = LocalAccountProvider(accountID: "local-default", database: database)
        try provider.ensureAccountExists()
        queryService = TimelineQueryService(database: database)
    }

    override func tearDownWithError() throws {
        queryService = nil
        provider = nil
        database = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testScopedUnreadPaginationRetentionAndNavigation() throws {
        try provider.addFolder(name: "筛选测试")
        let first = try provider.addFeed(title: "源一", feedURL: URL(string: "https://filter.example/one")!, folder: "筛选测试")
        let second = try provider.addFeed(title: "源二", feedURL: URL(string: "https://filter.example/two")!)
        let other = LocalAccountProvider(accountID: "other-account", database: database)
        try other.ensureAccountExists()
        try other.addFolder(name: "筛选测试")
        let foreign = try other.addFeed(title: "其他账户", feedURL: URL(string: "https://filter.example/foreign")!, folder: "筛选测试")
        for (owner, feed) in [(provider!, first), (provider!, second), (other, foreign)] {
            let entries = (0..<230).map { index in
                ParsedFeedEntry(id: "item-\(index)", title: "文章 \(index)", author: nil,
                    url: URL(string: "https://filter.example/item/\(index)"),
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
                    summary: "摘要", contentHTML: "<p>正文</p>")
            }
            _ = try owner.applyRefreshResult(.init(feedID: feed.id, oldTitle: feed.title,
                result: .success(.updated(ParsedFeed(title: feed.title, siteURL: nil, iconURL: nil, entries: entries), etag: nil, lastModified: nil))))
            let all = try queryService.fetchListItems(scope: .feed(feedID: feed.id.uuidString))
            try owner.markRead(entryIDs: all.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element.id }, read: true)
        }
        let scope = TimelineScope.feed(feedID: first.id.uuidString)
        let all = try queryService.fetchListItems(scope: scope)
        let expected = all.filter { !$0.isRead }
        let page1 = try queryService.fetchListItems(scope: scope, unreadOnly: true, limit: 100)
        let page2 = try queryService.fetchListItems(scope: scope, unreadOnly: true, limit: 100, offset: 100)
        XCTAssertEqual((page1 + page2).map(\.id), expected.map(\.id))
        XCTAssertEqual(expected.count, 115)
        let folder = TimelineScope.folder(accountID: "local-default", folderName: "筛选测试")
        XCTAssertEqual(try queryService.fetchListItems(scope: folder, unreadOnly: true).map(\.id), expected.map(\.id))
        XCTAssertEqual(try queryService.fetchListItems(scope: .feeds(feedIDs: [first.id.uuidString, second.id.uuidString]), unreadOnly: true).count, 230)
        XCTAssertTrue(try queryService.fetchListItems(scope: .feeds(feedIDs: []), unreadOnly: true).isEmpty)

        let current = expected[0].id
        try provider.markRead(entryIDs: [current], read: true)
        let outside = try XCTUnwrap(queryService.fetchListItems(scope: .feed(feedID: foreign.id.uuidString)).first?.id)
        let retained: Set<String> = [current, outside]
        XCTAssertEqual(try queryService.fetchListItems(scope: folder, unreadOnly: true, retainingIDs: retained).map(\.id), expected.map(\.id))
        let next = try queryService.fetchAdjacentItem(scope: folder, unreadOnly: true, currentItemID: current, direction: .next, retainingIDs: retained)
        XCTAssertEqual(next?.id, expected[1].id)
        XCTAssertEqual(try queryService.fetchAdjacentItem(scope: folder, unreadOnly: true, currentItemID: expected[1].id, direction: .previous, retainingIDs: retained)?.id, current)
        XCTAssertEqual(try queryService.fetchListItems(scope: scope, unreadOnly: true).count, 114)
        try provider.markRead(entryIDs: all.map(\.id), read: true)
        XCTAssertTrue(try queryService.fetchListItems(scope: scope, unreadOnly: true).isEmpty)
        XCTAssertEqual(try queryService.fetchListItems(scope: scope, unreadOnly: true, retainingIDs: retained).map(\.id), [current])
        XCTAssertEqual(try queryService.fetchListItems(scope: scope).count, 230)
    }

    func testSidebarCountsAggregationWithoutMaterializingArticles() throws {
        try provider.addFolder(name: "Tech")
        let feed1 = try provider.addFeed(title: "Feed 1", feedURL: URL(string: "https://f1.com/rss")!, folder: "Tech")
        let feed2 = try provider.addFeed(title: "Feed 2", feedURL: URL(string: "https://f2.com/rss")!)

        let now = Date().timeIntervalSince1970
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970

        // 插入 50 篇文章
        var entries1: [ParsedFeedEntry] = []
        for i in 1...30 {
            entries1.append(
                ParsedFeedEntry(
                    id: "f1-\(i)",
                    title: "F1 Article \(i)",
                    author: nil,
                    url: URL(string: "https://f1.com/\(i)"),
                    publishedAt: Date(timeIntervalSince1970: now - Double(i * 60)),
                    summary: "Summary \(i)",
                    contentHTML: "<p>Very long content \(i)</p>"
                )
            )
        }
        _ = try provider.applyRefreshResult(
            LocalAccountProvider.SingleFeedRefreshResult(
                feedID: feed1.id,
                oldTitle: feed1.title,
                result: .success(.updated(
                    ParsedFeed(title: "Feed 1", siteURL: nil, iconURL: nil, entries: entries1),
                    etag: nil,
                    lastModified: nil
                ))
            )
        )

        var entries2: [ParsedFeedEntry] = []
        for i in 1...20 {
            entries2.append(
                ParsedFeedEntry(
                    id: "f2-\(i)",
                    title: "F2 Article \(i)",
                    author: nil,
                    url: URL(string: "https://f2.com/\(i)"),
                    publishedAt: Date(timeIntervalSince1970: now - Double(i * 120)),
                    summary: "Summary 2-\(i)",
                    contentHTML: "<p>Very long content 2-\(i)</p>"
                )
            )
        }
        _ = try provider.applyRefreshResult(
            LocalAccountProvider.SingleFeedRefreshResult(
                feedID: feed2.id,
                oldTitle: feed2.title,
                result: .success(.updated(
                    ParsedFeed(title: "Feed 2", siteURL: nil, iconURL: nil, entries: entries2),
                    etag: nil,
                    lastModified: nil
                ))
            )
        )

        // 标读部分文章，标星部分文章
        let readIDs = [
            "\(feed1.id.uuidString)|f1-1".stableDigest,
            "\(feed1.id.uuidString)|f1-2".stableDigest,
            "\(feed1.id.uuidString)|f1-3".stableDigest,
            "\(feed2.id.uuidString)|f2-1".stableDigest
        ]
        try provider.markRead(entryIDs: readIDs, read: true)
        try provider.markStarred(entryID: "\(feed1.id.uuidString)|f1-5".stableDigest, starred: true)
        try provider.markStarred(entryID: "\(feed2.id.uuidString)|f2-2".stableDigest, starred: true)

        let counts = try queryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)

        // 验证全局未读：总数 50 - 4 = 46
        XCTAssertEqual(counts.allUnread, 46)
        XCTAssertEqual(counts.globalUnread, 46)
        // 验证星标数：2
        XCTAssertEqual(counts.starred, 2)
        // 验证 Feed 1 未读：30 - 3 = 27
        XCTAssertEqual(counts.unreadByFeed[feed1.id], 27)
        // 验证 Feed 2 未读：20 - 1 = 19
        XCTAssertEqual(counts.unreadByFeed[feed2.id], 19)
        // 验证 Folder Tech 未读：27
        XCTAssertEqual(counts.unreadByFolder["Tech"], 27)
    }

    func testBoundedListItemsQueryLimitAndOffset() throws {
        let feed = try provider.addFeed(title: "Stream Feed", feedURL: URL(string: "https://stream.com/rss")!)
        let now = Date().timeIntervalSince1970

        var entries: [ParsedFeedEntry] = []
        for i in 1...100 {
            entries.append(
                ParsedFeedEntry(
                    id: "stream-\(i)",
                    title: "Stream Item \(i)",
                    author: nil,
                    url: URL(string: "https://stream.com/\(i)"),
                    publishedAt: Date(timeIntervalSince1970: now + Double(i)),
                    summary: "Short summary \(i)",
                    contentHTML: String(repeating: "<p>Huge HTML Content payload</p>", count: 50)
                )
            )
        }
        _ = try provider.applyRefreshResult(
            LocalAccountProvider.SingleFeedRefreshResult(
                feedID: feed.id,
                oldTitle: feed.title,
                result: .success(.updated(
                    ParsedFeed(title: "Stream Feed", siteURL: nil, iconURL: nil, entries: entries),
                    etag: nil,
                    lastModified: nil
                ))
            )
        )

        // Bounded Query: Limit 20, Offset 0
        let firstPage = try queryService.fetchListItems(scope: .all, limit: 20, offset: 0)
        XCTAssertEqual(firstPage.count, 20)
        XCTAssertEqual(firstPage.first?.id, "\(feed.id.uuidString)|stream-100".stableDigest) // 倒序排在第一位

        // Bounded Query: Limit 20, Offset 20
        let secondPage = try queryService.fetchListItems(scope: .all, limit: 20, offset: 20)
        XCTAssertEqual(secondPage.count, 20)
        XCTAssertEqual(secondPage.first?.id, "\(feed.id.uuidString)|stream-80".stableDigest)

        // 验证投影出的条目元数据完好
        let item = firstPage.first!
        XCTAssertEqual(item.feedID, feed.id)
        XCTAssertEqual(item.sourceTitle, "Stream Feed")
        XCTAssertFalse(item.isRead)
        XCTAssertFalse(item.isStarred)
    }
}
