import Foundation

/// 请求协议与模型名称分离，允许中转服务的别名复用适配。
public enum AIModelAdaptation: String, Codable, CaseIterable, Sendable {
    case automatic
    case chat
    case userMessage
    case qwenTranslation

    public func resolved(modelID: String) -> Self {
        guard self == .automatic else { return self }
        return Self.isKnownTranslationModel(modelID) ? .qwenTranslation : .chat
    }

    public static func isKnownTranslationModel(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("qwen-mt-")
    }

    public var title: String {
        switch self {
        case .automatic: I18N.localized("自动", englishFallback: "Automatic")
        case .chat: I18N.localized("通用聊天", englishFallback: "General chat")
        case .userMessage: I18N.localized("单条用户消息", englishFallback: "Single user message")
        case .qwenTranslation: I18N.localized("专用翻译（Qwen-MT 兼容）", englishFallback: "Translation (Qwen-MT compatible)")
        }
    }
}

extension AIModelOption {
    public var usesTranslationAdaptation: Bool { adaptation.resolved(modelID: id) == .qwenTranslation }

    public var adaptationBadge: String? {
        guard usesTranslationAdaptation else { return nil }
        return AIModelAdaptation.isKnownTranslationModel(id)
            ? I18N.localized("仅翻译", englishFallback: "Translation only")
            : I18N.localized("翻译适配", englishFallback: "Translation adapter")
    }

    public func supports(_ feature: AIFeatureKind) -> Bool {
        !usesTranslationAdaptation || feature == .bilingualTranslation || feature == .selectionTranslation
    }
}

extension LLMConfiguration {
    public var resolvedAdaptation: AIModelAdaptation { adaptation.resolved(modelID: model) }
    public var usesTranslationAdaptation: Bool { resolvedAdaptation == .qwenTranslation }
}

/// 建议只作用于本次测试的配置；不把启发式探测当作模型用途认证。
public struct AIConnectionTestResult: Sendable, Equatable {
    public let suggestedAdaptation: AIModelAdaptation?

    public init(suggestedAdaptation: AIModelAdaptation? = nil) {
        self.suggestedAdaptation = suggestedAdaptation
    }
}
