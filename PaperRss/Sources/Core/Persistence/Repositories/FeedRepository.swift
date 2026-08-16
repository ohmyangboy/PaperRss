import Foundation
import GRDB

/// 管理订阅源 (Feed)、分类目录 (Folder) 及多对多关联关系的持久化仓库。
///
/// 遵循 Architecture Contract (Section 8.2, 8.3, 8.4 / INV-02)。
public final class FeedRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Database-Scoped Primitives (Feeds)

    public func fetchAllFeeds(accountID: String = "local-default", includeDeleted: Bool = false, in db: Database) throws -> [FeedRecord] {
        var query = FeedRecord.filter(Column("account_id") == accountID)
        if !includeDeleted {
            query = query.filter(Column("is_deleted") == false)
        }
        return try query.order(Column("sort_order").asc, Column("title").asc).fetchAll(db)
    }

    public func fetchFeed(id: String, in db: Database) throws -> FeedRecord? {
        try FeedRecord.filter(Column("id") == id).fetchOne(db)
    }

    public func fetchFeedByRemoteIdentity(accountID: String = "local-default", externalID: String, in db: Database) throws -> FeedRecord? {
        try FeedRecord
            .filter(Column("account_id") == accountID && Column("external_id") == externalID)
            .fetchOne(db)
    }

    public func fetchFeedByURL(accountID: String = "local-default", feedURL: String, includeDeleted: Bool = true, in db: Database) throws -> FeedRecord? {
        var query = FeedRecord.filter(Column("account_id") == accountID && Column("feed_url") == feedURL)
        if !includeDeleted {
            query = query.filter(Column("is_deleted") == false)
        }
        return try query.fetchOne(db)
    }

    public func saveFeed(_ record: FeedRecord, in db: Database) throws {
        try record.save(db)
    }

    public func deleteFeed(id: String, in db: Database) throws {
        _ = try FeedRecord.filter(Column("id") == id).deleteAll(db)
    }

    public func softDeleteFeed(id: String, in db: Database) throws {
        if var record = try fetchFeed(id: id, in: db) {
            record.isDeleted = true
            record.updatedAt = Date().timeIntervalSince1970
            try record.save(db)
        }
    }

    public func updateFeedMetadata(
        feedID: String,
        title: String? = nil,
        siteURL: String? = nil,
        storedIconURL: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        lastRefreshedAt: Double? = nil,
        in db: Database
    ) throws {
        guard var record = try fetchFeed(id: feedID, in: db) else { return }
        if let title { record.title = title }
        if let siteURL { record.siteURL = siteURL }
        if let storedIconURL { record.storedIconURL = storedIconURL }
        if let etag { record.etag = etag }
        if let lastModified { record.lastModified = lastModified }
        if let lastRefreshedAt { record.lastRefreshedAt = lastRefreshedAt }
        record.updatedAt = Date().timeIntervalSince1970
        try record.save(db)
    }

    // MARK: - Feed Model Projection (FeedRecord + Folder -> Domain Feed)

    public func fetchAllFeedModels(accountID: String? = nil, in db: Database) throws -> [Feed] {
        let accountClause = accountID != nil ? "AND f.account_id = :account_id" : ""
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        if let accountID {
            arguments["account_id"] = accountID
        }

        let sql = """
        SELECT
            f.id AS id,
            f.title AS title,
            f.site_url AS site_url,
            f.feed_url AS feed_url,
            fo.name AS folder_name,
            f.etag AS etag,
            f.last_modified AS last_modified,
            f.last_refreshed_at AS last_refreshed_at,
            f.is_deleted AS is_deleted,
            f.updated_at AS updated_at,
            f.stored_icon_url AS stored_icon_url
        FROM feeds f
        LEFT JOIN feed_folders ff ON ff.feed_id = f.id
        LEFT JOIN folders fo ON fo.id = ff.folder_id AND fo.is_deleted = 0
        WHERE f.is_deleted = 0 \(accountClause)
        ORDER BY f.sort_order ASC, f.title ASC;
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        return rows.compactMap { row in
            guard let idString: String = row["id"],
                  let uuid = UUID(uuidString: idString),
                  let feedURLString: String = row["feed_url"],
                  let feedURL = URL(string: feedURLString) else { return nil }

            let title: String = row["title"]
            let siteURLString: String? = row["site_url"]
            let siteURL = siteURLString.flatMap { URL(string: $0) }
            let folderName: String? = row["folder_name"]
            let etag: String? = row["etag"]
            let lastModified: String? = row["last_modified"]
            let lastRefreshedAtTimestamp: Double? = row["last_refreshed_at"]
            let lastRefreshedAt = lastRefreshedAtTimestamp.map { Date(timeIntervalSince1970: $0) }
            let isDeletedInt: Int = row["is_deleted"]
            let updatedAtTimestamp: Double = row["updated_at"]
            let updatedAt = Date(timeIntervalSince1970: updatedAtTimestamp)
            let storedIconURLString: String? = row["stored_icon_url"]
            let storedIconURL = storedIconURLString.flatMap { URL(string: $0) }

            return Feed(
                id: uuid,
                title: title,
                siteURL: siteURL,
                feedURL: feedURL,
                folder: folderName,
                etag: etag,
                lastModified: lastModified,
                lastRefreshedAt: lastRefreshedAt,
                isDeleted: isDeletedInt == 1,
                updatedAt: updatedAt,
                storedIconURL: storedIconURL
            )
        }
    }

    // MARK: - Folders & Management

    public func fetchAllFolders(accountID: String? = nil, includeDeleted: Bool = false, in db: Database) throws -> [FolderRecord] {
        var query = FolderRecord.all()
        if let accountID {
            query = query.filter(Column("account_id") == accountID)
        }
        if !includeDeleted {
            query = query.filter(Column("is_deleted") == false)
        }
        return try query.order(Column("sort_order").asc, Column("name").asc).fetchAll(db)
    }

    public func fetchFolderNames(accountID: String? = nil, in db: Database) throws -> [String] {
        let folders = try fetchAllFolders(accountID: accountID, includeDeleted: false, in: db)
        return folders.map(\.name)
    }

    public func addFolder(name: String, accountID: String = "local-default", in db: Database) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let folderID = "\(accountID):folder:\(clean)".stableDigest
        if try FolderRecord.filter(Column("id") == folderID).fetchOne(db) == nil {
            let maxSort = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM folders WHERE account_id = ?;", arguments: [accountID])) ?? 0
            let record = FolderRecord(
                id: folderID,
                accountID: accountID,
                externalID: nil,
                name: clean,
                sortOrder: maxSort + 1,
                isDeleted: false,
                updatedAt: Date().timeIntervalSince1970
            )
            try record.save(db)
        }
    }

    public func deleteFolder(name: String, accountID: String = "local-default", in db: Database) throws {
        let folderID = "\(accountID):folder:\(name)".stableDigest
        _ = try FeedFolderRecord.filter(Column("folder_id") == folderID).deleteAll(db)
        _ = try FolderRecord.filter(Column("id") == folderID).deleteAll(db)
    }

    public func renameFolder(oldName: String, newName: String, accountID: String = "local-default", in db: Database) throws {
        let cleanNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNew.isEmpty, cleanNew != oldName else { return }

        let oldFolderID = "\(accountID):folder:\(oldName)".stableDigest
        let newFolderID = "\(accountID):folder:\(cleanNew)".stableDigest

        guard let oldFolder = try FolderRecord.filter(Column("id") == oldFolderID).fetchOne(db) else { return }

        // 获取绑定到旧 folder 的所有 feed_ids
        let feedIDs = try String.fetchAll(
            db,
            sql: "SELECT feed_id FROM feed_folders WHERE folder_id = ?;",
            arguments: [oldFolderID]
        )

        _ = try FeedFolderRecord.filter(Column("folder_id") == oldFolderID).deleteAll(db)
        _ = try FolderRecord.filter(Column("id") == oldFolderID).deleteAll(db)

        let newRecord = FolderRecord(
            id: newFolderID,
            accountID: accountID,
            externalID: nil,
            name: cleanNew,
            sortOrder: oldFolder.sortOrder,
            isDeleted: false,
            updatedAt: Date().timeIntervalSince1970
        )
        try newRecord.save(db)

        for feedID in feedIDs {
            let link = FeedFolderRecord(feedID: feedID, folderID: newFolderID)
            try link.save(db)
        }
    }

    public func setFeedFolder(feedID: String, folderName: String?, accountID: String = "local-default", in db: Database) throws {
        _ = try FeedFolderRecord.filter(Column("feed_id") == feedID).deleteAll(db)

        guard let folderName = folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty else { return }

        // 确保 folder 存在
        try addFolder(name: folderName, accountID: accountID, in: db)
        let folderID = "\(accountID):folder:\(folderName)".stableDigest
        let link = FeedFolderRecord(feedID: feedID, folderID: folderID)
        try link.save(db)
    }

    public func setFeedFolder(feedIDs: Set<String>, folderName: String?, accountID: String = "local-default", in db: Database) throws {
        for feedID in feedIDs {
            try setFeedFolder(feedID: feedID, folderName: folderName, accountID: accountID, in: db)
        }
    }

    public func saveFolder(_ record: FolderRecord, in db: Database) throws {
        try record.save(db)
    }

    public func setFeedFolders(feedID: String, folderIDs: [String], in db: Database) throws {
        _ = try FeedFolderRecord.filter(Column("feed_id") == feedID).deleteAll(db)
        for folderID in folderIDs {
            let link = FeedFolderRecord(feedID: feedID, folderID: folderID)
            try link.save(db)
        }
    }

    public func fetchFolderIDs(forFeedID feedID: String, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT folder_id FROM feed_folders WHERE feed_id = ? ORDER BY folder_id ASC;",
            arguments: [feedID]
        )
    }

    // MARK: - Async Public APIs

    public func fetchAllFeedModels(accountID: String = "local-default") async throws -> [Feed] {
        try database.read { db in
            try fetchAllFeedModels(accountID: accountID, in: db)
        }
    }

    public func fetchFolderNames(accountID: String = "local-default") async throws -> [String] {
        try database.read { db in
            try fetchFolderNames(accountID: accountID, in: db)
        }
    }

    public func addFolder(name: String, accountID: String = "local-default") async throws {
        try database.write { db in
            try addFolder(name: name, accountID: accountID, in: db)
        }
    }

    public func deleteFolder(name: String, accountID: String = "local-default") async throws {
        try database.write { db in
            try deleteFolder(name: name, accountID: accountID, in: db)
        }
    }

    public func renameFolder(oldName: String, newName: String, accountID: String = "local-default") async throws {
        try database.write { db in
            try renameFolder(oldName: oldName, newName: newName, accountID: accountID, in: db)
        }
    }

    public func setFeedFolder(feedID: String, folderName: String?, accountID: String = "local-default") async throws {
        try database.write { db in
            try setFeedFolder(feedID: feedID, folderName: folderName, accountID: accountID, in: db)
        }
    }

    public func setFeedFolder(feedIDs: Set<String>, folderName: String?, accountID: String = "local-default") async throws {
        try database.write { db in
            try setFeedFolder(feedIDs: feedIDs, folderName: folderName, accountID: accountID, in: db)
        }
    }

    public func softDeleteFeed(id: String) async throws {
        try database.write { db in
            try softDeleteFeed(id: id, in: db)
        }
    }

    public func saveFeed(_ record: FeedRecord) async throws {
        try database.write { db in
            try saveFeed(record, in: db)
        }
    }

    public func saveFolder(_ record: FolderRecord) async throws {
        try database.write { db in
            try saveFolder(record, in: db)
        }
    }

    public func fetchAllFeeds(accountID: String = "local-default", includeDeleted: Bool = false) async throws -> [FeedRecord] {
        try database.read { db in
            try fetchAllFeeds(accountID: accountID, includeDeleted: includeDeleted, in: db)
        }
    }

    public func setFeedFolders(feedID: String, folderIDs: [String]) async throws {
        try database.write { db in
            try setFeedFolders(feedID: feedID, folderIDs: folderIDs, in: db)
        }
    }

    public func fetchFolderIDs(forFeedID feedID: String) async throws -> [String] {
        try database.read { db in
            try fetchFolderIDs(forFeedID: feedID, in: db)
        }
    }
}
