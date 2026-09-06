import Foundation

/// 协议由实际端点决定；未知中转可由用户明确覆盖，不能从模型名字推断网关。
public enum AIReasoningProtocol: String, Codable, CaseIterable, Sendable {
    case automatic, deepSeek, gemini, dashscope, openRouter, openAI
}

public struct AIReasoningMetadata: Codable, Hashable, Sendable {
    public var modelID: String
    public var endpoint: String
    public var fetchedAt: Date
    public var efforts: [String]
    public var canDisable: Bool
    public var supportsThinking: Bool
}

public struct AIReasoningCapabilities: Sendable {
    public var wireProtocol: AIReasoningProtocol
    public var efforts: [String]
    public var canDisable: Bool
    public var supportsThinking: Bool
    public var source: String
    public var modes: [String] {
        ["自动"] + (canDisable ? ["关闭"] : []) + (supportsThinking && efforts.isEmpty ? ["开启"] : []) + efforts
    }
    public func accepts(_ mode: String) -> Bool { modes.contains(Self.canonical(mode)) }
    public static func canonical(_ mode: String) -> String {
        ["低": "low", "中": "medium", "高": "high"][mode] ?? mode
    }
}

extension LLMConfiguration {
    public var reasoningEndpoint: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    public var reasoningCapabilities: AIReasoningCapabilities {
        let host = URLComponents(string: reasoningEndpoint)?.host?.lowercased() ?? ""
        let wire: AIReasoningProtocol
        if reasoningProtocol != .automatic { wire = reasoningProtocol }
        else if host == "api.deepseek.com" { wire = .deepSeek }
        else if host == "generativelanguage.googleapis.com" { wire = .gemini }
        else if host == "openrouter.ai" { wire = .openRouter }
        else if host == "dashscope.aliyuncs.com" || host.hasSuffix(".dashscope.aliyuncs.com") || host == "dashscope-intl.aliyuncs.com" || host == "dashscope-us.aliyuncs.com" || host.hasSuffix(".maas.aliyuncs.com") { wire = .dashscope }
        else { wire = .automatic }
        func result(_ efforts: [String] = [], _ off: Bool = false, _ on: Bool = false, _ source: String = "官方协议规则") -> AIReasoningCapabilities {
            AIReasoningCapabilities(wireProtocol: wire, efforts: efforts, canDisable: off, supportsThinking: on, source: source == "官方协议规则" && reasoningProtocol != .automatic ? "手动协议" : source)
        }
        if usesTranslationAdaptation { return result([], false, false, "不适用") }
        // 目录过期由刷新入口处理；同端点、同模型的已知能力仍可使用，避免已保存的思考模式隔天失效。
        if wire == .openRouter, let metadata = reasoningMetadata,
           metadata.modelID == model, metadata.endpoint == reasoningEndpoint {
            return result(metadata.efforts, metadata.canDisable, metadata.supportsThinking, "模型目录")
        }
        let id = model.lowercased().replacingOccurrences(of: "models/", with: "")
        // 2026-09-06 核验；完整档位未由多数供应商的 /models 暴露。
        // https://api-docs.deepseek.com/guides/thinking_mode/
        // https://ai.google.dev/gemini-api/docs/openai
        // https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions
        switch wire {
        case .deepSeek: return result(["low", "high", "max"], true, true)
        case .gemini where id.hasPrefix("gemini-2.5"):
            return result(["low", "medium", "high"], !id.contains("pro"), true)
        case .gemini where id.hasPrefix("gemini-3"):
            return result(id.contains("flash") ? ["minimal", "low", "medium", "high"] : ["low", "high"], false, true)
        case .dashscope where id.hasPrefix("qwen3.7"):
            return result([], true, true)
        case .dashscope where id.hasPrefix("deepseek-v4"):
            return result(id.contains("0731") || id.contains("0813") ? ["low", "high", "max"] : ["high", "max"], true, true)
        case .openAI where reasoningProtocol == .openAI:
            return result(["low", "medium", "high"], false, true, "手动协议")
        default: return result([], false, false, "能力未确认，请刷新模型目录或选择协议")
        }
    }
}
