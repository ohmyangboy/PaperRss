import Foundation
import XCTest
@testable import PaperRssCore

private struct ReasoningCatalogPort: AIModelPort {
    let json: String
    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: 200, data: Data(json.utf8))
    }
    func events(for request: URLRequest) async throws -> AIModelEventResponse { throw LLMServiceError.invalidResponse }
}

final class AIReasoningCapabilitiesTests: XCTestCase {
    private func config(_ endpoint: String = "https://api.deepseek.com/v1", _ model: String = "deepseek-v4-flash") -> LLMConfiguration {
        LLMConfiguration(baseURL: endpoint, model: model, temperature: 0.2, targetLanguage: "简体中文", allowInsecureLocalEndpoint: false, providerKind: .customOpenAICompatible)
    }
    private func body(_ config: LLMConfiguration) throws -> [String: Any] {
        let request = try LLMService().makeRequest(prompt: "Test", system: "Test", configuration: config, apiKey: "", stream: false)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    func testCustomOfficialDeepSeekCanActuallyDisableAndUseMax() throws {
        var value = config()
        XCTAssertEqual(value.reasoningCapabilities.modes, ["自动", "关闭", "low", "high", "max"])
        value.reasoningMode = "关闭"
        XCTAssertEqual((try body(value)["thinking"] as? [String: String])?["type"], "disabled")
        value.reasoningMode = "max"
        XCTAssertEqual(try body(value)["reasoning_effort"] as? String, "max")
        value.reasoningMode = "自动"
        XCTAssertNil(try body(value)["thinking"])
    }
    func testSameNameOnUnknownGatewayDoesNotInventCapabilities() throws {
        var value = config("https://example.test/v1")
        XCTAssertEqual(value.reasoningCapabilities.modes, ["自动"])
        value.reasoningMode = "关闭"
        XCTAssertThrowsError(try body(value))
        value.reasoningProtocol = .deepSeek
        XCTAssertEqual((try body(value)["thinking"] as? [String: String])?["type"], "disabled")
    }
    func testDashscopeUsesOwnSwitchWithoutFictitiousQwenEfforts() throws {
        var value = config("https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", "qwen3.7-flash")
        XCTAssertEqual(value.reasoningCapabilities.modes, ["自动", "关闭", "开启"])
        value.reasoningMode = "关闭"
        XCTAssertEqual(try body(value)["enable_thinking"] as? Bool, false)
        XCTAssertNil(try body(value)["thinking"])
        value.reasoningMode = "low"
        XCTAssertThrowsError(try body(value))
    }
    func testCatalogDistinguishesMissingNullAndMandatoryAndBindsEndpointModel() async throws {
        let port = ReasoningCatalogPort(json: #"{"data":[{"id":"alias","reasoning":{"supported_efforts":["xhigh","high"],"mandatory":false}},{"id":"null","reasoning":{"supported_efforts":null,"mandatory":true}},{"id":"missing","reasoning":{"mandatory":false}}]}"#)
        var value = config("https://openrouter.ai/api/v1", "alias")
        let models = try await LLMService(port: port).fetchModelOptions(configuration: value, apiKey: "")
        value.reasoningMetadata = models[0].reasoningMetadata
        XCTAssertEqual(value.reasoningCapabilities.modes, ["自动", "关闭", "xhigh", "high"])
        value.reasoningMode = "xhigh"
        XCTAssertEqual((try body(value)["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")
        XCTAssertEqual((try body(value)["provider"] as? [String: Bool])?["require_parameters"], true)
        value.model = "different"
        XCTAssertEqual(value.reasoningCapabilities.modes, ["自动"])
        value.model = "alias"
        value.reasoningMetadata = models[0].reasoningMetadata
        value.baseURL = "https://example.test/v1"
        value.reasoningProtocol = .openRouter
        XCTAssertEqual(value.reasoningCapabilities.modes, ["自动"])
        XCTAssertEqual(models[1].reasoningMetadata?.canDisable, false)
        XCTAssertTrue(models[1].reasoningMetadata?.efforts.contains("low") == true)
        XCTAssertEqual(models[2].reasoningMetadata?.efforts, [])
    }
    func testExpiredCatalogKeepsSavedReasoningUsableUntilRefresh() throws {
        var value = config("https://openrouter.ai/api/v1", "alias")
        let fetchedAt = Date(timeIntervalSinceNow: -90000)
        value.reasoningMetadata = AIReasoningMetadata(
            modelID: "alias", endpoint: value.reasoningEndpoint, fetchedAt: fetchedAt,
            efforts: ["high"], canDisable: true, supportsThinking: true
        )
        value.reasoningMode = "high"
        XCTAssertEqual((try body(value)["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        value.reasoningMode = "关闭"
        XCTAssertEqual((try body(value)["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
        // 保留原始抓取时间，AppStore 的 24 小时目录刷新仍会触发。
        XCTAssertEqual(value.reasoningMetadata?.fetchedAt, fetchedAt)
        value.model = "different"
        XCTAssertThrowsError(try body(value))
        value.model = "alias"
        value.baseURL = "https://example.test/v1"
        value.reasoningProtocol = .openRouter
        XCTAssertThrowsError(try body(value))
    }
    func testMetadataAndProtocolRoundTripAndRuntimeProjection() throws {
        var model = AIModelOption(id: "alias")
        model.reasoningProtocol = .openRouter
        model.reasoningMetadata = AIReasoningMetadata(modelID: "alias", endpoint: "https://example.test/v1", fetchedAt: Date(), efforts: ["high"], canDisable: false, supportsThinking: true)
        XCTAssertEqual(try JSONDecoder().decode(AIModelOption.self, from: JSONEncoder().encode(model)), model)
        let provider = AIProviderProfile(id: "test", kind: .customOpenAICompatible, name: "Custom", description: "", baseURL: "https://example.test/v1", selectedModelID: "alias", models: [model])
        let runtime = provider.runtimeConfiguration(features: .default)
        XCTAssertEqual(runtime.reasoningCapabilities.modes, ["自动", "high"])
        XCTAssertEqual(try JSONDecoder().decode(LLMConfiguration.self, from: JSONEncoder().encode(runtime)).reasoningMetadata, model.reasoningMetadata)
    }
    func testReasoningProtocolAndRawEffortsChangeCacheIdentity() {
        var first = config("https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3-flash")
        first.reasoningMode = "low"
        var second = first
        second.reasoningMode = "high"
        func fingerprint(_ value: LLMConfiguration) -> String {
            AIExecutionContext(providerID: "custom", providerKind: .customOpenAICompatible, configuration: value).fingerprint(for: .bilingual, promptVersion: 1)
        }
        XCTAssertNotEqual(fingerprint(first), fingerprint(second))
        second = first
        second.reasoningProtocol = .openAI
        XCTAssertNotEqual(fingerprint(first), fingerprint(second))
    }
    func testOfficialLanguageAliasesAndLiteSubset() throws {
        XCTAssertEqual(try LLMService.translationLanguage("zh_tw"), "Traditional Chinese")
        XCTAssertEqual(try LLMService.translationLanguage("繁体中文"), "Traditional Chinese")
        XCTAssertEqual(try LLMService.translationLanguage("nb"), "Norwegian Bokmål")
        XCTAssertEqual(try LLMService.translationLanguage("fa", model: "qwen-mt-lite"), "Persian")
        XCTAssertThrowsError(try LLMService.translationLanguage("nb", model: "qwen-mt-lite"))
        XCTAssertThrowsError(try LLMService.translationLanguage("unknown-code"))
    }
    func testMTIgnoresStaleReasoningAndRejectsTruncation() async throws {
        var value = config("https://example.test/v1", "qwen-mt-flash")
        value.reasoningMode = "低"
        XCTAssertEqual(value.reasoningCapabilities.source, "不适用")
        let port = ReasoningCatalogPort(json: #"{"choices":[{"message":{"content":"部分译文"},"finish_reason":"length"}]}"#)
        do {
            _ = try await LLMService(port: port).translate(paragraph: "Example", configuration: value, apiKey: "")
            XCTFail("截断不能被保存为完整译文")
        } catch LLMServiceError.truncatedResponse {} catch { XCTFail("Unexpected: \(error)") }
    }
}
