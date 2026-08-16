import Foundation

/// FreshRSS / Google Reader API HTTP 客户端。
///
/// 遵循 Architecture Contract (Section 16 / INV-11)。
/// 负责请求构建、URL 规范化、认证头注入、状态码映射、JSON 解码与写回标记。
/// 本类不依赖 SwiftUI、AppStore 或数据库模型。
public actor ReaderAPIClient {
    public let endpointURL: URL
    public let username: String
    public let accountID: String
    private let credentialStore: CredentialStore
    private let session: URLSession
    private let authenticator: ReaderAPIAuthenticator

    public init(
        endpointURL: URL,
        username: String,
        accountID: String,
        credentialStore: CredentialStore,
        session: URLSession = .shared,
        authenticator: ReaderAPIAuthenticator = ReaderAPIAuthenticator()
    ) {
        self.endpointURL = endpointURL
        self.username = username
        self.accountID = accountID
        self.credentialStore = credentialStore
        self.session = session
        self.authenticator = authenticator
    }

    // MARK: - Canonicalization

    /// 统一规范化用户输入的 FreshRSS 地址为正确的 Google Reader API 根地址。
    public static func canonicalBaseURL(for rawURL: URL) -> URL {
        var urlString = rawURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while urlString.hasSuffix("/") {
            urlString.removeLast()
        }

        if urlString.hasSuffix("/api/greader.php") || urlString.hasSuffix("/p/api/greader.php") {
            return URL(string: urlString) ?? rawURL
        }

        let canonicalString = "\(urlString)/api/greader.php"
        return URL(string: canonicalString) ?? rawURL
    }

    public var canonicalBaseURL: URL {
        Self.canonicalBaseURL(for: endpointURL)
    }

    // MARK: - Authentication Helper

    private func getPassword() throws -> String {
        guard let password = try credentialStore.freshRSSPassword(accountID: accountID), !password.isEmpty else {
            throw ReaderAPIError.invalidCredentials
        }
        return password
    }

    public func validateCredentials() async throws {
        let password = try getPassword()
        _ = try await authenticator.login(
            endpointURL: endpointURL,
            username: username,
            password: password,
            session: session
        )
    }

    // MARK: - Authenticated Request Wrapper

    private func performRequest(
        _ requestBuilder: (String) -> URLRequest,
        allowRetryOnAuthError: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let password = try getPassword()

        let authToken: String
        if let current = await authenticator.currentAuthToken() {
            authToken = current
        } else {
            authToken = try await authenticator.login(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session
            )
        }

        var request = requestBuilder(authToken)
        if request.timeoutInterval <= 0 {
            request.timeoutInterval = 30
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderAPIError.networkError("Invalid HTTP response")
        }

        if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && allowRetryOnAuthError {
            // 登录会话过期，重试一次
            await authenticator.invalidateAuth()
            let newAuth = try await authenticator.login(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session
            )
            let retryReq = requestBuilder(newAuth)
            let (retryData, retryResp) = try await session.data(for: retryReq)
            guard let retryHTTP = retryResp as? HTTPURLResponse else {
                throw ReaderAPIError.networkError("Invalid HTTP response")
            }
            if retryHTTP.statusCode == 401 || retryHTTP.statusCode == 403 {
                throw ReaderAPIError.invalidCredentials
            }
            guard (200...299).contains(retryHTTP.statusCode) else {
                let snippet = String(data: retryData.prefix(200), encoding: .utf8)
                throw ReaderAPIError.httpError(statusCode: retryHTTP.statusCode, bodySnippet: snippet)
            }
            return (retryData, retryHTTP)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ReaderAPIError.invalidCredentials
            }
            let snippet = String(data: data.prefix(200), encoding: .utf8)
            throw ReaderAPIError.httpError(statusCode: httpResponse.statusCode, bodySnippet: snippet)
        }

        return (data, httpResponse)
    }

    // MARK: - Subscriptions & Folders

    /// 获取远端订阅源列表 (`/reader/api/0/subscription/list`)
    public func fetchSubscriptions() async throws -> [ReaderAPISubscription] {
        let url = canonicalBaseURL
            .appendingPathComponent("reader/api/0/subscription/list")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "output", value: "json")]

        guard let requestURL = components?.url else {
            throw ReaderAPIError.invalidEndpointURL(url.absoluteString)
        }

        let (data, _) = try await performRequest { authToken in
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            return request
        }

        do {
            let decoded = try JSONDecoder().decode(ReaderAPISubscriptionListResponse.self, from: data)
            return decoded.subscriptions
        } catch {
            throw ReaderAPIError.decodingError("subscription/list: \(error.localizedDescription)")
        }
    }

    /// 获取远端标签/分类列表 (`/reader/api/0/tag/list`)
    public func fetchTags() async throws -> [ReaderAPITag] {
        let url = canonicalBaseURL
            .appendingPathComponent("reader/api/0/tag/list")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "output", value: "json")]

        guard let requestURL = components?.url else {
            throw ReaderAPIError.invalidEndpointURL(url.absoluteString)
        }

        let (data, _) = try await performRequest { authToken in
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            return request
        }

        do {
            let decoded = try JSONDecoder().decode(ReaderAPITagListResponse.self, from: data)
            return decoded.tags
        } catch {
            throw ReaderAPIError.decodingError("tag/list: \(error.localizedDescription)")
        }
    }

    // MARK: - Stream Item IDs (Unread / Starred)

    // MARK: - Stream Item IDs (Unread / Starred)

    /// 单页拉取未读文章 ID 集合及 continuation token
    public func fetchUnreadItemIDsPage(
        continuation: String? = nil,
        limit: Int = 10000
    ) async throws -> (itemIDs: [String], continuation: String?) {
        let url = canonicalBaseURL
            .appendingPathComponent("reader/api/0/stream/items/ids")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "s", value: "user/-/state/com.google/reading-list"),
            URLQueryItem(name: "xt", value: "user/-/state/com.google/read"),
            URLQueryItem(name: "n", value: String(limit)),
            URLQueryItem(name: "output", value: "json")
        ]
        if let continuation, !continuation.isEmpty {
            queryItems.append(URLQueryItem(name: "c", value: continuation))
        }
        components?.queryItems = queryItems

        guard let requestURL = components?.url else {
            throw ReaderAPIError.invalidEndpointURL(url.absoluteString)
        }

        let (data, _) = try await performRequest { authToken in
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            return request
        }

        do {
            let decoded = try JSONDecoder().decode(ReaderAPIStreamItemIDsResponse.self, from: data)
            let ids = decoded.itemRefs?.map(\.id) ?? []
            return (ids, decoded.continuation)
        } catch {
            throw ReaderAPIError.decodingError("unread stream/items/ids: \(error.localizedDescription)")
        }
    }

    /// 完整拉取未读文章 ID 集合（支持 continuation 多页翻页，显式标记完整性）
    public func fetchAllUnreadItemIDs(maxTotal: Int = 50000) async throws -> ReaderItemIDSet {
        var allIDs: [String] = []
        var nextContinuation: String? = nil
        var isExhausted = false

        repeat {
            let (pageIDs, continuation) = try await fetchUnreadItemIDsPage(continuation: nextContinuation, limit: 10000)
            allIDs.append(contentsOf: pageIDs)

            if let continuation, !continuation.isEmpty, continuation != nextContinuation {
                if allIDs.count < maxTotal {
                    nextContinuation = continuation
                } else {
                    // 达到了最大上限但仍有后续数据，标记为不完整
                    nextContinuation = nil
                    isExhausted = false
                }
            } else {
                nextContinuation = nil
                isExhausted = true
            }
        } while nextContinuation != nil

        return ReaderItemIDSet(ids: Set(allIDs), isComplete: isExhausted)
    }

    /// 兼容旧接口：拉取未读文章 ID
    public func fetchUnreadItemIDs(limit: Int = 10000) async throws -> [String] {
        let set = try await fetchAllUnreadItemIDs(maxTotal: limit)
        return Array(set.ids)
    }

    /// 单页拉取星标/收藏文章 ID 集合及 continuation token
    public func fetchStarredItemIDsPage(
        continuation: String? = nil,
        limit: Int = 10000
    ) async throws -> (itemIDs: [String], continuation: String?) {
        let url = canonicalBaseURL
            .appendingPathComponent("reader/api/0/stream/items/ids")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "s", value: "user/-/state/com.google/starred"),
            URLQueryItem(name: "n", value: String(limit)),
            URLQueryItem(name: "output", value: "json")
        ]
        if let continuation, !continuation.isEmpty {
            queryItems.append(URLQueryItem(name: "c", value: continuation))
        }
        components?.queryItems = queryItems

        guard let requestURL = components?.url else {
            throw ReaderAPIError.invalidEndpointURL(url.absoluteString)
        }

        let (data, _) = try await performRequest { authToken in
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            return request
        }

        do {
            let decoded = try JSONDecoder().decode(ReaderAPIStreamItemIDsResponse.self, from: data)
            let ids = decoded.itemRefs?.map(\.id) ?? []
            return (ids, decoded.continuation)
        } catch {
            throw ReaderAPIError.decodingError("starred stream/items/ids: \(error.localizedDescription)")
        }
    }

    /// 完整拉取星标文章 ID 集合（支持 continuation 多页翻页，显式标记完整性）
    public func fetchAllStarredItemIDs(maxTotal: Int = 50000) async throws -> ReaderItemIDSet {
        var allIDs: [String] = []
        var nextContinuation: String? = nil
        var isExhausted = false

        repeat {
            let (pageIDs, continuation) = try await fetchStarredItemIDsPage(continuation: nextContinuation, limit: 10000)
            allIDs.append(contentsOf: pageIDs)

            if let continuation, !continuation.isEmpty, continuation != nextContinuation {
                if allIDs.count < maxTotal {
                    nextContinuation = continuation
                } else {
                    // 达到了最大上限但仍有后续数据，标记为不完整
                    nextContinuation = nil
                    isExhausted = false
                }
            } else {
                nextContinuation = nil
                isExhausted = true
            }
        } while nextContinuation != nil

        return ReaderItemIDSet(ids: Set(allIDs), isComplete: isExhausted)
    }

    /// 兼容旧接口：拉取星标文章 ID
    public func fetchStarredItemIDs(limit: Int = 10000) async throws -> [String] {
        let set = try await fetchAllStarredItemIDs(maxTotal: limit)
        return Array(set.ids)
    }

    // MARK: - Stream Item Contents

    /// 批量拉取指定 item IDs 的完整文章内容 (`/reader/api/0/stream/items/contents`)
    public func fetchItemContents(itemIDs: [String]) async throws -> [ReaderAPIStreamItem] {
        guard !itemIDs.isEmpty else { return [] }

        // 分批获取（每批最多 50 篇，避免 URL / POST body 过大）
        let batchSize = 50
        var allItems: [ReaderAPIStreamItem] = []

        for start in stride(from: 0, to: itemIDs.count, by: batchSize) {
            let end = min(start + batchSize, itemIDs.count)
            let chunk = Array(itemIDs[start..<end])

            let url = canonicalBaseURL
                .appendingPathComponent("reader/api/0/stream/items/contents")

            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "output", value: "json")]

            guard let requestURL = components?.url else {
                throw ReaderAPIError.invalidEndpointURL(url.absoluteString)
            }

            let (data, _) = try await performRequest { authToken in
                var request = URLRequest(url: requestURL)
                request.httpMethod = "POST"
                request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                let queryItems: [URLQueryItem] = chunk.map { URLQueryItem(name: "i", value: $0) }
                var bodyComponents = URLComponents()
                bodyComponents.queryItems = queryItems
                request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
                return request
            }

            do {
                let decoded = try JSONDecoder().decode(ReaderAPIStreamContentsResponse.self, from: data)
                allItems.append(contentsOf: decoded.items)
            } catch {
                throw ReaderAPIError.decodingError("stream/items/contents: \(error.localizedDescription)")
            }
        }

        return allItems
    }

    /// 拉取最近文章流（有界拉取，用于首次初始化同步）
    public func fetchRecentStreamContents(limit: Int = 200) async throws -> [ReaderAPIStreamItem] {
        let url = canonicalBaseURL
            .appendingPathComponent("reader/api/0/stream/contents/user/-/state/com.google/reading-list")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "n", value: String(limit)),
            URLQueryItem(name: "output", value: "json")
        ]

        guard let requestURL = components?.url else {
            throw ReaderAPIError.invalidEndpointURL(url.absoluteString)
        }

        let (data, _) = try await performRequest { authToken in
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            return request
        }

        do {
            let decoded = try JSONDecoder().decode(ReaderAPIStreamContentsResponse.self, from: data)
            return decoded.items
        } catch {
            throw ReaderAPIError.decodingError("stream/contents: \(error.localizedDescription)")
        }
    }

    // MARK: - State Mutations (edit-tag)

    /// 修改文章已读状态 (`/reader/api/0/edit-tag`)
    public func markRead(itemIDs: [String], isRead: Bool) async throws {
        guard !itemIDs.isEmpty else { return }

        let addTag = isRead ? "user/-/state/com.google/read" : "user/-/state/com.google/kept-unread"
        let removeTag = isRead ? nil : "user/-/state/com.google/read"

        try await editTags(itemIDs: itemIDs, addTag: addTag, removeTag: removeTag)
    }

    /// 修改文章星标/收藏状态 (`/reader/api/0/edit-tag`)
    public func markStarred(itemIDs: [String], isStarred: Bool) async throws {
        guard !itemIDs.isEmpty else { return }

        let addTag = isStarred ? "user/-/state/com.google/starred" : nil
        let removeTag = isStarred ? nil : "user/-/state/com.google/starred"

        try await editTags(itemIDs: itemIDs, addTag: addTag, removeTag: removeTag)
    }

    private func editTags(itemIDs: [String], addTag: String?, removeTag: String?) async throws {
        let batchSize = 50
        for start in stride(from: 0, to: itemIDs.count, by: batchSize) {
            let end = min(start + batchSize, itemIDs.count)
            let chunk = Array(itemIDs[start..<end])

            let url = canonicalBaseURL
                .appendingPathComponent("reader/api/0/edit-tag")

            let password = try getPassword()
            let writeToken = try await authenticator.ensureWriteToken(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session
            )

            let (data, response) = try await performRequest { authToken in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                var queryItems: [URLQueryItem] = chunk.map { URLQueryItem(name: "i", value: $0) }
                if let addTag {
                    queryItems.append(URLQueryItem(name: "a", value: addTag))
                }
                if let removeTag {
                    queryItems.append(URLQueryItem(name: "r", value: removeTag))
                }
                queryItems.append(URLQueryItem(name: "T", value: writeToken))

                var bodyComponents = URLComponents()
                bodyComponents.queryItems = queryItems
                request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
                return request
            }

            guard response.statusCode == 200 else {
                let snippet = String(data: data.prefix(200), encoding: .utf8)
                throw ReaderAPIError.httpError(statusCode: response.statusCode, bodySnippet: snippet)
            }
        }
    }
}
