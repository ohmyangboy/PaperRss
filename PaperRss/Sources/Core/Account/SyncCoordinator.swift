import Foundation

/// 多账号同步协调器。
///
/// 遵循 Architecture Contract (Section 13 / INV-01, INV-02)。
/// 负责注册、维护各账号 Provider（Local 与 FreshRSS），并统一协调认证、拉取、状态写回与同步状态追踪。
public actor SyncCoordinator {
    private var providers: [String: any AccountProvider] = [:]
    private var isSyncing: [String: Bool] = [:]

    public init() {}

    public func registerProvider(_ provider: any AccountProvider) {
        providers[provider.accountID] = provider
    }

    public func unregisterProvider(accountID: String) {
        providers.removeValue(forKey: accountID)
        isSyncing.removeValue(forKey: accountID)
    }

    public func provider(for accountID: String) -> (any AccountProvider)? {
        providers[accountID]
    }

    public func allProviders() -> [any AccountProvider] {
        Array(providers.values)
    }

    /// 刷新所有已注册且处于启用状态的账号。
    public func refreshAll(reason: RefreshReason = .manual) async -> [String: Result<RefreshResult, Error>] {
        var results: [String: Result<RefreshResult, Error>] = [:]
        for (accountID, provider) in providers {
            if isSyncing[accountID] == true {
                continue
            }
            isSyncing[accountID] = true
            do {
                let result = try await provider.refresh(reason: reason)
                results[accountID] = .success(result)
            } catch {
                results[accountID] = .failure(error)
            }
            isSyncing[accountID] = false
        }
        return results
    }

    /// 刷新特定账号。
    public func refreshAccount(accountID: String, reason: RefreshReason = .manual) async throws -> RefreshResult {
        guard let provider = providers[accountID] else {
            throw LocalAccountError.feedNotFound
        }
        if isSyncing[accountID] == true {
            return RefreshResult(status: .success)
        }
        isSyncing[accountID] = true
        defer { isSyncing[accountID] = false }
        return try await provider.refresh(reason: reason)
    }

    /// 推动所有远端账号的出站状态突变（离线突变批量推送）。
    public func pushAllPendingArticleStates() async {
        for (_, provider) in providers {
            try? await provider.pushPendingArticleStates()
        }
    }
}
