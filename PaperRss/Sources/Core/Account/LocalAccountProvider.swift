import Foundation
import GRDB

public enum LocalAccountError: LocalizedError, Equatable, Sendable {
    case alreadySubscribed
    case feedNotFound

    public var errorDescription: String? {
        switch self {
        case .alreadySubscribed:
            return I18N.localized("这个订阅已经存在。")
        case .feedNotFound:
            return I18N.localized("未找到订阅源。")
        }
    }
}

/// Local 账号提供者。
///
/// 负责本地订阅账号在 SQLite 底层架构上的全部业务操作：
/// - 订阅源管理 (Feed / Folder)
/// - 网络拉取与增量合并 (Feed Fetch / SQLite Upsert)
/// - 阅读/星标状态流转 (ArticleState)
/// - 网页离线正文缓存 (ArticleCache)
/// - AI 生成产物与全局翻译记忆 (AIArtifact)
/// - OPML 导入与导出
public final class LocalAccountProvider: AccountProvider, Sendable {
    public let accountID: String
    private let database: LibraryDatabase
    public let feedRepository: FeedRepository
    public let articleRepository: ArticleRepository
    public let stateRepository: ArticleStateRepository
    public let cacheRepository: CacheRepository
    public let artifactRepository: AIArtifactRepository
    public let timelineQueryService: TimelineQueryService
    private let feedFetcher: @Sendable (Feed, Bool) async throws -> FeedFetchResult

    public init(
        accountID: String = "local-default",
        database: LibraryDatabase,
        feedFetcher: (@Sendable (Feed) async throws -> FeedFetchResult)? = nil,
        customFeedFetcher: (@Sendable (Feed, Bool) async throws -> FeedFetchResult)? = nil
    ) {
        self.accountID = accountID
        self.database = database
        self.feedRepository = FeedRepository(database: database)
        self.articleRepository = ArticleRepository(database: database)
        self.stateRepository = ArticleStateRepository(database: database)
        self.cacheRepository = CacheRepository(database: database)
        self.artifactRepository = AIArtifactRepository(database: database)
        self.timelineQueryService = TimelineQueryService(database: database)
        if let customFeedFetcher {
            self.feedFetcher = customFeedFetcher
        } else if let feedFetcher {
            self.feedFetcher = { feed, _ in
                try await feedFetcher(feed)
            }
        } else {
            self.feedFetcher = { feed, force in
                try await FeedService.fetch(feed, force: force)
            }
        }
    }

    // MARK: - Bootstrap

    public func ensureAccountExists() throws {
        try database.write { db in
            if try AccountRecord.filter(Column("id") == self.accountID).fetchOne(db) == nil {
                let now = Date().timeIntervalSince1970
                let account = AccountRecord(
                    id: self.accountID,
                    type: "local",
                    displayName: "本地订阅",
                    isEnabled: true,
                    createdAt: now,
                    updatedAt: now
                )
                try account.save(db)
            }
        }
    }

    // MARK: - Feed & Folder Management

    public func fetchFeeds() throws -> [Feed] {
        try database.read { db in
            try self.feedRepository.fetchAllFeedModels(accountID: self.accountID, in: db)
        }
    }

    public func fetchFolderNames() throws -> [String] {
        try database.read { db in
            try self.feedRepository.fetchFolderNames(accountID: self.accountID, in: db)
        }
    }

    public func addFeed(title: String, feedURL: URL, siteURL: URL? = nil, folder: String? = nil) throws -> Feed {
        let feedURLString = feedURL.absoluteString
        let now = Date().timeIntervalSince1970

        return try database.write { db in
            let existingFeeds = try FeedRecord
                .filter(Column("account_id") == self.accountID && Column("feed_url") == feedURLString)
                .fetchAll(db)

            if existingFeeds.contains(where: { !$0.isDeleted }) {
                throw LocalAccountError.alreadySubscribed
            }

            // 移除旧记录就地复活逻辑：若存在软删除的历史残留旧源，彻底物理清除并级联回收文章与状态
            for oldDeleted in existingFeeds where oldDeleted.isDeleted {
                try self.feedRepository.deleteFeed(id: oldDeleted.id, in: db)
            }

            // 全新添加 Feed
            let feedUUID = UUID()
            let feedID = feedUUID.uuidString
            let maxSort = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM feeds WHERE account_id = ?;", arguments: [self.accountID])) ?? 0
            let record = FeedRecord(
                id: feedID,
                accountID: self.accountID,
                externalID: nil,
                title: title,
                siteURL: siteURL?.absoluteString,
                feedURL: feedURLString,
                etag: nil,
                lastModified: nil,
                lastRefreshedAt: nil,
                isDeleted: false,
                updatedAt: now,
                storedIconURL: nil,
                sortOrder: maxSort + 1
            )
            try self.feedRepository.saveFeed(record, in: db)

            if let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
                try self.feedRepository.setFeedFolder(feedID: feedID, folderName: folder, accountID: self.accountID, in: db)
            }

            return Feed(
                id: feedUUID,
                title: title,
                siteURL: siteURL,
                feedURL: feedURL,
                folder: folder,
                updatedAt: Date(timeIntervalSince1970: now)
            )
        }
    }

    public func deleteFeed(feedID: UUID) throws {
        try database.write { db in
            try self.feedRepository.deleteFeed(id: feedID.uuidString, in: db)
        }
    }

    public func setFeedFolder(feedID: UUID, folderName: String?) throws {
        try database.write { db in
            try self.feedRepository.setFeedFolder(feedID: feedID.uuidString, folderName: folderName, accountID: self.accountID, in: db)
        }
    }

    public func setFeedFolder(feedIDs: Set<UUID>, folderName: String?) throws {
        let stringIDs = Set(feedIDs.map(\.uuidString))
        try database.write { db in
            try self.feedRepository.setFeedFolder(feedIDs: stringIDs, folderName: folderName, accountID: self.accountID, in: db)
        }
    }

    public func addFolder(name: String) throws {
        try database.write { db in
            try self.feedRepository.addFolder(name: name, accountID: self.accountID, in: db)
        }
    }

    public func deleteFolder(name: String) throws {
        try database.write { db in
            try self.feedRepository.deleteFolder(name: name, accountID: self.accountID, in: db)
        }
    }

    public func renameFolder(oldName: String, newName: String) throws {
        try database.write { db in
            try self.feedRepository.renameFolder(oldName: oldName, newName: newName, accountID: self.accountID, in: db)
        }
    }

    // MARK: - Feed Refreshing (SQLite Transactional Merge)

    public struct SingleFeedRefreshResult: Sendable {
        public let feedID: UUID
        public let oldTitle: String
        public let result: Result<FeedFetchResult, Error>
    }

    public func fetchSingleFeed(feed: Feed, timeoutSeconds: Double = 10.0, force: Bool = false) async -> SingleFeedRefreshResult {
        let feedID = feed.id
        let title = feed.title
        do {
            let fetchResult = try await withThrowingTaskGroup(of: FeedFetchResult.self) { group in
                group.addTask {
                    try await self.feedFetcher(feed, force)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                let res = try await group.next()!
                group.cancelAll()
                return res
            }
            return SingleFeedRefreshResult(feedID: feedID, oldTitle: title, result: .success(fetchResult))
        } catch {
            return SingleFeedRefreshResult(feedID: feedID, oldTitle: title, result: .failure(error))
        }
    }

    /// 单源拉取与增量合并，支持 force: true 忽略 304 强制重新拉取
    @discardableResult
    public func refreshFeed(id: UUID, force: Bool = true) async throws -> (updated: Bool, newUnreadEntries: [Entry]) {
        let feedIDString = id.uuidString
        guard let feed = try database.read({ db in
            try self.feedRepository.fetchFeedModel(id: feedIDString, in: db)
        }) else {
            throw LocalAccountError.feedNotFound
        }

        let singleRes = await fetchSingleFeed(feed: feed, force: force)
        switch singleRes.result {
        case .success:
            return try await applyRefreshResultAsync(singleRes)
        case .failure(let error):
            throw error
        }
    }

    /// 将单次抓取结果合并入 SQLite
    public func applyRefreshResult(
        _ taskResult: SingleFeedRefreshResult
    ) throws -> (updated: Bool, newUnreadEntries: [Entry]) {
        return try database.write { db in
            try self.applyRefreshResult(taskResult, in: db)
        }
    }

    /// 将单次抓取结果合并入 SQLite writer queue，绝不占用调用方的 MainActor。
    public func applyRefreshResultAsync(
        _ taskResult: SingleFeedRefreshResult
    ) async throws -> (updated: Bool, newUnreadEntries: [Entry]) {
        try await database.writeAsync { db in
            try self.applyRefreshResult(taskResult, in: db)
        }
    }

    private func applyRefreshResult(
        _ taskResult: SingleFeedRefreshResult,
        in db: Database
    ) throws -> (updated: Bool, newUnreadEntries: [Entry]) {
        let feedIDString = taskResult.feedID.uuidString
        let now = Date().timeIntervalSince1970

        guard let existing = try feedRepository.fetchFeed(id: feedIDString, in: db),
              !existing.isDeleted else {
            return (false, [])
        }

        switch taskResult.result {
        case let .success(.notModified(etag, lastModified)):
            try feedRepository.updateFeedMetadata(
                feedID: feedIDString,
                etag: etag,
                lastModified: lastModified,
                lastRefreshedAt: now,
                in: db
            )
            return (false, [])

        case let .success(.updated(parsed, etag, lastModified)):
            try AutoTranslationRepository.saveHints(parsed.languageHints, scope: "feed", id: feedIDString, in: db)
            try feedRepository.updateFeedMetadata(
                feedID: feedIDString,
                title: parsed.title,
                siteURL: parsed.siteURL?.absoluteString,
                storedIconURL: parsed.iconURL?.absoluteString ?? existing.storedIconURL,
                etag: etag,
                lastModified: lastModified,
                lastRefreshedAt: now,
                in: db
            )
            let newUnreads = try articleRepository.mergeParsedEntries(
                accountID: accountID,
                feedID: feedIDString,
                parsedEntries: parsed.entries,
                in: db
            )
            return (true, newUnreads)

        case .failure:
            return (false, [])
        }
    }

    // MARK: - State Management

    public func markRead(entryID: String, read: Bool = true) throws {
        try database.write { db in
            try self.stateRepository.markRead(itemID: entryID, isRead: read, in: db)
        }
    }

    public func markRead(entryIDs: [String], read: Bool = true) throws {
        try database.write { db in
            try self.stateRepository.markRead(itemIDs: entryIDs, isRead: read, in: db)
        }
    }

    public func markStarred(entryID: String, starred: Bool = true) throws {
        try database.write { db in
            try self.stateRepository.markStarred(itemID: entryID, isStarred: starred, in: db)
        }
    }

    public func markAllRead(
        feedID: UUID? = nil,
        feedIDs: Set<UUID>? = nil,
        folderName: String? = nil,
        startOfDayTimestamp: Double? = nil
    ) throws {
        try database.write { db in
            try self.stateRepository.markAllRead(
                accountID: self.accountID,
                feedID: feedID?.uuidString,
                feedIDs: feedIDs.map { Set($0.map(\.uuidString)) },
                folderName: folderName,
                startOfDayTimestamp: startOfDayTimestamp,
                in: db
            )
        }
    }

    // MARK: - Articles & Details

    public func fetchEntry(id: String) throws -> Entry? {
        try database.read { db in
            try self.articleRepository.fetchEntry(id: id, in: db)
        }
    }

    public func fetchAllEntries() throws -> [Entry] {
        try database.read { db in
            try self.articleRepository.fetchAllEntries(accountID: self.accountID, in: db)
        }
    }

    // MARK: - Caches & AI Artifacts

    public func fetchCache(entryID: String) throws -> ArticleCache? {
        try database.read { db in
            try self.cacheRepository.fetchCacheModel(itemID: entryID, in: db)
        }
    }

    public func saveCache(_ cache: ArticleCache) throws {
        try database.write { db in
            try self.cacheRepository.saveCacheModel(cache, in: db)
        }
    }

    /// 全量清除网页正文提取缓存并回收磁盘空间。返回删除的缓存行数。
    /// VACUUM 仅为空间回收优化，失败不影响「已清除」的结果语义（尽力而为）。
    public func clearAllCaches() throws -> Int {
        let count = try database.write { db in
            try self.cacheRepository.deleteAllCaches(in: db)
        }
        try? database.vacuum()
        return count
    }

    /// 当前网页正文缓存文章数与占用大小。
    public func cacheStats() throws -> ArticleCacheStats {
        try database.read { db in
            try self.cacheRepository.cacheStats(in: db)
        }
    }

    /// 当前本地 SQLite 数据库文件与文章/缓存统计。
    public func storageStats(cutoffDate: Date? = nil) throws -> LibraryDatabase.StorageStats {
        try database.storageStats(cutoffDate: cutoffDate)
    }

    /// 清理早于截止日期的已读且未标星文章（正文、离线缓存与 AI 产物）。
    public func purgeOldReadArticles(cutoffDate: Date, maxDuration: TimeInterval = 2.0) throws -> Int {
        try database.write { db in
            try self.articleRepository.purgeOldReadArticles(cutoffDate: cutoffDate, maxDuration: maxDuration, in: db)
        }
    }

    /// 清理超远期孤立墓碑记录。
    public func purgeExpiredTombstones(cutoffDate: Date, maxDuration: TimeInterval = 2.0) throws -> Int {
        try database.write { db in
            try self.articleRepository.purgeExpiredTombstones(cutoffDate: cutoffDate, maxDuration: maxDuration, in: db)
        }
    }

    /// 回收数据库磁盘空间。
    public func vacuum() throws {
        try database.vacuum()
    }

    public func fetchArtifact(entryID: String, kind: AIArtifactKind, isCompleteOnly: Bool = false, configurationFingerprint: String? = nil) throws -> AIArtifact? {
        try database.read { db in
            try self.artifactRepository.fetchLatestArtifactModel(entryID: entryID, kind: kind, isCompleteOnly: isCompleteOnly, configurationFingerprint: configurationFingerprint, in: db)
        }
    }

    public func fetchBilingualArtifact(entryID: String, contentHash: String, model: String, configurationFingerprint: String? = nil) throws -> AIArtifact? {
        try database.read { db in
            try self.artifactRepository.fetchBilingualArtifactModel(entryID: entryID, contentHash: contentHash, model: model, configurationFingerprint: configurationFingerprint, in: db)
        }
    }

    public func fetchBilingualArtifact(entryID: String, contentHash: String, targetLanguage: String) throws -> AIArtifact? {
        try database.read { db in
            try self.artifactRepository.fetchBilingualArtifactModel(
                entryID: entryID,
                contentHash: contentHash,
                targetLanguage: targetLanguage,
                in: db
            )
        }
    }

    public func fetchGlobalTranslationMemory(key: String) throws -> AIArtifact? {
        try database.read { db in
            try self.artifactRepository.fetchGlobalTranslationMemory(key: key, in: db)
        }
    }

    public func fetchSelectionArtifacts(entryID: String, articleHash: String) throws -> [AIArtifact] {
        try database.read { db in
            try self.artifactRepository.fetchSelectionArtifacts(entryID: entryID, articleHash: articleHash, in: db)
        }
    }

    public func saveArtifact(_ artifact: AIArtifact) throws {
        try database.write { db in
            try self.artifactRepository.saveArtifactModel(artifact, accountID: self.accountID, in: db)
        }
    }

    public func replaceCurrentSummary(with artifact: AIArtifact) throws {
        try database.write { db in
            try self.artifactRepository.replaceCurrentSummary(
                with: artifact,
                accountID: self.accountID,
                in: db
            )
        }
    }

    // MARK: - OPML

    public func exportOPML() throws -> Data {
        let feeds = try fetchFeeds()
        return OPMLService.export(feeds: feeds)
    }

    public func importOPML(_ data: Data) throws -> [UUID] {
        let urls = OPMLService.importURLs(data: data)
        return try database.write { db in
            try importOPMLURLs(urls, in: db)
        }
    }

    /// 在数据库 writer queue 批量导入 OPML，避免 300 个订阅逐条占用 MainActor。
    public func importOPMLAsync(_ data: Data) async throws -> [UUID] {
        let urls = OPMLService.importURLs(data: data)
        return try await database.writeAsync { db in
            try self.importOPMLURLs(urls, in: db)
        }
    }

    private func importOPMLURLs(_ urls: [URL], in db: Database) throws -> [UUID] {
        var newFeedIDs: [UUID] = []
        var seenURLs = Set<String>()
        let now = Date().timeIntervalSince1970
        var nextSortOrder = (try Int.fetchOne(
            db,
            sql: "SELECT MAX(sort_order) FROM feeds WHERE account_id = ?;",
            arguments: [accountID]
        )) ?? 0

        for url in urls where seenURLs.insert(url.absoluteString).inserted {
            let feedURLString = url.absoluteString
            let title = url.host ?? feedURLString
            if var existing = try feedRepository.fetchFeedByURL(
                accountID: accountID,
                feedURL: feedURLString,
                includeDeleted: true,
                in: db
            ) {
                guard existing.isDeleted else { continue }
                existing.isDeleted = false
                existing.updatedAt = now
                if !title.isEmpty { existing.title = title }
                try feedRepository.saveFeed(existing, in: db)
                if let id = UUID(uuidString: existing.id) {
                    newFeedIDs.append(id)
                }
                continue
            }

            nextSortOrder += 1
            let id = UUID()
            try feedRepository.saveFeed(
                FeedRecord(
                    id: id.uuidString,
                    accountID: accountID,
                    title: title,
                    feedURL: feedURLString,
                    updatedAt: now,
                    sortOrder: nextSortOrder
                ),
                in: db
            )
            newFeedIDs.append(id)
        }

        return newFeedIDs
    }

    // MARK: - AccountProvider

    public func refresh(reason: RefreshReason) async throws -> RefreshResult {
        let feeds = (try? fetchFeeds()) ?? []
        for feed in feeds {
            let singleRes = await fetchSingleFeed(feed: feed)
            _ = try? applyRefreshResult(singleRes)
        }
        return RefreshResult(status: .success)
    }

    public func pushPendingArticleStates() async throws {
        // Local 账号由本地 authoritative 维护，无需出站推送
    }

    // MARK: - AccountProvider CRUD

    public func addFeed(url: URL, title: String?, folder: String?) async throws -> Feed {
        let feedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? (url.host ?? url.absoluteString)
        return try addFeed(title: feedTitle, feedURL: url, siteURL: nil, folder: folder)
    }

    public func deleteFeed(feedID: UUID) async throws {
        try database.write { db in
            try self.feedRepository.deleteFeed(id: feedID.uuidString, in: db)
        }
    }

    public func addFolder(name: String) async throws -> FolderRecord {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw LocalAccountError.feedNotFound
        }
        try database.write { db in
            try self.feedRepository.addFolder(name: clean, accountID: self.accountID, in: db)
        }
        let folderID = "\(accountID):folder:\(clean)".stableDigest
        return try database.read { db in
            guard let folder = try FolderRecord.filter(Column("id") == folderID).fetchOne(db) else {
                throw LocalAccountError.feedNotFound
            }
            return folder
        }
    }

    public func deleteFolder(name: String) async throws {
        try database.write { db in
            try self.feedRepository.deleteFolder(name: name, accountID: self.accountID, in: db)
        }
    }
}
