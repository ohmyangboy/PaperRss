import XCTest
@testable import PaperRssCore

@MainActor
final class AISettingsFirstLaunchTests: XCTestCase {
    private func withPreferences(_ legacy: LLMConfiguration?, check: (AppStore) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = ["PaperRss.aiSettings.v5", "PaperRss.aiSettings.v4", "PaperRss.aiSettings.v2", "PaperRss.llmConfiguration", "PaperRss.localAPIKey"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, original) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        } }
        for key in keys { defaults.removeObject(forKey: key) }
        if let legacy { defaults.set(try JSONEncoder().encode(legacy), forKey: "PaperRss.llmConfiguration") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(databaseURL: directory.appendingPathComponent("library.sqlite"), persistenceURL: directory.appendingPathComponent("library.json"))
        try check(store)
    }

    func testFreshInstallationBindsAllFeaturesToDeepSeek() throws {
        try withPreferences(nil) { store in
            for feature in AIFeatureKind.allCases {
                XCTAssertEqual(store.aiSettings.configuration(for: feature)?.model?.providerID, AIProviderID.deepSeek)
            }
        }
    }

    func testExistingOpenAIConfigurationKeepsItsProvider() throws {
        try withPreferences(.default) { store in
            XCTAssertEqual(store.aiSettings.configuration(for: .summary)?.model?.providerID, AIProviderID.openAI)
        }
    }
}
