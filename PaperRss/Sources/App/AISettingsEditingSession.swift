import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// 仅在进程内存活；未保存的连接与密钥不参与运行时路由。
@MainActor
final class AISettingsEditingSession: ObservableObject {
    struct Draft {
        var provider: AIProviderProfile
        var apiKey: String
        var original: AIProviderProfile?
        var originalKey: String
        var revision = 0
        var isDirty: Bool { original == nil || provider != original || apiKey != originalKey }
    }

    @Published private(set) var drafts: [String: Draft] = [:]
    @Published private(set) var newProviderID: String?
    private var operations: [String: (UUID, Task<Void, Never>?)] = [:]

    func load(_ provider: AIProviderProfile, apiKey: String) {
        guard drafts[provider.id] == nil else { return }
        drafts[provider.id] = Draft(provider: provider, apiKey: apiKey, original: provider, originalKey: apiKey)
    }

    func edit(_ id: String, _ change: (inout Draft) -> Void) {
        guard var draft = drafts[id] else { return }
        change(&draft)
        draft.revision += 1
        cancelOperations(for: id)
        drafts[id] = draft
    }

    @discardableResult
    func beginNewProvider() -> String {
        if let newProviderID { return newProviderID }
        let provider = AIProviderProfile.custom(name: "", description: "", baseURL: "", modelID: "")
        drafts[provider.id] = Draft(provider: provider, apiKey: "", original: nil, originalKey: "")
        newProviderID = provider.id
        return provider.id
    }

    func markSaved(_ id: String) {
        guard var draft = drafts[id] else { return }
        draft.original = draft.provider
        draft.originalKey = draft.apiKey
        drafts[id] = draft
        if newProviderID == id { newProviderID = nil }
    }

    func discard(_ id: String) {
        cancelOperations(for: id)
        drafts.removeValue(forKey: id)
        if newProviderID == id { newProviderID = nil }
    }

    func beginOperation(for id: String) -> UUID {
        cancelOperations(for: id)
        let token = UUID()
        operations[id] = (token, nil)
        return token
    }

    func register(_ task: Task<Void, Never>, for id: String, token: UUID) {
        guard operations[id]?.0 == token else { task.cancel(); return }
        operations[id] = (token, task)
    }

    func accepts(_ token: UUID, for id: String, revision: Int) -> Bool {
        operations[id]?.0 == token && drafts[id]?.revision == revision
    }

    func cancelOperations(for id: String) {
        operations.removeValue(forKey: id)?.1?.cancel()
    }
}
