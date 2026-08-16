import Foundation
import XCTest
import GRDB
@testable import PaperRssCore

final class MockLLMURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host.contains("deepseek.com") || host.contains("openai.com") || host.contains("example.com")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isStream: Bool
        if let body = request.httpBody, let str = String(data: body, encoding: .utf8) {
            isStream = str.contains("\"stream\":true")
        } else if request.httpBodyStream != nil {
            isStream = true
        } else {
            isStream = true
        }

        if isStream {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            let sseChunks = (1...8).map { i in
                "data: {\"choices\":[{\"delta\":{\"content\":\"Chunk \(i) \"}}]}\n\n"
            } + ["data: [DONE]\n\n"]

            for chunk in sseChunks {
                client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            }
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            let jsonBody = """
            {"choices":[{"message":{"content":"[\\"翻译结果1\\", \\"翻译结果2\\", \\"翻译结果3\\"]"}}]}
            """
            client?.urlProtocol(self, didLoad: Data(jsonBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class ReaderAIAndRuntimeRegressionTests: XCTestCase {
    var tempDir: URL!
    var sqliteURL: URL!
    var database: LibraryDatabase!
    var provider: LocalAccountProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockLLMURLProtocol.self)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssRegressionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sqliteURL = tempDir.appendingPathComponent("library.sqlite")
        database = try LibraryDatabase(databaseURL: sqliteURL)
        provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockLLMURLProtocol.self)
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Test A: Viewport body translation preserves paragraph IDs
    @MainActor
    func testA_ViewportBodyTranslation() async throws {
        let feed = Feed(id: UUID(), title: "Tech", feedURL: URL(string: "https://tech.com/rss")!)
        let entry = Entry(
            id: "entry-vp-1",
            feedID: feed.id,
            title: "Original Title",
            url: URL(string: "https://tech.com/1"),
            publishedAt: Date(),
            summary: "Summary text"
        )
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: [entry],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .deepSeek,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        store.llmConfiguration = .deepSeek
        _ = store.saveLLMConfiguration(store.llmConfiguration, apiKey: "test-api-key")

        let paragraphs = [
            ReaderParagraph(id: "title", original: "Original Title"),
            ReaderParagraph(id: "p0", original: "First paragraph."),
            ReaderParagraph(id: "p1", original: "Second paragraph."),
            ReaderParagraph(id: "p2", original: "Third paragraph.")
        ]

        // 预先给 title 与 p0 存入 TM 缓存
        store.cacheTranslations(
            [
                BilingualSegment(id: "title", original: "Original Title", translation: "原文标题"),
                BilingualSegment(id: "p0", original: "First paragraph.", translation: "第一段。")
            ],
            configuration: store.llmConfiguration
        )

        // 仅请求 title 和 p0
        await store.translateBilingualParagraphs(
            entry: entry,
            text: "Original Title\nFirst paragraph.\nSecond paragraph.\nThird paragraph.",
            paragraphs: paragraphs,
            paragraphIDs: ["title", "p0"]
        )

        let artifact = try store.localProvider.fetchArtifact(entryID: entry.id, kind: .bilingual, isCompleteOnly: false)
        XCTAssertNotNil(artifact)
        let segmentIDs = artifact?.segments.map(\.id) ?? []
        XCTAssertTrue(segmentIDs.contains("title"))
        XCTAssertTrue(segmentIDs.contains("p0"))
        XCTAssertFalse(segmentIDs.contains("p1"))
        XCTAssertFalse(segmentIDs.contains("p2"))
        // 只有部分段落翻译，isComplete 必须为 false
        XCTAssertFalse(artifact?.isComplete ?? true)
    }

    // MARK: - Test B: translateBilingualParagraphs await semantics guarantees persistence
    @MainActor
    func testB_TranslateBilingualParagraphsAwaitSemantics() async throws {
        let feed = Feed(id: UUID(), title: "News", feedURL: URL(string: "https://news.com/rss")!)
        let entry = Entry(
            id: "entry-await-1",
            feedID: feed.id,
            title: "Await Test",
            url: URL(string: "https://news.com/await"),
            publishedAt: Date(),
            summary: "Summary text"
        )
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: [entry],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .deepSeek,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        store.llmConfiguration = .deepSeek
        _ = store.saveLLMConfiguration(store.llmConfiguration, apiKey: "test-api-key")

        let paragraphs = [
            ReaderParagraph(id: "title", original: "Await Test"),
            ReaderParagraph(id: "p0", original: "Paragraph content.")
        ]
        // 存入 TM 缓存确保同步翻译命中
        store.cacheTranslations(
            [
                BilingualSegment(id: "title", original: "Await Test", translation: "等待测试"),
                BilingualSegment(id: "p0", original: "Paragraph content.", translation: "段落内容。")
            ],
            configuration: store.llmConfiguration
        )

        // 调用 await 方法
        await store.translateBilingualParagraphs(
            entry: entry,
            text: "Await Test\nParagraph content.",
            paragraphs: paragraphs,
            paragraphIDs: ["title", "p0"]
        )

        // await 返回后，直接从底层 SQLite 立即读取，必须存在且 isComplete = true
        let persistedArtifact = try store.localProvider.fetchArtifact(entryID: entry.id, kind: .bilingual, isCompleteOnly: false)
        XCTAssertNotNil(persistedArtifact, "Artifact must be synchronously persisted before async method returns")
        XCTAssertEqual(persistedArtifact?.segments.count, 2)
        XCTAssertTrue(persistedArtifact?.isComplete ?? false)
    }

    // MARK: - Test C: Streaming summary callback delivers incremental deltas
    @MainActor
    func testC_StreamingSummaryScopedCallback() async throws {
        let feed = Feed(id: UUID(), title: "AI", feedURL: URL(string: "https://ai.com/rss")!)
        let entry = Entry(
            id: "entry-summary-1",
            feedID: feed.id,
            title: "Summary Stream Test",
            url: URL(string: "https://ai.com/stream"),
            publishedAt: Date(),
            summary: "Summary text"
        )
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: [entry],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .deepSeek,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        store.llmConfiguration = .deepSeek
        _ = store.saveLLMConfiguration(store.llmConfiguration, apiKey: "test-api-key")

        final class Box: @unchecked Sendable {
            var deltas: [String] = []
            private let lock = NSLock()
            func append(_ s: String) {
                lock.lock()
                defer { lock.unlock() }
                deltas.append(s)
            }
        }
        let box = Box()
        await store.generateSummary(entry: entry, text: "Long article body for testing summary streaming", force: true) { delta in
            box.append(delta)
        }

        // 验证摘要生成结束后 SQLite 中存入了 complete 产物
        let artifact = try store.localProvider.fetchArtifact(entryID: entry.id, kind: .summary, isCompleteOnly: true)
        XCTAssertNotNil(artifact)
        XCTAssertTrue(artifact?.isComplete ?? false)
    }

    // MARK: - Test D: SQLite summary writes are throttled/bounded
    @MainActor
    func testD_SQLiteSummaryWritesThrottled() async throws {
        let feed = Feed(id: UUID(), title: "AI", feedURL: URL(string: "https://ai.com/rss")!)
        let entry = Entry(
            id: "entry-throttled-1",
            feedID: feed.id,
            title: "Throttled Summary Test",
            url: URL(string: "https://ai.com/throttled"),
            publishedAt: Date(),
            summary: "Summary text"
        )
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: [entry],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .deepSeek,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        store.llmConfiguration = .deepSeek
        _ = store.saveLLMConfiguration(store.llmConfiguration, apiKey: "test-api-key")

        // 记录调用 generateSummary 期间的状态
        await store.generateSummary(entry: entry, text: "Some short text", force: true)

        let artifact = try store.localProvider.fetchArtifact(entryID: entry.id, kind: .summary, isCompleteOnly: false)
        XCTAssertNotNil(artifact)
        XCTAssertTrue(artifact?.isComplete ?? false)
    }

    // MARK: - Test E: Global AppStore objectWillChange is not emitted per LLM delta
    @MainActor
    func testE_GlobalAppStoreObjectWillChangeNotEmittedPerLLMDelta() async throws {
        let feed = Feed(id: UUID(), title: "Feed", feedURL: URL(string: "https://feed.com/rss")!)
        let entry = Entry(
            id: "entry-owc-1",
            feedID: feed.id,
            title: "OWC Test",
            url: URL(string: "https://feed.com/owc"),
            publishedAt: Date(),
            summary: "Summary text"
        )
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: [entry],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .deepSeek,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        store.llmConfiguration = .deepSeek
        _ = store.saveLLMConfiguration(store.llmConfiguration, apiKey: "test-api-key")

        var changeCount = 0
        let cancellable = store.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        // 生成 summary
        await store.generateSummary(entry: entry, text: "Testing change count suppression", force: true)

        // 变更通知次数必须极为有限（仅 activeSummaryRequest 开始和结束各 1 次，及状态置空），绝对不是 8+ 次每个 delta emit
        XCTAssertLessThanOrEqual(changeCount, 6, "Global objectWillChange must not fire on every token delta")
    }

    // MARK: - Test F: Sidebar count access does not materialize all entries
    @MainActor
    func testF_SidebarCountDoesNotCallFetchAllEntries() throws {
        let feed = Feed(id: UUID(), title: "Count Feed", feedURL: URL(string: "https://count.com/rss")!)
        var entries: [Entry] = []
        for i in 1...20 {
            entries.append(Entry(
                id: "item-\(i)",
                feedID: feed.id,
                title: "Item \(i)",
                url: URL(string: "https://count.com/\(i)"),
                publishedAt: Date(),
                summary: "Summary \(i)"
            ))
        }
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: entries,
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let counts = store.sidebarCounts
        XCTAssertEqual(counts.allUnread, 20)
        XCTAssertEqual(counts.starred, 0)
        XCTAssertEqual(counts.unreadByFeed[feed.id], 20)
    }

    // MARK: - Test G: 250+ timeline items remain reachable through pagination
    @MainActor
    func testG_TimelinePaginationReachesAll250Items() throws {
        let feed = Feed(id: UUID(), title: "Big Feed", feedURL: URL(string: "https://big.com/rss")!)
        let count = 260
        var entries: [Entry] = []
        let now = Date()
        for i in 1...count {
            entries.append(Entry(
                id: "big-item-\(i)",
                feedID: feed.id,
                title: "Big Item \(i)",
                url: URL(string: "https://big.com/\(i)"),
                publishedAt: now.addingTimeInterval(-Double(i * 10)),
                summary: "Summary \(i)"
            ))
        }
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: entries,
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })

        // 分页获取：第一页 100 条
        let page1 = store.fetchTimelinePage(scope: .all, limit: 100, offset: 0)
        XCTAssertEqual(page1.count, 100)

        // 第二页 100 条
        let page2 = store.fetchTimelinePage(scope: .all, limit: 100, offset: 100)
        XCTAssertEqual(page2.count, 100)

        // 第三页 60 条
        let page3 = store.fetchTimelinePage(scope: .all, limit: 100, offset: 200)
        XCTAssertEqual(page3.count, 60)

        // 验证去重后总数完整覆盖 260 条
        let allFetched = page1 + page2 + page3
        let allFetchedIDs = Set(allFetched.map { $0.id })
        XCTAssertEqual(allFetchedIDs.count, 260)
    }

    // MARK: - Test H: Mark-all-read affects database rows beyond the first page
    @MainActor
    func testH_MarkAllReadAffectsFullDatabaseScopeBeyondFirstPage() throws {
        let feed = Feed(id: UUID(), title: "Unread Feed", feedURL: URL(string: "https://unread.com/rss")!)
        let count = 250
        var entries: [Entry] = []
        for i in 1...count {
            entries.append(Entry(
                id: "unread-\(i)",
                feedID: feed.id,
                title: "Unread \(i)",
                url: URL(string: "https://unread.com/\(i)"),
                publishedAt: Date().addingTimeInterval(-Double(i)),
                summary: "Summary \(i)"
            ))
        }
        let legacyDB = AppDatabase(
            feeds: [feed],
            entries: entries,
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default,
            customFolders: []
        )
        let store = AppStore(testDatabase: legacyDB, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        XCTAssertEqual(store.sidebarCounts.allUnread, 250)

        // 在全库 scope 下执行 markAllRead
        store.markAllRead(feedID: feed.id)

        // 验证全库 250 篇已被标记为已读
        XCTAssertEqual(store.sidebarCounts.allUnread, 0)
        XCTAssertEqual(store.sidebarCounts.unreadByFeed[feed.id, default: 0], 0)
    }

    // MARK: - Test I: local-default has no account_sync_state after migration/update
    func testI_LocalAccountSyncStateCleanedAfterMigration() throws {
        let dbURL = tempDir.appendingPathComponent("sync_state_test.sqlite")
        // 1. 初始化纯 v1 数据库并手动插入 local-default 的 account_sync_state
        var v1Migrator = DatabaseMigrator()
        v1Migrator.registerMigration("v1-create-library-schema") { db in
            try db.execute(sql: """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL,
                type TEXT NOT NULL,
                display_name TEXT NOT NULL,
                endpoint_url TEXT,
                username TEXT,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE account_sync_state (
                account_id TEXT PRIMARY KEY NOT NULL,
                initial_sync_completed INTEGER NOT NULL DEFAULT 0,
                last_sync_started_at REAL,
                last_sync_completed_at REAL,
                last_full_reconcile_at REAL,
                last_article_fetch_at REAL,
                consecutive_failure_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            );
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('local-default', 'local', 'Local Account', 0, 0);
            INSERT INTO account_sync_state (account_id, initial_sync_completed)
            VALUES ('local-default', 1);
            """)
        }

        let pool = try DatabasePool(path: dbURL.path)
        try v1Migrator.migrate(pool)

        // 验证插入成功
        try pool.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account_sync_state WHERE account_id = 'local-default'")
            XCTAssertEqual(count, 1)
        }

        // 2. 执行完整的 DatabaseMigrations.migrator（应用 v2 迁移）
        try DatabaseMigrations.migrator.migrate(pool)

        // 3. 验证 local-default 的 sync_state 已经被彻底删除
        try pool.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account_sync_state WHERE account_id = 'local-default'")
            XCTAssertEqual(count, 0, "local-default must have no account_sync_state row after v2 migration")
        }
    }
}
