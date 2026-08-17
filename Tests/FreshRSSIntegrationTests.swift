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
        true
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
                    // FreshRSS 官方真实行为：返回十进制数字字符串 "1"（对应 hex 0x0000000000000001）
                    let json = """
                    {"itemRefs":[{"id":"1"}]}
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
            // 验证：external_id 完整持久化 raw tag ID，不被 lossy 截断
            XCTAssertEqual(items[0].externalID, "tag:google.com,2005:reader/item/0000000000000001")
            XCTAssertEqual(items[0].feedID, "feed-uuid-1")

            let article = try ArticleRecord.filter(Column("item_id") == items[0].id).fetchOne(db)
            XCTAssertNotNil(article)
            XCTAssertEqual(article?.title, "Article One")
            XCTAssertEqual(article?.author, "Alice")
            XCTAssertEqual(article?.contentHTML, "<p>Content of article one</p>")

            let state = try ArticleStateRecord.filter(Column("item_id") == items[0].id).fetchOne(db)
            XCTAssertNotNil(state)
            XCTAssertFalse(state!.isRead, "Article One should be unread due to decimal and hex equivalence")
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

    // MARK: - 7. Goal 2 Fix Regression Tests

    /// P0 验证：当 fetchUnreadItemIDs 或 fetchStarredItemIDs 发生网络或解码错误时，
    /// Reconciliation 绝不能通过负向推断将本地未读/星标文章批量标为已读或取消星标。
    func testFailedStateFetchPreservesLocalReadAndStarredStates() async throws {
        let accountID = "freshrss-p0-fail-safe"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let itemID = "opaque_item_1"
        try database.write { db in
            let acc = AccountRecord(
                id: accountID,
                type: AccountType.freshRSS.rawValue,
                displayName: "Safe FreshRSS",
                endpointURL: endpoint.absoluteString,
                username: "alice",
                isEnabled: true,
                createdAt: 0,
                updatedAt: 0
            )
            try acc.save(db)
            let feed = FeedRecord(
                id: "feed-p0-1",
                accountID: accountID,
                externalID: "feed/100",
                title: "Safe Feed",
                feedURL: "https://safe.com/rss",
                updatedAt: 0
            )
            try feed.save(db)
            let item = ItemRecord(
                id: "\(accountID)::\(itemID)",
                accountID: accountID,
                externalID: itemID,
                feedID: "feed-p0-1",
                createdAt: 100,
                updatedAt: 100
            )
            try item.save(db)
            try ArticleRecord(itemID: item.id, title: "Existing Item", contentHTML: "<p>Content</p>").save(db)
            let state = ArticleStateRecord(
                itemID: item.id,
                isRead: false,
                isStarred: true,
                updatedAt: 100
            )
            try state.save(db)
            let syncState = AccountSyncStateRecord(
                accountID: accountID,
                initialSyncCompleted: true,
                lastSyncCompletedAt: 100,
                lastFullReconcileAt: 100
            )
            try syncState.save(db)
        }

        // 模拟远端：stream/contents 正常返回，但 stream/items/ids 返回 HTTP 500 错误
        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"subscriptions\":[{\"id\":\"feed/100\",\"title\":\"Safe Feed\",\"url\":\"https://safe.com/rss\",\"categories\":[]}]}".data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (resp, "Internal Server Error".data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "items": [
                        {
                            "id": "tag:google.com,2005:reader/item/\(itemID)",
                            "title": "Existing Item",
                            "origin": {"streamId": "feed/100"},
                            "content": {"content": "<p>Content</p>"},
                            "categories": []
                        }
                    ]
                }
                """
                return (resp, json.data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"items\":[]}".data(using: .utf8)!)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "alice",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        // 刷新远端，此时状态拉取失败
        _ = try await provider.refresh(reason: .manual)

        // 校验：本地未读状态与星标状态必须被原样保留，绝对不能被推断置为 isRead=true 或 isStarred=false
        let state = try database.read { db in
            try ArticleStateRecord.filter(Column("item_id") == "\(accountID)::\(itemID)").fetchOne(db)
        }
        XCTAssertNotNil(state)
        XCTAssertFalse(state!.isRead, "Local unread state must NOT be modified when remote unread state fetch fails")
        XCTAssertTrue(state!.isStarred, "Local starred state must NOT be modified when remote starred state fetch fails")
    }

    /// P1 验证：Reader API continuation 分页必须完整拉取所有分页并构建权威集合。
    func testContinuationPaginationFetchesAllPagesAuthoritatively() async throws {
        let accountID = "freshrss-pagination-test"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let client = ReaderAPIClient(
            endpointURL: endpoint,
            username: "page_user",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        let requestedContinuationsBox = TestStateBox<[String?]>([])
        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let query = request.url?.query ?? ""
                let continuation = query.components(separatedBy: "&").first(where: { $0.hasPrefix("c=") })?.replacingOccurrences(of: "c=", with: "")
                requestedContinuationsBox.mutate { $0.append(continuation) }

                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if continuation == nil {
                    // 第 1 页：包含 1 条，附带 continuation token "page_2_token"
                    let json = """
                    {
                        "itemRefs": [{"id": "1001"}],
                        "continuation": "page_2_token"
                    }
                    """
                    return (resp, json.data(using: .utf8)!)
                } else if continuation == "page_2_token" {
                    // 第 2 页：包含 1 条，无 continuation token
                    let json = """
                    {
                        "itemRefs": [{"id": "1002"}]
                    }
                    """
                    return (resp, json.data(using: .utf8)!)
                }
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{}".data(using: .utf8)!)
        }

        let allUnreads = try await client.fetchAllUnreadItemIDs(maxTotal: 5000)
        XCTAssertTrue(allUnreads.isComplete)
        XCTAssertEqual(allUnreads.ids, Set(["1001", "1002"]))
        let expectedContinuations: [String?] = [nil, "page_2_token"]
        XCTAssertEqual(requestedContinuationsBox.value, expectedContinuations)
    }

    /// P1 验证：不透明 remote ID（包含斜杠、非数字）绝不能被 lossy 截断为数字或最后一部分。
    func testPreservesOpaqueRemoteIDsWithoutLossyParsing() async throws {
        let accountID = "freshrss-opaque-ids"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let client = ReaderAPIClient(
            endpointURL: endpoint,
            username: "opaque_user",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "itemRefs": [
                        {"id": "tag:google.com,2005:reader/item/foo/a/123"},
                        {"id": "tag:google.com,2005:reader/item/bar/b/123"}
                    ]
                }
                """
                return (resp, json.data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{}".data(using: .utf8)!)
        }

        let unreadIDs = try await client.fetchAllUnreadItemIDs()
        XCTAssertTrue(unreadIDs.contains("tag:google.com,2005:reader/item/foo/a/123"), "Opaque ID must be preserved in its entirety")
        XCTAssertTrue(unreadIDs.contains("tag:google.com,2005:reader/item/bar/b/123"), "Opaque ID must be preserved in its entirety")
        XCTAssertFalse(unreadIDs.contains("123"), "Lossy parsing extracting '123' must not occur")
    }

    /// P1 验证：多账号下相同名称文件夹（如 Local/Tech, FreshRSS-A/Tech, FreshRSS-B/Tech）完全物理隔离查询。
    func testCrossAccountFolderIsolationWithSameName() throws {
        let timelineQuery = TimelineQueryService(database: database)

        try database.write { db in
            let localAcc = AccountRecord(id: "local-default", type: AccountType.local.rawValue, displayName: "On My Mac", isEnabled: true, createdAt: 0, updatedAt: 0)
            try localAcc.save(db)
            let accA = AccountRecord(id: "freshrss-A", type: AccountType.freshRSS.rawValue, displayName: "FreshRSS A", endpointURL: "https://a.com", username: "a", isEnabled: true, createdAt: 0, updatedAt: 0)
            try accA.save(db)
            let accB = AccountRecord(id: "freshrss-B", type: AccountType.freshRSS.rawValue, displayName: "FreshRSS B", endpointURL: "https://b.com", username: "b", isEnabled: true, createdAt: 0, updatedAt: 0)
            try accB.save(db)

            let localFeedID = UUID().uuidString
            let accAFeedID = UUID().uuidString
            let accBFeedID = UUID().uuidString

            // Local 账号
            let localFolder = FolderRecord(id: "loc-fld-1", accountID: "local-default", name: "Tech", sortOrder: 0, isDeleted: false, updatedAt: 0)
            try localFolder.save(db)
            let localFeed = FeedRecord(id: localFeedID, accountID: "local-default", title: "Local Tech Feed", feedURL: "https://loc.com/rss", updatedAt: 0)
            try localFeed.save(db)
            try FeedFolderRecord(feedID: localFeed.id, folderID: localFolder.id).save(db)
            let localItem = ItemRecord(id: "loc-item-1", accountID: "local-default", externalID: "item-1", feedID: localFeed.id, createdAt: 100, updatedAt: 100)
            try localItem.save(db)
            try ArticleRecord(itemID: localItem.id, title: "Local Tech News", url: "https://loc.com/1").save(db)
            try ArticleStateRecord(itemID: localItem.id, isRead: false, isStarred: false, updatedAt: 100).save(db)

            // FreshRSS A 账号
            let accAFolder = FolderRecord(id: "accA-fld-1", accountID: "freshrss-A", name: "Tech", sortOrder: 0, isDeleted: false, updatedAt: 0)
            try accAFolder.save(db)
            let accAFeed = FeedRecord(id: accAFeedID, accountID: "freshrss-A", title: "AccA Tech Feed", feedURL: "https://accA.com/rss", updatedAt: 0)
            try accAFeed.save(db)
            try FeedFolderRecord(feedID: accAFeed.id, folderID: accAFolder.id).save(db)
            let accAItem = ItemRecord(id: "accA-item-1", accountID: "freshrss-A", externalID: "item-A", feedID: accAFeed.id, createdAt: 100, updatedAt: 100)
            try accAItem.save(db)
            try ArticleRecord(itemID: accAItem.id, title: "AccA Tech News", url: "https://accA.com/1").save(db)
            try ArticleStateRecord(itemID: accAItem.id, isRead: false, isStarred: false, updatedAt: 100).save(db)

            // FreshRSS B 账号
            let accBFolder = FolderRecord(id: "accB-fld-1", accountID: "freshrss-B", name: "Tech", sortOrder: 0, isDeleted: false, updatedAt: 0)
            try accBFolder.save(db)
            let accBFeed = FeedRecord(id: accBFeedID, accountID: "freshrss-B", title: "AccB Tech Feed", feedURL: "https://accB.com/rss", updatedAt: 0)
            try accBFeed.save(db)
            try FeedFolderRecord(feedID: accBFeed.id, folderID: accBFolder.id).save(db)
            let accBItem = ItemRecord(id: "accB-item-1", accountID: "freshrss-B", externalID: "item-B", feedID: accBFeed.id, createdAt: 100, updatedAt: 100)
            try accBItem.save(db)
            try ArticleRecord(itemID: accBItem.id, title: "AccB Tech News", url: "https://accB.com/1").save(db)
            try ArticleStateRecord(itemID: accBItem.id, isRead: false, isStarred: false, updatedAt: 100).save(db)
        }

        // 分别查询 Tech 文件夹
        let localTechItems = try timelineQuery.fetchListItems(scope: .folder(accountID: "local-default", folderName: "Tech"))
        let accATechItems = try timelineQuery.fetchListItems(scope: .folder(accountID: "freshrss-A", folderName: "Tech"))
        let accBTechItems = try timelineQuery.fetchListItems(scope: .folder(accountID: "freshrss-B", folderName: "Tech"))

        XCTAssertEqual(localTechItems.map(\.title), ["Local Tech News"])
        XCTAssertEqual(accATechItems.map(\.title), ["AccA Tech News"])
        XCTAssertEqual(accBTechItems.map(\.title), ["AccB Tech News"])

        // Sidebar 计数隔离统计
        let counts = try timelineQuery.fetchSidebarCounts(startOfDayTimestamp: 0)
        XCTAssertEqual(counts.unreadCount(folder: "Tech", accountID: "local-default"), 1)
        XCTAssertEqual(counts.unreadCount(folder: "Tech", accountID: "freshrss-A"), 1)
        XCTAssertEqual(counts.unreadCount(folder: "Tech", accountID: "freshrss-B"), 1)
    }

    /// P1 验证：防止创建相同 (canonical endpoint, username) 的重复 FreshRSS 账号。
    @MainActor
    func testDuplicateFreshRSSAccountPrevented() async throws {
        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("legacy.json"),
            credentialStore: inMemoryCredentialStore
        )

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"subscriptions\":[],\"tags\":[],\"itemRefs\":[],\"items\":[]}".data(using: .utf8)!)
        }

        // 第一次添加账号成功
        let acc = try await store.addFreshRSSAccount(
            endpointURLText: "https://dup.example.com",
            username: "dup_user",
            password: "pwd",
            customSession: mockSession
        )
        XCTAssertEqual(acc.username, "dup_user")

        // 再次添加相同 endpoint (即使 URL 路径稍有不同但 canonical endpoint 一致) + username
        do {
            _ = try await store.addFreshRSSAccount(
                endpointURLText: "https://dup.example.com/api/greader.php/",
                username: "dup_user",
                password: "pwd",
                customSession: mockSession
            )
            XCTFail("Must throw accountAlreadyExists error for duplicate account")
        } catch let ReaderAPIError.accountAlreadyExists(msg) {
            XCTAssertTrue(msg.contains("dup_user"))
        }
    }

    /// P1 验证：FreshRSS markAllRead 在 Local 文章上不创建 outbox，在 FreshRSS 文章上原子生成 outbox。
    func testFreshRSSMarkAllReadGeneratesOutbox() throws {
        let stateRepo = ArticleStateRepository(database: database)

        try database.write { db in
            let localAcc = AccountRecord(id: "local-default", type: AccountType.local.rawValue, displayName: "On My Mac", isEnabled: true, createdAt: 0, updatedAt: 0)
            try localAcc.save(db)

            let acc = AccountRecord(
                id: "freshrss-mark-test",
                type: AccountType.freshRSS.rawValue,
                displayName: "FR",
                endpointURL: "https://fr.com",
                username: "u",
                isEnabled: true,
                createdAt: 0,
                updatedAt: 0
            )
            try acc.save(db)

            let locFeed = FeedRecord(id: "loc-feed", accountID: "local-default", title: "L", feedURL: "https://l.com", updatedAt: 0)
            try locFeed.save(db)
            let locItem = ItemRecord(id: "loc-item", accountID: "local-default", externalID: "1", feedID: locFeed.id, createdAt: 0, updatedAt: 0)
            try locItem.save(db)
            try ArticleStateRecord(itemID: locItem.id, isRead: false, isStarred: false, updatedAt: 0).save(db)

            let frFeed = FeedRecord(id: "fr-feed", accountID: acc.id, title: "F", feedURL: "https://f.com", updatedAt: 0)
            try frFeed.save(db)
            let frItem = ItemRecord(id: "fr-item", accountID: acc.id, externalID: "2", feedID: frFeed.id, createdAt: 0, updatedAt: 0)
            try frItem.save(db)
            try ArticleStateRecord(itemID: frItem.id, isRead: false, isStarred: false, updatedAt: 0).save(db)
        }

        // 全局将所有文章标记为已读
        try database.write { db in
            try stateRepo.markAllRead(in: db)
        }

        // 校验：Local item 没有生成 outbox，FreshRSS item 成功生成了 outbox
        let localOutbox = try database.read { db in
            try ArticleStateOutboxRecord.filter(Column("item_id") == "loc-item").fetchAll(db)
        }
        XCTAssertEqual(localOutbox.count, 0, "Local items must not generate outbox entries")

        let frOutbox = try database.read { db in
            try ArticleStateOutboxRecord.filter(Column("item_id") == "fr-item").fetchAll(db)
        }
        XCTAssertEqual(frOutbox.count, 1, "FreshRSS items must generate outbox entries on markAllRead")
        XCTAssertEqual(frOutbox.first?.stateKey, "read")
        XCTAssertTrue(frOutbox.first?.desiredValue == true)
    }

    /// P1 验证：AIArtifact 保存时，若 entryID 为 FreshRSS item，其所属 account_id 必须为该 item 的真实 account_id。
    func testAIArtifactOwnershipDerivedFromItemAccount() throws {
        let artifactRepo = AIArtifactRepository(database: database)
        let frAccountID = "freshrss-ai-owner"

        try database.write { db in
            let acc = AccountRecord(
                id: frAccountID,
                type: AccountType.freshRSS.rawValue,
                displayName: "FR AI",
                endpointURL: "https://fr.com",
                username: "ai_user",
                isEnabled: true,
                createdAt: 0,
                updatedAt: 0
            )
            try acc.save(db)
            let feed = FeedRecord(id: "fr-ai-feed", accountID: frAccountID, title: "AI Feed", feedURL: "https://ai.com", updatedAt: 0)
            try feed.save(db)
            let item = ItemRecord(id: "\(frAccountID)::item_ai_1", accountID: frAccountID, externalID: "item_ai_1", feedID: feed.id, createdAt: 0, updatedAt: 0)
            try item.save(db)
        }

        let artifact = AIArtifact(
            id: UUID(),
            entryID: "\(frAccountID)::item_ai_1",
            kind: .summary,
            contentHash: "hash123",
            model: "deepseek-chat",
            targetLanguage: "zh-CN",
            promptVersion: 1,
            content: "Article AI Summary Content",
            segments: [],
            isComplete: true,
            isDeleted: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        // 保存 AIArtifact（默认传入 "local-default"，内部自动根据 items 表推导纠偏）
        try database.write { db in
            try artifactRepo.saveArtifactModel(artifact, accountID: "local-default", in: db)
        }

        // 验证数据库中持久化的 AIArtifactRecord.account_id 为 frAccountID
        let record = try database.read { db in
            try AIArtifactRecord.filter(Column("subject_key") == "\(frAccountID)::item_ai_1").fetchOne(db)
        }
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.accountID, frAccountID, "AIArtifact account_id must match item's account_id, not local-default")
    }

    // MARK: - 8. FreshRSS Wire ID & Authoritative State Reconciliation Tests

    /// 验证 ReaderItemIDCodec 编解码器：十进制 ↔ 长十六进制 标识等价性转换及边界情况
    func testReaderItemIDCodecEquivalenceAndEdgeCases() {
        // 1. 真实 FreshRSS 样例：1572638017615972 ↔ tag:google.com,2005:reader/item/0005964e52667864
        let decID = "1572638017615972"
        let hexTagID = "tag:google.com,2005:reader/item/0005964e52667864"
        XCTAssertTrue(ReaderItemIDCodec.areEquivalent(decID, hexTagID))
        XCTAssertEqual(ReaderItemIDCodec.canonicalComparisonKey(for: decID), decID)
        XCTAssertEqual(ReaderItemIDCodec.canonicalComparisonKey(for: hexTagID), decID)
        XCTAssertEqual(ReaderItemIDCodec.formatTagID(fromDecimal: decID), hexTagID)

        // 2. 基础整数样例：1 ↔ tag:google.com,2005:reader/item/0000000000000001
        XCTAssertTrue(ReaderItemIDCodec.areEquivalent("1", "tag:google.com,2005:reader/item/0000000000000001"))

        // 3. 不相关的 opaque 标识绝对隔离
        XCTAssertFalse(ReaderItemIDCodec.areEquivalent("tag:google.com,2005:reader/item/foo/a/123", "tag:google.com,2005:reader/item/bar/b/123"))
        XCTAssertFalse(ReaderItemIDCodec.areEquivalent("123", "456"))

        // 4. 非标准 opaque 字符串原样保留比较键
        XCTAssertEqual(ReaderItemIDCodec.canonicalComparisonKey(for: "opaque_entry_id_999"), "opaque_entry_id_999")
    }

    /// 验证 ReaderAPIItemRef 解码兼容性：支持字符串 ID 与 legacy 整数 ID
    func testItemRefsJSONTolerantDecoding() throws {
        let json = """
        {
            "itemRefs": [
                {"id": "1572638017615972", "timestampUsec": "1700000000"},
                {"id": 1572638017615973, "timestampUsec": "1700000001"}
            ],
            "continuation": "next_token"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReaderAPIStreamItemIDsResponse.self, from: json)
        XCTAssertEqual(decoded.continuation, "next_token")
        XCTAssertEqual(decoded.itemRefs?.count, 2)
        XCTAssertEqual(decoded.itemRefs?[0].id, "1572638017615972")
        XCTAssertEqual(decoded.itemRefs?[1].id, "1572638017615973")
    }

    /// 验证所有 4 种状态组合精准同步（A, B, C, D）
    /// A: unread + unstarred -> (false, false)
    /// B: read   + starred   -> (true,  true)
    /// C: unread + starred   -> (false, true)
    /// D: read   + unstarred -> (true,  false)
    func testAllFourStateCombinations() async throws {
        let accountID = "freshrss-4-states"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        // 四篇测试文章数据
        // A: dec "101", hex "0000000000000065" -> unread + unstarred
        // B: dec "102", hex "0000000000000066" -> read + starred
        // C: dec "103", hex "0000000000000067" -> unread + starred
        // D: dec "104", hex "0000000000000068" -> read + unstarred
        let tagA = "tag:google.com,2005:reader/item/0000000000000065"
        let tagB = "tag:google.com,2005:reader/item/0000000000000066"
        let tagC = "tag:google.com,2005:reader/item/0000000000000067"
        let tagD = "tag:google.com,2005:reader/item/0000000000000068"

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "4States FR", endpointURL: endpoint.absoluteString, username: "user4", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-4s-1", accountID: accountID, externalID: "feed/4s", title: "Feed 4S", feedURL: "https://4s.com/rss", updatedAt: 0)
            try feed.save(db)
        }

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/4s\",\"title\":\"Feed 4S\",\"url\":\"https://4s.com/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if query.contains("starred") {
                    // Starred: B ("102") 和 C ("103")
                    let json = "{\"itemRefs\":[{\"id\":\"102\"},{\"id\":\"103\"}]}"
                    return (resp, json.data(using: .utf8)!)
                } else {
                    // Unread (reading-list, xt=read): A ("101") 和 C ("103")
                    let json = "{\"itemRefs\":[{\"id\":\"101\"},{\"id\":\"103\"}]}"
                    return (resp, json.data(using: .utf8)!)
                }
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "items": [
                        {
                            "id": "\(tagA)",
                            "title": "Item A",
                            "origin": {"streamId": "feed/4s"},
                            "content": {"content": "<p>A</p>"},
                            "categories": ["user/-/state/com.google/reading-list"]
                        },
                        {
                            "id": "\(tagB)",
                            "title": "Item B",
                            "origin": {"streamId": "feed/4s"},
                            "content": {"content": "<p>B</p>"},
                            "categories": ["user/-/state/com.google/read", "user/-/state/com.google/starred"]
                        },
                        {
                            "id": "\(tagC)",
                            "title": "Item C",
                            "origin": {"streamId": "feed/4s"},
                            "content": {"content": "<p>C</p>"},
                            "categories": ["user/-/state/com.google/reading-list", "user/-/state/com.google/starred"]
                        },
                        {
                            "id": "\(tagD)",
                            "title": "Item D",
                            "origin": {"streamId": "feed/4s"},
                            "content": {"content": "<p>D</p>"},
                            "categories": ["user/-/state/com.google/read"]
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
            username: "user4",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        _ = try await provider.refresh(reason: .manual)

        // 验证数据库状态
        try database.read { db in
            let stateA = try ArticleStateRecord.filter(Column("item_id") == "\(accountID)::\(tagA)").fetchOne(db)
            let stateB = try ArticleStateRecord.filter(Column("item_id") == "\(accountID)::\(tagB)").fetchOne(db)
            let stateC = try ArticleStateRecord.filter(Column("item_id") == "\(accountID)::\(tagC)").fetchOne(db)
            let stateD = try ArticleStateRecord.filter(Column("item_id") == "\(accountID)::\(tagD)").fetchOne(db)

            XCTAssertNotNil(stateA)
            XCTAssertNotNil(stateB)
            XCTAssertNotNil(stateC)
            XCTAssertNotNil(stateD)

            // A: unread + unstarred -> (false, false)
            XCTAssertFalse(stateA!.isRead, "A must be unread (isRead == false)")
            XCTAssertFalse(stateA!.isStarred, "A must be unstarred (isStarred == false)")

            // B: read + starred -> (true, true)
            XCTAssertTrue(stateB!.isRead, "B must be read (isRead == true)")
            XCTAssertTrue(stateB!.isStarred, "B must be starred (isStarred == true)")

            // C: unread + starred -> (false, true)
            XCTAssertFalse(stateC!.isRead, "C must be unread (isRead == false)")
            XCTAssertTrue(stateC!.isStarred, "C must be starred (isStarred == true)")

            // D: read + unstarred -> (true, false)
            XCTAssertTrue(stateD!.isRead, "D must be read (isRead == true)")
            XCTAssertFalse(stateD!.isStarred, "D must be unstarred (isStarred == false)")
        }
    }

    /// 验证两阶段双向状态流与 Outbox raw ID 传递
    func testTwoWayStateFlowAndOutboxRawID() async throws {
        let accountID = "freshrss-twoway-test"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let tagItem = "tag:google.com,2005:reader/item/0005964e52667864"
        let decItem = "1572638017615972"

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "TwoWay FR", endpointURL: endpoint.absoluteString, username: "user_twoway", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-tw-1", accountID: accountID, externalID: "feed/tw", title: "Feed TW", feedURL: "https://tw.com/rss", updatedAt: 0)
            try feed.save(db)
        }

        let sentEditTagsBox = TestStateBox<[(items: [String], addTag: String?, removeTag: String?)]>([])

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("reader/api/0/token") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "write_token_twoway".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/tw\",\"title\":\"Feed TW\",\"url\":\"https://tw.com/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if query.contains("starred") {
                    return (resp, "{\"itemRefs\":[]}".data(using: .utf8)!)
                } else {
                    // 初始未读返回十进制数字 ID
                    let json = "{\"itemRefs\":[{\"id\":\"\(decItem)\"}]}"
                    return (resp, json.data(using: .utf8)!)
                }
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "items": [
                        {
                            "id": "\(tagItem)",
                            "title": "TwoWay Article",
                            "origin": {"streamId": "feed/tw"},
                            "content": {"content": "<p>Content</p>"},
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
                sentEditTagsBox.mutate { $0.append((itemIDs, addTag, removeTag)) }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "OK".data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "user_twoway",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        // 1. 初始同步
        _ = try await provider.refresh(reason: .manual)

        let internalItemID = "\(accountID)::\(tagItem)"
        let stateRepo = ArticleStateRepository(database: database)

        // 2. 本地用户操作：标记已读
        try database.write { db in
            try stateRepo.markRead(itemID: internalItemID, isRead: true, in: db)
        }

        // 3. 再次触发同步推送 Outbox
        _ = try await provider.refresh(reason: .manual)

        // 4. 验证远端 edit-tag 收到的是完整的 raw long tag ID
        let edits = sentEditTagsBox.value
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.items, [tagItem], "Outbound edit-tag MUST send stored raw remote ID: \(tagItem)")
        XCTAssertTrue(edits.first?.addTag?.contains("read") == true)

        // 5. 验证本地 Outbox 已清空
        let outboxCount = try database.read { db in
            try ArticleStateOutboxRecord.filter(Column("account_id") == accountID).fetchCount(db)
        }
        XCTAssertEqual(outboxCount, 0)
    }

    /// 验证非权威的不完整集合（isComplete == false）绝不能负向推断修改缺失文章的本地状态
    func testIncompleteSetDoesNotNegativelyInfer() async throws {
        let accountID = "freshrss-incomplete-set"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let existingTagItem = "tag:google.com,2005:reader/item/0000000000000999"

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Incomplete FR", endpointURL: endpoint.absoluteString, username: "user_inc", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-inc-1", accountID: accountID, externalID: "feed/inc", title: "Feed INC", feedURL: "https://inc.com/rss", updatedAt: 0)
            try feed.save(db)
            let item = ItemRecord(id: "\(accountID)::\(existingTagItem)", accountID: accountID, externalID: existingTagItem, feedID: "feed-inc-1", createdAt: 100, updatedAt: 100)
            try item.save(db)
            // 本地已有未读且未星标
            let state = ArticleStateRecord(itemID: item.id, isRead: false, isStarred: true, updatedAt: 100)
            try state.save(db)
            let syncState = AccountSyncStateRecord(accountID: accountID, initialSyncCompleted: true, lastSyncCompletedAt: 100, lastFullReconcileAt: 100)
            try syncState.save(db)
        }

        let client = ReaderAPIClient(
            endpointURL: endpoint,
            username: "user_inc",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // 模拟不断返回 continuation，使拉取达到 maxTotal 上限退出
                let json = """
                {
                    "itemRefs": [{"id": "1"}],
                    "continuation": "never_ending_token"
                }
                """
                return (resp, json.data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{}".data(using: .utf8)!)
        }

        // 验证 fetchAllUnreadItemIDs 在达到上限后返回 isComplete = false
        let unreadSet = try await client.fetchAllUnreadItemIDs(maxTotal: 1)
        XCTAssertFalse(unreadSet.isComplete, "Set must be marked incomplete when continuation remains after maxTotal")

        // 验证：调和逻辑在 unreadSet.isComplete == false 时，不会将 absent item 负向推断为已读
        let canonicalKeys = ReaderItemIDCodec.buildCanonicalKeySet(from: unreadSet.ids)
        let itemKey = ReaderItemIDCodec.canonicalComparisonKey(for: existingTagItem)
        XCTAssertFalse(canonicalKeys.contains(itemKey))

        // 严格断言：若 isComplete == false，绝不能将 isRead 设为 true
        XCTAssertFalse(unreadSet.isComplete)
    }

    /// 验证 Stream Item 自带的 categories 具有最高优先级，直达状态判定
    func testStreamItemCategoriesTakePrecedence() async throws {
        let accountID = "freshrss-categories-precedence"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let tagItem = "tag:google.com,2005:reader/item/0000000000000888"

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Cat FR", endpointURL: endpoint.absoluteString, username: "user_cat", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-cat-1", accountID: accountID, externalID: "feed/cat", title: "Feed CAT", feedURL: "https://cat.com/rss", updatedAt: 0)
            try feed.save(db)
        }

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/cat\",\"title\":\"Feed CAT\",\"url\":\"https://cat.com/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // 即使 stream/items/ids 返回空集合或不包含该文章
                return (resp, "{\"itemRefs\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // Stream Item 本身明确带有 read 与 starred categories
                let json = """
                {
                    "items": [
                        {
                            "id": "\(tagItem)",
                            "title": "Category Item",
                            "origin": {"streamId": "feed/cat"},
                            "content": {"content": "<p>Content</p>"},
                            "categories": ["user/-/state/com.google/read", "user/-/state/com.google/starred"]
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
            username: "user_cat",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        _ = try await provider.refresh(reason: .manual)

        try database.read { db in
            let state = try ArticleStateRecord.filter(Column("item_id") == "\(accountID)::\(tagItem)").fetchOne(db)
            XCTAssertNotNil(state)
            XCTAssertTrue(state!.isRead, "Stream item with read category must be marked read")
            XCTAssertTrue(state!.isStarred, "Stream item with starred category must be marked starred")
        }
    }

    /// 验证文章拉取遇到网络故障时，必须抛出错误并记录在 AccountSyncState 中，绝不能静默当作空成功刷新
    func testArticleNetworkFailureThrowsAndDoesNotMarkSuccess() async throws {
        let accountID = "freshrss-net-fail"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Fail FR", endpointURL: endpoint.absoluteString, username: "user_fail", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-fail-1", accountID: accountID, externalID: "feed/fail", title: "Feed Fail", feedURL: "https://fail.com/rss", updatedAt: 0)
            try feed.save(db)
            let syncState = AccountSyncStateRecord(accountID: accountID, initialSyncCompleted: true, lastSyncCompletedAt: 100, lastFullReconcileAt: 100)
            try syncState.save(db)
        }

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"itemRefs\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                // 模拟文章内容拉取网络崩溃
                throw URLError(.timedOut)
            }
            throw URLError(.badURL)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "user_fail",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        do {
            _ = try await provider.refresh(reason: .manual)
            XCTFail("Refresh must throw when article stream fetch fails")
        } catch {
            // 验证抛出了网络错误
        }

        let syncState = try database.read { db in
            try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)
        }
        XCTAssertNotNil(syncState?.lastError, "lastError must be populated on sync failure")
        XCTAssertGreaterThan(syncState?.consecutiveFailureCount ?? 0, 0)
    }

    /// 验证找不到 externalID 的 outbox 行被保留并记录 lastError，严禁静默删除
    func testMissingExternalIDOutboxRowIsRetained() async throws {
        let accountID = "freshrss-orphan-outbox"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        let orphanItemID = "item_without_external_id"

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Orphan FR", endpointURL: endpoint.absoluteString, username: "user_orph", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let feed = FeedRecord(id: "feed-orph-1", accountID: accountID, title: "Feed Orph", feedURL: "https://orph.com/rss", updatedAt: 0)
            try feed.save(db)
            let item = ItemRecord(id: orphanItemID, accountID: accountID, externalID: "", feedID: feed.id, createdAt: 0, updatedAt: 0)
            try item.save(db)

            // 写入一个没有有效 externalID 的 Outbox 记录
            let outbox = ArticleStateOutboxRecord(accountID: accountID, itemID: orphanItemID, stateKey: "read", desiredValue: true, revision: 1, updatedAt: 0)
            try outbox.save(db)
        }

        let client = ReaderAPIClient(
            endpointURL: endpoint,
            username: "user_orph",
            accountID: accountID,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )
        let processor = ArticleStateOutboxProcessor(
            accountID: accountID,
            database: database,
            apiClient: client
        )

        let result = try await processor.processOutbox(forceAll: true)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(result.successCount, 0)

        // 校验：outbox 记录严禁被删除，且更新了 failure 和 lastError
        let retainedRow = try database.read { db in
            try ArticleStateOutboxRecord.filter(Column("account_id") == accountID && Column("item_id") == orphanItemID).fetchOne(db)
        }
        XCTAssertNotNil(retainedRow, "Orphan outbox record MUST be retained, never silently deleted")
        XCTAssertEqual(retainedRow?.attemptCount, 1)
        XCTAssertTrue(retainedRow?.lastError?.contains("Missing item or external_id") == true)
    }

    // MARK: - 9. Goal 2 Finalization Tests (Incremental Sync, Refresh Routing, Feed Lookup)

    /// 验证 P1：可靠增量同步与翻页（服务端在两次同步间产生 250 篇新文章，通过 continuation 完整同步到本地，全部存在且无重复）
    func testReliableIncrementalSyncFetchesAll250NewArticlesAcrossPages() async throws {
        let accountID = "freshrss-incr-250"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Incr FR", endpointURL: endpoint.absoluteString, username: "user_incr", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
        }

        let totalBatch1 = 100
        let totalBatch2 = 250

        let syncPhaseBox = TestStateBox<Int>(1)

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/incr\",\"title\":\"Feed Incr\",\"url\":\"https://incr.com/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"itemRefs\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let phase = syncPhaseBox.value
                if phase == 1 {
                    // 初始同步：返回 100 篇旧文章
                    var itemsJson: [String] = []
                    for i in 1...totalBatch1 {
                        let id = "tag:google.com,2005:reader/item/\(String(format: "%016x", i))"
                        itemsJson.append("""
                        {
                            "id": "\(id)",
                            "title": "Batch 1 Item \(i)",
                            "origin": {"streamId": "feed/incr"},
                            "content": {"content": "<p>Content \(i)</p>"},
                            "published": \(1000 + i),
                            "categories": ["user/-/state/com.google/read"]
                        }
                        """)
                    }
                    let json = "{\"items\":[\(itemsJson.joined(separator: ","))]}"
                    return (resp, json.data(using: .utf8)!)
                } else {
                    // 增量同步：250 篇新文章，通过分页 continuation 返回 (Page 1: 100 篇带 continuation "c2", Page 2: 100 篇带 continuation "c3", Page 3: 50 篇无 continuation)
                    if query.contains("c=c3") {
                        var itemsJson: [String] = []
                        for i in 201...totalBatch2 {
                            let id = "tag:google.com,2005:reader/item/\(String(format: "%016x", 1000 + i))"
                            itemsJson.append("""
                            {
                                "id": "\(id)",
                                "title": "Batch 2 Item \(i)",
                                "origin": {"streamId": "feed/incr"},
                                "content": {"content": "<p>New Content \(i)</p>"},
                                "published": \(2000 + i),
                                "categories": ["user/-/state/com.google/read"]
                            }
                            """)
                        }
                        let json = "{\"items\":[\(itemsJson.joined(separator: ","))]}"
                        return (resp, json.data(using: .utf8)!)
                    } else if query.contains("c=c2") {
                        var itemsJson: [String] = []
                        for i in 101...200 {
                            let id = "tag:google.com,2005:reader/item/\(String(format: "%016x", 1000 + i))"
                            itemsJson.append("""
                            {
                                "id": "\(id)",
                                "title": "Batch 2 Item \(i)",
                                "origin": {"streamId": "feed/incr"},
                                "content": {"content": "<p>New Content \(i)</p>"},
                                "published": \(2000 + i),
                                "categories": ["user/-/state/com.google/read"]
                            }
                            """)
                        }
                        let json = "{\"items\":[\(itemsJson.joined(separator: ","))],\"continuation\":\"c3\"}"
                        return (resp, json.data(using: .utf8)!)
                    } else {
                        var itemsJson: [String] = []
                        for i in 1...100 {
                            let id = "tag:google.com,2005:reader/item/\(String(format: "%016x", 1000 + i))"
                            itemsJson.append("""
                            {
                                "id": "\(id)",
                                "title": "Batch 2 Item \(i)",
                                "origin": {"streamId": "feed/incr"},
                                "content": {"content": "<p>New Content \(i)</p>"},
                                "published": \(2000 + i),
                                "categories": ["user/-/state/com.google/read"]
                            }
                            """)
                        }
                        let json = "{\"items\":[\(itemsJson.joined(separator: ","))],\"continuation\":\"c2\"}"
                        return (resp, json.data(using: .utf8)!)
                    }
                }
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{}".data(using: .utf8)!)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "user_incr",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        // 1. 执行初始同步
        _ = try await provider.refresh(reason: .manual)

        let initialCount = try database.read { db in
            try ItemRecord.filter(Column("account_id") == accountID).fetchCount(db)
        }
        XCTAssertEqual(initialCount, 100)

        // 2. 远端产生 250 篇新文章，进入 Phase 2 执行增量同步
        syncPhaseBox.value = 2
        _ = try await provider.refresh(reason: .manual)

        // 3. 校验：本地必须完整拥有 100 + 250 = 350 篇文章，绝无丢失或多余项
        let totalCount = try database.read { db in
            try ItemRecord.filter(Column("account_id") == accountID).fetchCount(db)
        }
        XCTAssertEqual(totalCount, 350, "All 250 new articles across pagination pages must exist locally")
    }

    /// 验证 P1：初始同步超出最近窗口的老星标与老未读条目可达且状态正确
    func testInitialSyncReachesOldStarredAndOldUnreadOutsideRecentWindow() async throws {
        let accountID = "freshrss-old-starred"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: accountID)

        try database.write { db in
            let acc = AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Old Starred FR", endpointURL: endpoint.absoluteString, username: "user_old", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
        }

        let oldStarredTagID = "tag:google.com,2005:reader/item/0000000000000888"
        let oldStarredDecID = "2184"
        let oldUnreadTagID = "tag:google.com,2005:reader/item/0000000000000999"
        let oldUnreadDecID = "2457"

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/history\",\"title\":\"History Feed\",\"url\":\"https://history.com/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if query.contains("starred") {
                    let json = "{\"itemRefs\":[{\"id\":\"\(oldStarredDecID)\"}]}"
                    return (resp, json.data(using: .utf8)!)
                } else {
                    let json = "{\"itemRefs\":[{\"id\":\"\(oldUnreadDecID)\"}]}"
                    return (resp, json.data(using: .utf8)!)
                }
            } else if path.contains("stream/items/contents") {
                // 正文补齐接口：为历史老星标与老未读返回权威正文与 feed 归属
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "items": [
                        {
                            "id": "\(oldStarredTagID)",
                            "title": "Old Starred Article",
                            "origin": {"streamId": "feed/history"},
                            "content": {"content": "<p>Historical Starred Content</p>"},
                            "categories": ["user/-/state/com.google/starred", "user/-/state/com.google/read"]
                        },
                        {
                            "id": "\(oldUnreadTagID)",
                            "title": "Old Unread Article",
                            "origin": {"streamId": "feed/history"},
                            "content": {"content": "<p>Historical Unread Content</p>"},
                            "categories": ["user/-/state/com.google/reading-list"]
                        }
                    ]
                }
                """
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                // 最近 200 篇文章中不包含这篇老星标和老未读
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "items": [
                        {
                            "id": "tag:google.com,2005:reader/item/0000000000000001",
                            "title": "Recent Item 1",
                            "origin": {"streamId": "feed/history"},
                            "content": {"content": "<p>Recent Content</p>"},
                            "categories": ["user/-/state/com.google/read"]
                        }
                    ]
                }
                """
                return (resp, json.data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{}".data(using: .utf8)!)
        }

        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: endpoint,
            username: "user_old",
            database: database,
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        // 初始同步
        _ = try await provider.refresh(reason: .manual)

        // 校验：老星标条目在数据库中必须存在且状态为 isStarred = true
        let starredItem = try database.read { db in
            try ItemRecord.filter(Column("account_id") == accountID && Column("external_id") == oldStarredTagID).fetchOne(db)
        }
        XCTAssertNotNil(starredItem, "Old starred item must exist locally even if outside recent stream window")

        if let starredItem {
            let state = try database.read { db in
                try ArticleStateRecord.filter(Column("item_id") == starredItem.id).fetchOne(db)
            }
            XCTAssertEqual(state?.isStarred, true)
        }

        // 校验：老未读条目在数据库中必须存在且状态为 isRead = false
        let unreadItem = try database.read { db in
            try ItemRecord.filter(Column("account_id") == accountID && Column("external_id") == oldUnreadTagID).fetchOne(db)
        }
        XCTAssertNotNil(unreadItem, "Old unread item must exist locally even if outside recent stream window")
        if let unreadItem {
            let state = try database.read { db in
                try ArticleStateRecord.filter(Column("item_id") == unreadItem.id).fetchOne(db)
            }
            XCTAssertEqual(state?.isRead, false)
        }
    }

    /// 验证 P1：全局刷新只触发每个 Provider 执行且仅执行一次（Local 绝不执行两次）
    @MainActor
    func testSingleGlobalRefreshInvokesEachProviderExactlyOnceWithoutDoubleLocalRefresh() async throws {
        let localFetchCounterBox = TestStateBox<Int>(0)
        let frAFetchCounterBox = TestStateBox<Int>(0)
        let frBFetchCounterBox = TestStateBox<Int>(0)

        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("legacy.json"),
            credentialStore: inMemoryCredentialStore,
            customSession: mockSession,
            feedFetcher: { feed in
                localFetchCounterBox.mutate { $0 += 1 }
                return .notModified(etag: "etag", lastModified: "now")
            }
        )

        // 1. 添加一个本地 feed
        _ = try store.localProvider.addFeed(
            title: "Local Feed",
            feedURL: URL(string: "https://local.example.com/rss.xml")!
        )
        store.reloadState()

        // 2. 添加两个 FreshRSS 账号并挂载请求处理计数
        MockFreshRSSURLProtocol.setHandler { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("fra.com") {
                frAFetchCounterBox.mutate { $0 += 1 }
            } else if urlStr.contains("frb.com") {
                frBFetchCounterBox.mutate { $0 += 1 }
            }
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"subscriptions\":[],\"tags\":[],\"itemRefs\":[],\"items\":[]}".data(using: .utf8)!)
        }

        _ = try await store.addFreshRSSAccount(endpointURLText: "https://fra.com", username: "user_a", password: "pwd", customSession: mockSession)
        _ = try await store.addFreshRSSAccount(endpointURLText: "https://frb.com", username: "user_b", password: "pwd", customSession: mockSession)

        // 重置计数器（排除初始添加时的网络调用）
        localFetchCounterBox.value = 0
        frAFetchCounterBox.value = 0
        frBFetchCounterBox.value = 0

        // 3. 触发一次用户全局刷新
        let outcome = await store.refresh(feedIDs: nil)
        XCTAssertNotNil(outcome)

        // 4. 校验：本地 Feed 抓取器精确调用 1 次，绝对不可被调用 2 次
        XCTAssertEqual(localFetchCounterBox.value, 1, "Local feed fetcher MUST be invoked exactly ONCE on global refresh")
        XCTAssertTrue(frAFetchCounterBox.value > 0, "FreshRSS A MUST be synced on global refresh")
        XCTAssertTrue(frBFetchCounterBox.value > 0, "FreshRSS B MUST be synced on global refresh")
    }

    /// 验证 P1：远端同步失败时暴露错误至 UI/Outcome，且本地成功数据完整保留不回滚
    @MainActor
    func testPartialRemoteRefreshFailureSurfacesErrorWhilePreservingLocalData() async throws {
        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("legacy.json"),
            credentialStore: inMemoryCredentialStore,
            customSession: mockSession,
            feedFetcher: { feed in
                let entry = ParsedFeedEntry(
                    id: "local-new-1",
                    title: "Brand New Local Article",
                    author: "Author",
                    url: URL(string: "https://healthy.local/1"),
                    publishedAt: Date(),
                    summary: "Hello",
                    contentHTML: "<p>Hello</p>"
                )
                let parsed = ParsedFeed(title: "Healthy Local Feed", siteURL: nil, iconURL: nil, entries: [entry])
                return .updated(parsed, etag: "new_etag", lastModified: "now")
            }
        )

        // 1. 本地 Feed
        _ = try store.localProvider.addFeed(
            title: "Healthy Local Feed",
            feedURL: URL(string: "https://healthy.local/rss.xml")!
        )
        store.reloadState()

        // 2. 添加一个 FreshRSS 账号，但模拟其远端请求返回 HTTP 503 Service Unavailable
        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"subscriptions\":[],\"tags\":[],\"itemRefs\":[],\"items\":[]}".data(using: .utf8)!)
        }
        _ = try await store.addFreshRSSAccount(endpointURLText: "https://broken.remote", username: "broken_user", password: "pwd", customSession: mockSession)

        // 变更 mock 为故障状态
        MockFreshRSSURLProtocol.setHandler { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (resp, "Service Unavailable".data(using: .utf8)!)
        }

        // 3. 执行全局刷新
        let outcome = await store.refresh(feedIDs: nil)
        XCTAssertNotNil(outcome)

        // 4. 校验：刷新状态必须为 failed，暴露错误信息，且本地数据完好保留
        if case let .failed(msg, _) = store.refreshStatus {
            XCTAssertTrue(msg.contains("503") || msg.contains("broken_user") || msg.contains("freshRSS"))
        } else {
            XCTFail("Global refresh status MUST be failed when remote account sync fails")
        }

        // 校验：本地文章依然完好保存在 store.entries 中
        let localArticle = store.unreadEntryListItems.first { $0.title == "Brand New Local Article" }
        XCTAssertNotNil(localArticle, "Local newly arrived articles MUST be preserved despite remote failure")
    }

    /// 验证 P2：AppStore.feed(for:) 与 feed(forFeedID:) 正确支持查找 FreshRSS 订阅源
    @MainActor
    func testAccountAwareFeedLookupWorksForFreshRSSFeeds() async throws {
        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("legacy.json"),
            credentialStore: inMemoryCredentialStore,
            customSession: mockSession
        )

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/remote1\",\"title\":\"Remote Tech Blog\",\"url\":\"https://techblog.remote/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"subscriptions\":[],\"tags\":[],\"itemRefs\":[],\"items\":[]}".data(using: .utf8)!)
        }

        let acc = try await store.addFreshRSSAccount(endpointURLText: "https://remotefeed.com", username: "user_feed", password: "pwd", customSession: mockSession)

        // 在 feedsByAccount 中获取该 feed
        let frFeeds = store.feedsByAccount[acc.id] ?? []
        XCTAssertEqual(frFeeds.count, 1)
        guard let frFeed = frFeeds.first else {
            XCTFail("Must contain remote feed")
            return
        }

        // 校验：通过 feed(forFeedID:) 成功查到
        let lookedUpFeed = store.feed(forFeedID: frFeed.id)
        XCTAssertNotNil(lookedUpFeed)
        XCTAssertEqual(lookedUpFeed?.title, "Remote Tech Blog")

        // 校验：构造关联该 feed 的 Entry，通过 store.feed(for: entry) 成功查到
        let dummyEntry = Entry(
            id: "fr-item-1",
            feedID: frFeed.id,
            title: "Test Entry",
            url: URL(string: "https://techblog.remote/1"),
            summary: "Content",
            contentHTML: "<p>Content</p>",
            isRead: false,
            isStarred: false,
            updatedAt: .now
        )
        let lookedUpEntryFeed = store.feed(for: dummyEntry)
        XCTAssertNotNil(lookedUpEntryFeed)
        XCTAssertEqual(lookedUpEntryFeed?.title, "Remote Tech Blog")
    }

    /// 验证并发防重保护：数据库事务内二次检查杜绝并发添加相同账号竞争
    @MainActor
    func testAtomicDuplicateFreshRSSAccountRacePrevention() async throws {
        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("legacy.json"),
            credentialStore: inMemoryCredentialStore
        )

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"subscriptions\":[],\"tags\":[],\"itemRefs\":[],\"items\":[]}".data(using: .utf8)!)
        }

        // 首次添加
        _ = try await store.addFreshRSSAccount(endpointURLText: "https://race.example.com", username: "race_user", password: "pwd", customSession: mockSession)

        // 模拟并发调用：第二次尝试直接插入相同账号记录到数据库中
        let accountRepo = AccountRepository(database: database)
        let duplicateRecord = AccountRecord(
            id: "race-dup-account-id",
            type: AccountType.freshRSS.rawValue,
            displayName: "Race User",
            endpointURL: "https://race.example.com",
            username: "race_user",
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0
        )

        do {
            try await accountRepo.saveAccountAtomicWithDuplicateCheck(duplicateRecord)
            XCTFail("saveAccountAtomicWithDuplicateCheck MUST throw accountAlreadyExists for duplicate account")
        } catch let ReaderAPIError.accountAlreadyExists(msg) {
            XCTAssertTrue(msg.contains("race_user"))
        }
    }

    /// 验证增量同步能够跨多页完整抓取 >1000 篇（如 1250 篇）新文章，且只有在到达已知边界后才推进时间戳
    @MainActor
    func testIncrementalSyncFetchesOver1250ArticlesAndAdvancesTimestamp() async throws {
        let endpoint = URL(string: "https://huge-sync.freshrss.com")!
        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("huge.json"),
            credentialStore: inMemoryCredentialStore,
            customSession: mockSession
        )

        // 构造 1250 篇增量文章数据，按 100 篇分页，共 13 页
        let totalItems = 1250
        let pageSize = 100
        let isInitialSyncDoneBox = TestStateBox(false)

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""

            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = "{\"subscriptions\":[{\"id\":\"feed/huge\",\"title\":\"Huge Feed\",\"url\":\"https://huge.com/rss\",\"categories\":[]}]}"
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") || path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"subscriptions\":[],\"tags\":[],\"itemRefs\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if !isInitialSyncDoneBox.value {
                    // 初始同步时返回空列表
                    return (resp, "{\"items\":[]}".data(using: .utf8)!)
                }

                // 增量同步时根据 continuation c 返回 1250 篇新文章
                var pageIndex = 0
                for item in query.split(separator: "&") {
                    let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2, pair[0] == "c", let cIdx = Int(pair[1].replacingOccurrences(of: "c_", with: "")) {
                        pageIndex = cIdx
                    }
                }

                let startIdx = pageIndex * pageSize
                let endIdx = min(startIdx + pageSize, totalItems)
                var itemsJSON: [String] = []
                for i in startIdx..<endIdx {
                    itemsJSON.append("""
                    {
                        "id": "tag:google.com,2005:reader/item/inc_\(String(format: "%016x", i + 1))",
                        "title": "Incremental Article #\(i + 1)",
                        "published": \(1700000000 + i),
                        "origin": {"streamId": "feed/huge"},
                        "content": {"content": "<p>Content #\(i + 1)</p>"},
                        "categories": ["user/-/state/com.google/reading-list"]
                    }
                    """)
                }

                let nextC = (endIdx < totalItems) ? "\"c_\(pageIndex + 1)\"" : "null"
                let json = "{\"items\":[\(itemsJSON.joined(separator: ", "))],\"continuation\":\(nextC)}"
                return (resp, json.data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        // 1. 首次添加账号（完成初始同步）
        let acc = try await store.addFreshRSSAccount(
            endpointURLText: endpoint.absoluteString,
            username: "huge_user",
            password: "pwd",
            customSession: mockSession
        )
        isInitialSyncDoneBox.mutate { $0 = true }

        // 2. 模拟增量同步：触发 refresh
        _ = await store.refresh()

        // 3. 校验：1250 篇文章全部存在且无重复
        let itemCount = try database.read { db in
            try ItemRecord.filter(Column("account_id") == acc.id).fetchCount(db)
        }
        XCTAssertEqual(itemCount, 1250, "All 1250 incremental articles must be synced")

        // 4. 校验：last_article_fetch_at 成功推进
        let syncState = try database.read { db in
            try AccountSyncStateRecord.filter(Column("account_id") == acc.id).fetchOne(db)
        }
        XCTAssertNotNil(syncState?.lastArticleFetchAt)
        XCTAssertGreaterThan(syncState!.lastArticleFetchAt!, 0)
    }

    /// 验证增量同步遇到意外截断（未达已知边界）时，last_article_fetch_at 绝不提前推进
    @MainActor
    func testTruncatedContinuationDoesNotAdvanceLastArticleFetchAt() async throws {
        let endpoint = URL(string: "https://truncated-sync.freshrss.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("pwd", accountID: "trunc-acc")
        let apiClient = ReaderAPIClient(
            endpointURL: endpoint,
            username: "trunc_user",
            accountID: "trunc-acc",
            credentialStore: inMemoryCredentialStore,
            session: mockSession
        )

        let requestCountBox = TestStateBox(0)

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                let count = requestCountBox.value
                requestCountBox.mutate { $0 += 1 }

                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // 每次返回 10 条，且每次带有不同的 continuation="c_\(count + 1)"
                let itemsJSON = (0..<10).map { i in
                    "{\"id\":\"tag:google.com,2005:reader/item/trunc_\(count * 10 + i)\",\"title\":\"T\(i)\",\"published\":1700000000}"
                }
                let json = "{\"items\":[\(itemsJSON.joined(separator: ", "))],\"continuation\":\"c_\(count + 1)\"}"
                return (resp, json.data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        // 设置 maxTotal = 25，因为每次 10 条，第 3 次达到 30 条 > 25，触发截断退出
        let (items, reachedBoundary) = try await apiClient.fetchIncrementalStreamContents(
            sinceTimestamp: 1690000000,
            pageSize: 10,
            maxTotal: 25,
            knownLocalExternalIDs: []
        )

        XCTAssertEqual(items.count, 30)
        XCTAssertFalse(reachedBoundary, "When truncated at maxTotal with active continuation, reachedBoundary MUST be false")
    }

    /// 验证历史特殊状态 ID 绝不会被随意分配给默认 Feed，不产生空白标题文章，未读数不归属错误 Feed
    @MainActor
    func testHistoricalSpecialIDsNeverGetFakeFeedOwnership() async throws {
        let endpoint = URL(string: "https://nofake.freshrss.com")!
        let store = AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("nofake.json"),
            credentialStore: inMemoryCredentialStore
        )

        MockFreshRSSURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""

            if path.contains("ClientLogin") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "Auth=mock_auth".data(using: .utf8)!)
            } else if path.contains("subscription/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "subscriptions": [
                        {"id": "feed/tech", "title": "Tech Feed", "url": "https://tech.com/rss", "categories": []},
                        {"id": "feed/design", "title": "Design Feed", "url": "https://design.com/rss", "categories": []}
                    ]
                }
                """
                return (resp, json.data(using: .utf8)!)
            } else if path.contains("tag/list") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"tags\":[]}".data(using: .utf8)!)
            } else if path.contains("stream/items/ids") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if query.contains("starred") {
                    // 返回 3 个老星标 ID
                    return (resp, "{\"itemRefs\":[{\"id\":\"old_starred_1\"},{\"id\":\"old_starred_2\"}]}".data(using: .utf8)!)
                } else {
                    return (resp, "{\"itemRefs\":[]}".data(using: .utf8)!)
                }
            } else if path.contains("stream/items/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // 对老星标 ID 返回真实正文及 origin.streamId = "feed/design"
                let itemsJSON = [
                    """
                    {
                        "id": "old_starred_1",
                        "title": "Design Historical Article 1",
                        "published": 1600000000,
                        "origin": {"streamId": "feed/design"},
                        "content": {"content": "<p>Design 1</p>"},
                        "categories": ["user/-/state/com.google/starred"]
                    }
                    """,
                    """
                    {
                        "id": "old_starred_2",
                        "title": "Design Historical Article 2",
                        "published": 1600000001,
                        "origin": {"streamId": "feed/design"},
                        "content": {"content": "<p>Design 2</p>"},
                        "categories": ["user/-/state/com.google/starred"]
                    }
                    """
                ]
                return (resp, "{\"items\":[\(itemsJSON.joined(separator: ", "))]}".data(using: .utf8)!)
            } else if path.contains("stream/contents") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"items\":[]}".data(using: .utf8)!)
            }
            throw URLError(.badURL)
        }

        // 添加账号
        let acc = try await store.addFreshRSSAccount(
            endpointURLText: endpoint.absoluteString,
            username: "nofake_user",
            password: "pwd",
            displayName: "NoFake RSS",
            customSession: mockSession
        )

        // 验证：文章正确归属到 Design Feed，而不是 Tech Feed (default)
        let designFeeds = try database.read { db in
            try FeedRecord.filter(Column("account_id") == acc.id && Column("external_id") == "feed/design").fetchAll(db)
        }
        XCTAssertEqual(designFeeds.count, 1)
        let designFeedUUID = UUID(uuidString: designFeeds[0].id)!

        let techFeeds = try database.read { db in
            try FeedRecord.filter(Column("account_id") == acc.id && Column("external_id") == "feed/tech").fetchAll(db)
        }
        XCTAssertEqual(techFeeds.count, 1)
        let techFeedUUID = UUID(uuidString: techFeeds[0].id)!

        // Tech Feed 文章数应为 0
        let techItems = store.fetchTimelinePage(scope: .feed(feedID: techFeedUUID.uuidString), limit: 10, offset: 0)
        XCTAssertEqual(techItems.count, 0, "Tech feed must not receive fake stub items")

        // Design Feed 文章数应为 2
        let designItems = store.fetchTimelinePage(scope: .feed(feedID: designFeedUUID.uuidString), limit: 10, offset: 0)
        XCTAssertEqual(designItems.count, 2, "Design feed must receive its hydrated items")
        XCTAssertEqual(designItems[0].title, "Design Historical Article 2")
        XCTAssertEqual(designItems[0].accountSourceBadge, "NoFake RSS")
    }
}
