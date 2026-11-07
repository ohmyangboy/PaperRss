import Foundation
#if SWIFT_PACKAGE
import PaperRssCore
import PaperRssAgentProtocol
#endif
#if os(macOS)
import AppKit
#endif

enum AgentMCPApprovalMode: String, CaseIterable {
    case ask, auto, full

    func automaticallyApplies(actionKind: String) -> Bool {
        // Auto permits only read/star state changes. Add/rename always ask; Auto never deletes feeds.
        self == .full || (self == .auto && ["mark_read", "state_change"].contains(actionKind))
    }

    var stateCapability: String { self == .full ? "state.write" : "state.write.approval" }
    var feedCapability: String { self == .full ? "feeds.manage" : "feeds.manage.approval" }
}

/// One process-owned endpoint. Only the App injects its already-open library.
@MainActor
final class AgentBridgeController: AgentBridge {
    static let shared = AgentBridgeController()
    static let enableKey = "PaperRss.agentMCPEnabled"
    static let approvalModeKey = "PaperRss.agentMCPApprovalMode"
    private var approvalMode: AgentMCPApprovalMode {
        AgentMCPApprovalMode(rawValue: defaults.string(forKey: Self.approvalModeKey) ?? "") ?? .ask
    }
    private let defaults: UserDefaults
    private var database: LibraryDatabase?
    private var accountID = "local-default"
    typealias AccountSnapshotProvider = @MainActor () throws -> [AgentJSON]
    private var accountSnapshotProvider: AccountSnapshotProvider?
    private var opener: (@MainActor @Sendable (AgentOpenRequest) throws -> Void)?
    let approvalCenter: AgentApprovalCenter
    private var clientLabels: [String: String] = [:]
    private var writeAction: (@MainActor @Sendable (String, [String], AgentStateField, Bool, Date) throws -> AgentWriteResult)?
    private var feedWriteAction: (@MainActor @Sendable (AgentFeedMutation, Date) async throws -> AgentFeedWriteResult)?
    private var sessions: [String: AgentLibraryService] = [:]
    private var generation = UUID()
    private var qaArticleIDs: [String] = []
    private var qaExpiresAt: Date?
    private var qaConsumed = false
    private var observers: [NSObjectProtocol] = []
    private(set) var transportFailure: String?
    #if os(macOS)
    private let directory: URL
    private var server: AgentIPCServer?
    #endif

    init(defaults: UserDefaults = .standard,
         directory: URL? = nil, approvalCenter: AgentApprovalCenter? = nil, launchArguments: [String] = CommandLine.arguments) {
        self.defaults = defaults
        self.approvalCenter = approvalCenter ?? AgentApprovalCenter()
        #if os(macOS)
        self.directory = directory ?? AgentIPCPaths.defaultDirectory
        #endif
        // Explicit, process-scoped QA consent. Never read IDs or approval from MCP arguments.
        // Release builds ignore these switches. One launch grants one helper session only.
        #if DEBUG
        if launchArguments.contains("--agent-qa-allow-content-egress"),
           let index = launchArguments.firstIndex(of: "--agent-qa-content-ids"),
           index + 1 < launchArguments.count {
            let ids = launchArguments[index + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if (1...20).contains(ids.count), Set(ids).count == ids.count,
               ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) {
                qaArticleIDs = ids
            }
        }
        #endif
    }

    /// App initialization owns this call; WindowGroup.onAppear must not create bridges.
    func attach(to store: AppStore, opener: @escaping @MainActor @Sendable (AgentOpenRequest) throws -> Void) {
        guard database == nil, store.startupError == nil else { return }
        approvalCenter.store = store
        writeAction = { [weak store] account, ids, field, value, expiresAt in
            guard let store else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss is not ready.") }
            return try store.applyAgentStateChange(accountID: account, articleIDs: ids, field: field, value: value, expiresAt: expiresAt)
        }
        feedWriteAction = { [weak store] mutation, expiresAt in
            guard let store else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss is not ready.") }
            return try await store.applyAgentFeedMutation(mutation, expiresAt: expiresAt)
        }
        Task { [weak self, store] in
            do { try await self?.attach(database: store.libraryDatabase, accountID: store.localProvider.accountID,
                accountSnapshotProvider: { [weak store] in
                    guard let store else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss is not ready.") }
                    return try Self.accountSnapshots(database: store.libraryDatabase, accounts: store.accounts,
                                                     syncStates: store.accountSyncStates, canOpen: true)
                }, opener: opener) }
            catch { self?.transportFailure = (error as? AgentFailure)?.code ?? "IPC_UNAVAILABLE" }
        }
    }

    /// Also used by isolated tests; never constructs a database or starts a provider/sync job.
    func attach(database: LibraryDatabase, accountID: String = "local-default",
                accountSnapshotProvider: AccountSnapshotProvider? = nil,
                opener: (@MainActor @Sendable (AgentOpenRequest) throws -> Void)? = nil) async throws {
        guard self.database == nil else { return }
        self.database = database
        self.accountID = accountID
        self.opener = opener
        self.accountSnapshotProvider = accountSnapshotProvider ?? {
            try Self.accountSnapshots(database: database, canOpen: opener != nil)
        }
        qaExpiresAt = Date().addingTimeInterval(900)
        #if os(macOS)
        let endpoint = AgentIPCServer(directory: directory, handler: { [weak self] sessionID, tool, arguments in
            guard let self else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss has stopped.") }
            return try await self.call(sessionID: sessionID, tool: tool, arguments: arguments)
        }, connected: { [weak self] sessionID, label in
            await self?.setClientLabel(label, sessionID: sessionID)
        }, disconnected: { [weak self] sessionID in
            await self?.disconnect(sessionID: sessionID)
        })
        do {
            try endpoint.start(enabled: defaults.bool(forKey: Self.enableKey))
            server = endpoint
            transportFailure = nil
        } catch {
            self.database = nil
            endpoint.stop()
            throw error
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    do { try await self?.refreshEnablement() }
                    catch { self?.transportFailure = (error as? AgentFailure)?.code ?? "IPC_UNAVAILABLE" }
                }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopTransport() }
            })
        #endif
    }

    #if DEBUG
    /// Isolated fixtures only; never reached by IPC or launch arguments.
    func attachForTesting(database: LibraryDatabase,
                          feedExecutor: (@MainActor @Sendable (AgentFeedMutation, Date) async throws -> AgentFeedWriteResult)? = nil) {
        self.database = database
        if let feedExecutor {
            feedWriteAction = feedExecutor
            writeAction = { _, _, _, _, _ in throw AgentFailure("UNSUPPORTED", "State writes unavailable in this fixture.") }
        }
        accountSnapshotProvider = { try Self.accountSnapshots(database: database) }
    }
    #endif

    func refreshEnablement() async throws {
        let enabled = defaults.bool(forKey: Self.enableKey)
        // Revoke even if filesystem state cannot be updated (for example a full disk).
        if !enabled { await revokeSessions() }
        #if os(macOS)
        try server?.setEnabled(enabled)
        #endif
    }

    private func readySession(id: String) async throws -> AgentLibraryService {
        guard defaults.bool(forKey: Self.enableKey) else {
            try await refreshEnablement()
            throw AgentFailure("NOT_ENABLED", "Enable local agent access in PaperRss first.")
        }
        guard let database else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss is not ready.") }
        let accountIDs = Set(try accountSnapshotProvider?().compactMap {
            $0["enabled"]?.boolValue == true ? $0["account_id"]?.stringValue : nil
        } ?? [])
        if let session = sessions[id] {
            await session.updateAccountIDs(accountIDs)
            return session
        }
        guard sessions.count < 16 else { throw AgentFailure("RATE_LIMITED", "Too many local agent sessions.") }
        let sessionGeneration = generation
        let created = AgentLibraryService(database: database, accountID: accountID,
            policy: AgentAccessPolicy(enabled: true, accountIDs: accountIDs, allowStarred: true, allowStateChanges: true),
            writeExecutor: writeAction.map { action in AppAgentWriteExecutor(action: { [weak self] account, ids, field, value, expiresAt in
                guard let self, self.generation == sessionGeneration, self.sessions[id] != nil,
                      self.defaults.bool(forKey: Self.enableKey) else {
                    throw AgentFailure("NOT_ENABLED", "Local agent access was revoked.")
                }
                return try action(account, ids, field, value, expiresAt)
            }, feedAction: { [weak self] mutation, expiresAt in
                guard let self, self.generation == sessionGeneration, self.sessions[id] != nil,
                      self.defaults.bool(forKey: Self.enableKey), let action = self.feedWriteAction else {
                    throw AgentFailure("NOT_ENABLED", "Feed management access was revoked.")
                }
                return try await action(mutation, expiresAt)
            }) },
            opener: { [weak self] request in
                guard let self, self.generation == sessionGeneration, self.sessions[id] != nil,
                      self.defaults.bool(forKey: Self.enableKey), let opener = self.opener else {
                    throw AgentFailure("NOT_ENABLED", "UI access is unavailable.")
                }
                let accounts = try self.accountSnapshotProvider?() ?? []
                guard accounts.contains(where: { $0["account_id"]?.stringValue == request.accountID && $0["enabled"]?.boolValue == true }) else {
                    throw AgentFailure("NOT_FOUND", "Account is unavailable.")
                }
                try opener(request)
            })
        sessions[id] = created
        if !qaConsumed, !qaArticleIDs.isEmpty, let qaExpiresAt, Date() < qaExpiresAt {
            qaConsumed = true
            do { _ = try await created.authorizeContent(accountID: accountID, articleIDs: qaArticleIDs) }
            catch {
                sessions.removeValue(forKey: id)
                await created.revoke()
                throw error
            }
        }
        return created
    }

    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        try await call(sessionID: "app", tool: tool, arguments: arguments)
    }

    func call(sessionID: String, tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        let requestGeneration = generation
        let service = try await readySession(id: sessionID)
        var response = try await service.call(tool: tool, arguments: arguments)
        guard defaults.bool(forKey: Self.enableKey), requestGeneration == generation,
              sessions[sessionID] === service else {
            throw AgentFailure("NOT_ENABLED", "Local agent access was revoked during the request.")
        }
        if ["paperrss_plan_manage_feeds", "paperrss_plan_state_change", "paperrss_plan_mark_read", "paperrss_plan_add_feed", "paperrss_plan_rename_feed", "paperrss_plan_remove_feed", "paperrss_add_feed", "paperrss_rename_feed", "paperrss_remove_feed"].contains(tool) {
            try await registerApproval(response, sessionID: sessionID)
            guard defaults.bool(forKey: Self.enableKey), requestGeneration == generation,
                  sessions[sessionID] === service else {
                throw AgentFailure("NOT_ENABLED", "Local agent access was revoked during approval.")
            }
            if var preview = response.objectValue, let planID = preview["plan_id"] {
                let status = try await service.call(tool: "paperrss_status", arguments: ["plan_id": planID])
                preview["plan_state"] = status["plan_state"]
                preview["receipt"] = status["receipt"]
                preview["approval"] = status["plan_state"]
                preview["approval_mode"] = .string(approvalMode.rawValue)
                response = .object(preview)
            }
        }
        if tool == "paperrss_status", var status = response.objectValue {
            let mode = approvalMode
            status["approval_mode"] = .string(mode.rawValue)
            status["app"] = Self.appInfo()
            status["accounts"] = .array(try (accountSnapshotProvider?() ?? []).map { account in
                guard var fields = account.objectValue, fields["enabled"]?.boolValue == true else { return account }
                var capabilities = fields["capabilities"]?.arrayValue ?? []
                capabilities.append(.string(mode.stateCapability))
                if feedWriteAction != nil { capabilities.append(.string(mode.feedCapability)) }
                fields["capabilities"] = .array(capabilities)
                return .object(fields)
            })
            status["capabilities"] = .array((Self.capabilities(canOpen: opener != nil, mode: mode) + (feedWriteAction != nil ? [mode.feedCapability] : [])).map(AgentJSON.string))
            status["tools"] = .array(AgentToolCatalog.names.map(AgentJSON.string))
            status["transport"] = .string(sessionID == "app" ? "in_process" : "unix_socket")
            status["paired"] = .bool(sessionID != "app")
            status["pair_state"] = .string(sessionID == "app" ? "app_internal" : "local_user_token")
            response = .object(status)
        }
        return response
    }

    static func appInfo(bundle: Bundle = .main) -> AgentJSON {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return .object(["version": .string(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                        "build": .string(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
                        "debug": .bool(debug)])
    }

    private static func capabilities(canOpen: Bool, mode: AgentMCPApprovalMode) -> [String] {
        ["metadata.read", "content.read.selection", mode.stateCapability] + (canOpen ? ["ui.open"] : [])
    }

    static func accountSnapshots(database: LibraryDatabase, accounts: [AccountRecord]? = nil,
                                 syncStates: [String: AccountSyncStateRecord]? = nil,
                                 canOpen: Bool = false) throws -> [AgentJSON] {
        try AgentAccountSnapshots.read(database: database, accounts: accounts, syncStates: syncStates, canOpen: canOpen)
    }

    /// Trusted App-only hook. Caller must obtain consent for the precise external session.
    func confirmContentSelection(articleIDs: [String], sessionID: String = "app") async throws -> String {
        let service = try await readySession(id: sessionID)
        return try await service.authorizeContent(accountID: accountID, articleIDs: articleIDs)
    }

    /// Trusted UI callback only. No RPC dispatch exposes approval or denial.
    func confirmStatePlan(planID: String, sessionID: String) async throws -> String {
        guard defaults.bool(forKey: Self.enableKey), let service = sessions[sessionID] else {
            throw AgentFailure("NOT_ENABLED", "Approval session is unavailable.")
        }
        return try await service.approveAndApply(planID: planID)
    }

    func denyStatePlan(planID: String, sessionID: String) async throws {
        guard let service = sessions[sessionID] else { throw AgentFailure("NOT_FOUND", "Session not found.") }
        try await service.deny(planID: planID)
    }

    private func setClientLabel(_ label: String?, sessionID: String) {
        clientLabels[sessionID] = label
    }

    private func registerApproval(_ plan: AgentJSON, sessionID: String) async throws {
        guard let planID = plan["plan_id"]?.stringValue,
              let accountID = plan["account_id"]?.stringValue,
              let expiry = plan["expires_at"]?.stringValue,
              let expiresAt = ISO8601DateFormatter().date(from: expiry) else {
            throw AgentFailure("INTERNAL", "Invalid approval preview.")
        }
        if approvalMode.automaticallyApplies(actionKind: plan["action_kind"]?.stringValue ?? "") {
            // Keep the plan discoverable via status even if its executor fails; approved plans can retry.
            _ = try? await confirmStatePlan(planID: planID, sessionID: sessionID)
            return
        }
        let account = try accountSnapshotProvider?().first { $0["account_id"]?.stringValue == accountID }
        let request = AgentApprovalCenter.Request(sessionID: sessionID, planID: planID,
            clientLabel: clientLabels[sessionID], actionKind: plan["action_kind"]?.stringValue ?? "state_change",
            accountName: account?["display_name"]?.stringValue ?? accountID,
            accountType: account?["type"]?.stringValue ?? "",
            summary: plan["summary"]?.stringValue ?? "",
            affectedCount: plan["affected_count"]?.intValue ?? 0,
            sampleTitles: plan["sample_titles"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            notice: plan["retention_notice"]?.stringValue ?? "", expiresAt: expiresAt,
            summaryEnglish: plan["summary_en"]?.stringValue,
            destructiveHint: plan["destructive_hint"]?.boolValue ?? false,
            feedChanges: plan["feed_changes"]?.arrayValue?.compactMap { change in
                guard let summary = change["summary"]?.stringValue, let english = change["summary_en"]?.stringValue else { return nil }
                return (summary, english)
            } ?? [],
            affectedFeeds: plan["affected_feeds"]?.arrayValue?.compactMap { feed in
                guard let id = feed["id"]?.stringValue, let title = feed["title"]?.stringValue else { return nil }
                return AgentFeedPreview(id: id, title: title)
            } ?? [])
        approvalCenter.register(request, approve: { [weak self] in
            guard let self else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss has stopped.") }
            _ = try await self.confirmStatePlan(planID: planID, sessionID: sessionID)
        }, deny: { [weak self] in
            guard let self else { throw AgentFailure("APP_NOT_RUNNING", "PaperRss has stopped.") }
            try await self.denyStatePlan(planID: planID, sessionID: sessionID)
        })
    }

    func disconnect(sessionID: String) async {
        clientLabels.removeValue(forKey: sessionID)
        approvalCenter.remove(sessionID: sessionID)
        let previous = sessions.removeValue(forKey: sessionID)
        await previous?.revoke()
    }

    private func revokeSessions() async {
        approvalCenter.removeAll()
        clientLabels.removeAll()
        generation = UUID()
        let previous = Array(sessions.values)
        sessions.removeAll()
        for service in previous { await service.revoke() }
    }

    /// Synchronous socket teardown is needed during process termination.
    private func stopTransport() {
        #if os(macOS)
        server?.stop()
        server = nil
        #endif
        generation = UUID()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func stop() async {
        stopTransport()
        await revokeSessions()
        database = nil
    }
}

/// App-owned executor. The closure runs on the main actor before touching AppStore.
private struct AppAgentWriteExecutor: AgentWriteExecutor {
    let action: @MainActor @Sendable (String, [String], AgentStateField, Bool, Date) async throws -> AgentWriteResult
    let feedAction: @MainActor @Sendable (AgentFeedMutation, Date) async throws -> AgentFeedWriteResult
    func executeFeed(_ mutation: AgentFeedMutation, expiresAt: Date) async throws -> AgentFeedWriteResult {
        try await feedAction(mutation, expiresAt)
    }
    func execute(accountID: String, articleIDs: [String], field: AgentStateField, value: Bool, expiresAt: Date) async throws -> AgentWriteResult {
        try await action(accountID, articleIDs, field, value, expiresAt)
    }
}
