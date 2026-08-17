import XCTest
import GRDB
@testable import PaperRssCore

final class LocalAccountProviderTests: XCTestCase {
    var tempDir: URL!
    var database: LibraryDatabase!
    var provider: LocalAccountProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssLocalAccountTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("library.sqlite")
        database = try LibraryDatabase(databaseURL: dbURL)
        provider = LocalAccountProvider(accountID: "local-default", database: database)
        try provider.ensureAccountExists()
    }

    override func tearDownWithError() throws {
        provider = nil
        database = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testEnsureAccountExistsIsIdempotent() throws {
        try provider.ensureAccountExists()
        try provider.ensureAccountExists()

        try database.dbPool.read { db in
            let accounts = try AccountRecord.fetchAll(db)
            XCTAssertEqual(accounts.count, 1)
            XCTAssertEqual(accounts.first?.id, "local-default")
            XCTAssertEqual(accounts.first?.type, "local")
            XCTAssertEqual(accounts.first?.displayName, "本地订阅")

            let syncStates = try AccountSyncStateRecord.fetchAll(db)
            XCTAssertEqual(syncStates.count, 0, "Local account must not create account_sync_state")
        }
    }

    func testFeedAndFolderManagement() throws {
        // 添加文件夹
        try provider.addFolder(name: "Tech")
        var folders = try provider.fetchFolderNames()
        XCTAssertEqual(folders, ["Tech"])

        // 添加 Feed
        let feed = try provider.addFeed(
            title: "Swift Org",
            feedURL: URL(string: "https://www.swift.org/atom.xml")!,
            siteURL: URL(string: "https://www.swift.org")!,
            folder: "Tech"
        )
        XCTAssertEqual(feed.title, "Swift Org")
        XCTAssertEqual(feed.folder, "Tech")

        var feeds = try provider.fetchFeeds()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.id, feed.id)
        XCTAssertEqual(feeds.first?.folder, "Tech")

        // 重命名文件夹
        try provider.renameFolder(oldName: "Tech", newName: "Technology")
        folders = try provider.fetchFolderNames()
        XCTAssertEqual(folders, ["Technology"])
        feeds = try provider.fetchFeeds()
        XCTAssertEqual(feeds.first?.folder, "Technology")

        // 移出文件夹
        try provider.setFeedFolder(feedID: feed.id, folderName: nil)
        feeds = try provider.fetchFeeds()
        XCTAssertNil(feeds.first?.folder)

        // 软删除 Feed
        try provider.deleteFeed(feedID: feed.id)
        feeds = try provider.fetchFeeds()
        XCTAssertEqual(feeds.count, 0)
    }

    func testIncrementalMergeAndStateTransitions() throws {
        let feed = try provider.addFeed(
            title: "Test News",
            feedURL: URL(string: "https://example.com/rss")!
        )

        let parsedEntries = [
            ParsedFeedEntry(
                id: "item-1",
                title: "Article 1",
                author: nil,
                url: URL(string: "https://example.com/1"),
                publishedAt: Date(timeIntervalSince1970: 1000),
                summary: "Summary 1",
                contentHTML: "<p>Content 1</p>"
            ),
            ParsedFeedEntry(
                id: "item-2",
                title: "Article 2",
                author: nil,
                url: URL(string: "https://example.com/2"),
                publishedAt: Date(timeIntervalSince1970: 2000),
                summary: "Summary 2",
                contentHTML: "<p>Content 2</p>"
            )
        ]

        // 首次抓取合并
        let result = LocalAccountProvider.SingleFeedRefreshResult(
            feedID: feed.id,
            oldTitle: feed.title,
            result: .success(.updated(
                ParsedFeed(title: "Test News", siteURL: nil, iconURL: nil, entries: parsedEntries),
                etag: "etag-1",
                lastModified: "last-1"
            ))
        )
        let outcome = try provider.applyRefreshResult(result)
        XCTAssertTrue(outcome.updated)
        XCTAssertEqual(outcome.newUnreadEntries.count, 2)

        // 状态验证：两篇未读
        var allEntries = try provider.fetchAllEntries()
        XCTAssertEqual(allEntries.count, 2)
        XCTAssertTrue(allEntries.allSatisfy { !$0.isRead && !$0.isStarred })

        let id1 = outcome.newUnreadEntries.first { $0.title == "Article 1" }!.id
        let id2 = outcome.newUnreadEntries.first { $0.title == "Article 2" }!.id

        // 标读与标星
        try provider.markRead(entryID: id1, read: true)
        try provider.markStarred(entryID: id2, starred: true)

        let item1 = try provider.fetchEntry(id: id1)
        let item2 = try provider.fetchEntry(id: id2)
        XCTAssertEqual(item1?.isRead, true)
        XCTAssertEqual(item1?.isStarred, false)
        XCTAssertEqual(item2?.isRead, false)
        XCTAssertEqual(item2?.isStarred, true)

        // 全部标读
        try provider.markAllRead()
        allEntries = try provider.fetchAllEntries()
        XCTAssertTrue(allEntries.allSatisfy(\.isRead))
    }

    func testArticleCacheAndAIArtifacts() throws {
        // 先创建 feed 和 item 满足外键约束
        let feed = try provider.addFeed(title: "Article Cache Feed", feedURL: URL(string: "https://example.com/rss2")!)
        try database.dbPool.write { db in
            let item = ItemRecord(
                id: "test-entry-1",
                accountID: "local-default",
                externalID: "ext-1",
                feedID: feed.id.uuidString,
                createdAt: 1000.0,
                updatedAt: 1000.0
            )
            try item.save(db)
        }

        // 测试 ArticleCache 存储
        let cache = ArticleCache(
            entryID: "test-entry-1",
            text: "Clean extracted text",
            html: "<p>Clean HTML</p>",
            imageURLs: [URL(string: "https://example.com/img.png")!],
            fetchedAt: Date(timeIntervalSince1970: 5000),
            sourceURL: URL(string: "https://example.com/article"),
            isSanitized: true
        )
        try provider.saveCache(cache)

        let fetchedCache = try provider.fetchCache(entryID: "test-entry-1")
        XCTAssertNotNil(fetchedCache)
        XCTAssertEqual(fetchedCache?.entryID, "test-entry-1")
        XCTAssertEqual(fetchedCache?.text, "Clean extracted text")
        XCTAssertEqual(fetchedCache?.imageURLs.count, 1)
        XCTAssertEqual(fetchedCache?.isSanitized, true)

        // 测试文章级 AI 产物
        let summaryArtifact = AIArtifact(
            id: UUID(),
            entryID: "test-entry-1",
            kind: .summary,
            contentHash: "hash-summary-1",
            model: "deepseek-chat",
            targetLanguage: "简体中文",
            promptVersion: 1,
            content: "这是一个一句话总结与核心要点。",
            isComplete: true
        )
        try provider.saveArtifact(summaryArtifact)

        let fetchedSummary = try provider.fetchArtifact(entryID: "test-entry-1", kind: .summary, isCompleteOnly: true)
        XCTAssertNotNil(fetchedSummary)
        XCTAssertEqual(fetchedSummary?.content, "这是一个一句话总结与核心要点。")
        XCTAssertEqual(fetchedSummary?.model, "deepseek-chat")

        // 测试全局翻译记忆
        let translationKey = "translation-memory-v2:digest-abc"
        let globalTM = AIArtifact(
            id: UUID(),
            entryID: translationKey,
            kind: .translation,
            contentHash: "digest-abc",
            model: "deepseek-chat",
            targetLanguage: "简体中文",
            promptVersion: 2,
            content: "这是一个翻译结果",
            isComplete: true
        )
        try provider.saveArtifact(globalTM)

        let fetchedTM = try provider.fetchGlobalTranslationMemory(key: translationKey)
        XCTAssertNotNil(fetchedTM)
        XCTAssertEqual(fetchedTM?.content, "这是一个翻译结果")

        // 验证全局翻译记忆在 SQLite 中 account_id 为 NULL
        try database.dbPool.read { db in
            let record = try AIArtifactRecord.filter(Column("subject_key") == translationKey).fetchOne(db)
            XCTAssertNotNil(record)
            XCTAssertNil(record?.accountID)
            XCTAssertNil(record?.itemID)
        }
    }

    func testOPMLExportAndImport() throws {
        _ = try provider.addFeed(
            title: "Apple Newsroom",
            feedURL: URL(string: "https://www.apple.com/newsroom/rss-feed.rss")!
        )
        _ = try provider.addFeed(
            title: "Swift Org",
            feedURL: URL(string: "https://www.swift.org/atom.xml")!
        )

        let opmlData = try provider.exportOPML()
        XCTAssertFalse(opmlData.isEmpty)
        let opmlString = String(data: opmlData, encoding: .utf8) ?? ""
        XCTAssertTrue(opmlString.contains("https://www.apple.com/newsroom/rss-feed.rss"))
        XCTAssertTrue(opmlString.contains("https://www.swift.org/atom.xml"))

        // 创建新库并导入
        let tempDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssOPMLImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        let db2 = try LibraryDatabase(databaseURL: tempDir2.appendingPathComponent("library.sqlite"))
        let provider2 = LocalAccountProvider(accountID: "local-default", database: db2)
        try provider2.ensureAccountExists()

        let importedIDs = try provider2.importOPML(opmlData)
        XCTAssertEqual(importedIDs.count, 2)
        let importedFeeds = try provider2.fetchFeeds()
        XCTAssertEqual(importedFeeds.count, 2)
    }

    func testAccountEnableAndDisableIsolation() async throws {
        let accountRepo = AccountRepository(database: database)
        let account = try await accountRepo.fetchAccount(id: "local-default")
        XCTAssertEqual(account?.isEnabled, true)

        let feed = try provider.addFeed(
            title: "Local Feed",
            feedURL: URL(string: "https://example.com/rss3")!
        )
        let parsed = [
            ParsedFeedEntry(
                id: "item-disable-test",
                title: "Disabled Item",
                author: nil,
                url: URL(string: "https://example.com/disable-1"),
                publishedAt: Date(),
                summary: "Summary",
                contentHTML: "<p>Content</p>"
            )
        ]
        let res = LocalAccountProvider.SingleFeedRefreshResult(
            feedID: feed.id,
            oldTitle: feed.title,
            result: .success(.updated(
                ParsedFeed(title: "Local Feed", siteURL: nil, iconURL: nil, entries: parsed),
                etag: nil,
                lastModified: nil
            ))
        )
        _ = try provider.applyRefreshResult(res)

        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var counts = try provider.timelineQueryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)
        XCTAssertEqual(counts.allUnread, 1)

        var items = try provider.timelineQueryService.fetchListItems(scope: .all)
        XCTAssertEqual(items.count, 1)

        // 禁用 local-default 账号
        try await accountRepo.updateAccountEnabled(id: "local-default", isEnabled: false)
        let disabledAccount = try await accountRepo.fetchAccount(id: "local-default")
        XCTAssertEqual(disabledAccount?.isEnabled, false)

        // 全局未读数与时间线应隔离并排除禁用账号
        counts = try provider.timelineQueryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)
        XCTAssertEqual(counts.allUnread, 0)
        items = try provider.timelineQueryService.fetchListItems(scope: .all)
        XCTAssertEqual(items.count, 0)

        // 重新启用 local-default 账号
        try await accountRepo.updateAccountEnabled(id: "local-default", isEnabled: true)
        counts = try provider.timelineQueryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)
        XCTAssertEqual(counts.allUnread, 1)
        items = try provider.timelineQueryService.fetchListItems(scope: .all)
        XCTAssertEqual(items.count, 1)
    }
}
