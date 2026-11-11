import Foundation
import GRDB
@testable import PaperRssCore
import XCTest
import PaperRssAgentProtocol
@testable import PaperRssDesktop

@MainActor
final class AgentBridgeControllerTests: XCTestCase {
    func testDefaultOffAndEnabledWithoutReadyAppFailClosed() async throws {
        let suite = "AgentBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = AgentBridgeController(defaults: defaults)
        do {
            _ = try await bridge.call(tool: "paperrss_list_feeds", arguments: [:])
            XCTFail("Default gate must reject")
        } catch let error as AgentFailure { XCTAssertEqual(error.code, "NOT_ENABLED") }
        defaults.set(true, forKey: AgentBridgeController.enableKey)
        do {
            _ = try await bridge.call(tool: "paperrss_status", arguments: [:])
            XCTFail("No app is attached")
        } catch let error as AgentFailure { XCTAssertEqual(error.code, "APP_NOT_RUNNING") }
        await bridge.stop()
    }
}

extension AgentBridgeControllerTests {
    func testAccountSnapshotsExposeOnlySafeFieldsForEveryAccountType() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let accounts = AccountType.allAgentFixtureTypes.enumerated().map { index, type in
            AccountRecord(id: "account-\(index)", type: type.rawValue, displayName: "RSS \(index)",
                endpointURL: "https://fixture-user:fixture-password@example.org:8443/private?token=fixture-secret",
                username: "fixture-user", isEnabled: index != 3, createdAt: 0, updatedAt: 0)
        }
        try database.write { db in
            for account in accounts { try account.insert(db) }
        }
        let provider = LocalAccountProvider(accountID: accounts[1].id, database: database)
        _ = try provider.addFeed(title: "Synthetic", feedURL: URL(string: "https://example.org/feed")!)
        let rows = try AgentBridgeController.accountSnapshots(database: database, accounts: accounts,
            syncStates: [accounts[1].id: AccountSyncStateRecord(accountID: accounts[1].id, lastSyncCompletedAt: 1_700_000_000)],
            canOpen: true)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0]["server_host"], .null)
        XCTAssertEqual(rows[1]["server_host"], .null)
        XCTAssertEqual(rows[2]["server_host"], .string("example.org:8443"))
        XCTAssertEqual(rows[3]["server_host"], .string("example.org:8443"))
        XCTAssertEqual(rows[1]["feed_count"], .number(1))
        XCTAssertEqual(rows[1]["unread_count"], .number(0))
        XCTAssertEqual(rows[1]["last_sync_at"], .string("2023-11-14T22:13:20Z"))
        XCTAssertEqual(rows[0]["last_sync_at"], .null)
        XCTAssertEqual(rows[3]["enabled"], .bool(false))
        XCTAssertEqual(rows[3]["capabilities"], .array([]))
        XCTAssertTrue(rows[2]["capabilities"]?.arrayValue?.contains(.string("ui.open")) == true)
        let text = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self).lowercased()
        for forbidden in ["password", "token", "secret", "cookie", "auth", "username", "fixture-user", "private", "https://", "@"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let defaults = try AgentBridgeController.accountSnapshots(database: database)
        XCTAssertEqual(defaults.count, 4)
        XCTAssertFalse(defaults[0]["capabilities"]?.arrayValue?.contains(.string("ui.open")) == true)
        XCTAssertNotNil(AgentBridgeController.appInfo()["debug"]?.boolValue)
        XCTAssertNotNil(AgentBridgeController.appInfo()["version"]?.stringValue)
        XCTAssertNotNil(AgentBridgeController.appInfo()["build"]?.stringValue)
    }
}

private extension AccountType {
    static let allAgentFixtureTypes: [AccountType] = [.local, .iCloud, .freshRSS, .miniflux]
}

/// Uses volatile defaults and repository-local fixtures; never reads the production library.
private final class AgentVolatileDefaults: UserDefaults, @unchecked Sendable {
    private var enabled = true
    var mode: String?
    override func string(forKey defaultName: String) -> String? { mode }
    override func bool(forKey defaultName: String) -> Bool { enabled }
    override func set(_ value: Bool, forKey defaultName: String) { enabled = value }
}

extension AgentBridgeControllerTests {
    func testApprovalRoutesToOwningSocketSessionAndRevocationClearsCenter() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/agent-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
        let defaults = AgentVolatileDefaults()
        let center = AgentApprovalCenter(showPanel: false)
        let bridge = AgentBridgeController(defaults: defaults, directory: directory, approvalCenter: center)
        bridge.attachForTesting(database: database)
        let arguments: [String: AgentJSON] = ["account_id": .string("local-default"), "scope": .string("account")]
        let first = try await bridge.call(sessionID: "socket-a", tool: "paperrss_plan_mark_read", arguments: arguments)
        let planID = try XCTUnwrap(first["plan_id"]?.stringValue)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.first?.sessionID, "socket-a")
        _ = try await bridge.call(sessionID: "socket-b", tool: "paperrss_status", arguments: [:])
        do {
            _ = try await bridge.confirmStatePlan(planID: planID, sessionID: "socket-b")
            XCTFail("Another session must not approve")
        } catch let error as AgentFailure { XCTAssertEqual(error.code, "CONFLICT") }
        await center.approve(try XCTUnwrap(center.pending.first))
        let status = try await bridge.call(sessionID: "socket-a", tool: "paperrss_status", arguments: ["plan_id": .string(planID)])
        XCTAssertEqual(status["plan_state"], .string("committed"))
        XCTAssertNotNil(status["receipt"])
        XCTAssertEqual(status["approval_mode"], .string("ask"))
        XCTAssertTrue(center.pending.isEmpty)
        _ = try await bridge.call(sessionID: "socket-a", tool: "paperrss_plan_mark_read", arguments: arguments)
        _ = try await bridge.call(sessionID: "socket-b", tool: "paperrss_plan_mark_read", arguments: arguments)
        await bridge.disconnect(sessionID: "socket-a")
        XCTAssertEqual(center.pending.map(\.sessionID), ["socket-b"])
        await center.deny(try XCTUnwrap(center.pending.first))
        XCTAssertTrue(center.pending.isEmpty)
        _ = try await bridge.call(sessionID: "socket-b", tool: "paperrss_plan_mark_read", arguments: arguments)
        defaults.set(false, forKey: AgentBridgeController.enableKey)
        try await bridge.refreshEnablement()
        XCTAssertTrue(center.pending.isEmpty)
        await bridge.stop()
    }
}

extension AgentBridgeControllerTests {
    func testFeedAliasesRequireAppClickAndUseInjectedExecutor() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/agent-feed-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
        let feed = try provider.addFeed(title: "Synthetic", feedURL: URL(string: "https://example.org/feed")!)
        let center = AgentApprovalCenter(showPanel: false)
        let bridge = AgentBridgeController(defaults: AgentVolatileDefaults(), directory: directory, approvalCenter: center)
        var executed: [String] = []
        bridge.attachForTesting(database: database, feedExecutor: { mutation, _ in
            executed.append(mutation.kind)
            return AgentFeedWriteResult(feedID: mutation.feedID ?? "created-feed", title: mutation.title ?? "Synthetic", sync: "local_only")
        })
        let status = try await bridge.call(tool: "paperrss_status", arguments: [:])
        XCTAssertTrue(status["accounts"]?.arrayValue?.first?["capabilities"]?.arrayValue?.contains(.string("feeds.manage.approval")) == true)
        for (index, tool) in ["paperrss_add_feed", "paperrss_plan_add_feed", "paperrss_rename_feed", "paperrss_plan_rename_feed", "paperrss_remove_feed", "paperrss_plan_remove_feed"].enumerated() {
            var arguments: [String: AgentJSON] = ["account_id": .string("local-default")]
            if tool.contains("add_feed") { arguments["url"] = .string("https://example.org/new-\(index)") }
            else { arguments["feed_id"] = .string(feed.id.uuidString) }
            if tool.contains("rename") { arguments["title"] = .string("Renamed") }
            let plan = try await bridge.call(tool: tool, arguments: arguments)
            let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
            XCTAssertEqual(executed.count, index)
            let request = try XCTUnwrap(center.pending.first)
            XCTAssertEqual(request.isDestructive, tool.contains("remove"))
            XCTAssertEqual(request.affectedFeeds, tool.contains("add_feed") ? [] : [
                AgentFeedPreview(id: feed.id.uuidString, title: "Synthetic")])
            do {
                _ = try await bridge.call(tool: "paperrss_apply_plan", arguments: ["plan_id": .string(id), "approval_id": .string("client-forged"), "idempotency_key": .string("forged-\(index)")])
                XCTFail("Client must not approve its own feed mutation")
            } catch let failure as AgentFailure { XCTAssertEqual(failure.code, "CONFIRMATION_REQUIRED") }
            await center.approve(request)
            let approved = try await bridge.call(tool: "paperrss_status", arguments: ["plan_id": .string(id)])
            XCTAssertEqual(approved["plan_state"], .string("committed"))
            XCTAssertNotNil(approved["receipt"])
            let approval = try await bridge.confirmStatePlan(planID: id, sessionID: "app")
            let replay = try await bridge.call(tool: "paperrss_apply_plan", arguments: ["plan_id": .string(id), "approval_id": .string(approval), "idempotency_key": .string("retry-\(index)")])
            XCTAssertEqual(replay, approved["receipt"])
            XCTAssertEqual(executed.count, index + 1)
        }
        await bridge.stop()
    }
}

extension AgentBridgeControllerTests {
    func testApprovalModesEvaluateAtRegistrationAndReportCapabilities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-modes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
        let feed = try provider.addFeed(title: "Synthetic", feedURL: URL(string: "https://example.org/feed")!)
        try database.write { db in
            try ItemRecord(id: "fixture", accountID: "local-default", externalID: "fixture",
                           feedID: feed.id.uuidString, createdAt: 1, updatedAt: 1).insert(db)
            try ArticleRecord(itemID: "fixture", title: "Synthetic", contentHTML: "").insert(db)
            try ArticleStateRecord(itemID: "fixture", isRead: false, isStarred: false, dateArrived: 1, updatedAt: 1).insert(db)
        }
        let defaults = AgentVolatileDefaults()
        let center = AgentApprovalCenter(showPanel: false)
        let bridge = AgentBridgeController(defaults: defaults, approvalCenter: center)
        bridge.attachForTesting(database: database)
        _ = try await bridge.confirmContentSelection(articleIDs: ["fixture"])
        for mode in ["ask", "auto", "full", "invalid"] {
            defaults.mode = mode
            for tool in ["paperrss_plan_mark_read", "paperrss_plan_state_change"] {
                let arguments: [String: AgentJSON] = tool == "paperrss_plan_mark_read"
                    ? ["account_id": .string("local-default"), "scope": .string("account")]
                    : ["account_id": .string("local-default"), "article_ids": .array([.string("fixture")]),
                       "field": .string("starred"), "value": .bool(true)]
                let plan = try await bridge.call(tool: tool, arguments: arguments)
                let status = try await bridge.call(tool: "paperrss_status", arguments: ["plan_id": plan["plan_id"]!])
                let automatic = mode == "auto" || mode == "full"
                XCTAssertEqual(status["plan_state"], .string(automatic ? "committed" : "pending"))
                XCTAssertEqual(status["receipt"] != nil, automatic)
                XCTAssertEqual(center.pending.isEmpty, automatic)
                XCTAssertEqual(status["approval_mode"], .string(mode == "invalid" ? "ask" : mode))
                let caps = try XCTUnwrap(status["capabilities"]?.arrayValue)
                XCTAssertTrue(caps.contains(.string(mode == "full" ? "state.write" : "state.write.approval")))
                if let request = center.pending.first { await center.deny(request) }
            }
        }
        XCTAssertTrue(try database.read { try XCTUnwrap(provider.stateRepository.fetchState(itemID: "fixture", in: $0)).isRead })
        await bridge.stop()
    }

    func testAutoAsksForEveryFeedMutationAndFullAppliesWithoutPanel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-feed-modes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
        let feed = try provider.addFeed(title: "Synthetic", feedURL: URL(string: "https://example.org/feed")!)
        let defaults = AgentVolatileDefaults()
        let center = AgentApprovalCenter(showPanel: false)
        let bridge = AgentBridgeController(defaults: defaults, approvalCenter: center)
        var executed = 0
        bridge.attachForTesting(database: database, feedExecutor: { mutation, _ in
            executed += 1
            return AgentFeedWriteResult(feedID: mutation.feedID ?? "created", title: "Synthetic", sync: "local_only")
        })
        for mode in ["auto", "full"] {
            defaults.mode = mode
            for kind in ["add_feed", "rename_feed", "remove_feed", "manage_feeds"] {
                var args: [String: AgentJSON] = ["account_id": .string("local-default")]
                if kind == "add_feed" { args["url"] = .string("https://example.org/new") }
                else { args["feed_id"] = .string(feed.id.uuidString) }
                if kind == "rename_feed" { args["title"] = .string("Renamed") }
                if kind == "manage_feeds" {
                    args = ["account_id": .string("local-default"), "operations": .array([
                        .object(["action": .string("remove_feed"), "feed_id": .string(feed.id.uuidString)])])]
                }
                let plan = try await bridge.call(tool: "paperrss_plan_\(kind)", arguments: args)
                if kind == "manage_feeds", mode == "auto" {
                    let request = try XCTUnwrap(center.pending.first)
                    XCTAssertTrue(request.isDestructive)
                    XCTAssertEqual(request.feedChanges.count, 1)
                }
                let status = try await bridge.call(tool: "paperrss_status", arguments: ["plan_id": plan["plan_id"]!])
                XCTAssertEqual(status["plan_state"], .string(mode == "full" ? "committed" : "pending"))
                XCTAssertEqual(status["receipt"] != nil, mode == "full")
                XCTAssertEqual(center.pending.isEmpty, mode == "full")
                XCTAssertTrue(status["capabilities"]?.arrayValue?.contains(.string(mode == "full" ? "feeds.manage" : "feeds.manage.approval")) == true)
                if mode == "auto" {
                    XCTAssertEqual(executed, 0)
                    await center.deny(try XCTUnwrap(center.pending.first))
                    let denied = try await bridge.call(tool: "paperrss_status", arguments: ["plan_id": plan["plan_id"]!])
                    XCTAssertEqual(denied["plan_state"], .string("denied"))
                }
            }
        }
        XCTAssertEqual(executed, 4)
        await bridge.stop()
    }
}

extension AgentBridgeControllerTests {
    func testFailedAppApplyRetainsApprovalForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
        let feed = try provider.addFeed(title: "Synthetic", feedURL: URL(string: "https://example.org/feed")!)
        let center = AgentApprovalCenter(showPanel: false)
        let bridge = AgentBridgeController(defaults: AgentVolatileDefaults(), approvalCenter: center)
        var attempts = 0
        bridge.attachForTesting(database: database, feedExecutor: { mutation, _ in
            attempts += 1
            if attempts == 1 { throw AgentFailure("CONFLICT", "Synthetic transient failure") }
            return AgentFeedWriteResult(feedID: mutation.feedID!, title: "Synthetic", sync: "local_only")
        })
        let plan = try await bridge.call(tool: "paperrss_plan_remove_feed",
            arguments: ["account_id": .string("local-default"), "feed_id": .string(feed.id.uuidString)])
        let request = try XCTUnwrap(center.pending.first)
        await center.approve(request)
        XCTAssertTrue(center.failed.contains(request.id))
        let approved = try await bridge.call(tool: "paperrss_status", arguments: ["plan_id": plan["plan_id"]!])
        XCTAssertEqual(approved["plan_state"], .string("approved"))
        XCTAssertNil(approved["receipt"])
        let receipt = try await bridge.call(tool: "paperrss_apply_plan", arguments: [
            "plan_id": plan["plan_id"]!, "approval_id": try XCTUnwrap(approved["approval_id"]),
            "idempotency_key": .string("optional-recovery")])
        await center.approve(request)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(attempts, 2)
        let committed = try await bridge.call(tool: "paperrss_status", arguments: ["plan_id": plan["plan_id"]!])
        XCTAssertEqual(committed["receipt"], receipt)
        await bridge.stop()
    }
}

extension AgentBridgeControllerTests {
    func testRefreshJoinsConflictsAndReplaysWithoutApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
        _ = try provider.addFeed(title: "Synthetic", feedURL: URL(string: "https://example.org/feed")!)
        let center = AgentApprovalCenter(showPanel: false)
        let bridge = AgentBridgeController(defaults: AgentVolatileDefaults(), approvalCenter: center)
        let probe = AgentRefreshProbe()
        bridge.attachForTesting(database: database)
        bridge.setRefreshWorkForTesting { _ in
            let index = probe.begin()
            if index == 1 { await probe.wait() }
            return AgentRefreshDetail(updatedFeedCount: 1, newArticleIDs: ["article-1"])
        }

        let idle = try await bridge.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(idle["approval_mode"], .string("ask"))
        XCTAssertTrue(idle["capabilities"]?.arrayValue?.contains(.string("feeds.refresh")) == true)
        XCTAssertTrue(center.pending.isEmpty)

        let first = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: [
            "scope": .string("all"), "idempotency_key": .string("batch-1")])
        let operationID = try XCTUnwrap(first["operation_id"]?.stringValue)
        XCTAssertTrue(operationID.hasPrefix("refresh-"))
        XCTAssertEqual(first["state"], .string("running"))
        XCTAssertEqual(first["joined"], .bool(false))
        XCTAssertEqual(first["feed_count"], .number(1))

        let joined = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: ["scope": .string("all")])
        XCTAssertEqual(joined["operation_id"], .string(operationID))
        XCTAssertEqual(joined["joined"], .bool(true))
        XCTAssertEqual(joined["state"], .string("running"))
        do {
            _ = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: [
                "scope": .string("account"), "account_id": .string("local-default")])
            XCTFail("A different target must not start")
        } catch let error as AgentFailure {
            XCTAssertEqual(error.code, "REFRESH_IN_PROGRESS")
            XCTAssertTrue(error.message.contains(operationID))
        }
        do {
            _ = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: [
                "scope": .string("account"), "account_id": .string("local-default"),
                "idempotency_key": .string("batch-1")])
            XCTFail("A key must stay bound to its target")
        } catch let error as AgentFailure {
            XCTAssertEqual(error.code, "CONFLICT")
        }
        for _ in 0..<50 where probe.count < 1 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(probe.count, 1)

        probe.release()
        var finished = first
        for _ in 0..<50 where finished["state"] == .string("running") {
            finished = try await bridge.call(tool: "paperrss_status", arguments: ["operation_id": .string(operationID)])
            if finished["state"] == .string("running") {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTAssertEqual(finished["state"], .string("completed"))
        XCTAssertEqual(finished["updated_feed_count"], .number(1))
        XCTAssertEqual(finished["new_unread_count"], .number(1))
        XCTAssertEqual(finished["new_article_ids"], .array([.string("article-1")]))
        XCTAssertEqual(probe.count, 1)
        let encoded = String(decoding: try JSONEncoder().encode(finished), as: UTF8.self)
        XCTAssertFalse(encoded.contains("title"))
        XCTAssertFalse(encoded.contains("http"))

        let replay = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: ["scope": .string("all")])
        XCTAssertEqual(replay["operation_id"], .string(operationID))
        XCTAssertEqual(replay["state"], .string("completed"))
        XCTAssertEqual(probe.count, 1)

        let next = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: [
            "scope": .string("account"), "account_id": .string("local-default")])
        XCTAssertEqual(next["state"], .string("running"))
        XCTAssertNotEqual(next["operation_id"], .string(operationID))
        for _ in 0..<50 where probe.count < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(probe.count, 2)
        await bridge.stop()
    }
}

private final class AgentRefreshProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        starts += 1
        return starts
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.released {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
