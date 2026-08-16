import Foundation

/// 负责 FreshRSS / Google Reader API 的客户端认证与 Token 维护。
///
/// 遵循 Architecture Contract (Section 15, 16 / INV-11, INV-12)。
/// 严禁在任何日志、错误信息或持久化存储中泄露密码与认证 Token。
public actor ReaderAPIAuthenticator {
    private var cachedAuthToken: String?
    private var cachedWriteToken: String?
    private var isAuthenticating: Bool = false

    public init() {}

    public func currentAuthToken() -> String? {
        cachedAuthToken
    }

    public func currentWriteToken() -> String? {
        cachedWriteToken
    }

    public func invalidateAuth() {
        cachedAuthToken = nil
        cachedWriteToken = nil
    }

    public func invalidateWriteToken() {
        cachedWriteToken = nil
    }

    /// 执行 ClientLogin 认证并保存内存级 Auth Token。
    public func login(
        endpointURL: URL,
        username: String,
        password: String,
        session: URLSession
    ) async throws -> String {
        let loginURL = ReaderAPIClient.canonicalBaseURL(for: endpointURL)
            .appendingPathComponent("accounts/ClientLogin")

        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "Email", value: username),
            URLQueryItem(name: "Passwd", value: password),
            URLQueryItem(name: "output", value: "json")
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderAPIError.networkError("Invalid HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            invalidateAuth()
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ReaderAPIError.invalidCredentials
            }
            let snippet = String(data: data.prefix(200), encoding: .utf8)
            if let snippet, snippet.lowercased().contains("badauthentication") || snippet.lowercased().contains("bad authentication") {
                throw ReaderAPIError.invalidCredentials
            }
            throw ReaderAPIError.httpError(statusCode: httpResponse.statusCode, bodySnippet: snippet)
        }

        guard let responseText = String(data: data, encoding: .utf8) else {
            throw ReaderAPIError.decodingError("Invalid response text encoding")
        }

        // 解析 ClientLogin 返回的 key=value 键值对（例如 Auth=... 或 JSON）
        var extractedAuth: String?
        for line in responseText.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == "Auth" {
                extractedAuth = parts[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }

        if extractedAuth == nil {
            // 尝试解析 JSON {"Auth": "..."}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let auth = json["Auth"] as? String {
                extractedAuth = auth
            }
        }

        guard let authToken = extractedAuth, !authToken.isEmpty else {
            if responseText.lowercased().contains("badauthentication") {
                throw ReaderAPIError.invalidCredentials
            }
            throw ReaderAPIError.decodingError("Auth token not found in ClientLogin response")
        }

        self.cachedAuthToken = authToken
        self.cachedWriteToken = nil
        return authToken
    }

    /// 获取执行写操作所需的 Write Token（从 `/reader/api/0/token` 端点）。
    public func ensureWriteToken(
        endpointURL: URL,
        username: String,
        password: String,
        session: URLSession
    ) async throws -> String {
        if let existing = cachedWriteToken {
            return existing
        }

        let authToken: String
        if let current = cachedAuthToken {
            authToken = current
        } else {
            authToken = try await login(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session
            )
        }

        let tokenURL = ReaderAPIClient.canonicalBaseURL(for: endpointURL)
            .appendingPathComponent("reader/api/0/token")

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "GET"
        request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderAPIError.networkError("Invalid HTTP response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            // Auth token 过期，重试一次登录
            invalidateAuth()
            let newAuth = try await login(
                endpointURL: endpointURL,
                username: username,
                password: password,
                session: session
            )
            var retryReq = URLRequest(url: tokenURL)
            retryReq.httpMethod = "GET"
            retryReq.setValue("GoogleLogin auth=\(newAuth)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResp) = try await session.data(for: retryReq)
            guard let retryHTTP = retryResp as? HTTPURLResponse, retryHTTP.statusCode == 200,
                  let text = String(data: retryData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw ReaderAPIError.writeTokenUnavailable
            }
            self.cachedWriteToken = text
            return text
        }

        guard httpResponse.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ReaderAPIError.writeTokenUnavailable
        }

        self.cachedWriteToken = text
        return text
    }
}
