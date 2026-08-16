import Foundation
import GRDB

/// Local 账号提供者。
///
/// 负责本地订阅账号在 SQLite 底层架构上的全部业务操作：
/// - 订阅源管理 (Feed / Folder)
/// - 网络拉取与增量合并 (Feed Fetch / SQLite Upsert)
/// - 阅读/星标状态流转 (ArticleState)
/// - 网页离线正文缓存 (ArticleCache)
/// - AI 生成产物与全局翻译记忆 (AIArtifact)
/// - OPML 导入与导出
public final class LocalAccountProvider: Sendable {
    public let accountID: String
    private let database: LibraryDatabase
    public let feedRepository: FeedRepository
    public let articleRepository: ArticleRepository
    public let stateRepository: ArticleStateRepository
    public let cacheRepository: CacheRepository
    public let artifactRepository: AIArtifactRepository
    public let timelineQueryService: TimelineQueryService
    private let feedFetcher: @Sendable (Feed) async throws -> FeedFetchResult

    public init(
        accountID: String = "local-default",
        database: LibraryDatabase,
        feedFetcher: (@Sendable (Feed) async throws -> FeedFetchResult)? = nil
    ) {
        self.accountID = accountID
        self.database = database
        self.feedRepository = FeedRepository(database: database)
        self.articleRepository = ArticleRepository(database: database)
        self.stateRepository = ArticleStateRepository(database: database)
        self.cacheRepository = CacheRepository(database: database)
        self.artifactRepository = AIArtifactRepository(database: database)
        self.timelineQueryService = TimelineQueryService(database: database)
        self.feedFetcher = feedFetcher ?? { feed in
            try await FeedService.fetch(feed)
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
        let feedUUID = UUID()
        let now = Date().timeIntervalSince1970
        let feedID = feedUUID.uuidString

        try database.write { db in
            let maxSort = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM feeds WHERE account_id = ?;", arguments: [self.accountID])) ?? 0
            let record = FeedRecord(
                id: feedID,
                accountID: self.accountID,
                externalID: nil,
                title: title,
                siteURL: siteURL?.absoluteString,
                feedURL: feedURL.absoluteString,
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

    public func deleteFeed(feedID: UUID) throws {
        try database.write { db in
            try self.feedRepository.softDeleteFeed(id: feedID.uuidString, in: db)
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

    public func fetchSingleFeed(feed: Feed, timeoutSeconds: Double = 10.0) async -> SingleFeedRefreshResult {
        let feedID = feed.id
        let title = feed.title
        do {
            let fetchResult = try await withThrowingTaskGroup(of: FeedFetchResult.self) { group in
                group.addTask {
                    try await self.feedFetcher(feed)
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

    /// 将单次抓取结果合并入 SQLite
    public func applyRefreshResult(
        _ taskResult: SingleFeedRefreshResult
    ) throws -> (updated: Bool, newUnreadEntries: [Entry]) {
        let feedIDString = taskResult.feedID.uuidString
        let now = Date().timeIntervalSince1970

        return try database.write { db in
            guard let existing = try self.feedRepository.fetchFeed(id: feedIDString, in: db),
                  !existing.isDeleted else {
                return (false, [])
            }

            switch taskResult.result {
            case let .success(.notModified(etag, lastModified)):
                try self.feedRepository.updateFeedMetadata(
                    feedID: feedIDString,
                    etag: etag,
                    lastModified: lastModified,
                    lastRefreshedAt: now,
                    in: db
                )
                return (false, [])

            case let .success(.updated(parsed, etag, lastModified)):
                try self.feedRepository.updateFeedMetadata(
                    feedID: feedIDString,
                    title: parsed.title,
                    siteURL: parsed.siteURL?.absoluteString,
                    storedIconURL: parsed.iconURL?.absoluteString ?? existing.storedIconURL,
                    etag: etag,
                    lastModified: lastModified,
                    lastRefreshedAt: now,
                    in: db
                )
                let newUnreads = try self.articleRepository.mergeParsedEntries(
                    accountID: self.accountID,
                    feedID: feedIDString,
                    parsedEntries: parsed.entries,
                    in: db
                )
                return (true, newUnreads)

            case .failure:
                return (false, [])
            }
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

    public func markAllRead(feedID: UUID? = nil, folderName: String? = nil) throws {
        try database.write { db in
            try self.stateRepository.markAllRead(
                accountID: self.accountID,
                feedID: feedID?.uuidString,
                folderName: folderName,
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

    public func fetchArtifact(entryID: String, kind: AIArtifactKind, isCompleteOnly: Bool = false) throws -> AIArtifact? {
        try database.read { db in
            try self.artifactRepository.fetchLatestArtifactModel(entryID: entryID, kind: kind, isCompleteOnly: isCompleteOnly, in: db)
        }
    }

    public func fetchBilingualArtifact(entryID: String, contentHash: String, model: String) throws -> AIArtifact? {
        try database.read { db in
            try self.artifactRepository.fetchBilingualArtifactModel(entryID: entryID, contentHash: contentHash, model: model, in: db)
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

    // MARK: - OPML

    public func exportOPML() throws -> Data {
        let feeds = try fetchFeeds()
        return OPMLService.export(feeds: feeds)
    }

    public func importOPML(_ data: Data) throws -> [UUID] {
        let urls = OPMLService.importURLs(data: data)
        var newFeedIDs: [UUID] = []
        let existingFeeds = try fetchFeeds()
        let existingFeedURLs = Set(existingFeeds.map(\.feedURL))

        for url in urls where !existingFeedURLs.contains(url) {
            let title = url.host ?? url.absoluteString
            let feed = try addFeed(title: title, feedURL: url)
            newFeedIDs.append(feed.id)
        }
        return newFeedIDs
    }
}
