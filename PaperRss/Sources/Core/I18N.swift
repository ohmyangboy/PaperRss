import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    public var id: String { rawValue }

    public func resolvedLocalization(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch self {
        case .zhHans, .en:
            return self
        case .system:
            let preferred = preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("en") ? .en : .zhHans
        }
    }

    public var localeIdentifier: String {
        resolvedLocalization().rawValue
    }

    @MainActor
    public var title: String {
        switch self {
        case .system: I18N.shared.localized("跟随系统")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }
}

@MainActor
public final class I18N: ObservableObject {
    public static let shared = I18N()

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "PaperRss.appLanguage")
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "PaperRss.appLanguage")
        self.language = raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    public var isEnglish: Bool {
        language.resolvedLocalization() == .en
    }

    public func localized(_ key: String) -> String {
        Self.localized(key, language: language)
    }

    public func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        Self.localizedFormat(key, arguments: arguments, language: language)
    }

    public func localized(_ key: String, _ englishFallback: String) -> String {
        Self.localized(key, englishFallback: englishFallback, language: language)
    }

    public nonisolated static func localized(
        _ key: String,
        englishFallback: String? = nil,
        language explicitLanguage: AppLanguage? = nil
    ) -> String {
        let raw = UserDefaults.standard.string(forKey: "PaperRss.appLanguage")
        let language = explicitLanguage
            ?? raw.flatMap(AppLanguage.init(rawValue:))
            ?? .system
        let localization = language.resolvedLocalization().rawValue
        let baseBundle = resourceBundle
        let fallback = localization == AppLanguage.en.rawValue
            ? (englishFallback ?? builtinEnglishTranslations[key] ?? key)
            : key
        guard let path = baseBundle.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return fallback
        }
        return bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
    }

    public nonisolated static func localizedFormat(
        _ key: String,
        arguments: [CVarArg],
        language explicitLanguage: AppLanguage? = nil
    ) -> String {
        let language = explicitLanguage ?? currentLanguage
        let formatTemplate = localized(key, language: language)
        return String(
            format: formatTemplate,
            locale: Locale(identifier: language.resolvedLocalization().rawValue),
            arguments: arguments
        )
    }

    private nonisolated static var currentLanguage: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "PaperRss.appLanguage")
        return raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    private nonisolated static var resourceBundle: Bundle {
        Bundle.main
    }

    private nonisolated static let builtinEnglishTranslations: [String: String] = [
        "今天": "Today",
        "添加订阅": "Add Feed",
        "未读": "Unread",
        "收藏": "Starred",
        "未启用": "Disabled",
        "等待同步": "Waiting for sync",
        "%lld 个订阅": "%lld Feeds",
        "跟随系统": "System",
        "慢读，深思": "Read slowly. Think deeply.",
        "当前账号": "Current Accounts",
        "管理本地与 FreshRSS 订阅账号及双向状态同步": "Manage local and FreshRSS accounts with two-way state sync",
        "PaperRss 支持多账号并行与按需启用。本地订阅与 FreshRSS 远端订阅相互隔离，禁用账号不会删除本地数据或凭据。": "PaperRss supports multiple independently enabled accounts. Local subscriptions and FreshRSS subscriptions remain isolated, and disabling an account does not delete local data or credentials.",
        "我的 Mac": "My Mac",
        "我的 Mac (本地账号)": "My Mac (Local Account)",
        "本机": "Local",
        "本机独立存储与离线阅读": "On-device storage and offline reading",
        "OpenAI 兼容接口": "OpenAI-Compatible Endpoint",
        "DeepSeek OpenAI 兼容接口": "DeepSeek OpenAI-Compatible Endpoint",
        "用于翻译、总结和解读文章": "For translation, summarization, and article analysis",
        "再按一次 C 切换对照翻译": "Press C again to toggle bilingual translation",
        "再按一次 V 查看 AI 摘要": "Press V again to view the AI summary",
        "再按一次 M 切换收藏": "Press M again to toggle star",
        "再按一次 F 切换禅模式": "Press F again to toggle Focus Mode"
    ]
}
