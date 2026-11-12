import Foundation
import GRDB

struct ICloudRecordOrigin: Codable, Sendable, Equatable {
    let kind: ICloudRecordKind
    let entityID: String
    let revision: Int64
}

struct ICloudPreparedRecord: Sendable, Equatable {
    let envelope: ICloudRecordEnvelope
    let systemFields: Data?
    let origins: [ICloudRecordOrigin]
    let isPending: Bool
    var bodyData: Data? = nil
    var isConfirmed: Bool = false
}

struct ICloudReceivedRecord: Sendable {
    let envelope: ICloudRecordEnvelope
    let systemFields: Data?
    var bodyData: Data? = nil
}

/// Durable wire cache also serves as the inbox for states/relationships whose
/// local parents have not arrived. Incoming pages and checkpoints are atomic.
final class ICloudRecordRepository: Sendable {
    let database: LibraryDatabase
    let accountID: String

    init(database: LibraryDatabase, accountID: String) {
        self.database = database
        self.accountID = accountID
    }

    func activate() throws {
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT type FROM accounts WHERE id = ?", arguments: [accountID]) == AccountType.iCloud.rawValue
            else { throw ICloudSyncRepositoryError.unsupportedAccount }
            try db.execute(sql: """
                INSERT INTO icloud_sync_scope (account_id, capture_enabled) VALUES (?, 1)
                ON CONFLICT(account_id) DO UPDATE SET capture_enabled = 1;
                """, arguments: [accountID])
            try ICloudRecordSchema.ensureDeviceIdentity(accountID: accountID, in: db)
            try ICloudSyncSchema.captureBaseline(accountID: accountID, in: db)
            try ICloudContentSchema.captureEligible(accountID: accountID, in: db)
            try prepareArticleMetadata(limit: 150, in: db)
        }
    }

    func bindSystemUserFingerprint(_ fingerprint: String) throws {
        guard !fingerprint.isEmpty else { throw ICloudRecordError.accountChanged }
        let accepted = try database.write { db -> Bool in
            try requireScope(in: db, permitsPause: true)
            let previous = try String.fetchOne(db, sql: "SELECT user_fingerprint FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID])
            if let previous, previous != fingerprint {
                try db.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = 'accountChanged' WHERE account_id = ?", arguments: [accountID])
                return false
            }
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET user_fingerprint = ?
                WHERE account_id = ?;
                """, arguments: [fingerprint, accountID])
            return true
        }
        guard accepted else { throw ICloudRecordError.accountChanged }
    }

    func pause(reason: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = ? WHERE account_id = ?", arguments: [reason, accountID])
        }
    }

    func engineState() throws -> Data? {
        try database.read { db in
            try requireScope(in: db)
            return try Data.fetchOne(db, sql: "SELECT engine_state FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID])
        }
    }

    func persistEngineState(_ data: Data) throws {
        try database.write { db in
            try requireScope(in: db)
            try db.execute(sql: "UPDATE icloud_sync_scope SET engine_state = ? WHERE account_id = ?", arguments: [data, accountID])
        }
    }

    func missingZones() throws -> [ICloudRecordZone] {
        try database.read { db in
            try requireScope(in: db)
            let mask = try Int.fetchOne(db, sql: "SELECT initialized_zones FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]) ?? 0
            return ICloudRecordZone.allCases.filter { mask & ($0 == .library ? 1 : 2) == 0 }
        }
    }

    func markZoneInitialized(_ zone: ICloudRecordZone) throws {
        try database.write { db in
            try requireScope(in: db)
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET initialized_zones = initialized_zones | ?
                WHERE account_id = ?;
                """, arguments: [zone == .library ? 1 : 2, accountID])
        }
    }

    func outgoingRecords(limit: Int = 150, recordNames: Set<String>? = nil) throws -> [ICloudPreparedRecord] {
        guard limit > 0 else { return [] }
        if recordNames?.isEmpty == true { return [] }
        try prepareContentRecords(limit: limit, recordNames: recordNames)
        return try database.write { db in
            try requireScope(in: db)
            // A missing historical source ID remains local and cannot starve
            // later portable changes in the queue.
            let changes = try Row.fetchAll(db, sql: """
                SELECT * FROM icloud_sync_changes
                WHERE account_id = ? AND is_pending = 1
                  AND (kind NOT IN ('read', 'starred') OR length(trim(json_extract(payload_json, '$.source_item_id'))) > 0)
                ORDER BY changed_at, kind, entity_id LIMIT ?;
                """, arguments: [accountID, limit])
            for change in changes { try prepare(change, in: db) }
            try prepareArticleMetadata(limit: limit, in: db)
            try prepareSettings(in: db)
            try prepareRetentionUnreadPolicy(in: db)
            let scope: String
            var arguments: StatementArguments = [accountID]
            if let recordNames {
                let names = recordNames.sorted()
                scope = "AND record_name IN (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))"
                arguments += StatementArguments(names)
            } else { scope = "" }
            arguments += [limit]
            return try Row.fetchAll(db, sql: """
                SELECT * FROM icloud_records WHERE account_id = ? AND is_pending = 1
                \(scope)
                ORDER BY CASE json_extract(envelope_json, '$.kind')
                    WHEN 'content' THEN 2 WHEN 'read' THEN 1 WHEN 'starred' THEN 1 ELSE 0 END,
                    zone, record_name LIMIT ?;
                """, arguments: arguments).map(prepared)
        }
    }

    func receive(_ records: [ICloudReceivedRecord], checkpoint: Data? = nil) throws {
        for record in records {
            try record.envelope.validate()
            try validateBody(record.envelope, data: record.bodyData)
        }
        if records.contains(where: { $0.envelope.kind == .retention || $0.envelope.kind == .retentionPolicy || $0.envelope.kind == .retentionQuota }) {
            let compatible = try database.read { db in
                try requireScope(in: db)
                return try usesRetentionProtocol(in: db)
            }
            if !compatible {
                try pause(reason: "invalidCloudRoot")
                throw ICloudRetentionError.unsupportedProtocol
            }
        }
        try prepareContentRecords(limit: 150, incoming: records.map(\.envelope))
        try remoteTransaction(checkpoint: checkpoint) { db in
            let maximum = records.flatMap { $0.envelope.fields.values.map(\.version.counter) }.max() ?? 0
            try db.execute(sql: "UPDATE icloud_sync_scope SET logical_clock = MAX(logical_clock, ?) WHERE account_id = ?",
                           arguments: [maximum, accountID])
            // All fences in a page precede states and bodies, independent of
            // query order. Earlier pages without a fence remain in the inbox.
            let ordered = records.filter { $0.envelope.kind == .retention } + records.filter { $0.envelope.kind != .retention }
            var affectedNames = Set(records.map(\.envelope.recordName))
            for received in ordered {
                try received.envelope.validate()
                try preparePendingLocal(for: received.envelope, in: db)
                let existing = try cached(received.envelope.recordName, zone: received.envelope.zone, in: db)
                let merged = try existing?.envelope.merged(with: received.envelope) ?? received.envelope
                let origins = existing?.origins ?? []
                let retired = try retentionSuppresses(merged, in: db)
                let pending = merged != received.envelope && !retired && merged.kind != .retentionQuota
                try save(merged, systemFields: received.systemFields, origins: origins, pending: pending,
                         bodyData: merged.kind == .content ? (merged.fields["payload_hash"] == received.envelope.fields["payload_hash"] ? received.bodyData : existing?.bodyData) : nil,
                         confirmed: !pending, in: db)
                if !pending && !retired { try acknowledge(origins, in: db) }
                let maximum = merged.fields.values.map(\.version.counter).max() ?? 0
                try db.execute(sql: """
                    UPDATE icloud_sync_scope SET logical_clock = MAX(logical_clock, ?)
                    WHERE account_id = ?;
                    """, arguments: [maximum, accountID])
                if merged.kind == .retention {
                    try reconcileRetentionFence(merged, in: db)
                    let suffix = merged.recordName.dropFirst("retention-v1:".count)
                    for kind in [ICloudRecordKind.read, .starred, .content] {
                        affectedNames.insert("\(kind.rawValue)-v1:" + suffix)
                    }
                }
            }
            try reconcileCachedRecords(in: db, recordNames: affectedNames,
                includesRelationships: records.contains { $0.envelope.kind == .feed || $0.envelope.kind == .folder })
            try prepareRetentionUnreadPolicy(in: db)
            try ICloudContentSchema.captureEligible(accountID: accountID, in: db)
        }
    }

    /// A CKSyncEngine save can outlive its upload eligibility (for example,
    /// turning off unread bodies). Remove only known inactive cache rows,
    /// retaining mapped local edits that have not reached the preparation page.
    func inactivePreparedRecordNames(_ names: Set<String>) throws -> Set<String> {
        guard !names.isEmpty else { return [] }
        let encoded = String(decoding: try JSONEncoder().encode(names.sorted()), as: UTF8.self)
        return try database.read { db in
            try requireScope(in: db)
            var inactive = Set(try String.fetchAll(db, sql: """
                SELECT r.record_name FROM icloud_records r JOIN json_each(?) n ON n.value = r.record_name
                WHERE r.account_id = ? AND r.is_pending = 0
                  AND NOT EXISTS (
                    SELECT 1 FROM icloud_record_mappings m JOIN icloud_sync_changes c
                        ON c.account_id = m.account_id AND c.kind = m.kind AND c.entity_id = m.entity_id
                    WHERE m.account_id = r.account_id AND m.record_name = r.record_name AND c.is_pending = 1)
                  AND NOT EXISTS (
                    SELECT 1 FROM icloud_record_mappings m JOIN icloud_content_changes c
                        ON c.account_id = m.account_id AND c.item_id = m.entity_id
                    JOIN items i ON i.id = c.item_id JOIN article_states st ON st.item_id = i.id
                    JOIN feeds f ON f.id = i.feed_id JOIN icloud_sync_scope s ON s.account_id = c.account_id
                    WHERE m.account_id = r.account_id AND m.kind = 'content' AND m.record_name = r.record_name
                      AND c.is_pending = 1 AND c.deferred_reason IS NULL AND f.is_deleted = 0
                      AND (st.is_starred = 1 OR (st.is_read = 0 AND s.sync_unread_content = 1)))
                  AND NOT (r.record_name = 'settings-v1:library' AND EXISTS (
                    SELECT 1 FROM icloud_sync_scope s WHERE s.account_id = r.account_id AND s.settings_pending = 1));
                """, arguments: [encoded, accountID]))
            if try usesRetentionProtocol(in: db) {
                for name in names where name.hasPrefix("retention-v1:") {
                    if try isPendingRetentionGuard(name, in: db) { inactive.remove(name) }
                    else { inactive.insert(name) }
                }
            }
            return inactive
        }
    }

    /// Confirm the immutable batch that was sent. A newer local revision stays
    /// pending even when an older server response arrives after another edit.
    func confirm(_ sent: ICloudPreparedRecord, server: ICloudReceivedRecord) throws {
        guard sent.envelope.recordName == server.envelope.recordName,
              sent.envelope == server.envelope else { throw ICloudRecordError.identityMismatch }
        try validateBody(server.envelope, data: server.bodyData)
        try prepareContentRecords(limit: 150, incoming: [sent.envelope])
        try remoteTransaction { db in
            try preparePendingLocal(for: sent.envelope, in: db)
            let latest = try cached(sent.envelope.recordName, zone: sent.envelope.zone, in: db) ?? sent
            let merged = try latest.envelope.merged(with: server.envelope)
            // A rebase preserves journal revision. A late receipt below its
            // retirement floor must not acknowledge that freshly rebased intent.
            if try !retentionSuppresses(sent.envelope, in: db) { try acknowledge(sent.origins, in: db) }
            let retired = try retentionSuppresses(merged, in: db)
            try save(merged, systemFields: server.systemFields, origins: latest.origins,
                     pending: merged != server.envelope && !retired && merged.kind != .retentionQuota,
                     bodyData: merged.kind == .content ? (merged.fields["payload_hash"] == server.envelope.fields["payload_hash"] ? server.bodyData : latest.bodyData) : nil,
                     confirmed: merged == server.envelope, in: db)
            if merged.kind == .retention { try reconcileRetentionFence(merged, in: db) }
            if merged.kind == .content {
                try db.execute(sql: "UPDATE icloud_records SET needs_apply = 0 WHERE account_id = ? AND zone = ? AND record_name = ?",
                               arguments: [accountID, merged.zone.rawValue, merged.recordName])
            } else { try applyCachedRecord(merged, in: db) }
            try prepareRetentionUnreadPolicy(in: db)
        }
    }

    /// Called after RSS materialization; replaying this inbox is idempotent and
    /// restores eligible RSS content without changing a captured reader intent.
    func reconcileInbox() throws {
        try prepareContentRecords(limit: 150)
        try remoteTransaction { db in
            try reconcileCachedRecords(in: db)
            try ICloudContentSchema.captureEligible(accountID: accountID, in: db)
        }
    }

    /// An older client may have consumed a CloudKit change token while
    /// ignoring the optional metadata. Re-read only its unresolved unread
    /// records on upgrade, without resetting tokens or scanning the library.
    func unresolvedArticleMetadata(excluding checked: Set<String>, limit: Int = 100) throws -> [ICloudRecordEnvelope] {
        let excluded = String(decoding: try JSONEncoder().encode(checked.sorted()), as: UTF8.self)
        return try database.read { db in
            try requireScope(in: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM icloud_records WHERE account_id = ? AND needs_apply = 1
                  AND json_extract(envelope_json, '$.kind') = 'read'
                  AND json_extract(envelope_json, '$.fields.value.value.flag._0') = 0
                  AND json_extract(envelope_json, '$.articleMetadata') IS NULL
                  AND record_name NOT IN (SELECT value FROM json_each(?))
                ORDER BY record_name LIMIT ?;
                """, arguments: [accountID, excluded, limit])
            return try rows.map { try prepared($0).envelope }
        }
    }

    func pendingCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_changes WHERE account_id = ? AND is_pending = 1", arguments: [accountID]) ?? 0
        }
    }

    func discardServerMetadata(recordName: String, zone: ICloudRecordZone) throws {
        guard zone == .articles else { throw ICloudRecordError.recoveryRequired }
        if (recordName.hasPrefix("retention-v1:") || recordName == ICloudRetentionUnreadPolicy.recordName || recordName == ICloudRetentionQuota.recordName), try usesRetentionProtocol() {
            try pause(reason: "retentionFenceMissing")
            throw ICloudRecordError.recoveryRequired
        }
        try database.write { db in
            try requireScope(in: db)
            if let old = try cached(recordName, zone: zone, in: db), old.envelope.kind == .content,
               try !retentionSuppresses(old.envelope, in: db) {
                for item in try localEntities(for: old.envelope, in: db) {
                    try ICloudContentSchema.captureEligible(accountID: accountID, itemID: item, requeue: true, in: db)
                }
            }
            // A physical status expiry never changes a reader state. A newer
            // pending intent can recreate that status with a fresh change tag.
            try db.execute(sql: """
                DELETE FROM icloud_records
                WHERE account_id = ? AND zone = ? AND record_name = ? AND is_pending = 0;
                """, arguments: [accountID, zone.rawValue, recordName])
            try db.execute(sql: """
                UPDATE icloud_records SET system_fields = NULL, is_confirmed = 0
                WHERE account_id = ? AND zone = ? AND record_name = ?;
                """, arguments: [accountID, zone.rawValue, recordName])
        }
    }

    func requireScope(in db: Database, permitsPause: Bool = false) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.capture_enabled, s.pause_reason, a.type FROM icloud_sync_scope s
            JOIN accounts a ON a.id = s.account_id WHERE s.account_id = ?;
            """, arguments: [accountID]), row["capture_enabled"] as Bool,
              row["type"] as String == AccountType.iCloud.rawValue
        else { throw ICloudRecordError.unavailableScope }
        if !permitsPause, let _: String = row["pause_reason"] { throw ICloudRecordError.recoveryRequired }
    }

    private func remoteTransaction(checkpoint: Data? = nil, _ action: (Database) throws -> Void) throws {
        try database.write { db in
            try requireScope(in: db)
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture = 1 WHERE account_id = ?", arguments: [accountID])
            try action(db)
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture = 0 WHERE account_id = ?", arguments: [accountID])
            if let checkpoint {
                try db.execute(sql: "UPDATE icloud_sync_scope SET engine_state = ? WHERE account_id = ?", arguments: [checkpoint, accountID])
            }
        }
    }

    private func prepared(_ row: Row) throws -> ICloudPreparedRecord {
        ICloudPreparedRecord(
            envelope: try decode(ICloudRecordEnvelope.self, json: row["envelope_json"]),
            systemFields: row["system_fields"],
            origins: try decode([ICloudRecordOrigin].self, json: row["origins_json"]),
            isPending: row["is_pending"], bodyData: row["body_data"], isConfirmed: row["is_confirmed"]
        )
    }

    func cached(_ name: String, zone: ICloudRecordZone, in db: Database) throws -> ICloudPreparedRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM icloud_records WHERE account_id = ? AND zone = ? AND record_name = ?",
                         arguments: [accountID, zone.rawValue, name]).map(prepared)
    }

    func save(_ envelope: ICloudRecordEnvelope, systemFields: Data?, origins: [ICloudRecordOrigin], pending: Bool, bodyData: Data? = nil, confirmed: Bool = false, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO icloud_records (account_id, zone, record_name, envelope_json, system_fields, origins_json, is_pending, needs_apply, body_data, is_confirmed)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(account_id, zone, record_name) DO UPDATE SET
                envelope_json = excluded.envelope_json, system_fields = excluded.system_fields,
                origins_json = excluded.origins_json, is_pending = excluded.is_pending, needs_apply = 1,
                body_data = excluded.body_data, is_confirmed = excluded.is_confirmed;
            """, arguments: [accountID, envelope.zone.rawValue, envelope.recordName,
                             try encode(envelope), systemFields, try encode(origins), pending, bodyData, confirmed])
    }

    func acknowledge(_ origins: [ICloudRecordOrigin], in db: Database) throws {
        for origin in origins {
            if origin.kind == .content {
                try db.execute(sql: "UPDATE icloud_content_changes SET is_pending = 0 WHERE account_id = ? AND item_id = ? AND revision = ?",
                               arguments: [accountID, origin.entityID, origin.revision])
                continue
            }
            if origin.kind == .settings {
                try db.execute(sql: "UPDATE icloud_sync_scope SET settings_pending = 0 WHERE account_id = ? AND settings_revision = ?",
                               arguments: [accountID, origin.revision])
                continue
            }
            try db.execute(sql: """
                UPDATE icloud_sync_changes SET is_pending = 0
                WHERE account_id = ? AND kind = ? AND entity_id = ? AND revision = ?;
                """, arguments: [accountID, origin.kind.rawValue, origin.entityID, origin.revision])
        }
    }

    private func prepare(_ row: Row, in db: Database) throws {
        guard let kind = ICloudRecordKind(rawValue: row["kind"]) else { throw ICloudRecordError.malformedRecord }
        let entity: String = row["entity_id"]
        let origin = ICloudRecordOrigin(kind: kind, entityID: entity, revision: row["revision"])
        let payload = try decode([String: JSONValue].self, json: row["payload_json"])
        let versions = try decode([String: ICloudFieldVersion].self, json: row["field_versions_json"])
        let name: String
        var feedURL: String?
        var source: String?
        var feedName: String?
        var folderName: String?
        var values: [String: ICloudFieldValue]
        switch kind {
        case .feed:
            guard let url = payload["feed_url"]?.string, let parsed = URL(string: url) else { throw ICloudRecordError.malformedRecord }
            feedURL = try ICloudSyncIdentity.canonicalFeedURL(parsed)
            name = try mapping(kind: kind, entity: entity, suggested: ICloudSyncIdentity.feedRecordName(feedURL: parsed), in: db)
            values = ["feed_url": .text(feedURL!), "title": .text(try payload.requiredString("title")),
                      "site_url": payload["site_url"]?.string.map(ICloudFieldValue.text) ?? .null,
                      "sort_order": .integer(try payload.requiredInteger("sort_order")), "deleted": .flag(row["is_tombstone"])]
        case .folder:
            name = try mapping(kind: kind, entity: entity, suggested: "folder-v1:\(UUID().uuidString.lowercased())", in: db)
            values = ["name": .text(try payload.requiredString("name")), "sort_order": .integer(try payload.requiredInteger("sort_order")),
                      "deleted": .flag(row["is_tombstone"])]
        case .membership:
            let localFeed = try payload.requiredString("feed_id")
            let localFolder = try payload.requiredString("folder_id")
            feedName = try structuralMapping(kind: .feed, entity: localFeed, in: db)
            folderName = try structuralMapping(kind: .folder, entity: localFolder, in: db)
            name = ICloudSyncIdentity.membershipRecordName(feedRecordName: feedName!, folderRecordName: folderName!)
            _ = try mapping(kind: kind, entity: entity, suggested: name, in: db)
            values = ["deleted": .flag(row["is_tombstone"])]
        case .read, .starred:
            guard let url = payload["feed_url"]?.string, let parsed = URL(string: url) else { throw ICloudRecordError.malformedRecord }
            source = payload["source_item_id"]?.string
            guard let articleName = try ICloudSyncIdentity.articleRecordName(feedURL: parsed, sourceItemID: source) else { return }
            feedURL = try ICloudSyncIdentity.canonicalFeedURL(parsed)
            name = "\(kind.rawValue)-v1:" + articleName.dropFirst("article-v1:".count)
            _ = try mapping(kind: kind, entity: entity, suggested: name, in: db)
            values = ["value": .flag(try payload.requiredInteger("value") != 0)]
        case .content, .settings, .retention, .retentionPolicy, .retentionQuota: throw ICloudRecordError.malformedRecord
        }
        let existing = try cached(name, zone: kind == .read || kind == .starred ? .articles : .library, in: db)
        var stamped: [String: ICloudVersionedField] = [:]
        for key in values.keys {
            guard let version = versions[key] else { throw ICloudRecordError.malformedRecord }
            stamped[key] = ICloudVersionedField(value: values[key]!, version: version)
        }
        var local = try ICloudRecordEnvelope(kind: kind, recordName: name, feedURL: feedURL, sourceItemID: source,
                                             feedRecordName: feedName, folderRecordName: folderName, fields: stamped)
        if kind == .read {
            if let metadata = existing?.envelope.articleMetadata { local.articleMetadata = metadata }
            else if let article = try ArticleRecord.fetchOne(db, key: entity) {
                local.articleMetadata = ICloudArticleMetadata(article)
            }
        }
        if kind == .read || kind == .starred {
            // Adding a metadata snapshot is not a new reader intent. In
            // particular it must not rebase an already retired state.
            if !(row["is_pending"] as Bool), try retentionSuppresses(local, in: db) { return }
            guard let version = try retentionStateVersion(local, origin: origin, isUserIntent: row["is_user_intent"], in: db) else {
                try acknowledge([origin], in: db)
                return
            }
            local.fields["value"] = .init(value: values["value"]!, version: version)
        }
        if existing?.origins.contains(origin) == true, existing?.envelope == local { return }
        let merged = try existing?.envelope.merged(with: local) ?? local
        if let existing, merged == existing.envelope {
            // In particular, a just-materialized false/false bootstrap is
            // already superseded by the durable inbox. Acknowledge it locally
            // instead of sending a redundant write to the server.
            try acknowledge([origin], in: db)
            return
        }
        var origins = existing?.origins.filter { !($0.kind == kind && $0.entityID == entity) } ?? []
        origins.append(origin)
        try save(merged, systemFields: existing?.systemFields, origins: origins, pending: true, in: db)
    }

    /// Upgrade old state-only records in bounded batches without changing
    /// their read/starred values, logical versions, or journal revisions.
    private func prepareArticleMetadata(limit: Int, in db: Database) throws {
        var after = "", remaining = limit
        while remaining > 0 {
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.* FROM icloud_sync_changes c
                JOIN items i ON i.id = c.entity_id AND i.account_id = c.account_id
                JOIN articles a ON a.item_id = i.id JOIN article_states s ON s.item_id = i.id
                JOIN feeds f ON f.id = i.feed_id
                LEFT JOIN icloud_record_mappings m ON m.account_id = c.account_id AND m.kind = 'read' AND m.entity_id = i.id
                LEFT JOIN icloud_records r ON r.account_id = c.account_id AND r.zone = 'PaperRssArticles-v1' AND r.record_name = m.record_name
                WHERE c.account_id = ? AND c.kind = 'read' AND c.is_pending = 0
                  AND f.is_deleted = 0 AND (s.is_read = 0 OR s.is_starred = 1)
                  AND length(trim(i.source_item_id)) > 0
                  AND json_extract(r.envelope_json, '$.articleMetadata') IS NULL
                  AND c.entity_id > ?
                ORDER BY c.entity_id LIMIT ?;
                """, arguments: [accountID, after, remaining])
            guard !rows.isEmpty else { break }
            for row in rows {
                let entity: String = row["entity_id"]
                after = entity
                let payload = try decode([String: JSONValue].self, json: row["payload_json"])
                guard let url = payload["feed_url"]?.string.flatMap(URL.init(string:)),
                      let identity = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: payload["source_item_id"]?.string) else { continue }
                let name = "read-v1:" + identity.dropFirst("article-v1:".count)
                if let stored = try cached(name, zone: .articles, in: db), try retentionSuppresses(stored.envelope, in: db) { continue }
                try prepare(row, in: db)
                if try cached(name, zone: .articles, in: db)?.envelope.articleMetadata != nil { remaining -= 1 }
            }
        }
    }

    private func structuralMapping(kind: ICloudRecordKind, entity: String, in db: Database) throws -> String {
        if let existing = try String.fetchOne(db, sql: "SELECT record_name FROM icloud_record_mappings WHERE account_id = ? AND kind = ? AND entity_id = ?",
                                             arguments: [accountID, kind.rawValue, entity]) { return existing }
        guard let change = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_changes WHERE account_id = ? AND kind = ? AND entity_id = ?",
                                           arguments: [accountID, kind.rawValue, entity]) else { throw ICloudRecordError.malformedRecord }
        try prepare(change, in: db)
        guard let name = try String.fetchOne(db, sql: "SELECT record_name FROM icloud_record_mappings WHERE account_id = ? AND kind = ? AND entity_id = ?",
                                            arguments: [accountID, kind.rawValue, entity]) else { throw ICloudRecordError.malformedRecord }
        return name
    }

    func mapping(kind: ICloudRecordKind, entity: String, suggested: String, in db: Database) throws -> String {
        try db.execute(sql: """
            INSERT INTO icloud_record_mappings (account_id, kind, entity_id, record_name) VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, kind, entity_id) DO NOTHING;
            """, arguments: [accountID, kind.rawValue, entity, suggested])
        return try String.fetchOne(db, sql: "SELECT record_name FROM icloud_record_mappings WHERE account_id = ? AND kind = ? AND entity_id = ?",
                                   arguments: [accountID, kind.rawValue, entity])!
    }

    func preparePendingLocal(for envelope: ICloudRecordEnvelope, in db: Database) throws {
        if envelope.kind == .settings { try prepareSettings(in: db); return }
        if envelope.kind == .retentionPolicy { try prepareRetentionUnreadPolicy(in: db); return }
        if envelope.kind == .content || envelope.kind == .retention || envelope.kind == .retentionQuota { return } // compressed outside the writer transaction
        let entities = try localEntities(for: envelope, in: db)
        for entity in entities {
            if let change = try Row.fetchOne(db, sql: """
                SELECT * FROM icloud_sync_changes WHERE account_id = ? AND kind = ? AND entity_id = ? AND is_pending = 1;
                """, arguments: [accountID, envelope.kind.rawValue, entity]) { try prepare(change, in: db) }
        }
    }

    func localEntities(for envelope: ICloudRecordEnvelope, in db: Database) throws -> [String] {
        var entities = try String.fetchAll(db, sql: """
            SELECT entity_id FROM icloud_record_mappings WHERE account_id = ? AND kind = ? AND record_name = ?;
            """, arguments: [accountID, envelope.kind.rawValue, envelope.recordName])
        if envelope.zone == .articles {
            entities = try entities.filter { try ItemRecord.fetchOne(db, key: $0) != nil }
        }
        if entities.isEmpty, let url = envelope.feedURL {
            let feeds = try FeedRecord.filter(Column("account_id") == accountID).fetchAll(db).filter {
                guard let parsed = URL(string: $0.feedURL) else { return false }
                return (try? ICloudSyncIdentity.canonicalFeedURL(parsed)) == url
            }
            if envelope.kind == .feed { entities = feeds.map(\.id) }
            else if let source = envelope.sourceItemID {
                for feed in feeds {
                    entities += try String.fetchAll(db, sql: "SELECT id FROM items WHERE account_id = ? AND feed_id = ? AND source_item_id = ?",
                                                    arguments: [accountID, feed.id, source])
                }
            }
        }
        for entity in entities { _ = try mapping(kind: envelope.kind, entity: entity, suggested: envelope.recordName, in: db) }
        return entities
    }

    private func reconcileCachedRecords(in db: Database, recordNames: Set<String>? = nil, includesRelationships: Bool = false) throws {
        // Parent ordering applies even when an incoming page is unordered.
        let scope: String
        var arguments: StatementArguments = [accountID]
        var additionalRecords: [ICloudRecordEnvelope] = []
        if let recordNames {
            if recordNames.isEmpty { return }
            let names = recordNames.sorted()
            scope = """
                AND (record_name IN (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))
                     \(includesRelationships ? "OR json_extract(envelope_json, '$.kind') IN ('membership', 'content', 'read', 'starred')" : ""))
                """
            arguments += StatementArguments(names)
            let sources = try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(envelope_json, '$.sourceItemID') FROM icloud_records
                WHERE account_id = ? AND record_name IN (\(Array(repeating: "?", count: names.count).joined(separator: ",")))
                    AND json_extract(envelope_json, '$.kind') IN ('read', 'starred');
                """, arguments: StatementArguments([accountID] + names))
            if !sources.isEmpty {
                // An earlier body may have been waiting for this state page.
                let pendingBodies = try Row.fetchAll(db, sql: """
                    SELECT * FROM icloud_records WHERE account_id = ? AND needs_apply = 1
                      AND json_extract(envelope_json, '$.kind') IN ('content', 'read', 'starred')
                      AND json_extract(envelope_json, '$.sourceItemID') IN (\(Array(repeating: "?", count: sources.count).joined(separator: ",")));
                    """, arguments: StatementArguments([accountID] + sources))
                additionalRecords = try pendingBodies.map { try prepared($0).envelope }
            }
        } else {
            // Unmatched state can remain in the inbox for a long time. Decode
            // only identities currently materialized by RSS, using an index.
            scope = """
                AND (zone = 'PaperRssLibrary-v1' OR json_extract(envelope_json, '$.kind') = 'content'
                    OR json_extract(envelope_json, '$.articleMetadata') IS NOT NULL OR EXISTS (
                    SELECT 1 FROM items i WHERE i.account_id = icloud_records.account_id
                    AND i.source_item_id IS NOT NULL
                    AND i.source_item_id = json_extract(icloud_records.envelope_json, '$.sourceItemID')
                ))
                """
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM icloud_records WHERE account_id = ? AND needs_apply = 1 \(scope);
            """, arguments: arguments)
        var seen = Set<String>()
        let records = (try rows.map { try prepared($0).envelope } + additionalRecords).filter { seen.insert($0.recordName).inserted }
        for kind in [ICloudRecordKind.retention, .retentionPolicy, .retentionQuota, .settings, .feed, .folder, .membership, .content, .read, .starred] {
            for record in records where record.kind == kind {
                try preparePendingLocal(for: record, in: db)
                let latest = try cached(record.recordName, zone: record.zone, in: db)!.envelope
                try applyCachedRecord(latest, in: db)
            }
        }
    }

    func applyCachedRecord(_ envelope: ICloudRecordEnvelope, in db: Database) throws {
        guard try retentionCanApply(envelope, in: db) else { return }
        if envelope.kind == .content {
            guard try restoreContent(envelope, in: db) else { return }
        } else if envelope.kind == .membership {
            guard let feed = envelope.feedRecordName, let folder = envelope.folderRecordName,
                  try liveEntity(kind: .feed, name: feed, in: db) != nil,
                  try liveEntity(kind: .folder, name: folder, in: db) != nil else { return }
        } else if [.read, .starred].contains(envelope.kind) {
            try restoreArticleMetadata(for: envelope, in: db)
            guard try !localEntities(for: envelope, in: db).isEmpty else { return }
        }
        try apply(envelope, in: db)
        try db.execute(sql: """
            UPDATE icloud_records SET needs_apply = 0
            WHERE account_id = ? AND zone = ? AND record_name = ?;
            """, arguments: [accountID, envelope.zone.rawValue, envelope.recordName])
    }

    private func restoreArticleMetadata(for envelope: ICloudRecordEnvelope, in db: Database) throws {
        let prefix = "\(envelope.kind.rawValue)-v1:"
        let suffix = envelope.recordName.dropFirst(prefix.count)
        guard let read = try cached("read-v1:" + suffix, zone: .articles, in: db)?.envelope,
              try retentionCanApply(read, in: db), let metadata = read.articleMetadata,
              let feedURL = read.feedURL, let parsed = URL(string: feedURL), let source = read.sourceItemID else { return }
        let readFlag = try liveCloudFlag(kind: .read, suffix: suffix, in: db)
        let starFlag = try liveCloudFlag(kind: .starred, suffix: suffix, in: db)
        guard readFlag == .flag(false) || starFlag == .flag(true) else { return }
        let feedName = try ICloudSyncIdentity.feedRecordName(feedURL: parsed)
        guard try cached(feedName, zone: .library, in: db)?.envelope.fields["deleted"]?.value != .flag(true),
              let feedID = try liveEntity(kind: .feed, name: feedName, in: db) else { return }
        var entities = try localEntities(for: read, in: db)
        let now = Date().timeIntervalSince1970
        if entities.isEmpty {
            let itemID = "\(feedID)|\(source)".stableDigest
            if let existing = try ItemRecord.fetchOne(db, key: itemID),
               existing.accountID != accountID || existing.feedID != feedID || existing.sourceItemID != source { return }
            try ItemRecord(id: itemID, accountID: accountID, externalID: itemID, feedID: feedID,
                createdAt: now, updatedAt: now, sourceItemID: source).save(db)
            try ArticleStateRecord(itemID: itemID, isRead: readFlag != .flag(false), isStarred: starFlag == .flag(true),
                dateArrived: now, updatedAt: now).save(db)
            entities = [itemID]
        }
        for itemID in entities where try ArticleRecord.fetchOne(db, key: itemID) == nil {
            try ArticleRecord(itemID: itemID, title: metadata.title, author: metadata.author, url: metadata.url,
                publishedAt: metadata.publishedAt, summary: "", contentUpdatedAt: 0).save(db)
        }
    }

    func replayStates(for envelope: ICloudRecordEnvelope, in db: Database) throws {
        guard envelope.kind == .content else { return }
        for kind in [ICloudRecordKind.read, .starred] {
            let name = "\(kind.rawValue)-v1:" + envelope.recordName.dropFirst("content-v1:".count)
            if let state = try cached(name, zone: .articles, in: db) {
                try preparePendingLocal(for: state.envelope, in: db)
                try applyCachedRecord(try cached(name, zone: .articles, in: db)!.envelope, in: db)
            }
        }
    }

    private func apply(_ envelope: ICloudRecordEnvelope, in db: Database) throws {
        let now = Date().timeIntervalSince1970
        let deleted = envelope.fields["deleted"]?.value == .flag(true)
        switch envelope.kind {
        case .feed:
            let entities = try localEntities(for: envelope, in: db)
            if deleted {
                for id in entities { _ = try FeedRecord.deleteOne(db, key: id) }
                try snapshot(envelope, entities: entities, in: db)
                return
            }
            let id = entities.first(where: { (try? FeedRecord.fetchOne(db, key: $0)) != nil }) ?? entities.first ?? UUID().uuidString
            _ = try mapping(kind: .feed, entity: id, suggested: envelope.recordName, in: db)
            var feed = try FeedRecord.fetchOne(db, key: id) ?? FeedRecord(id: id, accountID: accountID, title: "", feedURL: envelope.feedURL!, updatedAt: now)
            feed.title = try envelope.text("title"); feed.siteURL = envelope.optionalText("site_url")
            feed.sortOrder = try envelope.integer("sort_order"); feed.isDeleted = false; feed.updatedAt = now
            try feed.save(db)
            try snapshot(envelope, entities: [id], in: db)
        case .folder:
            let entities = try localEntities(for: envelope, in: db)
            if deleted {
                for id in entities { _ = try FolderRecord.deleteOne(db, key: id) }
                try snapshot(envelope, entities: entities, in: db)
                return
            }
            let id = entities.last(where: { (try? FolderRecord.fetchOne(db, key: $0)) != nil }) ?? UUID().uuidString
            _ = try mapping(kind: .folder, entity: id, suggested: envelope.recordName, in: db)
            try FolderRecord(id: id, accountID: accountID, externalID: envelope.recordName, name: envelope.text("name"),
                             sortOrder: envelope.integer("sort_order"), updatedAt: now).save(db)
            try snapshot(envelope, entities: [id], in: db)
        case .membership:
            guard let feedName = envelope.feedRecordName, let folderName = envelope.folderRecordName,
                  let feed = try liveEntity(kind: .feed, name: feedName, in: db),
                  let folder = try liveEntity(kind: .folder, name: folderName, in: db)
            else { return } // Durable cache retains this relationship.
            let entity = try encode([feed, folder])
            _ = try mapping(kind: .membership, entity: entity, suggested: envelope.recordName, in: db)
            if deleted {
                try db.execute(sql: "DELETE FROM feed_folders WHERE feed_id = ? AND folder_id = ?", arguments: [feed, folder])
            } else {
                try FeedFolderRecord(feedID: feed, folderID: folder).save(db)
            }
            try snapshot(envelope, entities: [entity], in: db)
        case .read, .starred:
            for item in try localEntities(for: envelope, in: db) {
                guard try ItemRecord.fetchOne(db, key: item) != nil else { continue }
                var state = try ArticleStateRecord.fetchOne(db, key: item) ??
                    ArticleStateRecord(itemID: item, isRead: false, isStarred: false, dateArrived: now, updatedAt: now)
                let previouslyRead = state.isRead, previouslyStarred = state.isStarred
                let value = envelope.fields["value"]!.value == .flag(true)
                if envelope.kind == .read { state.isRead = value } else { state.isStarred = value }
                state.updatedAt = now
                try state.save(db)
                try snapshot(envelope, entities: [item], in: db)
                let needsBodyRequeue = try retentionNeedsBodyRequeue(for: envelope, entity: item, in: db)
                if (!previouslyStarred && state.isStarred) || (previouslyRead && !state.isRead && !state.isStarred) || needsBodyRequeue {
                    try ICloudContentSchema.captureEligible(accountID: accountID, itemID: item, requeue: true, in: db)
                }
            }
        case .content: break // already restored, before dependent reader states
        case .settings: try applySettings(envelope, in: db)
        case .retention, .retentionPolicy, .retentionQuota: break // wire-only; never a reader or AI projection
        }
    }

    private func snapshot(_ envelope: ICloudRecordEnvelope, entities: [String], in db: Database) throws {
        guard let kind = ICloudSyncChangeKind(rawValue: envelope.kind.rawValue) else { return }
        let versions = try encode(envelope.fields.mapValues(\.version))
        for entity in entities {
            try ICloudSyncSchema.recordRemoteSnapshot(
                accountID: accountID, kind: kind, entityID: entity, versionsJSON: versions,
                tombstone: envelope.fields["deleted"]?.value == .flag(true), in: db
            )
        }
    }

    func liveEntity(kind: ICloudRecordKind, name: String, in db: Database) throws -> String? {
        let table = kind == .feed ? "feeds" : "folders"
        return try String.fetchOne(db, sql: """
            SELECT r.id FROM \(table) r JOIN icloud_record_mappings m ON m.entity_id = r.id AND m.account_id = r.account_id
            WHERE m.account_id = ? AND m.kind = ? AND m.record_name = ? AND r.is_deleted = 0 LIMIT 1;
            """, arguments: [accountID, kind.rawValue, name])
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

private enum JSONValue: Decodable {
    case string(String), integer(Int64), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let number = try? container.decode(Int64.self) { self = .integer(number) }
        else { self = .string(try container.decode(String.self)) }
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
}
private extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.string else { throw ICloudRecordError.malformedRecord }; return value
    }
    func requiredInteger(_ key: String) throws -> Int64 {
        guard case .integer(let value) = self[key] else { throw ICloudRecordError.malformedRecord }; return value
    }
}
private extension ICloudRecordEnvelope {
    func text(_ key: String) throws -> String {
        guard case .text(let value) = fields[key]?.value else { throw ICloudRecordError.malformedRecord }; return value
    }
    func optionalText(_ key: String) -> String? {
        if case .text(let value) = fields[key]?.value { return value }; return nil
    }
    func integer(_ key: String) throws -> Int {
        guard case .integer(let value) = fields[key]?.value, let result = Int(exactly: value)
        else { throw ICloudRecordError.malformedRecord }; return result
    }
}
