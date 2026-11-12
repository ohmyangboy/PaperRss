import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudArticleMetadataTests: XCTestCase {
    private var directories: [URL] = []
    private let feedURL = "https://example.com/rss"

    private struct Peer {
        let database: LibraryDatabase
        let repository: ICloudRecordRepository
        let account: String
    }

    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    private func peer() throws -> Peer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudMetadata-\(UUID())")
        directories.append(directory)
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let account = UUID().uuidString
        try database.write { db in
            try AccountRecord(id: account, type: AccountType.iCloud.rawValue, displayName: "iCloud", createdAt: 1, updatedAt: 1).save(db)
        }
        let repository = ICloudRecordRepository(database: database, accountID: account)
        try repository.activate()
        return Peer(database: database, repository: repository, account: account)
    }

    @discardableResult
    private func article(_ peer: Peer, source: String = "opaque") throws -> String {
        try peer.database.write { db in
            let existing = try FeedRecord.filter(Column("account_id") == peer.account).fetchOne(db)
            let feed = existing?.id ?? UUID().uuidString
            if existing == nil { try FeedRecord(id: feed, accountID: peer.account, title: "Feed", feedURL: feedURL, updatedAt: 1).save(db) }
            let item = UUID().uuidString
            try ItemRecord(id: item, accountID: peer.account, externalID: item, feedID: feed, createdAt: 1, updatedAt: 1, sourceItemID: source).save(db)
            try ArticleRecord(itemID: item, title: "Title \(source)", author: "Author", url: "https://example.com/\(source)",
                publishedAt: 1, summary: "Private summary", contentHTML: "<p>Private body</p>").save(db)
            try ArticleStateRecord(itemID: item, dateArrived: 1, updatedAt: 1).save(db)
            return item
        }
    }

    private func receive(_ records: [ICloudPreparedRecord], on peer: Peer) throws {
        try peer.repository.receive(records.map { .init(envelope: $0.envelope, systemFields: nil, bodyData: $0.bodyData) })
    }

    @discardableResult
    private func send(_ peer: Peer, to other: Peer) throws -> [ICloudPreparedRecord] {
        let records = try peer.repository.outgoingRecords()
        try receive(records, on: other)
        for record in records {
            try peer.repository.confirm(record, server: .init(envelope: record.envelope, systemFields: nil, bodyData: record.bodyData))
        }
        return records
    }

    private func unread(_ peer: Peer) throws -> Int {
        try peer.database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM items i JOIN articles a ON a.item_id=i.id
                JOIN article_states s ON s.item_id=i.id JOIN feeds f ON f.id=i.feed_id
                WHERE i.account_id=? AND f.is_deleted=0 AND s.is_read=0
                """, arguments: [peer.account]) ?? 0
        }
    }

    func testUnread47And58ConvergeWithoutBodySyncOrRefetch() throws {
        let phone = try peer(), mac = try peer()
        for n in 0..<47 { try article(phone, source: "item-\(n)") }
        try send(phone, to: mac)
        XCTAssertEqual(try unread(mac), 47)
        for n in 47..<58 { try article(phone, source: "item-\(n)") }
        let records = try send(phone, to: mac)
        XCTAssertFalse(records.contains { $0.envelope.kind == .content })
        XCTAssertEqual(try unread(phone), 58)
        XCTAssertEqual(try unread(mac), 58)
        XCTAssertFalse(try mac.repository.syncUnreadContent())
        let articles = try mac.database.read { try ArticleRecord.fetchAll($0) }
        XCTAssertEqual(articles.count, 58)
        XCTAssertTrue(articles.allSatisfy { $0.contentHTML == nil && $0.summary.isEmpty && $0.url != nil })
        let json = String(decoding: try JSONEncoder().encode(records.map(\.envelope)), as: UTF8.self)
        XCTAssertFalse(json.contains("Private summary"))
        XCTAssertFalse(json.contains("Private body"))
        XCTAssertTrue(try mac.repository.outgoingRecords().isEmpty)
        let item = try XCTUnwrap(articles.first?.itemID)
        try mac.database.write { try ArticleStateRepository(database: mac.database).markRead(itemID: item, isRead: true, in: $0) }
        try send(mac, to: phone)
        XCTAssertEqual(try unread(phone), 57)
        XCTAssertEqual(try unread(mac), 57)
    }

    func testMetadataBeforeFeedSurvivesRestartAndRestoresOnParentPage() throws {
        let a = try peer(), b = try peer()
        try article(a)
        let records = try a.repository.outgoingRecords()
        try receive(records.filter { $0.envelope.zone == .articles }, on: b)
        XCTAssertEqual(try unread(b), 0)
        let reopened = ICloudRecordRepository(database: b.database, accountID: b.account)
        try reopened.activate()
        try receive(records.filter { $0.envelope.kind == .feed }, on: b)
        XCTAssertEqual(try unread(b), 1)
        try reopened.reconcileInbox()
        XCTAssertEqual(try unread(b), 1)
    }

    func testLegacyCacheBackfillKeepsStateVersionAndDoesNotRepeat() throws {
        let a = try peer(), b = try peer()
        try article(a)
        let sent = try send(a, to: b)
        let original = try XCTUnwrap(sent.first { $0.envelope.kind == .read })
        try a.database.write { db in
            try db.execute(sql: "UPDATE icloud_records SET envelope_json=json_remove(envelope_json,'$.articleMetadata') WHERE account_id=? AND record_name=?",
                arguments: [a.account, original.envelope.recordName])
        }
        try a.repository.activate()
        let upgraded = try send(a, to: b)
        let read = try XCTUnwrap(upgraded.first { $0.envelope.kind == .read })
        XCTAssertNotNil(read.envelope.articleMetadata)
        XCTAssertEqual(read.envelope.fields, original.envelope.fields)
        XCTAssertEqual(read.origins, original.origins)
        XCTAssertTrue(try a.repository.outgoingRecords().isEmpty)
        XCTAssertEqual(try unread(b), 1)
    }

    func testLegacyPeerCanReadEnvelopeAndNewerStatePreservesMetadata() throws {
        let a = try peer()
        try article(a)
        let envelope = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .read }?.envelope)
        struct LegacyEnvelope: Decodable { let kind: ICloudRecordKind; let fields: [String: ICloudVersionedField] }
        let encoded = try JSONEncoder().encode(envelope)
        XCTAssertEqual(try JSONDecoder().decode(LegacyEnvelope.self, from: encoded).fields, envelope.fields)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyJSON.removeValue(forKey: "articleMetadata")
        var newer = try JSONDecoder().decode(ICloudRecordEnvelope.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        newer.fields["value"] = .init(value: .flag(true), version: .init(counter: 100, deviceID: UUID().uuidString))
        try newer.validate()
        let merged = try envelope.merged(with: newer)
        XCTAssertEqual(merged.fields, newer.fields)
        XCTAssertEqual(merged.articleMetadata, envelope.articleMetadata)
        XCTAssertEqual(try newer.merged(with: envelope), merged)
    }

    func testUpgradeRefreshFindsAlreadyConsumedStateWithoutResettingCheckpoint() throws {
        let a = try peer(), b = try peer()
        try article(a)
        let records = try a.repository.outgoingRecords()
        let legacy = records.map { record -> ICloudReceivedRecord in
            var envelope = record.envelope
            envelope.articleMetadata = nil
            return .init(envelope: envelope, systemFields: nil, bodyData: record.bodyData)
        }
        try b.repository.receive(legacy, checkpoint: Data([7, 8]))
        XCTAssertEqual(try unread(b), 0)
        let unresolved = try b.repository.unresolvedArticleMetadata(excluding: [])
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertTrue(try b.repository.unresolvedArticleMetadata(excluding: Set(unresolved.map(\.recordName))).isEmpty)
        let names = Set(unresolved.map(\.recordName))
        try receive(records.filter { names.contains($0.envelope.recordName) }, on: b)
        XCTAssertEqual(try unread(b), 1)
        XCTAssertEqual(try b.repository.engineState(), Data([7, 8]))
        XCTAssertTrue(try b.repository.unresolvedArticleMetadata(excluding: []).isEmpty)
    }

    func testOlderUnreadMetadataCannotOverwritePendingReadOrLocalBody() throws {
        let a = try peer(), b = try peer()
        try article(a)
        let item = try article(b)
        try b.database.write { try ArticleStateRepository(database: b.database).markRead(itemID: item, isRead: true, in: $0) }
        try receive(a.repository.outgoingRecords(), on: b)
        XCTAssertEqual(try unread(b), 0)
        let local = try b.database.read { try XCTUnwrap(ArticleRecord.fetchOne($0, key: item)) }
        XCTAssertEqual(local.summary, "Private summary")
        XCTAssertEqual(local.contentHTML, "<p>Private body</p>")
        XCTAssertEqual(try b.repository.outgoingRecords().first { $0.envelope.kind == .read }?.envelope.fields["value"]?.value, .flag(true))
    }

    func testDeletedFeedAndReadUnstarredMetadataDoNotRestoreArticles() throws {
        let a = try peer(), b = try peer(), c = try peer()
        let item = try article(a)
        let records = try a.repository.outgoingRecords()
        try receive(records.filter { $0.envelope.kind == .feed }, on: b)
        try b.database.write { try $0.execute(sql: "UPDATE feeds SET is_deleted=1 WHERE account_id=?", arguments: [b.account]) }
        try receive(records.filter { $0.envelope.zone == .articles }, on: b)
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items") }, 0)
        try a.database.write { try ArticleStateRepository(database: a.database).markRead(itemID: item, isRead: true, in: $0) }
        try send(a, to: c)
        XCTAssertEqual(try c.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items") }, 0)
    }

    func testEnablingBodySyncLaterFillsMetadataOnlyArticle() throws {
        let a = try peer(), b = try peer()
        try article(a)
        try send(a, to: b)
        try a.repository.setSyncUnreadContent(true)
        try send(a, to: b)
        let article = try b.database.read { try XCTUnwrap(ArticleRecord.fetchOne($0)) }
        XCTAssertEqual(article.summary, "Private summary")
        XCTAssertEqual(article.contentHTML, "<p>Private body</p>")
        XCTAssertEqual(try unread(b), 1)
    }

    func testRetiredMetadataCannotRestoreRowsOrRebaseAcknowledgedIntent() async throws {
        let a = try peer(), b = try peer()
        let generation = UUID().uuidString
        for peer in [a, b] {
            try await peer.repository.acceptCloudRoot(.init(generation: generation, phase: .ready, protocolVersion: 3))
        }
        try article(a)
        let records = try a.repository.outgoingRecords()
        let read = try XCTUnwrap(records.first { $0.envelope.kind == .read })
        let fence = try ICloudRetentionFence(generation: generation, article: read.envelope).retiring([read.envelope]).envelope()
        try receive(records.filter { $0.envelope.kind == .feed }, on: b)
        try b.repository.receive([.init(envelope: fence, systemFields: nil)])
        try receive([read], on: b)
        XCTAssertEqual(try unread(b), 0)
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items") }, 0)
        for record in records {
            try a.repository.confirm(record, server: .init(envelope: record.envelope, systemFields: nil, bodyData: record.bodyData))
        }
        try a.database.write { try $0.execute(sql: "UPDATE icloud_records SET envelope_json=json_remove(envelope_json,'$.articleMetadata')") }
        try a.repository.receive([.init(envelope: fence, systemFields: nil)])
        let clock = try a.database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }
        XCTAssertFalse(try a.repository.outgoingRecords().contains { $0.envelope.kind == .read })
        XCTAssertEqual(try a.database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }, clock)
    }

    func testMetadataIsBoundedAndMergeConvergesWithoutChangingReadVersion() throws {
        let a = try peer()
        let item = try article(a)
        let large = String(repeating: "👨‍👩‍👧‍👦", count: 5000)
        try a.database.write { try $0.execute(sql: "UPDATE articles SET title=?,author=? WHERE item_id=?", arguments: [large, large, item]) }
        var first = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .read }?.envelope)
        try first.validate()
        XCTAssertLessThanOrEqual(first.articleMetadata!.title.utf8.count, 8192)
        XCTAssertLessThanOrEqual(first.articleMetadata!.author!.utf8.count, 2048)
        var second = first
        second.articleMetadata = ICloudArticleMetadata(ArticleRecord(itemID: "other", title: "Other RSS snapshot"))
        XCTAssertEqual(try first.merged(with: second), try second.merged(with: first))
        XCTAssertEqual(try first.merged(with: second).fields, first.fields)
        first = try .init(kind: .starred, recordName: first.recordName.replacingOccurrences(of: "read-v1:", with: "starred-v1:"),
            feedURL: first.feedURL, sourceItemID: first.sourceItemID, fields: first.fields)
        first.articleMetadata = second.articleMetadata
        XCTAssertThrowsError(try first.validate())
    }
}
