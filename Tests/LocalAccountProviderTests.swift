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

        // 物理级联删除 Feed
        try provider.deleteFeed(feedID: feed.id)
        feeds = try provider.fetchFeeds()
        XCTAssertEqual(feeds.count, 0)
        try database.dbPool.read { db in
            let record = try FeedRecord.filter(Column("id") == feed.id.uuidString).fetchOne(db)
            XCTAssertNil(record, "FeedRecord must be physically deleted")
        }
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

    func testPhysicalCascadeDeletionPurgesAllAssociatedData() throws {
        let feed = try provider.addFeed(
            title: "Swift News",
            feedURL: URL(string: "https://example.com/swift-news")!,
            folder: "Languages"
        )
        let feedID = feed.id.uuidString

        let itemID = "swift-news-item-1"
        try database.dbPool.write { db in
            let item = ItemRecord(
                id: itemID,
                accountID: "local-default",
                externalID: "ext-swift-1",
                feedID: feedID,
                createdAt: 1000.0,
                updatedAt: 1000.0
            )
            try item.save(db)

            let article = ArticleRecord(
                itemID: itemID,
                title: "Swift 6 Released",
                author: "Apple",
                url: "https://example.com/swift-6",
                publishedAt: 1000.0,
                summary: "Swift 6 is here",
                contentHTML: "<p>Details</p>",
                contentUpdatedAt: 1000.0
            )
            try article.save(db)

            let state = ArticleStateRecord(
                itemID: itemID,
                isRead: true,
                isStarred: true,
                dateArrived: 1000.0,
                updatedAt: 1000.0
            )
            try state.save(db)

            let cache = ArticleCacheRecord(
                itemID: itemID,
                text: "Clean text",
                html: "<p>Clean</p>",
                imageUrlsJSON: nil,
                fetchedAt: 1000.0,
                sourceURL: "https://example.com/swift-6",
                isSanitized: true
            )
            try cache.save(db)

            let artifact = AIArtifactRecord(
                id: "artifact-swift-1",
                accountID: "local-default",
                itemID: itemID,
                subjectKey: itemID,
                kind: "summary",
                contentHash: "hash1",
                model: "model1",
                targetLanguage: "zh",
                promptVersion: 1,
                content: "AI Summary",
                segmentsJSON: nil,
                selectionText: nil,
                selectionArticleHash: nil,
                selectionAnchorJSON: nil,
                isComplete: true,
                isDeleted: false,
                createdAt: 1000.0,
                updatedAt: 1000.0
            )
            try artifact.save(db)
        }

        // 验证插入成功
        try database.dbPool.read { db in
            XCTAssertNotNil(try FeedRecord.filter(Column("id") == feedID).fetchOne(db))
            XCTAssertNotNil(try ItemRecord.filter(Column("id") == itemID).fetchOne(db))
            XCTAssertNotNil(try ArticleRecord.filter(Column("item_id") == itemID).fetchOne(db))
            XCTAssertNotNil(try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db))
            XCTAssertNotNil(try ArticleCacheRecord.filter(Column("item_id") == itemID).fetchOne(db))
            XCTAssertFalse(try FeedFolderRecord.filter(Column("feed_id") == feedID).fetchAll(db).isEmpty)
        }

        // 物理删除订阅源
        try provider.deleteFeed(feedID: feed.id)

        // 验证原生外键级联全部彻底清除
        try database.dbPool.read { db in
            XCTAssertNil(try FeedRecord.filter(Column("id") == feedID).fetchOne(db), "Feed 必须物理删除")
            XCTAssertNil(try ItemRecord.filter(Column("id") == itemID).fetchOne(db), "Items 必须级联删除")
            XCTAssertNil(try ArticleRecord.filter(Column("item_id") == itemID).fetchOne(db), "Articles 必须级联删除")
            XCTAssertNil(try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db), "ArticleStates 必须级联删除")
            XCTAssertNil(try ArticleCacheRecord.filter(Column("item_id") == itemID).fetchOne(db), "ArticleCaches 必须级联删除")
            XCTAssertTrue(try FeedFolderRecord.filter(Column("feed_id") == feedID).fetchAll(db).isEmpty, "FeedFolders 必须级联删除")
            // ai_artifacts 设置为 ON DELETE SET NULL
            let artifactRecord = try AIArtifactRecord.filter(Column("id") == "artifact-swift-1").fetchOne(db)
            XCTAssertNil(artifactRecord?.itemID, "AI Artifact item_id 必须置 NULL")
        }
    }

    func testReAddingFeedCreatesCleanNewFeedWithoutResurrectingOldData() throws {
        let feedURL = URL(string: "https://example.com/clean-test")!
        let firstFeed = try provider.addFeed(
            title: "Initial Title",
            feedURL: feedURL,
            folder: "OldFolder"
        )
        let firstUUID = firstFeed.id

        // 物理删除
        try provider.deleteFeed(feedID: firstUUID)
        XCTAssertEqual(try provider.fetchFeeds().count, 0)

        // 重新添加相同 URL
        let secondFeed = try provider.addFeed(
            title: "New Title",
            feedURL: feedURL,
            folder: "NewFolder"
        )

        // 必须为全新 UUID，而非复用已删除旧源的 ID
        XCTAssertNotEqual(secondFeed.id, firstUUID, "Must allocate a brand new UUID")
        XCTAssertEqual(secondFeed.title, "New Title")
        XCTAssertEqual(secondFeed.folder, "NewFolder")

        let feeds = try provider.fetchFeeds()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.id, secondFeed.id)
    }

    func testAddFeedPurgesAnyLingeringSoftDeletedRecords() throws {
        let feedURL = URL(string: "https://example.com/lingering")!
        let oldID = UUID().uuidString
        let oldItemID = "lingering-item"

        // 模拟存量软删除脏数据
        try database.dbPool.write { db in
            let oldFeed = FeedRecord(
                id: oldID,
                accountID: "local-default",
                externalID: nil,
                title: "Old Dead Feed",
                siteURL: nil,
                feedURL: feedURL.absoluteString,
                etag: "old-etag",
                lastModified: "old-mod",
                lastRefreshedAt: 1000.0,
                isDeleted: true,
                updatedAt: 1000.0,
                storedIconURL: nil,
                sortOrder: 1
            )
            try oldFeed.save(db)

            let item = ItemRecord(
                id: oldItemID,
                accountID: "local-default",
                externalID: "ext-lingering",
                feedID: oldID,
                createdAt: 1000.0,
                updatedAt: 1000.0
            )
            try item.save(db)
        }

        // 添加该 URL 的 Feed
        let added = try provider.addFeed(
            title: "Clean Replacement",
            feedURL: feedURL
        )

        XCTAssertNotEqual(added.id.uuidString, oldID)

        // 验证旧软删除记录和关联数据已被物理清除
        try database.dbPool.read { db in
            XCTAssertNil(try FeedRecord.filter(Column("id") == oldID).fetchOne(db))
            XCTAssertNil(try ItemRecord.filter(Column("id") == oldItemID).fetchOne(db))
            let activeFeeds = try FeedRecord.filter(Column("feed_url") == feedURL.absoluteString).fetchAll(db)
            XCTAssertEqual(activeFeeds.count, 1)
            XCTAssertEqual(activeFeeds.first?.id, added.id.uuidString)
            XCTAssertFalse(activeFeeds.first?.isDeleted ?? true)
        }
    }

    func testRefreshFeedSingleSourceWithForce() async throws {
        final class ForceRecorder: @unchecked Sendable {
            var recordedForce: Bool?
        }
        let recorder = ForceRecorder()

        let mockFetcher: @Sendable (Feed, Bool) async throws -> FeedFetchResult = { feed, force in
            recorder.recordedForce = force
            let entry = ParsedFeedEntry(
                id: "entry-single",
                title: "Single Entry",
                author: "Author",
                url: URL(string: "https://example.com/single"),
                publishedAt: Date(),
                summary: "Summary",
                contentHTML: "<p>Content</p>"
            )
            let parsed = ParsedFeed(title: "Single Feed", siteURL: nil, iconURL: nil, entries: [entry])
            return .updated(parsed, etag: "etag-single", lastModified: "mod-single")
        }

        let customProvider = LocalAccountProvider(
            accountID: "local-default",
            database: database,
            customFeedFetcher: mockFetcher
        )

        let feed = try customProvider.addFeed(
            title: "Original Feed",
            feedURL: URL(string: "https://example.com/single.xml")!
        )

        let outcome = try await customProvider.refreshFeed(id: feed.id, force: true)
        XCTAssertTrue(outcome.updated)
        XCTAssertEqual(outcome.newUnreadEntries.count, 1)
        XCTAssertEqual(recorder.recordedForce, true, "refreshFeed 必须将 force = true 传给 fetcher")

        // 再次强制刷新，由于 entry 已存在，正文回填/更新，newUnreadEntries 为空
        let secondOutcome = try await customProvider.refreshFeed(id: feed.id, force: true)
        XCTAssertTrue(secondOutcome.updated)
        XCTAssertEqual(secondOutcome.newUnreadEntries.count, 0)
    }

    func testRefreshFeedThrowsWhenFeedNotFound() async throws {
        do {
            _ = try await provider.refreshFeed(id: UUID(), force: true)
            XCTFail("Should throw LocalAccountError.feedNotFound")
        } catch let error as LocalAccountError {
            XCTAssertEqual(error, .feedNotFound)
        }
    }

    func testFeedServiceFetchConditionalHeadersRespectForce() async throws {
        URLProtocol.registerClass(FeedServiceHeaderCaptureURLProtocol.self)
        defer { URLProtocol.unregisterClass(FeedServiceHeaderCaptureURLProtocol.self) }

        let feed = Feed(
            id: UUID(),
            title: "Header Test",
            feedURL: URL(string: "https://feedservice-header-test.com/rss.xml")!,
            etag: "\"etag-123\"",
            lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
        )

        // 1. force == false 应当附带 If-None-Match 和 If-Modified-Since
        _ = try? await FeedService.fetch(feed, force: false)
        let reqNormal = FeedServiceHeaderCaptureURLProtocol.lock.withLock {
            FeedServiceHeaderCaptureURLProtocol.lastRequest
        }
        XCTAssertEqual(reqNormal?.value(forHTTPHeaderField: "If-None-Match"), "\"etag-123\"")
        XCTAssertEqual(reqNormal?.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 21 Oct 2015 07:28:00 GMT")

        // 2. force == true 应当完全忽略条件请求头并设置 reloadIgnoringLocalCacheData
        _ = try? await FeedService.fetch(feed, force: true)
        let reqForced = FeedServiceHeaderCaptureURLProtocol.lock.withLock {
            FeedServiceHeaderCaptureURLProtocol.lastRequest
        }
        XCTAssertNil(reqForced?.value(forHTTPHeaderField: "If-None-Match"), "force 为 true 时绝不能包含 If-None-Match")
        XCTAssertNil(reqForced?.value(forHTTPHeaderField: "If-Modified-Since"), "force 为 true 时绝不能包含 If-Modified-Since")
        XCTAssertEqual(reqForced?.cachePolicy, .reloadIgnoringLocalCacheData, "force 为 true 时必须强制绕过本地缓存")
    }

    func testBackfillCreatesFallbackStateIfArticleStateMissing() async throws {
        let feed = try provider.addFeed(
            title: "Fallback State Test",
            feedURL: URL(string: "https://example.com/fallback-state.xml")!
        )
        let feedID = feed.id.uuidString
        let itemID = "\(feedID)|missing-state-item".stableDigest

        // 创建孤立 ItemRecord（没有 ArticleRecord，也没有 ArticleStateRecord）
        try database.write { db in
            let item = ItemRecord(
                id: itemID,
                accountID: "local-default",
                externalID: itemID,
                feedID: feedID,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970
            )
            try item.save(db)
        }

        let parsed = ParsedFeedEntry(
            id: "missing-state-item",
            title: "Recovered",
            author: nil,
            url: nil,
            publishedAt: Date(),
            summary: "Summary",
            contentHTML: "<p>Text</p>"
        )

        let unreads = try database.write { db in
            try self.provider.articleRepository.mergeParsedEntries(
                accountID: "local-default",
                feedID: feedID,
                parsedEntries: [parsed],
                in: db
            )
        }
        XCTAssertTrue(unreads.isEmpty, "回填条目绝不能计入未读条目")

        let state = try database.read { db in
            try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db)
        }
        XCTAssertNotNil(state, "当 state 丢失时回填必须创建防御性 state 兜底")
        XCTAssertEqual(state?.isRead, true, "回填条目兜底状态必须为已读，防止幽灵复活")
    }
}

private final class FeedServiceHeaderCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "feedservice-header-test.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock {
            Self.lastRequest = request
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 304,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
