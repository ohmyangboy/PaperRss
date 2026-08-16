import Foundation
import GRDB

/// 管理文章身份 (Item) 与文章内容正文 (Article) 的持久化仓库。
///
/// 遵循 Architecture Contract (Section 8.5, 8.6 / INV-03, INV-04, INV-05)。
public final class ArticleRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Database-Scoped Primitives (Items)

    public func fetchItem(id: String, in db: Database) throws -> ItemRecord? {
        try ItemRecord.filter(Column("id") == id).fetchOne(db)
    }

    public func fetchItemByRemoteIdentity(accountID: String, externalID: String, in db: Database) throws -> ItemRecord? {
        try ItemRecord
            .filter(Column("account_id") == accountID && Column("external_id") == externalID)
            .fetchOne(db)
    }

    public func fetchItems(feedID: String, in db: Database) throws -> [ItemRecord] {
        try ItemRecord
            .filter(Column("feed_id") == feedID)
            .order(Column("created_at").desc)
            .fetchAll(db)
    }

    public func saveItem(_ record: ItemRecord, in db: Database) throws {
        try record.save(db)
    }

    public func deleteItem(id: String, in db: Database) throws {
        _ = try ItemRecord.filter(Column("id") == id).deleteAll(db)
    }

    // MARK: - Database-Scoped Primitives (Articles)

    public func fetchArticle(itemID: String, in db: Database) throws -> ArticleRecord? {
        try ArticleRecord.filter(Column("item_id") == itemID).fetchOne(db)
    }

    public func saveArticle(_ record: ArticleRecord, in db: Database) throws {
        try record.save(db)
    }

    public func deleteArticle(itemID: String, in db: Database) throws {
        _ = try ArticleRecord.filter(Column("item_id") == itemID).deleteAll(db)
    }

    // MARK: - Entry Aggregation Primitives (Item + Article + State)

    public func fetchEntry(id: String, in db: Database) throws -> Entry? {
        let sql = """
        SELECT
            i.id AS entry_id,
            i.feed_id AS feed_id,
            COALESCE(a.title, '') AS title,
            a.author AS author,
            a.url AS url,
            a.published_at AS published_at,
            COALESCE(a.summary, '') AS summary,
            a.content_html AS content_html,
            COALESCE(s.is_read, 0) AS is_read,
            COALESCE(s.is_starred, 0) AS is_starred,
            COALESCE(s.updated_at, i.updated_at) AS updated_at
        FROM items i
        LEFT JOIN articles a ON a.item_id = i.id
        LEFT JOIN article_states s ON s.item_id = i.id
        WHERE i.id = ?;
        """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [id]) else { return nil }
        return entryFromRow(row)
    }

    public func fetchAllEntries(accountID: String = "local-default", in db: Database) throws -> [Entry] {
        let sql = """
        SELECT
            i.id AS entry_id,
            i.feed_id AS feed_id,
            COALESCE(a.title, '') AS title,
            a.author AS author,
            a.url AS url,
            a.published_at AS published_at,
            COALESCE(a.summary, '') AS summary,
            a.content_html AS content_html,
            COALESCE(s.is_read, 0) AS is_read,
            COALESCE(s.is_starred, 0) AS is_starred,
            COALESCE(s.updated_at, i.updated_at) AS updated_at
        FROM items i
        INNER JOIN feeds f ON f.id = i.feed_id
        LEFT JOIN articles a ON a.item_id = i.id
        LEFT JOIN article_states s ON s.item_id = i.id
        WHERE i.account_id = ? AND f.is_deleted = 0
        ORDER BY COALESCE(a.published_at, i.created_at) DESC, i.id DESC;
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [accountID])
        return rows.compactMap { entryFromRow($0) }
    }

    /// 高性能增量入库：合并解析得到的文章列表，避免 O(n×m) Swift 遍历。
    /// 返回本次新插入且当前为未读的 Entry 列表。
    public func mergeParsedEntries(
        accountID: String = "local-default",
        feedID: String,
        parsedEntries: [ParsedFeedEntry],
        in db: Database
    ) throws -> [Entry] {
        let now = Date().timeIntervalSince1970
        var newUnreadEntries: [Entry] = []

        for parsed in parsedEntries {
            let itemID = "\(feedID)|\(parsed.id)".stableDigest
            let existingItem = try ItemRecord.filter(Column("id") == itemID).fetchOne(db)

            if existingItem == nil {
                // 1. 新条目
                let item = ItemRecord(
                    id: itemID,
                    accountID: accountID,
                    externalID: parsed.id,
                    feedID: feedID,
                    createdAt: now,
                    updatedAt: now
                )
                try item.save(db)

                let article = ArticleRecord(
                    itemID: itemID,
                    title: parsed.title,
                    author: parsed.author,
                    url: parsed.url?.absoluteString,
                    publishedAt: parsed.publishedAt?.timeIntervalSince1970,
                    summary: parsed.summary.plainText,
                    contentHTML: parsed.contentHTML,
                    contentUpdatedAt: now
                )
                try article.save(db)

                let state = ArticleStateRecord(
                    itemID: itemID,
                    isRead: false,
                    isStarred: false,
                    dateArrived: now,
                    updatedAt: now
                )
                try state.save(db)

                guard let feedUUID = UUID(uuidString: feedID) else { continue }
                let newEntry = Entry(
                    id: itemID,
                    feedID: feedUUID,
                    title: parsed.title,
                    author: parsed.author,
                    url: parsed.url,
                    publishedAt: parsed.publishedAt,
                    summary: parsed.summary.plainText,
                    contentHTML: parsed.contentHTML,
                    isRead: false,
                    isStarred: false,
                    updatedAt: Date(timeIntervalSince1970: now)
                )
                newUnreadEntries.append(newEntry)
            } else {
                // 2. 已有条目：仅在内容发生改变时更新 Article 正文
                if let existingArticle = try ArticleRecord.filter(Column("item_id") == itemID).fetchOne(db) {
                    var needsUpdate = false
                    var updatedArticle = existingArticle
                    if updatedArticle.title != parsed.title {
                        updatedArticle.title = parsed.title
                        needsUpdate = true
                    }
                    if let parsedAuthor = parsed.author, updatedArticle.author != parsedAuthor {
                        updatedArticle.author = parsedAuthor
                        needsUpdate = true
                    }
                    if let parsedHTML = parsed.contentHTML, updatedArticle.contentHTML != parsedHTML {
                        updatedArticle.contentHTML = parsedHTML
                        needsUpdate = true
                    }
                    if needsUpdate {
                        updatedArticle.contentUpdatedAt = now
                        try updatedArticle.save(db)
                    }
                }
            }
        }

        return newUnreadEntries
    }

    private func entryFromRow(_ row: Row) -> Entry? {
        guard let id: String = row["entry_id"],
              let feedIDString: String = row["feed_id"],
              let feedUUID = UUID(uuidString: feedIDString) else { return nil }

        let title: String = row["title"]
        let author: String? = row["author"]
        let urlString: String? = row["url"]
        let url = urlString.flatMap { URL(string: $0) }
        let publishedAtTimestamp: Double? = row["published_at"]
        let publishedAt = publishedAtTimestamp.map { Date(timeIntervalSince1970: $0) }
        let summary: String = row["summary"]
        let contentHTML: String? = row["content_html"]
        let isReadInt: Int = row["is_read"]
        let isStarredInt: Int = row["is_starred"]
        let updatedAtTimestamp: Double = row["updated_at"]
        let updatedAt = Date(timeIntervalSince1970: updatedAtTimestamp)

        return Entry(
            id: id,
            feedID: feedUUID,
            title: title,
            author: author,
            url: url,
            publishedAt: publishedAt,
            summary: summary,
            contentHTML: contentHTML,
            isRead: isReadInt == 1,
            isStarred: isStarredInt == 1,
            updatedAt: updatedAt
        )
    }

    // MARK: - Async Public APIs

    public func fetchEntry(id: String) async throws -> Entry? {
        try database.read { db in
            try fetchEntry(id: id, in: db)
        }
    }

    public func fetchAllEntries(accountID: String = "local-default") async throws -> [Entry] {
        try database.read { db in
            try fetchAllEntries(accountID: accountID, in: db)
        }
    }

    public func mergeParsedEntries(
        accountID: String = "local-default",
        feedID: String,
        parsedEntries: [ParsedFeedEntry]
    ) async throws -> [Entry] {
        try database.write { db in
            try mergeParsedEntries(accountID: accountID, feedID: feedID, parsedEntries: parsedEntries, in: db)
        }
    }

    public func fetchItem(id: String) async throws -> ItemRecord? {
        try database.read { db in
            try fetchItem(id: id, in: db)
        }
    }

    public func fetchItemByRemoteIdentity(accountID: String, externalID: String) async throws -> ItemRecord? {
        try database.read { db in
            try fetchItemByRemoteIdentity(accountID: accountID, externalID: externalID, in: db)
        }
    }

    public func saveItem(_ record: ItemRecord) async throws {
        try database.write { db in
            try saveItem(record, in: db)
        }
    }

    public func deleteItem(id: String) async throws {
        try database.write { db in
            try deleteItem(id: id, in: db)
        }
    }

    public func fetchArticle(itemID: String) async throws -> ArticleRecord? {
        try database.read { db in
            try fetchArticle(itemID: itemID, in: db)
        }
    }

    public func saveArticle(_ record: ArticleRecord) async throws {
        try database.write { db in
            try saveArticle(record, in: db)
        }
    }
}
