import Combine
import Foundation
import GRDB
import SwiftUI

public enum AppTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    @MainActor
    public var title: String {
        switch self {
        case .system: I18N.shared.localized("跟随系统")
        case .light: I18N.shared.localized("浅色模式")
        case .dark: I18N.shared.localized("深色模式")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum AIRequestPhase: Sendable, Equatable {
    case loadingLocalConfiguration
    case generating

    public var message: String {
        switch self {
        case .loadingLocalConfiguration: I18N.localized("正在读取本机 AI 配置…")
        case .generating: I18N.localized("正在生成，完成后会自动显示。")
        }
    }
}

public struct AIRequestStatus: Sendable, Equatable {
    public let entryID: String
    public let kind: AIArtifactKind
    public let phase: AIRequestPhase

    public init(entryID: String, kind: AIArtifactKind, phase: AIRequestPhase) {
        self.entryID = entryID
        self.kind = kind
        self.phase = phase
    }
}

/// 单篇正文重新拉取完成后的失效信号，用于驱动阅读页自动重载。
public struct ArticleRefreshSignal: Sendable, Equatable {
    public let entryID: String
    public let token: UUID

    public init(entryID: String, token: UUID) {
        self.entryID = entryID
        self.token = token
    }
}

@MainActor
public final class AppStore: ObservableObject {
    @Published public var appLanguage: AppLanguage = I18N.shared.language {
        didSet {
            I18N.shared.language = appLanguage
        }
    }
    @Published public private(set) var appTheme: AppTheme = .system
    @Published public private(set) var articleFontSize: Int = 17

    /// Feed 图标仓库：行渲染经它同步查询已就绪图标，杜绝 AsyncImage 加载期闪烁。
    public let iconStore = FeedIconStore()

    @Published public private(set) var feeds: [Feed] = []
    @Published public private(set) var customFolders: [String] = []
    @Published public private(set) var sidebarCounts: SidebarCounts = SidebarCounts()
    @Published public private(set) var entryListItems: [EntryListItem] = []
    @Published public private(set) var todayEntryListItems: [EntryListItem] = []
    @Published public private(set) var unreadEntryListItems: [EntryListItem] = []
    @Published public private(set) var starredEntryListItems: [EntryListItem] = []
    @Published public private(set) var timelineRevision: UInt64 = 0
    @Published public private(set) var articleRefreshSignal: ArticleRefreshSignal?
    @Published public private(set) var activeRefetchEntryIDs: Set<String> = []
    @Published public var llmConfiguration: LLMConfiguration = .default

    /// 进程内已准备正文 LRU 缓存：命中时 Reader 可跳过 prepare 管线即时换页。
    public private(set) var preparedArticleMemoryCache = PreparedArticleMemoryCache()
    private var neighborPrefetchTask: Task<Void, Never>?

    @Published public private(set) var refreshProgress: (current: Int, total: Int)? = nil
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var refreshStatus: FeedRefreshStatus = .idle
    @Published public private(set) var latestRefreshOutcome: FeedRefreshOutcome?
    @Published public private(set) var refreshInterval: FeedRefreshInterval = .twoHours
    @Published public private(set) var refreshOnLaunch: Bool = true
    @Published public private(set) var lastError: String?
    @Published public private(set) var isICloudSyncEnabled = false

    private enum ICloudSyncState {
        case disabled
        case waiting
        case synced(Date)
        case failed(String)
        case notEntitled
    }

    @Published private var iCloudSyncState: ICloudSyncState = .disabled
    public var iCloudSyncStatus: String {
        switch iCloudSyncState {
        case .disabled:
            return I18N.localized("未启用")
        case .waiting:
            return I18N.localized("等待同步")
        case let .synced(date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: appLanguage.localeIdentifier)
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return I18N.localizedFormat("上次同步：%@", arguments: [formatter.string(from: date)])
        case let .failed(message):
            return I18N.localizedFormat("同步失败：%@", arguments: [message])
        case .notEntitled:
            return CloudSyncError.notEntitled.localizedDescription
        }
    }

    @Published public private(set) var activeSummaryRequest: AIRequestStatus?
    @Published public private(set) var activeBilingualRequest: AIRequestStatus?
    @Published public private(set) var activeSelectionRequest: AIRequestStatus?

    public var activeAIRequest: AIRequestStatus? {
        activeSummaryRequest ?? activeBilingualRequest ?? activeSelectionRequest
    }

    public func activeAIStatus(for kind: AIArtifactKind) -> AIRequestStatus? {
        switch kind {
        case .summary: return activeSummaryRequest
        case .bilingual: return activeBilingualRequest
        case .translation, .selectionExplanation, .articleContext, .interpretation: return activeSelectionRequest
        }
    }

    private var activeBilingualTask: Task<Void, Never>?

    public func cancelBilingualTranslation() {
        activeBilingualTask?.cancel()
        activeBilingualTask = nil
        activeBilingualRequest = nil
    }

    @Published public private(set) var updateStatus: UpdateCheckStatus = .idle
    @Published public private(set) var ignoredVersion: String?
    @Published public private(set) var activeBilingualEntryIDs: Set<String> = []

    public func isBilingualActive(for entryID: String) -> Bool {
        activeBilingualEntryIDs.contains(entryID)
    }

    public func toggleBilingualMode(for entryID: String) {
        if activeBilingualEntryIDs.contains(entryID) {
            activeBilingualEntryIDs.remove(entryID)
            cancelBilingualTranslation()
        } else {
            activeBilingualEntryIDs.insert(entryID)
        }
    }

    public let libraryDatabase: LibraryDatabase
    public let localProvider: LocalAccountProvider
    public let credentialStore: CredentialStore
    public let syncCoordinator: SyncCoordinator
    public let accountRepository: AccountRepository
    public let customSession: URLSession?

    @Published public private(set) var accounts: [AccountRecord] = []
    @Published public var activeAccountID: String = "local-default"
    @Published public private(set) var accountSyncStates: [String: AccountSyncStateRecord] = [:]

    private let persistenceURL: URL
    private let feedFetcher: @Sendable (Feed) async throws -> FeedFetchResult
    private let llm = LLMService()
    private let preparationEngine: ArticlePreparationEngine
    private var automaticRefreshTask: Task<Void, Never>?

    private enum PreferenceKey {
        static let refreshInterval = "PaperRss.refreshInterval"
        static let refreshOnLaunch = "PaperRss.refreshOnLaunch"
        static let appTheme = "PaperRss.appTheme"
        static let articleFontSize = "PaperRss.articleFontSize"
        static let ignoredVersion = "PaperRss.ignoredVersion"
        static let llmConfiguration = "PaperRss.llmConfiguration"
    }

    @Published public private(set) var startupError: Error?
    public static let defaultTimelineLimit: Int = 100
    private var cachedEntryLookup: [String: Entry] = [:]

    // MARK: - Initializer

    public init(
        fileManager: FileManager = .default,
        databaseURL: URL? = nil,
        persistenceURL: URL? = nil,
        credentialStore: CredentialStore? = nil,
        customSession: URLSession? = nil,
        pageLoader: (any ArticlePageLoading)? = nil,
        feedFetcher: (@Sendable (Feed) async throws -> FeedFetchResult)? = nil
    ) {
        let actualFetcher = feedFetcher ?? { try await FeedService.fetch($0) }
        self.feedFetcher = actualFetcher
        self.customSession = customSession
        self.preparationEngine = ArticlePreparationEngine(pageLoader: pageLoader ?? DefaultArticlePageLoader())
        let applicationSupport = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        let directory = applicationSupport.appendingPathComponent("PaperRss", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.persistenceURL = persistenceURL ?? directory.appendingPathComponent("library.json")
        let sqliteURL = databaseURL ?? directory.appendingPathComponent("library.sqlite")

        do {
            self.libraryDatabase = try LibraryDatabase(databaseURL: sqliteURL)
        } catch {
            fatalError("Failed to initialize LibraryDatabase: \(error)")
        }

        self.credentialStore = credentialStore ?? KeychainCredentialStore.shared
        self.syncCoordinator = SyncCoordinator()
        self.accountRepository = AccountRepository(database: libraryDatabase)

        self.localProvider = LocalAccountProvider(
            accountID: "local-default",
            database: libraryDatabase,
            feedFetcher: actualFetcher
        )

        Task { [syncCoordinator, localProvider] in
            await syncCoordinator.registerProvider(localProvider)
        }

        // 1. Recover LLM Configuration from legacy JSON if needed (Independent of SQLite migration state)
        if let recovered = LegacyPreferenceMigrator.recoverLLMConfigurationIfNeeded(from: self.persistenceURL, fileManager: fileManager) {
            self.llmConfiguration = recovered
        }

        // 2. Startup Migration Sequence:
        var migrationSucceededOrNotNeeded = true
        if fileManager.fileExists(atPath: self.persistenceURL.path) {
            let migrator = LegacyJSONMigrator(database: libraryDatabase)
            do {
                let result = try migrator.migrate(from: self.persistenceURL)
                switch result {
                case .success, .alreadyCompleted, .noLegacySource:
                    migrationSucceededOrNotNeeded = true
                }
            } catch {
                migrationSucceededOrNotNeeded = false
                self.startupError = error
                self.lastError = I18N.localizedFormat("迁移历史数据失败：%@", arguments: [error.localizedDescription])
            }
        }

        // 3. Load Preferences
        let preferences = UserDefaults.standard
        refreshInterval = FeedRefreshInterval(rawValue: preferences.string(forKey: PreferenceKey.refreshInterval) ?? "") ?? .twoHours
        refreshOnLaunch = preferences.object(forKey: PreferenceKey.refreshOnLaunch) as? Bool ?? true
        let rawTheme = preferences.string(forKey: PreferenceKey.appTheme) ?? ""
        appTheme = AppTheme(rawValue: rawTheme) ?? .system
        let storedFontSize = preferences.integer(forKey: PreferenceKey.articleFontSize)
        articleFontSize = (13...25).contains(storedFontSize) ? storedFontSize : 17
        ignoredVersion = preferences.string(forKey: PreferenceKey.ignoredVersion)

        if let data = preferences.data(forKey: PreferenceKey.llmConfiguration),
           let savedConfig = try? JSONDecoder().decode(LLMConfiguration.self, from: data) {
            llmConfiguration = savedConfig
        } else {
            llmConfiguration = .default
        }

        let storedICloudSyncEnabled = UserDefaults.standard.bool(forKey: "PaperRss.iCloudSyncEnabled")
        if storedICloudSyncEnabled && !CloudSyncService.isICloudEntitled {
            UserDefaults.standard.set(false, forKey: "PaperRss.iCloudSyncEnabled")
            isICloudSyncEnabled = false
            iCloudSyncState = .notEntitled
        } else {
            isICloudSyncEnabled = storedICloudSyncEnabled
            iCloudSyncState = isICloudSyncEnabled ? .waiting : .disabled
        }

        // 4. Reload State from SQLite ONLY IF migration succeeded or not needed
        if migrationSucceededOrNotNeeded {
            try? localProvider.ensureAccountExists()
            reloadState()
        }

        Task { [weak self] in
            await self?.checkForUpdates(isUserInitiated: false)
        }
    }

    /// 测试用初始化器（隔离测试沙箱）
    public init(
        testDatabase: AppDatabase,
        feedFetcher: @escaping @Sendable (Feed) async throws -> FeedFetchResult,
        credentialStore: CredentialStore? = nil
    ) {
        self.feedFetcher = feedFetcher
        self.customSession = nil
        self.preparationEngine = ArticlePreparationEngine()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.persistenceURL = tempDir.appendingPathComponent("library.json")
        let sqliteURL = tempDir.appendingPathComponent("library.sqlite")

        do {
            self.libraryDatabase = try LibraryDatabase(databaseURL: sqliteURL)
        } catch {
            fatalError("Failed to initialize test LibraryDatabase: \(error)")
        }

        self.credentialStore = credentialStore ?? InMemoryCredentialStore()
        self.syncCoordinator = SyncCoordinator()
        self.accountRepository = AccountRepository(database: libraryDatabase)

        self.localProvider = LocalAccountProvider(
            accountID: "local-default",
            database: libraryDatabase,
            feedFetcher: feedFetcher
        )

        Task { [syncCoordinator, localProvider] in
            await syncCoordinator.registerProvider(localProvider)
        }

        var migrationSucceededOrNotNeeded = true
        // 写入测试 JSON 并执行迁移
        if let data = try? JSONEncoder.paperRss.encode(testDatabase) {
            try? data.write(to: persistenceURL)
            let migrator = LegacyJSONMigrator(database: libraryDatabase)
            do {
                _ = try migrator.migrate(from: persistenceURL)
            } catch {
                migrationSucceededOrNotNeeded = false
                self.startupError = error
                self.lastError = error.localizedDescription
            }
        }

        if migrationSucceededOrNotNeeded {
            try? localProvider.ensureAccountExists()
        }

        let preferences = UserDefaults.standard
        refreshInterval = FeedRefreshInterval(rawValue: preferences.string(forKey: PreferenceKey.refreshInterval) ?? "") ?? .twoHours
        refreshOnLaunch = preferences.object(forKey: PreferenceKey.refreshOnLaunch) as? Bool ?? true
        let rawTheme = preferences.string(forKey: PreferenceKey.appTheme) ?? ""
        appTheme = AppTheme(rawValue: rawTheme) ?? .system
        let storedFontSize = preferences.integer(forKey: PreferenceKey.articleFontSize)
        articleFontSize = (13...25).contains(storedFontSize) ? storedFontSize : 17
        ignoredVersion = preferences.string(forKey: PreferenceKey.ignoredVersion)
        llmConfiguration = testDatabase.llmConfiguration

        if migrationSucceededOrNotNeeded {
            reloadState()
        }
    }

    // MARK: - State Reload & Querying

    @Published public var feedsByAccount: [String: [Feed]] = [:]
    @Published public var foldersByAccount: [String: [String]] = [:]

    public func reloadState() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date()).timeIntervalSince1970
        let limit = Self.defaultTimelineLimit

        // 1. 读取所有账号（包括已禁用账号，供设置页管理与切换）
        let fetchedAccounts = (try? libraryDatabase.read { db in
            try AccountRecord.order(Column("created_at").asc).fetchAll(db)
        }) ?? []
        self.accounts = fetchedAccounts

        // 2. 加载全库/多账号 Feeds 与 Folders 投影
        var newFeedsByAccount: [String: [Feed]] = [:]
        var newFoldersByAccount: [String: [String]] = [:]

        if let allFeeds = try? libraryDatabase.read({ db in
            try self.localProvider.feedRepository.fetchAllFeedModels(accountID: nil, in: db)
        }) {
            for feed in allFeeds {
                // 通过 DB 查询所属 account_id
                let accID = (try? libraryDatabase.read { db in
                    try FeedRecord.filter(Column("id") == feed.id.uuidString).fetchOne(db)?.accountID
                }) ?? "local-default"
                newFeedsByAccount[accID, default: []].append(feed)
            }
        }

        if let allFolders = try? libraryDatabase.read({ db in
            try self.localProvider.feedRepository.fetchAllFolders(accountID: nil, in: db)
        }) {
            for folder in allFolders {
                newFoldersByAccount[folder.accountID, default: []].append(folder.name)
            }
        }

        self.feedsByAccount = newFeedsByAccount
        self.foldersByAccount = newFoldersByAccount
        self.feeds = newFeedsByAccount["local-default"] ?? []
        self.customFolders = newFoldersByAccount["local-default"] ?? []
        self.sidebarCounts = (try? localProvider.timelineQueryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)) ?? SidebarCounts()

        self.entryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .all, limit: limit)) ?? []
        self.todayEntryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .today(startOfDayTimestamp: startOfDay), limit: limit)) ?? []
        self.unreadEntryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .unread, limit: limit)) ?? []
        self.starredEntryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .starred, limit: limit)) ?? []
        self.cachedEntryLookup.removeAll(keepingCapacity: true)

        // 3. 读取 SyncState 并维护启用的 FreshRSS Providers
        var syncStates: [String: AccountSyncStateRecord] = [:]
        for account in fetchedAccounts {
            if let state = try? libraryDatabase.read({ db in
                try AccountSyncStateRecord.filter(Column("account_id") == account.id).fetchOne(db)
            }) {
                syncStates[account.id] = state
            }
            if account.type == AccountType.freshRSS.rawValue {
                if account.isEnabled, let urlStr = account.endpointURL, let url = URL(string: urlStr), let username = account.username {
                    let provider = FreshRSSAccountProvider(
                        accountID: account.id,
                        endpointURL: url,
                        username: username,
                        database: libraryDatabase,
                        credentialStore: credentialStore,
                        session: customSession
                    )
                    Task { [syncCoordinator] in
                        await syncCoordinator.registerProvider(provider)
                    }
                } else {
                    Task { [syncCoordinator] in
                        await syncCoordinator.unregisterProvider(accountID: account.id)
                    }
                }
            }
        }
        self.accountSyncStates = syncStates
        self.timelineRevision &+= 1
    }

    public var enabledAccounts: [AccountRecord] {
        accounts.filter { $0.isEnabled }
    }

    public func isAccountEnabled(_ accountID: String) -> Bool {
        accounts.first { $0.id == accountID }?.isEnabled ?? (accountID == "local-default")
    }

    public func setAccountEnabled(accountID: String, isEnabled: Bool) async throws {
        try await accountRepository.updateAccountEnabled(id: accountID, isEnabled: isEnabled)
        if !isEnabled {
            await syncCoordinator.unregisterProvider(accountID: accountID)
        }
        reloadState()
    }

    public func accountID(forFeedID feedID: UUID) -> String {
        for (accID, feeds) in feedsByAccount {
            if feeds.contains(where: { $0.id == feedID }) {
                return accID
            }
        }
        return "local-default"
    }

    // MARK: - Computed Public Accessors

    public func feeds(for accountID: String) -> [Feed] {
        feedsByAccount[accountID] ?? []
    }

    public func rootFeeds(for accountID: String) -> [Feed] {
        (feedsByAccount[accountID] ?? []).filter { $0.folder == nil }
    }

    public func folders(for accountID: String) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for folder in foldersByAccount[accountID] ?? [] where !seen.contains(folder) {
            names.append(folder)
            seen.insert(folder)
        }
        for feed in feedsByAccount[accountID] ?? [] {
            if let folder = feed.folder, !seen.contains(folder) {
                names.append(folder)
                seen.insert(folder)
            }
        }
        return names
    }

    public func feeds(in folder: String, for accountID: String) -> [Feed] {
        (feedsByAccount[accountID] ?? []).filter { $0.folder == folder }
    }

    public var rootFeeds: [Feed] { feeds.filter { $0.folder == nil } }
    public var folders: [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for folder in customFolders where !seen.contains(folder) {
            names.append(folder)
            seen.insert(folder)
        }
        for feed in feeds {
            if let folder = feed.folder, !seen.contains(folder) {
                names.append(folder)
                seen.insert(folder)
            }
        }
        return names
    }

    @available(*, deprecated, message: "For testing only. Production Views must use entryListItems and sidebarCounts")
    public var entries: [Entry] {
        (try? localProvider.fetchAllEntries()) ?? []
    }

    @available(*, deprecated, message: "For testing only. Production Views must use entryListItems and sidebarCounts")
    public var todayEntries: [Entry] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date()).timeIntervalSince1970
        return entries.filter {
            let ts = $0.publishedAt?.timeIntervalSince1970 ?? $0.updatedAt.timeIntervalSince1970
            return ts >= startOfDay
        }
    }

    public var todayUnreadCount: Int { sidebarCounts.todayUnread }

    @available(*, deprecated, message: "For testing only. Production Views must use entryListItems and sidebarCounts")
    public var unreadEntries: [Entry] { entries.filter { !$0.isRead } }

    @available(*, deprecated, message: "For testing only. Production Views must use entryListItems and sidebarCounts")
    public var starredEntries: [Entry] { entries.filter { $0.isStarred } }

    public func unreadCount(feedID: UUID) -> Int { sidebarCounts.unreadByFeed[feedID, default: 0] }
    public func unreadCount(folder: String, accountID: String = "local-default") -> Int {
        sidebarCounts.unreadCount(folder: folder, accountID: accountID)
    }

    public func unreadCount(scope: TimelineScope) -> Int {
        switch scope {
        case .all:
            return sidebarCounts.allUnread
        case .today:
            return sidebarCounts.todayUnread
        case .unread:
            return sidebarCounts.allUnread
        case .starred:
            return sidebarCounts.starred
        case let .folder(accountID, folderName):
            return sidebarCounts.unreadCount(folder: folderName, accountID: accountID)
        case let .feed(feedIDStr):
            if let uuid = UUID(uuidString: feedIDStr) {
                return sidebarCounts.unreadByFeed[uuid, default: 0]
            }
            return 0
        case let .feeds(feedIDStrs):
            let uuids = feedIDStrs.compactMap { UUID(uuidString: $0) }
            return uuids.reduce(0) { $0 + sidebarCounts.unreadByFeed[$1, default: 0] }
        }
    }

    public func unreadEntryListItems(retainingIDs: Set<String>) -> [EntryListItem] {
        (try? localProvider.timelineQueryService.fetchListItems(scope: .unread, retainingIDs: retainingIDs)) ?? unreadEntryListItems
    }

    public func starredEntryListItems(retainingIDs: Set<String>) -> [EntryListItem] {
        (try? localProvider.timelineQueryService.fetchListItems(scope: .starred, retainingIDs: retainingIDs)) ?? starredEntryListItems
    }

    public func entryListItems(feedID: UUID) -> [EntryListItem] {
        (try? localProvider.timelineQueryService.fetchListItems(scope: .feed(feedID: feedID.uuidString))) ?? []
    }

    public func entryListItems(feedIDs: Set<UUID>) -> [EntryListItem] {
        guard !feedIDs.isEmpty else { return [] }
        let ids = Set(feedIDs.map(\.uuidString))
        return (try? localProvider.timelineQueryService.fetchListItems(scope: .feeds(feedIDs: ids))) ?? []
    }

    public func entryListItems(folder: String, accountID: String = "local-default") -> [EntryListItem] {
        (try? localProvider.timelineQueryService.fetchListItems(scope: .folder(accountID: accountID, folderName: folder))) ?? []
    }

    public func fetchTimelinePage(
        scope: TimelineScope,
        retainingIDs: Set<String> = [],
        limit: Int = 100,
        offset: Int = 0
    ) -> [EntryListItem] {
        (try? localProvider.timelineQueryService.fetchListItems(
            scope: scope,
            retainingIDs: retainingIDs,
            limit: limit,
            offset: offset
        )) ?? []
    }

    public func fetchAdjacentItem(
        scope: TimelineScope,
        currentItemID: String,
        direction: AdjacentTimelineDirection,
        retainingIDs: Set<String> = []
    ) -> EntryListItem? {
        try? localProvider.timelineQueryService.fetchAdjacentItem(
            scope: scope,
            currentItemID: currentItemID,
            direction: direction,
            retainingIDs: retainingIDs
        )
    }

    public func entryListItems(folder: String) -> [EntryListItem] {
        (try? localProvider.timelineQueryService.fetchListItems(scope: .folder(folderName: folder))) ?? []
    }

    public func entries(feedID: UUID?) -> [Entry] {
        guard let feedID else { return entries }
        return entries.filter { $0.feedID == feedID }
    }

    public func entries(folder: String) -> [Entry] {
        let feedIDs = Set(feeds.filter { $0.folder == folder }.map(\.id))
        return entries.filter { feedIDs.contains($0.feedID) }
    }

    public func entry(id: String) -> Entry? {
        if let cached = cachedEntryLookup[id] {
            return cached
        }
        guard let fetched = try? localProvider.fetchEntry(id: id) else { return nil }
        if cachedEntryLookup.count >= 100 {
            cachedEntryLookup.removeAll(keepingCapacity: true)
        }
        cachedEntryLookup[id] = fetched
        return fetched
    }

    public func feed(for entry: Entry) -> Feed? {
        feed(forFeedID: entry.feedID)
    }

    public func feed(forFeedID feedID: UUID) -> Feed? {
        if let local = feeds.first(where: { $0.id == feedID }) {
            return local
        }
        for accountFeeds in feedsByAccount.values {
            if let matched = accountFeeds.first(where: { $0.id == feedID }) {
                return matched
            }
        }
        return nil
    }

    // MARK: - Feed & Folder Management

    public func setFeedFolder(_ feed: Feed, folder: String?) {
        setFeedFolder(feedID: feed.id, folder: folder)
    }

    public func setFeedFolder(feedID: UUID, folder: String?) {
        try? localProvider.setFeedFolder(feedID: feedID, folderName: folder)
        reloadState()
    }

    public func setFeedFolder(feedIDs: Set<UUID>, folder: String?) {
        guard !feedIDs.isEmpty else { return }
        try? localProvider.setFeedFolder(feedIDs: feedIDs, folderName: folder)
        reloadState()
    }

    public func addFolder(_ name: String) {
        guard let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return }
        try? localProvider.addFolder(name: clean)
        reloadState()
    }

    public func deleteFolder(_ name: String) {
        try? localProvider.deleteFolder(name: name)
        reloadState()
    }

    public func renameFolder(from oldName: String, to newName: String) {
        try? localProvider.renameFolder(oldName: oldName, newName: newName)
        reloadState()
    }

    public func addFeed(urlText: String, folder: String? = nil) async {
        guard let url = normalizedURL(urlText) else {
            lastError = I18N.localized("请输入有效的 Feed URL。")
            return
        }

        let title = url.host ?? url.absoluteString
        let feed: Feed
        do {
            feed = try localProvider.addFeed(title: title, feedURL: url, folder: folder)
        } catch let error as LocalAccountError {
            lastError = error.errorDescription
            return
        } catch {
            lastError = error.localizedDescription
            return
        }

        reloadState()
        await refresh(feedIDs: [feed.id], origin: .subscriptionManagement)
    }

    public func removeFeed(_ feed: Feed) {
        try? localProvider.deleteFeed(feedID: feed.id)
        reloadState()
    }

    public func deleteFeed(_ feed: Feed) {
        removeFeed(feed)
    }

    public func deleteFeeds(_ feedsToDelete: [Feed]) {
        for feed in feedsToDelete {
            try? localProvider.deleteFeed(feedID: feed.id)
        }
        reloadState()
    }

    public func deleteFeeds(_ ids: Set<UUID>) {
        for id in ids {
            try? localProvider.deleteFeed(feedID: id)
        }
        reloadState()
    }

    public func deleteFeeds(_ ids: [UUID]) {
        deleteFeeds(Set(ids))
    }

    public func reorderRootFeeds(orderedIDs: [UUID]) {
        var currentFeeds = self.feeds
        let idOrder = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        currentFeeds.sort {
            let rank1 = idOrder[$0.id, default: .max]
            let rank2 = idOrder[$1.id, default: .max]
            return rank1 < rank2
        }
        self.feeds = currentFeeds
        try? libraryDatabase.write { db in
            for (idx, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE feeds SET sort_order = ? WHERE id = ?;", arguments: [idx, id.uuidString])
            }
        }
    }

    public func reorderRootFeeds(fromOffsets: IndexSet, toOffset: Int) {
        var currentRootIDs = rootFeeds.map(\.id)
        currentRootIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        reorderRootFeeds(orderedIDs: currentRootIDs)
    }

    public func feeds(in folder: String) -> [Feed] {
        feeds.filter { $0.folder == folder }
    }

    public func reorderFeeds(in folder: String, fromOffsets: IndexSet, toOffset: Int) {
        var folderFeedIDs = feeds(in: folder).map(\.id)
        folderFeedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try? libraryDatabase.write { db in
            for (idx, id) in folderFeedIDs.enumerated() {
                try db.execute(sql: "UPDATE feeds SET sort_order = ? WHERE id = ?;", arguments: [idx, id.uuidString])
            }
        }
        reloadState()
    }

    public func reorderFolders(fromOffsets: IndexSet, toOffset: Int) {
        var names = folders
        names.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try? libraryDatabase.write { db in
            for (idx, name) in names.enumerated() {
                try db.execute(sql: "UPDATE folders SET sort_order = ? WHERE name = ? AND account_id = 'local-default';", arguments: [idx, name])
            }
        }
        reloadState()
    }

    public func setICloudSyncEnabled(_ enabled: Bool) {
        if enabled && !CloudSyncService.isICloudEntitled {
            isICloudSyncEnabled = false
            iCloudSyncState = .notEntitled
            UserDefaults.standard.set(false, forKey: "PaperRss.iCloudSyncEnabled")
            return
        }
        isICloudSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "PaperRss.iCloudSyncEnabled")
        iCloudSyncState = enabled ? .waiting : .disabled
    }

    public func syncICloud() async {
        // 本 Goal 专注于 Local Account & SQLite Cutover
    }

    public func importOPML(_ data: Data) async {
        let newFeedIDs = (try? localProvider.importOPML(data)) ?? []
        guard !newFeedIDs.isEmpty else { return }
        reloadState()
        await refresh(feedIDs: newFeedIDs, origin: .subscriptionManagement)
    }

    public func exportOPML() -> Data {
        (try? localProvider.exportOPML()) ?? Data()
    }

    // MARK: - Feed Refreshing

    @discardableResult
    public func refresh(
        feedIDs: [UUID]? = nil,
        reportErrors: Bool = true,
        origin: FeedRefreshOrigin = .manual
    ) async -> FeedRefreshOutcome? {
        guard !isRefreshing else { return nil }
        let startedAt = Date.now
        isRefreshing = true
        defer { isRefreshing = false }
        refreshStatus = .refreshing

        var failures: [String] = []
        var updatedFeeds = 0
        var newUnreadEntries: [Entry] = []

        // 1. 本地源抓取（指定局部源或全局本地源）
        let targetFeeds: [Feed]
        if let feedIDs {
            targetFeeds = feeds.filter { feedIDs.contains($0.id) && !$0.isDeleted }
        } else if isAccountEnabled("local-default") {
            targetFeeds = feeds.filter { !$0.isDeleted }
        } else {
            targetFeeds = []
        }

        let total = targetFeeds.count
        refreshProgress = (0, total)
        defer { refreshProgress = nil }

        let maxConcurrency = 6
        let provider = self.localProvider
        var completedCount = 0

        await withTaskGroup(of: LocalAccountProvider.SingleFeedRefreshResult.self) { group in
            var feedIndex = 0

            while feedIndex < targetFeeds.count && feedIndex < maxConcurrency {
                let feed = targetFeeds[feedIndex]
                feedIndex += 1
                group.addTask {
                    await provider.fetchSingleFeed(feed: feed)
                }
            }

            while let taskResult = await group.next() {
                completedCount += 1
                refreshProgress = (completedCount, total)

                do {
                    let outcome = try provider.applyRefreshResult(taskResult)
                    if outcome.updated { updatedFeeds += 1 }
                    newUnreadEntries.append(contentsOf: outcome.newUnreadEntries)
                } catch {
                    failures.append("\(taskResult.oldTitle)：\(error.localizedDescription)")
                }

                if case let .failure(error) = taskResult.result {
                    failures.append("\(taskResult.oldTitle)：\(error.localizedDescription)")
                }

                if feedIndex < targetFeeds.count {
                    let feed = targetFeeds[feedIndex]
                    feedIndex += 1
                    group.addTask {
                        await provider.fetchSingleFeed(feed: feed)
                    }
                }
            }
        }

        // 2. 全局刷新时，仅协调刷新所有远端账号（排除 local-default，杜绝本地重复刷新）
        if feedIDs == nil {
            let initialUnreadIDs = Set(self.unreadEntryListItems.map(\.id))

            let syncResults = await syncCoordinator.refreshRemoteAccounts(reason: origin == .manual ? .manual : .scheduled)

            for (accID, res) in syncResults {
                switch res {
                case .success(let result):
                    if case let .failed(msg) = result.status {
                        failures.append("账号 \(accID)：\(msg)")
                    }
                case .failure(let error):
                    failures.append("账号 \(accID)：\(error.localizedDescription)")
                }
            }

            // 重新载入全量状态，确保成功账号的数据即刻生效
            reloadState()

            // 提取远端同步产生的新未读文章
            let currentUnreads = self.unreadEntryListItems.map(\.id)
            let newlyArrivedIDs = currentUnreads.filter { !initialUnreadIDs.contains($0) }
            for id in newlyArrivedIDs {
                if let entry = entry(id: id) {
                    newUnreadEntries.append(entry)
                }
            }
        }

        reloadState()

        let finishedAt = Date.now
        var reportedEntryIDs: Set<String> = []
        let finalNewUnreads = newUnreadEntries.compactMap { candidate -> Entry? in
            guard reportedEntryIDs.insert(candidate.id).inserted,
                  let current = try? localProvider.fetchEntry(id: candidate.id) ?? self.entry(id: candidate.id),
                  !current.isRead else { return nil }
            return current
        }

        let outcome = FeedRefreshOutcome(
            origin: origin,
            newUnreadEntries: finalNewUnreads,
            updatedFeedCount: updatedFeeds,
            failedFeedCount: failures.count,
            finishedAt: finishedAt
        )
        latestRefreshOutcome = outcome

        if failures.isEmpty {
            refreshStatus = .completed(updatedFeeds: updatedFeeds, finishedAt: finishedAt)
        } else {
            let message = failures.joined(separator: "\n")
            refreshStatus = .failed(message: message, finishedAt: finishedAt)
            if reportErrors { lastError = message }
        }

        let minimumIndicatorDuration: TimeInterval = 1.2
        let remainingDuration = minimumIndicatorDuration - Date.now.timeIntervalSince(startedAt)
        if remainingDuration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainingDuration * 1_000_000_000))
        }

        return outcome
    }

    // MARK: - State Management

    private func updateLocalEntryState(entryID: String, isRead: Bool? = nil, isStarred: Bool? = nil) {
        func updateList(_ list: inout [EntryListItem]) {
            guard let index = list.firstIndex(where: { $0.id == entryID }) else { return }
            var item = list[index]
            if let isRead { item.isRead = isRead }
            if let isStarred { item.isStarred = isStarred }
            list[index] = item
        }

        updateList(&self.entryListItems)
        updateList(&self.todayEntryListItems)
        updateList(&self.unreadEntryListItems)
        updateList(&self.starredEntryListItems)

        // 仅重新统计 Sidebar Counts（纯 SQL 聚合，极快）
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date()).timeIntervalSince1970
        self.sidebarCounts = (try? localProvider.timelineQueryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)) ?? self.sidebarCounts

        // 更新 Entry 单篇缓存（若存在）
        if var cached = cachedEntryLookup[entryID] {
            if let isRead { cached.isRead = isRead }
            if let isStarred { cached.isStarred = isStarred }
            cachedEntryLookup[entryID] = cached
        }

        objectWillChange.send()
    }

    public func markRead(_ entry: Entry, read: Bool = true) {
        markRead(entryID: entry.id, read: read)
    }

    public func markRead(entryID: String, read: Bool = true) {
        try? localProvider.markRead(entryID: entryID, read: read)
        updateLocalEntryState(entryID: entryID, isRead: read)
        Task { [weak self] in
            await self?.syncCoordinator.pushAllPendingArticleStates()
        }
    }

    public func markRead(entryIDs: [String], read: Bool = true) {
        guard !entryIDs.isEmpty else { return }
        try? localProvider.markRead(entryIDs: entryIDs, read: read)
        reloadState()
        Task { [weak self] in
            await self?.syncCoordinator.pushAllPendingArticleStates()
        }
    }

    public func markStarred(_ entry: Entry, starred: Bool = true) {
        markStarred(entryID: entry.id, starred: starred)
    }

    public func markStarred(entryID: String, starred: Bool = true) {
        try? localProvider.markStarred(entryID: entryID, starred: starred)
        updateLocalEntryState(entryID: entryID, isStarred: starred)
        Task { [weak self] in
            await self?.syncCoordinator.pushAllPendingArticleStates()
        }
    }

    public func toggleStar(_ entry: Entry) {
        markStarred(entry, starred: !entry.isStarred)
    }

    public func toggleStar(entryID: String) {
        if let item = entryListItems.first(where: { $0.id == entryID }) {
            markStarred(entryID: entryID, starred: !item.isStarred)
        } else if let entry = entry(id: entryID) {
            markStarred(entryID: entryID, starred: !entry.isStarred)
        } else {
            markStarred(entryID: entryID, starred: true)
        }
    }

    public func markAllRead(
        accountID: String? = nil,
        feedID: UUID? = nil,
        feedIDs: Set<UUID>? = nil,
        folder: String? = nil,
        scope: TimelineScope? = nil
    ) {
        do {
            let actualStartOfDay: Double? = {
                if case .today(let ts) = scope { return ts }
                return nil
            }()
            let targetAccountID: String? = {
                if let accountID { return accountID }
                if case .folder(let acc, _) = scope { return acc }
                return nil
            }()
            let targetFolder: String? = {
                if let folder { return folder }
                if case .folder(_, let fName) = scope { return fName }
                return nil
            }()

            try libraryDatabase.write { db in
                try self.localProvider.stateRepository.markAllRead(
                    accountID: targetAccountID,
                    feedID: feedID?.uuidString,
                    feedIDs: feedIDs.map { Set($0.map(\.uuidString)) },
                    folderName: targetFolder,
                    startOfDayTimestamp: actualStartOfDay,
                    in: db
                )
            }
            reloadState()
            Task { [weak self] in
                await self?.syncCoordinator.pushAllPendingArticleStates()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - FreshRSS Account Management

    @discardableResult
    public func addFreshRSSAccount(
        endpointURLText: String,
        username: String,
        password: String,
        displayName: String? = nil,
        customSession: URLSession = .shared
    ) async throws -> AccountRecord {
        guard let rawURL = URL(string: endpointURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = rawURL.host, !host.isEmpty else {
            throw ReaderAPIError.invalidEndpointURL(endpointURLText)
        }

        let canonicalURL = ReaderAPIClient.canonicalBaseURL(for: rawURL)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw ReaderAPIError.invalidCredentials
        }
        guard !password.isEmpty else {
            throw ReaderAPIError.invalidCredentials
        }

        // 1. 原子检查是否存在相同 endpoint + username 的启用账号
        let isDuplicate = try libraryDatabase.read { db in
            let accounts = try AccountRecord
                .filter(Column("type") == AccountType.freshRSS.rawValue && Column("is_enabled") == true)
                .fetchAll(db)
            return accounts.contains { acc in
                guard let ep = acc.endpointURL, let un = acc.username else { return false }
                let canonicalExisting = (URL(string: ep).map { ReaderAPIClient.canonicalBaseURL(for: $0).absoluteString }) ?? ep
                return canonicalExisting == canonicalURL.absoluteString && un == trimmedUsername
            }
        }
        if isDuplicate {
            throw ReaderAPIError.accountAlreadyExists("\(trimmedUsername) @ \(canonicalURL.host ?? "")")
        }

        let tempAccountID = "freshRSS-\(UUID().uuidString)"
        let tempCredentialStore = InMemoryCredentialStore(initialCredentials: [tempAccountID: password])
        let validatorClient = ReaderAPIClient(
            endpointURL: canonicalURL,
            username: trimmedUsername,
            accountID: tempAccountID,
            credentialStore: tempCredentialStore,
            session: customSession
        )

        // 2. 验证登录凭据
        try await validatorClient.validateCredentials()

        // 3. 插入数据库
        let accountID = "freshRSS-\(UUID().uuidString)"
        let now = Date().timeIntervalSince1970
        let accountTitle: String
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accountTitle = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            accountTitle = rawURL.host ?? "FreshRSS"
        }

        let accountRecord = AccountRecord(
            id: accountID,
            type: AccountType.freshRSS.rawValue,
            displayName: accountTitle,
            endpointURL: canonicalURL.absoluteString,
            username: trimmedUsername,
            isEnabled: true,
            createdAt: now,
            updatedAt: now
        )

        try await accountRepository.saveAccountAtomicWithDuplicateCheck(accountRecord)

        // 4. 将密码写入真实 Keychain
        do {
            try credentialStore.saveFreshRSSPassword(password, accountID: accountID)
        } catch {
            // 如果 Keychain 写入失败，清理数据库账号记录
            try? await accountRepository.deleteAccount(id: accountID)
            throw error
        }

        // 5. 注册 Provider 到 SyncCoordinator
        let provider = FreshRSSAccountProvider(
            accountID: accountID,
            endpointURL: canonicalURL,
            username: trimmedUsername,
            database: libraryDatabase,
            credentialStore: credentialStore,
            session: customSession
        )
        await syncCoordinator.registerProvider(provider)

        // 6. 执行初始同步（明确暴露同步结果，禁止静默吞错）
        var initialSyncError: (any Error)? = nil
        do {
            _ = try await provider.refresh(reason: .manual)
        } catch {
            initialSyncError = error
        }

        reloadState()

        if let initialSyncError {
            throw initialSyncError
        }

        return accountRecord
    }

    public func removeAccount(accountID: String) async throws {
        guard accountID != "local-default" else {
            throw LocalAccountError.feedNotFound
        }

        await syncCoordinator.unregisterProvider(accountID: accountID)
        try? credentialStore.deleteFreshRSSCredentials(accountID: accountID)
        try await accountRepository.deleteAccount(id: accountID)
        reloadState()
    }

    public func syncAccount(accountID: String) async {
        do {
            _ = try await syncCoordinator.refreshAccount(accountID: accountID, reason: .manual)
            reloadState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func syncAllAccounts() async {
        _ = await syncCoordinator.refreshAll(reason: .manual)
        reloadState()
    }

    // MARK: - Article Preparation & Caches

    /// 统一正文准备入口：每个 entry 返回同源绑定的 PreparedArticle，并在内容更新时写入本地缓存。
    /// 内存 LRU 命中时零 IO、零解析直接返回，使顺序阅读切换即时完成。
    public func prepareArticle(for entry: Entry) async -> PreparedArticle {
        let fingerprint = PreparedArticleMemoryCache.contentFingerprint(for: entry)
        if let memoized = preparedArticleMemoryCache.article(for: entry.id, contentFingerprint: fingerprint) {
            return memoized
        }
        // 注：预取与阅读加载可能对同一 entry 并发准备（罕见且良性，内容一致，
        // 后写者胜出）。刻意不做共享去重任务：非结构化 Task 会切断视图
        // .task(id:) 的取消传播，导致快速切换无法中止在途网络请求。
        let generationAtStart = preparedArticleMemoryCache.generation
        let cached = try? localProvider.fetchCache(entryID: entry.id)
        let feed = self.feed(for: entry)
        let (prepared, updatedCache) = await preparationEngine.prepare(entry: entry, cached: cached, feed: feed)
        if let updatedCache, !Task.isCancelled {
            try? localProvider.saveCache(updatedCache)
        }
        // 取消的任务可能产出兜底结果，不污染内存缓存；
        // .fallback 表示本次未能产出真实正文（如网络瞬时失败），
        // 不缓存以便下次访问重新尝试；
        // 准备期间若发生失效（如重抓写入更好缓存），代数不匹配则放弃存储。
        if !Task.isCancelled,
           prepared.source != .fallback,
           generationAtStart == preparedArticleMemoryCache.generation {
            preparedArticleMemoryCache.store(prepared, entryID: entry.id, contentFingerprint: fingerprint)
        }
        return prepared
    }

    /// 内存中是否已有该条目可立即展示的准备结果（仅查进程内缓存，不触发任何 IO）。
    public func memoizedPreparedArticle(for entry: Entry) -> PreparedArticle? {
        preparedArticleMemoryCache.article(
            for: entry.id,
            contentFingerprint: PreparedArticleMemoryCache.contentFingerprint(for: entry)
        )
    }

    /// 阅读稳定后预取相邻文章，使顺序阅读的 Space/nn/bb 始终命中内存缓存。
    /// 单飞任务：新的选择会取消上一次未开始的预取；已缓存的邻居零开销跳过；
    /// 预取内部尊重取消标记，不会在用户快速连续切换时堆积网络请求。
    public func scheduleNeighborPrefetch(
        scope: TimelineScope,
        currentItemID: String,
        retainingIDs: Set<String>
    ) {
        neighborPrefetchTask?.cancel()
        neighborPrefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let directions: [AdjacentTimelineDirection] = [.next, .previous]
            for direction in directions {
                guard !Task.isCancelled else { return }
                let adjacent = self.fetchAdjacentItem(
                    scope: scope,
                    currentItemID: currentItemID,
                    direction: direction,
                    retainingIDs: retainingIDs
                )
                guard let neighborID = adjacent?.id,
                      !self.preparedArticleMemoryCache.contains(neighborID),
                      let neighbor = self.entry(id: neighborID) else { continue }
                _ = await self.prepareArticle(for: neighbor)
            }
        }
    }

    /// 单篇重新拉取正文：忽略旧缓存重新评估，仅在新内容可用时覆盖。
    /// - 成功（`.feed`/`.web` 来源且产出非空缓存）→ 写库并发布 `articleRefreshSignal`，返回 `true`。
    /// - 失败（回退兜底、无新内容）→ 保留旧缓存，返回 `false`。
    public func refetchArticle(for entry: Entry) async -> Bool {
        guard !activeRefetchEntryIDs.contains(entry.id) else { return false }
        activeRefetchEntryIDs.insert(entry.id)
        defer { activeRefetchEntryIDs.remove(entry.id) }

        let feed = self.feed(for: entry)
        let (prepared, updatedCache) = await preparationEngine.prepare(entry: entry, cached: nil, feed: feed)

        let usable = !prepared.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && prepared.source != .fallback
            && updatedCache != nil
        guard usable, let updatedCache else { return false }

        try? localProvider.saveCache(updatedCache)
        // 重抓写入了更好的正文缓存行，内存 LRU 中的旧结果必须立即失效。
        preparedArticleMemoryCache.invalidate(entryID: entry.id)
        articleRefreshSignal = ArticleRefreshSignal(entryID: entry.id, token: UUID())
        return true
    }

    /// 全量清除网页正文缓存并回收磁盘空间。返回删除的缓存行数。
    /// VACUUM 可能耗时数秒，故在后台线程执行以免阻塞主线程 UI。
    public func clearArticleCaches() async throws -> Int {
        let provider = localProvider
        preparedArticleMemoryCache.removeAll()
        return try await Task.detached(priority: .userInitiated) {
            try provider.clearAllCaches()
        }.value
    }

    /// 当前网页正文缓存文章数与占用大小（供设置页「缓存数据」展示）。
    public func articleCacheStats() throws -> ArticleCacheStats {
        try localProvider.cacheStats()
    }

    /// 按条目 ID 重新拉取正文；条目不存在时返回 `false`。
    public func refetchArticle(entryID: String) async -> Bool {
        guard let entry = self.entry(id: entryID) else { return false }
        return await refetchArticle(for: entry)
    }

    public func cachedText(for entry: Entry) -> String? {
        (try? localProvider.fetchCache(entryID: entry.id))?.text
    }

    public func articleText(for entry: Entry) async throws -> String {
        let prepared = await prepareArticle(for: entry)
        return prepared.text.isEmpty ? entry.sourceText : prepared.text
    }

    public func articleHTML(for entry: Entry) -> String? {
        let feed = self.feed(for: entry)
        if preparationEngine.isTwitterOrSelfContainedFeed(entry: entry, feed: feed) {
            if let rawHTML = entry.contentHTML, !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ArticleExtractor.content(from: rawHTML, baseURL: entry.url).html
            }
        }

        if let cache = try? localProvider.fetchCache(entryID: entry.id), let html = cache.html, !html.isEmpty {
            let sourceURL = cache.sourceURL ?? entry.url
            var repairedHTML = ArticleExtractor.sanitizedHTML(html, baseURL: sourceURL)
            if let sourceHTML = entry.contentHTML {
                repairedHTML = ArticleExtractor.repairingCollapsedWhitespaceImageURLs(
                    in: repairedHTML,
                    sourceHTML: sourceHTML,
                    baseURL: sourceURL
                )
            }
            if repairedHTML != html && cache.isSanitized {
                var repaired = cache
                repaired.html = repairedHTML
                repaired.imageURLs = ArticleExtractor.imageURLs(from: repairedHTML, baseURL: sourceURL)
                repaired.sourceURL = sourceURL
                try? localProvider.saveCache(repaired)
                // 修复写回改变了缓存行内容，内存 LRU 中的旧结果同步失效
                preparedArticleMemoryCache.invalidate(entryID: entry.id)
            }
            return repairedHTML
        }
        return entry.contentHTML.map { ArticleExtractor.sanitizedHTML($0, baseURL: entry.url) }
    }

    public func articleSourceURL(for entry: Entry) -> URL? {
        (try? localProvider.fetchCache(entryID: entry.id))?.sourceURL ?? entry.url
    }

    public func articleImageURLs(for entry: Entry) -> [URL] {
        let sourceURL = articleSourceURL(for: entry)
        if let html = articleHTML(for: entry) {
            return ArticleExtractor.imageURLs(from: html, baseURL: sourceURL)
        }
        return []
    }

    public func fetchFullArticle(for entry: Entry) async throws -> String {
        let prepared = await prepareArticle(for: entry)
        return prepared.text.isEmpty ? entry.sourceText : prepared.text
    }

    // MARK: - AI Artifacts

    public func artifact(for entry: Entry, kind: AIArtifactKind) -> AIArtifact? {
        try? localProvider.fetchArtifact(entryID: entry.id, kind: kind, isCompleteOnly: true)
    }

    public func summaryArtifact(for entry: Entry) -> AIArtifact? {
        try? localProvider.fetchArtifact(entryID: entry.id, kind: .summary, isCompleteOnly: false)
    }

    public func bilingualArtifact(for entry: Entry, text: String) -> AIArtifact? {
        let hash = text.stableDigest
        return try? localProvider.fetchBilingualArtifact(entryID: entry.id, contentHash: hash, model: llmConfiguration.model)
    }

    public func selectionArtifacts(for entry: Entry, articleHash: String) -> [AIArtifact] {
        (try? localProvider.fetchSelectionArtifacts(entryID: entry.id, articleHash: articleHash)) ?? []
    }

    public func isGeneratingAI(for entry: Entry, kind: AIArtifactKind) -> Bool {
        guard let status = activeAIStatus(for: kind) else { return false }
        return status.entryID == entry.id && status.kind == kind
    }

    public func generateSummary(
        entry: Entry,
        text: String,
        force: Bool = false,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async {
        let configuration = llmConfiguration
        let hash = text.stableDigest
        if !force, let existing = summaryArtifact(for: entry), existing.isComplete && existing.contentHash == hash && existing.model == configuration.model {
            return
        }
        guard activeSummaryRequest == nil else { return }

        lastError = nil
        activeSummaryRequest = AIRequestStatus(entryID: entry.id, kind: .summary, phase: .loadingLocalConfiguration)
        let apiKey = loadAPIKey()
        guard !apiKey.isEmpty else {
            activeSummaryRequest = nil
            lastError = LLMServiceError.missingAPIKey.localizedDescription
            return
        }

        activeSummaryRequest = AIRequestStatus(entryID: entry.id, kind: .summary, phase: .generating)

        let targetArtifactID = UUID()
        let tracker = SummaryStreamTracker(
            targetArtifact: AIArtifact(
                id: targetArtifactID,
                entryID: entry.id,
                kind: .summary,
                contentHash: hash,
                model: configuration.model,
                targetLanguage: configuration.targetLanguage,
                promptVersion: 1,
                content: "",
                isComplete: false
            )
        )
        try? localProvider.saveArtifact(tracker.currentArtifact)

        do {
            let result = try await llm.summary(text: text, configuration: configuration, apiKey: apiKey) { [weak self] delta in
                guard let self, !Task.isCancelled else { return }
                let (currentBuffer, shouldCheckpoint, artifactToCheckpoint) = tracker.append(delta)

                // 1. 局部 UI 实时流式通知（不发全局 objectWillChange）
                //    delta 必须被同步 await：迟到的非结构化 Task 会在
                //    generateSummary 返回、视图清理 streamingSummary 之后
                //    重新赋值，把已完成的摘要误标为未完成。
                if let onDelta {
                    await onDelta(currentBuffer)
                }

                // 2. 节流持久化 Checkpoint（支持崩溃/取消恢复）
                if shouldCheckpoint {
                    try? self.localProvider.saveArtifact(artifactToCheckpoint)
                }
            }

            var finalArtifact = tracker.currentArtifact
            finalArtifact.content = result
            finalArtifact.isComplete = true
            finalArtifact.updatedAt = .now
            try? localProvider.saveArtifact(finalArtifact)
            activeSummaryRequest = nil
        } catch {
            activeSummaryRequest = nil
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
        }
    }

    public func generateBilingualTranslation(entry: Entry, text: String, targetLanguage: String = "zh-Hans") async {
        let paragraphs = ArticleExtractor.readerParagraphs(in: text, title: entry.title)
        guard !paragraphs.isEmpty else { return }
        await translateBilingualParagraphs(
            entry: entry,
            text: text,
            paragraphs: paragraphs,
            paragraphIDs: paragraphs.map(\.id)
        )
    }

    public func dismissError() {
        lastError = nil
    }

    @discardableResult
    public func explainSelection(
        entry: Entry,
        selection: String,
        localContext: String = "",
        articleText: String = "",
        selectionAnchor: AISelectionAnchor? = nil,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let opResult = await executeSelectionAI(
            entry: entry,
            kind: .selectionExplanation,
            selectionText: selection,
            selectionAnchor: selectionAnchor,
            operation: { [weak self] apiKey, config in
                guard let self else { return nil }
                return try await self.llm.explainSelection(
                    selection: selection,
                    localContext: localContext,
                    articleContext: articleText.isEmpty ? entry.sourceText : articleText,
                    configuration: config,
                    apiKey: apiKey,
                    onDelta: onDelta
                )
            }
        )
        guard let result = opResult else {
            throw LLMServiceError.emptyResponse
        }
        return result
    }

    @discardableResult
    public func translateSelection(
        entry: Entry,
        selection: String,
        targetLanguage: String = "zh-Hans",
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let opResult = await executeSelectionAI(
            entry: entry,
            kind: .translation,
            selectionText: selection,
            operation: { [weak self] apiKey, config in
                guard let self else { return nil }
                var updatedConfig = config
                updatedConfig.targetLanguage = targetLanguage
                return try await self.llm.translate(
                    paragraph: selection,
                    configuration: updatedConfig,
                    apiKey: apiKey,
                    onDelta: onDelta
                )
            }
        )
        guard let result = opResult else {
            throw LLMServiceError.emptyResponse
        }
        return result
    }

    @discardableResult
    public func askSelection(
        entry: Entry,
        selection: String,
        question: String,
        localContext: String = "",
        articleText: String = "",
        selectionAnchor: AISelectionAnchor? = nil,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let opResult = await executeSelectionAI(
            entry: entry,
            kind: .interpretation,
            selectionText: selection,
            selectionAnchor: selectionAnchor,
            operation: { [weak self] apiKey, config in
                guard let self else { return nil }
                return try await self.llm.askSelection(
                    selection: selection,
                    question: question,
                    localContext: localContext,
                    articleContext: articleText.isEmpty ? entry.sourceText : articleText,
                    configuration: config,
                    apiKey: apiKey,
                    onDelta: onDelta
                )
            }
        )
        guard let result = opResult else {
            throw LLMServiceError.emptyResponse
        }
        return result
    }

    public func translateBilingualParagraphs(
        entry: Entry,
        text: String,
        paragraphs: [ReaderParagraph],
        paragraphIDs: [String],
        onDelta: (@Sendable (String, String) async -> Void)? = nil
    ) async {
        guard !paragraphs.isEmpty, !paragraphIDs.isEmpty else { return }

        let configuration = llmConfiguration
        let hash = text.stableDigest
        let requestedIDsSet = Set(paragraphIDs)
        let targetParagraphs = paragraphs.filter { requestedIDsSet.contains($0.id) }
        guard !targetParagraphs.isEmpty else { return }

        let paragraphOrder: [String: Int] = Dictionary(uniqueKeysWithValues: paragraphs.enumerated().map { ($1.id, $0) })

        // 1. 获取或创建 Artifact（根据 entryID + contentHash + model）
        var artifact = (try? localProvider.fetchArtifact(entryID: entry.id, kind: .bilingual, isCompleteOnly: false))
            ?? AIArtifact(
                id: UUID(),
                entryID: entry.id,
                kind: .bilingual,
                contentHash: hash,
                model: configuration.model,
                targetLanguage: configuration.targetLanguage,
                promptVersion: Self.translationPromptVersion,
                content: "",
                segments: [],
                isComplete: false
            )

        // 保证模型和 targetLanguage 同步
        if artifact.contentHash != hash || artifact.model != configuration.model {
            artifact.contentHash = hash
            artifact.model = configuration.model
            artifact.targetLanguage = configuration.targetLanguage
        }

        let existingSegmentMap: [String: BilingualSegment] = Dictionary(
            uniqueKeysWithValues: artifact.segments.map { ($0.id, $0) }
        )

        // 2. 区分已翻译、TM (翻译内存) 命中与未翻译段落
        var uncachedParagraphs: [ReaderParagraph] = []
        var newResolvedSegments: [BilingualSegment] = []

        for paragraph in targetParagraphs {
            if let existing = existingSegmentMap[paragraph.id] {
                // 已有该段落翻译，通知 onDelta
                if let onDelta {
                    Task { await onDelta(paragraph.id, existing.translation) }
                }
                continue
            }
            if let tmTranslation = cachedTranslation(for: paragraph.original, configuration: configuration) {
                let seg = BilingualSegment(id: paragraph.id, original: paragraph.original, translation: tmTranslation)
                newResolvedSegments.append(seg)
                if let onDelta {
                    Task { await onDelta(paragraph.id, tmTranslation) }
                }
            } else {
                uncachedParagraphs.append(paragraph)
            }
        }

        // 如果有 TM 命中的段落，先合并
        if !newResolvedSegments.isEmpty {
            for seg in newResolvedSegments {
                if let idx = artifact.segments.firstIndex(where: { $0.id == seg.id }) {
                    artifact.segments[idx] = seg
                } else {
                    artifact.segments.append(seg)
                }
            }
            artifact.segments.sort { paragraphOrder[$0.id, default: .max] < paragraphOrder[$1.id, default: .max] }
            artifact.content = artifact.segments.map(\.translation).joined(separator: "\n\n")
            artifact.updatedAt = .now
            let allExpectedIDs = Set(paragraphs.map(\.id))
            artifact.isComplete = Set(artifact.segments.map(\.id)).isSuperset(of: allExpectedIDs)
            try? localProvider.saveArtifact(artifact)
        }

        // 3. 如果所有请求段落都已解决，直接返回
        guard !uncachedParagraphs.isEmpty else {
            return
        }

        // 4. 检查 API Key
        let apiKey = loadAPIKey()
        guard !apiKey.isEmpty else {
            lastError = LLMServiceError.missingAPIKey.localizedDescription
            return
        }

        activeBilingualRequest = AIRequestStatus(entryID: entry.id, kind: .bilingual, phase: .generating)
        defer {
            activeBilingualRequest = nil
        }

        // 5. 按批次执行模型翻译并直接 await
        let batches = translationBatches(from: uncachedParagraphs)
        do {
            for batch in batches {
                guard !Task.isCancelled else { break }
                let translatedTexts = try await llm.translateBatch(
                    paragraphs: batch.map(\.original),
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { break }

                let batchSegments = zip(batch, translatedTexts).map {
                    BilingualSegment(id: $0.id, original: $0.original, translation: $1)
                }
                cacheTranslations(batchSegments, configuration: configuration)

                // 触发 onDelta
                if let onDelta {
                    for seg in batchSegments {
                        await onDelta(seg.id, seg.translation)
                    }
                }

                // 合并入当前 artifact
                var current = (try? localProvider.fetchArtifact(entryID: entry.id, kind: .bilingual, isCompleteOnly: false)) ?? artifact
                for seg in batchSegments {
                    if let idx = current.segments.firstIndex(where: { $0.id == seg.id }) {
                        current.segments[idx] = seg
                    } else {
                        current.segments.append(seg)
                    }
                }
                current.segments.sort { paragraphOrder[$0.id, default: .max] < paragraphOrder[$1.id, default: .max] }
                current.content = current.segments.map(\.translation).joined(separator: "\n\n")
                current.updatedAt = .now
                let allExpectedIDs = Set(paragraphs.map(\.id))
                current.isComplete = Set(current.segments.map(\.id)).isSuperset(of: allExpectedIDs)
                try? localProvider.saveArtifact(current)
                artifact = current
            }
        } catch {
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
        }
    }

    private func executeSelectionAI(
        entry: Entry,
        kind: AIArtifactKind,
        selectionText: String? = nil,
        selectionAnchor: AISelectionAnchor? = nil,
        operation: @Sendable @escaping (String, LLMConfiguration) async throws -> String?
    ) async -> String? {
        let configuration = llmConfiguration
        guard activeSelectionRequest == nil else { return nil }
        lastError = nil
        activeSelectionRequest = AIRequestStatus(entryID: entry.id, kind: kind, phase: .loadingLocalConfiguration)
        let apiKey = loadAPIKey()
        guard !apiKey.isEmpty else {
            activeSelectionRequest = nil
            lastError = LLMServiceError.missingAPIKey.localizedDescription
            return nil
        }
        activeSelectionRequest = AIRequestStatus(entryID: entry.id, kind: kind, phase: .generating)
        do {
            let result = try await operation(apiKey, configuration)
            if let result {
                let artifact = AIArtifact(
                    entryID: entry.id,
                    kind: kind,
                    contentHash: result.stableDigest,
                    model: configuration.model,
                    targetLanguage: configuration.targetLanguage,
                    promptVersion: 1,
                    content: result,
                    selectionText: selectionText,
                    selectionAnchor: selectionAnchor,
                    isComplete: true
                )
                try? localProvider.saveArtifact(artifact)
            }
            activeSelectionRequest = nil
            return result
        } catch {
            activeSelectionRequest = nil
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
            return nil
        }
    }

    // MARK: - Translation Memory Helpers

    private func cachedTranslation(for source: String, configuration: LLMConfiguration) -> String? {
        let key = translationMemoryKey(for: source, configuration: configuration)
        let entryID = translationMemoryEntryID(for: key)
        return (try? localProvider.fetchGlobalTranslationMemory(key: entryID))?.content
    }

    func cacheTranslations(_ segments: [BilingualSegment], configuration: LLMConfiguration) {
        for segment in segments {
            let key = translationMemoryKey(for: segment.original, configuration: configuration)
            let entryID = translationMemoryEntryID(for: key)
            let artifact = AIArtifact(
                entryID: entryID,
                kind: .translation,
                contentHash: key,
                model: configuration.model,
                targetLanguage: configuration.targetLanguage,
                promptVersion: Self.translationPromptVersion,
                content: segment.translation,
                isComplete: true
            )
            try? localProvider.saveArtifact(artifact)
        }
    }

    private func translationBatches(from paragraphs: [ReaderParagraph]) -> [[ReaderParagraph]] {
        var batches: [[ReaderParagraph]] = []
        var current: [ReaderParagraph] = []
        var characterCount = 0
        for paragraph in paragraphs {
            let wouldExceedLimit = !current.isEmpty && (
                current.count >= Self.maximumParagraphsPerTranslationBatch
                    || characterCount + paragraph.original.count > Self.maximumCharactersPerTranslationBatch
            )
            if wouldExceedLimit {
                batches.append(current)
                current = []
                characterCount = 0
            }
            current.append(paragraph)
            characterCount += paragraph.original.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func translationMemoryKey(for source: String, configuration: LLMConfiguration) -> String {
        [
            Self.translationMemoryEntryPrefix,
            source.paperRssNormalizedWhitespace,
            configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            configuration.model,
            configuration.targetLanguage,
            String(Self.translationPromptVersion)
        ].joined(separator: "|").stableDigest
    }

    private func translationMemoryEntryID(for key: String) -> String {
        "\(Self.translationMemoryEntryPrefix)\(key)"
    }

    private static let translationPromptVersion = 2
    private static let translationMemoryEntryPrefix = "translation-memory-v2:"
    private static let maximumParagraphsPerTranslationBatch = 4
    private static let maximumCharactersPerTranslationBatch = 1_200

    private final class SummaryStreamTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var lastCheckpoint = CFAbsoluteTimeGetCurrent()
        private let checkpointInterval: Double = 0.5
        private var targetArtifact: AIArtifact

        init(targetArtifact: AIArtifact) {
            self.targetArtifact = targetArtifact
        }

        func append(_ delta: String) -> (current: String, shouldCheckpoint: Bool, artifact: AIArtifact) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(delta)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastCheckpoint >= checkpointInterval {
                lastCheckpoint = now
                targetArtifact.content = buffer
                targetArtifact.updatedAt = .now
                return (buffer, true, targetArtifact)
            }
            return (buffer, false, targetArtifact)
        }

        var currentArtifact: AIArtifact {
            lock.lock()
            defer { lock.unlock() }
            var art = targetArtifact
            art.content = buffer
            art.updatedAt = .now
            return art
        }
    }

    // MARK: - Preferences & Configuration

    @discardableResult
    public func saveLLMConfiguration(_ configuration: LLMConfiguration, apiKey: String) -> LocalAPIKeyStore.Storage {
        let storage = LocalAPIKeyStore.saveAPIKey(apiKey)
        self.llmConfiguration = configuration
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.llmConfiguration)
        }
        return storage
    }

    public func updateLLMConfiguration(_ configuration: LLMConfiguration) {
        self.llmConfiguration = configuration
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.llmConfiguration)
        }
    }

    public func resetLLMConfiguration() {
        let defaultConfig = LLMConfiguration.default
        updateLLMConfiguration(defaultConfig)
    }

    public func loadAPIKey() -> String { LocalAPIKeyStore.loadAPIKey() }

    public func testLLM(configuration: LLMConfiguration, apiKey: String) async throws {
        try await llm.test(configuration: configuration, apiKey: apiKey)
    }

    public func setRefreshInterval(_ interval: FeedRefreshInterval) {
        guard refreshInterval != interval else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: PreferenceKey.refreshInterval)
        restartAutomaticRefreshIfNeeded()
    }

    public func setRefreshOnLaunch(_ enabled: Bool) {
        guard refreshOnLaunch != enabled else { return }
        refreshOnLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: PreferenceKey.refreshOnLaunch)
    }

    public func setAppTheme(_ theme: AppTheme) {
        guard appTheme != theme else { return }
        appTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: PreferenceKey.appTheme)
    }

    public func setArticleFontSize(_ size: Int) {
        let clamped = max(13, min(25, size))
        guard articleFontSize != clamped else { return }
        articleFontSize = clamped
        UserDefaults.standard.set(clamped, forKey: PreferenceKey.articleFontSize)
    }

    public func increaseArticleFontSize() { setArticleFontSize(articleFontSize + 1) }
    public func decreaseArticleFontSize() { setArticleFontSize(articleFontSize - 1) }
    public func resetArticleFontSize() { setArticleFontSize(17) }

    public func ignoreVersion(_ version: String) {
        let clean = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard ignoredVersion != clean else { return }
        ignoredVersion = clean
        UserDefaults.standard.set(clean, forKey: PreferenceKey.ignoredVersion)
    }

    public func clearIgnoredVersion() {
        guard ignoredVersion != nil else { return }
        ignoredVersion = nil
        UserDefaults.standard.removeObject(forKey: PreferenceKey.ignoredVersion)
    }

    public func startAutomaticRefresh() {
        guard automaticRefreshTask == nil else { return }
        automaticRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.refreshOnLaunch {
                await self.refresh(reportErrors: false, origin: .launch)
            }

            while !Task.isCancelled {
                guard let seconds = self.refreshInterval.seconds else {
                    do {
                        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    } catch {
                        return
                    }
                    continue
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refresh(reportErrors: false, origin: .scheduled)
            }
        }
    }

    public func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    private func restartAutomaticRefreshIfNeeded() {
        guard automaticRefreshTask != nil else { return }
        stopAutomaticRefresh()
        startAutomaticRefresh()
    }

    public func checkForUpdates(isUserInitiated: Bool) async {
        updateStatus = .checking
        do {
            let result = try await UpdateCheckService.checkForUpdates()
            if result.hasUpdate, let release = result.release, release.version != ignoredVersion {
                updateStatus = .hasUpdate(release: release, checkedAt: .now)
            } else {
                updateStatus = .upToDate(checkedAt: .now)
            }
        } catch {
            updateStatus = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Compatibility Property for Tests

    @available(*, deprecated, message: "Use Repository / LocalAccountProvider APIs instead of AppDatabase")
    public var database: AppDatabase {
        AppDatabase(
            feeds: feeds,
            entries: entries,
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: llmConfiguration,
            customFolders: customFolders
        )
    }

    // MARK: - Helpers

    private func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), direct.scheme != nil { return direct }
        return URL(string: "https://\(trimmed)")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var paperRssNormalizedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ delta: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(delta)
        return buffer
    }

    var content: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

extension JSONEncoder {
    public static let paperRss: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    public static let paperRss: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

