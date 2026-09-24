import XCTest
@testable import PaperRssCore

/// 标题/摘要翻译调度器：批量、去重、黑白名单、语言探测、失败退避与会话隔离。
@MainActor
final class FeedTitleTranslationCoordinatorTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        var batches: [[String]] = []
        var probes: [String] = []
    }

    private final class SessionBox: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private final class ConfigurationBox: @unchecked Sendable {
        var isEnabled = true
        var sessionID = "s1"
    }

    private func candidate(
        _ entryID: String,
        feedID: UUID,
        title: String,
        summary: String? = nil
    ) -> TitleTranslationCandidate {
        TitleTranslationCandidate(entryID: entryID, feedID: feedID, title: title, summary: summary)
    }

    private func waitFor(
        _ description: String,
        timeout: Duration = .seconds(3),
        condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时：\(description)")
    }

    func testPublishesTitleAndSummaryTranslations() async {
        let feedID = UUID()
        let recorder = Recorder()
        let coordinator = FeedTitleTranslationCoordinator(
            configurationProvider: {
                TitleTranslationContext(sessionID: "s1", targetLanguage: "简体中文", feedLists: [feedID: .whitelist])
            },
            translate: { texts, _ in
                recorder.batches.append(texts)
                var translations: [String: String] = [:]
                for text in texts { translations[text] = "T:" + text }
                return TitleTranslationBatchResult(translations: translations)
            },
            languageProbe: { _, _ in true }
        )
        coordinator.debounceInterval = .milliseconds(5)
        coordinator.updateScope([
            candidate("a", feedID: feedID, title: "Alpha", summary: "Alpha summary"),
            candidate("b", feedID: feedID, title: "Beta")
        ])

        await waitFor("标题与摘要译文发布") {
            coordinator.translations["a"]?.title != nil && coordinator.translations["a"]?.summary != nil
                && coordinator.translations["b"]?.title != nil
        }
        XCTAssertEqual(coordinator.translations["a"]?.title, "T:Alpha")
        XCTAssertEqual(coordinator.translations["a"]?.summary, "T:Alpha summary")
        XCTAssertEqual(coordinator.translations["b"]?.title, "T:Beta")
        XCTAssertNil(coordinator.translations["b"]?.summary)
        // 三个翻译单元合并成一次请求。
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(Set(recorder.batches[0]), ["Alpha", "Alpha summary", "Beta"])
    }

    func testDeduplicatesRepeatedTextsAcrossEntries() async {
        let feedID = UUID()
        let recorder = Recorder()
        let coordinator = FeedTitleTranslationCoordinator(
            configurationProvider: {
                TitleTranslationContext(sessionID: "s1", targetLanguage: "简体中文", feedLists: [feedID: .whitelist])
            },
            translate: { texts, _ in
                recorder.batches.append(texts)
                var translations: [String: String] = [:]
                for text in texts { translations[text] = "T:" + text }
                return TitleTranslationBatchResult(translations: translations)
            },
            languageProbe: { _, _ in true }
        )
        coordinator.debounceInterval = .milliseconds(5)
        coordinator.updateScope([
            candidate("a", feedID: feedID, title: "Same", summary: "Same summary"),
            candidate("b", feedID: feedID, title: "Same", summary: "Same summary")
        ])

        await waitFor("重复文本只请求一次") {
            coordinator.translations["a"]?.summary != nil && coordinator.translations["b"]?.summary != nil
        }
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches[0].count, 2)
        XCTAssertEqual(coordinator.translations["a"]?.title, "T:Same")
        XCTAssertEqual(coordinator.translations["b"]?.title, "T:Same")
    }

    func testBlacklistSkipsAndWhitelistBypassesLanguageProbe() async {
        let black = UUID()
        let white = UUID()
        let other = UUID()
        let recorder = Recorder()
        let coordinator = FeedTitleTranslationCoordinator(
            configurationProvider: {
                TitleTranslationContext(
                    sessionID: "s1",
                    targetLanguage: "简体中文",
                    feedLists: [black: .blacklist, white: .whitelist]
                )
            },
            translate: { texts, _ in
                recorder.batches.append(texts)
                var translations: [String: String] = [:]
                for text in texts { translations[text] = "T:" + text }
                return TitleTranslationBatchResult(translations: translations)
            },
            languageProbe: { text, _ in
                recorder.probes.append(text)
                return false // 一律判定为“已是目标语言”
            }
        )
        coordinator.debounceInterval = .milliseconds(5)
        coordinator.updateScope([
            candidate("black", feedID: black, title: "Blacklisted", summary: "Blacklisted summary"),
            candidate("white", feedID: white, title: "Whitelisted", summary: "Whitelisted summary"),
            candidate("other", feedID: other, title: "Other", summary: "Other summary")
        ])

        await waitFor("白名单译文发布") { coordinator.translations["white"]?.title != nil }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(coordinator.translations["black"]?.title)
        XCTAssertNil(coordinator.translations["other"]?.title)
        XCTAssertEqual(Set(recorder.batches.flatMap { $0 }), ["Whitelisted", "Whitelisted summary"])
        // 白名单不经过语言探测；名单外的标题与摘要分别判定。
        XCTAssertEqual(Set(recorder.probes), ["Other", "Other summary"])
    }

    func testFailuresStopAfterTwoAttemptsAcrossPasses() async {
        let feedID = UUID()
        let recorder = Recorder()
        let coordinator = FeedTitleTranslationCoordinator(
            configurationProvider: {
                TitleTranslationContext(sessionID: "s1", targetLanguage: "简体中文", feedLists: [feedID: .whitelist])
            },
            translate: { texts, _ in
                recorder.batches.append(texts)
                return TitleTranslationBatchResult(failedTexts: Set(texts))
            },
            languageProbe: { _, _ in true },
            maximumFailuresPerText: 2
        )
        coordinator.debounceInterval = .milliseconds(5)
        coordinator.updateScope([candidate("a", feedID: feedID, title: "Alpha")])

        await waitFor("第一次尝试") { recorder.batches.count == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        // 同一轮内不会立刻重试同一文本。
        XCTAssertEqual(recorder.batches.count, 1)

        coordinator.refresh()
        await waitFor("第二次尝试") { recorder.batches.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))

        coordinator.refresh()
        try? await Task.sleep(for: .milliseconds(120))
        // 达到失败上限后不再请求，避免滚动时反复为坏文本付费。
        XCTAssertEqual(recorder.batches.count, 2)
    }

    func testSessionChangeClearsCachedTranslations() async {
        let feedID = UUID()
        let session = SessionBox("s1")
        let recorder = Recorder()
        let coordinator = FeedTitleTranslationCoordinator(
            configurationProvider: {
                TitleTranslationContext(sessionID: session.value, targetLanguage: "简体中文", feedLists: [feedID: .whitelist])
            },
            translate: { texts, context in
                recorder.batches.append(texts)
                var translations: [String: String] = [:]
                for text in texts { translations[text] = "\(context.sessionID):\(text)" }
                return TitleTranslationBatchResult(translations: translations)
            },
            languageProbe: { _, _ in true }
        )
        coordinator.debounceInterval = .milliseconds(5)
        coordinator.updateScope([candidate("a", feedID: feedID, title: "Alpha")])

        await waitFor("第一会话译文") { coordinator.translations["a"]?.title == "s1:Alpha" }
        session.value = "s2"
        coordinator.refresh()

        await waitFor("模型/语言变化后重新翻译") { coordinator.translations["a"]?.title == "s2:Alpha" }
        XCTAssertEqual(recorder.batches.count, 2)
    }

    func testScopeUpdateDuringRequestDoesNotDropResults() async {
        let feedID = UUID()
        final class CoordinatorBox: @unchecked Sendable {
            var value: FeedTitleTranslationCoordinator?
        }
        let coordinatorBox = CoordinatorBox()
        let coordinator = FeedTitleTranslationCoordinator(
            configurationProvider: {
                TitleTranslationContext(sessionID: "s1", targetLanguage: "简体中文", feedLists: [feedID: .whitelist])
            },
            translate: { texts, _ in
                // 模拟请求进行中视图布局更新（会触发 updateScope 并取消去抖任务）。
                // 旧实现会把执行绑定在去抖任务上，取消后结果被丢弃、行缺少译文。
                coordinatorBox.value?.updateScope([
                    TitleTranslationCandidate(entryID: "b", feedID: feedID, title: "Beta")
                ])
                var translations: [String: String] = [:]
                for text in texts { translations[text] = "T:" + text }
                return TitleTranslationBatchResult(translations: translations)
            },
            languageProbe: { _, _ in true }
        )
        coordinatorBox.value = coordinator
        coordinator.debounceInterval = .milliseconds(5)
        coordinator.updateScope([candidate("a", feedID: feedID, title: "Alpha")])

        await waitFor("已完成的翻译结果不被丢弃") { coordinator.translations["a"]?.title == "T:Alpha" }
        await waitFor("新范围也会被处理") { coordinator.translations["b"]?.title == "T:Beta" }
    }

    func testDisabledFeatureClearsPublishedTranslations() async {
        let feedID = UUID()
        let box = ConfigurationBox()
        let coordinator = FeedTitleTranslationCoordinator(
            configurationProvider: {
                guard box.isEnabled else { return nil }
                return TitleTranslationContext(sessionID: box.sessionID, targetLanguage: "简体中文", feedLists: [feedID: .whitelist])
            },
            translate: { texts, _ in
                var translations: [String: String] = [:]
                for text in texts { translations[text] = "T:" + text }
                return TitleTranslationBatchResult(translations: translations)
            },
            languageProbe: { _, _ in true }
        )
        coordinator.debounceInterval = .milliseconds(5)
        coordinator.updateScope([candidate("a", feedID: feedID, title: "Alpha")])
        await waitFor("译文发布") { coordinator.translations["a"]?.title == "T:Alpha" }

        // 关闭功能后恢复原文：清空展示，且不再发起请求。
        box.isEnabled = false
        coordinator.refresh()
        await waitFor("关闭后清空译文") { coordinator.translations.isEmpty }
    }
}

final class TitleTranslationLanguageProbeTests: XCTestCase {
    func testTargetLanguageTitlesAreSkipped() {
        XCTAssertFalse(
            TitleTranslationLanguageProbe.needsTranslation(title: "深度学习的未来趋势与工程实践", targetLanguage: "简体中文")
        )
        XCTAssertFalse(
            TitleTranslationLanguageProbe.needsTranslation(title: "Deep Learning: A Survey", targetLanguage: "English")
        )
        XCTAssertTrue(
            TitleTranslationLanguageProbe.needsTranslation(title: "Deep Learning: A Survey", targetLanguage: "简体中文")
        )
        XCTAssertFalse(
            TitleTranslationLanguageProbe.needsTranslation(title: "   ", targetLanguage: "简体中文")
        )
    }
}

final class TitleTranslationSettingsTests: XCTestCase {
    func testLegacySettingsWithoutTitleTranslationDecodeAsDisabled() throws {
        var settings = AISettings.default
        var configurations = try XCTUnwrap(settings.featureConfigurations)
        configurations.removeValue(forKey: .titleTranslation)
        settings.featureConfigurations = configurations

        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        let configuration = try XCTUnwrap(decoded.configuration(for: .titleTranslation))
        // 老设置缺失该功能配置：保守地保持关闭，并回退到当前供应商模型。
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.model?.providerID, AIProviderID.deepSeek)

        let saved = decoded.updatingFeature(.titleTranslation, configuration: configuration)
        XCTAssertNotNil(saved.featureConfigurations?[.titleTranslation])
    }

    func testTranslationAdapterSupportsTitleTranslation() {
        let adapter = AIModelOption(id: "qwen-mt-lite")
        XCTAssertTrue(adapter.supports(.titleTranslation))
        XCTAssertTrue(adapter.supports(.bilingualTranslation))
        XCTAssertFalse(adapter.supports(.summary))

        let chat = AIModelOption(id: "deepseek-v4-flash")
        XCTAssertTrue(chat.supports(.titleTranslation))
    }

    func testWithTitleKeepsIdentityAndSummaryVisibility() {
        let feedID = UUID()
        let entry = EntryListItem(
            id: "entry-1",
            feedID: feedID,
            title: "Original Title",
            summaryPreview: "A short summary",
            sourceTitle: "Feed"
        )
        let translated = entry.withTitle("译文标题", summary: "译文摘要")
        XCTAssertEqual(translated.id, "entry-1")
        XCTAssertEqual(translated.feedID, feedID)
        XCTAssertEqual(translated.title, "译文标题")
        XCTAssertEqual(translated.summaryPreview, "译文摘要")
        XCTAssertEqual(translated.isSummaryVisible, entry.isSummaryVisible)
        XCTAssertEqual(translated.sourceTitle, "Feed")

        // 只替换标题时保留原摘要。
        let titleOnly = entry.withTitle("只换标题")
        XCTAssertEqual(titleOnly.title, "只换标题")
        XCTAssertEqual(titleOnly.summaryPreview, "A short summary")
    }

    func testArticleAutoTranslationEnablesListSwitchAndCapability() {
        var settings = AISettings.default
        settings = settings.updatingFeature(
            .titleTranslation,
            configuration: AIFeatureConfiguration(
                isEnabled: false,
                model: AIModelReference(providerID: AIProviderID.deepSeek, modelID: "deepseek-v4-flash")
            )
        )
        XCTAssertFalse(settings.features.automaticallyTranslate)
        XCTAssertFalse(settings.features.automaticallyTranslateTitles)

        let enabled = settings.settingArticleAutoTranslation(true)
        XCTAssertTrue(enabled.features.automaticallyTranslate)
        // 打开文章内容自动翻译时联动打开列表标题，并确保标题翻译能力可用。
        XCTAssertTrue(enabled.features.automaticallyTranslateTitles)
        XCTAssertTrue(enabled.configuration(for: .titleTranslation)?.isEnabled == true)
    }

    func testTurningOffArticleAutoTranslationKeepsListSwitch() {
        let enabled = AISettings.default.settingArticleAutoTranslation(true)
        let disabled = enabled.settingArticleAutoTranslation(false)
        XCTAssertFalse(disabled.features.automaticallyTranslate)
        // 列表标题可独立控制：关闭文章内容不影响列表标题开关。
        XCTAssertTrue(disabled.features.automaticallyTranslateTitles)
    }

    func testListTitleSwitchCanBeToggledIndependently() {
        let enabled = AISettings.default.settingTitleAutoTranslation(true)
        XCTAssertTrue(enabled.features.automaticallyTranslateTitles)
        XCTAssertFalse(enabled.features.automaticallyTranslate)
        XCTAssertTrue(enabled.configuration(for: .titleTranslation)?.isEnabled == true)

        let disabled = enabled.settingTitleAutoTranslation(false)
        XCTAssertFalse(disabled.features.automaticallyTranslateTitles)
    }

    func testLegacyPreferencesDecodeWithListSwitchOff() throws {
        let settings = AISettings.default
        let data = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var features = try XCTUnwrap(object["features"] as? [String: Any])
        features.removeValue(forKey: "automaticallyTranslateTitles")
        object["features"] = features
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AISettings.self, from: legacyData)
        XCTAssertFalse(decoded.features.automaticallyTranslateTitles)
    }
}

/// 标题/摘要翻译的存储端：一个批次一次请求、按文本去重、翻译记忆复用。
@MainActor
final class TitleTranslationStoreIntegrationTests: XCTestCase {
    private final class TitleTranslationPort: AIModelPort, @unchecked Sendable {
        private let lock = NSLock()
        private var capturedRequests = 0
        var requestCount: Int { lock.withLock { capturedRequests } }

        func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
            guard let data = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = body["messages"] as? [[String: Any]],
                  let user = messages.last?["content"] as? String,
                  let arrayLine = user.components(separatedBy: "\n").last(where: { $0.hasPrefix("[") && $0.hasSuffix("]") }),
                  let texts = try? JSONDecoder().decode([String].self, from: Data(arrayLine.utf8)) else {
                throw LLMServiceError.invalidResponse
            }
            lock.withLock { capturedRequests += 1 }
            let translations = texts.map { "译" + $0 }
            let content = String(decoding: try JSONSerialization.data(withJSONObject: translations), as: UTF8.self)
            let payload: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
            return AIModelHTTPResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: payload))
        }

        func events(for request: URLRequest) async throws -> AIModelEventResponse {
            throw LLMServiceError.invalidResponse
        }
    }

    private func makeStore(port: TitleTranslationPort) -> AppStore {
        let store = AppStore(testDatabase: .empty, aiModelPort: port)
        let provider = AIProviderProfile(
            id: "title-router",
            kind: .customOpenAICompatible,
            name: "Title Router",
            description: "",
            baseURL: "https://title-router.example.test/v1",
            selectedModelID: "title-model",
            models: [AIModelOption(id: "title-model")],
            temperature: 0.2
        )
        var settings = store.aiSettings
        settings = settings.addingProvider(provider)
        settings = settings.updatingFeature(
            .titleTranslation,
            configuration: AIFeatureConfiguration(
                isEnabled: true,
                model: AIModelReference(providerID: provider.id, modelID: "title-model"),
                reasoningMode: "自动"
            )
        )
        // 列表标题开关是标题翻译的行为开关（与功能配置的能力开关共同生效）。
        settings = settings.settingTitleAutoTranslation(true)
        store.saveAISettings(settings)
        return store
    }

    func testTranslateEntryTextsBatchesThenReusesTranslationMemory() async {
        let port = TitleTranslationPort()
        let store = makeStore(port: port)
        let texts = [
            "First Article",
            "A mock summary used to verify title and summary translation.",
            "First Article"
        ]

        let first = await store.translateEntryTexts(texts)
        XCTAssertEqual(first.translations["First Article"], "译First Article")
        XCTAssertEqual(
            first.translations["A mock summary used to verify title and summary translation."],
            "译A mock summary used to verify title and summary translation."
        )
        XCTAssertTrue(first.failedTexts.isEmpty)
        // 相同文本只发送一次，整批一个请求。
        XCTAssertEqual(port.requestCount, 1)

        let second = await store.translateEntryTexts(texts)
        XCTAssertEqual(second.translations.count, 2)
        XCTAssertTrue(second.failedTexts.isEmpty)
        // 翻译记忆命中：不再产生请求。
        XCTAssertEqual(port.requestCount, 1)
    }

    func testDisabledFeatureProducesNoRequest() async {
        let port = TitleTranslationPort()
        let store = AppStore(testDatabase: .empty, aiModelPort: port)
        let result = await store.translateEntryTexts(["First Article"])
        XCTAssertTrue(result.translations.isEmpty)
        XCTAssertEqual(port.requestCount, 0)
    }

    func testTitleTranslationSessionFollowsListSwitch() async {
        let port = TitleTranslationPort()
        let store = makeStore(port: port)
        XCTAssertNotNil(store.titleTranslationSession)

        // 关闭「列表标题」开关：会话失效，不再翻译（保留功能配置的能力开关）。
        store.saveAISettings(store.aiSettings.settingTitleAutoTranslation(false))
        XCTAssertNil(store.titleTranslationSession)
        let result = await store.translateEntryTexts(["First Article"])
        XCTAssertTrue(result.translations.isEmpty)
        XCTAssertEqual(port.requestCount, 0)
    }
}
