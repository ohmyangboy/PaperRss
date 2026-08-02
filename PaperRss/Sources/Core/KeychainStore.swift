import Foundation

/// Stores the API key as an app-local preference. This is intentionally not
/// synchronised to iCloud and does not involve the system Keychain, so reading
/// it never interrupts an AI request with a macOS password prompt.
///
/// The trade-off is deliberate: UserDefaults is protected by the app sandbox
/// but is not encrypted at rest like Keychain. It is suitable for this
/// single-user, local-only configuration, but should not be used for a shared
/// Mac account.
public enum LocalAPIKeyStore {
    private static let defaultsKey = "PaperRss.localAPIKey"

    public enum Storage: Sendable {
        case localAppConfiguration

        public var savedMessage: String {
            "已保存于此 Mac 的本地应用配置；不会同步到 iCloud，也不会再请求钥匙串密码。"
        }
    }

    public static func loadAPIKey() -> String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Storage {
        if key.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: defaultsKey)
        }
        return .localAppConfiguration
    }
}
