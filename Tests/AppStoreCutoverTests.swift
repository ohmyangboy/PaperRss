import XCTest
import GRDB
@testable import PaperRssCore

final class AppStoreCutoverTests: XCTestCase {
    var tempDir: URL!
    var legacyJSONURL: URL!
    var sqliteURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssStoreCutoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        legacyJSONURL = tempDir.appendingPathComponent("library.json")
        sqliteURL = tempDir.appendingPathComponent("library.sqlite")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testAppStoreStartupMigratesLegacyJSONAndStopsWritingJSON() async throws {
        // 构造旧版 legacy JSON 数据
        let feedUUID = UUID()
        let legacyFeed = Feed(
            id: feedUUID,
            title: "Legacy News",
            feedURL: URL(string: "https://legacy.com/rss")!
        )
        let legacyEntry = Entry(
            id: "legacy-entry-1",
            feedID: feedUUID,
            title: "Legacy Title",
            url: URL(string: "https://legacy.com/1"),
            publishedAt: Date(),
            summary: "Legacy summary"
        )
        let legacyDatabase = AppDatabase(
            feeds: [legacyFeed],
            entries: [legacyEntry],
            articleCaches: [:],
            readingStates: [
                "legacy-entry-1": ReadingState(entryID: "legacy-entry-1", isRead: true, isStarred: true)
            ],
            artifacts: [],
            llmConfiguration: .default,
            customFolders: ["OldFolder"]
        )
        let encodedData = try JSONEncoder.paperRss.encode(legacyDatabase)
        try encodedData.write(to: legacyJSONURL)

        // 启动 AppStore
        let store = AppStore(testDatabase: legacyDatabase, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })

        // 验证状态已完整载入
        XCTAssertEqual(store.feeds.count, 1)
        XCTAssertEqual(store.feeds.first?.title, "Legacy News")
        XCTAssertEqual(store.customFolders, ["OldFolder"])
        XCTAssertEqual(store.starredEntries.count, 1)

        // 修改数据：添加新源
        let newFeed = try store.localProvider.addFeed(
            title: "New SQLite Feed",
            feedURL: URL(string: "https://new.com/rss")!
        )
        store.reloadState()
        XCTAssertEqual(store.feeds.count, 2)

        // 验证 SQLite 数据库已保存新源
        try store.libraryDatabase.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds WHERE is_deleted = 0;")
            XCTAssertEqual(count, 2)
            let feedRecord = try FeedRecord.filter(Column("id") == newFeed.id.uuidString).fetchOne(db)
            XCTAssertNotNil(feedRecord)
            XCTAssertEqual(feedRecord?.title, "New SQLite Feed")
        }

        // 验证原 legacy library.json 绝不被覆盖写入（其内容与启动前完全一致）
        let currentJSONData = try Data(contentsOf: legacyJSONURL)
        let currentDecoded = try JSONDecoder.paperRss.decode(AppDatabase.self, from: currentJSONData)
        XCTAssertEqual(currentDecoded.feeds.count, 1) // 依然保持旧数据，运行时绝不更新 JSON
    }

    @MainActor
    func testFreshInstallBootstrapsSQLiteAuthoritatively() async throws {
        // 无 library.json 的新安装
        let store = AppStore(testDatabase: AppDatabase.empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })

        // 验证默认状态
        XCTAssertEqual(store.feeds.count, 0)
        XCTAssertEqual(store.sidebarCounts.allUnread, 0)

        // 验证 local-default 账号已初始化
        try store.libraryDatabase.read { db in
            let account = try AccountRecord.filter(Column("id") == "local-default").fetchOne(db)
            XCTAssertNotNil(account)
            XCTAssertEqual(account?.displayName, "本地订阅")
        }
    }

    @MainActor
    func testCorruptedLegacyJSONPreventsEmptyDatabaseBootstrapAndAllowsRetry() throws {
        // 1. 写入损坏的 JSON 数据
        let corruptContent = "{ this is invalid json content !!!"
        try corruptContent.write(to: legacyJSONURL, atomically: true, encoding: .utf8)

        // 2. 构造 AppStore 实例指向该损坏目录
        let customFM = FileManager.default
        let store = AppStore(fileManager: customFM, databaseURL: sqliteURL, persistenceURL: legacyJSONURL)

        // 验证 P0 契约：
        // - 向 UI 暴露明确 startupError
        XCTAssertNotNil(store.startupError)
        XCTAssertNotNil(store.lastError)
        // - 不进入空库正常运行状态（feeds 为空，未初始化）
        XCTAssertEqual(store.feeds.count, 0)
        // - SQLite 中绝不创建 local-default 账号
        try store.libraryDatabase.read { db in
            let account = try AccountRecord.filter(Column("id") == "local-default").fetchOne(db)
            XCTAssertNil(account, "Migration failed: local-default account must NOT be created!")
        }
        // - 原损坏文件原样保留
        let currentRaw = try String(contentsOf: legacyJSONURL, encoding: .utf8)
        XCTAssertEqual(currentRaw, corruptContent)

        // 3. 修复文件为有效数据，验证可安全重试
        let validFeed = Feed(id: UUID(), title: "Repaired News", feedURL: URL(string: "https://repaired.com/rss")!)
        let validDB = AppDatabase(
            feeds: [validFeed],
            entries: [],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default
        )
        let validData = try JSONEncoder.paperRss.encode(validDB)
        try validData.write(to: legacyJSONURL)

        // 再次启动
        let retryStore = AppStore(fileManager: customFM, databaseURL: sqliteURL, persistenceURL: legacyJSONURL)
        XCTAssertNil(retryStore.startupError)
        XCTAssertEqual(retryStore.feeds.count, 1)
        XCTAssertEqual(retryStore.feeds.first?.title, "Repaired News")
        try retryStore.libraryDatabase.read { db in
            let account = try AccountRecord.filter(Column("id") == "local-default").fetchOne(db)
            XCTAssertNotNil(account, "Retry succeeded: local-default account must exist now")
        }
    }

    @MainActor
    func testLegacyLLMConfigurationRecoveredWhenUserDefaultsMissing() throws {
        let defaults = UserDefaults.standard
        let prefKey = "PaperRss.llmConfiguration"
        defaults.removeObject(forKey: prefKey)
        defer { defaults.removeObject(forKey: prefKey) }

        var legacyLLM = LLMConfiguration.default
        legacyLLM.baseURL = "https://custom-legacy-llm.example.com/v1"
        legacyLLM.model = "custom-model-legacy"
        legacyLLM.customPrompt = "Legacy custom system prompt"

        let legacyDB = AppDatabase(
            feeds: [],
            entries: [],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: legacyLLM
        )
        let validData = try JSONEncoder.paperRss.encode(legacyDB)
        try validData.write(to: legacyJSONURL)

        let recovered = LegacyPreferenceMigrator.recoverLLMConfigurationIfNeeded(
            from: legacyJSONURL,
            userDefaults: defaults
        )
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.baseURL, "https://custom-legacy-llm.example.com/v1")
        XCTAssertEqual(recovered?.model, "custom-model-legacy")
        XCTAssertEqual(recovered?.customPrompt, "Legacy custom system prompt")

        // 验证 UserDefaults 已成功同步
        guard let savedData = defaults.data(forKey: prefKey),
              let savedConfig = try? JSONDecoder().decode(LLMConfiguration.self, from: savedData) else {
            XCTFail("UserDefaults must contain recovered LLMConfiguration")
            return
        }
        XCTAssertEqual(savedConfig.baseURL, "https://custom-legacy-llm.example.com/v1")
    }

    @MainActor
    func testExistingUserDefaultsConfigurationTakesPrecedenceOverLegacyJSON() throws {
        let defaults = UserDefaults.standard
        let prefKey = "PaperRss.llmConfiguration"

        var existingUserConfig = LLMConfiguration.default
        existingUserConfig.baseURL = "https://user-active-choice.example.com"
        existingUserConfig.model = "gpt-5-active"
        let encodedUserConfig = try JSONEncoder().encode(existingUserConfig)
        defaults.set(encodedUserConfig, forKey: prefKey)
        defer { defaults.removeObject(forKey: prefKey) }

        var legacyLLM = LLMConfiguration.default
        legacyLLM.baseURL = "https://obsolete-legacy.example.com"
        legacyLLM.model = "obsolete-model"
        let legacyDB = AppDatabase(
            feeds: [],
            entries: [],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: legacyLLM
        )
        let validData = try JSONEncoder.paperRss.encode(legacyDB)
        try validData.write(to: legacyJSONURL)

        let recovered = LegacyPreferenceMigrator.recoverLLMConfigurationIfNeeded(
            from: legacyJSONURL,
            userDefaults: defaults
        )
        // 现有 UserDefaults 绝对优先，返回现有配置
        XCTAssertEqual(recovered?.baseURL, "https://user-active-choice.example.com")
        XCTAssertEqual(recovered?.model, "gpt-5-active")

        guard let savedData = defaults.data(forKey: prefKey),
              let savedConfig = try? JSONDecoder().decode(LLMConfiguration.self, from: savedData) else {
            XCTFail("UserDefaults must retain user active config")
            return
        }
        XCTAssertEqual(savedConfig.baseURL, "https://user-active-choice.example.com")
    }

    @MainActor
    func testAIArtifactSelectionMetadataRoundTripAndRecovery() async throws {
        let db = try LibraryDatabase(databaseURL: sqliteURL)
        let repo = AIArtifactRepository(database: db)

        // 插入父级 feed 与 item
        let now = Date().timeIntervalSince1970
        try db.write { writeDB in
            try AccountRecord(id: "local-default", type: "local", displayName: "本地", isEnabled: true, createdAt: now, updatedAt: now).save(writeDB)
            try FeedRecord(id: "feed-1", accountID: "local-default", title: "Feed 1", feedURL: "https://feed.com", updatedAt: now).save(writeDB)
            try ItemRecord(id: "item-1", accountID: "local-default", externalID: "ext-1", feedID: "feed-1", createdAt: now, updatedAt: now).save(writeDB)
        }

        let anchor = AISelectionAnchor(paragraphID: "p-42", startOffset: 10, endOffset: 35)
        let artifact = AIArtifact(
            id: UUID(),
            entryID: "item-1",
            kind: .selectionExplanation,
            contentHash: "hash-42",
            model: "deepseek-chat",
            targetLanguage: "zh-Hans",
            content: "这是一个核心解释内容",
            selectionText: "选中的关键短语",
            selectionArticleHash: "article-hash-99",
            selectionAnchor: anchor,
            isComplete: true
        )

        try await repo.saveArtifactModel(artifact)

        // 重新查询
        let fetched = try await repo.fetchSelectionArtifacts(entryID: "item-1", articleHash: "article-hash-99")
        XCTAssertEqual(fetched.count, 1)
        let recovered = fetched.first!
        XCTAssertEqual(recovered.id, artifact.id)
        XCTAssertEqual(recovered.selectionText, "选中的关键短语")
        XCTAssertEqual(recovered.selectionArticleHash, "article-hash-99")
        XCTAssertEqual(recovered.selectionAnchor?.paragraphID, "p-42")
        XCTAssertEqual(recovered.selectionAnchor?.startOffset, 10)
        XCTAssertEqual(recovered.selectionAnchor?.endOffset, 35)
        XCTAssertEqual(recovered.content, "这是一个核心解释内容")
    }

    @MainActor
    func testLocalAccountDoesNotCreateRemoteAccountSyncState() throws {
        let db = try LibraryDatabase(databaseURL: sqliteURL)
        let provider = LocalAccountProvider(accountID: "local-default", database: db)
        try provider.ensureAccountExists()

        try db.read { readDB in
            let account = try AccountRecord.filter(Column("id") == "local-default").fetchOne(readDB)
            XCTAssertNotNil(account)

            let syncState = try AccountSyncStateRecord.filter(Column("account_id") == "local-default").fetchOne(readDB)
            XCTAssertNil(syncState, "Local account must NOT create account_sync_state record!")
        }
    }
}
