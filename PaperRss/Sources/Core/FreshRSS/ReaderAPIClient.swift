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
    public let variant: ReaderServiceVariant
    private let credentialStore: CredentialStore
    private let session: URLSession
    private let authenticator: ReaderAPIAuthenticator

    public init(
        endpointURL: URL,
        username: String,
        accountID: String,
        credentialStore: CredentialStore,
        session: URLSession = .shared,
        authenticator: ReaderAPIAuthenticator = ReaderAPIAuthenticator(),
        variant: ReaderServiceVariant = .freshRSS
    ) {
        self.endpointURL = endpointURL
        self.username = username
        self.accountID = accountID
        self.variant = variant
        self.credentialStore = credentialStore
        self.session = session
        self.authenticator = authenticator
    }

    // MARK: - Canonicalization

    /// 统一规范化用户输入的服务地址为正确的协议根地址。
    ///
    /// - FreshRSS：`<base>/api/greader.php`；
    /// - Miniflux：部署根地址，不追加 PHP 路径。
    public static func canonicalBaseURL(for rawURL: URL, variant: ReaderServiceVariant = .freshRSS) -> URL {
        ReaderServiceVariant.canonicalBaseURL(for: rawURL, variant: variant)
    }

    public var canonicalBaseURL: URL {
        Self.canonicalBaseURL(for: endpointURL, variant: variant)
    }

    // MARK: - Authentication Helper

    private func getPassword() throws -> String {
        guard let password = try credentialStore.password(for: variant.credentialScope, accountID: accountID), !password.isEmpty else {
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
            session: session,
            variant: variant
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
                session: session,
                variant: variant
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
                session: session,
                variant: variant
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

    /// 带 Write Token 的 POST 请求包装器。
    ///
    /// Miniflux 要求所有 POST（包括只读的 `stream/items/contents`）在表单中携带 `T`；
    /// 401/403 重试时会同时失效 Auth Token 与 Write Token，并重新构造包含 `T` 的完整请求体，
    /// 避免复用过期 write token 导致持续 401。
    private func performWriteRequest(
        _ requestBuilder: @Sendable (String, String) -> URLRequest,
        allowRetryOnAuthError: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let password = try getPassword()

        func makeRequest(authToken: String, writeToken: String) -> URLRequest {
            var request = requestBuilder(authToken, writeToken)
            if request.timeoutInterval <= 0 {
                request.timeoutInterval = 30
            }
            return request
        }

        let authToken: String
        if let current = await authenticator.currentAuthToken() {
            authToken = current
        } else {
            authToken = try await authenticator.login(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session,
                variant: variant
            )
        }
        let writeToken = try await authenticator.ensureWriteToken(
            endpointURL: endpointURL,
            username: username,
            password: password,
            session: session,
            variant: variant
        )

        let (data, response) = try await session.data(for: makeRequest(authToken: authToken, writeToken: writeToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderAPIError.networkError("Invalid HTTP response")
        }

        if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) && allowRetryOnAuthError {
            // Auth Token 与 Write Token 一并失效，重新登录并重建请求体
            await authenticator.invalidateAuth()
            let newAuth = try await authenticator.login(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session,
                variant: variant
            )
            let newWriteToken = try await authenticator.ensureWriteToken(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session,
                variant: variant
            )
            let retryReq = makeRequest(authToken: newAuth, writeToken: newWriteToken)
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

    /// 读取本轮文章流的 ID 快照，用于下载前确定真实工作量；首次仅取最近 200 篇。
    public func fetchRefreshStreamItemIDs(initialSync: Bool, sinceTimestamp: TimeInterval?) async throws -> Set<String> {
        var ids = Set<String>()
        var continuation: String?
        var visited = Set<String>()
        repeat {
            try Task.checkCancellation()
            let url = canonicalBaseURL.appendingPathComponent("reader/api/0/stream/items/ids")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "s", value: "user/-/state/com.google/reading-list"),
                URLQueryItem(name: "n", value: initialSync ? "200" : "10000"),
                URLQueryItem(name: "output", value: "json")
            ]
            if !initialSync, let sinceTimestamp {
                query.append(URLQueryItem(name: "ot", value: String(Int(max(0, sinceTimestamp - 300)))))
            }
            if let continuation { query.append(URLQueryItem(name: "c", value: continuation)) }
            components.queryItems = query
            let requestURL = components.url!
            let (data, _) = try await performRequest { token in
                var request = URLRequest(url: requestURL)
                request.setValue("GoogleLogin auth=\(token)", forHTTPHeaderField: "Authorization")
                return request
            }
            let page = try JSONDecoder().decode(ReaderAPIStreamItemIDsResponse.self, from: data)
            ids.formUnion(page.itemRefs?.map(\.id) ?? [])
            if initialSync { break }
            continuation = page.continuation.flatMap { $0.isEmpty ? nil : $0 }
            if let continuation, !visited.insert(continuation).inserted {
                throw ReaderAPIError.decodingError("Repeated stream ID continuation")
            }
        } while continuation != nil
        return ids
    }

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
    public func fetchAllUnreadItemIDs(maxTotal: Int = .max) async throws -> ReaderItemIDSet {
        var allIDs: [String] = []
        var nextContinuation: String? = nil
        var isExhausted = false
        var visited = Set<String>()

        repeat {
            try Task.checkCancellation()
            let (pageIDs, continuation) = try await fetchUnreadItemIDsPage(continuation: nextContinuation, limit: 10000)
            allIDs.append(contentsOf: pageIDs)

            if let continuation, !continuation.isEmpty {
                guard visited.insert(continuation).inserted else {
                    throw ReaderAPIError.decodingError("Repeated state ID continuation")
                }
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
    public func fetchAllStarredItemIDs(maxTotal: Int = .max) async throws -> ReaderItemIDSet {
        var allIDs: [String] = []
        var nextContinuation: String? = nil
        var isExhausted = false
        var visited = Set<String>()

        repeat {
            try Task.checkCancellation()
            let (pageIDs, continuation) = try await fetchStarredItemIDsPage(continuation: nextContinuation, limit: 10000)
            allIDs.append(contentsOf: pageIDs)

            if let continuation, !continuation.isEmpty {
                guard visited.insert(continuation).inserted else {
                    throw ReaderAPIError.decodingError("Repeated state ID continuation")
                }
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

    // MARK: - Reading List Enumeration (Miniflux-compatible)

    /// 全量枚举指定 stream 的文章 ID（按服务端返回顺序，跨页去重）。
    ///
    /// 不使用 `ot` 时间过滤：`ot` 按发布时间过滤而非服务端修改序列，
    /// 不能作为可靠增量游标；全量 ID 枚举成本低、无遗漏，正文按本地差集下载。
    public func fetchAllItemIDs(inStream streamID: String, pageSize: Int = 1000) async throws -> [String] {
        var orderedIDs: [String] = []
        var seenKeys = Set<String>()
        var continuation: String?
        var visitedContinuations = Set<String>()

        repeat {
            try Task.checkCancellation()

            let url = canonicalBaseURL
                .appendingPathComponent("reader/api/0/stream/items/ids")

            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var queryItems = [
                URLQueryItem(name: "s", value: streamID),
                URLQueryItem(name: "n", value: String(pageSize)),
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

            let page: ReaderAPIStreamItemIDsResponse
            do {
                page = try JSONDecoder().decode(ReaderAPIStreamItemIDsResponse.self, from: data)
            } catch {
                throw ReaderAPIError.decodingError("stream/items/ids [\(streamID)]: \(error.localizedDescription)")
            }

            for ref in page.itemRefs ?? [] {
                let key = ReaderItemIDCodec.canonicalComparisonKey(for: ref.id)
                guard !key.isEmpty else { continue }
                if seenKeys.insert(key).inserted {
                    orderedIDs.append(ref.id)
                }
            }

            continuation = page.continuation.flatMap { $0.isEmpty ? nil : $0 }
            if let continuation, !visitedContinuations.insert(continuation).inserted {
                throw ReaderAPIError.decodingError("Repeated stream continuation [\(streamID)]")
            }
        } while continuation != nil

        return orderedIDs
    }

    /// 全量枚举 reading-list 文章 ID。
    public func fetchAllReadingListItemIDs(pageSize: Int = 1000) async throws -> [String] {
        try await fetchAllItemIDs(inStream: "user/-/state/com.google/reading-list", pageSize: pageSize)
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

            @Sendable func makeRequest(requestURL: URL, chunk: [String], authToken: String, writeToken: String?) -> URLRequest {
                var request = URLRequest(url: requestURL)
                request.httpMethod = "POST"
                request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                var queryItems: [URLQueryItem] = chunk.map { URLQueryItem(name: "i", value: $0) }
                if let writeToken {
                    // Miniflux 对所有 POST（含只读的正文请求）强制要求表单 T 参数。
                    queryItems.append(URLQueryItem(name: "T", value: writeToken))
                }
                var bodyComponents = URLComponents()
                bodyComponents.queryItems = queryItems
                request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
                return request
            }

            let data: Data
            if variant == .miniflux {
                (data, _) = try await performWriteRequest { authToken, writeToken in
                    makeRequest(requestURL: requestURL, chunk: chunk, authToken: authToken, writeToken: writeToken)
                }
            } else {
                // FreshRSS 保持既有协议行为：正文 POST 不依赖 write token。
                (data, _) = try await performRequest { authToken in
                    makeRequest(requestURL: requestURL, chunk: chunk, authToken: authToken, writeToken: nil)
                }
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

    /// 单页拉取文章流内容 (`/reader/api/0/stream/contents/...`)
    public func fetchStreamContentsPage(
        streamID: String = "user/-/state/com.google/reading-list",
        continuation: String? = nil,
        limit: Int = 100,
        startTime: TimeInterval? = nil
    ) async throws -> (items: [ReaderAPIStreamItem], continuation: String?) {
        let streamPath = "reader/api/0/stream/contents/\(streamID)"
        let url = canonicalBaseURL.appendingPathComponent(streamPath)

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "n", value: String(limit)),
            URLQueryItem(name: "output", value: "json")
        ]
        if let continuation, !continuation.isEmpty {
            queryItems.append(URLQueryItem(name: "c", value: continuation))
        }
        if let startTime, startTime > 0 {
            queryItems.append(URLQueryItem(name: "ot", value: String(Int(startTime))))
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
            let decoded = try JSONDecoder().decode(ReaderAPIStreamContentsResponse.self, from: data)
            return (decoded.items, decoded.continuation)
        } catch {
            throw ReaderAPIError.decodingError("stream/contents: \(error.localizedDescription)")
        }
    }

    /// 遍历拉取指定时间戳之后的所有新文章内容（支持 continuation 分页循环直到追平时间边界或流结束）
    public func fetchIncrementalStreamContents(
        streamID: String = "user/-/state/com.google/reading-list",
        sinceTimestamp: TimeInterval? = nil,
        pageSize: Int = 100,
        maxTotal: Int = .max,
        knownLocalExternalIDs: Set<String>? = nil,
        onPage: (@Sendable ([ReaderAPIStreamItem]) async throws -> Void)? = nil
    ) async throws -> (items: [ReaderAPIStreamItem], reachedBoundary: Bool) {
        var allItems: [ReaderAPIStreamItem] = []
        var nextContinuation: String? = nil
        var reachedBoundary = false
        var visited = Set<String>()

        let cutoff = sinceTimestamp.map { max(0, $0 - 300) } // 5分钟重叠窗口

        while true {
            try Task.checkCancellation()
            let (pageItems, continuation) = try await fetchStreamContentsPage(
                streamID: streamID,
                continuation: nextContinuation,
                limit: pageSize,
                startTime: cutoff
            )
            try await onPage?(pageItems)
            allItems.append(contentsOf: pageItems)

            // FreshRSS 会按最近修改时间返回旧文章，不能用 published 或本地已存在来提前停止。
            guard let cont = continuation, !cont.isEmpty else {
                reachedBoundary = true
                break
            }
            guard visited.insert(cont).inserted else {
                throw ReaderAPIError.decodingError("Repeated stream continuation")
            }

            if allItems.count >= maxTotal {
                // 达到安全上限但 continuation 仍存在，属于未完成截断
                reachedBoundary = false
                break
            }

            nextContinuation = cont
        }

        return (allItems, reachedBoundary)
    }

    /// 拉取最近文章流（有界拉取，用于首次初始化同步）
    public func fetchRecentStreamContents(limit: Int = 200) async throws -> [ReaderAPIStreamItem] {
        let (items, _) = try await fetchStreamContentsPage(limit: limit)
        return items
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

            let (_, _) = try await performWriteRequest { authToken, writeToken in
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
        }
    }

    // MARK: - Subscription & Folder Management

    /// 快速新增订阅源 (`/reader/api/0/subscription/quickadd`)
    public func quickAddSubscription(url: URL) async throws -> ReaderAPIQuickAddResult {
        let quickAddURL = canonicalBaseURL.appendingPathComponent("reader/api/0/subscription/quickadd")

        let (data, _) = try await performWriteRequest { authToken, writeToken in
            var request = URLRequest(url: quickAddURL)
            request.httpMethod = "POST"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "T", value: writeToken),
                URLQueryItem(name: "quickadd", value: url.absoluteString)
            ]
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            return request
        }

        do {
            let result = try JSONDecoder().decode(ReaderAPIQuickAddResult.self, from: data)
            return result
        } catch {
            throw ReaderAPIError.decodingError("quickadd: \(error.localizedDescription)")
        }
    }

    /// 修改订阅源（添加/移除文件夹分类或修改标题） (`/reader/api/0/subscription/edit`)
    public func editSubscription(
        streamID: String,
        addFolderName: String? = nil,
        removeFolderName: String? = nil,
        title: String? = nil
    ) async throws {
        guard addFolderName != nil || removeFolderName != nil || title != nil else { return }

        let editURL = canonicalBaseURL.appendingPathComponent("reader/api/0/subscription/edit")

        let (_, _) = try await performWriteRequest { authToken, writeToken in
            var request = URLRequest(url: editURL)
            request.httpMethod = "POST"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            var queryItems = [
                URLQueryItem(name: "T", value: writeToken),
                URLQueryItem(name: "s", value: streamID),
                URLQueryItem(name: "ac", value: "edit")
            ]
            if let addFolderName, !addFolderName.isEmpty {
                queryItems.append(URLQueryItem(name: "a", value: "user/-/label/\(addFolderName)"))
            }
            if let removeFolderName, !removeFolderName.isEmpty {
                queryItems.append(URLQueryItem(name: "r", value: "user/-/label/\(removeFolderName)"))
            }
            if let title, !title.isEmpty {
                queryItems.append(URLQueryItem(name: "t", value: title))
            }

            var components = URLComponents()
            components.queryItems = queryItems
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            return request
        }
    }

    /// 退订订阅源 (`/reader/api/0/subscription/edit`)
    public func unsubscribe(streamID: String) async throws {
        let editURL = canonicalBaseURL.appendingPathComponent("reader/api/0/subscription/edit")

        let (_, _) = try await performWriteRequest { authToken, writeToken in
            var request = URLRequest(url: editURL)
            request.httpMethod = "POST"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "T", value: writeToken),
                URLQueryItem(name: "s", value: streamID),
                URLQueryItem(name: "ac", value: "unsubscribe")
            ]
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            return request
        }
    }

    /// 删除/禁用标签分类 (`/reader/api/0/disable-tag`)
    public func disableTag(folderExternalID: String) async throws {
        let disableURL = canonicalBaseURL.appendingPathComponent("reader/api/0/disable-tag")

        let (_, _) = try await performWriteRequest { authToken, writeToken in
            var request = URLRequest(url: disableURL)
            request.httpMethod = "POST"
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "T", value: writeToken),
                URLQueryItem(name: "s", value: folderExternalID)
            ]
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            return request
        }
    }
}

public struct ReaderAPIQuickAddResult: Codable, Sendable {
    public let numResults: Int?
    public let error: String?
    public let streamId: String?

    enum CodingKeys: String, CodingKey {
        case numResults
        case error
        case streamId
    }
}
