import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

// MARK: - Concurrency Test State Box

final class TestStateBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }

    func mutate(_ transform: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&_value)
    }
}

// MARK: - Mock FreshRSS URLProtocol

final class MockFreshRSSURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        defer { lock.unlock() }
        requestHandler = handler
    }

    static func requestBody(from request: URLRequest) -> Data {
        if let data = request.httpBody {
            return data
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var result = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    result.append(buffer, count: count)
                } else {
                    break
                }
            }
            return result
        }
        return Data()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host.contains("freshrss") || host.contains("example.com") || host.contains("greader")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        MockFreshRSSURLProtocol.lock.lock()
        let handler = MockFreshRSSURLProtocol.requestHandler
        MockFreshRSSURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - FreshRSS Integration Tests

final class FreshRSSIntegrationTests: XCTestCase {
    var tempDir: URL!
    var sqliteURL: URL!
    var database: LibraryDatabase!
    var mockSession: URLSession!
    var inMemoryCredentialStore: InMemoryCredentialStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssFreshRSSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sqliteURL = tempDir.appendingPathComponent("library.sqlite")
        database = try LibraryDatabase(databaseURL: sqliteURL)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockFreshRSSURLProtocol.self]
        mockSession = URLSession(configuration: config)

        inMemoryCredentialStore = InMemoryCredentialStore()
    }

    override func tearDownWithError() throws {
        MockFreshRSSURLProtocol.setHandler(nil)
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Authentication & Endpoint Canonicalization

    func testEndpointCanonicalization() {
        let u1 = URL(string: "https://rss.example.com")!
        XCTAssertEqual(ReaderAPIClient.canonicalBaseURL(for: u1).absoluteString, "https://rss.example.com/api/greader.php")

        let u2 = URL(string: "https://rss.example.com/")!
        XCTAssertEqual(ReaderAPIClient.canonicalBaseURL(for: u2).absoluteString, "https://rss.example.com/api/greader.php")

        let u3 = URL(string: "https://rss.example.com/api/greader.php")!
        XCTAssertEqual(ReaderAPIClient.canonicalBaseURL(for: u3).absoluteString, "https://rss.example.com/api/greader.php")

        let u4 = URL(string: "https://rss.example.com/freshrss/")!
        XCTAssertEqual(ReaderAPIClient.canonicalBaseURL(for: u4).absoluteString, "https://rss.example.com/freshrss/api/greader.php")
    }

    func testClientLoginSuccessAndWriteToken() async throws {
        let endpoint = URL(string: "https://freshrss.example.com")!
        let accountID = "freshrss-test-1"
        try inMemoryCredentialStore.saveFreshRSSPassword("secret_api_pwd", accountID: accountID)

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let body = String(data: MockFreshRSSURLProtocol.requestBody(from: request), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("Email=alice"))
                XCTAssertTrue(body.contains("Passwd=secret_api_pwd"))
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "Auth=mock_auth_token_123\nSID=mock_sid\n".data(using: .utf8)!
                return (resp, data)
            } else if path.contains("reader/api/0/token") {
                let authHeader = request.value(forHTTPHeaderField: "Authorization")
                XCTAssertEqual(authHeader, "GoogleLogin auth=mock_auth_token_123")
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "mock_write_token_xyz".data(using: .utf8)!
                return (resp, data)
            }
            throw URLError(.badURL)
        }

        let client = ReaderAPIClient(
            endpointURL: endpoint,
            username: "alice",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        try await client.validateCredentials()
    }

    func testClientLoginInvalidCredentialsThrows() async throws {
        let endpoint = URL(string: "https://freshrss.example.com")!
        let accountID = "freshrss-test-2"
        try inMemoryCredentialStore.saveFreshRSSPassword("wrong_pwd", accountID: accountID)

        MockFreshRSSURLProtocol.setHandler { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            let data = "Error=BadAuthentication".data(using: .utf8)!
            return (resp, data)
        }

        let client = ReaderAPIClient(
            endpointURL: endpoint,
            username: "alice",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        do {
            try await client.validateCredentials()
            XCTFail("Should throw invalidCredentials")
        } catch let error as ReaderAPIError {
            if case .invalidCredentials = error {
                // Passed
            } else {
                XCTFail("Expected invalidCredentials, got \(error)")
            }
        }
    }

    func testExpiredAuthTokenRetriesOnceAndSucceeds() async throws {
        let endpoint = URL(string: "https://freshrss.example.com")!
        let accountID = "freshrss-test-3"
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let loginCountBox = TestStateBox(0)
        let requestCountBox = TestStateBox(0)

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                loginCountBox.mutate { $0 += 1 }
                let currentCount = loginCountBox.value
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = "Auth=token_\(currentCount)".data(using: .utf8)!
                return (resp, data)
            } else if path.contains("subscription/list") {
                requestCountBox.mutate { $0 += 1 }
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth == "GoogleLogin auth=token_1" {
                    // 第一次使用旧 token 返回 401
                    let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    return (resp, Data())
                } else if auth == "GoogleLogin auth=token_2" {
                    // 重新认证后成功返回
                    let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    let json = """
                    {"subscriptions":[{"id":"feed/10","title":"Go Blog","categories":[],"url":"https://go.dev/rss"}]}
                    """
                    return (resp, json.data(using: .utf8)!)
                }
            }
            throw URLError(.badURL)
        }

        let client = ReaderAPIClient(
            endpointURL: endpoint,
            username: "alice",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        let subs = try await client.fetchSubscriptions()
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].title, "Go Blog")
        XCTAssertEqual(loginCountBox.value, 2, "Should re-login once")
        XCTAssertEqual(requestCountBox.value, 2, "Should retry request once")
    }

    // MARK: - 2. Subscriptions & Folders Pull & Idempotency

    func testSubscriptionAndFolderPullAndSoftDeletion() async throws {
        let accountID = "freshrss-sub-test"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        // 插入账号记录
        try database.write { db in
            let acc = AccountRecord(
                id: accountID,
                type: AccountType.freshRSS.rawValue,
                displayName: "My FreshRSS",
                endpointURL: endpoint.absoluteString,
                username: "alice",
                isEnabled: true,
                createdAt: 0,
                updatedAt: 0
            )
            try acc.save(db)
        }

        let subsJSONBox = TestStateBox("""
        {
            "subscriptions": [
                {
                    "id": "feed/100",
                    "title": "Swift News",
                    "url": "https://swift.org/rss",
                    "htmlUrl": "https://swift.org",
                    "categories": [{"id": "user/-/label/Tech", "label": "Tech"}]
                },
                {
                    "id": "feed/200",
                    "title": "Rust Blog",
                    "url": "https://rust-lang.org/rss",
                    "htmlUrl": "https://rust-lang.org",
                    "categories": []
                }
            ]
        }
        """)

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, subsJSONBox.value.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let tagsJSON = """
                {"tags":[{"id":"user/-/label/Tech"}]}
                """
                return (resp, tagsJSON.data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "alice",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        // 1. 首次拉取订阅与分类
        try await provider.syncSubscriptionsAndFolders()

        try database.read { db in
            let feeds = try FeedRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false).fetchAll(db)
            XCTAssertEqual(feeds.count, 2)
            let swiftFeed = feeds.first { $0.externalID == "feed/100" }
            XCTAssertNotNil(swiftFeed)
            XCTAssertEqual(swiftFeed?.title, "Swift News")

            let folders = try FolderRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false).fetchAll(db)
            XCTAssertEqual(folders.count, 1)
            XCTAssertEqual(folders[0].name, "Tech")
        }

        // 2. 幂等二次拉取（数据无变化，不产生重复条目）
        try await provider.syncSubscriptionsAndFolders()
        try database.read { db in
            let feeds = try FeedRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false).fetchAll(db)
            XCTAssertEqual(feeds.count, 2)
        }

        // 3. 远端删除了 feed/200（Rust Blog）
        subsJSONBox.value = """
        {
            "subscriptions": [
                {
                    "id": "feed/100",
                    "title": "Swift News",
                    "url": "https://swift.org/rss",
                    "htmlUrl": "https://swift.org",
                    "categories": [{"id": "user/-/label/Tech", "label": "Tech"}]
                }
            ]
        }
        """

        try await provider.syncSubscriptionsAndFolders()
        try database.read { db in
            let activeFeeds = try FeedRecord.filter(Column("account_id") == accountID && Column("is_deleted") == false).fetchAll(db)
            XCTAssertEqual(activeFeeds.count, 1)
            XCTAssertEqual(activeFeeds[0].externalID, "feed/100")

            let deletedFeeds = try FeedRecord.filter(Column("account_id") == accountID && Column("is_deleted") == true).fetchAll(db)
            XCTAssertEqual(deletedFeeds.count, 1)
            XCTAssertEqual(deletedFeeds[0].externalID, "feed/200", "Deleted remote feed must be soft-deleted in local SQLite")
        }
    }

    // MARK: - 3. Item / Article Incremental Pull & Opaque Remote IDs

    func testItemAndArticlePullWithOpaqueRemoteIDs() async throws {
        let accountID = "freshrss-items-test"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        try database.write { db in
            let acc = AccountRecord(
                id: accountID,
                type: AccountType.freshRSS.rawValue,
                displayName: "FreshRSS",
                endpointURL: endpoint.absoluteString,
                username: "bob",
                isEnabled: true,
                createdAt: 0,
                updatedAt: 0
            )
            try acc.save(db)
            let feed = FeedRecord(
                id: "feed-uuid-1",
                accountID: accountID,
                externalID: "feed/555",
                title: "Opaque Feed",
                feedURL: "https://opaque.com/rss",
                updatedAt: 0
            )
            try feed.save(db)
        }

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let query = request.url?.query ?? ""
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if query.contains("starred") {
                    return (resp, "{\"itemRefs\":[]}".data(using: .utf8)!)
                } else {
                    // item_alpha_opaque_001 未读
                    let json = """
                    {"itemRefs":[{"id":"tag:google.com,2005:reader/item/0000000000000001"}]}
                    """
                    return (resp, json.data(using: .utf8)!)
                }
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "items": [
                        {
                            "id": "tag:google.com,2005:reader/item/0000000000000001",
                            "title": "Article One",
                            "author": "Alice",
                            "published": 1700000000,
                            "origin": {"streamId": "feed/555"},
                            "content": {"content": "<p>Content of article one</p>"},
                            "categories": ["user/-/state/com.google/reading-list"]
                        }
                    ]
                }
                """
                return (resp, json.data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "bob",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        try await provider.syncArticlesAndStates()

        try database.read { db in
            let items = try ItemRecord.filter(Column("account_id") == accountID).fetchAll(db)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0].externalID, "0000000000000001")
            XCTAssertEqual(items[0].feedID, "feed-uuid-1")

            let article = try ArticleRecord.filter(Column("item_id") == items[0].id).fetchOne(db)
            XCTAssertNotNil(article)
            XCTAssertEqual(article?.title, "Article One")
            XCTAssertEqual(article?.author, "Alice")
            XCTAssertEqual(article?.contentHTML, "<p>Content of article one</p>")

            let state = try ArticleStateRecord.filter(Column("item_id") == items[0].id).fetchOne(db)
            XCTAssertNotNil(state)
            XCTAssertFalse(state!.isRead, "Article One should be unread")
            XCTAssertFalse(state!.isStarred)
        }
    }

    // MARK: - 4. State Reconciliation (Pending Local Mutation Wins for That Field Only)

    func testPendingLocalMutationWinsForThatFieldOnly() async throws {
        let accountID = "freshrss-reconcile-test"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let itemID = "item-rec-1"
        let remoteID = "remote-rec-001"

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Acc", endpointURL: endpoint.absoluteString, username: "u", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-1", accountID: accountID, externalID: "feed/1", title: "F", feedURL: "https://f.com", updatedAt: 0)
            try feed.save(db)
            let item = ItemRecord(id: itemID, accountID: accountID, externalID: remoteID, feedID: "feed-1", createdAt: 0, updatedAt: 0)
            try item.save(db)
            let article = ArticleRecord(itemID: itemID, title: "Title", publishedAt: 0, summary: "Sum", contentHTML: nil, contentUpdatedAt: 0)
            try article.save(db)

            // 本地状态：已被用户标为已读 (is_read = true)，但未加星标 (is_starred = false)
            let localState = ArticleStateRecord(itemID: itemID, isRead: true, isStarred: false, dateArrived: 0, updatedAt: 0)
            try localState.save(db)

            // 存在 Pending Outbox 突变：read = true
            let outbox = ArticleStateOutboxRecord(accountID: accountID, itemID: itemID, stateKey: "read", desiredValue: true, revision: 1, updatedAt: 0)
            try outbox.save(db)
        }

        // 远端返回：未读列表包含 remoteID (remote read = false)，且星标列表包含 remoteID (remote starred = true)
        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if query.contains("reading-list") && query.contains("xt=user") {
                    // 远端认为该文章是未读
                    let json = "{\"itemRefs\":[{\"id\":\"\(remoteID)\"}]}"
                    return (resp, json.data(using: .utf8)!)
                } else if query.contains("starred") {
                    // 远端认为该文章已加星标
                    let json = "{\"itemRefs\":[{\"id\":\"\(remoteID)\"}]}"
                    return (resp, json.data(using: .utf8)!)
                }
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"items\":[]}".data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "u",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        try await provider.syncArticlesAndStates()

        try database.read { db in
            let state = try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db)
            XCTAssertNotNil(state)

            // 1. Pending Local Read (true) 战胜了 Remote Unread (false) -> 保持 true
            XCTAssertTrue(state!.isRead, "Pending local read mutation MUST beat remote unread state")

            // 2. Starred 没有 pending local mutation，正常接受 Remote Starred (true) -> 变为 true
            XCTAssertTrue(state!.isStarred, "Remote starred state MUST apply since there is no pending starred mutation")
        }
    }

    // MARK: - 5. Durable Outbox & In-flight Mutation Race

    func testOutboxProcessWithInflightRaceProtection() async throws {
        let accountID = "freshrss-outbox-test"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let itemID = "item-race-1"
        let remoteID = "remote-race-001"

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Acc", endpointURL: endpoint.absoluteString, username: "u", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-1", accountID: accountID, externalID: "feed/1", title: "F", feedURL: "https://f.com", updatedAt: 0)
            try feed.save(db)
            let item = ItemRecord(id: itemID, accountID: accountID, externalID: remoteID, feedID: "feed-1", createdAt: 0, updatedAt: 0)
            try item.save(db)
            let state = ArticleStateRecord(itemID: itemID, isRead: true, isStarred: false, dateArrived: 0, updatedAt: 0)
            try state.save(db)

            // 初始 Outbox: revision = 1 (read = true)
            let outbox = ArticleStateOutboxRecord(accountID: accountID, itemID: itemID, stateKey: "read", desiredValue: true, revision: 1, updatedAt: 0)
            try outbox.save(db)
        }

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("reader/api/0/token") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "write_token_123".data(using: .utf8)!)
            } else if path.contains("reader/api/0/edit-tag") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "OK".data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        let apiClient = ReaderAPIClient(
            endpointURL: endpoint,
            username: "u",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )
        let processor = ArticleStateOutboxProcessor(
            accountID: accountID,
            database: database,
            apiClient: apiClient
        )

        // 1. 模拟在 outbox 处理之前发生本地新修改：用户又标为未读 (revision 变为 2)
        try database.write { db in
            var row = try ArticleStateOutboxRecord.filter(Column("item_id") == itemID && Column("state_key") == "read").fetchOne(db)!
            row.revision = 2
            row.desiredValue = false
            try row.save(db)
        }

        // 2. 模拟如果旧任务携带 revision = 1 执行删除
        let stateRepo = ArticleStateRepository(database: database)
        let deletedOld = try await stateRepo.deleteOutbox(accountID: accountID, itemID: itemID, stateKey: "read", revision: 1)
        XCTAssertFalse(deletedOld, "Deleting with stale revision 1 must NOT delete updated row with revision 2")

        // 3. 验证 revision = 2 的记录仍然完好存在
        try database.read { db in
            let row = try ArticleStateOutboxRecord.filter(Column("item_id") == itemID && Column("state_key") == "read").fetchOne(db)
            XCTAssertNotNil(row)
            XCTAssertEqual(row?.revision, 2)
            XCTAssertFalse(row!.desiredValue)
        }

        // 4. 执行真实 processor.processOutbox() 推送最新的 revision 2
        let result = try await processor.processOutbox()
        XCTAssertEqual(result.successCount, 1)

        // 5. 验证成功后 outbox 已被完全清空
        try database.read { db in
            let count = try ArticleStateOutboxRecord.filter(Column("account_id") == accountID).fetchCount(db)
            XCTAssertEqual(count, 0, "Outbox row must be deleted after successful remote confirmation")
        }
    }

    // MARK: - 6. Multi-Account Isolation (Local + FreshRSS A + FreshRSS B)

    @MainActor
    func testMultiAccountIsolation() async throws {
        let endpointA = URL(string: "https://a.freshrss.com")!
        let endpointB = URL(string: "https://b.freshrss.com")!

        let store = AppStore(
            testDatabase: AppDatabase.empty,
            feedFetcher: { _ in .notModified(etag: nil, lastModified: nil) },
            credentialStore: inMemoryCredentialStore
        )

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let host = request.url?.host ?? ""
                if host.contains("a.freshrss") {
                    let json = "{\"subscriptions\":[{\"id\":\"feed/10\",\"title\":\"Feed in A\",\"url\":\"https://a.com/rss\",\"categories\":[]}]}"
                    return (resp, json.data(using: .utf8)!)
                } else {
                    let json = "{\"subscriptions\":[{\"id\":\"feed/10\",\"title\":\"Feed in B\",\"url\":\"https://b.com/rss\",\"categories\":[]}]}"
                    return (resp, json.data(using: .utf8)!)
                }
            } else if path.contains("tag/list") || path.contains("stream/items/ids") || path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"subscriptions\":[],\"tags\":[],\"itemRefs\":[],\"items\":[]}".data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        // 添加本地源
        await store.addFeed(urlText: "https://local.com/rss")
        XCTAssertEqual(store.feeds.count, 1)

        // 添加 FreshRSS 账号 A
        let accA = try await store.addFreshRSSAccount(
            endpointURLText: endpointA.absoluteString,
            username: "userA",
            password: "pwdA",
            displayName: "FreshRSS A",
            customSession: mockSession
        )

        // 添加 FreshRSS 账号 B (两账号拥有相同的 remote feed ID "feed/10")
        let accB = try await store.addFreshRSSAccount(
            endpointURLText: endpointB.absoluteString,
            username: "userB",
            password: "pwdB",
            displayName: "FreshRSS B",
            customSession: mockSession
        )

        // 验证多账号并存
        XCTAssertEqual(store.accounts.count, 3) // local + accA + accB

        // 删除 FreshRSS 账号 A
        try await store.removeAccount(accountID: accA.id)

        // 验证账号 A 已删除，但本地账号与账号 B 完好保留
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertTrue(store.accounts.contains(where: { $0.id == "local-default" }))
        XCTAssertTrue(store.accounts.contains(where: { $0.id == accB.id }))
        XCTAssertFalse(store.accounts.contains(where: { $0.id == accA.id }))
    }

    // MARK: - 7. Full E2E Offline & Online Reconciliation Lifecycle

    @MainActor
    func testE2EOfflineAndOnlineLifecycle() async throws {
        let endpoint = URL(string: "https://freshrss.example.com")!
        let persistenceFile = tempDir.appendingPathComponent("library.json")
        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: persistenceFile,
            credentialStore: inMemoryCredentialStore
        )

        let remoteTagEditsBox = TestStateBox<[(items: [String], addTag: String?, removeTag: String?)]>([])
        let isNetworkOnlineBox = TestStateBox(true)

        MockFreshRSSURLProtocol.setHandler { request in
            guard isNetworkOnlineBox.value else {
                throw URLError(.notConnectedToInternet)
            }

            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("reader/api/0/token") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "mock_token".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/99\",\"title\":\"E2E Feed\",\"url\":\"https://e2e.com/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let query = request.url?.query ?? ""
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if query.contains("starred") {
                    return (resp, "{\"itemRefs\":[]}".data(using: .utf8)!)
                } else {
                    return (resp, "{\"itemRefs\":[{\"id\":\"e2e_item_1\"}]}".data(using: .utf8)!)
                }
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "items": [
                        {
                            "id": "e2e_item_1",
                            "title": "E2E Article",
                            "published": 1700000000,
                            "origin": {"streamId": "feed/99"},
                            "content": {"content": "<p>E2E Content</p>"},
                            "categories": ["user/-/state/com.google/reading-list"]
                        }
                    ]
                }
                """
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("edit-tag") {
                let body = String(data: MockFreshRSSURLProtocol.requestBody(from: request), encoding: .utf8) ?? ""
                var addTag: String?
                var removeTag: String?
                var itemIDs: [String] = []
                for item in body.split(separator: "&") {
                    let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2 {
                        let k = pair[0]
                        let v = pair[1].removingPercentEncoding ?? pair[1]
                        if k == "i" { itemIDs.append(v) }
                        if k == "a" { addTag = v }
                        if k == "r" { removeTag = v }
                    }
                }
                remoteTagEditsBox.mutate { $0.append((itemIDs, addTag, removeTag)) }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "OK".data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        // 1. 添加 FreshRSS 账号并执行首次同步
        let acc = try await store.addFreshRSSAccount(
            endpointURLText: endpoint.absoluteString,
            username: "e2e_user",
            password: "e2e_password",
            displayName: "E2E FreshRSS",
            customSession: mockSession
        )

        let provider = FreshRSSAccountProvider(
            accountID: acc.id,
            endpointURL: endpoint,
            username: "e2e_user",
            database: store.libraryDatabase,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )
        _ = try await provider.refresh(reason: .manual)
        store.reloadState()

        // 验证文章已入库可见，初始未读
        let items = store.fetchTimelinePage(scope: .all, limit: 10, offset: 0)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "E2E Article")
        XCTAssertFalse(items[0].isRead)

        // 2. 模拟网络断开 (Offline)
        isNetworkOnlineBox.value = false

        // 3. 用户在离线状态下标记已读并标星标
        store.markRead(entryID: items[0].id, read: true)
        store.toggleStar(entryID: items[0].id)

        // 验证本地状态立即更新，且写入了持久化 Outbox
        let localState = try store.libraryDatabase.read { db in
            try ArticleStateRecord.filter(Column("item_id") == items[0].id).fetchOne(db)
        }
        XCTAssertTrue(localState!.isRead)
        XCTAssertTrue(localState!.isStarred)

        let outboxCount = try store.libraryDatabase.read { db in
            try ArticleStateOutboxRecord.filter(Column("account_id") == acc.id).fetchCount(db)
        }
        XCTAssertEqual(outboxCount, 2, "Both read and starred mutations must be durably stored in outbox")

        // 4. 模拟应用重启（新建 AppStore 实例并挂载同数据库）
        let restartedStore = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: persistenceFile,
            credentialStore: inMemoryCredentialStore
        )
        let restartedItems = restartedStore.fetchTimelinePage(scope: .all, limit: 10, offset: 0)
        XCTAssertEqual(restartedItems.count, 1)
        XCTAssertTrue(restartedItems[0].isRead, "Read mutation preserved after restart")
        XCTAssertTrue(restartedItems[0].isStarred, "Starred mutation preserved after restart")

        // 5. 模拟网络恢复 (Online)
        isNetworkOnlineBox.value = true

        // 6. 执行同步推动 Outbox
        let restartedProvider = FreshRSSAccountProvider(
            accountID: acc.id,
            endpointURL: endpoint,
            username: "e2e_user",
            database: restartedStore.libraryDatabase,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )
        _ = try await restartedProvider.refresh(reason: .manual)

        // 7. 验证远端成功收到两次 edit-tag 请求（read 和 starred）
        let edits = remoteTagEditsBox.value
        XCTAssertTrue(edits.contains(where: { $0.items.contains("e2e_item_1") && $0.addTag?.contains("read") == true }))
        XCTAssertTrue(edits.contains(where: { $0.items.contains("e2e_item_1") && $0.addTag?.contains("starred") == true }))

        // 8. 验证本地 Outbox 彻底清空，达成双向一致
        let finalOutboxCount = try restartedStore.libraryDatabase.read { db in
            try ArticleStateOutboxRecord.filter(Column("account_id") == acc.id).fetchCount(db)
        }
        XCTAssertEqual(finalOutboxCount, 0, "Outbox must be drained completely after reconnect")
    }
}
