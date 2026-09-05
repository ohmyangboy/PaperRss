import XCTest
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
final class AISettingsEditingSessionTests: XCTestCase {
    private func provider(_ name: String = "Fixture") -> AIProviderProfile {
        .custom(name: name, description: "", baseURL: "https://example.com/v1", modelID: "fixture")
    }

    func testReloadPreservesUnsavedFieldsAndKeepsOriginalUntouched() {
        let session = AISettingsEditingSession()
        let saved = provider()
        session.load(saved, apiKey: "fixture-original")
        session.edit(saved.id) { $0.provider.name = "Edited"; $0.apiKey = "fixture-draft" }
        session.load(saved, apiKey: "fixture-original")
        XCTAssertEqual(session.drafts[saved.id]?.provider.name, "Edited")
        XCTAssertEqual(session.drafts[saved.id]?.apiKey, "fixture-draft")
        XCTAssertEqual(session.drafts[saved.id]?.original, saved)
        XCTAssertEqual(session.drafts[saved.id]?.isDirty, true)
    }

    func testNewProviderIsDeduplicatedUntilSaveAndKeepsIdentity() {
        let session = AISettingsEditingSession()
        let id = session.beginNewProvider()
        XCTAssertEqual(session.beginNewProvider(), id)
        XCTAssertEqual(session.drafts[id]?.provider.models, [])
        XCTAssertEqual(session.drafts[id]?.provider.isEnabled, true)
        XCTAssertNil(session.drafts[id]?.original)
        session.markSaved(id)
        XCTAssertEqual(session.drafts[id]?.provider.id, id)
        XCTAssertFalse(session.drafts[id]!.isDirty)
        XCTAssertNotEqual(session.beginNewProvider(), id)
    }

    func testProviderKeysModelsAndEnablementStayIsolatedUntilSave() {
        let session = AISettingsEditingSession()
        let a = provider("A"), b = provider("B")
        session.load(a, apiKey: "fixture-a")
        session.load(b, apiKey: "fixture-b")
        session.edit(a.id) {
            $0.provider.isEnabled = false
            $0.apiKey = ""
            $0.provider.models.append(AIModelOption(id: "extra", source: .manual))
        }
        XCTAssertEqual(session.drafts[a.id]?.original, a)
        XCTAssertEqual(session.drafts[b.id]?.provider, b)
        XCTAssertEqual(session.drafts[b.id]?.apiKey, "fixture-b")
        session.markSaved(a.id)
        XCTAssertEqual(session.drafts[a.id]?.original?.isEnabled, false)
        XCTAssertEqual(session.drafts[a.id]?.originalKey, "")
    }

    func testDiscardRestoresSavedProviderAndCancelsNewItem() {
        let session = AISettingsEditingSession()
        let saved = provider()
        session.load(saved, apiKey: "fixture")
        session.edit(saved.id) { $0.provider.name = "Edited" }
        session.discard(saved.id)
        session.load(saved, apiKey: "fixture")
        XCTAssertEqual(session.drafts[saved.id]?.provider, saved)
        let id = session.beginNewProvider()
        session.discard(id)
        XCTAssertNil(session.newProviderID)
        XCTAssertNil(session.drafts[id])
    }

    func testEditingOrLeavingRejectsLateOperations() {
        let session = AISettingsEditingSession()
        let saved = provider()
        session.load(saved, apiKey: "fixture")
        let first = session.beginOperation(for: saved.id)
        XCTAssertTrue(session.accepts(first, for: saved.id, revision: 0))
        session.edit(saved.id) { $0.apiKey = "edited" }
        XCTAssertFalse(session.accepts(first, for: saved.id, revision: 0))
        let second = session.beginOperation(for: saved.id)
        XCTAssertTrue(session.accepts(second, for: saved.id, revision: 1))
        session.cancelOperations(for: saved.id)
        XCTAssertFalse(session.accepts(second, for: saved.id, revision: 1))
    }

    func testSupersedingOperationCancelsNetworkTaskAndRejectsOldCompletion() {
        let session = AISettingsEditingSession()
        let id = session.beginNewProvider()
        let first = session.beginOperation(for: id)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        session.register(task, for: id, token: first)
        let second = session.beginOperation(for: id)
        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(session.accepts(first, for: id, revision: 0))
        XCTAssertTrue(session.accepts(second, for: id, revision: 0))
    }
}
