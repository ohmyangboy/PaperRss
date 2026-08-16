import Foundation

/// 独立管理从 Legacy JSON 到 UserDefaults 的偏好设置迁移。
///
/// 遵循 Architecture Contract (DA-04 / Section 19)：
/// - SQLite 数据库迁移状态与 Preference 迁移状态解耦；
/// - 只要 `UserDefaults` 缺失 `llmConfiguration` 且存在 `library.json`，即无损还原原 LLM 配置；
/// - 用户在 `UserDefaults` 中已有新设置时，绝对优先，禁止覆盖。
public enum LegacyPreferenceMigrator {
    public static func recoverLLMConfigurationIfNeeded(
        from jsonURL: URL,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> LLMConfiguration? {
        let prefKey = "PaperRss.llmConfiguration"
        // 1. 如果 UserDefaults 已存在配置，已有设置绝对优先
        if let existingData = userDefaults.data(forKey: prefKey),
           let saved = try? JSONDecoder().decode(LLMConfiguration.self, from: existingData) {
            return saved
        }

        // 2. 检查 legacy JSON 是否存在
        guard fileManager.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              let legacyDataset = try? LegacyMigrationJSONDecoder.decoder.decode(LegacyAppDatabase.self, from: data) else {
            return nil
        }

        let legacyLLM = legacyDataset.llmConfiguration
        let config = LLMConfiguration(
            providerName: legacyLLM.providerName,
            providerDescription: legacyLLM.providerDescription,
            baseURL: legacyLLM.baseURL,
            model: legacyLLM.model,
            reasoningMode: legacyLLM.reasoningMode,
            temperature: legacyLLM.temperature,
            targetLanguage: legacyLLM.targetLanguage,
            allowInsecureLocalEndpoint: legacyLLM.allowInsecureLocalEndpoint,
            showsAISummary: legacyLLM.showsAISummary,
            automaticallyGenerateSummary: legacyLLM.automaticallyGenerateSummary,
            showsSelectionExplanation: legacyLLM.showsSelectionExplanation,
            showsSelectionAsk: legacyLLM.showsSelectionAsk,
            showsSelectionTranslation: legacyLLM.showsSelectionTranslation,
            customPrompt: legacyLLM.customPrompt
        )

        if let encoded = try? JSONEncoder().encode(config) {
            userDefaults.set(encoded, forKey: prefKey)
        }
        return config
    }
}
