import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

/// Miniflux Google Reader 集成兼容性测试。
///
/// 模拟服务行为对齐 miniflux/v2 `internal/googlereader`：
/// - `POST /accounts/ClientLogin`（Email/Passwd，返回 `Auth=username/hash` 文本）
/// - 所有 POST 强制要求表单 `T` 参数
/// - `stream/items/ids` 使用 long-form `tag:google.com,2005:reader/item/<16hex>` ID 与 offset continuation
/// - `tag/list` 提供空分类；`disable-tag` 只移除分类、不退订
final class MinifluxCompatibilityTests: XCTestCase {

    // MARK: - Mock Server

    final class MockMinifluxGReaderServer: @unchecked Sendable {
        struct Feed {
            var id: Int64
            var title: String
            var url: String
            var categoryTitle: String?
        }

        struct Entry {
            var id: Int64
            var feedID: Int64
            var title: String
            var published: Int64
            var read: Bool
            var starred: Bool
        }

        let username = "miniflux_user"
        let password = "miniflux_pwd"
        let authToken = "miniflux_user/hash"

        private let lock = NSLock()
        private var feeds: [Feed]
        private var entries: [Entry]
        private let tagOnlyCategories: [String]

        private(set) var loginBodies: [String] = []
        private(set) var contentsBodies: [String] = []
        private(set) var editTagBodies: [String] = []
        private(set) var disableTagBodies: [String] = []
        private(set) var quickAddBodies: [String] = []
        private(set) var subscriptionEditBodies: [String] = []
        private(set) var streamIDQueries: [String] = []

        init(feeds: [Feed], entries: [Entry], tagOnlyCategories: [String] = ["Empty"]) {
            self.feeds = feeds
            self.entries = entries
            self.tagOnlyCategories = tagOnlyCategories
        }

        static func longFormID(_ id: Int64) -> String {
            let hex = String(id, radix: 16)
            return "tag:google.com,2005:reader/item/" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        }

        /// 模拟用户在 Miniflux 网页端修改条目状态。
        func setEntryState(id: Int64, read: Bool? = nil, starred: Bool? = nil) {
            lock.lock()
            defer { lock.unlock() }
            for index in entries.indices where entries[index].id == id {
                if let read { entries[index].read = read }
                if let starred { entries[index].starred = starred }
            }
        }

        func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            let url = request.url!
            let path = url.path
            let body = String(data: MockFreshRSSURLProtocol.requestBody(from: request), encoding: .utf8) ?? ""
            let method = request.httpMethod ?? "GET"

            func response(_ code: Int, _ json: Any) throws -> (HTTPURLResponse, Data) {
                let data = try JSONSerialization.data(withJSONObject: json)
                return (HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!, data)
            }

            func text(_ code: Int, _ value: String) -> (HTTPURLResponse, Data) {
                (HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(value.utf8))
            }

            if path.hasSuffix("/accounts/ClientLogin") {
                let form = Self.formValues(body)
                lock.lock(); loginBodies.append(body); lock.unlock()
                guard form["Email"]?.first == username, form["Passwd"]?.first == password else {
                    return try response(401, ["error": "unauthorized"])
                }
                return text(200, "SID=\(authToken)\nLSID=\(authToken)\nAuth=\(authToken)\n")
            }

            // 所有受保护请求必须携带 GoogleLogin 头
            guard request.value(forHTTPHeaderField: "Authorization") == "GoogleLogin auth=\(authToken)" else {
                return try response(401, ["error": "unauthorized"])
            }

            if path.hasSuffix("/reader/api/0/token") {
                return text(200, authToken)
            }

            if path.hasSuffix("/reader/api/0/tag/list") {
                lock.lock()
                let titles = Set(feeds.compactMap(\.categoryTitle)).union(tagOnlyCategories).sorted()
                lock.unlock()
                var tags: [[String: Any]] = [["id": "user/1/state/com.google/starred"]]
                for title in titles {
                    tags.append(["id": "user/1/label/\(title)", "label": title, "type": "folder"])
                }
                return try response(200, ["tags": tags])
            }

            if path.hasSuffix("/reader/api/0/subscription/list") {
                lock.lock()
                let subs: [[String: Any]] = feeds.map { feed in
                    var item: [String: Any] = ["id": "feed/\(feed.id)", "title": feed.title, "url": feed.url]
                    if let categoryTitle = feed.categoryTitle {
                        item["categories"] = [["id": "user/1/label/\(categoryTitle)", "label": categoryTitle, "type": "folder"]]
                    } else {
                        item["categories"] = []
                    }
                    return item
                }
                lock.unlock()
                return try response(200, ["subscriptions": subs])
            }

            if path.hasSuffix("/reader/api/0/stream/items/ids"), method == "GET" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let query = components?.queryItems ?? []
                func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
                lock.lock(); streamIDQueries.append(url.query ?? ""); lock.unlock()

                let stream = value("s") ?? ""
                let excludesRead = (value("xt") ?? "").contains("read")
                let offset = Int(value("c") ?? "0") ?? 0
                let limit = min(Int(value("n") ?? "1000") ?? 1000, 1000)

                lock.lock()
                var candidates: [Entry]
                if stream.hasSuffix("com.google/starred") {
                    candidates = entries.filter(\.starred)
                } else if stream.hasPrefix("feed/") {
                    let feedID = Int64(stream.dropFirst("feed/".count)) ?? -1
                    candidates = entries.filter { $0.feedID == feedID }
                } else if excludesRead {
                    candidates = entries.filter { !$0.read }
                } else {
                    candidates = entries
                }
                candidates.sort { $0.published > $1.published }
                let page = Array(candidates.dropFirst(offset).prefix(limit))
                let nextOffset = offset + page.count
                let continuation: String? = nextOffset < candidates.count ? String(nextOffset) : nil
                let refs = page.map { ["id": Self.longFormID($0.id)] }
                lock.unlock()

                var payload: [String: Any] = ["itemRefs": refs]
                if let continuation { payload["continuation"] = continuation }
                return try response(200, payload)
            }

            if path.hasSuffix("/reader/api/0/stream/items/contents"), method == "POST" {
                let form = Self.formValues(body)
                lock.lock(); contentsBodies.append(body); lock.unlock()
                guard form["T"]?.first == authToken else {
                    return try response(401, ["error": "missing T"])
                }
                let requestedIDs = (form["i"] ?? []).compactMap(Self.parseItemID)

                lock.lock()
                let feedByID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
                let matched = entries.filter { requestedIDs.contains($0.id) }
                let items: [[String: Any]] = matched.map { entry in
                    var categories = ["user/-/state/com.google/reading-list"]
                    if let title = feedByID[entry.feedID]?.categoryTitle {
                        categories.append("user/1/label/\(title)")
                    }
                    if entry.read { categories.append("user/-/state/com.google/read") }
                    if entry.starred { categories.append("user/-/state/com.google/starred") }
                    return [
                        "id": Self.longFormID(entry.id),
                        "title": entry.title,
                        "published": entry.published,
                        "updated": entry.published,
                        "categories": categories,
                        "origin": ["streamId": "feed/\(entry.feedID)", "title": feedByID[entry.feedID]?.title ?? "", "htmlUrl": "https://example.com"],
                        "alternate": [["href": "https://example.com/\(entry.id)", "type": "text/html"]],
                        "summary": ["content": "<p>summary \(entry.id)</p>"],
                        "content": ["content": "<p>content \(entry.id)</p>"]
                    ]
                }
                lock.unlock()
                return try response(200, [
                    "direction": "ltr",
                    "id": "user/-/state/com.google/reading-list",
                    "title": "Reading List",
                    "updated": 1_700_000_000,
                    "items": items
                ])
            }

            if path.hasSuffix("/reader/api/0/edit-tag"), method == "POST" {
                let form = Self.formValues(body)
                lock.lock(); editTagBodies.append(body); lock.unlock()
                guard form["T"]?.first == authToken else {
                    return try response(401, ["error": "missing T"])
                }
                let ids = (form["i"] ?? []).compactMap(Self.parseItemID)
                let addRead = (form["a"] ?? []).contains { $0.hasSuffix("/state/com.google/read") }
                let addKeptUnread = (form["a"] ?? []).contains { $0.hasSuffix("/state/com.google/kept-unread") }
                let removeRead = (form["r"] ?? []).contains { $0.hasSuffix("/state/com.google/read") }
                let addStarred = (form["a"] ?? []).contains { $0.hasSuffix("/state/com.google/starred") }
                let removeStarred = (form["r"] ?? []).contains { $0.hasSuffix("/state/com.google/starred") }
                lock.lock()
                for index in entries.indices where ids.contains(entries[index].id) {
                    if addRead { entries[index].read = true }
                    if addKeptUnread || removeRead { entries[index].read = false }
                    if addStarred { entries[index].starred = true }
                    if removeStarred { entries[index].starred = false }
                }
                lock.unlock()
                return text(200, "OK")
            }

            if path.hasSuffix("/reader/api/0/disable-tag"), method == "POST" {
                let form = Self.formValues(body)
                lock.lock(); disableTagBodies.append(body); lock.unlock()
                guard form["T"]?.first == authToken else {
                    return try response(401, ["error": "missing T"])
                }
                if let streamID = form["s"]?.first, let title = streamID.components(separatedBy: "/label/").last {
                    lock.lock()
                    // Miniflux 语义：移除分类并把订阅归入剩余分类（至少保留一个分类时为 nil）。
                    for index in feeds.indices where feeds[index].categoryTitle == title {
                        feeds[index].categoryTitle = nil
                    }
                    lock.unlock()
                }
                return text(200, "OK")
            }

            if path.hasSuffix("/reader/api/0/subscription/quickadd"), method == "POST" {
                let form = Self.formValues(body)
                lock.lock(); quickAddBodies.append(body); lock.unlock()
                guard form["T"]?.first == authToken else {
                    return try response(401, ["error": "missing T"])
                }
                lock.lock()
                if !feeds.contains(where: { $0.id == 30 }) {
                    feeds.append(Feed(id: 30, title: "Quick Feed", url: form["quickadd"]?.first ?? "", categoryTitle: nil))
                }
                lock.unlock()
                return try response(200, ["numResults": 1, "streamId": "feed/30", "streamName": "Quick Feed"])
            }

            if path.hasSuffix("/reader/api/0/subscription/edit"), method == "POST" {
                let form = Self.formValues(body)
                lock.lock(); subscriptionEditBodies.append(body); lock.unlock()
                guard form["T"]?.first == authToken else {
                    return try response(401, ["error": "missing T"])
                }
                if form["ac"]?.first == "unsubscribe" {
                    lock.lock()
                    if let streamID = form["s"]?.first, let feedID = Int64(streamID.dropFirst("feed/".count)) {
                        feeds.removeAll { $0.id == feedID }
                        entries.removeAll { $0.feedID == feedID }
                    }
                    lock.unlock()
                }
                return text(200, "OK")
            }

            throw URLError(.badURL)
        }

        // MARK: Helpers

        static func formValues(_ body: String) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for pair in body.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[0]
                let value = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]
                result[key, default: []].append(value)
            }
            return result
        }

        static func parseItemID(_ raw: String) -> Int64? {
            let prefix = "tag:google.com,2005:reader/item/"
            if raw.hasPrefix(prefix) {
                return Int64(raw.dropFirst(prefix.count), radix: 16)
            }
            if raw.count == 16, let value = Int64(raw, radix: 16) {
                return value
            }
            return Int64(raw)
        }
    }

    // MARK: - Test Fixtures

    private var tempDir: URL!
    private var sqliteURL: URL!
    private var database: LibraryDatabase!
    private var mockSession: URLSession!
    private var credentialStore: InMemoryCredentialStore!

    private func makeServer() -> MockMinifluxGReaderServer {
        MockMinifluxGReaderServer(
            feeds: [
                .init(id: 10, title: "Alpha Feed", url: "https://alpha.example.com/rss", categoryTitle: "Alpha"),
                .init(id: 20, title: "Beta Feed", url: "https://beta.example.com/rss", categoryTitle: nil)
            ],
            entries: [
                .init(id: 12345, feedID: 10, title: "Alpha Read Article", published: 1_700_000_100, read: true, starred: false),
                .init(id: 67890, feedID: 20, title: "Beta Unread Article", published: 1_700_000_200, read: false, starred: true)
            ]
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssMinifluxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sqliteURL = tempDir.appendingPathComponent("library.sqlite")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockFreshRSSURLProtocol.self]
        mockSession = URLSession(configuration: config)

        credentialStore = InMemoryCredentialStore()
    }

    override func tearDownWithError() throws {
        MockFreshRSSURLProtocol.setHandler(nil)
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore() -> AppStore {
        AppStore(
            databaseURL: sqliteURL,
            persistenceURL: tempDir.appendingPathComponent("legacy.json"),
            credentialStore: credentialStore,
            customSession: mockSession
        )
    }

    // MARK: - Tests

    @MainActor
    func testMinifluxAddAccountAndInitialSync() async throws {
        let server = makeServer()
        MockFreshRSSURLProtocol.setHandler { try server.handle($0) }

        let store = makeStore()
        let account = try await store.addReaderAccount(
            accountType: .miniflux,
            endpointURLText: "https://miniflux.example.com/",
            username: server.username,
            password: server.password,
            displayName: "Miniflux",
            customSession: mockSession
        )

        XCTAssertEqual(account.type, AccountType.miniflux.rawValue)
        XCTAssertEqual(account.endpointURL, "https://miniflux.example.com")
        XCTAssertTrue(server.loginBodies.contains { $0.contains("Email=miniflux_user") && $0.contains("Passwd=miniflux_pwd") })

        // 正文 POST 必须携带 write token（Miniflux 所有 POST 的硬性要求）
        XCTAssertFalse(server.contentsBodies.isEmpty, "初始同步必须按 ID 拉取正文")
        for body in server.contentsBodies {
            XCTAssertTrue(body.contains("T="), "Miniflux 正文 POST 必须带 T，实际: \(body)")
        }

        let database = store.libraryDatabase

        // 分类：Alpha（订阅分类）+ Empty（tag/list 空分类）都必须存在
        let folders = try database.read { db in
            try FolderRecord.filter(Column("account_id") == account.id && Column("is_deleted") == false).fetchAll(db)
        }
        XCTAssertEqual(Set(folders.map(\.name)), Set(["Alpha", "Empty"]))
        XCTAssertEqual(Set(folders.compactMap(\.externalID)), Set(["user/1/label/Alpha", "user/1/label/Empty"]))

        // 订阅
        let feeds = try database.read { db in
            try FeedRecord.filter(Column("account_id") == account.id && Column("is_deleted") == false).fetchAll(db)
        }
        XCTAssertEqual(Set(feeds.compactMap(\.externalID)), Set(["feed/10", "feed/20"]))

        // 条目：保存 long-form 远端身份，并带正文
        let items = try database.read { db in
            try ItemRecord.filter(Column("account_id") == account.id).fetchAll(db)
        }
        XCTAssertEqual(items.count, 2)
        let expectedIDs = Set([
            MockMinifluxGReaderServer.longFormID(12345),
            MockMinifluxGReaderServer.longFormID(67890)
        ])
        XCTAssertEqual(Set(items.compactMap(\.externalID)), expectedIDs)
        let articleCount = try database.read { db in
            try ArticleRecord.filter(Column("item_id") == items[0].id || Column("item_id") == items[1].id).fetchCount(db)
        }
        XCTAssertEqual(articleCount, 2)

        // 状态：12345 已读，67890 未读 + 星标
        let readItem = items.first { $0.externalID == MockMinifluxGReaderServer.longFormID(12345) }!
        let unreadItem = items.first { $0.externalID == MockMinifluxGReaderServer.longFormID(67890) }!
        let readState = try database.read { db in try ArticleStateRecord.filter(Column("item_id") == readItem.id).fetchOne(db) }
        let unreadState = try database.read { db in try ArticleStateRecord.filter(Column("item_id") == unreadItem.id).fetchOne(db) }
        XCTAssertEqual(readState?.isRead, true)
        XCTAssertEqual(unreadState?.isRead, false)
        XCTAssertEqual(unreadState?.isStarred, true)
    }

    func testMinifluxStreamIDsPaginationFollowsContinuation() async throws {
        let server = makeServer()
        MockFreshRSSURLProtocol.setHandler { try server.handle($0) }

        let accountID = "miniflux-pagination"
        try credentialStore.savePassword(server.password, for: .miniflux, accountID: accountID)
        let client = ReaderAPIClient(
            endpointURL: URL(string: "https://miniflux.example.com")!,
            username: server.username,
            accountID: accountID,
            credentialStore: credentialStore,
            session: mockSession,
            variant: .miniflux
        )

        let ids = try await client.fetchAllReadingListItemIDs(pageSize: 1)
        XCTAssertEqual(ids, [
            MockMinifluxGReaderServer.longFormID(67890),
            MockMinifluxGReaderServer.longFormID(12345)
        ])
        XCTAssertTrue(server.streamIDQueries.contains { $0.contains("c=1") }, "必须使用 continuation 翻页")
    }

    @MainActor
    func testMinifluxMarkReadPushUsesWriteTokenAndLongFormID() async throws {
        let server = makeServer()
        MockFreshRSSURLProtocol.setHandler { try server.handle($0) }

        let store = makeStore()
        let account = try await store.addReaderAccount(
            accountType: .miniflux,
            endpointURLText: "https://miniflux.example.com",
            username: server.username,
            password: server.password,
            customSession: mockSession
        )

        let item = try store.libraryDatabase.read { db in
            try ItemRecord.filter(
                Column("account_id") == account.id &&
                Column("external_id") == MockMinifluxGReaderServer.longFormID(12345)
            ).fetchOne(db)
        }
        let itemID = try XCTUnwrap(item?.id)

        store.markRead(entryID: itemID, read: false)
        await store.syncAccount(accountID: account.id)

        let editBody = try XCTUnwrap(server.editTagBodies.last)
        XCTAssertTrue(editBody.contains("T="), "edit-tag 必须携带 write token")
        XCTAssertTrue(editBody.contains("i=tag:google.com,2005:reader/item/0000000000003039"), "必须发送 long-form item ID，实际: \(editBody)")
        XCTAssertTrue(editBody.contains("a=user/-/state/com.google/kept-unread"))
        XCTAssertTrue(editBody.contains("r=user/-/state/com.google/read"))
    }

    @MainActor
    func testMinifluxDeleteFolderUsesDisableTagAndKeepsFeeds() async throws {
        let server = makeServer()
        MockFreshRSSURLProtocol.setHandler { try server.handle($0) }

        let store = makeStore()
        let account = try await store.addReaderAccount(
            accountType: .miniflux,
            endpointURLText: "https://miniflux.example.com",
            username: server.username,
            password: server.password,
            customSession: mockSession
        )

        await store.deleteFolderAsync("Alpha", accountID: account.id)

        XCTAssertEqual(server.disableTagBodies.count, 1)
        XCTAssertTrue(server.disableTagBodies[0].contains("s=user/1/label/Alpha"))
        XCTAssertFalse(
            server.subscriptionEditBodies.contains { $0.contains("ac=unsubscribe") },
            "Miniflux 删除分类绝不能退订订阅"
        )

        let feeds = try store.libraryDatabase.read { db in
            try FeedRecord.filter(Column("account_id") == account.id && Column("is_deleted") == false).fetchAll(db)
        }
        XCTAssertEqual(Set(feeds.compactMap(\.externalID)), Set(["feed/10", "feed/20"]))

        let folders = try store.libraryDatabase.read { db in
            try FolderRecord.filter(Column("account_id") == account.id && Column("is_deleted") == false).fetchAll(db)
        }
        XCTAssertEqual(Set(folders.map(\.name)), Set(["Empty"]))
    }

    func testMinifluxAddFolderIsUnsupported() async throws {
        let database = try LibraryDatabase(databaseURL: tempDir.appendingPathComponent("miniflux-folder.sqlite"))
        let accountID = "miniflux-addfolder"
        try credentialStore.savePassword("pwd", for: .miniflux, accountID: accountID)
        let provider = ReaderAccountProvider(
            accountID: accountID,
            endpointURL: URL(string: "https://miniflux.example.com")!,
            username: "miniflux_user",
            variant: .miniflux,
            database: database,
            credentialStore: credentialStore,
            session: mockSession
        )

        do {
            _ = try await provider.addFolder(name: "Empty Category")
            XCTFail("Miniflux 必须拒绝创建空分类")
        } catch let error as ReaderAPIError {
            guard case .unsupportedOperation = error else {
                XCTFail("预期 unsupportedOperation，实际 \(error)")
                return
            }
        }
    }

    @MainActor
    func testMinifluxAddFeedUsesServerReturnedStreamID() async throws {
        let server = makeServer()
        MockFreshRSSURLProtocol.setHandler { try server.handle($0) }

        let store = makeStore()
        let account = try await store.addReaderAccount(
            accountType: .miniflux,
            endpointURLText: "https://miniflux.example.com",
            username: server.username,
            password: server.password,
            customSession: mockSession
        )

        let added = await store.addFeed(urlText: "https://quick.example.com/rss", targetAccountID: account.id)
        let feed = try XCTUnwrap(added)

        XCTAssertEqual(feed.folder, nil)
        let recorded = try store.libraryDatabase.read { db in
            try FeedRecord.filter(Column("id") == feed.id.uuidString).fetchOne(db)
        }
        XCTAssertEqual(recorded?.externalID, "feed/30", "必须使用服务端返回的 feed/<id>，不得伪造 feed/<url>")
        XCTAssertTrue(server.quickAddBodies.contains { $0.contains("T=") })
    }

    @MainActor
    func testMinifluxRemoteStateChangesArePulledOnRefresh() async throws {
        let server = makeServer()
        MockFreshRSSURLProtocol.setHandler { try server.handle($0) }

        let store = makeStore()
        let account = try await store.addReaderAccount(
            accountType: .miniflux,
            endpointURLText: "https://miniflux.example.com",
            username: server.username,
            password: server.password,
            customSession: mockSession
        )

        // 模拟 Miniflux 网页端把 12345 标为未读 + 星标
        server.setEntryState(id: 12345, read: false, starred: true)
        await store.syncAccount(accountID: account.id)

        let state = try store.libraryDatabase.read { db in
            try ArticleStateRecord.filter(
                Column("item_id") == "\(account.id)::\(MockMinifluxGReaderServer.longFormID(12345))"
            ).fetchOne(db)
        }
        XCTAssertEqual(state?.isRead, false, "远端取消已读后，刷新必须回写到本地")
        XCTAssertEqual(state?.isStarred, true, "远端新增星标后，刷新必须回写到本地")
    }

    @MainActor
    func testMinifluxAccountDuplicateRejected() async throws {
        let server = makeServer()
        MockFreshRSSURLProtocol.setHandler { try server.handle($0) }

        let store = makeStore()
        _ = try await store.addReaderAccount(
            accountType: .miniflux,
            endpointURLText: "https://miniflux.example.com",
            username: server.username,
            password: server.password,
            customSession: mockSession
        )

        do {
            _ = try await store.addReaderAccount(
                accountType: .miniflux,
                endpointURLText: "https://miniflux.example.com/reader/api/0",
                username: server.username,
                password: server.password,
                customSession: mockSession
            )
            XCTFail("同一 Miniflux 服务与用户名必须拒绝重复添加")
        } catch let error as ReaderAPIError {
            guard case .accountAlreadyExists = error else {
                XCTFail("预期 accountAlreadyExists，实际 \(error)")
                return
            }
        }
    }
}
