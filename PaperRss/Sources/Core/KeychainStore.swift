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
    private static let legacyDefaultsKey = "PaperRss.localAPIKey"
    private static let providerKeyPrefix = "PaperRss.localAPIKey.provider."
    private static let migrationMarkerPrefix = "PaperRss.localAPIKey.migrated."

    public enum Storage: Sendable {
        case localAppConfiguration

        public var savedMessage: String {
            I18N.localized("已保存到 Mac 本地。")
        }
    }

    public static func loadAPIKey() -> String {
        UserDefaults.standard.string(forKey: legacyDefaultsKey) ?? ""
    }

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Storage {
        if key.isEmpty {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: legacyDefaultsKey)
        }
        return .localAppConfiguration
    }

    public static func loadAPIKey(for providerID: String) -> String {
        let key = providerDefaultsKey(for: providerID)
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    @discardableResult
    public static func saveAPIKey(_ key: String, for providerID: String) -> Storage {
        let defaultsKey = providerDefaultsKey(for: providerID)
        if key.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: defaultsKey)
        }
        return .localAppConfiguration
    }

    /// Copies the pre-v2 key once, while intentionally leaving the legacy key
    /// intact so an older build can still start with the user's configuration.
    @discardableResult
    public static func migrateLegacyAPIKeyIfNeeded(to providerID: String) -> Bool {
        let destinationKey = providerDefaultsKey(for: providerID)
        let defaults = UserDefaults.standard
        let markerKey = migrationMarker(for: providerID)
        // A user may intentionally clear a v2 provider key while the legacy
        // key is retained for rollback. Once copied, never resurrect it on a
        // later launch.
        if defaults.bool(forKey: markerKey) { return true }
        if defaults.string(forKey: destinationKey) != nil {
            defaults.set(true, forKey: markerKey)
            return true
        }
        guard let legacy = defaults.string(forKey: legacyDefaultsKey), !legacy.isEmpty else { return true }
        defaults.set(legacy, forKey: destinationKey)
        guard defaults.string(forKey: destinationKey) == legacy else { return false }
        defaults.set(true, forKey: markerKey)
        return true
    }

    private static func providerDefaultsKey(for providerID: String) -> String {
        providerKeyPrefix + providerID
    }

    private static func migrationMarker(for providerID: String) -> String {
        migrationMarkerPrefix + providerID
    }
}
