import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

extension FreshRSSIntegrationTests {
    func testIncrementalOldModifiedItemDoesNotStopPagination() async throws {
        try inMemoryCredentialStore.saveFreshRSSPassword("fixture", accountID: "compat")
        let calls = TestStateBox(0)
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.path.contains("ClientLogin") { return (response, Data("Auth=fixture".utf8)) }
            calls.mutate { $0 += 1 }
            let payload: [String: Any] = calls.value == 1
                ? ["items": [["id": "1", "published": 1]], "continuation": "next"]
                : ["items": [["id": "2", "published": 2]]]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }
        let client = ReaderAPIClient(endpointURL: URL(string: "https://example.com")!, username: "fixture", accountID: "compat", credentialStore: inMemoryCredentialStore, session: mockSession)
        let result = try await client.fetchIncrementalStreamContents(sinceTimestamp: 1000, knownLocalExternalIDs: ["1"])
        XCTAssertEqual(result.items.map(\.id), ["1", "2"])
        XCTAssertTrue(result.reachedBoundary)
    }

    func testRepeatedStateContinuationFailsInsteadOfClaimingComplete() async throws {
        try inMemoryCredentialStore.saveFreshRSSPassword("fixture", accountID: "compat")
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.path.contains("ClientLogin") { return (response, Data("Auth=fixture".utf8)) }
            return (response, Data(#"{"itemRefs":[{"id":"1"}],"continuation":"same"}"#.utf8))
        }
        let client = ReaderAPIClient(endpointURL: URL(string: "https://example.com")!, username: "fixture", accountID: "compat", credentialStore: inMemoryCredentialStore, session: mockSession)
        for starred in [false, true] {
            do {
                _ = try await (starred ? client.fetchAllStarredItemIDs() : client.fetchAllUnreadItemIDs())
                XCTFail("重复游标不能被当作完整状态集合")
            } catch ReaderAPIError.decodingError { }
        }
    }

    func testUnreadIDsBeyondFiftyThousandAreNotTruncated() async throws {
        try inMemoryCredentialStore.saveFreshRSSPassword("fixture", accountID: "compat")
        let pages = TestStateBox(0)
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.path.contains("ClientLogin") { return (response, Data("Auth=fixture".utf8)) }
            let page = pages.value
            pages.mutate { $0 += 1 }
            let start = page * 10000 + 1
            let end = min(start + 9999, 50001)
            var payload: [String: Any] = ["itemRefs": (start...end).map { ["id": String($0)] }]
            if end < 50001 { payload["continuation"] = String(end) }
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }
        let client = ReaderAPIClient(endpointURL: URL(string: "https://example.com")!, username: "fixture", accountID: "compat", credentialStore: inMemoryCredentialStore, session: mockSession)
        let result = try await client.fetchAllUnreadItemIDs()
        XCTAssertEqual(result.ids.count, 50001)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(pages.value, 6)
    }

    func testManualRefreshRepairsReadHistoryAndKeepsDistinctIDsWithSameURL() async throws {
        let accountID = "history-compat"
        try inMemoryCredentialStore.saveFreshRSSPassword("fixture", accountID: accountID)
        try database.write { db in
            try AccountRecord(id: accountID, type: AccountType.freshRSS.rawValue, displayName: "Fixture", endpointURL: "https://example.com", username: "fixture", isEnabled: true, createdAt: 0, updatedAt: 0).save(db)
            try AccountSyncStateRecord(accountID: accountID, initialSyncCompleted: true, lastSyncStartedAt: nil, lastSyncCompletedAt: 1000, lastFullReconcileAt: nil, lastArticleFetchAt: 1000, consecutiveFailureCount: 0, lastError: nil).save(db)
        }
        let downloads = TestStateBox(0)
        let failState = TestStateBox(false)
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let path = request.url!.path
            if path.contains("ClientLogin") { return (response, Data("Auth=fixture".utf8)) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let payload: [String: Any]
            if path.contains("subscription/list") {
                payload = ["subscriptions": [["id": "feed/test", "title": "Test", "url": "https://example.com/rss", "categories": []]]]
            } else if path.contains("stream/items/ids") {
                if query.contains(where: { $0.name == "xt" }) && failState.value { throw URLError(.timedOut) }
                let fullHistory = !query.contains { $0.name == "xt" || $0.name == "ot" || $0.value?.contains("starred") == true }
                payload = ["itemRefs": fullHistory ? [["id": "1"], ["id": "2"]] : []]
            } else if path.contains("stream/items/contents") {
                downloads.mutate { $0 += 1 }
                payload = ["items": (1...2).map { id in
                    ["id": String(format: "tag:google.com,2005:reader/item/%016llx", Int64(id)), "title": "Article \(id)", "published": 1, "origin": ["streamId": "feed/test"], "alternate": [["href": "https://example.com/shared"]], "categories": ["user/-/state/com.google/read"], "content": ["content": "Fixture"]] as [String: Any]
                }]
            } else { payload = ["items": []] }
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }
        let provider = FreshRSSAccountProvider(accountID: accountID, endpointURL: URL(string: "https://example.com")!, username: "fixture", database: database, credentialStore: inMemoryCredentialStore, session: mockSession)
        let started = Date().timeIntervalSince1970
        for _ in 0..<2 { _ = try await provider.refresh(reason: .manual) }
        XCTAssertEqual(downloads.value, 1, "历史正文只下载一次")
        let count = try database.read { db in try ItemRecord.filter(Column("account_id") == accountID).fetchCount(db) }
        XCTAssertEqual(count, 2, "同 URL 的不同远端条目不能合并")
        let state = try database.read { db in try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)! }
        XCTAssertGreaterThanOrEqual(state.lastArticleFetchAt!, started)
        XCTAssertEqual(state.lastArticleFetchAt, state.lastSyncStartedAt, "水位取请求开始，避免漏掉下载期间的新文章")
        failState.value = true
        do {
            _ = try await provider.refresh(reason: .scheduled)
            XCTFail("旧账号的状态请求失败也必须上报")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let failed = try database.read { db in try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)! }
        XCTAssertEqual(failed.lastArticleFetchAt, state.lastArticleFetchAt)
        XCTAssertEqual(failed.consecutiveFailureCount, 1)
    }
}
