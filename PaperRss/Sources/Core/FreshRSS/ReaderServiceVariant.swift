import Foundation

/// Google Reader API 兼容服务的协议差异预设。
///
/// 本类型描述「连接哪个服务」，`ReaderAPIClient` 依据预设处理端点规则；
/// 服务身份（`AccountType`）与协议实现（本类型）相互独立，
/// 便于 Miniflux 与 FreshRSS 共享同一套 Reader API 栈。
public enum ReaderServiceVariant: String, Codable, Hashable, Sendable {
    case freshRSS
    case miniflux

    /// 凭据命名空间；不同服务使用独立 Keychain service，互不覆盖。
    public var credentialScope: CredentialScope {
        switch self {
        case .freshRSS: return .freshRSS
        case .miniflux: return .miniflux
        }
    }

    /// 设置页使用的服务展示名（不参与本地化，品牌名保持原文）。
    public var serviceDisplayName: String {
        switch self {
        case .freshRSS: return "FreshRSS"
        case .miniflux: return "Miniflux"
        }
    }

    // MARK: - Endpoint Canonicalization

    /// 将用户输入规范化为「协议根地址」。
    ///
    /// - FreshRSS：根地址或子路径都会规范化为 `<base>/api/greader.php`；
    /// - Miniflux：保留部署子路径并去除尾斜杠，不追加 PHP 路径；
    ///   容忍误贴 `<base>/reader/api/0` 或 `<base>/reader/api` 的情况。
    public static func canonicalBaseURL(for rawURL: URL, variant: ReaderServiceVariant) -> URL {
        switch variant {
        case .freshRSS:
            return canonicalFreshRSSBaseURL(for: rawURL)
        case .miniflux:
            return canonicalMinifluxBaseURL(for: rawURL)
        }
    }

    /// 校验用户输入并返回规范化后的协议根地址。
    ///
    /// 校验规则：必须有主机名、仅允许 http/https、禁止内嵌用户名密码与 query/fragment。
    public static func validatedBaseURL(for rawURL: URL, variant: ReaderServiceVariant) throws -> URL {
        guard let host = rawURL.host, !host.isEmpty else {
            throw ReaderAPIError.invalidEndpointURL(rawURL.absoluteString)
        }
        let scheme = rawURL.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw ReaderAPIError.invalidEndpointURL(rawURL.absoluteString)
        }
        if let components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
            if components.user != nil || components.password != nil {
                throw ReaderAPIError.invalidEndpointURL(rawURL.absoluteString)
            }
            if components.query != nil || components.fragment != nil {
                throw ReaderAPIError.invalidEndpointURL(rawURL.absoluteString)
            }
        }
        return canonicalBaseURL(for: rawURL, variant: variant)
    }

    private static func canonicalFreshRSSBaseURL(for rawURL: URL) -> URL {
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

    private static func canonicalMinifluxBaseURL(for rawURL: URL) -> URL {
        var urlString = rawURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while urlString.hasSuffix("/") {
            urlString.removeLast()
        }

        // 容忍误贴 API 前缀，规范化回部署根地址。
        if urlString.hasSuffix("/reader/api/0") {
            urlString.removeLast("/reader/api/0".count)
        } else if urlString.hasSuffix("/reader/api") {
            urlString.removeLast("/reader/api".count)
        }

        while urlString.hasSuffix("/") {
            urlString.removeLast()
        }

        return URL(string: urlString) ?? rawURL
    }
}
