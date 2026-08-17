import Foundation
import GRDB

/// Timeline 查询作用域。
public enum TimelineScope: Sendable, Equatable, Hashable {
    case all
    case today(startOfDayTimestamp: Double)
    case unread
    case starred
    case feed(feedID: String)
    case feeds(feedIDs: Set<String>)
    case folder(accountID: String, folderName: String)

    /// 兼容便捷初始化
    public static func folder(folderName: String) -> TimelineScope {
        .folder(accountID: "local-default", folderName: folderName)
    }
}

/// Sidebar 计数聚合 DTO。
public struct SidebarCounts: Sendable, Equatable {
    public var allUnread: Int
    public var todayUnread: Int
    public var starred: Int
    public var unreadByFeed: [UUID: Int]
    public var unreadByFolder: [String: Int]

    public var globalUnread: Int { allUnread }

    public init(
        allUnread: Int = 0,
        todayUnread: Int = 0,
        starred: Int = 0,
        unreadByFeed: [UUID: Int] = [:],
        unreadByFolder: [String: Int] = [:]
    ) {
        self.allUnread = allUnread
        self.todayUnread = todayUnread
        self.starred = starred
        self.unreadByFeed = unreadByFeed
        self.unreadByFolder = unreadByFolder
    }

    public func unreadCount(folder: String, accountID: String = "local-default") -> Int {
        if let count = unreadByFolder["\(accountID)::\(folder)"] {
            return count
        }
        return unreadByFolder[folder] ?? 0
    }
}

/// 提供针对 Sidebar 与 Timeline 列表的高性能 Query-First 聚合与投影服务。
///
/// 遵循 Architecture Contract (DA-08 / Section 14, 23)：
/// - 纯 SQL 聚合与关联投影，不物化全量 `content_html`、`article_caches`、`ai_artifacts`；
/// - 杜绝 O(n) 全库 Swift 过滤与排序。
public final class TimelineQueryService: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Sidebar Counts (Pure SQL Aggregation)

    public func fetchSidebarCounts(
        accountID: String? = nil,
        startOfDayTimestamp: Double
    ) throws -> SidebarCounts {
        try database.read { db in
            try fetchSidebarCounts(accountID: accountID, startOfDayTimestamp: startOfDayTimestamp, in: db)
        }
    }

    public func fetchSidebarCounts(
        accountID: String? = nil,
        startOfDayTimestamp: Double,
        in db: Database
    ) throws -> SidebarCounts {
        let accountWhere = accountID != nil ? "AND i.account_id = :account_id" : "AND (acc.is_enabled = 1 OR acc.id IS NULL)"
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        if let accountID {
            arguments["account_id"] = accountID
        }

        // 1. 全局未读数
        let allUnreadSql = """
        SELECT COUNT(*)
        FROM items i
        INNER JOIN article_states s ON s.item_id = i.id
        INNER JOIN feeds f ON f.id = i.feed_id
        LEFT JOIN accounts acc ON acc.id = i.account_id
        WHERE f.is_deleted = 0 AND s.is_read = 0 \(accountWhere);
        """
        let allUnread = try Int.fetchOne(db, sql: allUnreadSql, arguments: StatementArguments(arguments)) ?? 0

        // 2. 今日未读数 (基于 articles.published_at 或 items.created_at)
        var todayArgs = arguments
        todayArgs["start_of_day"] = startOfDayTimestamp
        let todayUnreadSql = """
        SELECT COUNT(*)
        FROM items i
        INNER JOIN article_states s ON s.item_id = i.id
        INNER JOIN articles a ON a.item_id = i.id
        INNER JOIN feeds f ON f.id = i.feed_id
        LEFT JOIN accounts acc ON acc.id = i.account_id
        WHERE f.is_deleted = 0 AND s.is_read = 0 \(accountWhere)
          AND (a.published_at >= :start_of_day OR (a.published_at IS NULL AND i.created_at >= :start_of_day));
        """
        let todayUnread = try Int.fetchOne(
            db,
            sql: todayUnreadSql,
            arguments: StatementArguments(todayArgs)
        ) ?? 0

        // 3. 星标数
        let starredSql = """
        SELECT COUNT(*)
        FROM items i
        INNER JOIN article_states s ON s.item_id = i.id
        INNER JOIN feeds f ON f.id = i.feed_id
        LEFT JOIN accounts acc ON acc.id = i.account_id
        WHERE f.is_deleted = 0 AND s.is_starred = 1 \(accountWhere);
        """
        let starred = try Int.fetchOne(db, sql: starredSql, arguments: StatementArguments(arguments)) ?? 0

        // 4. 按 Feed 统计未读数
        let feedUnreadSql = """
        SELECT i.feed_id, COUNT(*) AS unread_count
        FROM items i
        INNER JOIN article_states s ON s.item_id = i.id
        INNER JOIN feeds f ON f.id = i.feed_id
        LEFT JOIN accounts acc ON acc.id = i.account_id
        WHERE f.is_deleted = 0 AND s.is_read = 0 \(accountWhere)
        GROUP BY i.feed_id;
        """
        let feedRows = try Row.fetchAll(db, sql: feedUnreadSql, arguments: StatementArguments(arguments))
        var unreadByFeed: [UUID: Int] = [:]
        for row in feedRows {
            if let feedIDString: String = row["feed_id"], let uuid = UUID(uuidString: feedIDString) {
                let count: Int = row["unread_count"]
                unreadByFeed[uuid] = count
            }
        }

        // 5. 按 Folder 统计未读数 (支持多账号隔离统计)
        let folderUnreadSql = """
        SELECT fo.account_id AS account_id, fo.name AS folder_name, COUNT(DISTINCT i.id) AS unread_count
        FROM items i
        INNER JOIN article_states s ON s.item_id = i.id
        INNER JOIN feeds f ON f.id = i.feed_id
        INNER JOIN feed_folders ff ON ff.feed_id = f.id
        INNER JOIN folders fo ON fo.id = ff.folder_id
        LEFT JOIN accounts acc ON acc.id = i.account_id
        WHERE f.is_deleted = 0 AND fo.is_deleted = 0 AND s.is_read = 0 \(accountWhere)
        GROUP BY fo.account_id, fo.name;
        """
        let folderRows = try Row.fetchAll(db, sql: folderUnreadSql, arguments: StatementArguments(arguments))
        var unreadByFolder: [String: Int] = [:]
        for row in folderRows {
            let accID: String = row["account_id"]
            let folderName: String = row["folder_name"]
            let count: Int = row["unread_count"]
            unreadByFolder["\(accID)::\(folderName)"] = count
            unreadByFolder[folderName] = count
        }

        return SidebarCounts(
            allUnread: allUnread,
            todayUnread: todayUnread,
            starred: starred,
            unreadByFeed: unreadByFeed,
            unreadByFolder: unreadByFolder
        )
    }

    // MARK: - Timeline List Items (Bounded Projection Query)

    public func fetchListItems(
        accountID: String? = nil,
        scope: TimelineScope,
        retainingIDs: Set<String> = [],
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EntryListItem] {
        try database.read { db in
            try fetchListItems(accountID: accountID, scope: scope, retainingIDs: retainingIDs, limit: limit, offset: offset, in: db)
        }
    }

    public func fetchListItems(
        accountID: String? = nil,
        scope: TimelineScope,
        retainingIDs: Set<String> = [],
        limit: Int? = nil,
        offset: Int = 0,
        in db: Database
    ) throws -> [EntryListItem] {
        var whereClauses = ["f.is_deleted = 0"]
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        if let accountID {
            whereClauses.append("i.account_id = :account_id")
            arguments["account_id"] = accountID
        } else {
            whereClauses.append("(acc.is_enabled = 1 OR acc.id IS NULL)")
        }

        switch scope {
        case .all:
            break
        case .today(let startOfDay):
            whereClauses.append("(a.published_at >= :start_of_day OR (a.published_at IS NULL AND i.created_at >= :start_of_day))")
            arguments["start_of_day"] = startOfDay
        case .unread:
            if retainingIDs.isEmpty {
                whereClauses.append("s.is_read = 0")
            } else {
                let placeholders = retainingIDs.enumerated().map { idx, id -> String in
                    let param = "ret_unread_\(idx)"
                    arguments[param] = id
                    return ":\(param)"
                }.joined(separator: ", ")
                whereClauses.append("(s.is_read = 0 OR i.id IN (\(placeholders)))")
            }
        case .starred:
            if retainingIDs.isEmpty {
                whereClauses.append("s.is_starred = 1")
            } else {
                let placeholders = retainingIDs.enumerated().map { idx, id -> String in
                    let param = "ret_starred_\(idx)"
                    arguments[param] = id
                    return ":\(param)"
                }.joined(separator: ", ")
                whereClauses.append("(s.is_starred = 1 OR i.id IN (\(placeholders)))")
            }
        case .feed(let feedID):
            whereClauses.append("i.feed_id = :feed_id")
            arguments["feed_id"] = feedID
        case .feeds(let feedIDs):
            if feedIDs.isEmpty {
                whereClauses.append("1 = 0")
            } else {
                let placeholders = feedIDs.enumerated().map { idx, id -> String in
                    let param = "feed_id_\(idx)"
                    arguments[param] = id
                    return ":\(param)"
                }.joined(separator: ", ")
                whereClauses.append("i.feed_id IN (\(placeholders))")
            }
        case .folder(let folderAccID, let folderName):
            whereClauses.append("i.account_id = :folder_acc_id")
            whereClauses.append("""
            i.feed_id IN (
                SELECT ff.feed_id
                FROM feed_folders ff
                INNER JOIN folders fo ON fo.id = ff.folder_id
                WHERE fo.account_id = :folder_acc_id AND fo.name = :folder_name AND fo.is_deleted = 0
            )
            """)
            arguments["folder_acc_id"] = folderAccID
            arguments["folder_name"] = folderName
        }

        var sql = """
        SELECT
            i.id AS entry_id,
            i.feed_id AS feed_id,
            i.account_id AS account_id,
            COALESCE(acc.type, 'local') AS account_type,
            COALESCE(acc.display_name, 'Local') AS account_display_name,
            COALESCE(a.title, '') AS title,
            a.url AS url,
            COALESCE(a.summary, '') AS summary,
            f.title AS feed_title,
            f.stored_icon_url AS stored_icon_url,
            f.site_url AS site_url,
            f.feed_url AS feed_url,
            a.published_at AS published_at,
            COALESCE(s.is_read, 0) AS is_read,
            COALESCE(s.is_starred, 0) AS is_starred
        FROM items i
        INNER JOIN feeds f ON f.id = i.feed_id
        LEFT JOIN accounts acc ON acc.id = i.account_id
        LEFT JOIN articles a ON a.item_id = i.id
        LEFT JOIN article_states s ON s.item_id = i.id
        WHERE \(whereClauses.joined(separator: " AND "))
        ORDER BY COALESCE(a.published_at, i.created_at) DESC, i.id DESC
        """

        if let limit {
            sql += " LIMIT \(limit) OFFSET \(offset)"
        }

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        return rows.compactMap { row -> EntryListItem? in
            guard let id: String = row["entry_id"],
                  let feedIDString: String = row["feed_id"],
                  let feedUUID = UUID(uuidString: feedIDString) else { return nil }

            let title: String = row["title"]
            let urlString: String? = row["url"]
            let url = urlString.flatMap { URL(string: $0) }
            let summary: String = row["summary"]
            let preview = String(summary.prefix(240))
            let sourceTitle: String = row["feed_title"]
            let storedIconURLString: String? = row["stored_icon_url"]
            let siteURLString: String? = row["site_url"]
            let feedURLString: String = row["feed_url"]

            // 派生 iconURL
            let iconURL = Self.resolveIconURL(
                storedIconURLString: storedIconURLString,
                siteURLString: siteURLString,
                feedURLString: feedURLString
            )

            let publishedAtTimestamp: Double? = row["published_at"]
            let publishedAt = publishedAtTimestamp.map { Date(timeIntervalSince1970: $0) }
            let isReadInt: Int = row["is_read"]
            let isStarredInt: Int = row["is_starred"]
            let accountID: String = row["account_id"] ?? "local-default"
            let accountType: String = row["account_type"] ?? AccountType.local.rawValue
            let accountDisplayName: String = row["account_display_name"] ?? "Local"

            return EntryListItem(
                id: id,
                feedID: feedUUID,
                title: title,
                url: url,
                summaryPreview: preview,
                sourceTitle: sourceTitle,
                feedIconURL: iconURL,
                publishedAt: publishedAt,
                isRead: isReadInt == 1,
                isStarred: isStarredInt == 1,
                accountID: accountID,
                accountType: accountType,
                accountDisplayName: accountDisplayName
            )
        }
    }

    // MARK: - Adjacent Item Query (O(1) Bounded Navigation)

    public func fetchAdjacentItem(
        accountID: String? = nil,
        scope: TimelineScope,
        currentItemID: String,
        direction: AdjacentTimelineDirection,
        retainingIDs: Set<String> = []
    ) throws -> EntryListItem? {
        try database.read { db in
            try fetchAdjacentItem(
                accountID: accountID,
                scope: scope,
                currentItemID: currentItemID,
                direction: direction,
                retainingIDs: retainingIDs,
                in: db
            )
        }
    }

    public func fetchAdjacentItem(
        accountID: String? = nil,
        scope: TimelineScope,
        currentItemID: String,
        direction: AdjacentTimelineDirection,
        retainingIDs: Set<String> = [],
        in db: Database
    ) throws -> EntryListItem? {
        // 1. 获取当前文章的排序基准 (published_at 或 created_at)
        let curSql = """
        SELECT COALESCE(a.published_at, i.created_at) AS sort_time
        FROM items i
        LEFT JOIN articles a ON a.item_id = i.id
        WHERE i.id = :cur_id
        LIMIT 1;
        """
        guard let curRow = try Row.fetchOne(db, sql: curSql, arguments: ["cur_id": currentItemID]),
              let curSortTime: Double = curRow["sort_time"] else {
            return nil
        }

        // 2. 构造与 fetchListItems 完全一致的 Scope 过滤条件
        var whereClauses = ["f.is_deleted = 0"]
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        if let accountID {
            whereClauses.append("i.account_id = :account_id")
            arguments["account_id"] = accountID
        } else {
            whereClauses.append("(acc.is_enabled = 1 OR acc.id IS NULL)")
        }

        switch scope {
        case .all:
            break
        case .today(let startOfDay):
            whereClauses.append("(a.published_at >= :start_of_day OR (a.published_at IS NULL AND i.created_at >= :start_of_day))")
            arguments["start_of_day"] = startOfDay
        case .unread:
            if retainingIDs.isEmpty {
                whereClauses.append("s.is_read = 0")
            } else {
                let placeholders = retainingIDs.enumerated().map { idx, id -> String in
                    let param = "ret_unread_\(idx)"
                    arguments[param] = id
                    return ":\(param)"
                }.joined(separator: ", ")
                whereClauses.append("(s.is_read = 0 OR i.id IN (\(placeholders)))")
            }
        case .starred:
            if retainingIDs.isEmpty {
                whereClauses.append("s.is_starred = 1")
            } else {
                let placeholders = retainingIDs.enumerated().map { idx, id -> String in
                    let param = "ret_starred_\(idx)"
                    arguments[param] = id
                    return ":\(param)"
                }.joined(separator: ", ")
                whereClauses.append("(s.is_starred = 1 OR i.id IN (\(placeholders)))")
            }
        case .feed(let feedID):
            whereClauses.append("i.feed_id = :feed_id")
            arguments["feed_id"] = feedID
        case .feeds(let feedIDs):
            if feedIDs.isEmpty {
                whereClauses.append("1 = 0")
            } else {
                let placeholders = feedIDs.enumerated().map { idx, id -> String in
                    let param = "feed_id_\(idx)"
                    arguments[param] = id
                    return ":\(param)"
                }.joined(separator: ", ")
                whereClauses.append("i.feed_id IN (\(placeholders))")
            }
        case .folder(let folderAccID, let folderName):
            whereClauses.append("i.account_id = :folder_acc_id")
            whereClauses.append("""
            i.feed_id IN (
                SELECT ff.feed_id
                FROM feed_folders ff
                INNER JOIN folders fo ON fo.id = ff.folder_id
                WHERE fo.account_id = :folder_acc_id AND fo.name = :folder_name AND fo.is_deleted = 0
            )
            """)
            arguments["folder_acc_id"] = folderAccID
            arguments["folder_name"] = folderName
        }

        arguments["cur_id"] = currentItemID
        arguments["cur_sort_time"] = curSortTime

        // 3. 根据方向添加比较条件和排序
        let orderClause: String
        switch direction {
        case .next:
            // 下一篇：更旧的文章 (sort_time 较小，或同时间 id 较小)
            whereClauses.append("(COALESCE(a.published_at, i.created_at) < :cur_sort_time OR (COALESCE(a.published_at, i.created_at) = :cur_sort_time AND i.id < :cur_id))")
            orderClause = "ORDER BY COALESCE(a.published_at, i.created_at) DESC, i.id DESC"
        case .previous:
            // 上一篇：更新的文章 (sort_time 较大，或同时间 id 较大)
            whereClauses.append("(COALESCE(a.published_at, i.created_at) > :cur_sort_time OR (COALESCE(a.published_at, i.created_at) = :cur_sort_time AND i.id > :cur_id))")
            orderClause = "ORDER BY COALESCE(a.published_at, i.created_at) ASC, i.id ASC"
        }

        let sql = """
        SELECT
            i.id AS entry_id,
            i.feed_id AS feed_id,
            i.account_id AS account_id,
            COALESCE(acc.type, 'local') AS account_type,
            COALESCE(acc.display_name, 'Local') AS account_display_name,
            COALESCE(a.title, '') AS title,
            a.url AS url,
            COALESCE(a.summary, '') AS summary,
            f.title AS feed_title,
            f.stored_icon_url AS stored_icon_url,
            f.site_url AS site_url,
            f.feed_url AS feed_url,
            a.published_at AS published_at,
            COALESCE(s.is_read, 0) AS is_read,
            COALESCE(s.is_starred, 0) AS is_starred
        FROM items i
        INNER JOIN feeds f ON f.id = i.feed_id
        LEFT JOIN accounts acc ON acc.id = i.account_id
        LEFT JOIN articles a ON a.item_id = i.id
        LEFT JOIN article_states s ON s.item_id = i.id
        WHERE \(whereClauses.joined(separator: " AND "))
        \(orderClause)
        LIMIT 1;
        """

        guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) else {
            return nil
        }

        guard let id: String = row["entry_id"],
              let feedIDString: String = row["feed_id"],
              let feedUUID = UUID(uuidString: feedIDString) else { return nil }

        let title: String = row["title"]
        let urlString: String? = row["url"]
        let url = urlString.flatMap { URL(string: $0) }
        let summary: String = row["summary"]
        let preview = String(summary.prefix(240))
        let sourceTitle: String = row["feed_title"]
        let storedIconURLString: String? = row["stored_icon_url"]
        let siteURLString: String? = row["site_url"]
        let feedURLString: String = row["feed_url"]

        let iconURL = Self.resolveIconURL(
            storedIconURLString: storedIconURLString,
            siteURLString: siteURLString,
            feedURLString: feedURLString
        )

        let publishedAtTimestamp: Double? = row["published_at"]
        let publishedAt = publishedAtTimestamp.map { Date(timeIntervalSince1970: $0) }
        let isReadInt: Int = row["is_read"]
        let isStarredInt: Int = row["is_starred"]
        let rowAccountID: String = row["account_id"] ?? "local-default"
        let accountType: String = row["account_type"] ?? AccountType.local.rawValue
        let accountDisplayName: String = row["account_display_name"] ?? "Local"

        return EntryListItem(
            id: id,
            feedID: feedUUID,
            title: title,
            url: url,
            summaryPreview: preview,
            sourceTitle: sourceTitle,
            feedIconURL: iconURL,
            publishedAt: publishedAt,
            isRead: isReadInt == 1,
            isStarred: isStarredInt == 1,
            accountID: rowAccountID,
            accountType: accountType,
            accountDisplayName: accountDisplayName
        )
    }

    private static func resolveIconURL(
        storedIconURLString: String?,
        siteURLString: String?,
        feedURLString: String
    ) -> URL? {
        if let storedIconURLString, let url = URL(string: storedIconURLString) {
            return url
        }
        let siteHost = siteURLString.flatMap { URL(string: $0)?.host }
        let feedHost = URL(string: feedURLString)?.host
        guard let host = (siteHost ?? feedHost)?.lowercased() else { return nil }

        let feedPath = URL(string: feedURLString)?.path.lowercased() ?? ""
        if host.contains("twitter.com") || host.contains("x.com") || feedPath.contains("/twitter/") || feedPath.hasPrefix("/twitter") || feedPath.contains("/x/") {
            return URL(string: "https://abs.twimg.com/favicons/twitter.3.ico")
        }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }
}

public enum AdjacentTimelineDirection: Sendable {
    case previous
    case next
}
