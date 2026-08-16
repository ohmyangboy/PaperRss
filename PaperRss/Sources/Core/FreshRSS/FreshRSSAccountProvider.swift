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
            // 1. 整理全部有效分类目录 (Tag / Category DTO)
            var categoryByExternalID: [String: String] = [:] // externalID -> label/name

            for tag in tags {
                let name = Self.extractFolderName(from: tag.id)
                if !name.isEmpty {
                    categoryByExternalID[tag.id] = name
                }
            }
            for sub in subscriptions {
                for cat in sub.categories {
                    let name = cat.label ?? Self.extractFolderName(from: cat.id)
                    if !name.isEmpty {
                        categoryByExternalID[cat.id] = name
                    }
                }
            }

            // 同步 folders 表：按 (account_id, external_id) 匹配与更新
            var folderIDByExternalID: [String: String] = [:]
            var folderIDByName: [String: String] = [:]
            var activeFolderExternalIDs = Set<String>()

            for (extID, name) in categoryByExternalID {
                activeFolderExternalIDs.insert(extID)
                if var existing = try FolderRecord.filter(Column("account_id") == self.accountID && Column("external_id") == extID).fetchOne(db) {
                    existing.name = name
                    existing.isDeleted = false
                    existing.updatedAt = now
                    try existing.save(db)
                    folderIDByExternalID[extID] = existing.id
                    folderIDByName[name] = existing.id
                } else if var existingByName = try FolderRecord.filter(Column("account_id") == self.accountID && Column("name") == name && Column("external_id") == nil).fetchOne(db) {
                    existingByName.externalID = extID
                    existingByName.isDeleted = false
                    existingByName.updatedAt = now
                    try existingByName.save(db)
                    folderIDByExternalID[extID] = existingByName.id
                    folderIDByName[name] = existingByName.id
                } else {
                    let folderID = UUID().uuidString
                    let record = FolderRecord(
                        id: folderID,
                        accountID: self.accountID,
                        externalID: extID,
                        name: name,
                        sortOrder: 0,
                        isDeleted: false,
                        updatedAt: now
                    )
                    try record.save(db)
                    folderIDByExternalID[extID] = folderID
                    folderIDByName[name] = folderID
                }
            }

            // 2. 同步 feeds 表及多对多 feed_folders 关联
            var activeRemoteFeedIDs = Set<String>()

            for sub in subscriptions {
                activeRemoteFeedIDs.insert(sub.id)
                let feedURL = sub.url ?? sub.htmlUrl ?? sub.id

                let internalFeedID: String
                if var existing = try FeedRecord.filter(Column("account_id") == self.accountID && Column("external_id") == sub.id).fetchOne(db) {
                    existing.title = sub.title
                    existing.feedURL = feedURL
                    existing.siteURL = sub.htmlUrl
                    existing.isDeleted = false
                    existing.updatedAt = now
                    try existing.save(db)
                    internalFeedID = existing.id
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
                    internalFeedID = feedID
                }

                // 重建该 feed 的所有 feed_folders 关联 (多对多)
                _ = try FeedFolderRecord.filter(Column("feed_id") == internalFeedID).deleteAll(db)
                for cat in sub.categories {
                    let catExtID = cat.id
                    let catName = cat.label ?? Self.extractFolderName(from: cat.id)
                    let matchedFolderID = folderIDByExternalID[catExtID] ?? folderIDByName[catName]
                    if let matchedFolderID {
                        let ff = FeedFolderRecord(feedID: internalFeedID, folderID: matchedFolderID)
                        try ff.save(db)
                    }
                }
            }

            // 3. 处理软删除：如果本地存在的远端订阅或文件夹已在 FreshRSS 端被删除，将其标为 is_deleted = 1
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

            let localFolders = try FolderRecord
                .filter(Column("account_id") == self.accountID && Column("is_deleted") == false && Column("external_id") != nil)
                .fetchAll(db)
            for localFolder in localFolders {
                if let ext = localFolder.externalID, !activeFolderExternalIDs.contains(ext) {
                    var updated = localFolder
                    updated.isDeleted = true
                    updated.updatedAt = now
                    try updated.save(db)
                }
            }
        }
    }

    // MARK: - Articles & States Sync

    public func syncArticlesAndStates() async throws {
        // 1. 安全拉取远端未读与星标 ID 集合（严禁将失败请求当作空集合，严格保留权威性标志）
        var remoteUnreadIDs: Set<String>? = nil
        var remoteStarredIDs: Set<String>? = nil

        do {
            let unreadIDsArray = try await apiClient.fetchAllUnreadItemIDs()
            remoteUnreadIDs = Set(unreadIDsArray.map { Self.canonicalRemoteItemID($0) })
        } catch {
            // 未读状态拉取失败：保留 nil，严禁使用 [] 抹去本地未读状态
        }

        do {
            let starredIDsArray = try await apiClient.fetchAllStarredItemIDs()
            remoteStarredIDs = Set(starredIDsArray.map { Self.canonicalRemoteItemID($0) })
        } catch {
            // 星标状态拉取失败：保留 nil，严禁使用 [] 抹去本地星标状态
        }

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

        if isInitialSync && remoteUnreadIDs == nil && remoteStarredIDs == nil {
            throw ReaderAPIError.networkError("Initial synchronization state fetch failed")
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

                // 查找或新建 item
                let internalItemID: String
                if let existingItem = try ItemRecord.filter(Column("account_id") == self.accountID && Column("external_id") == remoteID).fetchOne(db) {
                    internalItemID = existingItem.id
                } else {
                    let newID = "\(self.accountID)|\(remoteID)".stableDigest
                    let newItem = ItemRecord(
                        id: newID,
                        accountID: self.accountID,
                        externalID: remoteID,
                        feedID: targetFeedID,
                        createdAt: item.published ?? now,
                        updatedAt: item.updated ?? now
                    )
                    try newItem.save(db)
                    internalItemID = newID
                }

                // 保存/更新 articles 表内容
                let articleTitle = item.title ?? ""
                let articleAuthor = item.author
                let articleURL = item.alternate?.first?.href
                let articlePublished = item.published
                let contentHTML = item.content?.content ?? item.summary?.content
                let articleSummary = contentHTML.flatMap { Self.stripHTML($0) } ?? ""

                if var existingArticle = try ArticleRecord.filter(Column("item_id") == internalItemID).fetchOne(db) {
                    existingArticle.title = articleTitle
                    existingArticle.author = articleAuthor
                    existingArticle.url = articleURL
                    existingArticle.publishedAt = articlePublished
                    existingArticle.summary = articleSummary
                    existingArticle.contentHTML = contentHTML
                    existingArticle.contentUpdatedAt = now
                    try existingArticle.save(db)
                } else {
                    let newArticle = ArticleRecord(
                        itemID: internalItemID,
                        title: articleTitle,
                        author: articleAuthor,
                        url: articleURL,
                        publishedAt: articlePublished,
                        summary: articleSummary,
                        contentHTML: contentHTML,
                        contentUpdatedAt: now
                    )
                    try newArticle.save(db)
                }

                // 状态计算：结合 Categories 标签与 remoteUnreadIDs/remoteStarredIDs
                let itemCategories = item.categories ?? []
                let isRemoteReadFromCategories = itemCategories.contains(where: { $0.contains("state/com.google/read") })
                let isRemoteUnreadFromCategories = itemCategories.contains(where: { $0.contains("state/com.google/reading-list") })

                let finalRemoteRead: Bool? = {
                    if let remoteUnreadIDs {
                        return !remoteUnreadIDs.contains(remoteID)
                    }
                    if isRemoteReadFromCategories { return true }
                    if isRemoteUnreadFromCategories { return false }
                    return nil
                }()

                let isRemoteStarredFromCategories = itemCategories.contains(where: { $0.contains("state/com.google/starred") })
                let finalRemoteStarred: Bool? = {
                    if let remoteStarredIDs {
                        return remoteStarredIDs.contains(remoteID)
                    }
                    if isRemoteStarredFromCategories { return true }
                    return nil
                }()

                // 持久化 article_states（字段级调和）
                if var existingState = try ArticleStateRecord.filter(Column("item_id") == internalItemID).fetchOne(db) {
                    var modified = false
                    if let finalRemoteRead, !pendingReadItemIDs.contains(internalItemID) {
                        if existingState.isRead != finalRemoteRead {
                            existingState.isRead = finalRemoteRead
                            modified = true
                        }
                    }
                    if let finalRemoteStarred, !pendingStarredItemIDs.contains(internalItemID) {
                        if existingState.isStarred != finalRemoteStarred {
                            existingState.isStarred = finalRemoteStarred
                            modified = true
                        }
                    }
                    if modified {
                        existingState.updatedAt = now
                        try existingState.save(db)
                    }
                } else {
                    let newState = ArticleStateRecord(
                        itemID: internalItemID,
                        isRead: finalRemoteRead ?? false,
                        isStarred: finalRemoteStarred ?? false,
                        dateArrived: now,
                        updatedAt: now
                    )
                    try newState.save(db)
                }
            }

            // 6. 对未在本次 streamItems 中出现但已在本地库中的 items 进行全库远端状态校准（仅在远端状态集完整时，且严格排除 pending mutations）
            let allLocalItems = try ItemRecord
                .filter(Column("account_id") == self.accountID)
                .fetchAll(db)

            for localItem in allLocalItems {
                let canonicalExt = Self.canonicalRemoteItemID(localItem.externalID)

                guard var state = try ArticleStateRecord.filter(Column("item_id") == localItem.id).fetchOne(db) else {
                    continue
                }

                var stateChanged = false

                // 仅当 remoteUnreadIDs 成功权威获取时才进行负向推断
                if let remoteUnreadIDs, !pendingReadItemIDs.contains(localItem.id) {
                    let remoteUnread = remoteUnreadIDs.contains(canonicalExt)
                    let shouldBeRead = !remoteUnread
                    if state.isRead != shouldBeRead {
                        state.isRead = shouldBeRead
                        stateChanged = true
                    }
                }

                // 仅当 remoteStarredIDs 成功权威获取时才进行负向推断
                if let remoteStarredIDs, !pendingStarredItemIDs.contains(localItem.id) {
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
        let labelPrefix = "user/-/label/"
        if let range = categoryID.range(of: labelPrefix) {
            let label = String(categoryID[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { return label }
        }
        let components = categoryID.split(separator: "/")
        if let last = components.last {
            let name = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !name.hasPrefix("com.google") && !name.hasPrefix("state") {
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
