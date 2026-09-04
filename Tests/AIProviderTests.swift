import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private final class AIProviderModelsFailureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "models-failure.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"temporarily unavailable"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class GeminiModelsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "generativelanguage.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"models/gemini-3.7-flash"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class GeminiStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gemini-stream.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Gem\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"ini OK\"}}]}\n\n"
            + "data: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct FixedAIModelPort: AIModelPort {
    let response: AIModelHTTPResponse

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        response
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        AIModelEventResponse(
            statusCode: 200,
            lines: AsyncThrowingStream { continuation in
                continuation.yield(#"data: {"choices":[{"delta":{"content":"port"}}]}"#)
                continuation.yield("data: [DONE]")
                continuation.finish()
            }
        )
    }
}

private actor PausedAIModelPort: AIModelPort {
    private var continuation: CheckedContinuation<AIModelHTTPResponse, Never>?

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        fatalError("This test port only supports non-streaming requests")
    }

    func hasPendingRequest() -> Bool { continuation != nil }

    func resume() {
        continuation?.resume(returning: AIModelHTTPResponse(
            statusCode: 200,
            data: Data(#"{"choices":[{"message":{"content":"late result"}}]}"#.utf8)
        ))
        continuation = nil
    }
}

@MainActor
private final class RequestValidity {
    var isCurrent = true
}

private final class AIActionCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [Data?] = []

    static func reset() {
        lock.lock()
        captured.removeAll()
        capturedBodies.removeAll()
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func bodies() -> [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies
    }

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            guard readCount > 0 else { break }
            data.append(buffer, count: readCount)
        }
        return data.isEmpty ? nil : data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "active-provider.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        Self.capturedBodies.append(Self.bodyData(for: request))
        Self.lock.unlock()

        let isStream = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"stream\":true") == true
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isStream {
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n".utf8))
        } else {
            client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AIProviderTests: XCTestCase {
    @MainActor
    func testCurrentSummaryIsLatestCompleteArtifactAndDoesNotDependOnFeatureModel() throws {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let entry = Entry(
            id: "stable-summary",
            feedID: UUID(),
            title: "Stable",
            url: nil,
            publishedAt: Date(),
            summary: "source"
        )
        let older = AIArtifact(
            entryID: entry.id,
            kind: .summary,
            contentHash: "old-hash",
            model: "old-model",
            targetLanguage: "简体中文",
            content: "old complete",
            isComplete: true,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newestIncomplete = AIArtifact(
            entryID: entry.id,
            kind: .summary,
            contentHash: "new-hash",
            model: "new-model",
            targetLanguage: "简体中文",
            content: "partial",
            isComplete: false,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try store.localProvider.saveArtifact(older)
        try store.localProvider.saveArtifact(newestIncomplete)

        var settings = store.aiSettings
        settings = settings.updatingFeature(
            .summary,
            configuration: AIFeatureConfiguration(
                isEnabled: true,
                model: AIModelReference(providerID: AIProviderID.gemini, modelID: "gemini-3.8-flash")
            )
        )
        store.saveAISettings(settings)

        XCTAssertEqual(store.summaryArtifact(for: entry)?.id, older.id)
        XCTAssertTrue(store.isSummaryStale(for: entry, text: "changed source"))
    }

    @MainActor
    func testReplacingCurrentSummaryTombstonesEveryOlderVersionAtomically() throws {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let database = store.libraryDatabase
        let provider = store.localProvider
        let entryID = "replace-summary"
        let old = AIArtifact(
            entryID: entryID,
            kind: .summary,
            contentHash: "old",
            model: "old-model",
            targetLanguage: "简体中文",
            content: "old",
            isComplete: true,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let replacement = AIArtifact(
            entryID: entryID,
            kind: .summary,
            contentHash: "new",
            model: "new-model",
            targetLanguage: "简体中文",
            content: "new",
            isComplete: true,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try provider.saveArtifact(old)

        try provider.replaceCurrentSummary(with: replacement)

        XCTAssertEqual(try provider.fetchArtifact(entryID: entryID, kind: .summary, isCompleteOnly: true)?.id, replacement.id)
        let flags = try database.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, is_deleted FROM ai_artifacts WHERE subject_key = ? ORDER BY updated_at",
                arguments: [entryID]
            ).map { ($0["id"] as String, $0["is_deleted"] as Bool) }
        }
        XCTAssertEqual(flags.count, 2)
        XCTAssertTrue(flags[0].1)
        XCTAssertFalse(flags[1].1)
    }

    func testV5DefaultsPreferDeepSeekAndKeepReasoningPerFeature() throws {
        let settings = AISettings.default
        let expected = AIModelReference(providerID: AIProviderID.deepSeek, modelID: "deepseek-v4-flash")

        XCTAssertEqual(settings.schema, 5)
        XCTAssertEqual(settings.providers.first?.id, AIProviderID.deepSeek)
        XCTAssertTrue(settings.providers.allSatisfy(\.isEnabled))
        for kind in AIFeatureKind.allCases {
            let configuration = try XCTUnwrap(settings.configuration(for: kind))
            XCTAssertTrue(configuration.isEnabled)
            XCTAssertEqual(configuration.model, expected)
            XCTAssertEqual(configuration.reasoningMode, "自动")
        }
        XCTAssertFalse(settings.features.automaticallyGenerateSummary)
    }

    func testV3MigrationBindsItsActiveModelAndMovesReasoningOntoEveryFeature() throws {
        let legacyProvider = AIProviderProfile(
            id: "legacy-provider",
            kind: .customOpenAICompatible,
            name: "Legacy",
            description: "",
            baseURL: "https://legacy.example.test/v1",
            selectedModelID: "legacy-model",
            models: [AIModelOption(id: "legacy-model")],
            reasoningMode: "高",
            temperature: 0.7
        )
        let v3 = AISettings(
            activeProviderID: legacyProvider.id,
            providers: [legacyProvider],
            features: .default,
            schema: 3
        )

        let migrated = v3.migratedToCurrentSchema()
        let expected = AIModelReference(providerID: legacyProvider.id, modelID: "legacy-model")
        XCTAssertEqual(migrated.schema, 5)
        XCTAssertTrue(AIFeatureKind.allCases.allSatisfy { migrated.configuration(for: $0)?.model == expected })
        XCTAssertTrue(AIFeatureKind.allCases.allSatisfy { migrated.configuration(for: $0)?.reasoningMode == "高" })
    }

    func testFeatureResolutionUsesItsOwnModelAndFeatureLevelReasoning() throws {
        let provider = AIProviderProfile(
            id: "router",
            kind: .customOpenAICompatible,
            name: "Router",
            description: "",
            baseURL: "https://router.example.test/v1",
            selectedModelID: "summary-model",
            models: [
                AIModelOption(id: "summary-model", reasoningMode: "低", temperature: 0.1),
                AIModelOption(id: "translation-model", reasoningMode: "高", temperature: 0.8)
            ]
        )
        var settings = AISettings(
            activeProviderID: provider.id,
            providers: [provider],
            features: .default
        ).migratedToCurrentSchema()
        settings = settings.updatingFeature(
            .bilingualTranslation,
            configuration: AIFeatureConfiguration(
                isEnabled: true,
                model: AIModelReference(providerID: provider.id, modelID: "translation-model"),
                reasoningMode: "中"
            )
        )

        let resolved = try XCTUnwrap(settings.resolvedConfiguration(for: .bilingualTranslation))
        XCTAssertEqual(resolved.model, "translation-model")
        XCTAssertEqual(resolved.reasoningMode, "中")
        XCTAssertEqual(resolved.temperature, 0.2)
    }

    func testDisabledProviderIsNotAvailableAndCannotResolveFeatureExecution() throws {
        var settings = AISettings.default
        let deepSeekIndex = try XCTUnwrap(settings.providers.firstIndex { $0.id == AIProviderID.deepSeek })
        settings.providers[deepSeekIndex].isEnabled = false
        settings = settings.migratedToCurrentSchema()

        XCTAssertFalse(settings.availableModelReferences.contains {
            $0.providerID == AIProviderID.deepSeek
        })
        XCTAssertNil(settings.resolvedConfiguration(for: .summary))
        XCTAssertEqual(settings.configuration(for: .summary)?.model?.providerID, AIProviderID.deepSeek)
    }

    func testV4MigrationDropsUnconfirmedRemoteCatalogButKeepsManualAndReferencedModels() throws {
        let provider = AIProviderProfile(
            id: "catalog",
            kind: .customOpenAICompatible,
            name: "Catalog",
            description: "",
            baseURL: "https://catalog.example.test/v1",
            selectedModelID: "selected-remote",
            models: [
                AIModelOption(id: "selected-remote", source: .remote),
                AIModelOption(id: "auto-fetched", source: .remote),
                AIModelOption(id: "manual-model", source: .manual)
            ]
        )
        let reference = AIModelReference(providerID: provider.id, modelID: "selected-remote")
        let v4 = AISettings(
            activeProviderID: provider.id,
            providers: [provider],
            features: .default,
            featureConfigurations: [.summary: AIFeatureConfiguration(isEnabled: true, model: reference)],
            schema: 4
        )

        let migrated = v4.migratedToCurrentSchema()
        XCTAssertEqual(migrated.provider(id: provider.id)?.models.map(\.id), ["selected-remote", "manual-model"])
    }

    func testDeletingReferencedModelRebindsFeaturesToFirstRemainingModel() throws {
        let provider = AIProviderProfile(
            id: "fallback",
            kind: .customOpenAICompatible,
            name: "Fallback",
            description: "",
            baseURL: "https://fallback.example.test/v1",
            selectedModelID: "first",
            models: [AIModelOption(id: "first"), AIModelOption(id: "second")]
        )
        var settings = AISettings(
            activeProviderID: provider.id,
            providers: [provider],
            features: .default
        ).migratedToCurrentSchema()
        settings = settings.updatingFeature(
            .summary,
            configuration: AIFeatureConfiguration(
                isEnabled: true,
                model: AIModelReference(providerID: provider.id, modelID: "second")
            )
        )

        let updated = settings.deletingModel(providerID: provider.id, modelID: "second")
        XCTAssertEqual(
            updated.configuration(for: .summary)?.model,
            AIModelReference(providerID: provider.id, modelID: "first")
        )
        XCTAssertTrue(updated.configuration(for: .summary)?.isEnabled == true)
    }

    func testLLMServiceUsesInjectedModelPort() async throws {
        let response = AIModelHTTPResponse(
            statusCode: 200,
            data: Data(#"{"choices":[{"message":{"content":"adapter"}}]}"#.utf8)
        )
        let service = LLMService(port: FixedAIModelPort(response: response))
        let result = try await service.complete(
            prompt: "hello",
            system: "test",
            configuration: .default,
            apiKey: "key"
        )
        XCTAssertEqual(result, "adapter")
    }

    @MainActor
    func testLateSelectionResultIsNotPersistedAfterDocumentInvalidation() async throws {
        let port = PausedAIModelPort()
        let validity = RequestValidity()
        let store = AppStore(
            testDatabase: .empty,
            feedFetcher: { _ in FeedFetchResult.notModified(etag: nil, lastModified: nil) },
            aiModelPort: port
        )
        let provider = AIProviderProfile.custom(
            name: "Paused provider",
            description: "",
            baseURL: "https://paused.example.test/v1",
            modelID: "paused-model"
        )
        defer { LocalAPIKeyStore.saveAPIKey("", for: provider.id) }
        store.addAIProvider(provider, apiKey: "")
        store.setActiveAIProvider(id: provider.id)
        let entry = Entry(
            id: "selection-old-document",
            feedID: UUID(),
            title: "Old document",
            url: nil,
            publishedAt: Date(),
            summary: "Old source"
        )

        let task = Task { @MainActor in
            try? await store.explainSelection(
                entry: entry,
                selection: "Old",
                articleText: "Old source",
                isRequestCurrent: { validity.isCurrent }
            )
        }
        while !(await port.hasPendingRequest()) { await Task.yield() }
        validity.isCurrent = false
        await port.resume()
        _ = await task.value

        XCTAssertTrue(store.selectionArtifacts(for: entry, articleHash: "Old source".stableDigest).isEmpty)
    }

    @MainActor
    func testBilingualTranslationMemoryKeepsTheFrozenProviderIdentity() async throws {
        let port = PausedAIModelPort()
        let store = AppStore(
            testDatabase: .empty,
            feedFetcher: { _ in FeedFetchResult.notModified(etag: nil, lastModified: nil) },
            aiModelPort: port
        )
        let first = AIProviderProfile.custom(
            name: "First frozen provider",
            description: "",
            baseURL: "https://first-frozen.example.test/v1",
            modelID: "first-model"
        )
        let second = AIProviderProfile.custom(
            name: "Second provider",
            description: "",
            baseURL: "https://second-frozen.example.test/v1",
            modelID: "second-model"
        )
        defer {
            LocalAPIKeyStore.saveAPIKey("", for: first.id)
            LocalAPIKeyStore.saveAPIKey("", for: second.id)
        }
        store.addAIProvider(first, apiKey: "")
        store.addAIProvider(second, apiKey: "")
        store.setActiveAIProvider(id: first.id)
        let entry = Entry(
            id: "frozen-bilingual-entry",
            feedID: UUID(),
            title: "Frozen",
            url: nil,
            publishedAt: Date(),
            summary: "Source"
        )

        let task = Task { @MainActor in
            await store.translateBilingualParagraphs(
                entry: entry,
                text: "Source paragraph",
                paragraphs: [ReaderParagraph(id: "p0", original: "Source paragraph")],
                paragraphIDs: ["p0"]
            )
        }
        while !(await port.hasPendingRequest()) { await Task.yield() }
        store.setActiveAIProvider(id: second.id)
        await port.resume()
        await task.value

        let providerIDs = try await store.libraryDatabase.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT provider_id FROM ai_artifacts WHERE kind = 'translation';")
        }
        XCTAssertEqual(providerIDs, [first.id])
    }

    @MainActor
    func testAppStoreSwitchingProvidersKeepsKeysAndGlobalFeaturePreferences() {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let first = AIProviderProfile.custom(
            name: "First",
            description: "First provider",
            baseURL: "https://first.example.test/v1",
            modelID: "first-model"
        )
        let second = AIProviderProfile.custom(
            name: "Second",
            description: "Second provider",
            baseURL: "https://second.example.test/v1",
            modelID: "second-model"
        )
        let originalLegacyKey = LocalAPIKeyStore.loadAPIKey()
        defer {
            LocalAPIKeyStore.saveAPIKey("", for: first.id)
            LocalAPIKeyStore.saveAPIKey("", for: second.id)
            LocalAPIKeyStore.saveAPIKey(originalLegacyKey)
        }

        store.addAIProvider(first, apiKey: "first-key")
        store.addAIProvider(second, apiKey: "second-key")

        var features = store.aiSettings.features
        features.targetLanguage = "English"
        features.automaticallyGenerateSummary = true
        features.customPrompt = "Keep terminology exact"
        store.saveAISettings(store.aiSettings.updatingFeatures(features))

        store.setActiveAIProvider(id: first.id)
        XCTAssertEqual(store.activeAPIKey(), "first-key")
        XCTAssertEqual(store.llmConfiguration.baseURL, first.baseURL)
        XCTAssertEqual(store.llmConfiguration.targetLanguage, "English")

        store.setActiveAIProvider(id: second.id)
        XCTAssertEqual(store.activeAPIKey(), "second-key")
        XCTAssertEqual(store.apiKey(for: first.id), "first-key")
        XCTAssertEqual(store.llmConfiguration.baseURL, second.baseURL)
        XCTAssertEqual(store.llmConfiguration.model, second.selectedModelID)
        XCTAssertTrue(store.llmConfiguration.automaticallyGenerateSummary)
        XCTAssertEqual(store.llmConfiguration.customPrompt, "Keep terminology exact")
    }

    @MainActor
    func testProviderConnectionTestsOnlyTheSelectedModel() async throws {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let provider = AIProviderProfile.custom(
            name: "Selected model provider",
            description: "",
            baseURL: "https://active-provider.example.test/v1",
            modelID: "selected-model"
        ).addingManualModel(id: "another-model")
        let originalLegacyKey = LocalAPIKeyStore.loadAPIKey()
        defer {
            LocalAPIKeyStore.saveAPIKey("", for: provider.id)
            LocalAPIKeyStore.saveAPIKey(originalLegacyKey)
        }

        store.addAIProvider(provider, apiKey: "selected-model-key")
        store.setActiveAIProvider(id: provider.id)

        AIActionCaptureURLProtocol.reset()
        URLProtocol.registerClass(AIActionCaptureURLProtocol.self)
        defer { URLProtocol.unregisterClass(AIActionCaptureURLProtocol.self) }

        try await store.testAIProvider(providerID: provider.id, modelID: "selected-model")

        let requests = AIActionCaptureURLProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(AIActionCaptureURLProtocol.bodies().first ?? nil)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "selected-model")
        XCTAssertNotEqual(json["model"] as? String, "another-model")
    }

    @MainActor
    func testAIActionsUseTheCurrentlySelectedProviderSnapshot() async throws {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let provider = AIProviderProfile.custom(
            name: "Active provider",
            description: "",
            baseURL: "https://active-provider.example.test/v1",
            modelID: "active-model"
        )
        let originalLegacyKey = LocalAPIKeyStore.loadAPIKey()
        defer {
            LocalAPIKeyStore.saveAPIKey("", for: provider.id)
            LocalAPIKeyStore.saveAPIKey(originalLegacyKey)
        }

        store.addAIProvider(provider, apiKey: "active-provider-key")
        store.setActiveAIProvider(id: provider.id)
        let feedID = UUID()
        let entry = Entry(
            id: "entry-active-provider-1",
            feedID: feedID,
            title: "Active provider",
            url: URL(string: "https://active-provider.example.test/article"),
            publishedAt: Date(),
            summary: "Source text"
        )

        AIActionCaptureURLProtocol.reset()
        URLProtocol.registerClass(AIActionCaptureURLProtocol.self)
        defer { URLProtocol.unregisterClass(AIActionCaptureURLProtocol.self) }

        await store.generateSummary(entry: entry, text: "Source text", force: true)
        await store.translateBilingualParagraphs(
            entry: entry,
            text: "A paragraph.",
            paragraphs: [ReaderParagraph(id: "p0", original: "A paragraph.")],
            paragraphIDs: ["p0"]
        )
        _ = try await store.explainSelection(
            entry: entry,
            selection: "A paragraph.",
            localContext: "Source text",
            articleText: "Source text"
        )
        _ = try await store.askSelection(
            entry: entry,
            selection: "A paragraph.",
            question: "What does this mean?",
            localContext: "Source text",
            articleText: "Source text"
        )

        let requests = AIActionCaptureURLProtocol.requests()
        XCTAssertGreaterThanOrEqual(requests.count, 4)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://active-provider.example.test/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer active-provider-key")
        }
    }

    @MainActor
    func testKeylessCustomProviderSendsNoAuthorizationHeader() async throws {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let provider = AIProviderProfile.custom(
            name: "Local keyless gateway",
            description: "",
            baseURL: "https://active-provider.example.test/v1",
            modelID: "local-model"
        )
        defer { LocalAPIKeyStore.saveAPIKey("", for: provider.id) }
        store.addAIProvider(provider, apiKey: "")
        store.setActiveAIProvider(id: provider.id)
        let entry = Entry(
            id: "entry-keyless-provider",
            feedID: UUID(),
            title: "Keyless",
            url: URL(string: "https://example.test/keyless"),
            publishedAt: Date(),
            summary: "Source"
        )

        AIActionCaptureURLProtocol.reset()
        URLProtocol.registerClass(AIActionCaptureURLProtocol.self)
        defer { URLProtocol.unregisterClass(AIActionCaptureURLProtocol.self) }

        await store.generateSummary(entry: entry, text: "Source", force: true)

        let requests = AIActionCaptureURLProtocol.requests()
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(store.summaryArtifact(for: entry)?.content, "OK")
    }

    @MainActor
    func testSummaryRemainsVisibleAfterExecutionFingerprintChanges() async throws {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let provider = AIProviderProfile.custom(
            name: "Fingerprint provider",
            description: "",
            baseURL: "https://active-provider.example.test/v1",
            modelID: "fingerprint-model"
        )
        defer { LocalAPIKeyStore.saveAPIKey("", for: provider.id) }
        store.addAIProvider(provider, apiKey: "")
        store.setActiveAIProvider(id: provider.id)
        let entry = Entry(
            id: "entry-fingerprint-provider",
            feedID: UUID(),
            title: "Fingerprint",
            url: URL(string: "https://example.test/fingerprint"),
            publishedAt: Date(),
            summary: "Source"
        )

        AIActionCaptureURLProtocol.reset()
        URLProtocol.registerClass(AIActionCaptureURLProtocol.self)
        defer { URLProtocol.unregisterClass(AIActionCaptureURLProtocol.self) }
        await store.generateSummary(entry: entry, text: "Source", force: true)

        XCTAssertNotNil(store.summaryArtifact(for: entry))
        var features = store.aiSettings.features
        features.targetLanguage = "English"
        store.saveAISettings(store.aiSettings.updatingFeatures(features))

        XCTAssertNotNil(store.summaryArtifact(for: entry))
        XCTAssertNotNil(try store.localProvider.fetchArtifact(entryID: entry.id, kind: .summary, isCompleteOnly: false))
    }

    func testDefaultSettingsContainBuiltInProvidersAndKeepGeminiOfficialCompatibilityEndpoint() {
        let settings = AISettings.default

        XCTAssertEqual(settings.activeProviderID, AIProviderID.deepSeek)
        XCTAssertEqual(settings.providers.map(\.id), [AIProviderID.deepSeek, AIProviderID.openAI, AIProviderID.gemini])
        let gemini = settings.provider(id: AIProviderID.gemini)
        XCTAssertEqual(gemini?.kind, .gemini)
        XCTAssertEqual(gemini?.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(gemini?.selectedModelID, "gemini-3.8-flash")
        XCTAssertEqual(settings.schema, 5)
    }

    func testExecutionFingerprintChangesForEveryOutputRelevantSetting() {
        let provider = AISettings.default.provider(id: AIProviderID.gemini)!
        let base = AIExecutionContext(
            providerID: provider.id,
            providerKind: provider.kind,
            configuration: provider.runtimeConfiguration(features: .default)
        )
        let fingerprint = base.fingerprint(for: .summary, promptVersion: 1)

        XCTAssertNotEqual(
            fingerprint,
            AIExecutionContext(providerID: "another", providerKind: provider.kind, configuration: base.configuration)
                .fingerprint(for: .summary, promptVersion: 1)
        )
        var language = base.configuration
        language.targetLanguage = "English"
        XCTAssertNotEqual(fingerprint, AIExecutionContext(providerID: provider.id, providerKind: provider.kind, configuration: language).fingerprint(for: .summary, promptVersion: 1))
        var prompt = base.configuration
        prompt.customPrompt = "Keep equations"
        XCTAssertNotEqual(fingerprint, AIExecutionContext(providerID: provider.id, providerKind: provider.kind, configuration: prompt).fingerprint(for: .summary, promptVersion: 1))
        XCTAssertNotEqual(fingerprint, base.fingerprint(for: .summary, promptVersion: 2))
    }

    func testLegacyArtifactWithoutProviderFingerprintStillDecodes() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","entryID":"legacy","kind":"summary","contentHash":"hash","model":"model","targetLanguage":"中文","content":"old","segments":[],"isComplete":true,"isDeleted":false,"createdAt":0,"updatedAt":0}"#.utf8)
        let artifact = try JSONDecoder().decode(AIArtifact.self, from: data)
        XCTAssertNil(artifact.providerID)
        XCTAssertNil(artifact.configurationFingerprint)
    }

    func testV2MigrationRestoresBuiltInEndpointAndPreservesCustomizedEndpointAsCustom() throws {
        var gemini = try XCTUnwrap(AISettings.default.provider(id: AIProviderID.gemini))
        gemini.baseURL = "https://gateway.example.test/v1"
        gemini.selectedModelID = "my-gemini-model"
        let v2 = AISettings(
            activeProviderID: gemini.id,
            providers: AISettings.default.providers.map { $0.id == gemini.id ? gemini : $0 },
            features: .default,
            schema: 2
        )

        let migrated = v2.migratedToCurrentSchema()
        XCTAssertEqual(migrated.schema, 5)
        XCTAssertEqual(migrated.provider(id: AIProviderID.gemini)?.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        let customID = AISettings.migratedCustomProviderID(for: AIProviderID.gemini)
        XCTAssertEqual(migrated.activeProviderID, customID)
        XCTAssertEqual(migrated.provider(id: customID)?.baseURL, "https://gateway.example.test/v1")
        XCTAssertEqual(migrated.provider(id: customID)?.selectedModelID, "my-gemini-model")
    }

    func testSchemaV3StillRepairsPollutedBuiltInEndpointsIdempotently() throws {
        var settings = AISettings.default
        let index = try XCTUnwrap(settings.providers.firstIndex { $0.id == AIProviderID.gemini })
        settings.providers[index].baseURL = "https://api.deepseek.com"
        settings.providers[index].selectedModelID = "gemini-user-model"

        let repaired = settings.migratedToCurrentSchema()
        let repairedAgain = repaired.migratedToCurrentSchema()

        XCTAssertEqual(repaired.provider(id: AIProviderID.gemini)?.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(repaired.provider(id: AIProviderID.gemini)?.selectedModelID, "gemini-user-model")
        XCTAssertEqual(repaired.providers.filter { $0.id == "custom.migrated.gemini" }.count, 1)
        XCTAssertEqual(repairedAgain, repaired)
    }

    func testProviderValidationRejectsCompletionURLAndRemoteHTTPButAllowsExplicitLocalHTTP() throws {
        let completionURL = AIProviderProfile.custom(
            name: "Bad",
            description: "",
            baseURL: "https://example.test/v1/chat/completions",
            modelID: "model"
        )
        XCTAssertThrowsError(try completionURL.validateConnection(requireModel: true))

        var remoteHTTP = AIProviderProfile.custom(
            name: "Remote",
            description: "",
            baseURL: "http://example.test/v1",
            modelID: "model"
        )
        remoteHTTP.allowInsecureLocalEndpoint = true
        XCTAssertThrowsError(try remoteHTTP.validateConnection(requireModel: true))

        var localHTTP = AIProviderProfile.custom(
            name: "Local",
            description: "",
            baseURL: "http://127.0.0.1:11434/v1",
            modelID: "model"
        )
        localHTTP.allowInsecureLocalEndpoint = true
        XCTAssertNoThrow(try localHTTP.validateConnection(requireModel: true))
    }

    func testLegacyConfigurationMigrationPreservesConnectionAndFeatureFields() throws {
        var legacy = LLMConfiguration.default
        legacy.providerName = "我的网关"
        legacy.providerDescription = "阅读专用"
        legacy.baseURL = "https://llm.example.test/v1"
        legacy.model = "reader-model"
        legacy.reasoningMode = "高"
        legacy.temperature = 0.7
        legacy.targetLanguage = "English"
        legacy.allowInsecureLocalEndpoint = true
        legacy.showsAISummary = false
        legacy.automaticallyGenerateSummary = true
        legacy.showsSelectionExplanation = false
        legacy.showsSelectionAsk = true
        legacy.showsSelectionTranslation = false
        legacy.customPrompt = "Keep terminology exact"

        let migrated = AISettings.migrated(from: legacy)
        let profile = try XCTUnwrap(migrated.activeProvider)

        XCTAssertEqual(profile.id, AIProviderID.migratedLegacy)
        XCTAssertEqual(profile.kind, .customOpenAICompatible)
        XCTAssertEqual(profile.name, legacy.providerName)
        XCTAssertEqual(profile.description, legacy.providerDescription)
        XCTAssertEqual(profile.baseURL, legacy.baseURL)
        XCTAssertEqual(profile.selectedModelID, legacy.model)
        XCTAssertEqual(profile.reasoningMode, legacy.reasoningMode)
        XCTAssertEqual(profile.temperature, legacy.temperature)
        XCTAssertEqual(profile.allowInsecureLocalEndpoint, legacy.allowInsecureLocalEndpoint)
        XCTAssertEqual(migrated.features, AIFeaturePreferences(configuration: legacy))
        var expected = legacy
        expected.providerKind = .customOpenAICompatible
        XCTAssertEqual(migrated.resolvedConfiguration(), expected)
    }

    func testRecognizedDeepSeekLegacyConfigurationReusesBuiltInIDWithoutDroppingFeatures() {
        var legacy = LLMConfiguration.deepSeek
        legacy.automaticallyGenerateSummary = true
        legacy.customPrompt = "Use concise Chinese"

        let migrated = AISettings.migrated(from: legacy)

        XCTAssertEqual(migrated.activeProviderID, AIProviderID.deepSeek)
        XCTAssertEqual(migrated.activeProvider?.baseURL, legacy.baseURL)
        XCTAssertEqual(migrated.activeProvider?.selectedModelID, legacy.model)
        XCTAssertEqual(migrated.features.automaticallyGenerateSummary, true)
        XCTAssertEqual(migrated.features.customPrompt, legacy.customPrompt)
    }

    func testModelRefreshKeepsManualModelsCurrentSelectionAndPriorEnableState() throws {
        var profile = AIProviderProfile(
            id: "custom",
            kind: .customOpenAICompatible,
            name: "Custom",
            description: "",
            baseURL: "https://example.test/v1",
            selectedModelID: "manual-model",
            models: [
                AIModelOption(id: "remote-old", source: .remote, isEnabled: false),
                AIModelOption(id: "manual-model", source: .manual),
                AIModelOption(id: "manual-only", source: .manual)
            ]
        )
        profile = profile.updatingModels(from: ["remote-new", "remote-old", "remote-new"])

        XCTAssertEqual(profile.selectedModelID, "manual-model")
        XCTAssertEqual(profile.models.map(\.id), ["remote-new", "remote-old", "manual-model", "manual-only"])
        XCTAssertEqual(profile.models.first(where: { $0.id == "remote-old" })?.isEnabled, false)
        XCTAssertEqual(profile.models.first(where: { $0.id == "manual-only" })?.source, .manual)
    }

    func testProviderKeyStoreIsNamespacedAndLegacyMigrationLeavesOldKeyIntact() {
        let providerID = "test-\(UUID().uuidString)"
        let legacy = "legacy-key-\(UUID().uuidString)"
        let provider = "provider-key-\(UUID().uuidString)"
        defer {
            LocalAPIKeyStore.saveAPIKey("", for: providerID)
            LocalAPIKeyStore.saveAPIKey("")
        }

        LocalAPIKeyStore.saveAPIKey(legacy)
        XCTAssertTrue(LocalAPIKeyStore.migrateLegacyAPIKeyIfNeeded(to: providerID))
        XCTAssertEqual(LocalAPIKeyStore.loadAPIKey(for: providerID), legacy)
        XCTAssertEqual(LocalAPIKeyStore.loadAPIKey(), legacy)

        LocalAPIKeyStore.saveAPIKey(provider, for: providerID)
        XCTAssertEqual(LocalAPIKeyStore.loadAPIKey(for: providerID), provider)
        XCTAssertEqual(LocalAPIKeyStore.loadAPIKey(), legacy)

        LocalAPIKeyStore.saveAPIKey("", for: providerID)
        XCTAssertTrue(LocalAPIKeyStore.migrateLegacyAPIKeyIfNeeded(to: providerID))
        XCTAssertEqual(LocalAPIKeyStore.loadAPIKey(for: providerID), "")
        XCTAssertEqual(LocalAPIKeyStore.loadAPIKey(), legacy)
    }

    @MainActor
    func testClearingActiveProviderKeyKeepsLegacyRollbackCopy() {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let provider = AIProviderProfile.custom(
            name: "Key preservation",
            description: "",
            baseURL: "https://key-preservation.example.test/v1",
            modelID: "model"
        )
        let originalLegacyKey = LocalAPIKeyStore.loadAPIKey()
        defer {
            LocalAPIKeyStore.saveAPIKey("", for: provider.id)
            LocalAPIKeyStore.saveAPIKey(originalLegacyKey)
        }

        store.addAIProvider(provider, apiKey: "provider-key")
        store.setActiveAIProvider(id: provider.id)
        let rollbackCopy = LocalAPIKeyStore.loadAPIKey()
        store.saveAIProviderKey("", for: provider.id)
        _ = store.saveLLMConfiguration(store.llmConfiguration, apiKey: "")

        XCTAssertEqual(store.activeAPIKey(), "")
        XCTAssertEqual(LocalAPIKeyStore.loadAPIKey(), rollbackCopy)
    }

    @MainActor
    func testBilingualTranslationUsesGlobalTargetLanguageWhenNoOverrideIsProvided() async throws {
        let feed = Feed(id: UUID(), title: "Language", feedURL: URL(string: "https://language.example.test/rss")!)
        let entry = Entry(
            id: "entry-language-1",
            feedID: feed.id,
            title: "Language",
            url: URL(string: "https://language.example.test/article"),
            publishedAt: Date(),
            summary: ""
        )
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        var features = store.aiSettings.features
        features.targetLanguage = "English"
        store.saveAISettings(store.aiSettings.updatingFeatures(features))

        let paragraphs = [
            ReaderParagraph(id: "title", original: "A title"),
            ReaderParagraph(id: "paragraph", original: "A paragraph.")
        ]
        store.cacheTranslations(
            [
                BilingualSegment(id: "title", original: "A title", translation: "A title"),
                BilingualSegment(id: "paragraph", original: "A paragraph.", translation: "A paragraph.")
            ],
            configuration: store.llmConfiguration
        )

        await store.translateBilingualParagraphs(
            entry: entry,
            text: "A title\n\nA paragraph.",
            paragraphs: paragraphs,
            paragraphIDs: paragraphs.map(\.id)
        )

        let artifact = try store.localProvider.fetchArtifact(entryID: entry.id, kind: .bilingual, isCompleteOnly: false)
        XCTAssertEqual(artifact?.targetLanguage, "English")
    }

    func testGeminiCompatibilityRequestUsesBearerAndDoesNotEmitDeepSeekFields() throws {
        let provider = try XCTUnwrap(AISettings.default.provider(id: AIProviderID.gemini))
        let request = try LLMService().makeRequest(
            prompt: "Hello",
            system: "You are helpful.",
            configuration: provider.runtimeConfiguration(features: .default),
            apiKey: "gemini-test-key",
            stream: true
        )

        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gemini-test-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gemini-3.8-flash")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["temperature"], "Gemini 3.x rejects the deprecated temperature field")
        XCTAssertNil(json["thinking"])
        XCTAssertNil(json["reasoning_effort"])
    }

    func testGeminiReasoningModeMapsToOpenAICompatibilityField() throws {
        let provider = try XCTUnwrap(AISettings.default.provider(id: AIProviderID.gemini))
        var configuration = provider.runtimeConfiguration(features: .default)
        configuration.reasoningMode = "高"

        let request = try LLMService().makeRequest(
            prompt: "Hello",
            system: "You are helpful.",
            configuration: configuration,
            apiKey: "gemini-test-key",
            stream: false
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["reasoning_effort"] as? String, "high")
        XCTAssertNil(json["thinking"])
    }

    func testModelsRequestUsesProviderRootAndBearerKey() throws {
        var configuration = LLMConfiguration.default
        configuration.baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/"
        let request = try LLMService().makeModelsRequest(configuration: configuration, apiKey: "key")

        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
    }

    func testGeminiModelCatalogStripsModelsNamePrefix() async throws {
        var configuration = LLMConfiguration.default
        configuration.baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"

        URLProtocol.registerClass(GeminiModelsURLProtocol.self)
        defer { URLProtocol.unregisterClass(GeminiModelsURLProtocol.self) }

        let models = try await LLMService().fetchModels(configuration: configuration, apiKey: "gemini-test-key")

        XCTAssertEqual(models, ["gemini-3.7-flash"])
    }

    func testGeminiChatRequestStripsModelsNamePrefix() throws {
        var configuration = LLMConfiguration.default
        configuration.baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
        configuration.model = "models/gemini-3.7-flash"
        let request = try LLMService().makeRequest(
            prompt: "Hello",
            system: "You are helpful.",
            configuration: configuration,
            apiKey: "gemini-test-key",
            stream: false
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gemini-3.7-flash")
        XCTAssertNil(json["temperature"], "Gemini 3.x must omit deprecated temperature even when the catalog ID had a models/ prefix")
    }

    @MainActor
    func testModelRefreshFailureLeavesExistingProviderModelsUntouched() async throws {
        let store = AppStore(testDatabase: .empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let provider = AIProviderProfile.custom(
            name: "Unavailable",
            description: "",
            baseURL: "https://models-failure.example.test/v1",
            modelID: "keep-model"
        ).addingManualModel(id: "manual-model")
        store.addAIProvider(provider, apiKey: "test-key")
        let before = store.aiProvider(id: provider.id)?.models

        URLProtocol.registerClass(AIProviderModelsFailureURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(AIProviderModelsFailureURLProtocol.self)
            LocalAPIKeyStore.saveAPIKey("", for: provider.id)
        }

        do {
            _ = try await store.fetchAIModels(providerID: provider.id)
            XCTFail("A 503 model endpoint must fail")
        } catch let error as LLMServiceError {
            guard case .httpStatus(503, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(store.aiProvider(id: provider.id)?.models, before)
    }

    func testGeminiStreamingResponseUsesOpenAIEventStreamShape() async throws {
        var configuration = LLMConfiguration.default
        configuration.baseURL = "https://gemini-stream.example.test/v1"
        configuration.model = "gemini-2.5-flash"
        let deltas = DeltaCollector()

        URLProtocol.registerClass(GeminiStreamingURLProtocol.self)
        defer { URLProtocol.unregisterClass(GeminiStreamingURLProtocol.self) }

        let result = try await LLMService().complete(
            prompt: "Reply with a short phrase.",
            system: "You are a connectivity test.",
            configuration: configuration,
            apiKey: "gemini-test-key",
            onDelta: { delta in deltas.append(delta) }
        )

        XCTAssertEqual(result, "Gemini OK")
        XCTAssertEqual(deltas.value, "Gemini OK")
    }

    func testGeminiNonStreamingResponseUsesOpenAIChoiceShape() async throws {
        final class MockURLProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}
        }

        let provider = try XCTUnwrap(AISettings.default.provider(id: AIProviderID.gemini))
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockURLProtocol.self) }

        let result = try await LLMService().complete(
            prompt: "Reply with exactly OK.",
            system: "You are a connectivity test.",
            configuration: provider.runtimeConfiguration(features: .default),
            apiKey: "gemini-test-key"
        )

        XCTAssertEqual(result, "OK")
    }
}
