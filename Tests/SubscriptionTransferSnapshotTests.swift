import Foundation
import PaperRssAITransfer
import XCTest
@testable import PaperRssCore

final class SubscriptionTransferSnapshotTests: XCTestCase {
    private func make(feeds: [Feed], folders: [String] = []) -> SubscriptionSnapshot {
        SubscriptionTransferSnapshot.make(accountID: "selected", feedsByAccount: ["selected": feeds],
                                          foldersByAccount: ["selected": folders], sourceID: "fixture-source",
                                          sourceName: "Test Mac", accountName: "Selected account")
    }

    func testOneAccountProjectionKeepsFoldersAndDoesNotIncludeOtherAccountFeeds() throws {
        let selected = Feed(title: "Selected", feedURL: try XCTUnwrap(URL(string: "https://selected.example/feed")), folder: "Parent / Child")
        let other = Feed(title: "Other", feedURL: try XCTUnwrap(URL(string: "https://other.example/feed")))
        let feedsByAccount = ["selected": [selected], "other": [other]]
        let snapshot = SubscriptionTransferSnapshot.make(
            accountID: "selected", feedsByAccount: feedsByAccount,
            foldersByAccount: ["selected": ["Empty", "Parent / Child"], "other": ["Other folder"]],
            sourceID: "source", sourceName: "Mac", accountName: "Selected account"
        )
        XCTAssertEqual(snapshot.accountName, "Selected account")
        XCTAssertEqual(snapshot.feeds.count, 1)
        XCTAssertEqual(snapshot.feeds.first?.url, selected.feedURL.absoluteString)
        XCTAssertEqual(snapshot.feeds.first?.folders, ["Parent / Child"])
        XCTAssertEqual(snapshot.folders, ["Empty", "Parent / Child"])
        XCTAssertFalse(snapshot.feeds.contains { $0.url == other.feedURL.absoluteString })
    }

    func testDuplicateFeedRowsKeepAllMembershipsAsOneSubscription() throws {
        let id = UUID()
        let first = Feed(id: id, title: "Original", customTitle: "Custom title", feedURL: try XCTUnwrap(URL(string: "https://example.org/rss")), folder: "News")
        var second = first
        second.folder = "Favorites"
        var duplicate = first
        duplicate.folder = "News"
        let snapshot = make(feeds: [first, second, duplicate], folders: ["News", "Favorites", "Empty"])
        XCTAssertEqual(snapshot.feeds.count, 1)
        XCTAssertEqual(snapshot.feeds.first?.title, "Custom title")
        XCTAssertEqual(snapshot.feeds.first?.folder, "News")
        XCTAssertEqual(snapshot.feeds.first?.folders, ["News", "Favorites"])
        XCTAssertEqual(snapshot.folders, ["News", "Favorites", "Empty"])
    }

    func testDeletedFeedsAreExcludedAndUnsupportedURLsRemainAvailableForPreview() throws {
        let http = Feed(title: "HTTP", feedURL: try XCTUnwrap(URL(string: "http://example.org/feed")))
        let unsupported = Feed(title: "Unsupported", feedURL: try XCTUnwrap(URL(string: "file:///tmp/feed.xml")))
        let credentialURL = Feed(title: "Protected", feedURL: try XCTUnwrap(URL(string: "https://user:fixture@example.org/feed")))
        let deleted = Feed(title: "Deleted", feedURL: try XCTUnwrap(URL(string: "https://deleted.example/feed")), folder: "Removed", isDeleted: true)
        let snapshot = make(feeds: [http, unsupported, credentialURL, deleted])
        XCTAssertEqual(snapshot.feeds.map(\.id), [http, unsupported, credentialURL].map { $0.id.uuidString })
        XCTAssertEqual(snapshot.feeds.map(\.url), ["http://example.org/feed", "file:///tmp/feed.xml", "https://user:fixture@example.org/feed"])
        XCTAssertFalse(snapshot.folders.contains("Removed"))
    }

    func testSnapshotDoesNotIncludeFeedCacheOrAIFields() throws {
        let feed = Feed(title: "Example", feedURL: try XCTUnwrap(URL(string: "https://example.org/rss")), etag: "fixture-etag", lastModified: "fixture-modified")
        let data = try JSONEncoder().encode(make(feeds: [feed], folders: ["Empty", "Empty", " "]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("fixture-etag"))
        XCTAssertFalse(text.contains("fixture-modified"))
        XCTAssertFalse(text.contains("credentials"))
        XCTAssertFalse(text.contains("apiKey"))
        XCTAssertFalse(text.contains("featureConfigurations"))
        let restored = try JSONDecoder().decode(SubscriptionSnapshot.self, from: data)
        XCTAssertEqual(restored.folders, ["Empty"])
    }

    func testEmptyAccountStillKeepsEmptyFolders() {
        let snapshot = make(feeds: [], folders: ["Reading"])
        XCTAssertTrue(snapshot.feeds.isEmpty)
        XCTAssertEqual(snapshot.folders, ["Reading"])
    }
}
