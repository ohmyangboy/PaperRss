import Foundation

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
        case .invalidBaseURL: "Base URL 无效。"
        case .insecureEndpoint: "仅允许 HTTPS；局域网 HTTP 需在设置中明确开启。"
        case .invalidResponse: "模型返回的内容无法识别。"
        case .emptyResponse: "模型没有返回文本。"
        case .authenticationFailed: "身份验证失败。请在设置中检查 DeepSeek API Key 是否有效、完整且仍有权限。"
        case .rateLimited: "请求过于频繁或当前额度受限。请稍后重试，并检查服务商账户额度。"
        case .missingAPIKey: "尚未设置 API Key。请先在设置中完成 AI 服务配置。"
        case .requestInProgress: "已有 AI 任务正在进行，请稍后再试。"
        case let .httpStatus(code, message): "模型接口返回 HTTP \(code)：\(message)"
        }
    }
}

public struct LLMService: Sendable {
    public init() {}

    public func test(configuration: LLMConfiguration, apiKey: String) async throws {
        _ = try await complete(prompt: "Reply with exactly OK.", system: "You are a connectivity test.", configuration: configuration, apiKey: apiKey)
    }

    public func complete(
        prompt: String,
        system: String,
        configuration: LLMConfiguration,
        apiKey: String,
        onDelta: (@Sendable (String) async -> Void)? = nil,
        forceDisableReasoning: Bool = false
    ) async throws -> String {
        let urlRequest = try makeRequest(
            prompt: prompt,
            system: system,
            configuration: configuration,
            apiKey: apiKey,
            stream: onDelta != nil,
            forceDisableReasoning: forceDisableReasoning
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
                    forceDisableReasoning: forceDisableReasoning
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
        try await complete(
            prompt: """
            Article context memo:
            \(ArticleChunker.truncate(articleContext, maximumCharacters: 10_000))

            Nearby paragraphs:
            \(ArticleChunker.truncate(localContext, maximumCharacters: 5_000))

            Selected passage:
            \(ArticleChunker.truncate(selection, maximumCharacters: 4_000))
            """,
            system: "Explain the selected passage within this article in \(configuration.targetLanguage). Give only the key meaning and its role in the surrounding argument. Distinguish article facts from your inference. Do not restate the quote, add headings, greetings, or unrelated background. Keep it concise: 1 short paragraph, at most 120 Chinese characters (or about 70 English words).",
            configuration: configuration,
            apiKey: apiKey,
            onDelta: onDelta,
            // Selection explanations are an interactive reader gesture. Keep
            // DeepSeek's hidden reasoning off so the first visible delta is
            // not delayed by a reasoning trace the reader never sees.
            forceDisableReasoning: true
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
            onDelta: onDelta,
            // Translation is an extraction task rather than a reasoning task.
            // DeepSeek's automatic thinking can materially delay the first
            // visible paragraph while adding no reader-facing value.
            forceDisableReasoning: true
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
            apiKey: apiKey,
            forceDisableReasoning: true
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
        forceDisableReasoning: Bool = false
    ) throws -> URLRequest {
        guard var base = URLComponents(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LLMServiceError.invalidBaseURL }
        guard base.scheme == "https" || (configuration.allowInsecureLocalEndpoint && base.scheme == "http") else { throw LLMServiceError.insecureEndpoint }
        let root = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        base.path = root + "/chat/completions"
        guard let url = base.url else { throw LLMServiceError.invalidBaseURL }
        struct Message: Encodable { let role: String; let content: String }
        struct Thinking: Encodable { let type: String }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
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
        request.httpBody = try JSONEncoder().encode(Body(model: configuration.model, messages: [Message(role: "system", content: system), Message(role: "user", content: prompt)], temperature: configuration.temperature, stream: stream, thinking: deepSeekReasoning.0, reasoningEffort: deepSeekReasoning.1))
        return request
    }

    private func nonStreaming(request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let choices: [Choice] }
        guard let result = try? JSONDecoder().decode(Response.self, from: data), let text = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw LLMServiceError.invalidResponse }
        return text
    }

    private func stream(request: URLRequest, onDelta: @Sendable (String) async -> Void) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw LLMServiceError.invalidResponse }
        var output = ""
        for try await line in bytes.lines {
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

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw LLMServiceError.authenticationFailed }
            if http.statusCode == 429 { throw LLMServiceError.rateLimited }
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.description ?? String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw LLMServiceError.httpStatus(http.statusCode, body)
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
