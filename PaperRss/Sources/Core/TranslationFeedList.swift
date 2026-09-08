import Foundation

public enum TranslationFeedList: String, Codable, CaseIterable, Sendable {
    case whitelist, blacklist
    public var title: String {
        self == .whitelist ? I18N.localized("白名单", englishFallback: "Whitelist") : I18N.localized("黑名单", englishFallback: "Blacklist")
    }
}
