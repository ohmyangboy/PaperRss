import Foundation
import GRDB

/// FreshRSS 账号提供者。
///
/// 遵循 Architecture Contract (Section 7.2, 16, 17 / INV-04, INV-06, INV-07, INV-08, INV-11)。
/// 实现基于 Google Reader API 的订阅拉取、文章增量同步、双向状态调和与离线突变出站。
public actor FreshRSSAccountProvider: AccountProvider {
    public let accountID: String
    private let database: LibraryDatabase
    private let credentialStore: CredentialStore
    private let apiClient: ReaderAPIClient
    private let outboxProcessor: ArticleStateOutboxProcessor

    public init(
        accountID: String,
        endpointURL: URL,
        username: String,
        database: LibraryDatabase,
        credentialStore: CredentialStore,
        session: URLSession = .shared
    ) {
        self.accountID = accountID
        self.database = database
        self.credentialStore = credentialStore
        self.apiClient = ReaderAPIClient(
            endpointURL: endpointURL,
            username: username,
            accountID: accountID,
            credentialStore: credentialStore,
            session: session
        )
        self.outboxProcessor = ArticleStateOutboxProcessor(
            accountID: accountID,
            database: database,
            apiClient: apiClient
        )
    }

    public init(
        accountID: String,
        database: LibraryDatabase,
        credentialStore: CredentialStore,
        apiClient: ReaderAPIClient
    ) {
        self.accountID = accountID
        self.database = database
        self.credentialStore = credentialStore
        self.apiClient = apiClient
        self.outboxProcessor = ArticleStateOutboxProcessor(
            accountID: accountID,
            database: database,
            apiClient: apiClient
        )
    }

    // MARK: - AccountProvider Protocol

    public func refresh(reason: RefreshReason) async throws -> RefreshResult {
        let now = Date().timeIntervalSince1970
        await markSyncStarted(timestamp: now)

        do {
            // 1. 先尝试将本地离线修改写回远端
            _ = try await outboxProcessor.processOutbox()

            // 2. 拉取远端订阅源与分类目录
            try await syncSubscriptionsAndFolders()

            // 3. 拉取文章与阅读/星标状态，并执行字段级状态调和
            try await syncArticlesAndStates()

            // 4. 同步完成后若有未结 outbox 再次推进
            _ = try await outboxProcessor.processOutbox()

            await markSyncCompleted(timestamp: Date().timeIntervalSince1970)
            return RefreshResult(status: .success)
        } catch {
            let errorMsg = error.localizedDescription
            await markSyncFailed(timestamp: Date().timeIntervalSince1970, error: errorMsg)
            throw error
        }
    }

    public func pushPendingArticleStates() async throws {
        _ = try await outboxProcessor.processOutbox(forceAll: true)
    }

    // MARK: - Subscriptions & Folders Sync

    public func syncSubscriptionsAndFolders() async throws {
        let subscriptions = try await apiClient.fetchSubscriptions()
        let tags = (try? await apiClient.fetchTags()) ?? []

        let now = Date().timeIntervalSince1970

        try database.write { db in
            // 1. 整理全部有效分类目录
            var categoryNames = Set<String>()
            for tag in tags {
                let name = Self.extractFolderName(from: tag.id)
                if !name.isEmpty {
                    categoryNames.insert(name)
                }
            }
            for sub in subscriptions {
                for cat in sub.categories {
                    let name = cat.label ?? Self.extractFolderName(from: cat.id)
                    if !name.isEmpty {
                        categoryNames.insert(name)
                    }
                }
            }

            // 同步保存 folders 表
            var folderIDByName: [String: String] = [:]
            for name in categoryNames {
                if let existing = try FolderRecord.filter(Column("account_id") == self.accountID && Column("name") == name).fetchOne(db) {
                    folderIDByName[name] = existing.id
                    if existing.isDeleted {
                        var updated = existing
                        updated.isDeleted = false
                        updated.updatedAt = now
                        try updated.save(db)
                    }
                } else {
                    let folderID = UUID().uuidString
                    let record = FolderRecord(
                        id: folderID,
                        accountID: self.accountID,
                        name: name,
                        isDeleted: false,
                        updatedAt: now
                    )
                    try record.save(db)
                    folderIDByName[name] = folderID
                }
            }

            // 2. 同步 feeds 表
            var activeRemoteFeedIDs = Set<String>()

            for sub in subscriptions {
                activeRemoteFeedIDs.insert(sub.id)
                let feedURL = sub.url ?? sub.htmlUrl ?? sub.id

                let folderName = sub.categories.first.map { $0.label ?? Self.extractFolderName(from: $0.id) }

                if var existing = try FeedRecord.filter(Column("account_id") == self.accountID && Column("external_id") == sub.id).fetchOne(db) {
                    existing.title = sub.title
                    existing.feedURL = feedURL
                    existing.isDeleted = false
                    existing.updatedAt = now
                    try existing.save(db)

                    // 更新 feed_folders 关联
                    _ = try FeedFolderRecord.filter(Column("feed_id") == existing.id).deleteAll(db)
                    if let folderName, let folderID = folderIDByName[folderName] {
                        let ff = FeedFolderRecord(feedID: existing.id, folderID: folderID)
                        try ff.save(db)
                    }
                } else {
                    let feedID = UUID().uuidString
                    let newFeed = FeedRecord(
                        id: feedID,
                        accountID: self.accountID,
                        externalID: sub.id,
                        title: sub.title,
                        siteURL: sub.htmlUrl,
                        feedURL: feedURL,
                        etag: nil,
                        lastModified: nil,
                        lastRefreshedAt: now,
                        isDeleted: false,
                        updatedAt: now,
                        sortOrder: 0
                    )
                    try newFeed.save(db)

                    if let folderName, let folderID = folderIDByName[folderName] {
                        let ff = FeedFolderRecord(feedID: feedID, folderID: folderID)
                        try ff.save(db)
                    }
                }
            }

            // 3. 处理软删除：如果本地存在的远端订阅已在 FreshRSS 端被删除，将其标为 is_deleted = 1
            let localFeeds = try FeedRecord
                .filter(Column("account_id") == self.accountID && Column("is_deleted") == false)
                .fetchAll(db)
            for localFeed in localFeeds {
                if let ext = localFeed.externalID, !activeRemoteFeedIDs.contains(ext) {
                    var updated = localFeed
                    updated.isDeleted = true
                    updated.updatedAt = now
                    try updated.save(db)
                }
            }
        }
    }

    // MARK: - Articles & States Sync

    public func syncArticlesAndStates() async throws {
        // 1. 拉取远端未读与星标 ID 集合
        let unreadIDsArray = (try? await apiClient.fetchUnreadItemIDs(limit: 10000)) ?? []
        let starredIDsArray = (try? await apiClient.fetchStarredItemIDs(limit: 10000)) ?? []

        let remoteUnreadIDs = Set(unreadIDsArray.map { Self.canonicalRemoteItemID($0) })
        let remoteStarredIDs = Set(starredIDsArray.map { Self.canonicalRemoteItemID($0) })

        // 2. 获取本地 Pending Outbox 集合 (PU 和 PS)
        let pendingRows: [ArticleStateOutboxRecord] = try database.read { db in
            try ArticleStateOutboxRecord
                .filter(Column("account_id") == self.accountID)
                .fetchAll(db)
        }

        let pendingReadItemIDs = Set(pendingRows.filter { $0.stateKey == "read" }.map(\.itemID))
        let pendingStarredItemIDs = Set(pendingRows.filter { $0.stateKey == "starred" }.map(\.itemID))

        // 3. 检查是否为初次同步
        let isInitialSync: Bool = try database.read { db in
            let syncState = try AccountSyncStateRecord.filter(Column("account_id") == self.accountID).fetchOne(db)
            return !(syncState?.initialSyncCompleted ?? false)
        }

        // 4. 拉取文章内容
        var streamItems: [ReaderAPIStreamItem] = []

        if isInitialSync {
            // 首次同步：有界拉取最近 200 篇文章内容
            streamItems = (try? await apiClient.fetchRecentStreamContents(limit: 200)) ?? []
        } else {
            // 增量同步：先拉取最近流数据，或者按缺失内容补齐
            let recentStream = (try? await apiClient.fetchRecentStreamContents(limit: 100)) ?? []
            streamItems.append(contentsOf: recentStream)

            // 查找本地存在 item 但缺少 article 内容的条目
            let missingContentExternalIDs: [String] = try database.read { db in
                let sql = """
                SELECT i.external_id
                FROM items i
                LEFT JOIN articles a ON a.item_id = i.id
                WHERE i.account_id = ? AND i.external_id IS NOT NULL AND a.item_id IS NULL
                LIMIT 50;
                """
                return try String.fetchAll(db, sql: sql, arguments: [self.accountID])
            }

            if !missingContentExternalIDs.isEmpty {
                let fetchedMissing = (try? await apiClient.fetchItemContents(itemIDs: missingContentExternalIDs)) ?? []
                streamItems.append(contentsOf: fetchedMissing)
            }
        }

        let now = Date().timeIntervalSince1970

        // 5. 在单一事务中持久化文章、条目与状态，严格遵守字段级调和 (Reconciliation)
        try database.write { db in
            // 建立 feed_id 映射 (external_id -> internal UUID)
            let feedRecords = try FeedRecord
                .filter(Column("account_id") == self.accountID && Column("is_deleted") == false)
                .fetchAll(db)
            let feedIDByExternalID: [String: String] = Dictionary(
                uniqueKeysWithValues: feedRecords.compactMap { feed in
                    guard let ext = feed.externalID else { return nil }
                    return (ext, feed.id)
                }
            )
            let defaultFeedID = feedRecords.first?.id ?? UUID().uuidString

            for item in streamItems {
                let remoteID = Self.canonicalRemoteItemID(item.id)
                guard !remoteID.isEmpty else { continue }

                // 关联 Feed ID
                var targetFeedID = defaultFeedID
                if let streamId = item.origin?.streamId, let mapped = feedIDByExternalID[streamId] {
                    targetFeedID = mapped
                }

                // 查找或创建 ItemRecord
                let itemID: String
                if let existingItem = try ItemRecord.filter(Column("account_id") == self.accountID && Column("external_id") == remoteID).fetchOne(db) {
                    itemID = existingItem.id
                } else {
                    itemID = UUID().uuidString
                    let newItem = ItemRecord(
                        id: itemID,
                        accountID: self.accountID,
                        externalID: remoteID,
                        feedID: targetFeedID,
                        createdAt: item.published ?? now,
                        updatedAt: item.updated ?? now
                    )
                    try newItem.save(db)
                }

                // 插入或更新 ArticleRecord
                let articleTitle = item.title ?? "无标题"
                let articleAuthor = item.author
                let articleURL = item.alternate?.first?.href
                let publishedAt = item.published ?? now
                let contentHTML = item.content?.content ?? item.summary?.content
                let plainSummary = Self.stripHTML(contentHTML ?? "")

                let articleRecord = ArticleRecord(
                    itemID: itemID,
                    title: articleTitle,
                    author: articleAuthor,
                    url: articleURL,
                    publishedAt: publishedAt,
                    summary: plainSummary,
                    contentHTML: contentHTML,
                    contentUpdatedAt: item.updated ?? now
                )
                try articleRecord.save(db)

                // 字段级状态调和 (Reconciliation)
                // 1. 判断远端真实状态
                let itemCategories = item.categories ?? []
                let isRemoteReadFromCategories = itemCategories.contains(where: { $0.contains("state/com.google/read") })
                let isRemoteRead = isRemoteReadFromCategories || !remoteUnreadIDs.contains(remoteID)

                let isRemoteStarredFromCategories = itemCategories.contains(where: { $0.contains("state/com.google/starred") })
                let isRemoteStarred = isRemoteStarredFromCategories || remoteStarredIDs.contains(remoteID)

                var finalIsRead = isRemoteRead
                var finalIsStarred = isRemoteStarred

                // 2. 存在 pending local mutation 时，pending local mutation 优先于 remote
                if var existingState = try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db) {
                    if pendingReadItemIDs.contains(itemID) {
                        finalIsRead = existingState.isRead
                    }
                    if pendingStarredItemIDs.contains(itemID) {
                        finalIsStarred = existingState.isStarred
                    }
                    existingState.isRead = finalIsRead
                    existingState.isStarred = finalIsStarred
                    existingState.updatedAt = now
                    try existingState.save(db)
                } else {
                    let newState = ArticleStateRecord(
                        itemID: itemID,
                        isRead: finalIsRead,
                        isStarred: finalIsStarred,
                        dateArrived: now,
                        updatedAt: now
                    )
                    try newState.save(db)
                }
            }

            // 6. 对未在本次 streamItems 中出现但已在本地库中的 items 进行批量远端状态校准（排除 pending mutations）
            let allLocalItems = try ItemRecord
                .filter(Column("account_id") == self.accountID)
                .fetchAll(db)

            for localItem in allLocalItems {
                let canonicalExt = Self.canonicalRemoteItemID(localItem.externalID)

                guard var state = try ArticleStateRecord.filter(Column("item_id") == localItem.id).fetchOne(db) else {
                    continue
                }

                var stateChanged = false

                if !pendingReadItemIDs.contains(localItem.id) {
                    let remoteUnread = remoteUnreadIDs.contains(canonicalExt)
                    let shouldBeRead = !remoteUnread
                    if state.isRead != shouldBeRead {
                        state.isRead = shouldBeRead
                        stateChanged = true
                    }
                }

                if !pendingStarredItemIDs.contains(localItem.id) {
                    let shouldBeStarred = remoteStarredIDs.contains(canonicalExt)
                    if state.isStarred != shouldBeStarred {
                        state.isStarred = shouldBeStarred
                        stateChanged = true
                    }
                }

                if stateChanged {
                    state.updatedAt = now
                    try state.save(db)
                }
            }
        }
    }

    // MARK: - Helpers

    public static func extractFolderName(from categoryID: String) -> String {
        if let last = categoryID.split(separator: "/").last {
            let name = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !name.hasPrefix("com.google") {
                return name
            }
        }
        return ""
    }

    public static func canonicalRemoteItemID(_ rawID: String) -> String {
        if let last = rawID.split(separator: "/").last {
            return String(last)
        }
        return rawID
    }

    private static func stripHTML(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive)
        let range = NSRange(location: 0, length: html.utf16.count)
        let plain = regex?.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "") ?? html
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sync State Management

    private func markSyncStarted(timestamp: Double) async {
        try? database.write { db in
            if var state = try AccountSyncStateRecord.filter(Column("account_id") == self.accountID).fetchOne(db) {
                state.lastSyncStartedAt = timestamp
                try state.save(db)
            } else {
                let state = AccountSyncStateRecord(
                    accountID: self.accountID,
                    initialSyncCompleted: false,
                    lastSyncStartedAt: timestamp,
                    lastSyncCompletedAt: nil,
                    lastFullReconcileAt: nil,
                    lastArticleFetchAt: nil,
                    consecutiveFailureCount: 0,
                    lastError: nil
                )
                try state.save(db)
            }
        }
    }

    private func markSyncCompleted(timestamp: Double) async {
        try? database.write { db in
            if var state = try AccountSyncStateRecord.filter(Column("account_id") == self.accountID).fetchOne(db) {
                state.initialSyncCompleted = true
                state.lastSyncCompletedAt = timestamp
                state.lastArticleFetchAt = timestamp
                state.consecutiveFailureCount = 0
                state.lastError = nil
                try state.save(db)
            }
        }
    }

    private func markSyncFailed(timestamp: Double, error: String) async {
        try? database.write { db in
            if var state = try AccountSyncStateRecord.filter(Column("account_id") == self.accountID).fetchOne(db) {
                state.consecutiveFailureCount += 1
                state.lastError = error
                try state.save(db)
            }
        }
    }
}
