@preconcurrency import CloudKit
import Compression
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudContentTests: XCTestCase {
    private var directories: [URL] = []
    private let url = "https://example.com/rss"
    private let source = "urn:article:opaque"
    private struct Peer {
        let database: LibraryDatabase
        let repository: ICloudRecordRepository
        let account: String
    }
    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }
    private func peer() throws -> Peer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudContentTests-\(UUID())")
        directories.append(directory)
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let account = UUID().uuidString
        try database.write { try AccountRecord(id: account, type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0) }
        let repository = ICloudRecordRepository(database: database, accountID: account)
        try repository.activate()
        return Peer(database: database, repository: repository, account: account)
    }
    private func article(_ peer: Peer, sourceID: String? = "urn:article:opaque", body: String = "<p>Original RSS</p>", read: Bool = false, star: Bool = false, feedURL: String = "https://example.com/rss") throws -> String {
        try peer.database.write { db in
            let existing = try FeedRecord.filter(Column("account_id") == peer.account && Column("feed_url") == feedURL).fetchOne(db)
            let feedID = existing?.id ?? UUID().uuidString
            if existing == nil { try FeedRecord(id: feedID, accountID: peer.account, title: "Feed", feedURL: feedURL, updatedAt: 1).save(db) }
            let item = UUID().uuidString
            try ItemRecord(id: item, accountID: peer.account, externalID: item, feedID: feedID, createdAt: 1, updatedAt: 1, sourceItemID: sourceID).save(db)
            try ArticleRecord(itemID: item, title: "Original title", author: "Author", url: "https://example.com/article", publishedAt: 1, summary: "RSS summary", contentHTML: body).save(db)
            try ArticleStateRecord(itemID: item, isRead: read, isStarred: star, dateArrived: 1, updatedAt: 1).save(db)
            return item
        }
    }
    private func received(_ values: [ICloudPreparedRecord]) -> [ICloudReceivedRecord] {
        values.map { .init(envelope: $0.envelope, systemFields: nil, bodyData: $0.bodyData) }
    }
    private func send(_ peer: Peer, to other: Peer? = nil) throws -> [ICloudPreparedRecord] {
        let pending = try peer.repository.outgoingRecords()
        if let other { try other.repository.receive(received(pending)) }
        for (value, receipt) in zip(pending, received(pending)) { try peer.repository.confirm(value, server: receipt) }
        return pending
    }
    private func body(_ peer: Peer) throws -> ICloudPreparedRecord {
        try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .content })
    }
    private func mark(_ peer: Peer, item: String, read: Bool? = nil, star: Bool? = nil) throws {
        try peer.database.write { db in
            let states = ArticleStateRepository(database: peer.database)
            if let read { try states.markRead(itemID: item, isRead: read, in: db) }
            if let star { try states.markStarred(itemID: item, isStarred: star, in: db) }
        }
    }

    func testDefaultOffAndStarsAlwaysSendOriginalRSSWithoutDerivedFields() throws {
        let a = try peer()
        let item = try article(a)
        XCTAssertFalse(try a.repository.syncUnreadContent())
        XCTAssertFalse(try a.repository.outgoingRecords().contains { $0.envelope.kind == .content })
        try a.database.write { db in
            try db.execute(sql: "UPDATE articles SET preview_image_url = 'https://private.example/preview', preview_input_hash = 'private-preview' WHERE item_id = ?", arguments: [item])
            try ArticleCacheRecord(itemID: item, text: "private-extracted-body", html: "<p>private-cache</p>", fetchedAt: 1).save(db)
        }
        try mark(a, item: item, read: true, star: true)
        let content = try body(a)
        let data = try XCTUnwrap(content.bodyData)
        guard case .text(let hash) = content.envelope.fields["payload_hash"]?.value else { return XCTFail() }
        let decoded = try ICloudArticleContentCodec.decode(data, expectedHash: hash)
        XCTAssertEqual(decoded.contentHTML, "<p>Original RSS</p>")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("private-"))
        XCTAssertEqual(content.envelope.fields.keys.sorted(), ["payload_hash"])
    }

    func testCanceledEngineContentCanBeRemovedButNewEligibilityRetainsItsPendingSave() throws {
        let a = try peer()
        let item = try article(a)
        try a.repository.setSyncUnreadContent(true)
        let prepared = try a.repository.outgoingRecords()
        let content = try XCTUnwrap(prepared.first { $0.envelope.kind == .content })
        try a.repository.setSyncUnreadContent(false)
        _ = try a.repository.outgoingRecords()
        let names = Set(prepared.map { $0.envelope.recordName })
        XCTAssertEqual(try a.repository.inactivePreparedRecordNames(names), [content.envelope.recordName])
        try mark(a, item: item, star: true)
        XCTAssertFalse(try a.repository.inactivePreparedRecordNames(names).contains(content.envelope.recordName))
        XCTAssertTrue(try a.repository.outgoingRecords().contains { $0.envelope.recordName == content.envelope.recordName })
    }

    func testAcknowledgedRecordWithANewUnpreparedIntentRemainsInEngineQueue() throws {
        let a = try peer()
        let item = try article(a)
        let confirmed = try send(a)
        let read = try XCTUnwrap(confirmed.first { $0.envelope.kind == .read })
        XCTAssertTrue(try a.repository.inactivePreparedRecordNames([read.envelope.recordName]).contains(read.envelope.recordName))
        try mark(a, item: item, read: true)
        XCTAssertFalse(try a.repository.inactivePreparedRecordNames([read.envelope.recordName]).contains(read.envelope.recordName))
        let pending = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.recordName == read.envelope.recordName })
        XCTAssertEqual(pending.envelope.fields["value"]?.value, .flag(true))
    }

    func testStarredBodyRestoresWithoutRSSAndLaterRSSUsesSameLocalIdentity() throws {
        let a = try peer(), b = try peer()
        _ = try article(a, read: true, star: true)
        _ = try send(a, to: b)
        let restored = try b.database.read { try XCTUnwrap(ItemRecord.fetchOne($0, sql: "SELECT * FROM items")) }
        let state = try b.database.read { try XCTUnwrap(ArticleStateRecord.fetchOne($0, key: restored.id)) }
        XCTAssertTrue(state.isStarred)
        XCTAssertTrue(state.isRead)
        XCTAssertEqual(restored.sourceItemID, source)
        try b.database.write { db in
            _ = try ArticleRepository(database: b.database).mergeParsedEntries(accountID: b.account, feedID: restored.feedID,
                parsedEntries: [.init(id: source, title: "Fresh RSS", author: nil, url: nil, publishedAt: nil, summary: "Fresh", contentHTML: "<p>Fresh</p>")], in: db)
        }
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 1)
        XCTAssertTrue(try b.database.read { try ArticleStateRecord.fetchOne($0, key: restored.id)?.isStarred } == true)
    }

    func testBodyBeforeParentsAndStatesSurvivesRestartAndThenRestores() throws {
        let a = try peer(), b = try peer()
        _ = try article(a, star: true)
        let outgoing = try a.repository.outgoingRecords()
        let content = try XCTUnwrap(outgoing.first { $0.envelope.kind == .content })
        try b.repository.receive(received([content]))
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
        let reopened = try LibraryDatabase(databaseURL: URL(fileURLWithPath: b.database.databasePath))
        let repository = ICloudRecordRepository(database: reopened, accountID: b.account)
        try repository.receive(received(outgoing.filter { $0.envelope.kind == .feed }))
        XCTAssertEqual(try reopened.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
        try repository.receive(received(outgoing.filter { $0.envelope.kind == .read || $0.envelope.kind == .starred }))
        XCTAssertEqual(try reopened.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 1)
        XCTAssertEqual(try reopened.read { try Bool.fetchOne($0, sql: "SELECT is_starred FROM article_states") }, true)
    }

    func testUnreadOptionSynchronizesAndFreshDeviceBootstrapCannotDisableIt() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        try a.repository.setSyncUnreadContent(true)
        let sent = try send(a, to: b)
        XCTAssertTrue(try b.repository.syncUnreadContent())
        XCTAssertTrue(sent.contains { $0.envelope.kind == .content })
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 1)
        _ = try send(b, to: a)
        XCTAssertTrue(try a.repository.syncUnreadContent())
        try b.repository.setSyncUnreadContent(false)
        _ = try send(b, to: a)
        XCTAssertFalse(try a.repository.syncUnreadContent())
        XCTAssertEqual(try a.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM articles") }, 1)
    }

    func testReadingUnreadCancelsUnsentBodyButAStarStillKeepsIt() throws {
        let a = try peer()
        let item = try article(a)
        try a.repository.setSyncUnreadContent(true)
        _ = try body(a)
        try mark(a, item: item, read: true)
        XCTAssertFalse(try a.repository.outgoingRecords().contains { $0.envelope.kind == .content })
        XCTAssertTrue(try a.repository.outgoingRecords().contains { $0.envelope.kind == .read })
        try mark(a, item: item, star: true)
        XCTAssertNotNil(try body(a).bodyData)
        try a.repository.setSyncUnreadContent(false)
        XCTAssertNotNil(try body(a).bodyData)
    }

    func testLateBodyReceiptDoesNotClearNewRevisionOrOverwriteFreshRSS() throws {
        let a = try peer()
        let item = try article(a, star: true)
        let old = try body(a)
        try a.database.write { try $0.execute(sql: "UPDATE articles SET content_html = '<p>New RSS</p>' WHERE item_id = ?", arguments: [item]) }
        try a.repository.confirm(old, server: received([old])[0])
        let newer = try body(a)
        XCTAssertGreaterThan(newer.envelope.fields["payload_hash"]!.version, old.envelope.fields["payload_hash"]!.version)
        XCTAssertEqual(try a.database.read { try ArticleRecord.fetchOne($0, key: item)?.contentHTML }, "<p>New RSS</p>")
        try a.repository.confirm(newer, server: received([newer])[0])
        XCTAssertFalse(try a.repository.outgoingRecords().contains { $0.envelope.kind == .content })
    }

    func testReadOnlyChangeDoesNotSerializeOrRequeueAnExistingStarredBody() throws {
        let a = try peer()
        let item = try article(a, star: true)
        _ = try send(a)
        let revision = try a.database.read { try Int64.fetchOne($0, sql: "SELECT revision FROM icloud_content_changes WHERE item_id = ?", arguments: [item]) }
        try mark(a, item: item, read: true)
        XCTAssertFalse(try a.repository.outgoingRecords().contains { $0.envelope.kind == .content })
        XCTAssertEqual(try a.database.read { try Int64.fetchOne($0, sql: "SELECT revision FROM icloud_content_changes WHERE item_id = ?", arguments: [item]) }, revision)
    }

    func testUnknownGUIDAndOversizedBodyDoNotBlockStatusOrOtherBodies() throws {
        let a = try peer()
        _ = try article(a, sourceID: nil, star: true)
        _ = try article(a, sourceID: "oversized", body: String(repeating: "x", count: ICloudArticleContentCodec.maximumExpandedBytes + 1), star: true)
        _ = try article(a, sourceID: "valid", star: true)
        let outgoing = try a.repository.outgoingRecords()
        XCTAssertEqual(outgoing.filter { $0.envelope.kind == .content }.map(\.envelope.sourceItemID), ["valid"])
        XCTAssertTrue(outgoing.contains { $0.envelope.kind == .starred && $0.envelope.sourceItemID == "oversized" })
        XCTAssertEqual(try a.repository.deferredContentCount(), 1)
    }

    func testCorruptBodyPageDoesNotAdvanceCheckpointOrPartiallyRestore() throws {
        let a = try peer(), b = try peer()
        _ = try article(a, star: true)
        var records = received(try a.repository.outgoingRecords())
        let index = try XCTUnwrap(records.firstIndex { $0.envelope.kind == .content })
        records[index].bodyData = Data([1, 2, 3])
        try b.repository.persistEngineState(Data([1]))
        XCTAssertThrowsError(try b.repository.receive(records, checkpoint: Data([2])))
        XCTAssertEqual(try b.repository.engineState(), Data([1]))
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 0)
    }

    func testDeletedFeedAndRetainedIneligibleBodyCannotRestoreContentOrUnreadState() throws {
        let a = try peer(), b = try peer()
        let item = try article(a, read: true, star: true)
        let old = try a.repository.outgoingRecords()
        let content = try XCTUnwrap(old.first { $0.envelope.kind == .content })
        _ = try send(a)
        try mark(a, item: item, star: false)
        let newer = try a.repository.outgoingRecords()
        try b.repository.receive(received(old.filter { $0.envelope.kind != .content }))
        try b.repository.receive(received(newer))
        try b.repository.receive(received([content]))
        // The state snapshot now carries the minimal article row. An old body
        // still cannot restore content or turn a read, unstarred row unread.
        let restored = try b.database.read { try XCTUnwrap(ArticleRecord.fetchOne($0)) }
        XCTAssertNil(restored.contentHTML)
        XCTAssertTrue(restored.summary.isEmpty)
        let restoredState = try b.database.read { try XCTUnwrap(ArticleStateRecord.fetchOne($0, key: restored.itemID)) }
        XCTAssertTrue(restoredState.isRead)
        XCTAssertFalse(restoredState.isStarred)
        try a.database.write { _ = try FeedRecord.filter(Column("account_id") == a.account).deleteAll($0) }
        try b.repository.receive(received(try a.repository.outgoingRecords()))
        try b.repository.receive(received(old))
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 0)
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
    }

    func testAssetLeaseRoundTripAndLifetimeWithIncompressibleBody() throws {
        let a = try peer()
        var generator = SeededGenerator()
        let bytes = (0..<180_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        _ = try article(a, body: Data(bytes).base64EncodedString(), star: true)
        let content = try body(a)
        let data = try XCTUnwrap(content.bodyData)
        XCTAssertGreaterThan(data.count, ICloudArticleContentCodec.inlineBytes)
        var lease: ICloudAssetLease? = try ICloudAssetLease(data: data)
        let file = try XCTUnwrap(lease?.fileURL)
        let record = try ICloudRecordCodec.encode(content.envelope, systemFields: nil, bodyData: data, assetURL: file)
        XCTAssertNil(record["content"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try ICloudRecordCodec.received(record).bodyData, data)
        lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInlineContentRoundTripAndWrongHashAreRejected() throws {
        let a = try peer()
        _ = try article(a, star: true)
        let content = try body(a)
        let data = try XCTUnwrap(content.bodyData)
        let record = try ICloudRecordCodec.encode(content.envelope, systemFields: nil, bodyData: data)
        XCTAssertNotNil(record["content"])
        XCTAssertNil(record["contentAsset"])
        XCTAssertEqual(try ICloudRecordCodec.received(record).bodyData, data)
        record["content"] = Data([0]) as NSData
        XCTAssertThrowsError(try ICloudRecordCodec.received(record))
    }

    func testPhysicallyExpiredStarredContentRequeuesWithoutChangingReaderState() throws {
        let a = try peer()
        let item = try article(a, read: true, star: true)
        let sent = try send(a)
        let content = try XCTUnwrap(sent.first { $0.envelope.kind == .content })
        try a.repository.discardServerMetadata(recordName: content.envelope.recordName, zone: .articles)
        XCTAssertNil(try body(a).systemFields)
        XCTAssertEqual(try body(a).bodyData, content.bodyData)
        XCTAssertTrue(try a.database.read { try ArticleStateRecord.fetchOne($0, key: item)?.isRead } == true)
        XCTAssertTrue(try a.database.read { try ArticleStateRecord.fetchOne($0, key: item)?.isStarred } == true)
    }

    func testV15UpgradePreservesExistingDataAndDoesNotActivateLocalOrUploadBodies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudContentV15-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v15-icloud-record-protocol")
        let feed = UUID().uuidString
        try pool.write { db in
            try AccountRecord(id: "existing", type: "local", displayName: "Existing", createdAt: 1, updatedAt: 1).save(db)
            try FeedRecord(id: feed, accountID: "existing", title: "Existing", feedURL: url, updatedAt: 1).save(db)
            try ItemRecord(id: "old", accountID: "existing", externalID: "old", feedID: feed, createdAt: 1, updatedAt: 1, sourceItemID: source).save(db)
            try ArticleRecord(itemID: "old", title: "History", contentHTML: "<p>Keep</p>").save(db)
            try ArticleStateRecord(itemID: "old", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertEqual(try ItemRecord.fetchOne(db, key: "old")?.sourceItemID, source)
            XCTAssertEqual(try ArticleRecord.fetchOne(db, key: "old")?.contentHTML, "<p>Keep</p>")
            XCTAssertTrue(try ArticleStateRecord.fetchOne(db, key: "old")?.isStarred == true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_content_changes"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_scope"), 0)
        }
    }

    func testStructureAndUserStateArePrioritizedOverLargeContentQueue() throws {
        let a = try peer()
        _ = try article(a, star: true)
        let first = try a.repository.outgoingRecords(limit: 1)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.envelope.zone, .library)
        _ = try send(a)
        let item = try article(a, sourceID: "second", star: true)
        try mark(a, item: item, read: true)
        let next = try a.repository.outgoingRecords(limit: 1)
        XCTAssertTrue(next.first?.envelope.kind == .read || next.first?.envelope.kind == .starred)
    }

    func testExpandedCompressionBombAndUnknownPrivateFieldsAreRejected() throws {
        func fixture(_ source: Data) throws -> Data {
            var output = Data(count: source.count + 1024)
            let capacity = output.count
            let count = output.withUnsafeMutableBytes { destination in
                source.withUnsafeBytes { input in
                    compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        input.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
                }
            }
            XCTAssertGreaterThan(count, 0)
            output.count = count
            return output
        }
        let bomb = try fixture(Data(repeating: 120, count: ICloudArticleContentCodec.maximumExpandedBytes + 1))
        XCTAssertThrowsError(try ICloudArticleContentCodec.decode(bomb, expectedHash: ICloudArticleContentCodec.hash(bomb)))
        let privateField = try fixture(Data(#"{"title":"Title","summary":"","api_key":"not-an-allowed-field"}"#.utf8))
        XCTAssertThrowsError(try ICloudArticleContentCodec.decode(privateField, expectedHash: ICloudArticleContentCodec.hash(privateField)))
    }

    func testCanonicalFeedIdentityProtectsUnpreparedLocalBodyDuringConflict() throws {
        let a = try peer(), b = try peer()
        let itemA = try article(a, star: true, feedURL: "HTTPS://EXAMPLE.COM:443/rss#fragment")
        let old = try body(a)
        _ = try article(b, star: true)
        try b.repository.receive(received([old]))
        try a.database.write { try $0.execute(sql: "UPDATE articles SET content_html = '<p>New local RSS</p>' WHERE item_id = ?", arguments: [itemA]) }
        try a.repository.receive(received([old]))
        XCTAssertEqual(try a.database.read { try ArticleRecord.fetchOne($0, key: itemA)?.contentHTML }, "<p>New local RSS</p>")
        XCTAssertGreaterThan(try body(a).envelope.fields["payload_hash"]!.version, old.envelope.fields["payload_hash"]!.version)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var value: UInt64 = 0x1234_5678_9abc_def0
    mutating func next() -> UInt64 {
        value ^= value << 13; value ^= value >> 7; value ^= value << 17
        return value
    }
}
