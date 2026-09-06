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
    public let requestID: UUID
    public let entryID: String
    public let kind: AIArtifactKind
    public let phase: AIRequestPhase

    public init(requestID: UUID = UUID(), entryID: String, kind: AIArtifactKind, phase: AIRequestPhase) {
        self.requestID = requestID
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
    @Published public private(set) var readerAppearance: ReaderAppearance = .default
    public var articleFontSize: Int { readerAppearance.fontSize }

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
    /// Persisted provider profiles plus reader-facing AI preferences. The
    /// legacy `llmConfiguration` property remains as the active runtime
    /// projection for existing callers.
    @Published public private(set) var aiSettings: AISettings = .default
    public let aiWorkspace = ArticleAIWorkspace(maximumBackgroundConcurrency: 6)

    /// 进程内已准备正文 LRU 缓存：命中时 Reader 可跳过 prepare 管线即时换页。
    public private(set) var preparedArticleMemoryCache = PreparedArticleMemoryCache()
    private var neighborPrefetchTask: Task<Void, Never>?

    /// 兼容旧调用方的进度值，但不再作为 AppStore 的发布属性。
    /// 刷新进度属于刷新状态模块，不能让每个 feed 完成都使三栏失效。
    public private(set) var refreshProgress: (current: Int, total: Int)? = nil
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var refreshStatus: FeedRefreshStatus = .idle
    @Published public private(set) var latestRefreshOutcome: FeedRefreshOutcome?
    @Published public private(set) var refreshInterval: FeedRefreshInterval = .twoHours
    @Published public private(set) var refreshOnLaunch: Bool = true
    @Published public private(set) var lastError: String?
    /// 非阻断式瞬时提示（toast）。批量后台操作（如双语文逐段翻译）失败时的
    /// 轻量通知通道，与阻断式 lastError alert 分离；id 用于驱动 SwiftUI
    /// onChange，即使消息相同也能再次触发。
    public struct TransientNotice: Equatable {
        public let id = UUID()
        public let message: String
        public init(message: String) { self.message = message }
    }
    @Published public private(set) var transientNotice: TransientNotice?
    private var transientNoticeSignature: String?
    private var transientNoticeAt: Date = .distantPast
    /// 仅保存在当前进程内的反馈上下文；不写入数据库，也不包含原始错误文本。
    @Published public private(set) var latestFeedbackError: FeedbackErrorSnapshot?
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

    public func cancelBilingualTranslation() {
        activeBilingualRequest = nil
    }

    @Published public private(set) var activeBilingualEntryIDs: Set<String> = []

    public func isBilingualActive(for entryID: String) -> Bool {
        activeBilingualEntryIDs.contains(entryID)
    }

    public func toggleBilingualMode(for entryID: String) {
        if activeBilingualEntryIDs.contains(entryID) {
            activeBilingualEntryIDs.remove(entryID)
            cancelBilingualTranslation()
            aiWorkspace.cancel(.background(entryID: entryID, kind: .bilingual))
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
    private let shouldPersistAISettings: Bool
    private let feedFetcher: @Sendable (Feed) async throws -> FeedFetchResult
    private let llm: LLMService
    private let preparationEngine: ArticlePreparationEngine
    private var automaticRefreshTask: Task<Void, Never>?
    /// 当前刷新轮次中已经启动的本地 Feed 抓取任务。删除 Feed 时主动取消对应任务，
    /// 避免用户已经丢弃订阅后仍被旧网络请求拖住 Loading。
    private var activeRefreshFeedTasks: [UUID: Task<LocalAccountProvider.SingleFeedRefreshResult, Never>] = [:]
    /// 本轮刷新中被删除的 Feed。即使迟到结果已经离开网络层，也不得再进入 merge。
    private var invalidatedRefreshFeedIDs = Set<UUID>()
    /// 刷新进行中发生删除时，延后完整快照重建，避免与 Loading 收尾争抢 MainActor。
    private var stateReloadPendingAfterRefresh = false

    private enum PreferenceKey {
        static let refreshInterval = "PaperRss.refreshInterval"
        static let refreshOnLaunch = "PaperRss.refreshOnLaunch"
        static let appTheme = "PaperRss.appTheme"
        static let articleFontSize = "PaperRss.articleFontSize"
        static let readerAppearance = "PaperRss.readerAppearance"
        static let llmConfiguration = "PaperRss.llmConfiguration"
        static let aiSettings = "PaperRss.aiSettings.v5"
        static let legacyAISettingsV4 = "PaperRss.aiSettings.v4"
        static let legacyAISettings = "PaperRss.aiSettings.v2"
    }

    private static func loadReaderAppearance(from preferences: UserDefaults) -> ReaderAppearance {
        if let data = preferences.data(forKey: PreferenceKey.readerAppearance),
           let stored = try? JSONDecoder().decode(ReaderAppearance.self, from: data) {
            return stored.normalized
        }
        let legacyFontSize = preferences.integer(forKey: PreferenceKey.articleFontSize)
        return ReaderAppearance(
            fontSize: (ReaderAppearance.minimumFontSize...ReaderAppearance.maximumFontSize).contains(legacyFontSize)
                ? legacyFontSize
                : ReaderAppearance.defaultFontSize
        )
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
        self.llm = LLMService(port: URLSessionAIModelAdapter(session: customSession ?? .shared))
        self.preparationEngine = ArticlePreparationEngine(pageLoader: pageLoader ?? DefaultArticlePageLoader())
        let applicationSupport = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        let directory = applicationSupport.appendingPathComponent("PaperRss", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.persistenceURL = persistenceURL ?? directory.appendingPathComponent("library.json")
        // Tests and preview callers pass isolated database/persistence URLs. Do
        // not leak the v2 provider snapshot into the process-wide defaults in
        // those cases; the real app uses the default locations and persists it.
        self.shouldPersistAISettings = databaseURL == nil && persistenceURL == nil
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
        let recoveredLegacyConfiguration = LegacyPreferenceMigrator.recoverLLMConfigurationIfNeeded(from: self.persistenceURL, fileManager: fileManager)
        if let recovered = recoveredLegacyConfiguration {
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
        readerAppearance = Self.loadReaderAppearance(from: preferences)

        let legacyConfiguration: LLMConfiguration
        var hasLegacyConfiguration = recoveredLegacyConfiguration != nil || !LocalAPIKeyStore.loadAPIKey().isEmpty
        if let data = preferences.data(forKey: PreferenceKey.llmConfiguration),
           let savedConfig = try? JSONDecoder().decode(LLMConfiguration.self, from: data) {
            legacyConfiguration = savedConfig
            hasLegacyConfiguration = true
        } else {
            legacyConfiguration = llmConfiguration
        }

        if let data = preferences.data(forKey: PreferenceKey.aiSettings)
            ?? preferences.data(forKey: PreferenceKey.legacyAISettingsV4)
            ?? preferences.data(forKey: PreferenceKey.legacyAISettings),
           let savedSettings = try? JSONDecoder().decode(AISettings.self, from: data),
           !savedSettings.providers.isEmpty {
            let migratedSettings = savedSettings.migratedToCurrentSchema()
            for builtInID in [AIProviderID.openAI, AIProviderID.deepSeek, AIProviderID.gemini] {
                let customID = AISettings.migratedCustomProviderID(for: builtInID)
                if migratedSettings.provider(id: customID) != nil,
                   LocalAPIKeyStore.loadAPIKey(for: customID).isEmpty {
                    _ = LocalAPIKeyStore.saveAPIKey(LocalAPIKeyStore.loadAPIKey(for: builtInID), for: customID)
                }
            }
            aiSettings = migratedSettings
            if let summaryConfiguration = migratedSettings.resolvedConfiguration(for: .summary) {
                llmConfiguration = summaryConfiguration
            } else {
                llmConfiguration = legacyConfiguration
            }
            persistAISettings(migratedSettings)
            // Keep the old projection current for an older build that does
            // not know about the v2 provider document yet.
            if let summaryReference = migratedSettings.configuration(for: .summary)?.model,
               let summaryConfiguration = migratedSettings.resolvedConfiguration(for: .summary) {
                persistLegacyCompatibilityPairIfPossible(
                    configuration: summaryConfiguration,
                    providerID: summaryReference.providerID
                )
            }
        } else {
            let migrated = hasLegacyConfiguration ? AISettings.migrated(from: legacyConfiguration) : .default
            aiSettings = migrated
            llmConfiguration = migrated.resolvedConfiguration(for: .summary) ?? legacyConfiguration
            // Migrate the legacy key before writing v2. If the process is
            // interrupted, the next launch can safely repeat this idempotent
            // step; a newly-added empty provider will never inherit it later.
            _ = LocalAPIKeyStore.migrateLegacyAPIKeyIfNeeded(to: migrated.activeProviderID)
            persistAISettings(migrated)
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
    }

    /// 测试用初始化器（隔离测试沙箱）
    public init(
        testDatabase: AppDatabase,
        feedFetcher: @escaping @Sendable (Feed) async throws -> FeedFetchResult,
        credentialStore: CredentialStore? = nil,
        pageLoader: (any ArticlePageLoading)? = nil,
        aiModelPort: (any AIModelPort)? = nil
    ) {
        self.feedFetcher = feedFetcher
        self.customSession = nil
        self.llm = LLMService(port: aiModelPort ?? URLSessionAIModelAdapter())
        self.preparationEngine = ArticlePreparationEngine(pageLoader: pageLoader ?? DefaultArticlePageLoader())
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.persistenceURL = tempDir.appendingPathComponent("library.json")
        self.shouldPersistAISettings = false
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
        readerAppearance = Self.loadReaderAppearance(from: preferences)
        aiSettings = AISettings.migrated(from: testDatabase.llmConfiguration)
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

        let allFeedRecords = (try? libraryDatabase.read { db in
            try FeedRecord.fetchAll(db)
        }) ?? []
        let accountIDByFeedID = Dictionary(
            uniqueKeysWithValues: allFeedRecords.map { ($0.id, $0.accountID) }
        )
        if let allFeeds = try? libraryDatabase.read({ db in
            try self.localProvider.feedRepository.fetchAllFeedModels(accountID: nil, in: db)
        }) {
            for feed in allFeeds {
                let accID = accountIDByFeedID[feed.id.uuidString] ?? "local-default"
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

    /// 异步构造刷新后的 UI 快照。所有 SQLite 读取都在 GRDB reader queue 执行，
    /// MainActor 只负责最后一次性提交已完成的值，避免刷新尾部再次阻塞三栏。
    private func reloadStateAsync() async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date()).timeIntervalSince1970
        let limit = Self.defaultTimelineLimit
        let database = libraryDatabase
        let feedRepository = localProvider.feedRepository
        let timelineQueryService = localProvider.timelineQueryService

        let fetchedAccounts = (try? await database.readAsync { db in
            try AccountRecord.order(Column("created_at").asc).fetchAll(db)
        }) ?? []

        let allFeedRecords = (try? await database.readAsync { db in
            try FeedRecord.fetchAll(db)
        }) ?? []
        let accountIDByFeedID = Dictionary(
            uniqueKeysWithValues: allFeedRecords.map { ($0.id, $0.accountID) }
        )
        let allFeeds = (try? await database.readAsync { db in
            try feedRepository.fetchAllFeedModels(accountID: nil, in: db)
        }) ?? []
        var newFeedsByAccount: [String: [Feed]] = [:]
        for feed in allFeeds {
            let accountID = accountIDByFeedID[feed.id.uuidString] ?? "local-default"
            newFeedsByAccount[accountID, default: []].append(feed)
        }

        let allFolders = (try? await database.readAsync { db in
            try feedRepository.fetchAllFolders(accountID: nil, in: db)
        }) ?? []
        var newFoldersByAccount: [String: [String]] = [:]
        for folder in allFolders {
            newFoldersByAccount[folder.accountID, default: []].append(folder.name)
        }

        async let sidebarCountsResult = try? timelineQueryService.fetchSidebarCountsAsync(startOfDayTimestamp: startOfDay)
        async let allItemsResult = try? timelineQueryService.fetchListItemsAsync(scope: .all, limit: limit)
        async let todayItemsResult = try? timelineQueryService.fetchListItemsAsync(
            scope: .today(startOfDayTimestamp: startOfDay),
            limit: limit
        )
        async let unreadItemsResult = try? timelineQueryService.fetchListItemsAsync(scope: .unread, limit: limit)
        async let starredItemsResult = try? timelineQueryService.fetchListItemsAsync(scope: .starred, limit: limit)
        let (resolvedSidebarCounts, resolvedAllItems, resolvedTodayItems, resolvedUnreadItems, resolvedStarredItems) = await (
            sidebarCountsResult,
            allItemsResult,
            todayItemsResult,
            unreadItemsResult,
            starredItemsResult
        )

        let syncStateRecords = (try? await database.readAsync { db in
            try AccountSyncStateRecord.fetchAll(db)
        }) ?? []
        let syncStates = Dictionary(uniqueKeysWithValues: syncStateRecords.map { ($0.accountID, $0) })

        accounts = fetchedAccounts
        feedsByAccount = newFeedsByAccount
        foldersByAccount = newFoldersByAccount
        feeds = newFeedsByAccount["local-default"] ?? []
        customFolders = newFoldersByAccount["local-default"] ?? []
        sidebarCounts = resolvedSidebarCounts ?? SidebarCounts()
        entryListItems = resolvedAllItems ?? []
        todayEntryListItems = resolvedTodayItems ?? []
        unreadEntryListItems = resolvedUnreadItems ?? []
        starredEntryListItems = resolvedStarredItems ?? []
        cachedEntryLookup.removeAll(keepingCapacity: true)
        accountSyncStates = syncStates

        for account in fetchedAccounts where account.type == AccountType.freshRSS.rawValue {
            if account.isEnabled,
               let urlStr = account.endpointURL,
               let url = URL(string: urlStr),
               let username = account.username {
                let provider = FreshRSSAccountProvider(
                    accountID: account.id,
                    endpointURL: url,
                    username: username,
                    database: database,
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

        timelineRevision &+= 1
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
        unreadOnly: Bool = false,
        retainingIDs: Set<String> = [],
        limit: Int = 100,
        offset: Int = 0
    ) -> [EntryListItem] {
        (try? localProvider.timelineQueryService.fetchListItems(
            scope: scope,
            unreadOnly: unreadOnly,
            retainingIDs: retainingIDs,
            limit: limit,
            offset: offset
        )) ?? []
    }

    public func fetchAdjacentItem(
        scope: TimelineScope,
        unreadOnly: Bool = false,
        currentItemID: String,
        direction: AdjacentTimelineDirection,
        retainingIDs: Set<String> = []
    ) -> EntryListItem? {
        try? localProvider.timelineQueryService.fetchAdjacentItem(
            scope: scope,
            unreadOnly: unreadOnly,
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
            let message = I18N.localized("请输入有效的 Feed URL。")
            reportErrorMessage(message, module: .settings)
            lastError = message
            return
        }

        let title = url.host ?? url.absoluteString
        let feed: Feed
        do {
            feed = try localProvider.addFeed(title: title, feedURL: url, folder: folder)
        } catch let error as LocalAccountError {
            let message = error.errorDescription ?? error.localizedDescription
            reportError(error, module: .settings)
            lastError = message
            return
        } catch {
            reportError(error, module: .settings)
            lastError = error.localizedDescription
            return
        }

        reloadState()
        await refresh(feedIDs: [feed.id], origin: .subscriptionManagement)
    }

    public func removeFeed(_ feed: Feed) {
        guard deleteFeedAndInvalidateRefresh(feed.id) else { return }
        publishDeletedFeedState([feed.id])
        scheduleAsyncStateReload()
    }

    public func deleteFeed(_ feed: Feed) {
        removeFeed(feed)
    }

    public func deleteFeeds(_ feedsToDelete: [Feed]) {
        var deletedIDs = Set<UUID>()
        for feed in feedsToDelete {
            if deleteFeedAndInvalidateRefresh(feed.id) {
                deletedIDs.insert(feed.id)
            }
        }
        publishDeletedFeedState(deletedIDs)
        scheduleAsyncStateReload()
    }

    public func deleteFeeds(_ ids: Set<UUID>) {
        var deletedIDs = Set<UUID>()
        for id in ids {
            if deleteFeedAndInvalidateRefresh(id) {
                deletedIDs.insert(id)
            }
        }
        publishDeletedFeedState(deletedIDs)
        scheduleAsyncStateReload()
    }

    public func deleteFeeds(_ ids: [UUID]) {
        deleteFeeds(Set(ids))
    }

    @discardableResult
    private func deleteFeedAndInvalidateRefresh(_ feedID: UUID) -> Bool {
        do {
            try localProvider.deleteFeed(feedID: feedID)
            invalidatedRefreshFeedIDs.insert(feedID)
            activeRefreshFeedTasks[feedID]?.cancel()
            return true
        } catch {
            // 保持原有删除 API 的静默失败语义；删除未成功时不取消刷新任务。
            return false
        }
    }

    /// 先同步移除可见投影，让删除按钮立即反馈；完整计数和多账号快照在后台重建。
    private func publishDeletedFeedState(_ feedIDs: Set<UUID>) {
        guard !feedIDs.isEmpty else { return }

        feedsByAccount = feedsByAccount.mapValues { feeds in
            feeds.filter { !feedIDs.contains($0.id) }
        }
        feeds.removeAll { feedIDs.contains($0.id) }

        let removedItems = entryListItems.filter { feedIDs.contains($0.feedID) }
        let removedEntryIDs = Set(removedItems.map(\.id))
        let removedTodayUnreadCount = todayEntryListItems.filter {
            feedIDs.contains($0.feedID) && !$0.isRead
        }.count
        let removedStarredCount = starredEntryListItems.filter { feedIDs.contains($0.feedID) }.count
        let removedUnreadCount = feedIDs.reduce(0) { $0 + (sidebarCounts.unreadByFeed[$1] ?? 0) }

        entryListItems.removeAll { feedIDs.contains($0.feedID) }
        todayEntryListItems.removeAll { feedIDs.contains($0.feedID) }
        unreadEntryListItems.removeAll { feedIDs.contains($0.feedID) }
        starredEntryListItems.removeAll { feedIDs.contains($0.feedID) }
        for entryID in removedEntryIDs {
            cachedEntryLookup.removeValue(forKey: entryID)
        }

        var nextCounts = sidebarCounts
        nextCounts.allUnread = max(0, nextCounts.allUnread - removedUnreadCount)
        nextCounts.todayUnread = max(0, nextCounts.todayUnread - removedTodayUnreadCount)
        nextCounts.starred = max(0, nextCounts.starred - removedStarredCount)
        for feedID in feedIDs {
            nextCounts.unreadByFeed.removeValue(forKey: feedID)
        }
        sidebarCounts = nextCounts
        timelineRevision &+= 1
    }

    private func scheduleAsyncStateReload() {
        guard !isRefreshing else {
            stateReloadPendingAfterRefresh = true
            return
        }
        Task { @MainActor [weak self] in
            await self?.reloadStateAsync()
        }
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
        let newFeedIDs = (try? await localProvider.importOPMLAsync(data)) ?? []
        guard !newFeedIDs.isEmpty else { return }
        await reloadStateAsync()
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
        invalidatedRefreshFeedIDs.removeAll(keepingCapacity: true)
        defer {
            for task in activeRefreshFeedTasks.values {
                task.cancel()
            }
            activeRefreshFeedTasks.removeAll(keepingCapacity: true)
            invalidatedRefreshFeedIDs.removeAll(keepingCapacity: true)
            isRefreshing = false
            if stateReloadPendingAfterRefresh {
                stateReloadPendingAfterRefresh = false
                scheduleAsyncStateReload()
            }
        }
        refreshStatus = .refreshing

        var failures: [String] = []
        var updatedFeeds = 0
        var newUnreadEntries: [Entry] = []
        var shouldReloadLocalSnapshot = false

        // 1. 本地源抓取（指定局部源或全局本地源）
        let targetFeeds: [Feed]
        if let feedIDs {
            targetFeeds = feeds.filter { feedIDs.contains($0.id) && !$0.isDeleted }
        } else if isAccountEnabled("local-default") {
            targetFeeds = feeds.filter { !$0.isDeleted }
        } else {
            targetFeeds = []
        }

        let maxConcurrency = 6
        let provider = self.localProvider

        await withTaskGroup(of: LocalAccountProvider.SingleFeedRefreshResult.self) { group in
            var feedIndex = 0
            var activeTaskCount = 0

            while feedIndex < targetFeeds.count && activeTaskCount < maxConcurrency {
                let feed = targetFeeds[feedIndex]
                feedIndex += 1
                guard !invalidatedRefreshFeedIDs.contains(feed.id) else { continue }
                let fetchTask = Task.detached { [provider] in
                    await provider.fetchSingleFeed(feed: feed)
                }
                activeRefreshFeedTasks[feed.id] = fetchTask
                activeTaskCount += 1
                group.addTask {
                    await fetchTask.value
                }
            }

            while let taskResult = await group.next() {
                activeTaskCount -= 1
                activeRefreshFeedTasks.removeValue(forKey: taskResult.feedID)

                // 删除动作已经使本轮 Feed 失效：不计失败、不写数据库、不生成通知。
                if !invalidatedRefreshFeedIDs.contains(taskResult.feedID) {
                    shouldReloadLocalSnapshot = true
                    do {
                        let outcome = try await provider.applyRefreshResultAsync(taskResult)
                        if outcome.updated { updatedFeeds += 1 }
                        newUnreadEntries.append(contentsOf: outcome.newUnreadEntries)
                    } catch {
                        failures.append("\(taskResult.oldTitle)：\(error.localizedDescription)")
                    }

                    if case let .failure(error) = taskResult.result {
                        failures.append("\(taskResult.oldTitle)：\(error.localizedDescription)")
                    }
                }

                while feedIndex < targetFeeds.count && activeTaskCount < maxConcurrency {
                    let feed = targetFeeds[feedIndex]
                    feedIndex += 1
                    guard !invalidatedRefreshFeedIDs.contains(feed.id) else { continue }
                    let fetchTask = Task.detached { [provider] in
                        await provider.fetchSingleFeed(feed: feed)
                    }
                    activeRefreshFeedTasks[feed.id] = fetchTask
                    activeTaskCount += 1
                    group.addTask {
                        await fetchTask.value
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
            await reloadStateAsync()

            // 提取远端同步产生的新未读文章
            let currentUnreads = self.unreadEntryListItems.map(\.id)
            let newlyArrivedIDs = currentUnreads.filter { !initialUnreadIDs.contains($0) }
            for id in newlyArrivedIDs {
                if let entry = entry(id: id) {
                    newUnreadEntries.append(entry)
                }
            }
        } else {
            // 局部刷新没有远端账号同步，需要在所有异步 merge 完成后只重载一次。
            // 如果本轮唯一的 Feed 已在刷新期间删除，删除动作本身已经同步了 UI；
            // 跳过一次昂贵的全量快照，避免无效刷新继续占住 Loading。
            if shouldReloadLocalSnapshot {
                await reloadStateAsync()
            }
        }

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
            if reportErrors {
                reportErrorMessage(message, module: .refresh)
                lastError = message
            }
        }

        // 如果本轮所有本地目标都已被删除，网络任务已经取消，Loading 不应再额外等待
        // 固定的最短展示时长。仍有其它 Feed 未失效时保留最短时长，避免正常刷新闪烁。
        let hasNonInvalidatedTarget = targetFeeds.contains { !invalidatedRefreshFeedIDs.contains($0.id) }
        let shouldKeepMinimumIndicator = invalidatedRefreshFeedIDs.isEmpty || hasNonInvalidatedTarget
        if shouldKeepMinimumIndicator {
            let minimumIndicatorDuration: TimeInterval = 1.2
            let remainingDuration = minimumIndicatorDuration - Date.now.timeIntervalSince(startedAt)
            if remainingDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingDuration * 1_000_000_000))
            }
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
            reportError(error, module: .settings)
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
            reportError(error, module: .settings)
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
    public func prepareArticle(
        for entry: Entry,
        policy: ArticlePreparationPolicy = .foregroundRefresh
    ) async -> PreparedArticle {
        let fingerprint = PreparedArticleMemoryCache.contentFingerprint(for: entry)
        if let memoized = preparedArticleMemoryCache.article(for: entry.id, contentFingerprint: fingerprint) {
            return memoized
        }
        // 注：预取与阅读加载可能对同一 entry 并发准备（罕见且良性，后写者胜出）。
        // 刻意不做共享去重任务：非结构化 Task 会切断视图
        // .task(id:) 的取消传播，导致快速切换无法中止在途网络请求。
        // 内容一致性仅对缓存命中/全文 Feed 成立：摘要 Feed 的 localOnly 预取
        // 产出纯 Feed 摘要，与前台（含网页抓取）结果不同——该差异由下方
        // isProvisionalPrefetch 门禁拦截，禁止降级内容进入内存缓存。
        let generationAtStart = preparedArticleMemoryCache.generation
        let cached = try? localProvider.fetchCache(entryID: entry.id)
        let feed = self.feed(for: entry)
        let result = await preparationEngine.prepare(
            entry: entry,
            cached: cached,
            feed: feed,
            policy: policy
        )
        let prepared = result.prepared
        var permitsMemoryCaching = true
        if let updatedCache = result.updatedCache, !Task.isCancelled {
            do {
                try localProvider.saveCache(updatedCache)
                if result.didRefreshCache {
                    preparedArticleMemoryCache.invalidate(entryID: entry.id)
                    articleRefreshSignal = ArticleRefreshSignal(entryID: entry.id, token: UUID())
                }
            } catch {
                // 保留本次已准备正文供前台显示；磁盘未升级时下次打开仍会重试。
                if result.didRefreshCache {
                    permitsMemoryCaching = false
                }
            }
        }
        // 取消的任务可能产出兜底结果，不污染内存缓存；
        // .fallback 表示本次未能产出真实正文（如网络瞬时失败），
        // 不缓存以便下次访问重新尝试；
        // isProvisionalLocal 表示 localOnly 预取的弱 Feed 摘要（摘要 Feed 场景
        // 远弱于网页全文），入缓存会让正式打开命中它并跳过网页升级；
        // 准备期间若发生失效（如重抓写入更好缓存），代数不匹配则放弃存储。
        if !Task.isCancelled,
           permitsMemoryCaching,
           prepared.source != .fallback,
           result.cacheState == .current,
           !result.isProvisionalLocal,
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
        unreadOnly: Bool = false,
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
                    unreadOnly: unreadOnly,
                    currentItemID: currentItemID,
                    direction: direction,
                    retainingIDs: retainingIDs
                )
                guard let neighborID = adjacent?.id,
                      !self.preparedArticleMemoryCache.contains(neighborID),
                      let neighbor = self.entry(id: neighborID) else { continue }
                _ = await self.prepareArticle(for: neighbor, policy: .localOnly)
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

    private func currentAIExecutionContext(
        for feature: AIFeatureKind = .summary,
        configuration: LLMConfiguration? = nil
    ) -> AIExecutionContext {
        let reference = aiSettings.configuration(for: feature)?.model
        let provider = reference.flatMap { aiSettings.provider(id: $0.providerID) }
        return AIExecutionContext(
            providerID: provider?.id ?? AIProviderID.migratedLegacy,
            providerKind: provider?.kind ?? .customOpenAICompatible,
            configuration: configuration ?? aiSettings.resolvedConfiguration(for: feature) ?? llmConfiguration
        )
    }

    private func executionSnapshot(for feature: AIFeatureKind) -> (AIExecutionContext, String)? {
        guard aiSettings.configuration(for: feature)?.isEnabled == true,
              aiSettings.resolvedConfiguration(for: feature) != nil else { return nil }
        let execution = currentAIExecutionContext(for: feature)
        if execution.configuration.usesTranslationAdaptation,
           feature != .bilingualTranslation && feature != .selectionTranslation {
            emitTransientNotice(LLMServiceError.translationOnly.localizedDescription)
            return nil
        }
        return (execution, apiKey(for: execution.providerID))
    }

    private func artifactPromptVersion(for kind: AIArtifactKind) -> Int {
        kind == .bilingual || kind == .translation ? Self.translationPromptVersion : 1
    }

    private func currentArtifactFingerprint(for kind: AIArtifactKind, configuration: LLMConfiguration? = nil) -> String {
        currentAIExecutionContext(configuration: configuration)
            .fingerprint(for: kind, promptVersion: artifactPromptVersion(for: kind))
    }

    private func providerRequiresAPIKey(_ kind: AIProviderKind) -> Bool {
        kind != .customOpenAICompatible
    }

    public func artifact(for entry: Entry, kind: AIArtifactKind) -> AIArtifact? {
        try? localProvider.fetchArtifact(
            entryID: entry.id,
            kind: kind,
            isCompleteOnly: true,
            configurationFingerprint: currentArtifactFingerprint(for: kind)
        )
    }

    public func summaryArtifact(for entry: Entry) -> AIArtifact? {
        try? localProvider.fetchArtifact(
            entryID: entry.id,
            kind: .summary,
            isCompleteOnly: true
        )
    }

    public func isSummaryStale(for entry: Entry, text: String) -> Bool {
        guard let summary = summaryArtifact(for: entry) else { return false }
        return summary.contentHash != text.stableDigest
    }

    public func bilingualArtifact(for entry: Entry, text: String) -> AIArtifact? {
        let hash = text.stableDigest
        return try? localProvider.fetchBilingualArtifact(
            entryID: entry.id,
            contentHash: hash,
            targetLanguage: llmConfiguration.targetLanguage
        )
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
        guard let (execution, apiKey) = executionSnapshot(for: .summary) else { return }
        let configuration = execution.configuration
        let fingerprint = execution.fingerprint(for: .summary, promptVersion: 1)
        let hash = text.stableDigest
        if !force, summaryArtifact(for: entry) != nil {
            return
        }
        lastError = nil
        let requestID = UUID()
        activeSummaryRequest = AIRequestStatus(requestID: requestID, entryID: entry.id, kind: .summary, phase: .loadingLocalConfiguration)
        guard !apiKey.isEmpty || !providerRequiresAPIKey(execution.providerKind) else {
            if activeSummaryRequest?.requestID == requestID { activeSummaryRequest = nil }
            let error = LLMServiceError.missingAPIKey
            reportError(error, module: .ai)
            lastError = error.localizedDescription
            return
        }

        activeSummaryRequest = AIRequestStatus(requestID: requestID, entryID: entry.id, kind: .summary, phase: .generating)

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
                providerID: execution.providerID,
                configurationFingerprint: fingerprint,
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
            try? localProvider.replaceCurrentSummary(with: finalArtifact)
            if activeSummaryRequest?.requestID == requestID { activeSummaryRequest = nil }
        } catch {
            var abandonedArtifact = tracker.currentArtifact
            abandonedArtifact.isDeleted = true
            abandonedArtifact.updatedAt = .now
            try? localProvider.saveArtifact(abandonedArtifact)
            if activeSummaryRequest?.requestID == requestID { activeSummaryRequest = nil }
            if !Task.isCancelled {
                reportError(error, module: .ai)
                lastError = error.localizedDescription
            }
        }
    }

    public func generateBilingualTranslation(entry: Entry, text: String, targetLanguage: String? = nil) async {
        let paragraphs = ArticleExtractor.readerParagraphs(in: text, title: entry.title)
        guard !paragraphs.isEmpty else { return }
        await translateBilingualParagraphs(
            entry: entry,
            text: text,
            paragraphs: paragraphs,
            paragraphIDs: paragraphs.map(\.id),
            targetLanguage: targetLanguage
        )
    }

    public func dismissError() {
        lastError = nil
    }

    /// 发出非阻断式瞬时提示。同一消息在冷却期内的重复触发（如翻译批次
    /// 随滚动多次失败）只保留一次，避免 toast 刷屏。
    public func emitTransientNotice(_ message: String, cooldown: TimeInterval = 8) {
        if message == transientNoticeSignature,
           Date.now.timeIntervalSince(transientNoticeAt) < cooldown {
            return
        }
        transientNoticeSignature = message
        transientNoticeAt = .now
        transientNotice = TransientNotice(message: message)
    }

    public func dismissTransientNotice() {
        transientNotice = nil
    }

    public func reportError(_ error: Error, module: FeedbackModule, at date: Date = .now) {
        latestFeedbackError = FeedbackErrorSnapshot(
            module: module,
            message: error.localizedDescription,
            occurredAt: date
        )
    }

    public func reportErrorMessage(_ message: String, module: FeedbackModule, at date: Date = .now) {
        latestFeedbackError = FeedbackErrorSnapshot(module: module, message: message, occurredAt: date)
    }

    @discardableResult
    public func explainSelection(
        entry: Entry,
        selection: String,
        localContext: String = "",
        articleText: String = "",
        selectionAnchor: AISelectionAnchor? = nil,
        onDelta: (@Sendable (String) async -> Void)? = nil,
        isRequestCurrent: @MainActor @Sendable @escaping () -> Bool = { true }
    ) async throws -> String {
        // hash 基准与 articleContext 相同；正常路径下 == preparedArticle.text
        // 的 digest，与划词标注恢复查询 (savedSelectionAnnotations) 严格同源。
        let anchorArticleHash = (articleText.isEmpty ? entry.sourceText : articleText).stableDigest
        let opResult = await executeSelectionAI(
            entry: entry,
            kind: .selectionExplanation,
            selectionText: selection,
            selectionAnchor: selectionAnchor,
            selectionArticleHash: anchorArticleHash,
            isRequestCurrent: isRequestCurrent,
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
        targetLanguage: String? = nil,
        onDelta: (@Sendable (String) async -> Void)? = nil,
        isRequestCurrent: @MainActor @Sendable @escaping () -> Bool = { true }
    ) async throws -> String {
        let opResult = await executeSelectionAI(
            entry: entry,
            kind: .translation,
            selectionText: selection,
            isRequestCurrent: isRequestCurrent,
            operation: { [weak self] apiKey, config in
                guard let self else { return nil }
                var updatedConfig = config
                if let targetLanguage {
                    let normalizedLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalizedLanguage.isEmpty {
                        updatedConfig.targetLanguage = normalizedLanguage
                    }
                }
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
        onDelta: (@Sendable (String) async -> Void)? = nil,
        isRequestCurrent: @MainActor @Sendable @escaping () -> Bool = { true }
    ) async throws -> String {
        // 与 explainSelection 相同的 hash 基准；缺失该字段的提问 artifact
        // 无法被划词标注恢复链路检索（切换文章后提问图标消失的根因）。
        let anchorArticleHash = (articleText.isEmpty ? entry.sourceText : articleText).stableDigest
        let opResult = await executeSelectionAI(
            entry: entry,
            kind: .interpretation,
            selectionText: selection,
            selectionAnchor: selectionAnchor,
            selectionArticleHash: anchorArticleHash,
            isRequestCurrent: isRequestCurrent,
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
        targetLanguage: String? = nil,
        onDelta: (@Sendable (String, String) async -> Void)? = nil,
        isRequestCurrent: @MainActor @Sendable @escaping () -> Bool = { true }
    ) async {
        guard !paragraphs.isEmpty, !paragraphIDs.isEmpty, isRequestCurrent() else { return }

        guard let (baseExecution, apiKey) = executionSnapshot(for: .bilingualTranslation) else { return }
        var configuration = baseExecution.configuration
        if let targetLanguage {
            let normalizedLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedLanguage.isEmpty {
                configuration.targetLanguage = normalizedLanguage
            }
        }
        let hash = text.stableDigest
        let execution = AIExecutionContext(
            providerID: baseExecution.providerID,
            providerKind: baseExecution.providerKind,
            configuration: configuration
        )
        let fingerprint = execution.fingerprint(for: .bilingual, promptVersion: Self.translationPromptVersion)
        let requestedIDsSet = Set(paragraphIDs)
        let targetParagraphs = paragraphs.filter { requestedIDsSet.contains($0.id) }
        guard !targetParagraphs.isEmpty else { return }

        let paragraphOrder: [String: Int] = Dictionary(uniqueKeysWithValues: paragraphs.enumerated().map { ($1.id, $0) })

        // 1. 用户可见双语产物按正文与目标语言稳定复用；模型只记录来源。
        var artifact = (try? localProvider.fetchBilingualArtifact(
            entryID: entry.id,
            contentHash: hash,
            targetLanguage: configuration.targetLanguage
        ))
            ?? AIArtifact(
                id: UUID(),
                entryID: entry.id,
                kind: .bilingual,
                contentHash: hash,
                model: configuration.model,
                targetLanguage: configuration.targetLanguage,
                promptVersion: Self.translationPromptVersion,
                providerID: execution.providerID,
                configurationFingerprint: fingerprint,
                content: "",
                segments: [],
                isComplete: false
            )

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
                    await onDelta(paragraph.id, existing.translation)
                }
                guard isRequestCurrent(), !Task.isCancelled else { return }
                continue
            }
            if let tmTranslation = cachedTranslation(
                for: paragraph.original,
                configuration: configuration,
                executionContext: execution
            ) {
                let seg = BilingualSegment(id: paragraph.id, original: paragraph.original, translation: tmTranslation)
                newResolvedSegments.append(seg)
                if let onDelta {
                    await onDelta(paragraph.id, tmTranslation)
                }
                guard isRequestCurrent(), !Task.isCancelled else { return }
            } else {
                uncachedParagraphs.append(paragraph)
            }
        }

        // 如果有 TM 命中的段落，先合并
        if !newResolvedSegments.isEmpty {
            guard isRequestCurrent(), !Task.isCancelled else { return }
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
        guard isRequestCurrent(), !Task.isCancelled else { return }

        // 4. 检查 API Key
        guard !apiKey.isEmpty || !providerRequiresAPIKey(execution.providerKind) else {
            let error = LLMServiceError.missingAPIKey
            reportError(error, module: .ai)
            // 未配置 API Key 属于可预期的环境状态，且翻译随滚动批量触发，
            // 走非阻断 toast 并冷却去重，不弹 lastError 阻断式弹窗。
            emitTransientNotice(error.localizedDescription)
            return
        }

        let requestID = UUID()
        activeBilingualRequest = AIRequestStatus(requestID: requestID, entryID: entry.id, kind: .bilingual, phase: .generating)
        defer {
            if activeBilingualRequest?.requestID == requestID { activeBilingualRequest = nil }
        }

        // 5. 完全相同的原文只发送一次；每篇最多两个批次并行，先返回的先显示。
        // 不折叠原文空白，避免合并代码或空白具有含义的段落。
        let paragraphsBySource = Dictionary(grouping: uncachedParagraphs, by: \.original)
        var seenSources = Set<String>()
        let uniqueParagraphs = uncachedParagraphs.filter { seenSources.insert($0.original).inserted }
        let batches = configuration.usesTranslationAdaptation ? uniqueParagraphs.map { [$0] } : translationBatches(from: uniqueParagraphs)
        let batchConfiguration = configuration
        let service = llm
        do {
            try await withThrowingTaskGroup(of: ([ReaderParagraph], [String]).self) { group in
                var nextBatchIndex = 0
                func enqueueNextBatch() {
                    guard nextBatchIndex < batches.count else { return }
                    let batch = batches[nextBatchIndex]
                    nextBatchIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let translations = try await service.translateBatch(
                            paragraphs: batch.map(\.original),
                            configuration: batchConfiguration,
                            apiKey: apiKey
                        )
                        return (batch, translations)
                    }
                }
                for _ in 0..<min(2, batches.count) { enqueueNextBatch() }
                for try await (batch, translatedTexts) in group {
                    guard !Task.isCancelled, isRequestCurrent() else {
                        group.cancelAll()
                        return
                    }

                    let batchSegments = zip(batch, translatedTexts).flatMap { paragraph, translation in
                        (paragraphsBySource[paragraph.original] ?? [paragraph]).map {
                            BilingualSegment(
                                id: $0.id,
                                original: $0.original,
                                translation: translation,
                                providerID: execution.providerID,
                                modelID: batchConfiguration.model,
                                configurationFingerprint: fingerprint
                            )
                        }
                    }
                    cacheTranslations(
                        batchSegments,
                        configuration: configuration,
                        executionContext: execution
                    )

                    // 触发 onDelta
                    if let onDelta {
                        for seg in batchSegments {
                            await onDelta(seg.id, seg.translation)
                            guard isRequestCurrent(), !Task.isCancelled else { group.cancelAll(); return }
                        }
                    }

                    guard isRequestCurrent(), !Task.isCancelled else { group.cancelAll(); return }

                    // 合并入当前 artifact
                    var current = (try? localProvider.fetchBilingualArtifact(
                        entryID: entry.id,
                        contentHash: hash,
                        targetLanguage: configuration.targetLanguage
                    )) ?? artifact
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
                    enqueueNextBatch()
                }
            }
        } catch {
            if !Task.isCancelled, isRequestCurrent() {
                reportError(error, module: .ai)
                // 翻译失败随滚动批量触发，走非阻断 toast 并冷却去重。
                emitTransientNotice(error.localizedDescription)
            }
        }
    }

    private func executeSelectionAI(
        entry: Entry,
        kind: AIArtifactKind,
        selectionText: String? = nil,
        selectionAnchor: AISelectionAnchor? = nil,
        selectionArticleHash: String? = nil,
        isRequestCurrent: @MainActor @Sendable @escaping () -> Bool,
        operation: @Sendable @escaping (String, LLMConfiguration) async throws -> String?
    ) async -> String? {
        let feature: AIFeatureKind
        switch kind {
        case .translation: feature = .selectionTranslation
        case .selectionExplanation: feature = .selectionExplanation
        case .interpretation, .articleContext: feature = .selectionAsk
        case .summary: feature = .summary
        case .bilingual: feature = .bilingualTranslation
        }
        guard let (execution, apiKey) = executionSnapshot(for: feature) else { return nil }
        let configuration = execution.configuration
        guard activeSelectionRequest == nil else { return nil }
        lastError = nil
        let requestID = UUID()
        activeSelectionRequest = AIRequestStatus(requestID: requestID, entryID: entry.id, kind: kind, phase: .loadingLocalConfiguration)
        guard !apiKey.isEmpty || !providerRequiresAPIKey(execution.providerKind) else {
            if activeSelectionRequest?.requestID == requestID { activeSelectionRequest = nil }
            let error = LLMServiceError.missingAPIKey
            reportError(error, module: .ai)
            lastError = error.localizedDescription
            return nil
        }
        activeSelectionRequest = AIRequestStatus(requestID: requestID, entryID: entry.id, kind: kind, phase: .generating)
        do {
            let result = try await operation(apiKey, configuration)
            guard isRequestCurrent(), !Task.isCancelled else {
                if activeSelectionRequest?.requestID == requestID { activeSelectionRequest = nil }
                return nil
            }
            if let result {
                let artifact = AIArtifact(
                    entryID: entry.id,
                    kind: kind,
                    contentHash: result.stableDigest,
                    model: configuration.model,
                    targetLanguage: configuration.targetLanguage,
                    promptVersion: 1,
                    providerID: execution.providerID,
                    configurationFingerprint: execution.fingerprint(for: kind, promptVersion: 1),
                    content: result,
                    selectionText: selectionText,
                    selectionArticleHash: selectionArticleHash,
                    selectionAnchor: selectionAnchor,
                    isComplete: true
                )
                try? localProvider.saveArtifact(artifact)
            }
            if activeSelectionRequest?.requestID == requestID { activeSelectionRequest = nil }
            return result
        } catch {
            if activeSelectionRequest?.requestID == requestID { activeSelectionRequest = nil }
            if !Task.isCancelled {
                reportError(error, module: .ai)
                lastError = error.localizedDescription
            }
            return nil
        }
    }

    // MARK: - Translation Memory Helpers

    private func cachedTranslation(
        for source: String,
        configuration: LLMConfiguration,
        executionContext: AIExecutionContext
    ) -> String? {
        let key = translationMemoryKey(
            for: source,
            configuration: configuration,
            executionContext: executionContext
        )
        let entryID = translationMemoryEntryID(for: key)
        return (try? localProvider.fetchGlobalTranslationMemory(key: entryID))?.content
    }

    func cacheTranslations(
        _ segments: [BilingualSegment],
        configuration: LLMConfiguration,
        executionContext: AIExecutionContext? = nil
    ) {
        let execution = executionContext ?? currentAIExecutionContext(configuration: configuration)
        let fingerprint = execution.fingerprint(for: .translation, promptVersion: Self.translationPromptVersion)
        for segment in segments {
            let key = translationMemoryKey(
                for: segment.original,
                configuration: configuration,
                executionContext: execution
            )
            let entryID = translationMemoryEntryID(for: key)
            let artifact = AIArtifact(
                entryID: entryID,
                kind: .translation,
                contentHash: key,
                model: configuration.model,
                targetLanguage: configuration.targetLanguage,
                promptVersion: Self.translationPromptVersion,
                providerID: execution.providerID,
                configurationFingerprint: fingerprint,
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

    private func translationMemoryKey(
        for source: String,
        configuration: LLMConfiguration,
        executionContext: AIExecutionContext
    ) -> String {
        [
            Self.translationMemoryEntryPrefix,
            source.paperRssNormalizedWhitespace,
            executionContext.fingerprint(
                for: .translation,
                promptVersion: Self.translationPromptVersion
            )
        ].joined(separator: "|").stableDigest
    }

    private func translationMemoryEntryID(for key: String) -> String {
        "\(Self.translationMemoryEntryPrefix)\(key)"
    }

    private static let translationPromptVersion = 2
    private static let translationMemoryEntryPrefix = "translation-memory-v4:"
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

    public var activeAIProvider: AIProviderProfile? {
        aiSettings.configuration(for: .summary)?.model
            .flatMap { aiSettings.provider(id: $0.providerID) }
    }

    public func aiProvider(id: String) -> AIProviderProfile? {
        aiSettings.provider(id: id)
    }

    public func apiKey(for providerID: String) -> String {
        LocalAPIKeyStore.loadAPIKey(for: providerID)
    }

    public func activeAPIKey() -> String {
        guard let providerID = aiSettings.configuration(for: .summary)?.model?.providerID else { return "" }
        return apiKey(for: providerID)
    }

    /// Persists the v2 settings document while updating the compatibility
    /// projection consumed by the existing AI actions.
    public func saveAISettings(_ settings: AISettings) {
        guard !settings.providers.isEmpty else { return }
        let normalized = settings.migratedToCurrentSchema()
        aiSettings = normalized
        persistAISettings(normalized)
        // The old configuration and key are one rollback snapshot. Only
        // advance them when the summary route resolves to an enabled provider;
        // disabling a provider must never pair its key with a fallback URL.
        if let summaryConfiguration = normalized.resolvedConfiguration(for: .summary) {
            llmConfiguration = summaryConfiguration
            if let summaryProviderID = normalized.configuration(for: .summary)?.model?.providerID,
               !LocalAPIKeyStore.loadAPIKey(for: summaryProviderID).isEmpty {
                persistLegacyCompatibilityPairIfPossible(
                    configuration: summaryConfiguration,
                    providerID: summaryProviderID
                )
            }
        }
    }

    public func saveAIProvider(_ provider: AIProviderProfile, apiKey: String? = nil) {
        var updated = provider
        if let apiKey, apiKey != self.apiKey(for: provider.id) {
            updated.models = updated.models.map { model in
                var next = model
                next.reasoningMetadata = nil
                return next
            }
        }
        let settings = aiSettings.updatingProvider(updated)
        if let apiKey {
            _ = saveAIProviderKey(apiKey, for: provider.id)
        }
        saveAISettings(settings)
    }

    @discardableResult
    public func saveAIProviderKey(_ apiKey: String, for providerID: String) -> LocalAPIKeyStore.Storage {
        let changed = apiKey != self.apiKey(for: providerID)
        let storage = LocalAPIKeyStore.saveAPIKey(apiKey, for: providerID)
        if changed, var provider = aiSettings.provider(id: providerID) {
            provider.models = provider.models.map { model in
                var next = model
                next.reasoningMetadata = nil
                return next
            }
            saveAISettings(aiSettings.updatingProvider(provider))
        }
        // Keep the old single-provider projection aligned only for the active
        // provider. This lets an older build start safely, while keys for
        // inactive providers never overwrite one another. An empty v2 key is
        // deliberately not mirrored: the legacy value is the rollback copy
        // retained for the first compatible release.
        if providerID == aiSettings.configuration(for: .summary)?.model?.providerID,
           !apiKey.isEmpty,
           let summaryConfiguration = aiSettings.resolvedConfiguration(for: .summary) {
            persistLegacyCompatibilityPairIfPossible(
                configuration: summaryConfiguration,
                providerID: providerID
            )
        }
        return storage
    }

    public func setActiveAIProvider(id: String) {
        guard let provider = aiSettings.provider(id: id), let modelID = provider.models.first?.id else { return }
        let reference = AIModelReference(providerID: id, modelID: modelID)
        var settings = aiSettings.selectingProvider(id: id)
        for kind in AIFeatureKind.allCases {
            let existing = settings.configuration(for: kind)
            let enabled = existing?.isEnabled ?? true
            settings = settings.updatingFeature(
                kind,
                configuration: AIFeatureConfiguration(
                    isEnabled: enabled,
                    model: reference,
                    reasoningMode: existing?.reasoningMode ?? "自动"
                )
            )
        }
        saveAISettings(settings)
        let key = apiKey(for: id)
        if !key.isEmpty,
           let summaryConfiguration = aiSettings.resolvedConfiguration(for: .summary) {
            persistLegacyCompatibilityPairIfPossible(
                configuration: summaryConfiguration,
                providerID: id
            )
        }
    }

    public func setAIModelEnabled(_ enabled: Bool, modelID: String, providerID: String) {
        guard var provider = aiSettings.provider(id: providerID), provider.selectedModelID != modelID,
              let index = provider.models.firstIndex(where: { $0.id == modelID }) else { return }
        provider.models[index].isEnabled = enabled
        saveAIProvider(provider)
    }

    public func addAIProvider(_ provider: AIProviderProfile, apiKey: String = "") {
        _ = LocalAPIKeyStore.saveAPIKey(apiKey, for: provider.id)
        saveAISettings(aiSettings.addingProvider(provider))
    }

    @discardableResult
    public func deleteAIProvider(id: String) -> Bool {
        guard let provider = aiSettings.provider(id: id), !provider.isBuiltIn else {
            return false
        }
        let next = aiSettings.deletingProvider(id: id)
        guard next.providers.count < aiSettings.providers.count else { return false }
        _ = LocalAPIKeyStore.saveAPIKey("", for: id)
        saveAISettings(next)
        return true
    }

    private func persistAISettings(_ settings: AISettings) {
        guard shouldPersistAISettings,
              let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: PreferenceKey.aiSettings)
    }

    private func persistLegacyCompatibilityPairIfPossible(
        configuration: LLMConfiguration,
        providerID: String
    ) {
        guard shouldPersistAISettings else { return }
        let key = LocalAPIKeyStore.loadAPIKey(for: providerID)
        guard !key.isEmpty,
              let data = try? JSONEncoder().encode(configuration) else { return }
        // The old configuration and key form one rollback snapshot. Never
        // advance only the endpoint/model side when the new provider has no
        // credential, which could send the previous provider's secret away.
        _ = LocalAPIKeyStore.saveAPIKey(key)
        UserDefaults.standard.set(data, forKey: PreferenceKey.llmConfiguration)
    }

    @discardableResult
    public func saveLLMConfiguration(_ configuration: LLMConfiguration, apiKey: String) -> LocalAPIKeyStore.Storage {
        // The compatibility entry point may be called by an older settings
        // surface with an empty key. Clear only the provider-scoped v2 value;
        // the legacy key remains as the rollback copy for this release.
        let storage: LocalAPIKeyStore.Storage = apiKey.isEmpty
            ? .localAppConfiguration
            : LocalAPIKeyStore.saveAPIKey(apiKey)
        let destination = compatibilityProviderID(for: configuration)
        var settings = aiSettings
        let source = settings.provider(id: destination)
            ?? AISettings.migrated(from: configuration).provider(id: destination)
            ?? AIProviderProfile(id: destination, kind: .customOpenAICompatible, configuration: configuration)
        let profile = source.replacing(
            name: configuration.providerName,
            description: configuration.providerDescription,
            baseURL: configuration.baseURL,
            selectedModelID: configuration.model,
            reasoningMode: configuration.reasoningMode,
            temperature: configuration.temperature,
            allowInsecureLocalEndpoint: configuration.allowInsecureLocalEndpoint
        ).selectingModel(configuration.model)
        settings = settings.updatingProvider(profile).selectingProvider(id: destination).updatingFeatures(AIFeaturePreferences(configuration: configuration, translationPreferences: settings.features.translationPreferences))
        _ = LocalAPIKeyStore.saveAPIKey(apiKey, for: destination)
        self.llmConfiguration = configuration
        self.aiSettings = settings
        persistAISettings(settings)
        if !apiKey.isEmpty {
            persistLegacyCompatibilityPairIfPossible(configuration: configuration, providerID: destination)
        }
        return storage
    }

    public func updateLLMConfiguration(_ configuration: LLMConfiguration) {
        let destination = compatibilityProviderID(for: configuration)
        var settings = aiSettings
        let source = settings.provider(id: destination)
            ?? AISettings.migrated(from: configuration).provider(id: destination)
            ?? AIProviderProfile(id: destination, kind: .customOpenAICompatible, configuration: configuration)
        let profile = source.replacing(
            name: configuration.providerName,
            description: configuration.providerDescription,
            baseURL: configuration.baseURL,
            selectedModelID: configuration.model,
            reasoningMode: configuration.reasoningMode,
            temperature: configuration.temperature,
            allowInsecureLocalEndpoint: configuration.allowInsecureLocalEndpoint
        ).selectingModel(configuration.model)
        settings = settings.updatingProvider(profile).selectingProvider(id: destination).updatingFeatures(AIFeaturePreferences(configuration: configuration, translationPreferences: settings.features.translationPreferences))
        self.aiSettings = settings
        self.llmConfiguration = configuration
        persistAISettings(settings)
    }

    public func resetLLMConfiguration() {
        let defaultConfig = LLMConfiguration.default
        updateLLMConfiguration(defaultConfig)
    }

    public func loadAPIKey() -> String { activeAPIKey() }

    public func testLLM(configuration: LLMConfiguration, apiKey: String) async throws {
        try await llm.test(configuration: configuration, apiKey: apiKey)
    }

    private var reasoningRefreshes: Set<String> = []

    /// 只请求当前供应商目录，不执行推理。并发功能卡共用一次刷新。
    public func refreshReasoningCapabilities(providerID: String, force: Bool = false) async throws {
        guard let provider = aiSettings.provider(id: providerID), !reasoningRefreshes.contains(providerID) else { return }
        let runtime = provider.runtimeConfiguration(features: aiSettings.features)
        guard runtime.reasoningCapabilities.wireProtocol == .openRouter else { return }
        if !force, provider.models.allSatisfy({ model in
            guard let metadata = model.reasoningMetadata else { return false }
            return metadata.endpoint == runtime.reasoningEndpoint && Date().timeIntervalSince(metadata.fetchedAt) < 86400
        }) { return }
        let key = apiKey(for: providerID)
        reasoningRefreshes.insert(providerID)
        defer { reasoningRefreshes.remove(providerID) }
        let fetched = try await fetchAIModels(provider: provider, apiKey: key)
        try Task.checkCancellation()
        guard aiSettings.provider(id: providerID) == provider, apiKey(for: providerID) == key else { return }
        var updated = provider
        updated.models = provider.models.map { model in
            var next = model
            next.reasoningMetadata = fetched.first(where: { $0.id == model.id })?.reasoningMetadata
            return next
        }
        if updated != provider { saveAISettings(aiSettings.updatingProvider(updated)) }
    }

    public func fetchAIModels(providerID: String) async throws -> [AIModelOption] {
        guard let provider = aiSettings.provider(id: providerID) else {
            throw LLMServiceError.invalidBaseURL
        }
        let requestedAPIKey = apiKey(for: providerID)
        // A remote catalog is only a candidate list. The settings editor must
        // explicitly confirm selected identifiers before they enter a draft,
        // and saving that draft is the only persistence boundary.
        return try await fetchAIModels(provider: provider, apiKey: requestedAPIKey)
    }

    public func fetchAIModels(provider: AIProviderProfile, apiKey: String) async throws -> [AIModelOption] {
        try provider.validateConnection(requireModel: false)
        if provider.kind != .customOpenAICompatible && apiKey.isEmpty {
            throw LLMServiceError.missingAPIKey
        }
        let configuration = provider.runtimeConfiguration(features: aiSettings.features)
        let remote = try await llm.fetchModelOptions(configuration: configuration, apiKey: apiKey)
        return provider.updatingModels(from: remote.map(\.id)).models.map { model in
            var next = model
            if let fetched = remote.first(where: { $0.id == model.id }) { next.reasoningMetadata = fetched.reasoningMetadata }
            return next
        }
    }

    public func testAIProvider(providerID: String, modelID: String? = nil) async throws {
        guard let provider = aiSettings.provider(id: providerID) else {
            throw LLMServiceError.invalidBaseURL
        }
        var configuration = provider.runtimeConfiguration(features: aiSettings.features)
        if let modelID {
            let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedModelID.isEmpty {
                configuration.model = trimmedModelID
            }
        }
        let draft = provider.replacing(selectedModelID: configuration.model).selectingModel(configuration.model)
        try await testAIProvider(provider: draft, apiKey: apiKey(for: providerID))
    }

    public func probeAIProvider(provider: AIProviderProfile, apiKey: String) async throws -> AIConnectionTestResult {
        try provider.validateConnection(requireModel: true)
        if provider.kind != .customOpenAICompatible && apiKey.isEmpty { throw LLMServiceError.missingAPIKey }
        return try await llm.probeConnection(configuration: provider.runtimeConfiguration(features: aiSettings.features), apiKey: apiKey)
    }

    public func testAIProvider(provider: AIProviderProfile, apiKey: String) async throws {
        try provider.validateConnection(requireModel: true)
        if provider.kind != .customOpenAICompatible && apiKey.isEmpty {
            throw LLMServiceError.missingAPIKey
        }
        try await testLLM(
            configuration: provider.runtimeConfiguration(features: aiSettings.features),
            apiKey: apiKey
        )
    }

    private func compatibilityProviderID(for configuration: LLMConfiguration) -> String {
        let migratedID = AISettings.migrated(from: configuration).activeProviderID
        if migratedID != AIProviderID.migratedLegacy {
            return migratedID
        }
        if let active = aiSettings.activeProvider, !active.isBuiltIn {
            return active.id
        }
        return AIProviderID.migratedLegacy
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
        var updated = readerAppearance
        updated.setFontSize(size)
        saveReaderAppearanceIfNeeded(updated)
    }

    public func setReaderLineHeight(_ value: Double) {
        var updated = readerAppearance
        updated.setLineHeight(value)
        saveReaderAppearanceIfNeeded(updated)
    }

    public func increaseArticleFontSize() { setArticleFontSize(articleFontSize + 1) }
    public func decreaseArticleFontSize() { setArticleFontSize(articleFontSize - 1) }
    public func resetArticleFontSize() { setArticleFontSize(ReaderAppearance.defaultFontSize) }

    public func setReaderThemePreset(_ preset: ReaderThemePreset) {
        var updated = readerAppearance
        updated.selectPreset(preset)
        saveReaderAppearanceIfNeeded(updated)
    }

    public func setReaderFontFamily(_ fontFamilyName: String?) {
        var updated = readerAppearance
        updated.setFontFamilyName(fontFamilyName)
        saveReaderAppearanceIfNeeded(updated)
    }

    public func setReaderBackgroundHex(_ hex: String, for mode: ReaderAppearanceMode) {
        var updated = readerAppearance
        updated.setBackgroundHex(hex, for: mode)
        saveReaderAppearanceIfNeeded(updated)
    }

    public func resetReaderAppearanceToPreset() {
        var updated = readerAppearance
        updated.resetToPreset()
        saveReaderAppearanceIfNeeded(updated)
    }

    public func resetReaderAppearanceToDefault() {
        saveReaderAppearanceIfNeeded(.default)
    }

    private func saveReaderAppearanceIfNeeded(_ updated: ReaderAppearance) {
        guard readerAppearance != updated else { return }
        readerAppearance = updated
        let preferences = UserDefaults.standard
        if let data = try? JSONEncoder().encode(updated) {
            preferences.set(data, forKey: PreferenceKey.readerAppearance)
        }
        // 保留旧键，确保尚未升级到组合偏好模型的构建仍可读取字号。
        preferences.set(updated.fontSize, forKey: PreferenceKey.articleFontSize)
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
