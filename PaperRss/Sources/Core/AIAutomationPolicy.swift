import Foundation

public enum AutoTranslationDecision: String, Sendable {
    case translate, disabled, exempt, unavailable, sameLanguage, mixed, unknown, unsupportedTarget, blacklisted, insufficientText

}

public enum AIAutomationPolicy {
    public static func evaluate(analysis: ArticleLanguageAnalysis, targetLanguage: String,
                                enabled: Bool, exempt: Bool, available: Bool,
                                list: TranslationFeedList? = nil) -> AutoTranslationDecision {
        if !enabled { return .disabled }
        if exempt { return .exempt }
        if !available { return .unavailable }
        if list == .blacklist { return .blacklisted }
        if list == .whitelist { return .translate }
        guard let target = baseLanguage(targetLanguage) else { return .unsupportedTarget }
        switch analysis.status {
        case .mixed: return .mixed
        case .unknown: return analysis.sampledLetterCount < LanguageDetectionService.minimumLetters ? .insufficientText : .unknown
        case .single:
            guard let source = analysis.dominantLanguage.flatMap(baseLanguage) else { return .unknown }
            return source == target ? .sameLanguage : .translate
        }
    }

    public static func baseLanguage(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        let aliases = ["简体中文": "zh", "繁體中文": "zh", "繁体中文": "zh", "中文": "zh", "chinese": "zh",
                       "english": "en", "日本語": "ja", "japanese": "ja", "한국어": "ko", "korean": "ko",
                       "français": "fr", "french": "fr", "deutsch": "de", "german": "de", "español": "es", "spanish": "es",
                       "português": "pt", "portuguese": "pt", "italiano": "it", "italian": "it", "русский": "ru", "russian": "ru",
                       "العربية": "ar", "arabic": "ar", "हिन्दी": "hi", "hindi": "hi", "ไทย": "th", "thai": "th",
                       "tiếng việt": "vi", "vietnamese": "vi", "bahasa indonesia": "id", "indonesian": "id"]
        if let alias = aliases[normalized] { return alias }
        guard normalized.range(of: #"^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$"#, options: .regularExpression) != nil,
              let base = normalized.split(separator: "-").first.map(String.init),
              Locale.LanguageCode.isoLanguageCodes.contains(where: { $0.identifier == base }),
              base != "und", base != "mul", base != "zxx" else { return nil }
        return base
    }
}
