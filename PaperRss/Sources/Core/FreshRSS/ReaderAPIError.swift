import Foundation

/// FreshRSS / Google Reader API 错误体系。
///
/// 遵循 Architecture Contract (Section 16 / INV-11)。
/// 严禁在此错误类型及其描述中泄露密码、Auth Token 或 Write Token。
public enum ReaderAPIError: LocalizedError, Sendable {
    case invalidEndpointURL(String)
    case invalidCredentials
    case sessionExpired
    case writeTokenUnavailable
    case httpError(statusCode: Int, bodySnippet: String?)
    case decodingError(String)
    case serverError(String)
    case networkError(String)
    case requestCancelled
    case accountAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointURL(url):
            return I18N.localized("无效的 FreshRSS API 地址：\(url)")
        case .invalidCredentials:
            return I18N.localized("FreshRSS 用户名或 API 密码错误。")
        case .sessionExpired:
            return I18N.localized("FreshRSS 登录会话已过期。")
        case .writeTokenUnavailable:
            return I18N.localized("无法获取 FreshRSS 写操作 Token。")
        case let .httpError(statusCode, bodySnippet):
            if let bodySnippet, !bodySnippet.isEmpty {
                return I18N.localized("FreshRSS 服务器错误 (HTTP \(statusCode)): \(bodySnippet)")
            }
            return I18N.localized("FreshRSS 服务器响应异常 (HTTP \(statusCode))。")
        case let .decodingError(detail):
            return I18N.localized("FreshRSS 数据解析失败：\(detail)")
        case let .serverError(message):
            return I18N.localized("FreshRSS 错误：\(message)")
        case let .networkError(message):
            return I18N.localized("网络连接失败：\(message)")
        case .requestCancelled:
            return I18N.localized("请求已取消。")
        case let .accountAlreadyExists(detail):
            return I18N.localized("该 FreshRSS 账号已存在：\(detail)")
        }
    }
}
