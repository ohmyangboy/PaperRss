import Foundation

public struct AIModelHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public struct AIModelEventResponse: Sendable {
    public let statusCode: Int
    public let lines: AsyncThrowingStream<String, Error>

    public init(statusCode: Int, lines: AsyncThrowingStream<String, Error>) {
        self.statusCode = statusCode
        self.lines = lines
    }
}

public protocol AIModelPort: Sendable {
    func data(for request: URLRequest) async throws -> AIModelHTTPResponse
    func events(for request: URLRequest) async throws -> AIModelEventResponse
}

public struct URLSessionAIModelAdapter: AIModelPort, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMServiceError.invalidResponse }
        return AIModelHTTPResponse(statusCode: http.statusCode, data: data)
    }

    public func events(for request: URLRequest) async throws -> AIModelEventResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMServiceError.invalidResponse }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return AIModelEventResponse(statusCode: http.statusCode, lines: lines)
    }
}

public enum LLMServiceError: LocalizedError, Sendable {
    case invalidBaseURL
    case insecureEndpoint
    case invalidResponse
    case emptyResponse
    case authenticationFailed
    case rateLimited
    case missingAPIKey
    case requestInProgress
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: I18N.localized("Base URL 无效。")
        case .insecureEndpoint: I18N.localized("仅允许 HTTPS；局域网 HTTP 需在设置中明确开启。")
        case .invalidResponse: I18N.localized("模型返回的内容无法识别。")
        case .emptyResponse: I18N.localized("模型没有返回文本。")
        case .authenticationFailed: I18N.localized(
            "身份验证失败。请在设置中检查当前供应商的 API Key 是否有效、完整且仍有权限。",
            englishFallback: "Authentication failed. Check that the current provider's API key is complete, valid, and still authorized."
        )
        case .rateLimited: I18N.localized("请求过于频繁或当前额度受限。请稍后重试，并检查服务商账户额度。")
        case .missingAPIKey: I18N.localized("尚未设置 API Key。请先在设置中完成 AI 服务配置。")
        case .requestInProgress: I18N.localized("已有 AI 任务正在进行，请稍后再试。")
        case let .httpStatus(code, message): I18N.localizedFormat("模型接口返回 HTTP %lld：%@", arguments: [code, message])
        }
    }
}

public struct LLMService: Sendable {
    private let port: any AIModelPort

    public init(port: any AIModelPort = URLSessionAIModelAdapter()) {
        self.port = port
    }

    public func test(configuration: LLMConfiguration, apiKey: String) async throws {
        _ = try await complete(prompt: "Reply with exactly OK.", system: "You are a connectivity test.", configuration: configuration, apiKey: apiKey)
    }

    /// Fetches the OpenAI-compatible model catalog for a provider. Gemini's
    /// official compatibility endpoint exposes the same `/models` shape, so a
    /// single request contract works for built-in and custom providers.
    public func fetchModels(configuration: LLMConfiguration, apiKey: String) async throws -> [String] {
        let request = try makeModelsRequest(configuration: configuration, apiKey: apiKey)
        let response = try await port.data(for: request)
        try validate(statusCode: response.statusCode, data: response.data)
        struct Model: Decodable { let id: String }
        struct Response: Decodable { let data: [Model] }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: response.data) else {
            throw LLMServiceError.invalidResponse
        }
        let ids = decoded.data.map(\.id)
            .map { normalizedModelID($0, configuration: configuration) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw LLMServiceError.invalidResponse }
        return ids
    }

    public func complete(
        prompt: String,
        system: String,
        configuration: LLMConfiguration,
        apiKey: String,
        onDelta: (@Sendable (String) async -> Void)? = nil,
        forceDisableReasoning: Bool = false,
        overrideTemperature: Double? = nil
    ) async throws -> String {
        let urlRequest = try makeRequest(
            prompt: prompt,
            system: system,
            configuration: configuration,
            apiKey: apiKey,
            stream: onDelta != nil,
            forceDisableReasoning: forceDisableReasoning,
            overrideTemperature: overrideTemperature
        )
        if let onDelta {
            do { return try await stream(request: urlRequest, onDelta: onDelta) }
            catch LLMServiceError.emptyResponse {
                // Some OpenAI-compatible servers accept `stream: true` but
                // return a normal JSON completion. Retry only in that case;
                // retrying network/auth/rate-limit failures risks duplicate
                // requests and misleading error messages.
                let fallback = try makeRequest(
                    prompt: prompt,
                    system: system,
                    configuration: configuration,
                    apiKey: apiKey,
                    stream: false,
                    forceDisableReasoning: forceDisableReasoning,
                    overrideTemperature: overrideTemperature
                )
                let text = try await nonStreaming(request: fallback)
                await onDelta(text)
                return text
            }
        }
        return try await nonStreaming(request: urlRequest)
    }

    public func summary(text: String, configuration: LLMConfiguration, apiKey: String, onDelta: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        try await complete(
            prompt: "Article:\n\n\(ArticleChunker.truncate(text, maximumCharacters: 28_000))",
            system: "Summarize the article in \(configuration.targetLanguage). Start with one concise conclusion, then give 3 to 7 factual bullets. Do not invent sources or facts.",
            configuration: configuration, apiKey: apiKey, onDelta: onDelta
        )
    }

    public func articleContext(
        text: String,
        configuration: LLMConfiguration,
        apiKey: String
    ) async throws -> String {
        try await complete(
            prompt: """
            Article:

            \(ArticleChunker.contextualArticle(text, around: "", maximumCharacters: 60_000))
            """,
            system: "Create a compact reusable context memo for later questions about this article, in \(configuration.targetLanguage). Preserve the thesis, section structure, key entities, definitions, evidence, and relationships between claims. State only what the article says. Use concise structured prose and keep the memo under 1,200 words.",
            configuration: configuration,
            apiKey: apiKey
        )
    }

    public func explainSelection(
        selection: String,
        localContext: String,
        articleContext: String,
        configuration: LLMConfiguration,
        apiKey: String,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        var systemPrompt = """
        你是一位清晰、讲人话的阅读助手。读者在阅读文章时划选了一段文字（由于划词操作可能存在 1-2 行误差，请自动定位读者真正未理解的核心语句或名词概念），请用\(configuration.targetLanguage)进行通俗解构。

        回答准则：
        1. 直白解读：直接用平实、易懂的语言解释这句话或关键句到底在表达什么意思。
        2. 术语与概念拆解：若划选内容中包含专业术语、缩写、技术名词或暗喻，单列并简要解释清楚。
        3. 严禁事项：绝对禁止分析文章结构、段落作用、修辞手法、起承转合或“呼应上下文/前文”等阅读理解式套话。只聚焦于帮助读者看懂语句本身。
        4. 格式与字数：保持简洁直接（控制在 100-180 个字左右），不要重复引用原文，不要使用问候套话。
        """
        let trimmedCustom = configuration.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            systemPrompt += "\n\nAdditional user preference: \(trimmedCustom)"
        }
        return try await complete(
            prompt: """
            Article context memo:
            \(ArticleChunker.truncate(articleContext, maximumCharacters: 10_000))

            Nearby paragraphs:
            \(ArticleChunker.truncate(localContext, maximumCharacters: 5_000))

            Selected passage:
            \(ArticleChunker.truncate(selection, maximumCharacters: 4_000))
            """,
            system: systemPrompt,
            configuration: configuration,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    public func askSelection(
        selection: String,
        question: String,
        localContext: String,
        articleContext: String,
        configuration: LLMConfiguration,
        apiKey: String,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        var systemPrompt = """
        你是一位渊博且贴心的阅读助手。读者正在阅读一篇文章，并针对划选的文本提出了具体问题。请结合划选内容与文章上下文，用\(configuration.targetLanguage)进行针对性回答。

        回答准则：
        1. 针对性解答：切中读者提问的核心，直接回答问题，语言平实易懂。
        2. 结合划选文本：紧扣划选段落与上下文，拆解相关专业概念或逻辑。
        3. 严禁事项：绝对禁止分析文章结构起承转合，不要重复问题或完整引用原文，不要使用问候套话。
        4. 格式与字数：控制在 120-220 字左右，可适度使用 Markdown 加粗或短列表。
        """
        let trimmedCustom = configuration.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            systemPrompt += "\n\n额外用户偏好指令：\(trimmedCustom)"
        }
        return try await complete(
            prompt: """
            文章全局上下文:
            \(ArticleChunker.truncate(articleContext, maximumCharacters: 10_000))

            划选段落上下文:
            \(ArticleChunker.truncate(localContext, maximumCharacters: 5_000))

            划选文本:
            \(ArticleChunker.truncate(selection, maximumCharacters: 4_000))

            读者的提问:
            \(ArticleChunker.truncate(question, maximumCharacters: 1_000))
            """,
            system: systemPrompt,
            configuration: configuration,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    public func translate(
        paragraph: String,
        configuration: LLMConfiguration,
        apiKey: String,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        try await complete(
            prompt: paragraph,
            system: "Translate the following passage into \(configuration.targetLanguage). Preserve meaning, tone, numbers, names, links, and Markdown. Return only the translation.",
            configuration: configuration,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    /// Sends adjacent reader blocks together.  One request removes the repeated
    /// system-prompt and connection overhead of several single-paragraph calls,
    /// while the ordered JSON result lets the caller keep each translation next
    /// to its original block.  Callers deliberately fall back to `translate`
    /// when a provider cannot keep the response shape.
    public func translateBatch(paragraphs: [String], configuration: LLMConfiguration, apiKey: String) async throws -> [String] {
        guard !paragraphs.isEmpty else { return [] }
        guard paragraphs.count > 1 else {
            return [try await translate(paragraph: paragraphs[0], configuration: configuration, apiKey: apiKey)]
        }

        let source = try JSONEncoder().encode(paragraphs)
        let prompt = """
        Translate every string in this JSON array into \(configuration.targetLanguage).
        Keep array order exactly unchanged. Preserve meaning, tone, numbers, names, links, and Markdown.
        Return ONLY a valid JSON array of translated strings: no Markdown fence, no explanation, and no omitted item.

        \(String(decoding: source, as: UTF8.self))
        """
        let output = try await complete(
            prompt: prompt,
            system: "You are a precise translation engine. The response must be valid JSON and must contain exactly one translated string for every input string.",
            configuration: configuration,
            apiKey: apiKey
        )
        let translations = try Self.decodeBatchTranslations(output)
        guard translations.count == paragraphs.count,
              translations.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LLMServiceError.invalidResponse
        }
        return translations
    }

    /// Accept the two harmless wrappers commonly returned by OpenAI-compatible
    /// services (a fenced array or `{ "translations": [...] }`) without ever
    /// guessing at order.  Keeping this deterministic is important: a malformed
    /// batch must retry as single paragraphs rather than attach a translation to
    /// the wrong source block.
    static func decodeBatchTranslations(_ response: String) throws -> [String] {
        var payload = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```") {
            guard let firstNewline = payload.firstIndex(of: "\n") else { throw LLMServiceError.invalidResponse }
            payload = String(payload[payload.index(after: firstNewline)...])
            if let closing = payload.range(of: "```", options: .backwards) {
                payload = String(payload[..<closing.lowerBound])
            }
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let values = try? JSONDecoder().decode([String].self, from: Data(payload.utf8)) {
            return values
        }
        struct Wrapped: Decodable { let translations: [String] }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: Data(payload.utf8)) {
            return wrapped.translations
        }
        throw LLMServiceError.invalidResponse
    }

    /// Builds the OpenAI-compatible request used by both the connection check
    /// and every AI action. Internal visibility lets the test suite assert the
    /// exact provider contract without ever issuing a network request.
    func makeRequest(
        prompt: String,
        system: String,
        configuration: LLMConfiguration,
        apiKey: String,
        stream: Bool,
        forceDisableReasoning: Bool = false,
        overrideTemperature: Double? = nil
    ) throws -> URLRequest {
        guard var base = URLComponents(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LLMServiceError.invalidBaseURL }
        try validateEndpoint(base, allowInsecureLocalEndpoint: configuration.allowInsecureLocalEndpoint)
        let root = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        base.path = root + "/chat/completions"
        guard let url = base.url else { throw LLMServiceError.invalidBaseURL }
        struct Message: Encodable { let role: String; let content: String }
        struct Thinking: Encodable { let type: String }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double?
            let stream: Bool
            let thinking: Thinking?
            let reasoningEffort: String?

            enum CodingKeys: String, CodingKey {
                case model, messages, temperature, stream, thinking
                case reasoningEffort = "reasoning_effort"
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let deepSeekReasoning: (Thinking?, String?)
        if configuration.usesDeepSeekAPI, forceDisableReasoning {
            deepSeekReasoning = (Thinking(type: "disabled"), nil)
        } else if configuration.usesDeepSeekAPI {
            switch configuration.reasoningMode {
            case "关闭": deepSeekReasoning = (Thinking(type: "disabled"), nil)
            case "低": deepSeekReasoning = (Thinking(type: "enabled"), "low")
            case "中": deepSeekReasoning = (Thinking(type: "enabled"), "medium")
            case "高": deepSeekReasoning = (Thinking(type: "enabled"), "high")
            default: deepSeekReasoning = (Thinking(type: "enabled"), nil)
            }
        } else {
            deepSeekReasoning = (nil, nil)
        }
        // Gemini's OpenAI-compatible endpoint accepts the standard
        // `reasoning_effort` field. Gemini 3 models cannot disable thinking,
        // so "关闭"/automatic intentionally omit the field and let Google
        // choose the model default.
        let geminiReasoningEffort: String?
        if configuration.usesGeminiAPI {
            let geminiModel = configuration.model
                .replacingOccurrences(of: "models/", with: "")
                .lowercased()
            switch configuration.reasoningMode {
            case "关闭" where geminiModel.hasPrefix("gemini-2.5") && !geminiModel.contains("pro"):
                geminiReasoningEffort = "none"
            case "低": geminiReasoningEffort = "low"
            case "中": geminiReasoningEffort = "medium"
            case "高": geminiReasoningEffort = "high"
            default: geminiReasoningEffort = nil
            }
        } else {
            geminiReasoningEffort = nil
        }
        // Gemini 3.x rejects the deprecated sampling knobs (temperature,
        // top_p and top_k). Keep the setting for other providers and omit it
        // for the official Gemini 3 compatibility endpoint.
        let normalizedModel = normalizedModelID(configuration.model, configuration: configuration)
        let supportsTemperature = !(configuration.usesGeminiAPI && normalizedModel.lowercased().hasPrefix("gemini-3"))
        let temp = supportsTemperature ? (overrideTemperature ?? configuration.temperature) : nil
        request.httpBody = try JSONEncoder().encode(Body(model: normalizedModel, messages: [Message(role: "system", content: system), Message(role: "user", content: prompt)], temperature: temp, stream: stream, thinking: deepSeekReasoning.0, reasoningEffort: deepSeekReasoning.1 ?? geminiReasoningEffort))
        return request
    }

    private func normalizedModelID(_ modelID: String, configuration: LLMConfiguration) -> String {
        let cleanID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.usesGeminiAPI, cleanID.hasPrefix("models/") else { return cleanID }
        return String(cleanID.dropFirst("models/".count))
    }

    func makeModelsRequest(configuration: LLMConfiguration, apiKey: String) throws -> URLRequest {
        guard var base = URLComponents(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LLMServiceError.invalidBaseURL }
        try validateEndpoint(base, allowInsecureLocalEndpoint: configuration.allowInsecureLocalEndpoint)
        let root = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        base.path = root + "/models"
        guard let url = base.url else { throw LLMServiceError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func validateEndpoint(
        _ components: URLComponents,
        allowInsecureLocalEndpoint: Bool
    ) throws {
        guard let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { throw LLMServiceError.invalidBaseURL }
        let normalizedPath = components.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.hasSuffix("models"),
              !normalizedPath.hasSuffix("chat/completions") else {
            throw LLMServiceError.invalidBaseURL
        }
        if scheme == "https" { return }
        guard scheme == "http", allowInsecureLocalEndpoint else {
            throw LLMServiceError.insecureEndpoint
        }
        let isLocalName = host == "localhost" || host.hasSuffix(".local")
        let octets = host.split(separator: ".").compactMap { Int($0) }
        let isPrivateIPv4 = octets.count == 4 && (
            octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 127)
                || (octets[0] == 169 && octets[1] == 254)
        )
        let isLocalIPv6 = host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        guard isLocalName || isPrivateIPv4 || isLocalIPv6 else {
            throw LLMServiceError.insecureEndpoint
        }
    }

    private func nonStreaming(request: URLRequest) async throws -> String {
        let response = try await port.data(for: request)
        try validate(statusCode: response.statusCode, data: response.data)
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let choices: [Choice] }
        guard let result = try? JSONDecoder().decode(Response.self, from: response.data), let text = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw LLMServiceError.invalidResponse }
        return text
    }

    private func stream(request: URLRequest, onDelta: @Sendable (String) async -> Void) async throws -> String {
        let response = try await port.events(for: request)
        guard (200...299).contains(response.statusCode) else {
            // URLSession.bytes exposes the response before its body. Preserve
            // the same stable error categories as the JSON path without
            // buffering or logging a provider's response (which may contain
            // sensitive request context).
            if response.statusCode == 401 || response.statusCode == 403 { throw LLMServiceError.authenticationFailed }
            if response.statusCode == 429 { throw LLMServiceError.rateLimited }
            throw LLMServiceError.httpStatus(response.statusCode, "")
        }
        var output = ""
        for try await line in response.lines {
            guard line.hasPrefix("data:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { break }
            guard let data = value.data(using: .utf8) else { continue }
            struct Chunk: Decodable { struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }; let choices: [Choice] }
            if let chunk = try? JSONDecoder().decode(Chunk.self, from: data), let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                output += delta
                await onDelta(delta)
            }
        }
        guard !output.isEmpty else { throw LLMServiceError.emptyResponse }
        return output
    }

    private func validate(statusCode: Int, data: Data) throws {
        guard (200...299).contains(statusCode) else {
            if statusCode == 401 || statusCode == 403 { throw LLMServiceError.authenticationFailed }
            if statusCode == 429 { throw LLMServiceError.rateLimited }
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.description ?? String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw LLMServiceError.httpStatus(statusCode, body)
        }
    }
}

public enum ArticleChunker {
    public static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Keeps one source paragraph per translation unit whenever possible. An
    /// unusually long paragraph is split only at sentence-like boundaries, so
    /// each unit can be translated and rendered independently.
    public static func translationSegments(_ text: String, maximumCharacters: Int = 5_000) -> [String] {
        paragraphs(text).flatMap { paragraph in
            guard paragraph.count > maximumCharacters else { return [paragraph] }
            var result: [String] = []
            var remainder = paragraph[...]
            while remainder.count > maximumCharacters {
                let ceiling = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
                let boundary = remainder[..<ceiling].lastIndex(where: { ".!?。！？；;".contains($0) })
                let end = boundary.map { remainder.index(after: $0) } ?? ceiling
                result.append(String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
                remainder = remainder[end...]
            }
            let tail = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { result.append(tail) }
            return result
        }
    }

    public static func truncate(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maximumCharacters)
        return String(text[..<end]) + "\n\n[Content truncated for this operation]"
    }

    /// Most articles fit in the model request unchanged. For unusually long
    /// pages, retain the opening, the exact neighborhood of the selection, and
    /// the ending so the model sees both local meaning and whole-article shape.
    public static func contextualArticle(
        _ text: String,
        around selection: String,
        maximumCharacters: Int
    ) -> String {
        guard text.count > maximumCharacters else { return text }

        let edgeBudget = min(8_000, maximumCharacters / 5)
        let neighborhoodBudget = maximumCharacters - edgeBudget * 2
        let opening = String(text.prefix(edgeBudget))
        let ending = String(text.suffix(edgeBudget))

        let neighborhood: String
        if let range = text.range(of: selection), !selection.isEmpty {
            let selectionOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let startOffset = max(0, selectionOffset - neighborhoodBudget / 2)
            let start = text.index(text.startIndex, offsetBy: startOffset)
            let remaining = text.distance(from: start, to: text.endIndex)
            let end = text.index(start, offsetBy: min(neighborhoodBudget, remaining))
            neighborhood = String(text[start..<end])
        } else {
            let middleOffset = max(0, (text.count - neighborhoodBudget) / 2)
            let start = text.index(text.startIndex, offsetBy: middleOffset)
            let end = text.index(start, offsetBy: min(neighborhoodBudget, text.distance(from: start, to: text.endIndex)))
            neighborhood = String(text[start..<end])
        }

        return """
        [Article opening]
        \(opening)

        [Selection neighborhood]
        \(neighborhood)

        [Article ending]
        \(ending)
        """
    }
}
