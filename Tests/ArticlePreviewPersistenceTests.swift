import XCTest
import GRDB
@testable import PaperRssCore

@MainActor
final class ArticlePreviewPersistenceTests: XCTestCase {
    private func temporaryDatabase() throws -> (LibraryDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewPersistence-\(UUID())")
        return (try LibraryDatabase(databaseURL: root.appendingPathComponent("library.sqlite")), root)
    }
    private func seed(_ database: LibraryDatabase, feedID: String) throws {
        try database.write { db in
            try AccountRecord(id: "local-default", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save(db)
            try FeedRecord(id: feedID, accountID: "local-default", title: "Feed", siteURL: "https://publisher.example", feedURL: "https://publisher.example/rss", updatedAt: 1).save(db)
        }
    }
    private func parsed(_ id: String, image: String?, date: Double = 100) -> ParsedFeedEntry {
        let html = image.map { "<p>Body</p><img src='\($0)'>" } ?? "<p>Body without a photo</p>"
        return ParsedFeedEntry(id: id, title: "Article \(id)", url: URL(string: "https://publisher.example/\(id)"),
            publishedAt: Date(timeIntervalSince1970: date), summary: "Summary", contentHTML: html,
            previewImage: EntryPreviewImageExtractor.extract(contentHTML: html, baseURL: URL(string: "https://publisher.example")))
    }

    func testNewUpdatedAndRestoredMetadataPreservesArticleStates() throws {
        let (database, root) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let feedID = UUID().uuidString
        try seed(database, feedID: feedID)
        let repository = ArticleRepository(database: database)
        let id: String = try database.write { db in
            let entries = try repository.mergeParsedEntries(feedID: feedID, parsedEntries: [parsed("one", image: "/first.jpg")], in: db)
            let id = try XCTUnwrap(entries.first?.id)
            XCTAssertEqual(entries.first?.previewImageURL?.path, "/first.jpg")
            try db.execute(sql: "UPDATE article_states SET is_read = 1, is_starred = 1 WHERE item_id = ?", arguments: [id])
            return id
        }
        try database.write { db in
            let new = try repository.mergeParsedEntries(feedID: feedID, parsedEntries: [parsed("one", image: "/changed.jpg")], in: db)
            XCTAssertTrue(new.isEmpty)
            XCTAssertEqual(try repository.fetchEntry(id: id, in: db)?.previewImageURL?.path, "/changed.jpg")
            let state = try XCTUnwrap(ArticleStateRecord.fetchOne(db, key: id))
            XCTAssertTrue(state.isRead)
            XCTAssertTrue(state.isStarred)
            try repository.deleteArticle(itemID: id, in: db)
            _ = try repository.mergeParsedEntries(feedID: feedID, parsedEntries: [parsed("one", image: "/restored.jpg")], in: db)
            XCTAssertEqual(try repository.fetchEntry(id: id, in: db)?.previewImageURL?.path, "/restored.jpg")
            XCTAssertEqual(try ArticleStateRecord.fetchOne(db, key: id), state)
            _ = try repository.mergeParsedEntries(feedID: feedID, parsedEntries: [parsed("one", image: nil)], in: db)
            let article = try XCTUnwrap(ArticleRecord.fetchOne(db, key: id))
            XCTAssertNil(article.previewImageURL)
            XCTAssertEqual(article.previewExtractionRevision, EntryPreviewImage.currentRevision)
        }
    }

    func testDescriptionOnlyMetadataChangeIsPersistedEvenWhenBodyIsUnchanged() throws {
        let (database, root) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let feedID = UUID().uuidString
        try seed(database, feedID: feedID)
        let repository = ArticleRepository(database: database)
        var original = parsed("one", image: nil)
        original.previewImage = EntryPreviewImageExtractor.extract(descriptionHTML: "<img src='/old.jpg'>", contentHTML: original.contentHTML, baseURL: original.url)
        var updated = original
        updated.previewImage = EntryPreviewImageExtractor.extract(descriptionHTML: "<img src='/new.jpg'>", contentHTML: original.contentHTML, baseURL: original.url)
        try database.write { db in
            let first = try repository.mergeParsedEntries(feedID: feedID, parsedEntries: [original], in: db)
            let id = try XCTUnwrap(first.first?.id)
            _ = try repository.mergeParsedEntries(feedID: feedID, parsedEntries: [updated], in: db)
            XCTAssertEqual(try repository.fetchEntry(id: id, in: db)?.previewImageURL?.path, "/new.jpg")
        }
    }

    func testListAndAdjacentProjectionsStayLightweight() throws {
        let (database, root) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let feedID = UUID().uuidString
        try seed(database, feedID: feedID)
        let repository = ArticleRepository(database: database)
        try database.write { db in
            _ = try repository.mergeParsedEntries(feedID: feedID, parsedEntries: [parsed("new", image: "/new.jpg", date: 200), parsed("old", image: "/old.jpg", date: 100)], in: db)
        }
        let query = TimelineQueryService(database: database)
        let items = try query.fetchListItems(scope: .all, limit: 100)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].previewImageURL?.path, "/new.jpg")
        XCTAssertFalse(Mirror(reflecting: items[0]).children.contains { $0.label == "contentHTML" })
        let next = try query.fetchAdjacentItem(scope: .all, currentItemID: items[0].id, direction: .next)
        XCTAssertEqual(next?.id, items[1].id)
        XCTAssertEqual(next?.previewImageURL?.path, "/old.jpg")
    }

    func testBackfillIsBoundedIdempotentAndDoesNotChangeReadOrStarState() async throws {
        let (database, root) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let feedID = UUID().uuidString
        try seed(database, feedID: feedID)
        let ids = (0..<103).map { "legacy-\($0)" }
        try database.write { db in
            for id in ids {
                try ItemRecord(id: id, accountID: "local-default", externalID: id, feedID: feedID, createdAt: 7, updatedAt: 7).save(db)
                try ArticleRecord(itemID: id, title: id, contentHTML: "<img src='/legacy.jpg'>", contentUpdatedAt: 7).save(db)
                try ArticleStateRecord(itemID: id, isRead: true, isStarred: true, dateArrived: 7, updatedAt: 7).save(db)
            }
        }
        let backfill = ArticlePreviewBackfill(database: database)
        let first = try await backfill.prepare(entryIDs: ids)
        XCTAssertEqual(first, 100)
        let repeated = try await backfill.prepare(entryIDs: Array(ids.prefix(100)))
        XCTAssertEqual(repeated, 0)
        let last = try await backfill.prepare(entryIDs: Array(ids.suffix(3)))
        XCTAssertEqual(last, 3)
        try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM articles WHERE preview_image_url = 'https://publisher.example/legacy.jpg'"), 103)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_states WHERE is_read = 1 AND is_starred = 1 AND updated_at = 7"), 103)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM articles WHERE content_updated_at = 7"), 103)
        }
    }

    func testV11UpgradeAddsNullableMetadataWithoutReadingOldHTML() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try DatabaseMigrations.migrator.migrate(queue, upTo: "v11-deduplicate-feed-articles")
            try queue.write { db in
                try AccountRecord(id: "local-default", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save(db)
                try FeedRecord(id: "feed", accountID: "local-default", title: "Feed", feedURL: "https://example.com/rss", updatedAt: 1).save(db)
                try ItemRecord(id: "old", accountID: "local-default", externalID: "old", feedID: "feed", createdAt: 1, updatedAt: 1).save(db)
                try db.execute(sql: "INSERT INTO articles(item_id,title,summary,content_html,content_updated_at) VALUES('old','Old','Summary','<img src=old.jpg>',1)")
                try ArticleStateRecord(itemID: "old", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
            }
        }
        let database = try LibraryDatabase(databaseURL: url)
        try database.read { db in
            let article = try XCTUnwrap(ArticleRecord.fetchOne(db, key: "old"))
            XCTAssertEqual(article.contentHTML, "<img src=old.jpg>")
            XCTAssertNil(article.previewImageURL)
            XCTAssertEqual(article.previewExtractionRevision, 0)
            let state = try XCTUnwrap(ArticleStateRecord.fetchOne(db, key: "old"))
            XCTAssertTrue(state.isRead && state.isStarred)
        }
    }

    func testOlderCodableRecordsAndEntriesStillDecode() throws {
        let record = try JSONDecoder().decode(ArticleRecord.self, from: Data(#"{"item_id":"one","title":"Old","summary":"Summary","content_updated_at":1}"#.utf8))
        XCTAssertEqual(record.previewExtractionRevision, 0)
        XCTAssertNil(record.previewImageURL)
        let entry = Entry(id: "one", feedID: UUID(), title: "Old", isRead: true, isStarred: true)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(Entry.self, from: data)
        XCTAssertNil(decoded.previewImageURL)
        XCTAssertEqual(decoded, entry)
    }
}

extension FreshRSSIntegrationTests {
    func testArticlePreviewFromFreshRSSSummarySurvivesContentAndRefresh() async throws {
        let accountID = "preview-freshrss"
        let feedID = UUID().uuidString
        let endpoint = URL(string: "https://freshrss.example.com")!
        try inMemoryCredentialStore.saveFreshRSSPassword("test", accountID: accountID)
        try database.write { db in
            try AccountRecord(id: accountID, type: "freshRSS", displayName: "FreshRSS", endpointURL: endpoint.absoluteString, username: "test", createdAt: 1, updatedAt: 1).save(db)
            try FeedRecord(id: feedID, accountID: accountID, externalID: "feed/preview", title: "Feed", siteURL: "https://publisher.example", feedURL: "https://publisher.example/rss", updatedAt: 1).save(db)
        }
        let version = TestStateBox(1)
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let path = request.url!.path
            if path.contains("ClientLogin") { return (response, Data("Auth=test".utf8)) }
            if path.contains("stream/items/ids") { return (response, Data("{\"itemRefs\":[]}".utf8)) }
            if path.contains("stream/contents") {
                let json = """
                {"items":[{"id":"tag:google.com,2005:reader/item/0000000000000001","title":"Article","published":1700000000,
                "origin":{"streamId":"feed/preview"},"content":{"content":"<p>Unchanged full content</p>"},
                "summary":{"content":"<img src='/cover\(version.value).jpg'>"},
                "categories":["user/-/state/com.google/read","user/-/state/com.google/starred"]}]}
                """
                return (response, Data(json.utf8))
            }
            throw URLError(.badURL)
        }
        let provider = FreshRSSAccountProvider(accountID: accountID, endpointURL: endpoint, username: "test", database: database, credentialStore: inMemoryCredentialStore, session: mockSession)
        try await provider.syncArticlesAndStates()
        var items = try TimelineQueryService(database: database).fetchListItems(scope: .all)
        XCTAssertEqual(items.first?.previewImageURL?.absoluteString, "https://publisher.example/cover1.jpg")
        XCTAssertEqual(items.first?.accountID, accountID)
        XCTAssertEqual(items.first?.isRead, true)
        XCTAssertEqual(items.first?.isStarred, true)
        version.value = 2
        try await provider.syncArticlesAndStates()
        items = try TimelineQueryService(database: database).fetchListItems(scope: .all)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.previewImageURL?.path, "/cover2.jpg")
        XCTAssertEqual(items.first?.isRead, true)
        XCTAssertEqual(items.first?.isStarred, true)
    }
}
