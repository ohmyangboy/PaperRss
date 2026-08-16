import Foundation
import GRDB

/// 管理文章阅读/标星状态 (ArticleState) 与待同步状态出站队列 (ArticleStateOutbox) 的持久化仓库。
///
/// 遵循 Architecture Contract (Section 8.7, 9 / INV-06, INV-07, INV-08)。
public final class ArticleStateRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Database-Scoped Primitives (Article States)

    public func fetchState(itemID: String, in db: Database) throws -> ArticleStateRecord? {
        try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db)
    }

    public func saveState(_ record: ArticleStateRecord, in db: Database) throws {
        try record.save(db)
    }

    public func deleteState(itemID: String, in db: Database) throws {
        _ = try ArticleStateRecord.filter(Column("item_id") == itemID).deleteAll(db)
    }

    public func markRead(itemID: String, isRead: Bool, in db: Database) throws {
        let now = Date().timeIntervalSince1970
        if var existing = try fetchState(itemID: itemID, in: db) {
            existing.isRead = isRead
            existing.updatedAt = now
            try existing.save(db)
        } else {
            let newState = ArticleStateRecord(
                itemID: itemID,
                isRead: isRead,
                isStarred: false,
                dateArrived: now,
                updatedAt: now
            )
            try newState.save(db)
        }
    }

    public func markRead(itemIDs: [String], isRead: Bool, in db: Database) throws {
        guard !itemIDs.isEmpty else { return }
        let targetIDs = Set(itemIDs)
        for id in targetIDs {
            try markRead(itemID: id, isRead: isRead, in: db)
        }
    }

    public func markStarred(itemID: String, isStarred: Bool, in db: Database) throws {
        let now = Date().timeIntervalSince1970
        if var existing = try fetchState(itemID: itemID, in: db) {
            existing.isStarred = isStarred
            existing.updatedAt = now
            try existing.save(db)
        } else {
            let newState = ArticleStateRecord(
                itemID: itemID,
                isRead: false,
                isStarred: isStarred,
                dateArrived: now,
                updatedAt: now
            )
            try newState.save(db)
        }
    }

    /// 将特定 Feed、Folder 或全库的未读文章全部标记为已读
    public func markAllRead(
        accountID: String = "local-default",
        feedID: String? = nil,
        folderName: String? = nil,
        in db: Database
    ) throws {
        let now = Date().timeIntervalSince1970
        var whereSql = "i.account_id = ? AND s.is_read = 0"
        var args: [DatabaseValueConvertible] = [accountID]

        if let feedID {
            whereSql += " AND i.feed_id = ?"
            args.append(feedID)
        } else if let folderName {
            whereSql += """
             AND i.feed_id IN (
                SELECT ff.feed_id
                FROM feed_folders ff
                INNER JOIN folders fo ON fo.id = ff.folder_id
                WHERE fo.name = ? AND fo.is_deleted = 0
            )
            """
            args.append(folderName)
        }

        let selectItemIDsSql = """
        SELECT i.id
        FROM items i
        INNER JOIN article_states s ON s.item_id = i.id
        WHERE \(whereSql);
        """
        let unreadItemIDs = try String.fetchAll(db, sql: selectItemIDsSql, arguments: StatementArguments(args))
        guard !unreadItemIDs.isEmpty else { return }

        let updateSql = """
        UPDATE article_states
        SET is_read = 1, updated_at = ?
        WHERE item_id IN (
            SELECT i.id FROM items i INNER JOIN article_states s ON s.item_id = i.id WHERE \(whereSql)
        );
        """
        var updateArgs: [DatabaseValueConvertible] = [now]
        updateArgs.append(contentsOf: args)
        try db.execute(sql: updateSql, arguments: StatementArguments(updateArgs))
    }

    // MARK: - Database-Scoped Primitives (Article State Outbox)

    public func fetchPendingOutbox(accountID: String, in db: Database) throws -> [ArticleStateOutboxRecord] {
        try ArticleStateOutboxRecord
            .filter(Column("account_id") == accountID)
            .order(Column("updated_at").asc)
            .fetchAll(db)
    }

    public func fetchOutboxRecord(accountID: String, itemID: String, stateKey: String, in db: Database) throws -> ArticleStateOutboxRecord? {
        try ArticleStateOutboxRecord
            .filter(Column("account_id") == accountID && Column("item_id") == itemID && Column("state_key") == stateKey)
            .fetchOne(db)
    }

    public func saveOutbox(_ record: ArticleStateOutboxRecord, in db: Database) throws {
        try record.save(db)
    }

    public func deleteOutbox(accountID: String, itemID: String, stateKey: String, revision: Int, in db: Database) throws -> Bool {
        let deletedCount = try ArticleStateOutboxRecord
            .filter(
                Column("account_id") == accountID &&
                Column("item_id") == itemID &&
                Column("state_key") == stateKey &&
                Column("revision") == revision
            )
            .deleteAll(db)
        return deletedCount > 0
    }

    /// 在同一个事务中原子保存本地状态并更新 Outbox（INV-06 架构不变量）
    public func saveStateAndOutbox(
        state: ArticleStateRecord,
        outbox: ArticleStateOutboxRecord?,
        in db: Database
    ) throws {
        try saveState(state, in: db)
        if let outbox {
            try saveOutbox(outbox, in: db)
        }
    }

    // MARK: - Async Public APIs

    public func fetchState(itemID: String) async throws -> ArticleStateRecord? {
        try database.read { db in
            try fetchState(itemID: itemID, in: db)
        }
    }

    public func saveState(_ record: ArticleStateRecord) async throws {
        try database.write { db in
            try saveState(record, in: db)
        }
    }

    public func markRead(itemID: String, isRead: Bool) async throws {
        try database.write { db in
            try markRead(itemID: itemID, isRead: isRead, in: db)
        }
    }

    public func markRead(itemIDs: [String], isRead: Bool) async throws {
        try database.write { db in
            try markRead(itemIDs: itemIDs, isRead: isRead, in: db)
        }
    }

    public func markStarred(itemID: String, isStarred: Bool) async throws {
        try database.write { db in
            try markStarred(itemID: itemID, isStarred: isStarred, in: db)
        }
    }

    public func markAllRead(accountID: String = "local-default", feedID: String? = nil, folderName: String? = nil) async throws {
        try database.write { db in
            try markAllRead(accountID: accountID, feedID: feedID, folderName: folderName, in: db)
        }
    }

    public func saveStateAndOutbox(state: ArticleStateRecord, outbox: ArticleStateOutboxRecord?) async throws {
        try database.write { db in
            try saveStateAndOutbox(state: state, outbox: outbox, in: db)
        }
    }

    public func fetchPendingOutbox(accountID: String) async throws -> [ArticleStateOutboxRecord] {
        try database.read { db in
            try fetchPendingOutbox(accountID: accountID, in: db)
        }
    }

    public func deleteOutbox(accountID: String, itemID: String, stateKey: String, revision: Int) async throws -> Bool {
        try database.write { db in
            try deleteOutbox(accountID: accountID, itemID: itemID, stateKey: stateKey, revision: revision, in: db)
        }
    }
}
