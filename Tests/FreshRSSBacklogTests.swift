import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

extension FreshRSSIntegrationTests {
    func testUnreadBacklog4100IsHydratedAndRemainsIdempotent() async throws {
        try await verifyBacklogRecovery(failureCode: nil)
    }

    func testUnreadBacklogHydrationFailureIsSavedAndRetried() async throws {
        try await verifyBacklogRecovery(failureCode: .notConnectedToInternet)
    }

    func testUnreadBacklogTimeoutClearsProgressAndRetries() async throws {
        try await verifyBacklogRecovery(failureCode: .timedOut)
    }

    func testUnreadBacklogCancellationClearsProgressAndRetries() async throws {
        try await verifyBacklogRecovery(failureCode: .cancelled)
    }

    func testRefreshProgressSnapshotPaginatesDeduplicatesAndUsesOverlap() async throws {
        let accountID = "progress-snapshot"
        try inMemoryCredentialStore.saveFreshRSSPassword("fixture", accountID: accountID)
        let calls = TestStateBox(0)
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.path.contains("ClientLogin") { return (response, Data("Auth=fixture".utf8)) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertFalse(query.contains { $0.name == "xt" }, "进度包含已读的新文章")
            XCTAssertEqual(query.first { $0.name == "ot" }?.value, "700")
            calls.mutate { $0 += 1 }
            let payload: [String: Any] = query.contains { $0.name == "c" }
                ? ["itemRefs": [["id": "2"], ["id": "3"]]]
                : ["itemRefs": [["id": "1"], ["id": "2"]], "continuation": "next"]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }
        let client = ReaderAPIClient(endpointURL: URL(string: "https://freshrss.example.com")!, username: "fixture", accountID: accountID, credentialStore: inMemoryCredentialStore, session: mockSession)
        let ids = try await client.fetchRefreshStreamItemIDs(initialSync: false, sinceTimestamp: 1000)
        XCTAssertEqual(ids, ["1", "2", "3"])
        XCTAssertEqual(calls.value, 2)
    }

    private func verifyBacklogRecovery(failureCode: URLError.Code?) async throws {
        let failHydration = failureCode != nil
        let accountID = "backlog-recovery"
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("fixture", accountID: accountID)
        try database.write { db in
            try AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Diagnostic", endpointURL: endpoint.absoluteString, username: "fixture", isEnabled: true, createdAt: 0, updatedAt: 0).save(db)
        }
        let phase = TestStateBox(0)
        let requested = TestStateBox(0)
        let shouldFail = TestStateBox(failHydration)
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let path = request.url!.path
            func item(_ id: Int) -> [String: Any] {
                var categories = ["user/-/state/com.google/reading-list"]
                if id == 100 || id == 5000 {
                    categories.append("user/-/state/com.google/starred")
                }
                if id == 5000 {
                    categories.append("user/-/state/com.google/read")
                }
                return [
                    "id": String(format: "tag:google.com,2005:reader/item/%016llx", Int64(id)),
                    "title": "Article \(id)",
                    "published": 1,
                    "origin": ["streamId": "feed/test"],
                    "categories": categories,
                    "content": ["content": "<p>Fixture</p>"]
                ]
            }
            let payload: [String: Any]
            if path.contains("ClientLogin") { return (response, Data("Auth=fixture".utf8)) }
            if path.contains("subscription/list") {
                payload = ["subscriptions": [["id": "feed/test", "title": "Test", "url": "https://example.com/rss", "categories": []]]]
            } else if path.contains("stream/items/ids") {
                let isStarred = request.url!.query!.contains("starred")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                if !isStarred && !query.contains(where: { $0.name == "xt" }) {
                    let ids = phase.value == 0 ? Array(1...200) : (phase.value >= 2 ? [4101] : [])
                    payload = ["itemRefs": ids.map { ["id": String($0)] }]
                } else {
                    payload = ["itemRefs": isStarred ? [["id": "100"], ["id": "5000"]] : (1...(phase.value >= 2 ? 4101 : 4100)).map { ["id": String($0)] }]
                }
            } else if path.contains("stream/items/contents") {
                var body = URLComponents()
                body.percentEncodedQuery = String(data: MockFreshRSSURLProtocol.requestBody(from: request), encoding: .utf8)
                let ids = (body.queryItems ?? []).filter { $0.name == "i" }.compactMap { $0.value.flatMap(Int.init) }
                XCTAssertLessThanOrEqual(ids.count, 50)
                if shouldFail.value && requested.value >= 50 {
                    throw URLError(failureCode ?? .notConnectedToInternet)
                }
                requested.mutate { $0 += ids.count }
                payload = ["items": ids.map(item)]
            } else if path.contains("stream/contents") {
                payload = ["items": phase.value == 0 ? (1...200).map(item) : (phase.value >= 2 ? [item(4101)] : [])]
            } else { payload = [:] }
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }
        let progressEvents = TestStateBox<[AccountRefreshProgress]>([])
        let progressCounts = TestStateBox<[Int]>([])
        let progressFinished = TestStateBox(false)
        let testDatabase = database!
        let provider = FreshRSSAccountProvider(accountID: accountID, endpointURL: endpoint, username: "fixture", database: database, credentialStore: inMemoryCredentialStore, session: mockSession, onProgress: { progress in
            progressFinished.value = progress == nil
            if let progress { progressEvents.mutate { $0.append(progress) } }
            if progress?.total != nil {
                let count = try? testDatabase.read { db in
                    try ItemRecord.filter(Column("account_id") == accountID).fetchCount(db)
                }
                if let count { progressCounts.mutate { $0.append(count) } }
            }
        })
        if failHydration {
            do {
                _ = try await provider.refresh(reason: .manual)
                XCTFail("补齐请求失败必须上报同步失败")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, failureCode)
            }
            let state = try database.read { db in
                try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)
            }
            XCTAssertTrue(progressFinished.value, "异常返回前必须清除进度")
            XCTAssertEqual(state?.initialSyncCompleted, false)
            XCTAssertNil(state?.lastArticleFetchAt)
            XCTAssertEqual(state?.consecutiveFailureCount, 1)
            let saved = try database.read { db in
                try ItemRecord.filter(Column("account_id") == accountID).fetchCount(db)
            }
            XCTAssertEqual(saved, 250, "失败前获取的最近文章和首批历史正文必须保存")
            shouldFail.value = false
        }
        for stage in 0...3 {
            if stage == 1 {
                // 保留已完成首次同步的游标，仅留下 400 条，模拟旧版本账号的历史缺口。
                try database.write { db in
                    try db.execute(sql: "DELETE FROM items WHERE account_id = ? AND external_id NOT IN (SELECT external_id FROM items WHERE account_id = ? ORDER BY external_id LIMIT 400)", arguments: [accountID, accountID])
                }
                requested.value = 200
            }
            progressEvents.value = []
            phase.value = stage
            _ = try await provider.refresh(reason: .manual)
            let count = try database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items i JOIN article_states s ON s.item_id = i.id WHERE i.account_id = ? AND s.is_read = 0", arguments: [accountID])!
            }
            XCTAssertEqual(requested.value, 3901, "刷新不应重复补齐已有正文")
            XCTAssertEqual(count, stage >= 2 ? 4101 : 4100)
            let starredCount = try database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items i JOIN article_states s ON s.item_id = i.id WHERE i.account_id = ? AND s.is_starred = 1", arguments: [accountID])!
            }
            XCTAssertTrue(progressFinished.value, "成功或失败后必须清除进行中状态")
            XCTAssertTrue(progressCounts.value.contains(250), "第一批完成后立即发布已落库计数")
            XCTAssertTrue(progressCounts.value.contains(400), "无需等待全量下载即可看到中间批次")
            let events = progressEvents.value
            XCTAssertEqual(events.first?.phase, .preparing)
            XCTAssertNil(events.first?.fraction)
            XCTAssertEqual(events.last?.phase, .reconciling)
            XCTAssertNil(events.last?.fraction, "校准阶段不能伪装成下载百分比")
            let downloads = events.filter { $0.phase == .downloading }
            XCTAssertEqual(downloads.first?.completed, 0)
            XCTAssertEqual(downloads.last?.completed, downloads.last?.total)
            if stage == 0 && !failHydration {
                XCTAssertEqual(downloads.first?.total, 4101)
                XCTAssertTrue(downloads.contains { $0.completed == 250 && $0.total == 4101 })
            }
            if stage >= 2 { XCTAssertEqual(downloads.first?.total, 1) }
            XCTAssertEqual(starredCount, 2, "历史已读收藏也必须补齐，未读收藏不能重复入库")
        }
    }
}
