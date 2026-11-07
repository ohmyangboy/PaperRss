import Foundation
import PaperRssAITransfer

/// Builds an in-memory device transfer without changing the saved AI configuration.
/// Credentials are deliberately separate from the settings document.
public enum AISettingsTransferSnapshot {
    public static func make(
        settings: AISettings,
        sourceID: String,
        sourceName: String,
        keyForProvider: (String) -> String
    ) throws -> TransferSnapshot {
        var credentials: [String: String] = [:]
        for provider in settings.providers {
            let key = keyForProvider(provider.id)
            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                credentials[provider.id] = key
            }
        }
        return TransferSnapshot(
            sourceID: sourceID,
            sourceName: sourceName,
            settings: try JSONValue.decode(settings),
            credentials: credentials
        )
    }

    public static func sourceID(defaults: UserDefaults = .standard) -> String {
        let key = "PaperRss.aiTransfer.sourceID"
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil {
            return existing
        }
        let identifier = UUID().uuidString
        defaults.set(identifier, forKey: key)
        return identifier
    }
}
