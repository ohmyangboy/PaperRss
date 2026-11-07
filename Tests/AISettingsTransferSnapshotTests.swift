import Foundation
import PaperRssAITransfer
import XCTest
@testable import PaperRssCore

final class AISettingsTransferSnapshotTests: XCTestCase {
    func testSnapshotPreservesSavedSettingsAndSeparatesCredentials() throws {
        var settings = AISettings.default
        settings.features.customPrompt = "保留作者观点"
        settings.features.targetLanguage = "English"
        let saved = settings
        let snapshot = try AISettingsTransferSnapshot.make(
            settings: settings,
            sourceID: "test-mac",
            sourceName: "Test Mac",
            keyForProvider: { id in id == AIProviderID.deepSeek ? "fixture-secret-123" : "" }
        )

        XCTAssertEqual(snapshot.sourceID, "test-mac")
        XCTAssertEqual(snapshot.sourceName, "Test Mac")
        XCTAssertEqual(snapshot.credentials, [AIProviderID.deepSeek: "fixture-secret-123"])
        let restored = try snapshot.settings.decoded(as: AISettings.self)
        XCTAssertEqual(restored, saved)
        let settingsText = String(decoding: try JSONEncoder().encode(snapshot.settings), as: UTF8.self)
        XCTAssertFalse(settingsText.contains("fixture-secret-123"))
        XCTAssertEqual(settings.features.customPrompt, saved.features.customPrompt)
    }

    func testSnapshotKeepsAllProvidersAndFeatureBindingsWithoutInventingKeys() throws {
        let base = AISettings.default
        var custom = AIProviderProfile(
            id: "custom.provider",
            kind: .customOpenAICompatible,
            isEnabled: false,
            name: "Private provider",
            description: "fixture",
            baseURL: "https://example.test/v1",
            selectedModelID: "example-model",
            models: [AIModelOption(id: "example-model", reasoningMode: "自动", temperature: 0.7)]
        )
        custom.models[0].isEnabled = false
        let settings = base.addingProvider(custom)
        var visited: [String] = []
        let snapshot = try AISettingsTransferSnapshot.make(
            settings: settings,
            sourceID: "source",
            sourceName: "Mac",
            keyForProvider: { id in
                visited.append(id)
                return id == custom.id ? "fixture-key" : "   "
            }
        )
        let restored = try snapshot.settings.decoded(as: AISettings.self)
        XCTAssertEqual(visited, settings.providers.map(\.id))
        XCTAssertEqual(restored.providers.map(\.id), settings.providers.map(\.id))
        XCTAssertEqual(restored.featureConfigurations, settings.featureConfigurations)
        XCTAssertEqual(restored.providers.first(where: { $0.id == custom.id })?.isEnabled, false)
        XCTAssertEqual(snapshot.credentials, [custom.id: "fixture-key"])
    }

    func testSourceIdentityIsStableAndIsolated() {
        let suite = "AITransferSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AISettingsTransferSnapshot.sourceID(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, AISettingsTransferSnapshot.sourceID(defaults: defaults))
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("PaperRss.aiTransfer") }, ["PaperRss.aiTransfer.sourceID"])
    }
}
