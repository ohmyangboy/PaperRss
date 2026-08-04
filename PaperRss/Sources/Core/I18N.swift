import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    public var id: String { rawValue }

    @MainActor
    public var title: String {
        switch self {
        case .system: I18N.shared.tr("跟随系统", "System Default")
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
        let raw = UserDefaults.standard.string(forKey: "PaperRss.appLanguage") ?? AppLanguage.zhHans.rawValue
        self.language = AppLanguage(rawValue: raw) ?? .zhHans
    }

    public var isEnglish: Bool {
        switch language {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("en")
        case .zhHans:
            return false
        case .en:
            return true
        }
    }

    public func tr(_ zh: String, _ en: String) -> String {
        Self.tr(zh, en)
    }

    public nonisolated static func tr(_ zh: String, _ en: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "PaperRss.appLanguage") ?? AppLanguage.zhHans.rawValue
        let lang = AppLanguage(rawValue: raw) ?? .zhHans
        let isEn: Bool
        switch lang {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            isEn = preferred.hasPrefix("en")
        case .zhHans:
            isEn = false
        case .en:
            isEn = true
        }
        return isEn ? en : zh
    }
}
