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
        session: URLSession? = nil
    ) {
        self.accountID = accountID
        self.database = database
        self.credentialStore = credentialStore
        self.apiClient = ReaderAPIClient(
            endpointURL: endpointURL,
            username: username,
            accountID: accountID,
            credentialStore: credentialStore,
            session: session ?? .shared
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
            let reachedBoundary = try await syncArticlesAndStates()

            // 4. 同步完成后若有未结 outbox 再次推进
            _ = try await outboxProcessor.processOutbox()

            await markSyncCompleted(timestamp: Date().timeIntervalSince1970, advanceFetchTimestamp: reachedBoundary)
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
        let now = Date().timeIntervalSince1970

        try database.write { db in
            // 1. 仅以 subscriptions[].categories 作为权威的订阅文件夹来源
            var categoryByExternalID: [String: String] = [:]

            for sub in subscriptions {
                for cat in sub.categories {
                    let trimmedLabel = cat.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let extracted = Self.extractFolderName(from: cat.id)
                    let name = (trimmedLabel?.isEmpty == false ? trimmedLabel : nil) ?? extracted
                    if !name.isEmpty {
                        categoryByExternalID[cat.id] = name
                    }
                }
            }

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

                var feedRecordID: String
                if var existing = try FeedRecord.filter(Column("account_id") == self.accountID && Column("external_id") == sub.id).fetchOne(db) {
                    existing.title = sub.title
                    existing.feedURL = feedURL
                    existing.siteURL = sub.htmlUrl
                    existing.isDeleted = false
                    existing.updatedAt = now
                    try existing.save(db)
                    feedRecordID = existing.id
                } else if var existingByURL = try FeedRecord.filter(Column("account_id") == self.accountID && Column("feed_url") == feedURL).fetchOne(db) {
                    existingByURL.externalID = sub.id
                    existingByURL.title = sub.title
                    existingByURL.siteURL = sub.htmlUrl
                    existingByURL.isDeleted = false
                    existingByURL.updatedAt = now
                    try existingByURL.save(db)
                    feedRecordID = existingByURL.id
                } else {
                    let newFeedID = UUID().uuidString
                    let maxSort = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM feeds WHERE account_id = ?;", arguments: [self.accountID])) ?? 0
                    let record = FeedRecord(
                        id: newFeedID,
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
                        storedIconURL: nil,
                        sortOrder: maxSort + 1
                    )
                    try record.save(db)
                    feedRecordID = newFeedID
                }

                // 关联分类
                try FeedFolderRecord.filter(Column("feed_id") == feedRecordID).deleteAll(db)
                for cat in sub.categories {
                    let folderID = folderIDByExternalID[cat.id] ?? (cat.label.flatMap { folderIDByName[$0] })
                    if let folderID {
                        let link = FeedFolderRecord(feedID: feedRecordID, folderID: folderID)
                        try link.save(db)
                    }
                }
            }

            // 标记远端已删除的 feeds
            let localFeeds = try FeedRecord.filter(Column("account_id") == self.accountID && Column("is_deleted") == false).fetchAll(db)
            for localFeed in localFeeds {
                if let ext = localFeed.externalID, !activeRemoteFeedIDs.contains(ext) {
                    var updated = localFeed
                    updated.isDeleted = true
                    updated.updatedAt = now
                    try updated.save(db)
                }
            }

            // 标记远端已删除的 folders
            let localFolders = try FolderRecord.filter(Column("account_id") == self.accountID && Column("is_deleted") == false).fetchAll(db)
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

    @discardableResult
    public func syncArticlesAndStates() async throws -> Bool {
        // 1. 检查是否为初次同步，并获取上次成功拉取时间戳
        let (isInitialSync, lastArticleFetchAt): (Bool, TimeInterval?) = try database.read { db in
            let syncState = try AccountSyncStateRecord.filter(Column("account_id") == self.accountID).fetchOne(db)
            let isInitial = !(syncState?.initialSyncCompleted ?? false)
            let lastFetch = syncState?.lastArticleFetchAt ?? syncState?.lastSyncCompletedAt
            return (isInitial, lastFetch)
        }

        // 2. 拉取远端未读与星标 ID 集合（支持 continuation 翻页，显式标记完整性）
        var remoteUnreadSet: ReaderItemIDSet? = nil
        var remoteStarredSet: ReaderItemIDSet? = nil
        var canonicalUnreadKeys: Set<String>? = nil
        var canonicalStarredKeys: Set<String>? = nil

        do {
            let unreadResult = try await apiClient.fetchAllUnreadItemIDs()
            remoteUnreadSet = unreadResult
            canonicalUnreadKeys = ReaderItemIDCodec.buildCanonicalKeySet(from: unreadResult.ids)
        } catch {
            remoteUnreadSet = nil
            canonicalUnreadKeys = nil
            if isInitialSync { throw error }
        }

        do {
            let starredResult = try await apiClient.fetchAllStarredItemIDs()
            remoteStarredSet = starredResult
            canonicalStarredKeys = ReaderItemIDCodec.buildCanonicalKeySet(from: starredResult.ids)
        } catch {
            remoteStarredSet = nil
            canonicalStarredKeys = nil
            if isInitialSync { throw error }
        }

        // 3. 获取本地 Pending Outbox 集合 (PU 和 PS)
        let pendingRows: [ArticleStateOutboxRecord] = try database.read { db in
            try ArticleStateOutboxRecord
                .filter(Column("account_id") == self.accountID)
                .fetchAll(db)
        }

        let pendingReadItemIDs = Set(pendingRows.filter { $0.stateKey == "read" }.map(\.itemID))
        let pendingStarredItemIDs = Set(pendingRows.filter { $0.stateKey == "starred" }.map(\.itemID))

        // 4. 拉取文章内容（严禁吞掉必须的失败）
        var streamItems: [ReaderAPIStreamItem] = []
        var olderSpecialRawIDs: [String] = []
        var reachedBoundary = true

        if isInitialSync {
            // 首次同步：有界拉取最近 200 篇文章内容
            streamItems = try await apiClient.fetchRecentStreamContents(limit: 200)

            // Initial Sync Policy: 识别历史窗口外的 old unread / old starred 并批量拉取真实正文
            var streamItemKeys = Set(streamItems.map { ReaderItemIDCodec.canonicalComparisonKey(for: $0.id) })

            if let unreadSet = remoteUnreadSet {
                for rawID in unreadSet.ids {
                    let key = ReaderItemIDCodec.canonicalComparisonKey(for: rawID)
                    if !streamItemKeys.contains(key) {
                        olderSpecialRawIDs.append(rawID)
                        streamItemKeys.insert(key)
                    }
                }
            }
            if let starredSet = remoteStarredSet {
                for rawID in starredSet.ids {
                    let key = ReaderItemIDCodec.canonicalComparisonKey(for: rawID)
                    if !streamItemKeys.contains(key) {
                        olderSpecialRawIDs.append(rawID)
                        streamItemKeys.insert(key)
                    }
                }
            }

            // 按需分批拉取历史特殊条目真实正文（每批 50 篇，上限 200 篇），获取 origin.streamId 与完整内容
            if !olderSpecialRawIDs.isEmpty {
                let initialHydrationBatch = Array(olderSpecialRawIDs.prefix(200))
                let batchSize = 50
                for startIdx in stride(from: 0, to: initialHydrationBatch.count, by: batchSize) {
                    let chunk = Array(initialHydrationBatch[startIdx..<min(startIdx + batchSize, initialHydrationBatch.count)])
                    if let fetchedOlder = try? await apiClient.fetchItemContents(itemIDs: chunk) {
                        streamItems.append(contentsOf: fetchedOlder)
                    }
                }
            }
        } else {
            // 增量同步：获取本地已存在的 external_id 集合
            let existingExternalIDs: Set<String> = try database.read { db in
                let items = try ItemRecord.filter(Column("account_id") == self.accountID).fetchAll(db)
                return Set(items.compactMap(\.externalID))
            }

            // 使用时间边界与 continuation 遍历拉取增量新文章（直到追平时间边界或流结束）
            let fetchResult = try await apiClient.fetchIncrementalStreamContents(
                sinceTimestamp: lastArticleFetchAt,
                knownLocalExternalIDs: existingExternalIDs
            )
            reachedBoundary = fetchResult.reachedBoundary
            streamItems.append(contentsOf: fetchResult.items)

            // 查找本地存在 item 但缺少 article 内容的条目（独立补齐与重试）
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
                if let fetchedMissing = try? await apiClient.fetchItemContents(itemIDs: missingContentExternalIDs) {
                    streamItems.append(contentsOf: fetchedMissing)
                }
            }
        }

        let now = Date().timeIntervalSince1970

        // 5. 在单一事务中持久化文章、条目与状态，严格遵守字段级调和 (Reconciliation)
        try database.write { db in
            // 建立 feed_id 映射 (external_id -> internal UUID)
            let allAccountFeeds = try FeedRecord
                .filter(Column("account_id") == self.accountID)
                .fetchAll(db)

            let feedIDByExternalID: [String: String] = Dictionary(
                uniqueKeysWithValues: allAccountFeeds.compactMap { feed in
                    guard let ext = feed.externalID else { return nil }
                    return (ext, feed.id)
                }
            )

            var processedItemIDs = Set<String>()

            // A. 处理当前流返回的 streamItems（权威 categories 优先判定）
            for item in streamItems {
                let rawRemoteID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawRemoteID.isEmpty else { continue }

                // 关联 Feed ID：通过 origin.streamId 精确关联所属源，杜绝伪造 defaultFeedID
                guard let streamId = item.origin?.streamId, let targetFeedID = feedIDByExternalID[streamId] else {
                    continue
                }

                // 查找或新建 item（持久化 raw remote identity）
                let internalItemID: String
                if let existingItem = try ItemRecord.filter(Column("account_id") == self.accountID && Column("external_id") == rawRemoteID).fetchOne(db) {
                    internalItemID = existingItem.id
                } else {
                    let newID = "\(self.accountID)::\(rawRemoteID)"
                    let newItem = ItemRecord(
                        id: newID,
                        accountID: self.accountID,
                        externalID: rawRemoteID,
                        feedID: targetFeedID,
                        createdAt: item.published ?? now,
                        updatedAt: item.updated ?? now
                    )
                    try newItem.save(db)
                    internalItemID = newID
                }

                processedItemIDs.insert(internalItemID)

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

                // 状态计算：当前 stream item 自身自带权威 categories
                let remoteItemRead = item.isMarkedReadByCategories
                let remoteItemStarred = item.isMarkedStarredByCategories

                // 持久化 article_states（字段级调和 + pending local mutation 保护）
                if var existingState = try ArticleStateRecord.filter(Column("item_id") == internalItemID).fetchOne(db) {
                    var modified = false
                    if !pendingReadItemIDs.contains(internalItemID) {
                        if existingState.isRead != remoteItemRead {
                            existingState.isRead = remoteItemRead
                            modified = true
                        }
                    }
                    if !pendingStarredItemIDs.contains(internalItemID) {
                        if existingState.isStarred != remoteItemStarred {
                            existingState.isStarred = remoteItemStarred
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
                        isRead: pendingReadItemIDs.contains(internalItemID) ? false : remoteItemRead,
                        isStarred: pendingStarredItemIDs.contains(internalItemID) ? false : remoteItemStarred,
                        dateArrived: now,
                        updatedAt: now
                    )
                    try newState.save(db)
                }
            }

            // B. 对未在本次 streamItems 中出现但在本地库中的 items 进行全库远端状态校准
            let allLocalItems = try ItemRecord
                .filter(Column("account_id") == self.accountID)
                .fetchAll(db)

            for localItem in allLocalItems {
                if processedItemIDs.contains(localItem.id) {
                    continue
                }

                guard var state = try ArticleStateRecord.filter(Column("item_id") == localItem.id).fetchOne(db) else {
                    continue
                }

                let itemKey = ReaderItemIDCodec.canonicalComparisonKey(for: localItem.externalID)
                var stateChanged = false

                // 1. 未读状态调和
                if !pendingReadItemIDs.contains(localItem.id),
                   let unreadSet = remoteUnreadSet,
                   let unreadKeys = canonicalUnreadKeys {
                    let isUnread = unreadKeys.contains(itemKey)
                    if isUnread {
                        // 在未读集合中 -> 未读 (isRead = false)
                        if state.isRead != false {
                            state.isRead = false
                            stateChanged = true
                        }
                    } else if unreadSet.isComplete {
                        // 不在未读集合中 且 未读集合完整权威 -> 负向推断为已读 (isRead = true)
                        if state.isRead != true {
                            state.isRead = true
                            stateChanged = true
                        }
                    }
                    // 若不在未读集合中但未读集合不完整，严禁负向推断，保持本地 state.isRead 原值
                }

                // 2. 星标状态调和
                if !pendingStarredItemIDs.contains(localItem.id),
                   let starredSet = remoteStarredSet,
                   let starredKeys = canonicalStarredKeys {
                    let isStarred = starredKeys.contains(itemKey)
                    if isStarred {
                        // 在星标集合中 -> 星标 (isStarred = true)
                        if state.isStarred != true {
                            state.isStarred = true
                            stateChanged = true
                        }
                    } else if starredSet.isComplete {
                        // 不在星标集合中 且 星标集合完整权威 -> 负向推断为未星标 (isStarred = false)
                        if state.isStarred != false {
                            state.isStarred = false
                            stateChanged = true
                        }
                    }
                    // 若不在星标集合中但星标集合不完整，严禁负向推断，保持本地 state.isStarred 原值
                }

                if stateChanged {
                    state.updatedAt = now
                    try state.save(db)
                }
            }
        }
        return reachedBoundary
    }

    // MARK: - Helpers

    public static func extractFolderName(from categoryID: String) -> String {
        // 排除系统 stream / state（如 starred、reading-list、main、important 等）
        if categoryID.contains("user/-/state/") || categoryID.contains("/state/com.google/") || categoryID.contains("org.freshrss") {
            return ""
        }
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

    private func markSyncCompleted(timestamp: Double, advanceFetchTimestamp: Bool = true) async {
        try? database.write { db in
            if var state = try AccountSyncStateRecord.filter(Column("account_id") == self.accountID).fetchOne(db) {
                state.initialSyncCompleted = true
                state.lastSyncCompletedAt = timestamp
                if advanceFetchTimestamp {
                    state.lastArticleFetchAt = timestamp
                }
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
