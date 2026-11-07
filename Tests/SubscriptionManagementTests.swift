import Foundation
import XCTest
import GRDB
@testable import PaperRssCore

private actor SubscriptionCloudFixture: ICloudAccountSyncing {
    func fetchChanges() async throws {}
    func sendChanges() async throws {}
    func stop() async {}
}

private actor SubscriptionServerFixture: AccountProvider {
    let accountID: String
    let accountType: AccountType
    let local: LocalAccountProvider
    private var requestedURLs: [URL] = []
    var shouldFail = true

    init(accountID: String, type: AccountType, database: LibraryDatabase) {
        self.accountID = accountID; self.accountType = type
        local = LocalAccountProvider(accountID: accountID, database: database)
    }
    func addFeed(url: URL, title: String?, folder: String?) async throws -> Feed {
        requestedURLs.append(url)
        if shouldFail && url.path == "/fail" { throw URLError(.notConnectedToInternet) }
        return try local.addFeed(title: title ?? "Server title", feedURL: url, folder: folder)
    }
    func allowRetry() { shouldFail = false }
    func calls() -> [URL] { requestedURLs }
    func refresh(reason: RefreshReason) async throws -> RefreshResult { RefreshResult() }
    func pushPendingArticleStates() async throws {}
    func deleteFeed(feedID: UUID) async throws { try await local.deleteFeed(feedID: feedID) }
    func addFolder(name: String) async throws -> FolderRecord { throw LocalAccountError.feedNotFound }
    func deleteFolder(name: String) async throws {}
}

@MainActor
final class SubscriptionManagementTests: XCTestCase {
    private func store() -> AppStore {
        AppStore(testDatabase: .empty, feedFetcher: { _ in .notModified(etag: nil, lastModified: nil) })
    }
    private func opml(_ outlines: String) -> Data {
        Data("<opml version=\"2.0\"><body>\(outlines)</body></opml>".utf8)
    }
    private func addServer(_ store: AppStore, type: AccountType) async throws -> SubscriptionServerFixture {
        let id = "fixture-\(type.rawValue)"
        try store.libraryDatabase.write { db in
            try AccountRecord(id: id, type: type.rawValue, displayName: "Server fixture",
                endpointURL: "https://example.invalid", username: "fixture", createdAt: 0, updatedAt: 0).save(db)
        }
        let server = SubscriptionServerFixture(accountID: id, type: type, database: store.libraryDatabase)
        await store.syncCoordinator.registerProvider(server)
        store.reloadState()
        return server
    }

    func testImportTargetsChosenICloudAccountAndPreservesFoldersWithoutTouchingLocal() async throws {
        let store = store()
        let cloud = try await store.createICloudAccount(fingerprint: "fixture", sync: SubscriptionCloudFixture())
        store.activeAccountID = "local-default"
        let data = opml("<outline text=\"Tech\"><outline title=\"Chosen\" xmlUrl=\"https://example.org/rss\"/></outline><outline text=\"Empty\"/>")
        let result = await store.importOPML(data, targetAccountID: cloud.id)
        XCTAssertEqual(result?.addedCount, 1)
        XCTAssertTrue(store.feeds(for: "local-default").isEmpty)
        XCTAssertEqual(store.feeds(for: cloud.id).first?.title, "Chosen")
        XCTAssertEqual(store.feeds(for: cloud.id).first?.folder, "Tech")
        XCTAssertTrue(store.folders(for: cloud.id).contains("Empty"))
        let repeated = await store.importOPML(data, targetAccountID: cloud.id)
        XCTAssertEqual(repeated?.addedCount, 0)
        XCTAssertEqual(repeated?.skippedCount, 1)
    }

    func testImportToEachServerPreservesDestinationAndReportsPartialFailureAndRetry() async throws {
        for type in [AccountType.freshRSS, .miniflux] {
            let store = store()
            let server = try await addServer(store, type: type)
            let data = opml("<outline text=\"Tech\"><outline title=\"Good\" xmlUrl=\"https://example.org/good\"/><outline title=\"Failed\" xmlUrl=\"https://example.org/fail\"/></outline>")
            let first = await store.importOPML(data, targetAccountID: server.accountID)
            XCTAssertEqual(first?.addedCount, 1)
            XCTAssertEqual(first?.failedTitles, ["Failed"])
            XCTAssertTrue(store.feeds(for: "local-default").isEmpty)
            XCTAssertEqual(store.feeds(for: server.accountID).first?.folder, "Tech")
            await server.allowRetry()
            let second = await store.importOPML(data, targetAccountID: server.accountID)
            XCTAssertEqual(second?.addedCount, 1)
            XCTAssertEqual(second?.skippedCount, 1)
            XCTAssertEqual(second?.failedTitles, [])
            let calls = await server.calls()
            XCTAssertEqual(calls.map(\.path), ["/good", "/fail", "/fail"])
        }
    }

    func testInvalidDisabledArchivedAndMissingTargetsNeverFallBackToLocal() async throws {
        let store = store()
        let server = try await addServer(store, type: .freshRSS)
        let data = opml("<outline title=\"One\" xmlUrl=\"https://example.org/one\"/>")
        try store.libraryDatabase.write { db in
            try db.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = ?", arguments: [server.accountID])
            try AccountRecord(id: "archived-cloud", type: "iCloud", displayName: "Archive fixture", createdAt: 0, updatedAt: 0).insert(db)
        }
        let disabled = await store.importOPML(data, targetAccountID: server.accountID)
        XCTAssertNil(disabled)
        // Archives must follow the existing suspended-scope invariant; server accounts cannot be archived.
        let archived = ICloudRecordRepository(database: store.libraryDatabase, accountID: "archived-cloud")
        try archived.activate()
        try store.libraryDatabase.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET capture_enabled = 0, suppress_capture = 1, pause_reason = 'accountChanged' WHERE account_id = 'archived-cloud'")
            try db.execute(sql: "UPDATE accounts SET is_enabled = 0, is_archived = 1 WHERE id = 'archived-cloud'")
        }
        let archivedResult = await store.importOPML(data, targetAccountID: "archived-cloud")
        XCTAssertNil(archivedResult)
        let missing = await store.importOPML(data, targetAccountID: "missing")
        XCTAssertNil(missing)
        let malformed = await store.importOPML(Data("<opml><body><outline".utf8), targetAccountID: "local-default")
        XCTAssertNil(malformed)
        XCTAssertTrue(store.feeds(for: "local-default").isEmpty)
        let calls = await server.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testCrossAccountDropCopiesSubscriptionsAndLeavesSourceHistoryAndTargetDuplicatesUntouched() async throws {
        let store = store()
        let source = try store.localProvider.addFeed(title: "Source", feedURL: URL(string: "https://example.org/rss")!, folder: "Original")
        try store.libraryDatabase.write { db in
            try ItemRecord(id: "source-article", accountID: "local-default", externalID: "source-article", feedID: source.id.uuidString, createdAt: 1, updatedAt: 1).insert(db)
            try ArticleRecord(itemID: "source-article", title: "Source article", summary: "", contentUpdatedAt: 1).insert(db)
            try ArticleStateRecord(itemID: "source-article", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).insert(db)
        }
        let cloud = try await store.createICloudAccount(fingerprint: "fixture", sync: SubscriptionCloudFixture())
        let result = await store.copyOrMoveFeeds([source.id], toFolder: "Copied", accountID: cloud.id)
        XCTAssertEqual(result?.addedCount, 1)
        let copy = try XCTUnwrap(store.feeds(for: cloud.id).first)
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.title, "Source")
        XCTAssertEqual(copy.folder, "Copied")
        XCTAssertEqual(store.feeds(for: "local-default").first?.folder, "Original")
        let state = try store.libraryDatabase.read { try ArticleStateRecord.fetchOne($0, key: "source-article") }
        XCTAssertEqual(state?.isRead, true)
        XCTAssertEqual(state?.isStarred, true)
        let repeated = await store.copyOrMoveFeeds([source.id], toFolder: "Different", accountID: cloud.id)
        XCTAssertEqual(repeated?.skippedCount, 1)
        XCTAssertEqual(store.feeds(for: cloud.id).first?.folder, "Copied")
        let moved = await store.copyOrMoveFeeds([copy.id], toFolder: nil, accountID: cloud.id)
        XCTAssertEqual(moved?.movedCount, 1)
        XCTAssertEqual(store.feeds(for: cloud.id).first?.id, copy.id)
        XCTAssertNil(store.feeds(for: cloud.id).first?.folder)
        XCTAssertFalse(store.canDropFeeds([UUID()], targetAccountID: cloud.id))
    }

    func testCrossAccountDropsWorkInBothServerDirectionsAndDeduplicateAcrossSources() async throws {
        let store = store()
        let first = try await addServer(store, type: .freshRSS)
        let second = try await addServer(store, type: .miniflux)
        let source = try await first.addFeed(url: URL(string: "https://example.org/server")!, title: "Server feed", folder: "Source")
        store.reloadState()
        let toLocal = await store.copyOrMoveFeeds([source.id], toFolder: "Local", accountID: "local-default")
        XCTAssertEqual(toLocal?.addedCount, 1)
        let localCopy = try XCTUnwrap(store.feeds(for: "local-default").first)
        let toServer = await store.copyOrMoveFeeds([source.id, localCopy.id], toFolder: "Target", accountID: second.accountID)
        XCTAssertEqual(toServer?.addedCount, 1)
        XCTAssertEqual(toServer?.skippedCount, 1)
        XCTAssertEqual(store.feeds(for: second.accountID).first?.folder, "Target")
        XCTAssertEqual(store.feeds(for: first.accountID).first?.id, source.id)
        XCTAssertEqual(store.feeds(for: "local-default").first?.id, localCopy.id)
    }

    func testImportReaddsSoftDeletedServerSubscription() async throws {
        let store = store()
        let server = try await addServer(store, type: .miniflux)
        let feed = try await server.addFeed(url: URL(string: "https://example.org/deleted")!, title: "Deleted", folder: nil)
        try store.libraryDatabase.write { db in
            try db.execute(sql: "UPDATE feeds SET is_deleted = 1 WHERE id = ?", arguments: [feed.id.uuidString])
        }
        let result = await store.importOPML(opml("<outline xmlUrl=\"https://example.org/deleted\"/>"), targetAccountID: server.accountID)
        XCTAssertEqual(result?.addedCount, 1)
        XCTAssertEqual(result?.skippedCount, 0)
        XCTAssertEqual(store.feeds(for: server.accountID).count, 1)
    }
}
