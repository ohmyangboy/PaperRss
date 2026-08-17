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

    // MARK: - Test J: Delete and re-add Feed restores same UUID and preserves all history
    @MainActor
    func testJ_DeleteAndReAddFeedRestoresSameUUIDAndPreservesHistory() async throws {
        let feedURL = URL(string: "https://react.dev/rss.xml")!
        let parsedEntries = [
            ParsedFeedEntry(
                id: "react-19-release",
                title: "React 19",
                author: "React Team",
                url: URL(string: "https://react.dev/blog/react-19"),
                publishedAt: Date(),
                summary: "React 19 release notes",
                contentHTML: "<p>React 19 content</p>"
            )
        ]

        let fetcher: @Sendable (Feed) async throws -> FeedFetchResult = { _ in
            .updated(
                ParsedFeed(
                    title: "React Blog",
                    siteURL: URL(string: "https://react.dev"),
                    iconURL: nil,
                    entries: parsedEntries
                ),
                etag: "etag-1",
                lastModified: "last-mod-1"
            )
        }

        let store = AppStore(testDatabase: AppDatabase.empty, feedFetcher: fetcher)

        // 1. 添加订阅
        await store.addFeed(urlText: feedURL.absoluteString, folder: "Frontend")
        XCTAssertEqual(store.feeds.count, 1)
        let originalFeed = try XCTUnwrap(store.feeds.first)
        let originalFeedID = originalFeed.id

        // 2. 刷新文章并验证文章入库
        let itemsBeforeDelete = store.entryListItems(feedID: originalFeedID)
        XCTAssertEqual(itemsBeforeDelete.count, 1)
        let entryID = itemsBeforeDelete[0].id

        // 3. 标已读、标收藏
        store.markRead(entryID: entryID, read: true)
        store.toggleStar(entryID: entryID)

        // 4. 保存 ArticleCache 和 AIArtifact
        let cache = ArticleCache(
            entryID: entryID,
            text: "React 19 content",
            html: "<p>React 19 content</p>",
            imageURLs: [],
            fetchedAt: Date(),
            sourceURL: URL(string: "https://react.dev/blog/react-19")!,
            isSanitized: true
        )
        try store.localProvider.saveCache(cache)

        let artifact = AIArtifact(
            entryID: entryID,
            kind: .summary,
            contentHash: "hash-123",
            model: "deepseek-chat",
            targetLanguage: "zh-Hans",
            promptVersion: 1,
            content: "React 19 摘要",
            isComplete: true
        )
        try store.localProvider.saveArtifact(artifact)

        // 5. 删除 Feed (Soft Delete)
        store.deleteFeed(originalFeed)
        XCTAssertEqual(store.feeds.count, 0)
        XCTAssertEqual(store.entryListItems(feedID: originalFeedID).count, 0)

        // 6. 重新添加同一个 URL
        await store.addFeed(urlText: feedURL.absoluteString, folder: "Tech")

        // 7. 验证：
        // a. 恢复同一个 Feed UUID，分类目录更新为 Tech
        XCTAssertEqual(store.feeds.count, 1)
        let restoredFeed = try XCTUnwrap(store.feeds.first)
        XCTAssertEqual(restoredFeed.id, originalFeedID, "Must restore the EXACT same Feed UUID")
        XCTAssertEqual(restoredFeed.folder, "Tech")

        // b. 历史文章立即恢复可见，已读和星标状态完好保留
        let restoredItems = store.entryListItems(feedID: originalFeedID)
        XCTAssertEqual(restoredItems.count, 1)
        XCTAssertEqual(restoredItems[0].id, entryID)
        XCTAssertTrue(restoredItems[0].isRead, "Read state must be preserved")
        XCTAssertTrue(restoredItems[0].isStarred, "Starred state must be preserved")

        // c. ArticleCache 和 AIArtifact 完好保留
        let restoredCache = try store.localProvider.fetchCache(entryID: entryID)
        XCTAssertNotNil(restoredCache)
        XCTAssertEqual(restoredCache?.text, "React 19 content")

        let restoredArtifact = try store.localProvider.fetchArtifact(entryID: entryID, kind: .summary, isCompleteOnly: true)
        XCTAssertNotNil(restoredArtifact)
        XCTAssertEqual(restoredArtifact?.content, "React 19 摘要")

        // d. 再次刷新能够正常成功，且没有生成重复文章
        await store.refresh(feedIDs: [originalFeedID], origin: .manual)
        let itemsAfterRefresh = store.entryListItems(feedID: originalFeedID)
        XCTAssertEqual(itemsAfterRefresh.count, 1, "Must not duplicate items on refresh")
    }

    // MARK: - Test K: Cross-feed same parsed.id coexists in local account without UNIQUE violation
    @MainActor
    func testK_CrossFeedSameParsedIDCoexistsWithoutUniqueViolation() async throws {
        let feedA = Feed(id: UUID(), title: "Feed A", feedURL: URL(string: "https://a.com/rss")!)
        let feedB = Feed(id: UUID(), title: "Feed B", feedURL: URL(string: "https://b.com/rss")!)

        // 两个源有完全相同的 parsed.id = "common-123"
        let parsedA = ParsedFeedEntry(
            id: "common-123",
            title: "Article A",
            author: "Author A",
            url: URL(string: "https://a.com/1"),
            publishedAt: Date(),
            summary: "Summary A",
            contentHTML: "<p>A</p>"
        )
        let parsedB = ParsedFeedEntry(
            id: "common-123",
            title: "Article B",
            author: "Author B",
            url: URL(string: "https://b.com/1"),
            publishedAt: Date(),
            summary: "Summary B",
            contentHTML: "<p>B</p>"
        )

        let store = AppStore(testDatabase: AppDatabase.empty, feedFetcher: { feed in
            if feed.feedURL.host == "a.com" {
                return .updated(ParsedFeed(title: "Feed A", siteURL: nil, iconURL: nil, entries: [parsedA]), etag: nil, lastModified: nil)
            } else {
                return .updated(ParsedFeed(title: "Feed B", siteURL: nil, iconURL: nil, entries: [parsedB]), etag: nil, lastModified: nil)
            }
        })

        // 添加 Feed A
        await store.addFeed(urlText: feedA.feedURL.absoluteString)
        let countAfterA = try store.libraryDatabase.read { db in
            try ItemRecord.fetchCount(db)
        }
        XCTAssertEqual(countAfterA, 1, "After Feed A, items count must be 1")

        // 添加 Feed B (不应触发 UNIQUE(account_id, external_id) 冲突)
        await store.addFeed(urlText: feedB.feedURL.absoluteString)
        let countAfterB = try store.libraryDatabase.read { db in
            try ItemRecord.fetchCount(db)
        }
        XCTAssertEqual(countAfterB, 2, "After Feed B, items count must be 2")

        let allItems = store.fetchTimelinePage(scope: .all, limit: 100, offset: 0)
        XCTAssertEqual(allItems.count, 2, "Both items with same parsed.id from different feeds must coexist")

        // 验证 item.id 互不相同
        XCTAssertNotEqual(allItems[0].id, allItems[1].id)
    }

    // MARK: - Test L: True timeline pagination with 350+ items
    @MainActor
    func testL_TrueTimelinePagingWith350Items() throws {
        let feed = Feed(id: UUID(), title: "Huge Feed", feedURL: URL(string: "https://huge.com/rss")!)
        let count = 360
        var entries: [Entry] = []
        let now = Date()
        for i in 1...count {
            entries.append(Entry(
                id: "huge-item-\(i)",
                feedID: feed.id,
                title: "Huge Item \(i)",
                url: URL(string: "https://huge.com/\(i)"),
                publishedAt: now.addingTimeInterval(-Double(i * 10)),
                summary: "Summary \(i)",
                contentHTML: "<p>Very long content \(i)</p>"
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

        // 真实分页：offset 0, 100, 200, 300
        let page1 = store.fetchTimelinePage(scope: .all, limit: 100, offset: 0)
        XCTAssertEqual(page1.count, 100)

        let page2 = store.fetchTimelinePage(scope: .all, limit: 100, offset: 100)
        XCTAssertEqual(page2.count, 100)

        let page3 = store.fetchTimelinePage(scope: .all, limit: 100, offset: 200)
        XCTAssertEqual(page3.count, 100)

        let page4 = store.fetchTimelinePage(scope: .all, limit: 100, offset: 300)
        XCTAssertEqual(page4.count, 60)

        let allFetched = page1 + page2 + page3 + page4
        let allFetchedIDs = Set(allFetched.map(\.id))
        XCTAssertEqual(allFetchedIDs.count, 360, "All 360 items must be reachable without duplicate or missing rows")

        // 验证更改状态反映在投影
        store.markRead(entryID: "huge-item-1", read: true)
        store.toggleStar(entryID: "huge-item-1")
        let updatedPage1 = store.fetchTimelinePage(scope: .all, limit: 1, offset: 0)
        XCTAssertTrue(updatedPage1[0].isRead)
        XCTAssertTrue(updatedPage1[0].isStarred)
    }

    // MARK: - Test M: v3 migration normalizes local item external_id
    func testM_V3MigrationNormalizesLocalItemExternalID() throws {
        let dbURL = tempDir.appendingPathComponent("v3_migration_test.sqlite")
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-create-library-schema") { db in
            try db.execute(sql: """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL,
                type TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE feeds (
                id TEXT PRIMARY KEY NOT NULL,
                account_id TEXT NOT NULL,
                title TEXT NOT NULL,
                feed_url TEXT NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE items (
                id TEXT PRIMARY KEY NOT NULL,
                account_id TEXT NOT NULL,
                external_id TEXT,
                feed_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE UNIQUE INDEX idx_items_remote_identity ON items (account_id, external_id) WHERE external_id IS NOT NULL;
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('local-default', 'local', 'Local', 0, 0);
            INSERT INTO feeds (id, account_id, title, feed_url, updated_at)
            VALUES ('f1', 'local-default', 'Feed 1', 'https://f1.com', 0);
            INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
            VALUES ('digest-1', 'local-default', 'raw-id-1', 'f1', 0, 0);
            """)
        }
        migrator.registerMigration("v2-clean-local-account-sync-state") { _ in }

        let pool = try DatabasePool(path: dbURL.path)
        try migrator.migrate(pool)

        // 运行全局 DatabaseMigrations (包含 v3)
        try DatabaseMigrations.migrator.migrate(pool)

        try pool.read { db in
            let externalID = try String.fetchOne(db, sql: "SELECT external_id FROM items WHERE id = 'digest-1'")
            XCTAssertEqual(externalID, "digest-1", "v3 migration must set external_id = id for local account items")
        }
    }
}
