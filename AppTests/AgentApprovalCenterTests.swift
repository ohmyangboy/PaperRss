import Foundation
import XCTest
@testable import PaperRssDesktop

@MainActor
final class AgentApprovalCenterTests: XCTestCase {
    private func request(session: String = "socket-a", plan: String = "plan", expiry: Date = Date().addingTimeInterval(60)) -> AgentApprovalCenter.Request {
        .init(sessionID: session, planID: plan, clientLabel: "Test helper", actionKind: "mark_read",
              accountName: "Synthetic", accountType: "freshRSS", summary: "Mark synthetic articles read",
              affectedCount: 2, sampleTitles: ["Untrusted **title**"], notice: "Queued for sync", expiresAt: expiry)
    }

    func testKeysIncludeSessionAndDisconnectOnlyRemovesOwner() {
        let center = AgentApprovalCenter(showPanel: false)
        center.register(request(), approve: {}, deny: {})
        center.register(request(session: "socket-b"), approve: {}, deny: {})
        center.register(request(), approve: { XCTFail("Duplicate must not replace callback") }, deny: {})
        XCTAssertEqual(center.pending.count, 2)
        center.remove(sessionID: "socket-a")
        XCTAssertEqual(center.pending.map(\.sessionID), ["socket-b"])
        center.removeAll()
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testApproveAndDenyRunOnlyChosenCallbackAndRemoveRequest() async {
        let center = AgentApprovalCenter(showPanel: false)
        var approved = 0
        var denied = 0
        let first = request()
        let second = request(plan: "second")
        center.register(first, approve: { approved += 1 }, deny: { denied += 1 })
        center.register(second, approve: { approved += 1 }, deny: { denied += 1 })
        XCTAssertEqual(approved, 0)
        await center.approve(first)
        await center.approve(first)
        await center.deny(second)
        XCTAssertEqual(approved, 1)
        XCTAssertEqual(denied, 1)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testExpiredAndRemovedRequestsCannotApprove() async {
        var now = Date()
        let center = AgentApprovalCenter(showPanel: false, clock: { now })
        let first = request(expiry: now.addingTimeInterval(10))
        center.register(first, approve: { XCTFail("Expired") }, deny: { XCTFail("Expired") })
        now = now.addingTimeInterval(11)
        await center.approve(first)
        XCTAssertTrue(center.pending.isEmpty)
        let second = request(expiry: now.addingTimeInterval(10))
        center.register(second, approve: { XCTFail("Revoked") }, deny: { XCTFail("Revoked") })
        center.removeAll()
        await center.approve(second)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testExpiryRemovesRequestAutomatically() async throws {
        let center = AgentApprovalCenter(showPanel: false)
        center.register(request(expiry: Date().addingTimeInterval(0.02)), approve: {}, deny: {})
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testDecisionFailureStaysPendingAndCanRetry() async {
        struct Failure: Error {}
        let center = AgentApprovalCenter(showPanel: false)
        let item = request()
        var attempts = 0
        center.register(item, approve: {
            attempts += 1
            if attempts == 1 { throw Failure() }
        }, deny: {})
        await center.approve(item)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertTrue(center.failed.contains(item.id))
        XCTAssertTrue(center.busy.isEmpty)
        await center.approve(item)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(center.failed.isEmpty)
    }

    func testDecisionRemainsBusyAndRejectsDuplicateClicksUntilCompletion() async {
        let center = AgentApprovalCenter(showPanel: false)
        let item = request()
        let started = expectation(description: "approval started")
        var continuation: CheckedContinuation<Void, Never>?
        var attempts = 0
        center.register(item, approve: {
            attempts += 1
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                continuation = resume
                started.fulfill()
            }
        }, deny: { XCTFail("Cannot deny while approval is running") })

        let task = Task { await center.approve(item) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(center.busy.contains(item.id))
        XCTAssertEqual(center.pending.count, 1)
        await center.approve(item)
        await center.deny(item)
        XCTAssertEqual(attempts, 1)

        continuation?.resume()
        await task.value
        XCTAssertTrue(center.busy.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
    }
}

extension AgentApprovalCenterTests {
    func testRemovalRequestHasExplicitDestructiveWarning() {
        let request = AgentApprovalCenter.Request(sessionID: "fixture", planID: "remove", clientLabel: nil,
            actionKind: "remove_feed", accountName: "Synthetic", accountType: "local",
            summary: "Remove synthetic feed", affectedCount: 3, sampleTitles: [], notice: "",
            expiresAt: Date().addingTimeInterval(60))
        XCTAssertTrue(request.isDestructive)
        XCTAssertTrue(request.isFeedManagement)
        XCTAssertFalse(request.warning.isEmpty)
        let center = AgentApprovalCenter(showPanel: false)
        center.register(request, approve: { XCTFail("No user click") }, deny: {})
        XCTAssertTrue(center.pending.first?.isDestructive == true)
        center.removeAll()
    }
}

extension AgentApprovalCenterTests {
    func testPanelKeepsExplicitConsentAndNativeButtonStyles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("PaperRss/Sources/App/AgentApprovalCenter.swift"), encoding: .utf8)
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("keyboardShortcut"), "Approval must require an explicit button click")
        XCTAssertFalse(code.contains("defaultAction"))
        let listStart = try XCTUnwrap(code.range(of: "struct AgentApprovalList: View"))
        let listCode = code[listStart.lowerBound...]
        for expiryCopy in ["到期时间", "Expires:", "到期", "expiry", "expiresAt"] {
            XCTAssertFalse(listCode.contains(expiryCopy), "Approval UI must not expose expiry: \(expiryCopy)")
        }
        let deny = try XCTUnwrap(code.range(of: "Button(i18n.localized(\"拒绝\", \"Deny\"))"))
        let approve = try XCTUnwrap(code.range(of: "Button(i18n.localized(\"批准\", \"Approve\"))"))
        XCTAssertTrue(code[deny.lowerBound..<approve.lowerBound].contains(".buttonStyle(.bordered)"))
        XCTAssertTrue(code[approve.lowerBound...].contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(code[approve.lowerBound...].contains(".tint(request.isDestructive ? Color.red : Color.accentColor)"))
        XCTAssertTrue(code.contains("width: 440, height: 340"))
        XCTAssertTrue(code.contains("panel?.title = \"PaperRss MCP\""))
        XCTAssertTrue(code.contains(".environmentObject(store.iconStore)"))
        XCTAssertTrue(code.contains("FeedFaviconView(feedID:"))
        XCTAssertTrue(code.contains(".nonactivatingPanel"))
        XCTAssertTrue(code.contains("window.isFloatingPanel = true"))
        XCTAssertTrue(code.contains("panel?." + "orderFrontRegardless()"))
        XCTAssertTrue(code.contains("NSApp.requestUserAttention(.informationalRequest)"))
        for identifier in ["panel", "deny.", "approve.", "warning."] {
            XCTAssertTrue(code.contains("agent.approval." + identifier))
        }
    }
}
