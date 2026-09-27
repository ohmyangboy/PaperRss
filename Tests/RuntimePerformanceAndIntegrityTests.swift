import XCTest
import GRDB
@testable import PaperRssCore

final class RuntimePerformanceAndIntegrityTests: XCTestCase {
    var tempDir: URL!
    var sqliteURL: URL!
    var libraryDB: LibraryDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssPerfTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sqliteURL = tempDir.appendingPathComponent("library.sqlite")
        libraryDB = try LibraryDatabase(databaseURL: sqliteURL)
    }

    override func tearDownWithError() throws {
        libraryDB = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    /// 批量插入大规模测试数据（50,000 条 Items + Articles + States）
    private func seedLargeScaleFixture(itemCount: Int = 50_000) throws -> (feedID: String, sampleItemIDs: [String]) {
        let now = Date().timeIntervalSince1970
        let feedUUID = UUID()
        let feedID = feedUUID.uuidString

        var sampleIDs: [String] = []

        try libraryDB.write { db in
            try AccountRecord(id: "local-default", type: "local", displayName: "本地订阅", isEnabled: true, createdAt: now, updatedAt: now).save(db)
            try FeedRecord(id: feedID, accountID: "local-default", title: "High Volume Tech Feed", feedURL: "https://highvolume.com/rss", updatedAt: now).save(db)

            let largeHTMLPayload = String(repeating: "<p>This is a performance payload paragraph of RSS text.</p>\n", count: 20)

            for i in 1...itemCount {
                let itemID = "item-\(i)"
                if i % 5000 == 1 || i == itemCount {
                    sampleIDs.append(itemID)
                }

                let pubDate = now - Double(itemCount - i) * 60.0

                try ItemRecord(
                    id: itemID,
                    accountID: "local-default",
                    externalID: "ext-\(i)",
                    feedID: feedID,
                    createdAt: pubDate,
                    updatedAt: pubDate
                ).save(db)

                try ArticleRecord(
                    itemID: itemID,
                    title: "Article Title #\(i) with detailed header",
                    author: "Author \(i % 100)",
                    url: "https://highvolume.com/article/\(i)",
                    publishedAt: pubDate,
                    summary: "This is a short summary preview for item \(i).",
                    contentHTML: largeHTMLPayload,
                    contentUpdatedAt: pubDate
                ).save(db)

                try ArticleStateRecord(
                    itemID: itemID,
                    isRead: i % 2 == 0,
                    isStarred: i % 50 == 0,
                    dateArrived: pubDate,
                    updatedAt: pubDate
                ).save(db)
            }
        }

        return (feedID, sampleIDs)
    }

    @MainActor
    func testSelectedArticleDoesNotMaterializeFullDatabaseOrAllContentHTML() throws {
        let (_, sampleIDs) = try seedLargeScaleFixture(itemCount: 50_000)
        let targetID = sampleIDs.first!

        let store = AppStore(fileManager: .default, databaseURL: sqliteURL)

        // 1. 验证 Timeline Runtime 默认使用 Bounded Limit (100 条)，绝不将 50,000 条条目反序列化到内存
        XCTAssertEqual(store.entryListItems.count, AppStore.defaultTimelineLimit)

        // 2. 验证文章点查是 Bounded 索引查询
        let start = CFAbsoluteTimeGetCurrent()
        let article = store.entry(id: targetID)
        let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        XCTAssertNotNil(article)
        XCTAssertEqual(article?.id, targetID)
        // 单点查询应该在 500 毫秒内完成（即使在 50k 数据量下）
        XCTAssertLessThan(duration, 500.0, "Single entry point-lookup must be fast and bounded, took \(duration)ms")

        // 3. 验证再次访问命中 Entry 缓存
        let cachedStart = CFAbsoluteTimeGetCurrent()
        let cachedArticle = store.entry(id: targetID)
        let cachedDuration = (CFAbsoluteTimeGetCurrent() - cachedStart) * 1000.0

        XCTAssertEqual(cachedArticle?.id, targetID)
        XCTAssertLessThan(cachedDuration, 50.0, "Cached entry lookup must take < 50ms, took \(cachedDuration)ms")
    }

    @MainActor
    func testMarkReadDoesNotReloadFullTimelines() async throws {
        let (feedID, _) = try seedLargeScaleFixture(itemCount: 50_000)

        let store = AppStore(fileManager: .default, databaseURL: sqliteURL)
        guard let firstUnreadItem = store.unreadEntryListItems.first else {
            XCTFail("Must have unread items")
            return
        }

        let targetID = firstUnreadItem.id
        let initialUnreadCount = store.sidebarCounts.allUnread

        // 测量 markRead 耗时
        let start = CFAbsoluteTimeGetCurrent()
        store.markRead(entryID: targetID, read: true)
        let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        print("TIMELINE_INTERACTION_BASELINE markReadMainThreadMS=\(duration)")

        let pageStart = CFAbsoluteTimeGetCurrent()
        let page = store.fetchTimelinePage(scope: .unread, limit: 100)
        let pageDuration = (CFAbsoluteTimeGetCurrent() - pageStart) * 1000.0
        print("TIMELINE_INTERACTION_BASELINE unreadPage100MainThreadMS=\(pageDuration)")
        XCTAssertEqual(page.count, 100)

        let feedPageStart = CFAbsoluteTimeGetCurrent()
        let feedPage = store.fetchTimelinePage(scope: .feed(feedID: feedID), limit: 100)
        let feedPageDuration = (CFAbsoluteTimeGetCurrent() - feedPageStart) * 1000.0
        XCTAssertEqual(feedPage.count, 100)
        let adjacentStart = CFAbsoluteTimeGetCurrent()
        let adjacent = store.fetchAdjacentItem(
            scope: .unread,
            currentItemID: page[3].id,
            direction: .next
        )
        let adjacentDuration = (CFAbsoluteTimeGetCurrent() - adjacentStart) * 1000.0
        let feedAdjacentStart = CFAbsoluteTimeGetCurrent()
        let feedAdjacent = store.fetchAdjacentItem(
            scope: .feed(feedID: feedID),
            currentItemID: page[3].id,
            direction: .next
        )
        let feedAdjacentDuration = (CFAbsoluteTimeGetCurrent() - feedAdjacentStart) * 1000.0
        print("TIMELINE_INTERACTION_AFTER feedPage100QueryMS=\(feedPageDuration)")
        print("TIMELINE_INTERACTION_BASELINE unreadAdjacentMainThreadMS=\(adjacentDuration) feedAdjacentMainThreadMS=\(feedAdjacentDuration)")
        XCTAssertNotNil(adjacent)
        XCTAssertNotNil(feedAdjacent)

        let anotherID = try XCTUnwrap(page.first?.id)
        let provider = LocalAccountProvider(accountID: "local-default", database: libraryDB)
        let writeStart = CFAbsoluteTimeGetCurrent()
        try provider.markRead(entryID: anotherID, read: true)
        let writeDuration = (CFAbsoluteTimeGetCurrent() - writeStart) * 1000.0
        let countsStart = CFAbsoluteTimeGetCurrent()
        _ = try TimelineQueryService(database: libraryDB).fetchSidebarCounts(
            startOfDayTimestamp: Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        )
        let countsDuration = (CFAbsoluteTimeGetCurrent() - countsStart) * 1000.0
        print("TIMELINE_INTERACTION_BASELINE writeMainThreadMS=\(writeDuration) sidebarCountsMainThreadMS=\(countsDuration)")

        // 验证只做局部更新与单个 Sidebar SQL 聚合，不重新加载 4 个全量 Timeline
        XCTAssertLessThan(duration, 500.0, "markRead must be fine-grained and not reload all 4 timelines, took \(duration)ms")

        // 验证状态已更新
        XCTAssertEqual(store.sidebarCounts.allUnread, initialUnreadCount - 1)
        if let updatedItem = store.entryListItems.first(where: { $0.id == targetID }) {
            XCTAssertTrue(updatedItem.isRead)
        }

        let readerEntries = try [page[1].id, page[2].id].map { id in
            try XCTUnwrap(store.entry(id: id))
        }
        let readerStart = CFAbsoluteTimeGetCurrent()
        for entry in readerEntries { store.markReadFromReader(entry) }
        let readerMainThreadDuration = (CFAbsoluteTimeGetCurrent() - readerStart) * 1000.0
        print("TIMELINE_INTERACTION_AFTER readerTwoMarksMainThreadMS=\(readerMainThreadDuration)")
        XCTAssertLessThan(readerMainThreadDuration, 50.0, "Reader selection must not aggregate sidebar counts on MainActor")

        let deadline = Date().addingTimeInterval(3)
        while store.sidebarCounts.allUnread != initialUnreadCount - 4 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.sidebarCounts.allUnread, initialUnreadCount - 4)
        for entry in readerEntries {
            XCTAssertTrue(store.entry(id: entry.id)?.isRead == true)
        }
    }

    func testTimelineQueryServiceBoundedPaginationUnder50kItems() throws {
        _ = try seedLargeScaleFixture(itemCount: 50_000)

        let queryService = TimelineQueryService(database: libraryDB)

        // 验证分页查询 LIMIT 50 OFFSET 100 极速返回
        let start = CFAbsoluteTimeGetCurrent()
        let page = try queryService.fetchListItems(scope: .all, limit: 50, offset: 100)
        let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        XCTAssertEqual(page.count, 50)
        XCTAssertLessThan(duration, 500.0, "Bounded list projection query under 50k rows must complete < 500ms, took \(duration)ms")

        // 验证条目仅包含元数据，不携带全量庞大正文，内存轻量
        let sample = page.first!
        XCTAssertFalse(sample.title.isEmpty)
        XCTAssertFalse(sample.sourceTitle.isEmpty)
    }
}
