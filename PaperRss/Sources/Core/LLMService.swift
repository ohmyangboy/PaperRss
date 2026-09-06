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
    case unsupportedReasoning
    case truncatedResponse
    case invalidBaseURL
    case insecureEndpoint
    case invalidResponse
    case emptyResponse
    case authenticationFailed
    case rateLimited
    case missingAPIKey
    case requestInProgress
    case translationOnly
    case unsupportedTranslationLanguage
    case inconclusiveTranslationProbe
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedReasoning: I18N.localized("当前思考选项未获此接口支持，请重新选择思考模式。", englishFallback: "Select a reasoning mode supported by this endpoint.")
        case .truncatedResponse: I18N.localized("模型输出被截断，请缩短输入后重试。", englishFallback: "Model output was truncated. Shorten the input and retry.")
        case .translationOnly: I18N.localized("当前模型适配仅用于翻译，请为此功能选择其他模型。", englishFallback: "This adapter is for translation. Select another model for this feature.")
        case .unsupportedTranslationLanguage: I18N.localized("翻译接口不支持此目标语言，请填写支持的语言名称或代码。", englishFallback: "The translation adapter does not support this target language. Enter a supported language name or code.")
        case .inconclusiveTranslationProbe: I18N.localized("翻译协议探测未能确认目标语言生效，请检查模型说明或手动选择适配。", englishFallback: "The probe could not confirm the target languages. Check the model documentation or choose an adapter manually.")
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
        if configuration.usesTranslationAdaptation {
            _ = try await translate(paragraph: "The library opens tomorrow morning.", configuration: configuration, apiKey: apiKey)
        } else {
            _ = try await complete(prompt: "Reply with exactly OK.", system: "You are a connectivity test.", configuration: configuration, apiKey: apiKey)
        }
    }

    /// Fetches the OpenAI-compatible model catalog for a provider. Gemini's
    /// official compatibility endpoint exposes the same `/models` shape, so a
    /// single request contract works for built-in and custom providers.
    public func fetchModels(configuration: LLMConfiguration, apiKey: String) async throws -> [String] {
        try await fetchModelOptions(configuration: configuration, apiKey: apiKey).map(\.id)
    }

    public func fetchModelOptions(configuration: LLMConfiguration, apiKey: String) async throws -> [AIModelOption] {
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
        let raw = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let entries = raw?["data"] as? [[String: Any]] ?? []
        return ids.map { id in
            var option = AIModelOption(id: id, source: .remote)
            if configuration.reasoningCapabilities.wireProtocol == .openRouter,
               let entry = entries.first(where: { ($0["id"] as? String) == id }),
               let reasoning = entry["reasoning"] as? [String: Any] {
                let efforts: [String]
                if reasoning["supported_efforts"] is NSNull {
                    efforts = ["minimal", "low", "medium", "high", "xhigh", "max"]
                } else { efforts = reasoning["supported_efforts"] as? [String] ?? [] }
                option.reasoningMetadata = AIReasoningMetadata(modelID: id, endpoint: configuration.reasoningEndpoint, fetchedAt: Date(), efforts: efforts.filter { $0 != "none" }, canDisable: reasoning["mandatory"] as? Bool == false, supportsThinking: true)
            }
            return option
        }
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
        guard !configuration.usesTranslationAdaptation else { throw LLMServiceError.translationOnly }
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
        if configuration.usesTranslationAdaptation {
            let request = try makeTranslationRequest(paragraph: paragraph, configuration: configuration, apiKey: apiKey)
            let result = try await nonStreaming(request: request)
            try Task.checkCancellation()
            if let onDelta { await onDelta(result) }
            return result
        }
        return try await complete(
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
        if configuration.usesTranslationAdaptation {
            // 调度层每批一段；直接调用批量入口时仍保证数量与顺序。
            var translated: [String] = []
            for paragraph in paragraphs {
                try Task.checkCancellation()
                translated.append(try await translate(paragraph: paragraph, configuration: configuration, apiKey: apiKey))
            }
            return translated
        }
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let normalizedModel = normalizedModelID(configuration.model, configuration: configuration)
        var body: [String: Any] = ["model": normalizedModel, "stream": stream,
            "messages": configuration.resolvedAdaptation == .userMessage
                ? [["role": "user", "content": system + "\n\n" + prompt]]
                : [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        if !(configuration.usesGeminiAPI && normalizedModel.lowercased().hasPrefix("gemini-3")) {
            body["temperature"] = overrideTemperature ?? configuration.temperature
        }
        let capability = configuration.reasoningCapabilities
        let mode = forceDisableReasoning && capability.canDisable ? "关闭" : AIReasoningCapabilities.canonical(configuration.reasoningMode)
        // 无效旧选项必须显式重选，不能在界面显示关闭、请求却自动开启。
        guard mode == "自动" || capability.accepts(mode) else { throw LLMServiceError.unsupportedReasoning }
        if mode != "自动" {
            let off = mode == "关闭"
            let effort = mode == "开启" || off ? nil : mode
            switch capability.wireProtocol {
            case .deepSeek:
                body["thinking"] = ["type": off ? "disabled" : "enabled"]
                body["reasoning_effort"] = effort
            case .gemini: body["reasoning_effort"] = off ? "none" : effort
            case .dashscope:
                body["enable_thinking"] = !off
                body["reasoning_effort"] = effort
            case .openRouter:
                var reasoning: [String: Any] = ["enabled": !off]
                reasoning["effort"] = effort
                body["reasoning"] = reasoning
                body["provider"] = ["require_parameters": true]
            case .openAI: body["reasoning_effort"] = effort
            case .automatic: break
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeTranslationRequest(paragraph: String, configuration: LLMConfiguration, apiKey: String) throws -> URLRequest {
        var transport = configuration
        transport.adaptation = .chat
        transport.reasoningMode = "自动"
        var request = try makeRequest(prompt: "", system: "", configuration: transport, apiKey: apiKey, stream: false)
        // 只复用端点、鉴权和超时。翻译协议不携带通用聊天的采样与推理参数。
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [["role": "user", "content": paragraph]],
            "stream": false,
            "translation_options": ["source_lang": "auto", "target_lang": try Self.translationLanguage(configuration.targetLanguage, model: configuration.model)]
        ])
        return request
    }

    static func translationLanguage(_ language: String, model: String = "") throws -> String {
        // 官方语言表，2026-09-06；模型子集由服务端校验。
        // https://help.aliyun.com/zh/model-studio/machine-translation
        let aliases = [
            "英语": "English",
            "english": "English",
            "en": "English",
            "简体中文": "Chinese",
            "chinese": "Chinese",
            "zh": "Chinese",
            "繁体中文": "Traditional Chinese",
            "traditional chinese": "Traditional Chinese",
            "zh_tw": "Traditional Chinese",
            "俄语": "Russian",
            "russian": "Russian",
            "ru": "Russian",
            "日语": "Japanese",
            "japanese": "Japanese",
            "ja": "Japanese",
            "韩语": "Korean",
            "korean": "Korean",
            "ko": "Korean",
            "西班牙语": "Spanish",
            "spanish": "Spanish",
            "es": "Spanish",
            "法语": "French",
            "french": "French",
            "fr": "French",
            "葡萄牙语": "Portuguese",
            "portuguese": "Portuguese",
            "pt": "Portuguese",
            "德语": "German",
            "german": "German",
            "de": "German",
            "意大利语": "Italian",
            "italian": "Italian",
            "it": "Italian",
            "泰语": "Thai",
            "thai": "Thai",
            "th": "Thai",
            "越南语": "Vietnamese",
            "vietnamese": "Vietnamese",
            "vi": "Vietnamese",
            "印度尼西亚语": "Indonesian",
            "indonesian": "Indonesian",
            "id": "Indonesian",
            "马来语": "Malay",
            "malay": "Malay",
            "ms": "Malay",
            "阿拉伯语": "Arabic",
            "arabic": "Arabic",
            "ar": "Arabic",
            "印地语": "Hindi",
            "hindi": "Hindi",
            "hi": "Hindi",
            "希伯来语": "Hebrew",
            "hebrew": "Hebrew",
            "he": "Hebrew",
            "缅甸语": "Burmese",
            "burmese": "Burmese",
            "my": "Burmese",
            "泰米尔语": "Tamil",
            "tamil": "Tamil",
            "ta": "Tamil",
            "乌尔都语": "Urdu",
            "urdu": "Urdu",
            "ur": "Urdu",
            "孟加拉语": "Bengali",
            "bengali": "Bengali",
            "bn": "Bengali",
            "波兰语": "Polish",
            "polish": "Polish",
            "pl": "Polish",
            "荷兰语": "Dutch",
            "dutch": "Dutch",
            "nl": "Dutch",
            "罗马尼亚语": "Romanian",
            "romanian": "Romanian",
            "ro": "Romanian",
            "土耳其语": "Turkish",
            "turkish": "Turkish",
            "tr": "Turkish",
            "高棉语": "Khmer",
            "khmer": "Khmer",
            "km": "Khmer",
            "老挝语": "Lao",
            "lao": "Lao",
            "lo": "Lao",
            "粤语": "Cantonese",
            "cantonese": "Cantonese",
            "yue": "Cantonese",
            "捷克语": "Czech",
            "czech": "Czech",
            "cs": "Czech",
            "希腊语": "Greek",
            "greek": "Greek",
            "el": "Greek",
            "瑞典语": "Swedish",
            "swedish": "Swedish",
            "sv": "Swedish",
            "匈牙利语": "Hungarian",
            "hungarian": "Hungarian",
            "hu": "Hungarian",
            "丹麦语": "Danish",
            "danish": "Danish",
            "da": "Danish",
            "芬兰语": "Finnish",
            "finnish": "Finnish",
            "fi": "Finnish",
            "乌克兰语": "Ukrainian",
            "ukrainian": "Ukrainian",
            "uk": "Ukrainian",
            "保加利亚语": "Bulgarian",
            "bulgarian": "Bulgarian",
            "bg": "Bulgarian",
            "塞尔维亚语": "Serbian",
            "serbian": "Serbian",
            "sr": "Serbian",
            "泰卢固语": "Telugu",
            "telugu": "Telugu",
            "te": "Telugu",
            "南非荷兰语": "Afrikaans",
            "afrikaans": "Afrikaans",
            "af": "Afrikaans",
            "亚美尼亚语": "Armenian",
            "armenian": "Armenian",
            "hy": "Armenian",
            "阿萨姆语": "Assamese",
            "assamese": "Assamese",
            "as": "Assamese",
            "阿斯图里亚斯语": "Asturian",
            "asturian": "Asturian",
            "ast": "Asturian",
            "巴斯克语": "Basque",
            "basque": "Basque",
            "eu": "Basque",
            "白俄罗斯语": "Belarusian",
            "belarusian": "Belarusian",
            "be": "Belarusian",
            "波斯尼亚语": "Bosnian",
            "bosnian": "Bosnian",
            "bs": "Bosnian",
            "加泰罗尼亚语": "Catalan",
            "catalan": "Catalan",
            "ca": "Catalan",
            "宿务语": "Cebuano",
            "cebuano": "Cebuano",
            "ceb": "Cebuano",
            "克罗地亚语": "Croatian",
            "croatian": "Croatian",
            "hr": "Croatian",
            "埃及阿拉伯语": "Egyptian Arabic",
            "egyptian arabic": "Egyptian Arabic",
            "arz": "Egyptian Arabic",
            "爱沙尼亚语": "Estonian",
            "estonian": "Estonian",
            "et": "Estonian",
            "加利西亚语": "Galician",
            "galician": "Galician",
            "gl": "Galician",
            "格鲁吉亚语": "Georgian",
            "georgian": "Georgian",
            "ka": "Georgian",
            "古吉拉特语": "Gujarati",
            "gujarati": "Gujarati",
            "gu": "Gujarati",
            "冰岛语": "Icelandic",
            "icelandic": "Icelandic",
            "is": "Icelandic",
            "爪哇语": "Javanese",
            "javanese": "Javanese",
            "jv": "Javanese",
            "卡纳达语": "Kannada",
            "kannada": "Kannada",
            "kn": "Kannada",
            "哈萨克语": "Kazakh",
            "kazakh": "Kazakh",
            "kk": "Kazakh",
            "拉脱维亚语": "Latvian",
            "latvian": "Latvian",
            "lv": "Latvian",
            "立陶宛语": "Lithuanian",
            "lithuanian": "Lithuanian",
            "lt": "Lithuanian",
            "卢森堡语": "Luxembourgish",
            "luxembourgish": "Luxembourgish",
            "lb": "Luxembourgish",
            "马其顿语": "Macedonian",
            "macedonian": "Macedonian",
            "mk": "Macedonian",
            "马加希语": "Maithili",
            "maithili": "Maithili",
            "mai": "Maithili",
            "马耳他语": "Maltese",
            "maltese": "Maltese",
            "mt": "Maltese",
            "马拉地语": "Marathi",
            "marathi": "Marathi",
            "mr": "Marathi",
            "美索不达米亚阿拉伯语": "Mesopotamian Arabic",
            "mesopotamian arabic": "Mesopotamian Arabic",
            "acm": "Mesopotamian Arabic",
            "摩洛哥阿拉伯语": "Moroccan Arabic",
            "moroccan arabic": "Moroccan Arabic",
            "ary": "Moroccan Arabic",
            "内志阿拉伯语": "Najdi Arabic",
            "najdi arabic": "Najdi Arabic",
            "ars": "Najdi Arabic",
            "尼泊尔语": "Nepali",
            "nepali": "Nepali",
            "ne": "Nepali",
            "北阿塞拜疆语": "North Azerbaijani",
            "north azerbaijani": "North Azerbaijani",
            "az": "North Azerbaijani",
            "北黎凡特阿拉伯语": "North Levantine Arabic",
            "north levantine arabic": "North Levantine Arabic",
            "apc": "North Levantine Arabic",
            "北乌兹别克语": "Northern Uzbek",
            "northern uzbek": "Northern Uzbek",
            "uz": "Northern Uzbek",
            "书面语挪威语": "Norwegian Bokmål",
            "norwegian bokmål": "Norwegian Bokmål",
            "nb": "Norwegian Bokmål",
            "新挪威语": "Norwegian Nynorsk",
            "norwegian nynorsk": "Norwegian Nynorsk",
            "nn": "Norwegian Nynorsk",
            "奥克语": "Occitan",
            "occitan": "Occitan",
            "oc": "Occitan",
            "奥里亚语": "Odia",
            "odia": "Odia",
            "or": "Odia",
            "邦阿西楠语": "Pangasinan",
            "pangasinan": "Pangasinan",
            "pag": "Pangasinan",
            "西西里语": "Sicilian",
            "sicilian": "Sicilian",
            "scn": "Sicilian",
            "信德语": "Sindhi",
            "sindhi": "Sindhi",
            "sd": "Sindhi",
            "僧伽罗语": "Sinhala",
            "sinhala": "Sinhala",
            "si": "Sinhala",
            "斯洛伐克语": "Slovak",
            "slovak": "Slovak",
            "sk": "Slovak",
            "斯洛文尼亚语": "Slovenian",
            "slovenian": "Slovenian",
            "sl": "Slovenian",
            "南黎凡特阿拉伯语": "South Levantine Arabic",
            "south levantine arabic": "South Levantine Arabic",
            "ajp": "South Levantine Arabic",
            "斯瓦希里语": "Swahili",
            "swahili": "Swahili",
            "sw": "Swahili",
            "他加禄语": "Tagalog",
            "tagalog": "Tagalog",
            "tl": "Tagalog",
            "塔伊兹-亚丁阿拉伯语": "Ta’izzi-Adeni Arabic",
            "ta’izzi-adeni arabic": "Ta’izzi-Adeni Arabic",
            "acq": "Ta’izzi-Adeni Arabic",
            "托斯克阿尔巴尼亚语": "Tosk Albanian",
            "tosk albanian": "Tosk Albanian",
            "sq": "Tosk Albanian",
            "突尼斯阿拉伯语": "Tunisian Arabic",
            "tunisian arabic": "Tunisian Arabic",
            "aeb": "Tunisian Arabic",
            "威尼斯语": "Venetian",
            "venetian": "Venetian",
            "vec": "Venetian",
            "瓦莱语": "Waray",
            "waray": "Waray",
            "war": "Waray",
            "威尔士语": "Welsh",
            "welsh": "Welsh",
            "cy": "Welsh",
            "西波斯语": "Western Persian",
            "western persian": "Western Persian",
            "fa": "Western Persian",
            "中文": "Chinese",
            "zh-cn": "Chinese",
            "zh-hans": "Chinese",
            "simplified chinese": "Chinese",
            "zh-tw": "Traditional Chinese",
            "zh-hant": "Traditional Chinese",
            "英文": "English",
            "en-us": "English",
            "en-gb": "English",
            "日文": "Japanese",
            "印尼语": "Indonesian",
            "波斯语": "Western Persian",
        ]
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if var mapped = aliases[value] {
            if model.lowercased().hasPrefix("qwen-mt-lite") {
                if mapped == "Western Persian" { mapped = "Persian" }
                let supported = ["English", "Chinese", "Traditional Chinese", "Russian", "Japanese", "Korean", "Spanish", "French", "Portuguese", "German", "Italian", "Thai", "Vietnamese", "Indonesian", "Malay", "Arabic", "Hindi", "Hebrew", "Urdu", "Bengali", "Polish", "Dutch", "Turkish", "Khmer", "Czech", "Swedish", "Hungarian", "Danish", "Finnish", "Tagalog", "Persian"]
                guard supported.contains(mapped) else { throw LLMServiceError.unsupportedTranslationLanguage }
            }
            return mapped
        }
        throw LLMServiceError.unsupportedTranslationLanguage
    }

    public func probeConnection(configuration: LLMConfiguration, apiKey: String) async throws -> AIConnectionTestResult {
        do {
            try await test(configuration: configuration, apiKey: apiKey)
            return AIConnectionTestResult()
        } catch {
            guard configuration.adaptation == .automatic,
                  !configuration.usesTranslationAdaptation,
                  let hint = Self.protocolHint(error) else { throw error }
            try Task.checkCancellation()
            if hint == .userMessage {
                var userOnly = configuration
                userOnly.adaptation = .userMessage
                do {
                    let output = try await complete(prompt: "Reply with exactly OK.", system: "", configuration: userOnly, apiKey: apiKey)
                    if output.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" {
                        return AIConnectionTestResult(suggestedAdaptation: .userMessage)
                    }
                } catch {
                    guard Self.protocolHint(error) == .qwenTranslation else { throw error }
                }
            }
            return try await probeTranslation(configuration: configuration, apiKey: apiKey)
        }
    }

    /// 只匹配参数/角色类的 400/422；网络、鉴权、限流错误不扩大发送。
    static func protocolHint(_ error: Error) -> AIModelAdaptation? {
        guard case let LLMServiceError.httpStatus(code, body) = error, code == 400 || code == 422 else { return nil }
        let message = body.lowercased()
        if message.contains("translation_options") || message.contains("target_lang") || message.contains("source_lang") {
            return .qwenTranslation
        }
        if (message.contains("role") && (message.contains("system") || message.contains("[user, assistant]")))
            && (message.contains("support") || message.contains("must") || message.contains("invalid")) {
            return .userMessage
        }
        return nil
    }

    private func probeTranslation(configuration: LLMConfiguration, apiKey: String) async throws -> AIConnectionTestResult {
        let sample = "The red bicycle is parked beside the library. Tomorrow morning we will read a book together."
        var candidate = configuration
        candidate.adaptation = .qwenTranslation
        candidate.targetLanguage = "Chinese"
        try Task.checkCancellation()
        let chinese = try await translate(paragraph: sample, configuration: candidate, apiKey: apiKey)
        candidate.targetLanguage = "Japanese"
        try Task.checkCancellation()
        let japanese = try await translate(paragraph: sample, configuration: candidate, apiKey: apiKey)
        let hasHan = chinese.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count >= 8
        let hasKana = japanese.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) }.count >= 5
        let chineseHasKana = chinese.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        guard hasHan, hasKana, !chineseHasKana, chinese != japanese else { throw LLMServiceError.inconclusiveTranslationProbe }
        return AIConnectionTestResult(suggestedAdaptation: .qwenTranslation)
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
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        let isPrivateIPv4 = parts.count == 4 && octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } && (
            octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 127)
                || (octets[0] == 169 && octets[1] == 254)
        )
        let ipv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let isLocalIPv6 = ipv6.contains(":") && (ipv6 == "::1" || ipv6.hasPrefix("fe80:") || ipv6.hasPrefix("fc") || ipv6.hasPrefix("fd"))
        guard isLocalName || isPrivateIPv4 || isLocalIPv6 else {
            throw LLMServiceError.insecureEndpoint
        }
    }

    private func nonStreaming(request: URLRequest) async throws -> String {
        let response = try await port.data(for: request)
        try validate(statusCode: response.statusCode, data: response.data)
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        guard let result = try? JSONDecoder().decode(Response.self, from: response.data), let text = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw LLMServiceError.invalidResponse }
        if result.choices.first?.finish_reason == "length" { throw LLMServiceError.truncatedResponse }
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
