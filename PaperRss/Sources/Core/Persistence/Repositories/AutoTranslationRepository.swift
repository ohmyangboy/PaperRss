import Foundation
import GRDB

/// 自动化配置只在本地保存，与同步服务的订阅配置隔离。
public struct AutoTranslationRepository: Sendable {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }

    public func feedLists() throws -> [UUID: TranslationFeedList] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT l.feed_id, l.list FROM translation_feed_lists l JOIN feeds f ON f.id = l.feed_id AND f.account_id = l.account_id WHERE f.is_deleted = 0")
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id = UUID(uuidString: row["feed_id"]), let list = TranslationFeedList(rawValue: row["list"]) else { return nil }
                return (id, list)
            })
        }
    }

    public func setList(_ list: TranslationFeedList?, feedID: UUID, accountID: String) throws {
        try database.write { db in
            if let list {
                try db.execute(sql: "INSERT OR REPLACE INTO translation_feed_lists(account_id, feed_id, list) SELECT account_id, id, ? FROM feeds WHERE id = ? AND account_id = ? AND is_deleted = 0", arguments: [list.rawValue, feedID.uuidString, accountID])
            } else {
                try db.execute(sql: "DELETE FROM translation_feed_lists WHERE account_id = ? AND feed_id = ?", arguments: [accountID, feedID.uuidString])
            }
        }
    }

    public func isExempt(entry: Entry) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM translation_article_exemptions e JOIN feeds f ON f.account_id = e.account_id WHERE e.item_id = ? AND f.id = ?)", arguments: [entry.id, entry.feedID.uuidString]) ?? false
        }
    }

    public func setExempt(_ exempt: Bool, accountID: String, entryID: String) throws {
        try database.write { db in
            if exempt {
                try db.execute(sql: "INSERT OR IGNORE INTO translation_article_exemptions(account_id, item_id) VALUES (?, ?)", arguments: [accountID, entryID])
            } else {
                try db.execute(sql: "DELETE FROM translation_article_exemptions WHERE account_id = ? AND item_id = ?", arguments: [accountID, entryID])
            }
        }
    }

    public func accountID(feedID: UUID) throws -> String? {
        try database.read { db in try String.fetchOne(db, sql: "SELECT account_id FROM feeds WHERE id = ? AND is_deleted = 0", arguments: [feedID.uuidString]) }
    }

    static func saveHints(_ hints: [ArticleLanguageHint], scope: String, id: String, in db: Database) throws {
        guard !hints.isEmpty else {
            try db.execute(sql: "DELETE FROM source_language_hints WHERE scope = ? AND entity_id = ?", arguments: [scope, id])
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(hints)
        try db.execute(sql: """
            INSERT INTO source_language_hints(scope, entity_id, hints_json) VALUES (?, ?, ?)
            ON CONFLICT(scope, entity_id) DO UPDATE SET hints_json = excluded.hints_json
            WHERE hints_json != excluded.hints_json
            """, arguments: [scope, id, String(decoding: data, as: UTF8.self)])
    }

    public func languageHints(entry: Entry) throws -> [ArticleLanguageHint] {
        try database.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT hints_json FROM source_language_hints WHERE (scope = 'feed' AND entity_id = ?) OR (scope = 'article' AND entity_id = ?)", arguments: [entry.feedID.uuidString, entry.id])
            return rows.flatMap { (try? JSONDecoder().decode([ArticleLanguageHint].self, from: Data($0.utf8))) ?? [] }
        }
    }
}
