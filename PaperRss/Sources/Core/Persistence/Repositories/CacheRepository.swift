import Foundation
import GRDB

/// 管理文章网页正文提取离线缓存 (ArticleCache) 的持久化仓库。
///
/// 遵循 Architecture Contract (Section 10)。
public final class CacheRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Database-Scoped Primitives

    public func fetchCache(itemID: String, in db: Database) throws -> ArticleCacheRecord? {
        try ArticleCacheRecord.filter(Column("item_id") == itemID).fetchOne(db)
    }

    public func saveCache(_ record: ArticleCacheRecord, in db: Database) throws {
        try record.save(db)
    }

    public func deleteCache(itemID: String, in db: Database) throws {
        _ = try ArticleCacheRecord.filter(Column("item_id") == itemID).deleteAll(db)
    }

    // MARK: - Domain Model Helpers

    public func fetchCacheModel(itemID: String, in db: Database) throws -> ArticleCache? {
        guard let record = try fetchCache(itemID: itemID, in: db) else { return nil }
        let imageURLStrings: [String] = record.imageUrlsJSON.flatMap { json in
            try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        } ?? []
        let imageURLs = imageURLStrings.compactMap { URL(string: $0) }
        let sourceURL = record.sourceURL.flatMap { URL(string: $0) }
        return ArticleCache(
            entryID: record.itemID,
            text: record.text,
            html: record.html,
            imageURLs: imageURLs,
            fetchedAt: Date(timeIntervalSince1970: record.fetchedAt),
            sourceURL: sourceURL,
            isSanitized: record.isSanitized
        )
    }

    public func saveCacheModel(_ cache: ArticleCache, in db: Database) throws {
        let imageUrlStrings = cache.imageURLs.map(\.absoluteString)
        let imageUrlsJSON = (try? LegacyMigrationJSONEncoder.encodeString(imageUrlStrings)) ?? "[]"
        let record = ArticleCacheRecord(
            itemID: cache.entryID,
            text: cache.text,
            html: cache.html,
            imageUrlsJSON: imageUrlsJSON,
            fetchedAt: cache.fetchedAt.timeIntervalSince1970,
            sourceURL: cache.sourceURL?.absoluteString,
            isSanitized: cache.isSanitized
        )
        try saveCache(record, in: db)
    }

    // MARK: - Async Public APIs

    public func fetchCacheModel(itemID: String) async throws -> ArticleCache? {
        try database.read { db in
            try fetchCacheModel(itemID: itemID, in: db)
        }
    }

    public func saveCacheModel(_ cache: ArticleCache) async throws {
        try database.write { db in
            try saveCacheModel(cache, in: db)
        }
    }

    public func fetchCache(itemID: String) async throws -> ArticleCacheRecord? {
        try database.read { db in
            try fetchCache(itemID: itemID, in: db)
        }
    }

    public func saveCache(_ record: ArticleCacheRecord) async throws {
        try database.write { db in
            try saveCache(record, in: db)
        }
    }

    public func deleteCache(itemID: String) async throws {
        try database.write { db in
            try deleteCache(itemID: itemID, in: db)
        }
    }
}
