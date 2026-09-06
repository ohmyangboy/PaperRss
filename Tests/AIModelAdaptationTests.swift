import Foundation
import XCTest
@testable import PaperRssCore

private actor AdaptationPort: AIModelPort {
    var responses: [AIModelHTTPResponse]
    var requests: [URLRequest] = []
    var pauses = false
    init(_ responses: [AIModelHTTPResponse]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        if pauses { try await Task.sleep(for: .seconds(60)) }
        guard !responses.isEmpty else { throw LLMServiceError.invalidResponse }
        return responses.removeFirst()
    }
    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        throw LLMServiceError.invalidResponse
    }
    func captured() -> [URLRequest] { requests }
    func pause() { pauses = true }
}

final class AIModelAdaptationTests: XCTestCase {
    private func configuration(_ model: String = "renamed-model") -> LLMConfiguration {
        LLMConfiguration(baseURL: "https://example.test/v1", model: model, temperature: 0.2,
                         targetLanguage: "简体中文", allowInsecureLocalEndpoint: false)
    }
    private func reply(_ text: String) -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: 200, data: try! JSONSerialization.data(withJSONObject:
            ["choices": [["message": ["content": text]]]]))
    }
    private func failure(_ code: Int, _ message: String) -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: code, data: try! JSONSerialization.data(withJSONObject:
            ["error": ["message": message, "type": "invalid_request_error"]]))
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testLegacyDefaultsAndExplicitAdapterRoundTrip() throws {
        let old = try JSONDecoder().decode(AIModelOption.self, from: Data(#"{"id":"alias"}"#.utf8))
        XCTAssertEqual(old.adaptation, .automatic)
        let model = AIModelOption(id: "alias", adaptation: .qwenTranslation)
        XCTAssertEqual(try JSONDecoder().decode(AIModelOption.self, from: JSONEncoder().encode(model)), model)
        XCTAssertEqual(try JSONDecoder().decode(LLMConfiguration.self, from: Data("{}".utf8)).adaptation, .automatic)
    }

    func testKnownModelAndAliasShareCapabilitiesWithoutMisclassifyingQwen() {
        XCTAssertTrue(AIModelOption(id: " QWEN-MT-flash ").usesTranslationAdaptation)
        XCTAssertFalse(AIModelOption(id: "qwen-plus").usesTranslationAdaptation)
        let alias = AIModelOption(id: "arbitrary-name", adaptation: .qwenTranslation)
        XCTAssertTrue(alias.supports(.bilingualTranslation))
        XCTAssertTrue(alias.supports(.selectionTranslation))
        XCTAssertFalse(alias.supports(.summary))
        XCTAssertFalse(alias.supports(.selectionExplanation))
        XCTAssertFalse(alias.supports(.selectionAsk))
    }

    func testTranslationWireContractOmitsChatOptionsAndKeepsAPIKeyOutOfBody() throws {
        let request = try LLMService().makeTranslationRequest(paragraph: "Hello", configuration: configuration("qwen-mt-flash"), apiKey: "test-key")
        let payload = try body(request)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(payload["messages"] as? [[String: String]], [["role": "user", "content": "Hello"]])
        XCTAssertEqual(payload["translation_options"] as? [String: String], ["source_lang": "auto", "target_lang": "Chinese"])
        XCTAssertNil(payload["temperature"])
        XCTAssertNil(payload["reasoning_effort"])
        XCTAssertNil(payload["extra_body"])
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-key"))
    }

    func testRenamedTranslationProtocolSuggestsWithoutChangingConfiguration() async throws {
        let port = AdaptationPort([
            failure(400, "Role must be in [user, assistant]."),
            failure(400, "translation_options.target_lang is required"),
            reply("红色自行车停在图书馆旁边，明天早晨我们一起读书。"),
            reply("赤い自転車は図書館のそばにあります。明日の朝、一緒に本を読みます。")
        ])
        let config = configuration()
        let result = try await LLMService(port: port).probeConnection(configuration: config, apiKey: "")
        XCTAssertEqual(result.suggestedAdaptation, .qwenTranslation)
        XCTAssertEqual(config.adaptation, .automatic)
        let requests = await port.captured()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(try body(requests[2])["translation_options"] as? [String: String], ["source_lang": "auto", "target_lang": "Chinese"])
        XCTAssertEqual(try body(requests[3])["translation_options"] as? [String: String], ["source_lang": "auto", "target_lang": "Japanese"])
    }

    func testSystemRejectionCanStillBeGeneralChat() async throws {
        let port = AdaptationPort([failure(400, "system role is not supported"), reply("OK")])
        let result = try await LLMService(port: port).probeConnection(configuration: configuration(), apiKey: "")
        XCTAssertEqual(result.suggestedAdaptation, .userMessage)
        let requests = await port.captured()
        XCTAssertEqual(requests.count, 2)
        let messages = try XCTUnwrap(try body(requests[1])["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["user"])
    }

    func testIgnoredTranslationOptionsDoNotProduceRecommendation() async {
        let port = AdaptationPort([failure(400, "target_lang required"), reply("Hello"), reply("Hello")])
        do {
            _ = try await LLMService(port: port).probeConnection(configuration: configuration(), apiKey: "")
            XCTFail("不能将忽略语言参数的响应识别为翻译协议")
        } catch LLMServiceError.inconclusiveTranslationProbe {} catch { XCTFail("\(error)") }
    }

    func testAuthRateLimitServerAndUnrelatedParameterErrorsNeverProbe() async {
        for code in [401, 403, 429, 500, 400] {
            let port = AdaptationPort([failure(code, "request failed")])
            do {
                _ = try await LLMService(port: port).probeConnection(configuration: configuration(), apiKey: "")
                XCTFail("应返回原始错误")
            } catch {}
            let requests = await port.captured()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testTranslationBatchKeepsInputOrderAndDoesNotSendJSONInstructions() async throws {
        let port = AdaptationPort([reply("第一段"), reply("第二段")])
        let result = try await LLMService(port: port).translateBatch(paragraphs: ["First", "Second"], configuration: configuration("qwen-mt-flash"), apiKey: "")
        XCTAssertEqual(result, ["第一段", "第二段"])
        let requests = await port.captured()
        XCTAssertEqual(try requests.map { try body($0)["messages"] as? [[String: String]] }, [
            [["role": "user", "content": "First"]], [["role": "user", "content": "Second"]]
        ])
    }

    func testSummaryIsBlockedBeforeNetwork() async {
        let port = AdaptationPort([])
        do {
            _ = try await LLMService(port: port).summary(text: "article", configuration: configuration("qwen-mt-plus"), apiKey: "")
            XCTFail("翻译适配不可用于摘要")
        } catch LLMServiceError.translationOnly {} catch { XCTFail("\(error)") }
        let requests = await port.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationStopsProbeWithoutFallbackRequests() async throws {
        let port = AdaptationPort([failure(400, "target_lang required")])
        await port.pause()
        let config = configuration()
        let task = Task { try await LLMService(port: port).probeConnection(configuration: config, apiKey: "") }
        for _ in 0..<100 {
            if await port.captured().count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("应取消探测") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        let requests = await port.captured()
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testSavedTranslationRoutingBlocksSummaryWithoutRewritingSelection() async {
        let port = AdaptationPort([])
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        }, aiModelPort: port)
        var provider = AIProviderProfile.custom(name: "fixture", description: "", baseURL: "https://example.test/v1", modelID: "alias")
        provider.models[0].adaptation = .qwenTranslation
        store.addAIProvider(provider, apiKey: "")
        let reference = AIModelReference(providerID: provider.id, modelID: "alias")
        store.saveAISettings(store.aiSettings.updatingFeature(.summary, configuration: AIFeatureConfiguration(isEnabled: true, model: reference)))
        let entry = Entry(id: "blocked", feedID: UUID(), title: "fixture", url: nil, publishedAt: nil, summary: "text")
        await store.generateSummary(entry: entry, text: "text", force: true)
        XCTAssertEqual(store.aiSettings.configuration(for: .summary)?.model, reference)
        let requests = await port.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRuntimeProjectionRefreshAndCacheIdentityPreserveAdapter() throws {
        var provider = AIProviderProfile.custom(name: "test", description: "", baseURL: "https://example.test/v1", modelID: "alias")
        let original = provider.runtimeConfiguration(features: .default)
        provider.models[0].adaptation = .qwenTranslation
        provider = provider.updatingModels(from: ["alias", "other"])
        let changed = provider.runtimeConfiguration(features: .default)
        XCTAssertEqual(changed.adaptation, .qwenTranslation)
        XCTAssertEqual(provider.runtimeConfiguration(modelID: "other", features: .default).adaptation, .automatic)
        let first = AIExecutionContext(providerID: provider.id, providerKind: provider.kind, configuration: original)
        let second = AIExecutionContext(providerID: provider.id, providerKind: provider.kind, configuration: changed)
        XCTAssertNotEqual(first.fingerprint(for: .bilingual, promptVersion: 1), second.fingerprint(for: .bilingual, promptVersion: 1))
    }
}
