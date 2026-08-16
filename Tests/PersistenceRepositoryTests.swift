import XCTest
import GRDB
@testable import PaperRssCore

final class PersistenceRepositoryTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var database: LibraryDatabase!
    private var accountRepo: AccountRepository!
    private var feedRepo: FeedRepository!
    private var articleRepo: ArticleRepository!
    private var stateRepo: ArticleStateRepository!
    private var cacheRepo: CacheRepository!
    private var aiRepo: AIArtifactRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssRepoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        let dbURL = temporaryDirectoryURL.appendingPathComponent("repo-test.sqlite")
        database = try LibraryDatabase(databaseURL: dbURL)

        accountRepo = AccountRepository(database: database)
        feedRepo = FeedRepository(database: database)
        articleRepo = ArticleRepository(database: database)
        stateRepo = ArticleStateRepository(database: database)
        cacheRepo = CacheRepository(database: database)
        aiRepo = AIArtifactRepository(database: database)
    }

    override func tearDownWithError() throws {
        accountRepo = nil
        feedRepo = nil
        articleRepo = nil
        stateRepo = nil
        cacheRepo = nil
        aiRepo = nil
        database = nil
        if let temporaryDirectoryURL, FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Record Round-Trip & Type Contracts (REAL / Bool / Nullable / Opaque String)

    func testAccountAndSyncStateRoundTrip() async throws {
        let account = AccountRecord(
            id: "acc_test_1",
            type: "freshRSS",
            displayName: "My Server",
            endpointURL: "https://rss.example.com/api/greader.php",
            username: "alice",
            isEnabled: true,
            createdAt: 1700000000.123,
            updatedAt: 1700000050.456
        )
        try await accountRepo.saveAccount(account)

        let fetched = try await accountRepo.fetchAccount(id: "acc_test_1")
        XCTAssertEqual(fetched, account)

        let syncState = AccountSyncStateRecord(
            accountID: "acc_test_1",
            initialSyncCompleted: true,
            lastSyncStartedAt: 1700000100.0,
            lastSyncCompletedAt: 1700000110.0,
            lastFullReconcileAt: 1700000000.0,
            lastArticleFetchAt: 1700000105.0,
            consecutiveFailureCount: 2,
            lastError: "Connection timeout"
        )
        try await accountRepo.saveSyncState(syncState)

        let fetchedSync = try await accountRepo.fetchSyncState(accountID: "acc_test_1")
        XCTAssertEqual(fetchedSync, syncState)
    }

    func testFeedAndFolderWithMultipleFolders() async throws {
        let account = AccountRecord(
            id: "acc_local",
            type: "local",
            displayName: "Local Account",
            createdAt: 1000.0,
            updatedAt: 1000.0
        )
        try await accountRepo.saveAccount(account)

        let folder1 = FolderRecord(id: "fol_1", accountID: "acc_local", name: "News", updatedAt: 1000.0)
        let folder2 = FolderRecord(id: "fol_2", accountID: "acc_local", name: "Tech", updatedAt: 1000.0)
        try await feedRepo.saveFolder(folder1)
        try await feedRepo.saveFolder(folder2)

        let feed = FeedRecord(
            id: "feed_1",
            accountID: "acc_local",
            externalID: "opaque-str-999#special/chars",
            title: "Swift Org",
            siteURL: "https://swift.org",
            feedURL: "https://swift.org/atom.xml",
            etag: "\"etag-123\"",
            lastModified: "Wed, 21 Oct 2025 07:28:00 GMT",
            lastRefreshedAt: 1050.0,
            isDeleted: false,
            updatedAt: 1000.0,
            storedIconURL: "https://swift.org/favicon.ico",
            sortOrder: 1
        )
        try await feedRepo.saveFeed(feed)

        // 绑定两个 Folder
        try await feedRepo.setFeedFolders(feedID: "feed_1", folderIDs: ["fol_1", "fol_2"])

        let folderIDs = try await feedRepo.fetchFolderIDs(forFeedID: "feed_1")
        XCTAssertEqual(folderIDs, ["fol_1", "fol_2"])

        let feeds = try await feedRepo.fetchAllFeeds(accountID: "acc_local")
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.externalID, "opaque-str-999#special/chars")
    }

    func testItemWithoutArticleAndIndependentState() async throws {
        let account = AccountRecord(id: "acc_freshrss", type: "freshRSS", displayName: "FreshRSS", createdAt: 1000.0, updatedAt: 1000.0)
        try await accountRepo.saveAccount(account)

        let feed = FeedRecord(id: "feed_fr", accountID: "acc_freshrss", title: "Feed", feedURL: "https://f.com", updatedAt: 1000.0)
        try await feedRepo.saveFeed(feed)

        let item = ItemRecord(
            id: "item_header_only",
            accountID: "acc_freshrss",
            externalID: "tag:google.com,2005:reader/item/0000000000001234",
            feedID: "feed_fr",
            createdAt: 1000.0,
            updatedAt: 1000.0
        )
        try await articleRepo.saveItem(item)

        let state = ArticleStateRecord(
            itemID: "item_header_only",
            isRead: false,
            isStarred: true,
            dateArrived: 1000.0,
            updatedAt: 1000.0
        )
        try await stateRepo.saveState(state)

        // 验证 item 和 state 存在，而 article 为 nil
        let fetchedItem = try await articleRepo.fetchItem(id: "item_header_only")
        let fetchedState = try await stateRepo.fetchState(itemID: "item_header_only")
        let fetchedArticle = try await articleRepo.fetchArticle(itemID: "item_header_only")

        XCTAssertNotNil(fetchedItem)
        XCTAssertNotNil(fetchedState)
        XCTAssertTrue(fetchedState?.isStarred == true)
        XCTAssertNil(fetchedArticle, "Item 可以在未拉取 Article 正文的情况下独立存在")

        // 随后拉取并填充 Article 正文
        let article = ArticleRecord(
            itemID: "item_header_only",
            title: "Header Now Has Body",
            author: "John Doe",
            url: "https://example.com/p/1",
            publishedAt: 990.0,
            summary: "Short summary",
            contentHTML: "<p>Full content</p>",
            contentUpdatedAt: 1100.0
        )
        try await articleRepo.saveArticle(article)

        let updatedArticle = try await articleRepo.fetchArticle(itemID: "item_header_only")
        XCTAssertEqual(updatedArticle?.title, "Header Now Has Body")
    }

    func testCacheAndArticleStateOutbox() async throws {
        let account = AccountRecord(id: "acc_1", type: "freshRSS", displayName: "FreshRSS", createdAt: 1000.0, updatedAt: 1000.0)
        try await accountRepo.saveAccount(account)
        let feed = FeedRecord(id: "feed_1", accountID: "acc_1", title: "Feed", feedURL: "https://f.com", updatedAt: 1000.0)
        try await feedRepo.saveFeed(feed)
        let item = ItemRecord(id: "item_1", accountID: "acc_1", externalID: "ext_1", feedID: "feed_1", createdAt: 1000.0, updatedAt: 1000.0)
        try await articleRepo.saveItem(item)

        // Cache
        let cache = ArticleCacheRecord(
            itemID: "item_1",
            text: "Clean extracted plain text",
            html: "<div>Extracted HTML</div>",
            imageUrlsJSON: "[\"https://img.com/1.png\"]",
            fetchedAt: 1050.0,
            sourceURL: "https://source.com/1",
            isSanitized: true
        )
        try await cacheRepo.saveCache(cache)

        let fetchedCache = try await cacheRepo.fetchCache(itemID: "item_1")
        XCTAssertEqual(fetchedCache, cache)

        // Outbox 原子保存与删除
        let state = ArticleStateRecord(itemID: "item_1", isRead: true, isStarred: false, dateArrived: 1000.0, updatedAt: 1050.0)
        let outbox = ArticleStateOutboxRecord(
            accountID: "acc_1",
            itemID: "item_1",
            stateKey: "read",
            desiredValue: true,
            revision: 1,
            updatedAt: 1050.0,
            attemptCount: 0,
            nextAttemptAt: nil,
            lastError: nil
        )
        try await stateRepo.saveStateAndOutbox(state: state, outbox: outbox)

        let pendingOutbox = try await stateRepo.fetchPendingOutbox(accountID: "acc_1")
        XCTAssertEqual(pendingOutbox.count, 1)
        XCTAssertEqual(pendingOutbox.first?.stateKey, "read")

        // 模拟网络同步成功后删除特定 revision
        let deleted = try await stateRepo.deleteOutbox(accountID: "acc_1", itemID: "item_1", stateKey: "read", revision: 1)
        XCTAssertTrue(deleted)

        let afterDelete = try await stateRepo.fetchPendingOutbox(accountID: "acc_1")
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testArticleScopedAndGlobalAIArtifacts() async throws {
        let account = AccountRecord(id: "acc_1", type: "local", displayName: "Local", createdAt: 1000.0, updatedAt: 1000.0)
        try await accountRepo.saveAccount(account)
        let feed = FeedRecord(id: "feed_1", accountID: "acc_1", title: "Feed", feedURL: "https://f.com", updatedAt: 1000.0)
        try await feedRepo.saveFeed(feed)
        let item = ItemRecord(id: "item_1", accountID: "acc_1", externalID: "ext_1", feedID: "feed_1", createdAt: 1000.0, updatedAt: 1000.0)
        try await articleRepo.saveItem(item)

        // 1. Article-scoped artifact
        let articleArtifact = AIArtifactRecord(
            id: "art_article_1",
            accountID: "acc_1",
            itemID: "item_1",
            subjectKey: "item_1",
            kind: "summary",
            contentHash: "hash_summary_123",
            model: "deepseek-chat",
            targetLanguage: "zh-Hans",
            content: "这是一篇测试文章的摘要",
            isComplete: true,
            createdAt: 1000.0,
            updatedAt: 1000.0
        )
        try await aiRepo.saveArtifact(articleArtifact)

        let fetchedArticleArt = try await aiRepo.fetchArtifactByArticle(
            itemID: "item_1",
            kind: "summary",
            contentHash: "hash_summary_123"
        )
        XCTAssertEqual(fetchedArticleArt?.content, "这是一篇测试文章的摘要")

        // 2. Global Translation Memory artifact (account_id = nil, item_id = nil)
        let globalArtifact = AIArtifactRecord(
            id: "art_global_1",
            accountID: nil,
            itemID: nil,
            subjectKey: "tm_para_sha256_xyz",
            kind: "translation",
            contentHash: "hash_trans_456",
            model: "deepseek-chat",
            targetLanguage: "zh-Hans",
            content: "全局翻译记忆段落",
            isComplete: true,
            createdAt: 1000.0,
            updatedAt: 1000.0
        )
        try await aiRepo.saveArtifact(globalArtifact)

        let fetchedGlobalArt = try await aiRepo.fetchGlobalArtifact(
            subjectKey: "tm_para_sha256_xyz",
            kind: "translation",
            contentHash: "hash_trans_456"
        )
        XCTAssertEqual(fetchedGlobalArt?.content, "全局翻译记忆段落")
    }

    // MARK: - 2. Atomic Migration Transaction & Rollback Test (DA-04 Compatibility)

    enum MigrationTestError: Error {
        case simulatedFailure
    }

    func testAtomicMultiTableTransactionRollback() throws {
        // 验证在单个 database.write 事务中执行全表写入，如果中途抛出异常，所有表全部原子回滚
        XCTAssertThrowsError(
            try database.write { db in
                let acc = AccountRecord(id: "tx_acc", type: "local", displayName: "Tx Acc", createdAt: 1000.0, updatedAt: 1000.0)
                try accountRepo.saveAccount(acc, in: db)

                let feed = FeedRecord(id: "tx_feed", accountID: "tx_acc", title: "Tx Feed", feedURL: "https://tx.com", updatedAt: 1000.0)
                try feedRepo.saveFeed(feed, in: db)

                let item = ItemRecord(id: "tx_item", accountID: "tx_acc", externalID: "tx_ext", feedID: "tx_feed", createdAt: 1000.0, updatedAt: 1000.0)
                try articleRepo.saveItem(item, in: db)

                let state = ArticleStateRecord(itemID: "tx_item", isRead: true, isStarred: false, dateArrived: 1000.0, updatedAt: 1000.0)
                try stateRepo.saveState(state, in: db)

                // 故意在此抛出错误触发回滚
                throw MigrationTestError.simulatedFailure
            }
        ) { error in
            guard let migError = error as? MigrationTestError, migError == .simulatedFailure else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        // 验证事务完全回滚，各表均不存在写入记录
        try database.read { db in
            XCTAssertNil(try accountRepo.fetchAccount(id: "tx_acc", in: db))
            XCTAssertNil(try feedRepo.fetchFeed(id: "tx_feed", in: db))
            XCTAssertNil(try articleRepo.fetchItem(id: "tx_item", in: db))
            XCTAssertNil(try stateRepo.fetchState(itemID: "tx_item", in: db))
        }
    }
}
