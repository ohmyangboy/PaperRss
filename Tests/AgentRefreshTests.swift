import XCTest
import PaperRssAgentProtocol

final class AgentRefreshTests: XCTestCase {
    func testSameTargetJoinsConflictsAndReplaysForThirtySeconds() {
        var board = AgentRefreshBoard()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let all = AgentRefreshRequest(scope: "all", feedCount: 4, idempotencyKey: "k")
        let account = AgentRefreshRequest(scope: "account", accountID: "local-default", feedCount: 2)
        guard case .start(let first) = board.admit(request: all, now: now, makeID: { "refresh-1" }) else {
            return XCTFail("Expected a new refresh")
        }
        guard case .joined(let joined) = board.admit(request: all, now: now.addingTimeInterval(1)) else {
            return XCTFail("Expected the running refresh")
        }
        XCTAssertEqual(joined.operationID, first.operationID)
        XCTAssertTrue(joined.joined)
        XCTAssertFalse(first.joined)
        guard case .busy(let busy) = board.admit(request: account, now: now.addingTimeInterval(1)) else {
            return XCTFail("Expected the other refresh to wait")
        }
        XCTAssertEqual(busy.operationID, "refresh-1")
        var keyed = account
        keyed.idempotencyKey = "k"
        guard case .conflict = board.admit(request: keyed, now: now.addingTimeInterval(1)) else {
            return XCTFail("Expected a key bound to a different target")
        }

        board.finish(operationID: first.operationID, detail: AgentRefreshDetail(updatedFeedCount: 1, newArticleIDs: ["a"]), now: now.addingTimeInterval(2))
        guard case .replay(let replay) = board.admit(request: all, now: now.addingTimeInterval(10)) else {
            return XCTFail("Expected the recent result")
        }
        XCTAssertEqual(replay.state, "completed")
        XCTAssertEqual(replay.newUnreadCount, 1)
        XCTAssertFalse(replay.joined)
        var again = account
        again.idempotencyKey = "k"
        guard case .start(let second) = board.admit(request: again, now: now.addingTimeInterval(40), makeID: { "refresh-2" }) else {
            return XCTFail("Expected a new refresh after 30 seconds")
        }
        XCTAssertEqual(second.operationID, "refresh-2")
        guard case .conflict = board.admit(request: all, now: now.addingTimeInterval(41)) else {
            return XCTFail("Expected the reused key to stay bound to the running target")
        }
    }

    func testFinishedReceiptTruncatesArticleIDsAndDropsExpiredOperations() {
        var board = AgentRefreshBoard()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<51).map { "article-\($0)" }
        guard case .start(let started) = board.admit(request: AgentRefreshRequest(scope: "feeds", accountID: "local", feedIDs: ["feed"], feedCount: 1), now: now, makeID: { "refresh-ids" }) else {
            return XCTFail("Expected a start")
        }
        board.finish(operationID: started.operationID, detail: AgentRefreshDetail(newArticleIDs: ids), now: now)
        let snapshot = board.snapshot(operationID: started.operationID, now: now)
        XCTAssertEqual(snapshot?.newArticleIDs.count, 50)
        XCTAssertEqual(snapshot?.truncated, true)
        XCTAssertEqual(snapshot?.newUnreadCount, 51)
        let encoded = String(decoding: try! JSONEncoder().encode(AgentJSON.object(snapshot!.fields())), as: UTF8.self)
        XCTAssertFalse(encoded.contains("title"))
        XCTAssertFalse(encoded.contains("excerpt"))
        XCTAssertNil(board.snapshot(operationID: started.operationID, now: now.addingTimeInterval(901)))

        var many = AgentRefreshBoard()
        for index in 0..<21 {
            let request = AgentRefreshRequest(scope: "feeds", accountID: "local", feedIDs: ["feed-\(index)"], feedCount: 1)
            guard case .start(let item) = many.admit(request: request, now: now, makeID: { "refresh-\(index)" }) else {
                return XCTFail("Expected start \(index)")
            }
            many.finish(operationID: item.operationID, detail: AgentRefreshDetail(), now: now)
        }
        XCTAssertNil(many.snapshot(operationID: "refresh-0", now: now))
        XCTAssertNotNil(many.snapshot(operationID: "refresh-20", now: now))
    }
}
