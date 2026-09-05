import Foundation

/// Stable identifiers are deliberately human-readable so a settings file can
/// be inspected during support without exposing credentials.
public enum AIProviderID {
    public static let openAI = "builtin.openai"
    public static let deepSeek = "builtin.deepseek"
    public static let gemini = "builtin.gemini"
    public static let migratedLegacy = "migrated.legacy"
}

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case openAICompatible
    case deepSeek
    case gemini
    case customOpenAICompatible

    public var isBuiltIn: Bool {
        switch self {
        case .customOpenAICompatible: false
        case .openAICompatible, .deepSeek, .gemini: true
        }
    }
}

public enum AIModelSource: String, Codable, Sendable {
    case remote
    case manual
}

public enum AIFeatureKind: String, Codable, CaseIterable, Sendable {
    case summary
    case bilingualTranslation
    case selectionTranslation
    case selectionExplanation
    case selectionAsk
}

public struct AIModelReference: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct AIFeatureConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var model: AIModelReference?
    public var reasoningMode: String

    public init(isEnabled: Bool, model: AIModelReference?, reasoningMode: String = "自动") {
        self.isEnabled = isEnabled
        self.model = model
        self.reasoningMode = reasoningMode
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, model, reasoningMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            model: try values.decodeIfPresent(AIModelReference.self, forKey: .model),
            reasoningMode: try values.decodeIfPresent(String.self, forKey: .reasoningMode) ?? "自动"
        )
    }
}

public enum AIProviderValidationError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL
    case insecureRemoteEndpoint
    case endpointIsNotAPIRoot
    case missingModel

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: I18N.localized("Base URL 无效。")
        case .insecureRemoteEndpoint: I18N.localized("HTTP 仅允许用于已明确开启的本地或局域网地址。")
        case .endpointIsNotAPIRoot: I18N.localized("请输入 API 根地址，不要包含 /models 或 /chat/completions。")
        case .missingModel: I18N.localized("请先选择或填写模型。")
        }
    }
}

public struct AIModelOption: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var source: AIModelSource
    public var isEnabled: Bool
    public var reasoningMode: String
    public var temperature: Double

    public init(
        id: String,
        displayName: String? = nil,
        source: AIModelSource = .manual,
        isEnabled: Bool = true,
        reasoningMode: String = "自动",
        temperature: Double = 0.2
    ) {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = cleanID
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : cleanID
        self.source = source
        self.isEnabled = isEnabled
        self.reasoningMode = reasoningMode
        self.temperature = temperature
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, source, isEnabled, reasoningMode, temperature
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            displayName: try values.decodeIfPresent(String.self, forKey: .displayName),
            source: try values.decodeIfPresent(AIModelSource.self, forKey: .source) ?? .manual,
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            reasoningMode: try values.decodeIfPresent(String.self, forKey: .reasoningMode) ?? "自动",
            temperature: try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
        )
    }
}

/// Settings that describe reader-facing AI behavior, rather than a network
/// connection. They intentionally remain unchanged when the active provider
/// changes.
public struct AIFeaturePreferences: Codable, Hashable, Sendable {
    public var targetLanguage: String
    public var showsAISummary: Bool
    public var automaticallyGenerateSummary: Bool
    public var showsSelectionExplanation: Bool
    public var showsSelectionAsk: Bool
    public var showsSelectionTranslation: Bool
    public var customPrompt: String

    public static let `default` = AIFeaturePreferences(
        targetLanguage: "简体中文",
        showsAISummary: true,
        automaticallyGenerateSummary: false,
        showsSelectionExplanation: true,
        showsSelectionAsk: true,
        showsSelectionTranslation: true,
        customPrompt: ""
    )

    public init(
        targetLanguage: String,
        showsAISummary: Bool = true,
        automaticallyGenerateSummary: Bool = false,
        showsSelectionExplanation: Bool = true,
        showsSelectionAsk: Bool = true,
        showsSelectionTranslation: Bool = true,
        customPrompt: String = ""
    ) {
        self.targetLanguage = targetLanguage
        self.showsAISummary = showsAISummary
        self.automaticallyGenerateSummary = automaticallyGenerateSummary
        self.showsSelectionExplanation = showsSelectionExplanation
        self.showsSelectionAsk = showsSelectionAsk
        self.showsSelectionTranslation = showsSelectionTranslation
        self.customPrompt = customPrompt
    }

    public init(configuration: LLMConfiguration) {
        self.init(
            targetLanguage: configuration.targetLanguage,
            showsAISummary: configuration.showsAISummary,
            automaticallyGenerateSummary: configuration.automaticallyGenerateSummary,
            showsSelectionExplanation: configuration.showsSelectionExplanation,
            showsSelectionAsk: configuration.showsSelectionAsk,
            showsSelectionTranslation: configuration.showsSelectionTranslation,
            customPrompt: configuration.customPrompt
        )
    }
}

public struct AIProviderProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var kind: AIProviderKind
    public var isEnabled: Bool
    public var name: String
    public var description: String
    public var baseURL: String
    public var selectedModelID: String
    public var models: [AIModelOption]
    public var reasoningMode: String
    public var temperature: Double
    public var allowInsecureLocalEndpoint: Bool

    public var isBuiltIn: Bool { kind.isBuiltIn }

    public init(
        id: String,
        kind: AIProviderKind,
        isEnabled: Bool = true,
        name: String,
        description: String,
        baseURL: String,
        selectedModelID: String,
        models: [AIModelOption] = [],
        reasoningMode: String = "自动",
        temperature: Double = 0.2,
        allowInsecureLocalEndpoint: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.name = name
        self.description = description
        self.baseURL = baseURL
        self.selectedModelID = selectedModelID
        self.models = Self.normalizedModels(models, retaining: selectedModelID)
        self.reasoningMode = reasoningMode
        self.temperature = temperature
        self.allowInsecureLocalEndpoint = allowInsecureLocalEndpoint
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, isEnabled, name, description, baseURL, selectedModelID, models
        case reasoningMode, temperature, allowInsecureLocalEndpoint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            kind: try values.decode(AIProviderKind.self, forKey: .kind),
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            name: try values.decode(String.self, forKey: .name),
            description: try values.decodeIfPresent(String.self, forKey: .description) ?? "",
            baseURL: try values.decode(String.self, forKey: .baseURL),
            selectedModelID: try values.decodeIfPresent(String.self, forKey: .selectedModelID) ?? "",
            models: try values.decodeIfPresent([AIModelOption].self, forKey: .models) ?? [],
            reasoningMode: try values.decodeIfPresent(String.self, forKey: .reasoningMode) ?? "自动",
            temperature: try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2,
            allowInsecureLocalEndpoint: try values.decodeIfPresent(Bool.self, forKey: .allowInsecureLocalEndpoint) ?? false
        )
    }

    public init(id: String, kind: AIProviderKind, configuration: LLMConfiguration) {
        self.init(
            id: id,
            kind: kind,
            isEnabled: true,
            name: configuration.providerName,
            description: configuration.providerDescription,
            baseURL: configuration.baseURL,
            selectedModelID: configuration.model,
            models: [AIModelOption(id: configuration.model)],
            reasoningMode: configuration.reasoningMode,
            temperature: configuration.temperature,
            allowInsecureLocalEndpoint: configuration.allowInsecureLocalEndpoint
        )
    }

    public func runtimeConfiguration(features: AIFeaturePreferences) -> LLMConfiguration {
        runtimeConfiguration(modelID: selectedModelID, features: features)
    }

    public func runtimeConfiguration(modelID: String, features: AIFeaturePreferences) -> LLMConfiguration {
        return LLMConfiguration(
            providerName: name,
            providerDescription: description,
            baseURL: baseURL,
            model: modelID,
            reasoningMode: reasoningMode,
            temperature: temperature,
            targetLanguage: features.targetLanguage,
            allowInsecureLocalEndpoint: allowInsecureLocalEndpoint,
            showsAISummary: features.showsAISummary,
            automaticallyGenerateSummary: features.automaticallyGenerateSummary,
            showsSelectionExplanation: features.showsSelectionExplanation,
            showsSelectionAsk: features.showsSelectionAsk,
            showsSelectionTranslation: features.showsSelectionTranslation,
            customPrompt: features.customPrompt,
            providerKind: kind
        )
    }

    public func updatingModels(from remoteIDs: [String]) -> AIProviderProfile {
        let cleanIDs = remoteIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var existingByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let remoteSet = Set(cleanIDs)
        var merged: [AIModelOption] = []

        for id in cleanIDs where !merged.contains(where: { $0.id == id }) {
            if let existing = existingByID.removeValue(forKey: id) {
                merged.append(existing)
            } else {
                merged.append(AIModelOption(
                    id: id,
                    source: .remote,
                    reasoningMode: reasoningMode,
                    temperature: temperature
                ))
            }
        }

        // User-added models survive a refresh even when the provider cannot
        // list them. The selected model is retained as a manual fallback too.
        for model in models where model.source == .manual && !remoteSet.contains(model.id) {
            if !merged.contains(where: { $0.id == model.id }) {
                merged.append(model)
            }
        }
        return replacing(models: Self.normalizedModels(merged, retaining: selectedModelID))
    }

    public func addingManualModel(id: String, displayName: String? = nil) -> AIProviderProfile {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { return self }
        var next = models
        if let index = next.firstIndex(where: { $0.id == cleanID }) {
            next[index].source = .manual
            next[index].isEnabled = true
            if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next[index].displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            next.append(AIModelOption(
                id: cleanID,
                displayName: displayName,
                source: .manual,
                reasoningMode: reasoningMode,
                temperature: temperature
            ))
        }
        return replacing(models: Self.normalizedModels(next, retaining: selectedModelID))
    }

    public func updatingModel(id: String, isEnabled: Bool) -> AIProviderProfile {
        var next = models
        guard let index = next.firstIndex(where: { $0.id == id }) else { return self }
        next[index].isEnabled = isEnabled
        return replacing(models: Self.normalizedModels(next, retaining: selectedModelID))
    }

    public func selectingModel(_ modelID: String) -> AIProviderProfile {
        let cleanID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { return self }
        return replacing(selectedModelID: cleanID, models: Self.normalizedModels(models, retaining: cleanID))
    }

    public func validateConnection(requireModel: Bool) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              scheme == "https" || scheme == "http" else {
            throw AIProviderValidationError.invalidBaseURL
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if path.hasSuffix("models") || path.hasSuffix("chat/completions") {
            throw AIProviderValidationError.endpointIsNotAPIRoot
        }
        if scheme == "http" {
            let isLocalName = host == "localhost" || host.hasSuffix(".local")
            let octets = host.split(separator: ".").compactMap { Int($0) }
            let isPrivateIPv4 = octets.count == 4 && (
                octets[0] == 10 ||
                (octets[0] == 127) ||
                (octets[0] == 192 && octets[1] == 168) ||
                (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 169 && octets[1] == 254)
            )
            let isLocalIPv6 = host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
            guard allowInsecureLocalEndpoint && (isLocalName || isPrivateIPv4 || isLocalIPv6) else {
                throw AIProviderValidationError.insecureRemoteEndpoint
            }
        }
        if requireModel && selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProviderValidationError.missingModel
        }
    }

    public static func custom(
        name: String,
        description: String,
        baseURL: String,
        modelID: String = ""
    ) -> AIProviderProfile {
        let cleanModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIProviderProfile(
            id: "custom.\(UUID().uuidString.lowercased())",
            kind: .customOpenAICompatible,
            name: name,
            description: description,
            baseURL: baseURL,
            selectedModelID: cleanModelID,
            models: cleanModelID.isEmpty ? [] : [AIModelOption(id: cleanModelID, source: .manual)]
        )
    }

    public func replacing(
        isEnabled: Bool? = nil,
        name: String? = nil,
        description: String? = nil,
        baseURL: String? = nil,
        selectedModelID: String? = nil,
        models: [AIModelOption]? = nil,
        reasoningMode: String? = nil,
        temperature: Double? = nil,
        allowInsecureLocalEndpoint: Bool? = nil
    ) -> AIProviderProfile {
        AIProviderProfile(
            id: id,
            kind: kind,
            isEnabled: isEnabled ?? self.isEnabled,
            name: name ?? self.name,
            description: description ?? self.description,
            baseURL: baseURL ?? self.baseURL,
            selectedModelID: selectedModelID ?? self.selectedModelID,
            models: models ?? self.models,
            reasoningMode: reasoningMode ?? self.reasoningMode,
            temperature: temperature ?? self.temperature,
            allowInsecureLocalEndpoint: allowInsecureLocalEndpoint ?? self.allowInsecureLocalEndpoint
        )
    }

    private static func normalizedModels(_ models: [AIModelOption], retaining selectedModelID: String) -> [AIModelOption] {
        var seen = Set<String>()
        var result: [AIModelOption] = []
        for model in models {
            let cleanID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty, seen.insert(cleanID).inserted else { continue }
            var normalized = model
            normalized.displayName = normalized.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? cleanID
                : normalized.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(normalized)
        }
        if !selectedModelID.isEmpty, !seen.contains(selectedModelID) {
            result.append(AIModelOption(
                id: selectedModelID,
                source: .manual,
                reasoningMode: "自动",
                temperature: 0.2
            ))
        }
        return result
    }
}

public struct AISettings: Codable, Hashable, Sendable {
    public static let schemaVersion = 5

    public var schema: Int
    public var activeProviderID: String
    public var providers: [AIProviderProfile]
    public var features: AIFeaturePreferences
    public var featureConfigurations: [AIFeatureKind: AIFeatureConfiguration]?

    public var activeProvider: AIProviderProfile? {
        providers.first(where: { $0.id == activeProviderID })
    }

    public static let `default` = AISettings(
        activeProviderID: AIProviderID.deepSeek,
        providers: [
            AIProviderProfile(
                id: AIProviderID.deepSeek,
                kind: .deepSeek,
                name: LLMConfiguration.deepSeek.providerName,
                description: LLMConfiguration.deepSeek.providerDescription,
                baseURL: LLMConfiguration.deepSeek.baseURL,
                selectedModelID: LLMConfiguration.deepSeek.model,
                models: [
                    AIModelOption(id: "deepseek-v4-flash", displayName: "deepseek-v4-flash", source: .manual),
                    AIModelOption(id: "deepseek-v4-pro", displayName: "deepseek-v4-pro", source: .manual)
                ],
                reasoningMode: LLMConfiguration.deepSeek.reasoningMode,
                temperature: LLMConfiguration.deepSeek.temperature,
                allowInsecureLocalEndpoint: LLMConfiguration.deepSeek.allowInsecureLocalEndpoint
            ),
            AIProviderProfile(
                id: AIProviderID.openAI,
                kind: .openAICompatible,
                name: "OpenAI 兼容接口",
                description: "用于翻译、总结和解读文章",
                baseURL: "https://api.openai.com/v1",
                selectedModelID: "gpt-4o-mini"
            ),
            AIProviderProfile(
                id: AIProviderID.gemini,
                kind: .gemini,
                name: "Google Gemini",
                description: "Google Gemini 官方 OpenAI 兼容接口",
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                selectedModelID: "gemini-3.8-flash"
            )
        ],
        features: .default,
        featureConfigurations: Dictionary(uniqueKeysWithValues: AIFeatureKind.allCases.map {
            ($0, AIFeatureConfiguration(
                isEnabled: true,
                model: AIModelReference(providerID: AIProviderID.deepSeek, modelID: "deepseek-v4-flash"),
                reasoningMode: $0 == .bilingualTranslation || $0 == .selectionTranslation ? "关闭" : "自动"
            ))
        })
    )

    public init(
        activeProviderID: String,
        providers: [AIProviderProfile],
        features: AIFeaturePreferences,
        featureConfigurations: [AIFeatureKind: AIFeatureConfiguration]? = nil,
        schema: Int = AISettings.schemaVersion
    ) {
        self.schema = schema
        self.providers = providers
        self.features = features
        self.featureConfigurations = featureConfigurations
        self.activeProviderID = providers.contains(where: { $0.id == activeProviderID })
            ? activeProviderID
            : providers.first?.id ?? AIProviderID.deepSeek
    }

    public func resolvedConfiguration() -> LLMConfiguration {
        resolvedConfiguration(for: .summary) ?? .default
    }

    public func configuration(for kind: AIFeatureKind) -> AIFeatureConfiguration? {
        if var configured = featureConfigurations?[kind] {
            if configured.reasoningMode == "关闭",
               let reference = configured.model,
               let provider = provider(id: reference.providerID),
               !provider.runtimeConfiguration(modelID: reference.modelID, features: features).supportsDisablingReasoning {
                // 换到不支持关闭的模型时，界面和执行都显示其实际使用的自动模式。
                configured.reasoningMode = "自动"
            }
            return configured
        }
        guard let provider = activeProvider else { return nil }
        let reference = AIModelReference(providerID: provider.id, modelID: provider.selectedModelID)
        return AIFeatureConfiguration(
            isEnabled: legacyEnabledState(for: kind),
            model: reference,
            reasoningMode: provider.reasoningMode
        )
    }

    public var availableModelReferences: [AIModelReference] {
        providers.filter(\.isEnabled).flatMap { provider in
            provider.models.map { AIModelReference(providerID: provider.id, modelID: $0.id) }
        }
    }

    public func resolvedConfiguration(for kind: AIFeatureKind) -> LLMConfiguration? {
        guard let feature = configuration(for: kind),
              let reference = feature.model,
              let provider = provider(id: reference.providerID),
              provider.isEnabled,
              provider.models.contains(where: { $0.id == reference.modelID }) else { return nil }
        var runtime = provider.runtimeConfiguration(modelID: reference.modelID, features: features)
        runtime.reasoningMode = feature.reasoningMode
        runtime.showsAISummary = configuration(for: .summary)?.isEnabled ?? false
        runtime.showsSelectionTranslation = configuration(for: .selectionTranslation)?.isEnabled ?? false
        runtime.showsSelectionExplanation = configuration(for: .selectionExplanation)?.isEnabled ?? false
        runtime.showsSelectionAsk = configuration(for: .selectionAsk)?.isEnabled ?? false
        return runtime
    }

    public func provider(id: String) -> AIProviderProfile? {
        providers.first(where: { $0.id == id })
    }

    public func updatingProvider(_ provider: AIProviderProfile) -> AISettings {
        var next = providers
        if let index = next.firstIndex(where: { $0.id == provider.id }) {
            next[index] = provider
        } else {
            next.append(provider)
        }
        return sanitized(providers: next, featureConfigurations: featureConfigurations)
    }

    public func addingProvider(_ provider: AIProviderProfile) -> AISettings {
        guard !providers.contains(where: { $0.id == provider.id }) else { return self }
        return sanitized(providers: providers + [provider], featureConfigurations: featureConfigurations)
    }

    public func deletingProvider(id: String) -> AISettings {
        guard let target = provider(id: id), !target.isBuiltIn else { return self }
        let next = providers.filter { $0.id != id }
        return sanitized(providers: next, featureConfigurations: featureConfigurations)
    }

    public func selectingProvider(id: String) -> AISettings {
        guard providers.contains(where: { $0.id == id }) else { return self }
        return AISettings(activeProviderID: id, providers: providers, features: features, featureConfigurations: featureConfigurations, schema: schema)
    }

    public func updatingFeatures(_ features: AIFeaturePreferences) -> AISettings {
        AISettings(activeProviderID: activeProviderID, providers: providers, features: features, featureConfigurations: featureConfigurations, schema: schema)
    }

    public func updatingFeature(
        _ kind: AIFeatureKind,
        configuration: AIFeatureConfiguration
    ) -> AISettings {
        var next = resolvedFeatureConfigurations()
        next[kind] = configuration
        return sanitized(providers: providers, featureConfigurations: next)
    }

    public func deletingModel(providerID: String, modelID: String) -> AISettings {
        guard var provider = provider(id: providerID) else { return self }
        provider.models.removeAll { $0.id == modelID }
        if provider.selectedModelID == modelID {
            provider.selectedModelID = provider.models.first?.id ?? ""
        }
        var configurations = resolvedFeatureConfigurations()
        let localFallback = provider.models.first.map {
            AIModelReference(providerID: providerID, modelID: $0.id)
        }
        for kind in AIFeatureKind.allCases
        where configurations[kind]?.model == AIModelReference(providerID: providerID, modelID: modelID) {
            configurations[kind]?.model = localFallback
        }
        var nextProviders = providers
        if let index = nextProviders.firstIndex(where: { $0.id == providerID }) {
            nextProviders[index] = provider
        }
        return sanitized(providers: nextProviders, featureConfigurations: configurations)
    }

    public static func migratedCustomProviderID(for builtInID: String) -> String {
        "custom.migrated.\(builtInID.replacingOccurrences(of: "builtin.", with: ""))"
    }

    /// Normalizes the v2 document without discarding a user-modified built-in
    /// endpoint. Such an endpoint becomes a stable custom profile while the
    /// built-in profile returns to its official connection identity.
    public func migratedToCurrentSchema() -> AISettings {
        let referencedModelIDs = Dictionary(grouping: (featureConfigurations ?? [:]).values.compactMap(\.model), by: \.providerID)
            .mapValues { Set($0.map(\.modelID)) }

        func migratedModels(for provider: AIProviderProfile) -> [AIModelOption] {
            var models = provider.models
            if schema < 4 {
                models = models.map { model in
                    var migrated = model
                    migrated.reasoningMode = provider.reasoningMode
                    migrated.temperature = provider.temperature
                    return migrated
                }
            }
            guard schema < 5 else { return models }
            var retainedIDs = referencedModelIDs[provider.id] ?? []
            if !provider.selectedModelID.isEmpty { retainedIDs.insert(provider.selectedModelID) }
            return models.filter { model in
                model.source == .manual || retainedIDs.contains(model.id)
            }.map { model in
                var migrated = model
                // From v5 onward every configured model was explicitly added,
                // even when its identifier originated from a remote catalog.
                migrated.source = .manual
                return migrated
            }
        }

        var result: [AIProviderProfile] = []
        var activeID = activeProviderID
        let defaults = Self.default.providers
        let builtInIDs = Set(defaults.map(\.id))
        var customProviders = providers.filter { !builtInIDs.contains($0.id) }.map {
            $0.replacing(models: migratedModels(for: $0))
        }

        for canonical in defaults {
            guard let existing = provider(id: canonical.id) else {
                result.append(canonical)
                continue
            }
            let oldBase = existing.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let officialBase = canonical.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if oldBase != officialBase {
                let customID = Self.migratedCustomProviderID(for: existing.id)
                if !customProviders.contains(where: { $0.id == customID }) {
                    customProviders.append(AIProviderProfile(
                        id: customID,
                        kind: .customOpenAICompatible,
                        isEnabled: existing.isEnabled,
                        name: existing.name,
                        description: existing.description,
                        baseURL: existing.baseURL,
                        selectedModelID: existing.selectedModelID,
                        models: migratedModels(for: existing),
                        reasoningMode: existing.reasoningMode,
                        temperature: existing.temperature,
                        allowInsecureLocalEndpoint: existing.allowInsecureLocalEndpoint
                    ))
                }
                if activeID == existing.id { activeID = customID }
            }

            let selectedModel = canonical.id == AIProviderID.gemini && existing.selectedModelID == "gemini-3.7-flash"
                ? "gemini-3.8-flash"
                : existing.selectedModelID
            result.append(AIProviderProfile(
                id: canonical.id,
                kind: canonical.kind,
                isEnabled: existing.isEnabled,
                name: canonical.name,
                description: canonical.description,
                baseURL: canonical.baseURL,
                selectedModelID: selectedModel,
                models: migratedModels(for: existing),
                reasoningMode: existing.reasoningMode,
                temperature: existing.temperature,
                allowInsecureLocalEndpoint: false
            ))
        }

        result.append(contentsOf: customProviders)
        let migratedConfigurations: [AIFeatureKind: AIFeatureConfiguration]
        if schema >= Self.schemaVersion, let featureConfigurations {
            migratedConfigurations = featureConfigurations
        } else if schema >= 4, let featureConfigurations {
            migratedConfigurations = featureConfigurations.mapValues { configuration in
                guard let reference = configuration.model,
                      let provider = providers.first(where: { $0.id == reference.providerID }) else {
                    return configuration
                }
                let legacyReasoning = provider.models.first(where: { $0.id == reference.modelID })?.reasoningMode
                    ?? provider.reasoningMode
                return AIFeatureConfiguration(
                    isEnabled: configuration.isEnabled,
                    model: reference,
                    reasoningMode: legacyReasoning
                )
            }
        } else {
            let selectedProvider = result.first(where: { $0.id == activeID }) ?? result.first
            let reference = selectedProvider.map {
                AIModelReference(providerID: $0.id, modelID: $0.selectedModelID)
            }
            migratedConfigurations = Dictionary(uniqueKeysWithValues: AIFeatureKind.allCases.map {
                ($0, AIFeatureConfiguration(
                    isEnabled: legacyEnabledState(for: $0),
                    model: reference,
                    reasoningMode: selectedProvider?.reasoningMode ?? "自动"
                ))
            })
        }
        let settings = AISettings(
            activeProviderID: activeID,
            providers: result,
            features: features,
            featureConfigurations: migratedConfigurations,
            schema: Self.schemaVersion
        )
        return settings.sanitized(providers: settings.providers, featureConfigurations: migratedConfigurations)
    }

    /// Converts the old single configuration into one active profile without
    /// discarding any field. Built-in IDs are reused only for recognizable
    /// official endpoints; arbitrary endpoints receive a stable migration ID.
    public static func migrated(from configuration: LLMConfiguration) -> AISettings {
        let normalizedBaseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let target: (id: String, kind: AIProviderKind)
        if configuration.usesDeepSeekAPI {
            target = (AIProviderID.deepSeek, .deepSeek)
        } else if normalizedBaseURL == "https://api.openai.com/v1" {
            target = (AIProviderID.openAI, .openAICompatible)
        } else if normalizedBaseURL == "https://generativelanguage.googleapis.com/v1beta/openai" {
            target = (AIProviderID.gemini, .gemini)
        } else {
            target = (AIProviderID.migratedLegacy, .customOpenAICompatible)
        }

        var providers = AISettings.default.providers
        let profile = AIProviderProfile(id: target.id, kind: target.kind, configuration: configuration)
        if let index = providers.firstIndex(where: { $0.id == target.id }) {
            providers[index] = profile
        } else {
            providers.insert(profile, at: 0)
        }
        return AISettings(
            activeProviderID: target.id,
            providers: providers,
            features: AIFeaturePreferences(configuration: configuration),
            schema: 3
        ).migratedToCurrentSchema()
    }

    private func legacyEnabledState(for kind: AIFeatureKind) -> Bool {
        switch kind {
        case .summary: features.showsAISummary
        case .bilingualTranslation: true
        case .selectionTranslation: features.showsSelectionTranslation
        case .selectionExplanation: features.showsSelectionExplanation
        case .selectionAsk: features.showsSelectionAsk
        }
    }

    private func resolvedFeatureConfigurations() -> [AIFeatureKind: AIFeatureConfiguration] {
        Dictionary(uniqueKeysWithValues: AIFeatureKind.allCases.compactMap { kind in
            configuration(for: kind).map { (kind, $0) }
        })
    }

    private func sanitized(
        providers nextProviders: [AIProviderProfile],
        featureConfigurations configurations: [AIFeatureKind: AIFeatureConfiguration]?
    ) -> AISettings {
        let fallback = nextProviders.lazy.compactMap { provider -> AIModelReference? in
            guard provider.isEnabled else { return nil }
            guard let modelID = provider.models.first?.id else { return nil }
            return AIModelReference(providerID: provider.id, modelID: modelID)
        }.first
        var nextConfigurations = configurations ?? resolvedFeatureConfigurations()
        for kind in AIFeatureKind.allCases {
            var configuration = nextConfigurations[kind]
                ?? AIFeatureConfiguration(
                    isEnabled: legacyEnabledState(for: kind),
                    model: fallback,
                    reasoningMode: "自动"
                )
            let isValid = configuration.model.map { reference in
                nextProviders.contains { provider in
                    provider.id == reference.providerID
                        && provider.models.contains(where: { $0.id == reference.modelID })
                }
            } ?? false
            if !isValid {
                configuration.model = fallback
                if fallback == nil { configuration.isEnabled = false }
            }
            nextConfigurations[kind] = configuration
        }
        return AISettings(
            activeProviderID: nextProviders.contains(where: { $0.id == activeProviderID })
                ? activeProviderID
                : nextProviders.first?.id ?? AIProviderID.deepSeek,
            providers: nextProviders,
            features: features,
            featureConfigurations: nextConfigurations,
            schema: Self.schemaVersion
        )
    }
}

/// Immutable, credential-free description of the settings that can affect an
/// AI result. API keys deliberately do not participate in this value.
public struct AIExecutionContext: Hashable, Sendable {
    public let providerID: String
    public let providerKind: AIProviderKind
    public let configuration: LLMConfiguration

    public init(
        providerID: String,
        providerKind: AIProviderKind,
        configuration: LLMConfiguration
    ) {
        self.providerID = providerID
        self.providerKind = providerKind
        self.configuration = configuration
    }

    public func fingerprint(for kind: AIArtifactKind, promptVersion: Int) -> String {
        let normalizedBaseURL = configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let normalizedModel = configuration.model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let effectiveReasoning: String
        switch providerKind {
        case .gemini where normalizedModel.hasPrefix("gemini-3"):
            effectiveReasoning = ["低", "中", "高"].contains(configuration.reasoningMode)
                ? configuration.reasoningMode
                : "provider-default"
        default:
            effectiveReasoning = configuration.reasoningMode
        }
        let effectiveTemperature = providerKind == .gemini && normalizedModel.hasPrefix("gemini-3")
            ? "omitted"
            : String(configuration.temperature)

        let payload = [
            "ai-execution-v1",
            kind.rawValue,
            providerID,
            providerKind.rawValue,
            normalizedBaseURL,
            normalizedModel,
            configuration.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines),
            effectiveReasoning,
            effectiveTemperature,
            String(promptVersion),
            configuration.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).stableDigest
        ].joined(separator: "|")
        return "v1:\(payload.stableDigest)"
    }
}
