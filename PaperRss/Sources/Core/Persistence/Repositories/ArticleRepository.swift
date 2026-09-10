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
        INNER JOIN articles a ON a.item_id = i.id
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
        INNER JOIN articles a ON a.item_id = i.id
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
            try AutoTranslationRepository.saveHints(parsed.languageHints, scope: "article", id: itemID, in: db)
            let existingItem = try ItemRecord.filter(Column("id") == itemID).fetchOne(db)

            if existingItem == nil {
                // 1. 新条目
                let item = ItemRecord(
                    id: itemID,
                    accountID: accountID,
                    externalID: itemID,
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
                // 2. 已有条目：仅在内容发生改变时更新 Article 正文；正文被清理时执行回填恢复
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
                    let parsedSummary = parsed.summary.plainText
                    if !parsedSummary.isEmpty && updatedArticle.summary != parsedSummary {
                        updatedArticle.summary = parsedSummary
                        needsUpdate = true
                    }
                    if let parsedURL = parsed.url?.absoluteString, updatedArticle.url != parsedURL {
                        updatedArticle.url = parsedURL
                        needsUpdate = true
                    }
                    if needsUpdate {
                        updatedArticle.contentUpdatedAt = now
                        try updatedArticle.save(db)
                    }
                } else {
                    // 正文曾被清理淘汰（existingArticle == nil），源站 XML 依然包含该条目，执行正文回填恢复
                    let restoredArticle = ArticleRecord(
                        itemID: itemID,
                        title: parsed.title,
                        author: parsed.author,
                        url: parsed.url?.absoluteString,
                        publishedAt: parsed.publishedAt?.timeIntervalSince1970,
                        summary: parsed.summary.plainText,
                        contentHTML: parsed.contentHTML,
                        contentUpdatedAt: now
                    )
                    try restoredArticle.save(db)
                    // 保持 article_states 状态不变（is_read 保持原有值，不增加未读数，不加入 newUnreadEntries）
                    if try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db) == nil {
                        let fallbackState = ArticleStateRecord(
                            itemID: itemID,
                            isRead: true,
                            isStarred: false,
                            dateArrived: now,
                            updatedAt: now
                        )
                        try fallbackState.save(db)
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

    // MARK: - Cleanup & Retention

    /// 清理早于截止日期的已读且未标星文章（正文、离线网页缓存与 AI 衍生数据）。
    ///
    /// 遵循墓碑模型（Tombstone Preservation，对齐 NetNewsWire）：
    /// - 仅物理删除 articles、article_caches、ai_artifacts；
    /// - 严格保留 items（身份）与 article_states（is_read = 1），防止老文章再次刷新时幽灵复活。
    /// - 采用阶梯式限时清理与分批执行，单次事务最多执行 maxDuration 秒（默认 2.0s），防止长时间排他锁库导致 UI 冻结。
    /// - 返回本次实际清理的文章篇数。
    public func purgeOldReadArticles(
        cutoffDate: Date,
        maxDuration: TimeInterval = 2.0,
        in db: Database
    ) throws -> Int {
        let now = Date()
        let calendar = Calendar.current
        let targetDays = max(0, calendar.dateComponents([.day], from: cutoffDate, to: now).day ?? 0)

        // 阶梯式步长（由远及近）：优先清理远古老文章
        let candidateIntervals = [365, 270, 180, 120, 90, 60]
        let ladder = candidateIntervals.filter { $0 > targetDays }

        let startTime = Date()
        func tooMuchTimeHasPassed() -> Bool {
            Date().timeIntervalSince(startTime) > maxDuration
        }

        var totalDeleted = 0
        let batchLimit = 500

        func purgeBatch(stepCutoff: Date) throws -> Int {
            let cutoffTimestamp = stepCutoff.timeIntervalSince1970
            let sql = """
            SELECT a.item_id
            FROM articles a
            INNER JOIN article_states s ON s.item_id = a.item_id
            INNER JOIN items i ON i.id = a.item_id
            WHERE s.is_read = 1
              AND s.is_starred = 0
              AND (s.date_arrived < ? OR (s.date_arrived IS NULL AND i.created_at < ?))
            LIMIT ?;
            """
            var stepDeleted = 0
            while !tooMuchTimeHasPassed() {
                let itemIDs = try String.fetchAll(db, sql: sql, arguments: [cutoffTimestamp, cutoffTimestamp, batchLimit])
                if itemIDs.isEmpty {
                    break
                }
                let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
                let args = StatementArguments(itemIDs)

                try db.execute(sql: "DELETE FROM article_caches WHERE item_id IN (\(placeholders));", arguments: args)
                try db.execute(sql: "DELETE FROM ai_artifacts WHERE item_id IN (\(placeholders));", arguments: args)
                try db.execute(sql: "DELETE FROM articles WHERE item_id IN (\(placeholders));", arguments: args)

                stepDeleted += itemIDs.count
                if itemIDs.count < batchLimit {
                    break
                }
            }
            return stepDeleted
        }

        for interval in ladder {
            guard let stepCutoff = calendar.date(byAdding: .day, value: -interval, to: now) else { continue }
            totalDeleted += try purgeBatch(stepCutoff: stepCutoff)
            if tooMuchTimeHasPassed() {
                return totalDeleted
            }
        }

        if !tooMuchTimeHasPassed() {
            totalDeleted += try purgeBatch(stepCutoff: cutoffDate)
        }

        return totalDeleted
    }

    /// 清理超远期孤立墓碑（仅在 items 与 article_states 存在，但 articles 正文已被清理，且时间早于 cutoffDate）。
    ///
    /// 仅清理已读且未标星的墓碑条目。同样受 maxDuration 耗时保护（默认 2.0s）。返回清理的条目数。
    public func purgeExpiredTombstones(
        cutoffDate: Date,
        maxDuration: TimeInterval = 2.0,
        batchLimit: Int = 500,
        in db: Database
    ) throws -> Int {
        let startTime = Date()
        func tooMuchTimeHasPassed() -> Bool {
            Date().timeIntervalSince(startTime) > maxDuration
        }

        let cutoffTimestamp = cutoffDate.timeIntervalSince1970
        let sql = """
        SELECT i.id
        FROM items i
        LEFT JOIN articles a ON a.item_id = i.id
        LEFT JOIN article_states s ON s.item_id = i.id
        WHERE a.item_id IS NULL
          AND (s.date_arrived < ? OR (s.date_arrived IS NULL AND i.created_at < ?))
          AND COALESCE(s.is_read, 1) = 1
          AND COALESCE(s.is_starred, 0) = 0
        LIMIT ?;
        """
        var totalDeleted = 0
        while !tooMuchTimeHasPassed() {
            let itemIDs = try String.fetchAll(db, sql: sql, arguments: [cutoffTimestamp, cutoffTimestamp, batchLimit])
            if itemIDs.isEmpty {
                break
            }
            let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
            let args = StatementArguments(itemIDs)

            try db.execute(sql: "DELETE FROM article_states WHERE item_id IN (\(placeholders));", arguments: args)
            try db.execute(sql: "DELETE FROM items WHERE id IN (\(placeholders));", arguments: args)

            totalDeleted += itemIDs.count
            if itemIDs.count < batchLimit {
                break
            }
        }
        return totalDeleted
    }

    public func purgeOldReadArticles(cutoffDate: Date, maxDuration: TimeInterval = 2.0) async throws -> Int {
        try database.write { db in
            try self.purgeOldReadArticles(cutoffDate: cutoffDate, maxDuration: maxDuration, in: db)
        }
    }

    public func purgeExpiredTombstones(cutoffDate: Date, maxDuration: TimeInterval = 2.0) async throws -> Int {
        try database.write { db in
            try self.purgeExpiredTombstones(cutoffDate: cutoffDate, maxDuration: maxDuration, in: db)
        }
    }
}
