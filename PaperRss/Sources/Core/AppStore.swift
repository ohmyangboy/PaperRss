import Combine
import Foundation
import GRDB
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssAgentProtocol
#endif

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

/// 标题翻译的会话指纹：模型、目标语言与提示版本的组合变化时，
/// 内存译文与失败计数全部作废，避免串用旧模型的结果。
public struct TitleTranslationSession: Sendable {
    public let fingerprint: String
    public let targetLanguage: String

    public init(fingerprint: String, targetLanguage: String) {
        self.fingerprint = fingerprint
        self.targetLanguage = targetLanguage
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
    @Published public private(set) var articleRetentionPolicy: ArticleRetentionPolicy = .sixMonths
    @Published public private(set) var automaticallyFetchArticleContent = true

    /// Feed 图标仓库：行渲染经它同步查询已就绪图标，杜绝 AsyncImage 加载期闪烁。
    public let iconStore = FeedIconStore()
    public let thumbnailStore = ArticleThumbnailStore()
    private lazy var previewBackfill = ArticlePreviewBackfill(database: libraryDatabase)

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

    /// 列表标题的按需翻译调度器。视图只上报可见范围，去抖、批量、
    /// 缓存与失败退避都由它统一处理。
    public lazy var titleTranslator: FeedTitleTranslationCoordinator = makeTitleTranslator()

    /// 标题翻译当前可用的会话（功能开关、列表标题开关、模型与目标语言就绪时非空）。
    public var titleTranslationSession: TitleTranslationSession? {
        guard aiSettings.features.automaticallyTranslateTitles else { return nil }
        guard let (execution, _) = executionSnapshot(for: .titleTranslation) else { return nil }
        return TitleTranslationSession(
            fingerprint: execution.fingerprint(for: .translation, promptVersion: Self.translationPromptVersion),
            targetLanguage: execution.configuration.targetLanguage
        )
    }

    private func makeTitleTranslator() -> FeedTitleTranslationCoordinator {
        FeedTitleTranslationCoordinator(
            configurationProvider: { [weak self] in
                guard let self, let session = self.titleTranslationSession else { return nil }
                return TitleTranslationContext(
                    sessionID: session.fingerprint,
                    targetLanguage: session.targetLanguage,
                    feedLists: self.translationFeedLists
                )
            },
            translate: { [weak self] texts, context in
                guard let self else { return .empty }
                return await self.translateEntryTexts(texts, targetLanguage: context.targetLanguage)
            }
        )
    }

    /// 进程内已准备正文 LRU 缓存：命中时 Reader 可跳过 prepare 管线即时换页。
    public private(set) var preparedArticleMemoryCache = PreparedArticleMemoryCache()
    private var neighborPrefetchTask: Task<Void, Never>?
    private var sidebarCountsRefreshTask: Task<Void, Never>?
    private var sidebarCountsRefreshGeneration: UInt64 = 0

    @discardableResult
    private func beginSidebarCountsRefresh() -> UInt64 {
        sidebarCountsRefreshGeneration &+= 1
        sidebarCountsRefreshTask?.cancel()
        sidebarCountsRefreshTask = nil
        return sidebarCountsRefreshGeneration
    }

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

    @Published public private(set) var autoTranslationRevision = 0
    public var translationFeedLists: [UUID: TranslationFeedList] { (try? autoTranslationRepository.feedLists()) ?? [:] }

    public func setTranslationFeedList(_ list: TranslationFeedList?, feedID: UUID, accountID: String) throws {
        try autoTranslationRepository.setList(list, feedID: feedID, accountID: accountID)
        autoTranslationRevision += 1
    }

    private var automaticallyActivatedEntryIDs: Set<String> = []
    public let languageDetectionService = LanguageDetectionService()
    public var autoTranslationRepository: AutoTranslationRepository { .init(database: libraryDatabase) }

    public var bilingualTargetLanguage: String {
        aiSettings.resolvedConfiguration(for: .bilingualTranslation)?.targetLanguage ?? aiSettings.features.targetLanguage
    }

    public func autoTranslationPreflight(entry: Entry) -> AutoTranslationDecision? {
        if !aiSettings.features.automaticallyTranslate { return .disabled }
        guard let exempt = try? autoTranslationRepository.isExempt(entry: entry) else { return .disabled }
        if exempt { return .exempt }
        if translationFeedLists[entry.feedID] == .blacklist { return .blacklisted }
        guard let execution = executionSnapshot(for: .bilingualTranslation),
              !execution.1.isEmpty || !providerRequiresAPIKey(execution.0.providerKind) else { return .unavailable }
        return nil
    }

    public func autoTranslationDecision(entry: Entry, analysis: ArticleLanguageAnalysis) -> AutoTranslationDecision {
        if let skip = autoTranslationPreflight(entry: entry) { return skip }
        return AIAutomationPolicy.evaluate(analysis: analysis, targetLanguage: bilingualTargetLanguage,
            enabled: true, exempt: false, available: true, list: translationFeedLists[entry.feedID])
    }

    public func applyAutoTranslation(_ decision: AutoTranslationDecision, entryID: String) {
        if decision == .translate {
            if !activeBilingualEntryIDs.contains(entryID) {
                automaticallyActivatedEntryIDs.insert(entryID)
                activeBilingualEntryIDs.insert(entryID)
            }
        } else if automaticallyActivatedEntryIDs.remove(entryID) != nil {
            activeBilingualEntryIDs.remove(entryID)
            aiWorkspace.cancel(.background(entryID: entryID, kind: .bilingual))
        }
    }

    @Published public private(set) var activeBilingualEntryIDs: Set<String> = []

    public func isBilingualActive(for entryID: String) -> Bool {
        activeBilingualEntryIDs.contains(entryID)
    }

    public func toggleBilingualMode(for entryID: String) {
        if let entry = entry(id: entryID), let account = try? autoTranslationRepository.accountID(feedID: entry.feedID) {
            do {
                try autoTranslationRepository.setExempt(activeBilingualEntryIDs.contains(entryID), accountID: account, entryID: entryID)
            } catch {
                reportError(error, module: .settings)
                return
            }
        }
        automaticallyActivatedEntryIDs.remove(entryID)
        autoTranslationRevision += 1
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
    private var iCloudProviders: [String: ICloudAccountProvider] = [:]
    private var iCloudCopyReviewRoute: (id: UUID, accountID: String, provider: ICloudAccountProvider)?
    private var iCloudArchiveReviewRoute: (review: ICloudArchiveRecoveryReview, accountID: String, provider: ICloudAccountProvider)?
    private var accountRecoveryProjectionRevision = 0
    private let directFeedFetcher: @Sendable (Feed, Bool) async throws -> FeedFetchResult
    public var supportsICloudSync: Bool { ICloudSyncEngineDriver.isEntitled }
    public var iCloudAccountCreationAvailability: ICloudAccountCreationAvailability {
        if accounts.contains(where: { $0.type == AccountType.iCloud.rawValue && !$0.isArchived }) { return .alreadyExists }
        return supportsICloudSync ? .ready : .unsupportedBuild
    }
    public var canAddICloudAccount: Bool {
        iCloudAccountCreationAvailability == .ready
    }
    @Published public private(set) var iCloudPushError: String?

    public func setICloudPushRegistrationAvailable(_ available: Bool) {
        iCloudPushError = available ? nil : I18N.localized(
            "iCloud 远程更新通知暂未连接，仍可手动同步。",
            englishFallback: "Remote iCloud updates are unavailable. You can still sync manually.")
    }
    /// 每个账号的进度发布节流状态。随该账号的一轮刷新创建和结束，不跨轮残留。
    private var refreshProgressPublishers: [String: RefreshProgressPublishPolicy] = [:]
    @Published public private(set) var accountRefreshProgress: [String: AccountRefreshProgress] = [:]
    @Published public private(set) var accountSyncStates: [String: AccountSyncStateRecord] = [:]
    @Published public private(set) var reloadingFeedIDs: Set<UUID> = []

    public func isFeedReloading(_ feedID: UUID) -> Bool {
        reloadingFeedIDs.contains(feedID)
    }

    private let persistenceURL: URL
    private let shouldPersistAISettings: Bool
    private let articleFetchPreferences: UserDefaults?
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
        static let articleRetentionPolicy = "PaperRss.articleRetentionPolicy"
        static let automaticallyFetchArticleContent = "PaperRss.automaticallyFetchArticleContent"
        static let lastMaintenanceTimestamp = "PaperRss.lastMaintenanceTimestamp"
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
        feedFetcher: (@Sendable (Feed) async throws -> FeedFetchResult)? = nil,
        customFeedFetcher: (@Sendable (Feed, Bool) async throws -> FeedFetchResult)? = nil
    ) {
        let actualFetcher: @Sendable (Feed, Bool) async throws -> FeedFetchResult
        if let customFeedFetcher {
            actualFetcher = customFeedFetcher
        } else if let feedFetcher {
            actualFetcher = { feed, _ in try await feedFetcher(feed) }
        } else {
            actualFetcher = { feed, force in try await FeedService.fetch(feed, force: force) }
        }
        self.feedFetcher = { feed in try await actualFetcher(feed, false) }
        self.directFeedFetcher = actualFetcher
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
        self.articleFetchPreferences = databaseURL == nil && persistenceURL == nil ? .standard : nil
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
            customFeedFetcher: actualFetcher
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
        self.automaticallyFetchArticleContent = articleFetchPreferences?.object(forKey: PreferenceKey.automaticallyFetchArticleContent) as? Bool ?? true
        let preferences = UserDefaults.standard
        refreshInterval = FeedRefreshInterval(rawValue: preferences.string(forKey: PreferenceKey.refreshInterval) ?? "") ?? .twoHours
        refreshOnLaunch = preferences.object(forKey: PreferenceKey.refreshOnLaunch) as? Bool ?? true
        let rawTheme = preferences.string(forKey: PreferenceKey.appTheme) ?? ""
        appTheme = AppTheme(rawValue: rawTheme) ?? .system
        readerAppearance = Self.loadReaderAppearance(from: preferences)
        articleRetentionPolicy = preferences.string(forKey: PreferenceKey.articleRetentionPolicy).flatMap(ArticleRetentionPolicy.init(rawValue:)) ?? .sixMonths

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
            scheduleMissingIconProbe(delay: 2.0)
        }
    }

    deinit {
        missingIconProbeTask?.cancel()
    }

    /// 测试用初始化器（隔离测试沙箱）
    public init(
        testDatabase: AppDatabase,
        feedFetcher: (@Sendable (Feed) async throws -> FeedFetchResult)? = nil,
        customFeedFetcher: (@Sendable (Feed, Bool) async throws -> FeedFetchResult)? = nil,
        credentialStore: CredentialStore? = nil,
        pageLoader: (any ArticlePageLoading)? = nil,
        aiModelPort: (any AIModelPort)? = nil,
        articleFetchPreferences: UserDefaults? = nil
    ) {
        let actualFetcher: @Sendable (Feed, Bool) async throws -> FeedFetchResult
        if let customFeedFetcher {
            actualFetcher = customFeedFetcher
        } else if let feedFetcher {
            actualFetcher = { feed, _ in try await feedFetcher(feed) }
        } else {
            actualFetcher = { feed, force in try await FeedService.fetch(feed, force: force) }
        }
        self.feedFetcher = { feed in try await actualFetcher(feed, false) }
        self.directFeedFetcher = actualFetcher
        self.customSession = nil
        self.llm = LLMService(port: aiModelPort ?? URLSessionAIModelAdapter())
        self.preparationEngine = ArticlePreparationEngine(pageLoader: pageLoader ?? DefaultArticlePageLoader())
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.persistenceURL = tempDir.appendingPathComponent("library.json")
        self.shouldPersistAISettings = false
        self.articleFetchPreferences = articleFetchPreferences
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
            customFeedFetcher: actualFetcher
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
        articleRetentionPolicy = preferences.string(forKey: PreferenceKey.articleRetentionPolicy).flatMap(ArticleRetentionPolicy.init(rawValue:)) ?? .sixMonths
        self.automaticallyFetchArticleContent = articleFetchPreferences?.object(forKey: PreferenceKey.automaticallyFetchArticleContent) as? Bool ?? true
        aiSettings = AISettings.migrated(from: testDatabase.llmConfiguration)
        llmConfiguration = testDatabase.llmConfiguration

        if migrationSucceededOrNotNeeded {
            reloadState()
        }
    }

    // MARK: - State Reload & Querying

    // 订阅结构改变时建立分组，批次计数更新无需为每个文件夹扫描全部 Feed。
    private var sidebarFeedsByFolder: [String: [String?: [Feed]]] = [:]
    @Published public var feedsByAccount: [String: [Feed]] = [:] {
        didSet {
            sidebarFeedsByFolder = feedsByAccount.mapValues { Dictionary(grouping: $0, by: \.folder) }
        }
    }
    @Published public var foldersByAccount: [String: [String]] = [:]

    public func reloadState() {
        beginSidebarCountsRefresh()
        autoTranslationRevision += 1
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
            if account.type == AccountType.iCloud.rawValue {
                scheduleICloudProviderRegistration(account)
            }
            if let state = try? libraryDatabase.read({ db in
                try AccountSyncStateRecord.filter(Column("account_id") == account.id).fetchOne(db)
            }) {
                syncStates[account.id] = state
            }
            if let accountType = AccountType(rawValue: account.type), let variant = accountType.readerVariant {
                if account.isEnabled, let urlStr = account.endpointURL, let url = URL(string: urlStr), let username = account.username {
                    let provider = ReaderAccountProvider(
                        accountID: account.id,
                        endpointURL: url,
                        username: username,
                        variant: variant,
                        database: libraryDatabase,
                        credentialStore: credentialStore,
                        session: customSession,
                        onProgress: { [weak self] progress in
                            await self?.receiveRefreshProgress(progress, accountID: account.id)
                        }
                    )
                    Task { [syncCoordinator] in
                        await syncCoordinator.registerProviderIfNeeded(provider)
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
        let recoveryRevision = accountRecoveryProjectionRevision
        let sidebarGeneration = beginSidebarCountsRefresh()
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

        // A snapshot started before an archive commit cannot put the old
        // enabled account back into the UI or provider registration routes.
        guard recoveryRevision == accountRecoveryProjectionRevision else { return }
        accounts = fetchedAccounts
        feedsByAccount = newFeedsByAccount
        autoTranslationRevision += 1
        foldersByAccount = newFoldersByAccount
        feeds = newFeedsByAccount["local-default"] ?? []
        customFolders = newFoldersByAccount["local-default"] ?? []
        if sidebarCountsRefreshGeneration == sidebarGeneration {
            sidebarCounts = resolvedSidebarCounts ?? SidebarCounts()
        }
        entryListItems = resolvedAllItems ?? []
        todayEntryListItems = resolvedTodayItems ?? []
        unreadEntryListItems = resolvedUnreadItems ?? []
        starredEntryListItems = resolvedStarredItems ?? []
        cachedEntryLookup.removeAll(keepingCapacity: true)
        accountSyncStates = syncStates

        for account in fetchedAccounts {
            if account.type == AccountType.iCloud.rawValue {
                scheduleICloudProviderRegistration(account)
            }
            guard let accountType = AccountType(rawValue: account.type), let variant = accountType.readerVariant else { continue }
            if account.isEnabled,
               let urlStr = account.endpointURL,
               let url = URL(string: urlStr),
               let username = account.username {
                let provider = ReaderAccountProvider(
                    accountID: account.id,
                    endpointURL: url,
                    username: username,
                    variant: variant,
                    database: database,
                    credentialStore: credentialStore,
                    session: customSession,
                    onProgress: { [weak self] progress in
                        await self?.receiveRefreshProgress(progress, accountID: account.id)
                    }
                )
                Task { [syncCoordinator] in
                    await syncCoordinator.registerProviderIfNeeded(provider)
                }
            } else {
                Task { [syncCoordinator] in
                    await syncCoordinator.unregisterProvider(accountID: account.id)
                }
            }
        }

        timelineRevision &+= 1
    }

    // MARK: - Feed Icon Probing

    private var missingIconProbeTask: Task<Void, Never>?

    /// 当探测器找到订阅源真实图标时，同步更新在内存中的 Feed 模型，定向触发侧栏行与视图刷新
    @MainActor
    public func updateFeedIcon(feedIDs: [UUID], iconURL: URL) {
        guard !feedIDs.isEmpty else { return }
        let idSet = Set(feedIDs)
        feedsByAccount = feedsByAccount.mapValues { accountFeeds in
            accountFeeds.map { feed in
                if idSet.contains(feed.id) && feed.storedIconURL != iconURL {
                    var updated = feed
                    updated.storedIconURL = iconURL
                    return updated
                }
                return feed
            }
        }
        feeds = feeds.map { feed in
            if idSet.contains(feed.id) && feed.storedIconURL != iconURL {
                var updated = feed
                updated.storedIconURL = iconURL
                return updated
            }
            return feed
        }
    }

    /// 调度后台无图源真实图标探测（带防抖与延时保护，避免与主线程渲染和启动刷新争抢系统资源）
    public func scheduleMissingIconProbe(delay: TimeInterval = 1.0, force: Bool = false) {
        missingIconProbeTask?.cancel()
        let database = self.libraryDatabase
        let iconStore = self.iconStore
        missingIconProbeTask = Task { @MainActor [weak self] in
            await CancellableDelayGate().wait(delay)
            guard !Task.isCancelled, let self else { return }
            // 若当前仍处于全量/增量刷新流程中，延后重试，绝不与核心文章抓取争抢线程与网络资源
            if self.isRefreshing {
                self.scheduleMissingIconProbe(delay: 2.0, force: force)
                return
            }
            let allFeeds = self.feedsByAccount.values.flatMap { $0 }
            guard !allFeeds.isEmpty else { return }
            await FeedIconProbeService.shared.probeMissingIcons(
                for: allFeeds,
                database: database,
                iconStore: iconStore,
                force: force,
                onIconDiscovered: { [weak self] feedIDs, iconURL in
                    self?.updateFeedIcon(feedIDs: feedIDs, iconURL: iconURL)
                }
            )
        }
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
            await iCloudProviders[accountID]?.stop()
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
        sidebarFeedsByFolder[accountID]?[nil] ?? []
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
        sidebarFeedsByFolder[accountID]?[folder] ?? []
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

    /// Metadata only: no image downloads, reader preparation or read-state changes.
    public func prepareTimelinePreviews(entryIDs: [String]) async {
        var didChange = false
        for offset in stride(from: 0, to: entryIDs.count, by: 100) {
            guard !Task.isCancelled else { break }
            let ids = Array(entryIDs[offset..<min(offset + 100, entryIDs.count)])
            if let count = try? await previewBackfill.prepare(entryIDs: ids), count > 0 { didChange = true }
        }
        if didChange { timelineRevision &+= 1 }
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

    /// Feed scope changes must not run the first-page query on MainActor.
    public func fetchTimelinePageAsync(
        scope: TimelineScope,
        unreadOnly: Bool = false,
        retainingIDs: Set<String> = [],
        limit: Int = 100,
        offset: Int = 0
    ) async -> [EntryListItem] {
        (try? await localProvider.timelineQueryService.fetchListItemsAsync(
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

    public func fetchAdjacentItemAsync(
        scope: TimelineScope,
        unreadOnly: Bool = false,
        currentItemID: String,
        direction: AdjacentTimelineDirection,
        retainingIDs: Set<String> = []
    ) async -> EntryListItem? {
        try? await localProvider.timelineQueryService.fetchAdjacentItemAsync(
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
        try? directProvider(for: accountID(forFeedID: feedID)).setFeedFolder(feedID: feedID, folderName: folder)
        reloadState()
    }

    public func setFeedFolder(feedIDs: Set<UUID>, folder: String?) {
        guard !feedIDs.isEmpty else { return }
        for group in Dictionary(grouping: feedIDs, by: { accountID(forFeedID: $0) }) {
            try? directProvider(for: group.key).setFeedFolder(feedIDs: Set(group.value), folderName: folder)
        }
        reloadState()
    }

    public func addFolder(_ name: String, targetAccountID: String? = nil) {
        guard let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return }
        let accID = targetAccountID ?? defaultSubscriptionAccountID

        if accID == "local-default" || accounts.contains(where: { $0.id == accID && $0.type == AccountType.iCloud.rawValue }) {
            try? directProvider(for: accID).addFolder(name: clean)
            reloadState()
        } else {
            Task { [weak self, syncCoordinator] in
                if let provider = await syncCoordinator.provider(for: accID) {
                    _ = try? await provider.addFolder(name: clean)
                }
                await self?.reloadStateAsync()
            }
        }
    }

    public func deleteFolder(_ name: String, accountID: String = "local-default") {
        Task {
            await deleteFolderAsync(name, accountID: accountID)
        }
    }

    public func deleteFolderAsync(_ name: String, accountID: String = "local-default") async {
        if accountID == "local-default" || accounts.contains(where: { $0.id == accountID && $0.type == AccountType.iCloud.rawValue }) {
            try? await directProvider(for: accountID).deleteFolder(name: name)
            await reloadStateAsync()
        } else {
            if let provider = await syncCoordinator.provider(for: accountID) {
                try? await provider.deleteFolder(name: name)
            }
            await reloadStateAsync()
        }
    }

    public func renameFolder(from oldName: String, to newName: String, accountID: String = "local-default") {
        try? directProvider(for: accountID).renameFolder(oldName: oldName, newName: newName)
        reloadState()
    }

    public func renameFeed(_ feed: Feed, to newTitle: String) {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean != feed.title else { return }
        let accID = accountID(for: feed.id) ?? "local-default"
        if accID == "local-default" || accounts.contains(where: { $0.id == accID && $0.type == AccountType.iCloud.rawValue }) {
            do {
                try directProvider(for: accID).renameFeed(feedID: feed.id, newTitle: clean)
                reloadState()
            } catch {
                reportError(error, module: .settings)
                lastError = error.localizedDescription
            }
        } else {
            Task {
                if let provider = await syncCoordinator.provider(for: accID) {
                    do {
                        try await provider.renameFeed(feedID: feed.id, newTitle: clean)
                        await reloadStateAsync()
                    } catch {
                        reportError(error, module: .settings)
                        lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    public func renameFeedAsync(_ feed: Feed, to newTitle: String) async throws {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean != feed.title else { return }
        let accID = accountID(for: feed.id) ?? "local-default"
        if accID == "local-default" || accounts.contains(where: { $0.id == accID && $0.type == AccountType.iCloud.rawValue }) {
            try await directProvider(for: accID).renameFeed(feedID: feed.id, newTitle: clean)
            await reloadStateAsync()
        } else {
            guard let provider = await syncCoordinator.provider(for: accID) else {
                throw AgentFailure("UNSUPPORTED", "The account provider is unavailable for renaming feeds.")
            }
            try await provider.renameFeed(feedID: feed.id, newTitle: clean)
            await reloadStateAsync()
        }
    }

    @discardableResult
    public func addFeed(urlText: String, title: String? = nil, targetAccountID: String? = nil, folder: String? = nil) async -> Feed? {
        guard let url = normalizedURL(urlText) else {
            let message = I18N.localized("请输入有效的 Feed URL。")
            reportErrorMessage(message, module: .settings)
            lastError = message
            return nil
        }

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let accID = targetAccountID ?? defaultSubscriptionAccountID
        guard (try? subscriptionAccount(accID)) != nil else {
            lastError = I18N.shared.localized("目标账号不可用。", "The target account is unavailable.")
            return nil
        }

        if accID == "local-default" {
            let feed: Feed
            do {
                let localTitle = cleanTitle ?? (url.host ?? url.absoluteString)
                feed = try localProvider.addFeed(title: localTitle, feedURL: url, folder: folder)
            } catch let error as LocalAccountError {
                let message = error.errorDescription ?? error.localizedDescription
                reportError(error, module: .settings)
                lastError = message
                return nil
            } catch {
                reportError(error, module: .settings)
                lastError = error.localizedDescription
                return nil
            }

            reloadState()
            await refresh(feedIDs: [feed.id], origin: .subscriptionManagement)
            scheduleMissingIconProbe(delay: 0.5)
            return feed
        } else {
            guard let provider = await syncCoordinator.provider(for: accID) else {
                let message = I18N.localized("未找到目标账号提供者。")
                reportErrorMessage(message, module: .settings)
                lastError = message
                return nil
            }

            let addedFeed: Feed
            do {
                addedFeed = try await provider.addFeed(url: url, title: cleanTitle, folder: folder)
            } catch {
                reportError(error, module: .settings)
                lastError = error.localizedDescription
                return nil
            }

            await reloadStateAsync()
            if provider.accountType == .iCloud {
                await refresh(feedIDs: [addedFeed.id], origin: .subscriptionManagement)
            }
            scheduleMissingIconProbe(delay: 0.5)
            return addedFeed
        }
    }

    /// Await the same account provider used by subscription UI before issuing an Agent receipt.
    public func applyAgentFeedMutation(_ mutation: AgentFeedMutation, expiresAt: Date) async throws -> AgentFeedWriteResult {
        func validate() throws -> Feed? {
            try Task.checkCancellation()
            guard expiresAt > Date() else { throw AgentFailure("CONFLICT", "Plan expired before execution.") }
            return try libraryDatabase.read { db in
                guard let account = try AccountRecord.fetchOne(db, key: mutation.accountID), account.isEnabled, !account.isArchived,
                      AccountType(rawValue: account.type) != nil else {
                    throw AgentFailure("NOT_FOUND", "Enabled account not found.")
                }
                if mutation.kind == "add_feed" {
                    guard let raw = mutation.url, let url = URL(string: raw),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                        throw AgentFailure("INVALID_ARGUMENT", "Feed URL must be HTTP(S) without credentials.")
                    }
                    let duplicate = try FeedRecord.filter(Column("account_id") == mutation.accountID && Column("feed_url") == url.absoluteString && Column("is_deleted") == false).fetchOne(db)
                    guard duplicate == nil else { throw AgentFailure("CONFLICT", "Already subscribed in this account.") }
                    return nil
                }
                guard let id = mutation.feedID,
                      let record = try FeedRecord.fetchOne(db, key: id), record.accountID == mutation.accountID, !record.isDeleted,
                      let feed = try localProvider.feedRepository.fetchFeedModel(id: id, in: db) else {
                    throw AgentFailure("NOT_FOUND", "Feed not found in the allowed account.")
                }
                if [AccountType.freshRSS.rawValue, AccountType.miniflux.rawValue].contains(account.type),
                   record.externalID?.isEmpty != false {
                    throw AgentFailure("UNSUPPORTED", "This server feed has no subscription identifier; sync the account before managing it.")
                }
                return feed
            }
        }
        let feed = try validate()
        guard let provider = await syncCoordinator.provider(for: mutation.accountID) else {
            throw AgentFailure("UNSUPPORTED", "The account provider is unavailable for feed management.")
        }
        _ = try validate()
        let sync = provider.accountType == .local ? "local_only" : provider.accountType == .iCloud ? "queued" : "server_committed"
        switch mutation.kind {
        case "add_feed":
            guard let added = await addFeed(urlText: mutation.url!, title: mutation.title,
                                           targetAccountID: mutation.accountID, folder: mutation.folder) else {
                throw AgentFailure("INTERNAL_ERROR", "The account provider could not add the feed.")
            }
            return AgentFeedWriteResult(feedID: added.id.uuidString, title: added.title, sync: sync)
        case "rename_feed":
            guard let feed, let title = mutation.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.unicodeScalars.count <= 200 else { throw AgentFailure("INVALID_ARGUMENT", "A title of 1–200 characters is required.") }
            try await renameFeedAsync(feed, to: title)
            return AgentFeedWriteResult(feedID: feed.id.uuidString, title: title, sync: sync)
        case "remove_feed":
            guard let feed else { throw AgentFailure("NOT_FOUND", "Feed not found.") }
            try await provider.deleteFeed(feedID: feed.id)
            invalidatedRefreshFeedIDs.insert(feed.id)
            activeRefreshFeedTasks[feed.id]?.cancel()
            publishDeletedFeedState([feed.id])
            await reloadStateAsync()
            return AgentFeedWriteResult(feedID: feed.id.uuidString, title: feed.title, sync: sync)
        default:
            throw AgentFailure("UNSUPPORTED", "This feed operation is not supported.")
        }
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

    public func accountID(for feedID: UUID) -> String? {
        for (accID, feeds) in feedsByAccount {
            if feeds.contains(where: { $0.id == feedID }) {
                return accID
            }
        }
        return (try? libraryDatabase.read { db in
            try FeedRecord.filter(Column("id") == feedID.uuidString).fetchOne(db)?.accountID
        })
    }

    @discardableResult
    private func deleteFeedAndInvalidateRefresh(_ feedID: UUID) -> Bool {
        let accID = accountID(for: feedID) ?? "local-default"
        invalidatedRefreshFeedIDs.insert(feedID)
        activeRefreshFeedTasks[feedID]?.cancel()

        if accID == "local-default" {
            do {
                try localProvider.deleteFeed(feedID: feedID)
                let database = self.libraryDatabase
                Task.detached(priority: .utility) {
                    try? database.vacuum()
                }
                return true
            } catch {
                // 保持原有删除 API 的静默失败语义；删除未成功时不取消刷新任务。
                return false
            }
        } else {
            Task { [weak self, syncCoordinator] in
                if let provider = await syncCoordinator.provider(for: accID) {
                    try? await provider.deleteFeed(feedID: feedID)
                }
                await self?.reloadStateAsync()
            }
            return true
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
        beginSidebarCountsRefresh()
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

    public func reorderRootFeeds(orderedIDs: [UUID], accountID: String = "local-default") {
        guard Set(orderedIDs).count == orderedIDs.count else { return }
        guard accountID == "local-default" || accounts.contains(where: { $0.id == accountID && $0.type == AccountType.iCloud.rawValue }) else { return }
        if accountID == "local-default" {
            var currentFeeds = self.feeds
            let idOrder = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
            currentFeeds.sort {
                let rank1 = idOrder[$0.id, default: .max]
                let rank2 = idOrder[$1.id, default: .max]
                return rank1 < rank2
            }
            self.feeds = currentFeeds
        }
        try? libraryDatabase.write { db in
            for (idx, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE feeds SET sort_order = ? WHERE id = ? AND account_id = ?;", arguments: [idx, id.uuidString, accountID])
            }
        }
        reloadState()
    }

    public func reorderRootFeeds(fromOffsets: IndexSet, toOffset: Int, accountID: String = "local-default") {
        var currentRootIDs = rootFeeds(for: accountID).map(\.id)
        guard !fromOffsets.isEmpty, fromOffsets.allSatisfy({ currentRootIDs.indices.contains($0) }),
              (0...currentRootIDs.count).contains(toOffset) else { return }
        currentRootIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        reorderRootFeeds(orderedIDs: currentRootIDs, accountID: accountID)
    }

    public func feeds(in folder: String) -> [Feed] {
        feeds.filter { $0.folder == folder }
    }

    public func reorderFeeds(in folder: String, fromOffsets: IndexSet, toOffset: Int, accountID: String = "local-default") {
        guard accountID == "local-default" || accounts.contains(where: { $0.id == accountID && $0.type == AccountType.iCloud.rawValue }) else { return }
        var folderFeedIDs = feeds(in: folder, for: accountID).map(\.id)
        guard !fromOffsets.isEmpty, fromOffsets.allSatisfy({ folderFeedIDs.indices.contains($0) }),
              (0...folderFeedIDs.count).contains(toOffset) else { return }
        folderFeedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try? libraryDatabase.write { db in
            for (idx, id) in folderFeedIDs.enumerated() {
                try db.execute(sql: "UPDATE feeds SET sort_order = ? WHERE id = ? AND account_id = ?;", arguments: [idx, id.uuidString, accountID])
            }
        }
        reloadState()
    }

    public func reorderFolders(fromOffsets: IndexSet, toOffset: Int, accountID: String = "local-default") {
        guard accountID == "local-default" || accounts.contains(where: { $0.id == accountID && $0.type == AccountType.iCloud.rawValue }) else { return }
        var names = folders(for: accountID)
        guard !fromOffsets.isEmpty, fromOffsets.allSatisfy({ names.indices.contains($0) }),
              (0...names.count).contains(toOffset) else { return }
        names.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try? libraryDatabase.write { db in
            for (idx, name) in names.enumerated() {
                try db.execute(sql: "UPDATE folders SET sort_order = ? WHERE name = ? AND account_id = ?;", arguments: [idx, name, accountID])
            }
        }
        reloadState()
    }

    /// Organize folders inside one direct-fetch account. Cross-account additions
    /// go through copyOrMoveFeeds and never reuse source IDs or article history.
    @discardableResult
    public func moveFeeds(_ feedIDs: Set<UUID>, toFolder folder: String?, accountID: String) -> Bool {
        guard !feedIDs.isEmpty,
              let target = try? subscriptionAccount(accountID),
              AccountType(rawValue: target.type)?.fetchesRSSDirectly == true
        else { return false }
        let owned = (try? libraryDatabase.read { db in
            for id in feedIDs {
                guard let feed = try FeedRecord.fetchOne(db, key: id.uuidString),
                      feed.accountID == accountID, !feed.isDeleted else { return false }
            }
            return true
        }) ?? false
        guard owned else { return false }
        do {
            try directProvider(for: accountID).setFeedFolder(feedIDs: feedIDs, folderName: folder)
            reloadState()
            return true
        } catch {
            let message = I18N.localized("无法移动订阅，现有资料已保留。", englishFallback: "Unable to move feeds. Your existing data is retained.")
            reportErrorMessage(message, module: .settings)
            lastError = message
            return false
        }
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
        guard let account = accounts.first(where: { $0.type == AccountType.iCloud.rawValue && $0.isEnabled }) else { return }
        await syncAccount(accountID: account.id)
    }

    public func iCloudAccountSnapshot(accountID: String) async throws -> ICloudAccountSyncSnapshot {
        try await ICloudRecordRepository(database: libraryDatabase, accountID: accountID).accountSnapshot()
    }

    public func iCloudRecoveryReview(accountID: String) async throws -> ICloudRecoveryReview {
        try await ICloudRecordRepository(database: libraryDatabase, accountID: accountID).recoveryReview()
    }

    public func iCloudArchiveLocalReview(accountID: String) async throws -> ICloudArchiveReview {
        let coordinator = ICloudArchiveRecoveryCoordinator(database: libraryDatabase, accountID: accountID,
            transport: ICloudArchiveCloudKitTransport(database: libraryDatabase, accountID: accountID))
        return try await coordinator.snapshot().review
    }

    public func iCloudArchiveCatalog(accountID: String) async throws -> ICloudArchiveCatalog {
        try await ICloudArchiveReadingRepository(database: libraryDatabase, accountID: accountID).catalog()
    }

    public func iCloudArchivePage(accountID: String, query: ICloudArchiveQuery) async throws -> ICloudArchivePage {
        try await ICloudArchiveReadingRepository(database: libraryDatabase, accountID: accountID).page(query)
    }

    public func iCloudArchiveDetail(accountID: String, id: String, section: ICloudArchiveQuery.Section) async throws -> ICloudArchiveDetail {
        try await ICloudArchiveReadingRepository(database: libraryDatabase, accountID: accountID).detail(id: id, section: section)
    }

    public func prepareICloudArchiveRecovery(accountID: String, connectionConfirmed: Bool) async throws -> ICloudArchiveRecoveryReview {
        guard connectionConfirmed else { throw ICloudArchiveRecoveryError.connectionConfirmationRequired }
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await prepareICloudArchiveRecoveryAfterEntitlementCheck(accountID: accountID, connectionConfirmed: connectionConfirmed)
    }

    func prepareICloudArchiveRecoveryAfterEntitlementCheck(accountID: String, connectionConfirmed: Bool) async throws -> ICloudArchiveRecoveryReview {
        guard connectionConfirmed else { throw ICloudArchiveRecoveryError.connectionConfirmationRequired }
        guard let account = accounts.first(where: { $0.id == accountID && $0.type == AccountType.iCloud.rawValue && $0.isEnabled && !$0.isArchived }) else {
            throw ICloudArchiveRecoveryError.unavailableSource
        }
        if let previous = iCloudArchiveReviewRoute { await discardICloudArchiveRecoveryReview(id: previous.review.id) }
        let provider = iCloudProvider(for: account)
        let review = try await provider.prepareArchiveRecovery()
        if Task.isCancelled {
            await provider.discardArchiveRecoveryReview(id: review.id)
            throw CancellationError()
        }
        iCloudArchiveReviewRoute = (review, accountID, provider)
        return review
    }

    public func discardICloudArchiveRecoveryReview(id: UUID) async {
        guard let route = iCloudArchiveReviewRoute, route.review.id == id else { return }
        iCloudArchiveReviewRoute = nil
        await route.provider.discardArchiveRecoveryReview(id: id)
    }

    public func executeICloudArchiveRecovery(reviewID: UUID, archiveConfirmed: Bool,
        initializeEmptyCloudConfirmed: Bool = false) async throws -> ICloudArchiveRecoveryResult {
        guard archiveConfirmed else { throw ICloudArchiveRecoveryError.archiveConfirmationRequired }
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await executeICloudArchiveRecoveryAfterEntitlementCheck(reviewID: reviewID, archiveConfirmed: archiveConfirmed,
                                                                         initializeEmptyCloudConfirmed: initializeEmptyCloudConfirmed)
    }

    /// Tests inject the new account's sync implementation before projection or
    /// registration, so even an entitled test runner never contacts CloudKit.
    func executeICloudArchiveRecoveryAfterEntitlementCheck(reviewID: UUID, archiveConfirmed: Bool,
        initializeEmptyCloudConfirmed: Bool = false,
        newSync: (any ICloudAccountSyncing)? = nil) async throws -> ICloudArchiveRecoveryResult {
        guard archiveConfirmed else { throw ICloudArchiveRecoveryError.archiveConfirmationRequired }
        guard let route = iCloudArchiveReviewRoute, route.review.id == reviewID,
              accounts.contains(where: { $0.id == route.accountID && $0.isEnabled && !$0.isArchived }) else {
            throw ICloudArchiveRecoveryError.staleReview
        }
        guard !route.review.needsCloudInitialization || initializeEmptyCloudConfirmed else {
            throw ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired
        }
        iCloudArchiveReviewRoute = nil
        let account = try await route.provider.executeArchiveRecovery(reviewID: reviewID,
            initializeEmptyCloudConfirmed: initializeEmptyCloudConfirmed)
        // Committed: this result is retained through cancellation/network
        // failures. Install the new provider before any callback reloads it.
        accountRecoveryProjectionRevision &+= 1
        iCloudProviders.removeValue(forKey: route.accountID)
        let provider = iCloudProvider(for: account, sync: newSync)
        activeAccountID = account.id
        reloadState()
        await syncCoordinator.unregisterProvider(accountID: route.accountID)
        await route.provider.stop()
        await syncCoordinator.registerProvider(provider)
        var warning: String?
        if Task.isCancelled { warning = ICloudSyncFailure.message(for: CancellationError()) }
        else {
            do {
                let refreshed = try await provider.refresh(reason: .launch)
                if case .failed(let message) = refreshed.status { warning = message }
            }
            catch { warning = ICloudSyncFailure.message(for: error) }
        }
        reloadState()
        return .init(newAccountID: account.id, counts: route.review.counts, syncWarning: warning)
    }

    public func resumeOriginalICloudAccount(accountID: String, confirmed: Bool) async throws -> ICloudSameAccountResumeResult {
        guard confirmed else { throw ICloudSameAccountResumeError.confirmationRequired }
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await resumeOriginalICloudAccountAfterEntitlementCheck(accountID: accountID, confirmed: confirmed)
    }

    /// Isolated tests use a fake syncing implementation. The UI always enters
    /// through the entitlement-guarded public API above.
    func resumeOriginalICloudAccountAfterEntitlementCheck(accountID: String, confirmed: Bool) async throws -> ICloudSameAccountResumeResult {
        guard confirmed else { throw ICloudSameAccountResumeError.confirmationRequired }
        guard let account = accounts.first(where: { $0.id == accountID && $0.type == AccountType.iCloud.rawValue && $0.isEnabled }) else {
            throw ICloudSameAccountResumeError.unavailableScope
        }
        return try await iCloudProvider(for: account).resumeOriginalAccount()
    }

    public func iCloudMigrationPreview(sourceAccountID: String) async throws -> ICloudMigrationPreview {
        try await ICloudMigrationPreviewRepository(database: libraryDatabase).preview(sourceAccountID: sourceAccountID)
    }

    public var canPrepareICloudLocalCopy: Bool {
        supportsICloudSync && accounts.contains { $0.type == AccountType.iCloud.rawValue && $0.isEnabled }
    }

    public func iCloudCopySourceCatalog(sourceAccountID: String) async throws -> ICloudCopySourceCatalog {
        try await ICloudLocalCopyRepository(database: libraryDatabase).sourceCatalog(accountID: sourceAccountID)
    }

    public func prepareICloudLocalCopy(catalog: ICloudCopySourceCatalog, selection: ICloudCopySelection) async throws -> ICloudCopyReview {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await prepareICloudLocalCopyAfterEntitlementCheck(catalog: catalog, selection: selection)
    }

    /// Isolated integration tests inject a sync implementation that verifies its
    /// fake root/context. Production UI must use the entitlement-guarded entry.
    func prepareICloudLocalCopyAfterEntitlementCheck(catalog: ICloudCopySourceCatalog, selection: ICloudCopySelection) async throws -> ICloudCopyReview {
        guard let account = accounts.first(where: { $0.type == AccountType.iCloud.rawValue && $0.isEnabled }) else {
            throw ICloudLocalCopyError.unavailableTarget
        }
        let provider = iCloudProvider(for: account)
        let review = try await provider.prepareLocalCopy(catalog: catalog, selection: selection)
        if Task.isCancelled {
            await provider.discardLocalCopyReview(id: review.id)
            throw CancellationError()
        }
        iCloudCopyReviewRoute = (review.id, account.id, provider)
        return review
    }

    public func discardICloudLocalCopyReview(id: UUID) async {
        guard let route = iCloudCopyReviewRoute, route.id == id else { return }
        iCloudCopyReviewRoute = nil
        await route.provider.discardLocalCopyReview(id: id)
    }

    public func executeICloudLocalCopy(reviewID: UUID, privacyReviewed: Bool) async throws -> ICloudCopyResult {
        guard privacyReviewed else { throw ICloudLocalCopyError.reviewRequired }
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await executeICloudLocalCopyAfterEntitlementCheck(reviewID: reviewID, privacyReviewed: privacyReviewed)
    }

    func executeICloudLocalCopyAfterEntitlementCheck(reviewID: UUID, privacyReviewed: Bool) async throws -> ICloudCopyResult {
        guard privacyReviewed else { throw ICloudLocalCopyError.reviewRequired }
        guard let route = iCloudCopyReviewRoute, route.id == reviewID,
              accounts.contains(where: { $0.id == route.accountID && $0.type == AccountType.iCloud.rawValue && $0.isEnabled }) else {
            throw ICloudLocalCopyError.stalePlan
        }
        iCloudCopyReviewRoute = nil
        return try await route.provider.executeLocalCopy(reviewID: reviewID)
    }

    public func iCloudCloudResidueReview(accountID: String) async throws -> ICloudCloudResidueReview {
        let repository = ICloudRecordRepository(database: libraryDatabase, accountID: accountID)
        return try await ICloudCloudResidueScanner(repository: repository,
            transport: ICloudCloudResidueCloudKitTransport(repository: repository)).scan()
    }

    public func iCloudCloudInventory(accountID: String, reset: Bool) async throws -> ICloudCloudInventory {
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.type == AccountType.iCloud.rawValue, account.isEnabled else {
            throw ICloudRecordError.unavailableScope
        }
        return try await iCloudProvider(for: account).scanCloudInventory(reset: reset)
    }

    public func prepareICloudRetentionReview(accountID: String, reset: Bool = false) async throws -> ICloudRetentionReview {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await prepareICloudRetentionReviewAfterEntitlementCheck(accountID: accountID, reset: reset)
    }

    public func prepareICloudNewLibraryReview(accountID: String) async throws -> ICloudNewLibraryReview {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await retentionProvider(accountID: accountID).prepareNewLibraryReview()
    }
    public func discardICloudNewLibraryReview(accountID: String, id: UUID) async {
        await iCloudProviders[accountID]?.discardNewLibraryReview(id: id)
    }
    public func executeICloudNewLibraryReview(accountID: String, reviewID: UUID, newLibraryConfirmed: Bool,
                                             oldCloudRetentionConfirmed: Bool) async throws {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        try await retentionProvider(accountID: accountID).executeNewLibraryReview(id: reviewID,
            newLibraryConfirmed: newLibraryConfirmed, oldCloudRetentionConfirmed: oldCloudRetentionConfirmed)
    }
    func prepareICloudRetentionReviewAfterEntitlementCheck(accountID: String, reset: Bool = false) async throws -> ICloudRetentionReview {
        try await retentionProvider(accountID: accountID).prepareRetentionReview(reset: reset)
    }
    public func discardICloudRetentionReview(accountID: String, id: UUID) async {
        await iCloudProviders[accountID]?.discardRetentionReview(id: id)
    }
    public func startICloudRetention(accountID: String, reviewID: UUID, cleanupConfirmed: Bool,
                                    clockMaintenanceConfirmed: Bool) async throws {
        guard cleanupConfirmed else { throw ICloudRetentionReviewError.confirmationRequired }
        guard clockMaintenanceConfirmed else { throw ICloudRetentionReviewError.clockMaintenanceRequired }
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        try await startICloudRetentionAfterEntitlementCheck(accountID: accountID, reviewID: reviewID,
            cleanupConfirmed: cleanupConfirmed, clockMaintenanceConfirmed: clockMaintenanceConfirmed)
    }
    func startICloudRetentionAfterEntitlementCheck(accountID: String, reviewID: UUID, cleanupConfirmed: Bool,
                                                  clockMaintenanceConfirmed: Bool) async throws {
        try await retentionProvider(accountID: accountID).startReviewedRetention(id: reviewID,
            cleanupConfirmed: cleanupConfirmed, clockMaintenanceConfirmed: clockMaintenanceConfirmed)
    }
    public func iCloudRetentionProgress(accountID: String) async throws -> ICloudRetentionProgress? {
        try await retentionProvider(accountID: accountID).retentionProgress()
    }
    public func resumeICloudRetention(accountID: String, approvalID: String) async throws {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        try await retentionProvider(accountID: accountID).resumeReviewedRetention(approvalID: approvalID)
    }
    public func stopICloudRetention(accountID: String, approvalID: String) async throws {
        try await retentionProvider(accountID: accountID).stopReviewedRetention(approvalID: approvalID)
    }
    public func prepareICloudRetentionMaintenanceReview(accountID: String) async throws -> ICloudRetentionMaintenanceReview {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await retentionProvider(accountID: accountID).prepareRetentionMaintenanceReview()
    }
    public func discardICloudRetentionMaintenanceReview(accountID: String, id: UUID) async {
        await iCloudProviders[accountID]?.discardRetentionMaintenanceReview(id: id)
    }
    public func enableICloudRetentionMaintenance(accountID: String, reviewID: UUID, cleanupConfirmed: Bool,
                                                futureArticlesConfirmed: Bool, clockMaintenanceConfirmed: Bool) async throws {
        guard cleanupConfirmed, futureArticlesConfirmed, clockMaintenanceConfirmed else {
            throw ICloudRetentionMaintenanceError.confirmationRequired
        }
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        try await retentionProvider(accountID: accountID).enableReviewedRetentionMaintenance(id: reviewID,
            cleanupConfirmed: cleanupConfirmed, futureArticlesConfirmed: futureArticlesConfirmed,
            clockMaintenanceConfirmed: clockMaintenanceConfirmed)
    }
    public func iCloudRetentionMaintenanceStatus(accountID: String) async throws -> ICloudRetentionMaintenanceStatus? {
        try await retentionProvider(accountID: accountID).retentionMaintenanceStatus()
    }
    public func stopICloudRetentionMaintenance(accountID: String, approvalID: String) async throws {
        try await retentionProvider(accountID: accountID).stopRetentionMaintenance(approvalID: approvalID)
    }
    public func resumeICloudRetentionMaintenance(accountID: String) async throws {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        try await retentionProvider(accountID: accountID).resumeEnabledRetentionMaintenance()
    }
    public func reviewICloudRetentionOutcomes(accountID: String, approvalID: String) async throws -> ICloudRetentionOutcomeReviewResult {
        guard supportsICloudSync else { throw ICloudEngineError.notEntitled }
        return try await retentionProvider(accountID: accountID).reviewRetentionOutcomes(approvalID: approvalID)
    }
    private func retentionProvider(accountID: String) throws -> ICloudAccountProvider {
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.type == AccountType.iCloud.rawValue, account.isEnabled, !account.isArchived else {
            throw ICloudRecordError.unavailableScope
        }
        return iCloudProvider(for: account)
    }

    public func setICloudSyncUnreadContent(accountID: String, enabled: Bool) async throws {
        try await ICloudRecordRepository(database: libraryDatabase, accountID: accountID).setSyncUnreadContentAsync(enabled)
    }

    public func iCloudErrorMessage(_ error: any Error) -> String {
        ICloudSyncFailure.message(for: error)
    }

    private func iCloudProvider(for account: AccountRecord, sync: (any ICloudAccountSyncing)? = nil) -> ICloudAccountProvider {
        if let cached = iCloudProviders[account.id] { return cached }
        let provider = ICloudAccountProvider(
            accountID: account.id, database: libraryDatabase, customFeedFetcher: directFeedFetcher,
            sync: sync, onProgress: { [weak self] progress in
                await self?.receiveRefreshProgress(progress, accountID: account.id)
            }, onChange: { [weak self] in
                await self?.reloadStateAsync()
            }
        )
        iCloudProviders[account.id] = provider
        return provider
    }

    private func scheduleICloudProviderRegistration(_ account: AccountRecord) {
        if account.isArchived {
            let previous = iCloudProviders.removeValue(forKey: account.id)
            Task { [syncCoordinator] in
                await syncCoordinator.unregisterProvider(accountID: account.id)
                await previous?.stop()
            }
            return
        }
        let provider = iCloudProvider(for: account)
        Task { [syncCoordinator] in
            if account.isEnabled {
                await syncCoordinator.registerProvider(provider)
                await provider.startAutomaticSync()
            } else {
                await syncCoordinator.unregisterProvider(accountID: account.id)
                await provider.stop()
            }
        }
    }

    public func resumeICloudAutomaticSync(fetchRemote: Bool = true) async {
        for account in accounts where account.type == AccountType.iCloud.rawValue && account.isEnabled {
            await iCloudProvider(for: account).resumeAutomaticSync(fetchRemote: fetchRemote)
        }
    }

    /// The UI creates an empty independent account. It never copies local
    /// history implicitly. System account validation precedes persistence.
    @discardableResult
    public func addICloudAccount() async throws -> AccountRecord {
        let fingerprint = try await ICloudSyncEngineDriver.systemUserFingerprint()
        return try await createICloudAccount(fingerprint: fingerprint, waitForInitialSync: false)
    }

    /// Injectable local integration boundary used by isolated tests. Networking
    /// remains entitlement-guarded in the public account creation entry point.
    @discardableResult
    func createICloudAccount(
        fingerprint: String, sync: (any ICloudAccountSyncing)? = nil,
        waitForInitialSync: Bool = true
    ) async throws -> AccountRecord {
        let account = try await libraryDatabase.writeAsync { db in
            guard try AccountRecord.filter(Column("type") == AccountType.iCloud.rawValue && Column("is_archived") == false).fetchOne(db) == nil else {
                throw ICloudAccountError.alreadyExists
            }
            let now = Date().timeIntervalSince1970
            let record = AccountRecord(id: "icloud-\(UUID().uuidString)", type: AccountType.iCloud.rawValue,
                                      displayName: "iCloud", createdAt: now, updatedAt: now)
            try record.save(db)
            try db.execute(sql: """
                INSERT INTO icloud_sync_scope(account_id, capture_enabled, user_fingerprint) VALUES (?, 1, ?);
                """, arguments: [record.id, fingerprint])
            try ICloudRecordSchema.ensureDeviceIdentity(accountID: record.id, in: db)
            return record
        }
        let provider = iCloudProvider(for: account, sync: sync)
        await syncCoordinator.registerProvider(provider)
        activeAccountID = account.id
        await reloadStateAsync()
        if waitForInitialSync {
            _ = try await provider.refresh(reason: .launch)
            await reloadStateAsync()
        } else {
            accountRefreshProgress[account.id] = AccountRefreshProgress()
            Task { [self] in
                defer { endRefreshProgress(accountID: account.id) }
                do { _ = try await provider.refresh(reason: .launch) }
                catch {
                    reportErrorMessage(ICloudSyncFailure.message(for: error), module: .settings)
                }
                await reloadStateAsync()
            }
        }
        return account
    }

    @Published public private(set) var importingAccountIDs: Set<String> = []

    public var subscriptionAccounts: [AccountRecord] {
        accounts.filter { $0.isEnabled && !$0.isArchived && AccountType(rawValue: $0.type) != nil }
    }

    private func subscriptionAccount(_ accountID: String) throws -> AccountRecord {
        try libraryDatabase.read { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.isEnabled,
                  !account.isArchived, AccountType(rawValue: account.type) != nil else {
                throw AgentFailure("NOT_FOUND", "Enabled account not found.")
            }
            return account
        }
    }

    @discardableResult
    public func importOPML(_ data: Data, targetAccountID: String? = nil) async -> SubscriptionImportResult? {
        let accountID = targetAccountID ?? defaultSubscriptionAccountID
        guard !importingAccountIDs.contains(accountID) else {
            lastError = I18N.shared.localized("该账号正在导入订阅，请稍后再试。", "This account is importing subscriptions. Try again shortly.")
            return nil
        }
        importingAccountIDs.insert(accountID)
        defer { importingAccountIDs.remove(accountID) }
        do {
            let account = try subscriptionAccount(accountID)
            let document = try OPMLService.parse(data: data)
            let uniqueCount = Set(document.subscriptions.map(\.feedURL)).count
            if AccountType(rawValue: account.type)?.fetchesRSSDirectly == true {
                let newFeedIDs = try await directProvider(for: accountID).importOPMLAsync(data)
                await reloadStateAsync()
                if !newFeedIDs.isEmpty { await refresh(feedIDs: newFeedIDs, origin: .subscriptionManagement) }
                return SubscriptionImportResult(addedCount: newFeedIDs.count, skippedCount: uniqueCount - newFeedIDs.count)
            }
            guard let provider = await syncCoordinator.provider(for: accountID) else {
                throw AgentFailure("UNSUPPORTED", "The account provider is unavailable.")
            }
            var result = SubscriptionImportResult()
            var seen = Set<URL>()
            for subscription in document.subscriptions where seen.insert(subscription.feedURL).inserted {
                do {
                    try Task.checkCancellation()
                    _ = try subscriptionAccount(accountID)
                    let exists = try libraryDatabase.read { db in
                        try localProvider.feedRepository.fetchFeedByURL(accountID: accountID,
                            feedURL: subscription.feedURL.absoluteString, includeDeleted: false, in: db) != nil
                    }
                    if exists { result.skippedCount += 1; continue }
                    _ = try await provider.addFeed(url: subscription.feedURL, title: subscription.title, folder: subscription.folder)
                    result.addedCount += 1
                } catch {
                    result.failedTitles.append(subscription.title ?? subscription.feedURL.host ?? I18N.localized("订阅源"))
                }
            }
            await reloadStateAsync()
            scheduleMissingIconProbe(delay: 0.5)
            return result
        } catch {
            let message = error is OPMLImportError
                ? I18N.localized("无法读取 OPML 文件，请检查文件格式。", englishFallback: "Unable to read the OPML file. Check its format.")
                : I18N.shared.localized("无法导入到目标账号，请检查账号是否启用且连接正常。", "Could not import into this account. Check that it is enabled and connected.")
            reportErrorMessage(message, module: .settings)
            lastError = message
            return nil
        }
    }

    /// Resolve IDs from our database; external text never supplies URLs or account ownership.
    public func canDropFeeds(_ feedIDs: Set<UUID>, targetAccountID: String) -> Bool {
        guard !feedIDs.isEmpty, !importingAccountIDs.contains(targetAccountID),
              let account = try? subscriptionAccount(targetAccountID) else { return false }
        return (try? libraryDatabase.read { db in
            var crossesAccounts = false
            for id in feedIDs {
                guard let feed = try FeedRecord.fetchOne(db, key: id.uuidString), !feed.isDeleted,
                      let source = try AccountRecord.fetchOne(db, key: feed.accountID),
                      source.isEnabled, !source.isArchived else { return false }
                crossesAccounts = crossesAccounts || feed.accountID != targetAccountID
            }
            return crossesAccounts || AccountType(rawValue: account.type)?.fetchesRSSDirectly == true
        }) ?? false
    }

    @discardableResult
    public func acceptFeedDrop(_ feedIDs: Set<UUID>, toFolder folder: String?, accountID: String) -> Bool {
        guard canDropFeeds(feedIDs, targetAccountID: accountID) else { return false }
        Task {
            if let result = await copyOrMoveFeeds(feedIDs, toFolder: folder, accountID: accountID) {
                emitTransientNotice(result.summary)
            }
        }
        return true
    }

    /// Same-account drops organize folders. Cross-account drops add subscriptions only,
    /// preserving all source articles/state and leaving existing target subscriptions intact.
    @discardableResult
    public func copyOrMoveFeeds(_ feedIDs: Set<UUID>, toFolder folder: String?, accountID: String) async -> SubscriptionImportResult? {
        guard canDropFeeds(feedIDs, targetAccountID: accountID) else { return nil }
        do {
            let (same, copies, duplicates): (Set<UUID>, [Feed], Int) = try libraryDatabase.read { db in
                var same = Set<UUID>(), copies: [Feed] = [], duplicates = 0
                var urls = Set<String>()
                for id in feedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    guard let record = try FeedRecord.fetchOne(db, key: id.uuidString), !record.isDeleted,
                          var feed = try localProvider.feedRepository.fetchFeedModel(id: id.uuidString, in: db) else {
                        throw LocalAccountError.feedNotFound
                    }
                    if record.accountID == accountID { same.insert(id); continue }
                    guard urls.insert(record.feedURL).inserted,
                          try localProvider.feedRepository.fetchFeedByURL(accountID: accountID, feedURL: record.feedURL, includeDeleted: false, in: db) == nil else {
                        duplicates += 1
                        continue
                    }
                    feed.folder = folder
                    copies.append(feed)
                }
                return (same, copies, duplicates)
            }
            var moved = 0
            var skipped = duplicates
            if !same.isEmpty {
                let target = try subscriptionAccount(accountID)
                if AccountType(rawValue: target.type)?.fetchesRSSDirectly == true {
                    guard moveFeeds(same, toFolder: folder, accountID: accountID) else { return nil }
                    moved = same.count
                } else {
                    skipped += same.count
                }
            }
            guard !copies.isEmpty else {
                return SubscriptionImportResult(movedCount: moved, skippedCount: skipped)
            }
            var result = await importOPML(OPMLService.export(feeds: copies), targetAccountID: accountID)
            result?.movedCount = moved
            result?.skippedCount += skipped
            return result
        } catch {
            lastError = I18N.shared.localized("无法添加这些订阅，来源账号的内容已保留。", "Could not add these feeds. The source account is unchanged.")
            reportErrorMessage(lastError ?? "", module: .settings)
            return nil
        }
    }

    public func exportOPML(accountID: String? = nil) -> Data {
        let target = accountID ?? defaultSubscriptionAccountID
        return (try? libraryDatabase.read {
            try localProvider.exportOPML(accountID: target, in: $0)
        }) ?? OPMLService.export(feeds: [])
    }

    private var defaultSubscriptionAccountID: String {
        if isAccountEnabled(activeAccountID) { return activeAccountID }
        return isAccountEnabled("local-default") ? "local-default" : enabledAccounts.first?.id ?? "local-default"
    }

    private func directProvider(for accountID: String) -> LocalAccountProvider {
        if let account = accounts.first(where: { $0.id == accountID && $0.type == AccountType.iCloud.rawValue }) {
            return iCloudProvider(for: account).local
        }
        return accountID == localProvider.accountID ? localProvider
            : LocalAccountProvider(accountID: accountID, database: libraryDatabase, customFeedFetcher: directFeedFetcher)
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

        // 本轮远端账号排队即显示等待；不覆盖已经运行的独立账号同步。
        let queuedAccountIDs = feedIDs == nil ? accounts.filter {
            $0.id != "local-default" && $0.isEnabled && accountRefreshProgress[$0.id] == nil
        }.map(\.id) : []
        for accountID in queuedAccountIDs {
            accountRefreshProgress[accountID] = AccountRefreshProgress()
        }
        defer {
            for accountID in queuedAccountIDs {
                endRefreshProgress(accountID: accountID)
            }
        }

        var failures: [String] = []
        var updatedFeeds = 0
        var newUnreadEntries: [Entry] = []
        var shouldReloadLocalSnapshot = false

        // 1. 本地源抓取（指定局部源或全局本地源）
        var targetFeeds: [Feed]
        if let feedIDs {
            targetFeeds = feeds.filter { feedIDs.contains($0.id) && !$0.isDeleted }
        } else if isAccountEnabled("local-default") {
            targetFeeds = feeds.filter { !$0.isDeleted }
        } else {
            targetFeeds = []
        }
        var seenLocalFeedIDs = Set<UUID>()
        targetFeeds = targetFeeds.filter { seenLocalFeedIDs.insert($0.id).inserted }

        var completedLocalFeeds = 0
        if !targetFeeds.isEmpty {
            accountRefreshProgress["local-default"] = AccountRefreshProgress(completed: 0, total: targetFeeds.count)
        }
        defer { endRefreshProgress(accountID: "local-default") }
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

                completedLocalFeeds += 1
                await receiveRefreshProgress(AccountRefreshProgress(completed: completedLocalFeeds, total: targetFeeds.count), accountID: "local-default")

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

        endRefreshProgress(accountID: "local-default")

        if let feedIDs {
            let selected = Set(feedIDs)
            for account in accounts where account.isEnabled && account.type == AccountType.iCloud.rawValue {
                let targets = Set(feeds(for: account.id).filter { selected.contains($0.id) }.map(\.id))
                guard !targets.isEmpty else { continue }
                do {
                    let result = try await iCloudProvider(for: account).refresh(feedIDs: targets, reason: .manual)
                    if case .failed(let message) = result.status { failures.append(message) }
                } catch { failures.append(ICloudSyncFailure.message(for: error)) }
                shouldReloadLocalSnapshot = true
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

    /// 强制重新拉取指定 Feed 的全部内容并回填恢复正文
    public func reloadFeed(feedID: UUID) async {
        guard !isRefreshing && !reloadingFeedIDs.contains(feedID) else { return }
        isRefreshing = true
        reloadingFeedIDs.insert(feedID)
        refreshStatus = .refreshing
        let accID = accountID(for: feedID) ?? "local-default"
        accountRefreshProgress[accID] = AccountRefreshProgress(completed: 0, total: 1)
        defer {
            reloadingFeedIDs.remove(feedID)
            endRefreshProgress(accountID: accID)
            isRefreshing = false
        }

        do {
            if accID == "local-default" {
                let outcome = try await localProvider.refreshFeed(id: feedID, force: true)
                await reloadStateAsync()
                refreshStatus = .completed(updatedFeeds: outcome.updated ? 1 : 0, finishedAt: Date.now)
            } else {
                if let provider = await syncCoordinator.provider(for: accID) {
                    let result = try await provider.refresh(reason: .manual)
                    if case let .failed(msg) = result.status {
                        throw NSError(domain: "PaperRss", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
                    }
                }
                await reloadStateAsync()
                refreshStatus = .completed(updatedFeeds: 1, finishedAt: Date.now)
            }
        } catch {
            let message = error.localizedDescription
            refreshStatus = .failed(message: message, finishedAt: Date.now)
            reportErrorMessage(message, module: .refresh)
            lastError = message
            await reloadStateAsync()
        }
    }

    // MARK: - State Management

    private func updateLocalEntryState(
        entryID: String,
        isRead: Bool? = nil,
        isStarred: Bool? = nil,
        refreshSidebarCountsSynchronously: Bool = true
    ) {
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

        let generation = beginSidebarCountsRefresh()
        if refreshSidebarCountsSynchronously {
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            sidebarCounts = (try? localProvider.timelineQueryService.fetchSidebarCounts(
                startOfDayTimestamp: startOfDay
            )) ?? sidebarCounts
        } else {
            sidebarCountsRefreshTask = Task { @MainActor [weak self] in
                // A burst of selections only needs the final count snapshot.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                let counts = try? await self.localProvider.timelineQueryService.fetchSidebarCountsAsync(
                    startOfDayTimestamp: startOfDay
                )
                guard !Task.isCancelled,
                      self.sidebarCountsRefreshGeneration == generation,
                      let counts else { return }
                self.sidebarCounts = counts
                self.sidebarCountsRefreshTask = nil
            }
        }

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

    /// Reader selection already patches its visible row. Keep the tiny SQLite write
    /// synchronous, then aggregate sidebar counts on a reader queue so a large
    /// library cannot hold the next selection frame on the main actor.
    public func markReadFromReader(_ entry: Entry) {
        guard (try? localProvider.markRead(entryID: entry.id, read: true)) != nil else { return }
        updateLocalEntryState(
            entryID: entry.id,
            isRead: true,
            refreshSidebarCountsSynchronously: false
        )
        Task { [weak self] in
            await self?.syncCoordinator.pushAllPendingArticleStates()
        }
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

    /// Agent writes share the UI repository/outbox path, but propagate failures to the receipt.
    /// Validation and mutations stay in one transaction; iCloud capture observes this commit.
    public func applyAgentStateChange(accountID: String, articleIDs: [String],
                                      field: AgentStateField, value: Bool, expiresAt: Date) throws -> AgentWriteResult {
        let result = try libraryDatabase.write { db -> AgentWriteResult in
            try Task.checkCancellation()
            guard expiresAt > Date() else { throw AgentFailure("CONFLICT", "Plan expired before execution.") }
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.isEnabled,
                  !account.isArchived, AccountType(rawValue: account.type) != nil else {
                throw AgentFailure("NOT_FOUND", "Enabled account not found.")
            }
            for id in articleIDs {
                guard let item = try localProvider.articleRepository.fetchItem(id: id, in: db),
                      item.accountID == accountID,
                      let feed = try localProvider.feedRepository.fetchFeed(id: item.feedID, in: db),
                      feed.accountID == accountID, !feed.isDeleted else {
                    throw AgentFailure("NOT_FOUND", "Article not found in the approved account.")
                }
            }
            var applied = 0
            for id in articleIDs {
                guard let state = try localProvider.stateRepository.fetchState(itemID: id, in: db) else {
                    throw AgentFailure("CONFLICT", "Article state missing.")
                }
                if (field == .read ? state.isRead : state.isStarred) == value { continue }
                applied += 1
                switch field {
                case .read: try localProvider.stateRepository.markRead(itemID: id, isRead: value, in: db)
                case .starred: try localProvider.stateRepository.markStarred(itemID: id, isStarred: value, in: db)
                }
            }
            return AgentWriteResult(appliedCount: applied, skippedCount: articleIDs.count - applied,
                sync: account.type == AccountType.local.rawValue ? "local_only" : "queued_for_sync")
        }
        reloadState()
        Task { [weak self] in await self?.syncCoordinator.pushAllPendingArticleStates() }
        return result
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

    // MARK: - Remote Reader Account Management

    @discardableResult
    public func addFreshRSSAccount(
        endpointURLText: String,
        username: String,
        password: String,
        displayName: String? = nil,
        customSession: URLSession = .shared,
        waitForInitialSync: Bool = true
    ) async throws -> AccountRecord {
        try await addReaderAccount(
            accountType: .freshRSS,
            endpointURLText: endpointURLText,
            username: username,
            password: password,
            displayName: displayName,
            customSession: customSession,
            waitForInitialSync: waitForInitialSync
        )
    }

    /// 添加 Google Reader API 兼容的远端账号（FreshRSS / Miniflux）。
    @discardableResult
    public func addReaderAccount(
        accountType: AccountType,
        endpointURLText: String,
        username: String,
        password: String,
        displayName: String? = nil,
        customSession: URLSession = .shared,
        waitForInitialSync: Bool = true
    ) async throws -> AccountRecord {
        guard let variant = accountType.readerVariant else {
            throw ReaderAPIError.invalidEndpointURL(endpointURLText)
        }
        guard let rawURL = URL(string: endpointURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ReaderAPIError.invalidEndpointURL(endpointURLText)
        }

        let canonicalURL = try ReaderServiceVariant.validatedBaseURL(for: rawURL, variant: variant)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw ReaderAPIError.invalidCredentials
        }
        guard !password.isEmpty else {
            throw ReaderAPIError.invalidCredentials
        }

        // 1. 原子检查是否存在相同服务、规范化端点与用户名的启用账号
        let accountTypeRaw = accountType.rawValue
        let isDuplicate = try libraryDatabase.read { db in
            let accounts = try AccountRecord
                .filter(Column("type") == accountTypeRaw && Column("is_enabled") == true)
                .fetchAll(db)
            return accounts.contains { acc in
                guard let ep = acc.endpointURL, let un = acc.username else { return false }
                let canonicalExisting = (URL(string: ep).map { ReaderAPIClient.canonicalBaseURL(for: $0, variant: variant).absoluteString }) ?? ep
                return canonicalExisting == canonicalURL.absoluteString && un == trimmedUsername
            }
        }
        if isDuplicate {
            throw ReaderAPIError.accountAlreadyExists("\(trimmedUsername) @ \(canonicalURL.host ?? "")")
        }

        let tempAccountID = "\(accountTypeRaw)-\(UUID().uuidString)"
        let tempCredentialStore = InMemoryCredentialStore(initialCredentials: [tempAccountID: password], scope: variant.credentialScope)
        let validatorClient = ReaderAPIClient(
            endpointURL: canonicalURL,
            username: trimmedUsername,
            accountID: tempAccountID,
            credentialStore: tempCredentialStore,
            session: customSession,
            variant: variant
        )

        // 2. 验证登录凭据
        try await validatorClient.validateCredentials()

        // 3. 插入数据库
        let accountID = "\(accountTypeRaw)-\(UUID().uuidString)"
        let now = Date().timeIntervalSince1970
        let accountTitle: String
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accountTitle = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            accountTitle = rawURL.host ?? variant.serviceDisplayName
        }

        let accountRecord = AccountRecord(
            id: accountID,
            type: accountTypeRaw,
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
            try credentialStore.savePassword(password, for: variant.credentialScope, accountID: accountID)
        } catch {
            // 如果 Keychain 写入失败，清理数据库账号记录
            try? await accountRepository.deleteAccount(id: accountID)
            throw error
        }

        // 5. 注册 Provider 到 SyncCoordinator
        let provider = ReaderAccountProvider(
            accountID: accountID,
            endpointURL: canonicalURL,
            username: trimmedUsername,
            variant: variant,
            database: libraryDatabase,
            credentialStore: credentialStore,
            session: customSession,
            onProgress: { [weak self] progress in
                await self?.receiveRefreshProgress(progress, accountID: accountID)
            }
        )
        await syncCoordinator.registerProvider(provider)

        // 账号持久化成功即可关闭添加界面；首次同步由 Store 持有，不依赖弹窗生命周期。
        if waitForInitialSync {
            defer {
                reloadState()
                scheduleMissingIconProbe(delay: 0.5)
            }
            _ = try await provider.refresh(reason: .manual)
        } else {
            reloadState()
            accountRefreshProgress[accountID] = AccountRefreshProgress()
            Task { [self] in
                defer {
                    endRefreshProgress(accountID: accountID)
                    reloadState()
                    scheduleMissingIconProbe(delay: 0.5)
                }
                do {
                    _ = try await provider.refresh(reason: .manual)
                } catch {
                    reportError(error, module: .settings)
                    lastError = error.localizedDescription
                }
            }
        }

        return accountRecord
    }

    /// 批次落库后仅更新侧边栏投影，不在同步中重新注册 Provider。
    private func receiveRefreshProgress(_ progress: AccountRefreshProgress?, accountID: String) async {
        // 快速连续完成的 Feed／批次合并发布，避免全局 ObservableObject 高频重绘。
        guard let progress else {
            // 一轮结束：清掉节流状态，下一轮从零重新计数。
            refreshProgressPublishers.removeValue(forKey: accountID)
            await publishRefreshProgress(nil, accountID: accountID)
            return
        }
        var publisher = refreshProgressPublishers[accountID] ?? RefreshProgressPublishPolicy()
        guard publisher.shouldPublish(progress, at: Date()) else { return }
        refreshProgressPublishers[accountID] = publisher
        await publishRefreshProgress(progress, accountID: accountID)
    }

    /// 真正落地一次进度发布：刷新侧边栏投影并更新全局进度。
    private func publishRefreshProgress(_ progress: AccountRefreshProgress?, accountID: String) async {
        let sidebarGeneration = beginSidebarCountsRefresh()
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        if progress?.completed == 0 {
            let repository = localProvider.feedRepository
            if let snapshot = try? await libraryDatabase.readAsync({ db in
                let account = try AccountRecord.filter(Column("id") == accountID).fetchOne(db)
                let feeds = try repository.fetchAllFeedModels(accountID: accountID, in: db)
                let folders = try repository.fetchAllFolders(accountID: accountID, in: db)
                return (account, feeds, folders.map(\.name))
            }) {
                if let account = snapshot.0, !accounts.contains(where: { $0.id == accountID }) {
                    accounts.append(account)
                }
                feedsByAccount[accountID] = snapshot.1
                foldersByAccount[accountID] = snapshot.2
            }
        }
        if let counts = try? await localProvider.timelineQueryService.fetchSidebarCountsAsync(startOfDayTimestamp: startOfDay),
           sidebarCountsRefreshGeneration == sidebarGeneration {
            sidebarCounts = counts
        }
        if progress == nil,
           let state = try? await libraryDatabase.readAsync({ db in
               try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)
           }) {
            accountSyncStates[accountID] = state
        }
        // 查询结束后在同一主线程事务发布，避免进度先触发一次重绘、计数再触发一次。
        accountRefreshProgress[accountID] = progress
        timelineRevision &+= 1
    }

    /// 一轮刷新的终止点：清掉节流状态并撤下进度，下一轮从 0 重新计数。
    /// 节流状态属于这一轮，不能留在账号上跨轮复用。
    private func endRefreshProgress(accountID: String) {
        refreshProgressPublishers.removeValue(forKey: accountID)
        accountRefreshProgress.removeValue(forKey: accountID)
    }

    public func removeAccount(accountID: String) async throws {
        guard accountID != "local-default" else {
            throw LocalAccountError.feedNotFound
        }

        let accountType = try await accountRepository.fetchAccount(id: accountID).flatMap { AccountType(rawValue: $0.type) }
        try await accountRepository.validateAccountRemoval(id: accountID)
        await syncCoordinator.unregisterProvider(accountID: accountID)
        if let provider = iCloudProviders.removeValue(forKey: accountID) { await provider.stop() }
        if let scope = accountType?.readerVariant?.credentialScope {
            try? credentialStore.deleteCredentials(for: scope, accountID: accountID)
        } else if accountType != .iCloud {
            try? credentialStore.deleteFreshRSSCredentials(accountID: accountID)
        }
        try await accountRepository.deleteAccount(id: accountID)
        reloadState()
    }

    public func syncAccount(accountID: String) async {
        defer {
            endRefreshProgress(accountID: accountID)
            reloadState()
        }
        do {
            _ = try await syncCoordinator.refreshAccount(accountID: accountID, reason: .manual)
            reloadState()
        } catch {
            if accounts.first(where: { $0.id == accountID })?.type == AccountType.iCloud.rawValue {
                let message = ICloudSyncFailure.message(for: error)
                reportErrorMessage(message, module: .settings)
                lastError = message
            } else {
                reportError(error, module: .settings)
                lastError = error.localizedDescription
            }
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
        await prepareArticleResult(for: entry, policy: policy).prepared
    }

    /// 先准备当前已有内容。此入口不等待网页，也不会通知阅读器重载自身。
    public func prepareInitialArticle(for entry: Entry) async -> ArticlePreparationResult {
        await prepareArticleResult(for: entry, policy: .initialDisplay)
    }

    /// 在本地首帧之后升级全文。完成只更新缓存，当前阅读器是否换页由用户决定。
    public func refreshArticleInBackground(for entry: Entry) async -> PreparedArticle? {
        guard automaticallyFetchArticleContent, !Task.isCancelled else { return nil }
        let result = await prepareArticleResult(
            for: entry, policy: .foregroundRefresh, usesMemoryCache: false
        )
        guard !Task.isCancelled, automaticallyFetchArticleContent,
              result.cacheState == .current, !result.isProvisionalLocal else { return nil }
        // Another consumer may have completed the same article after this
        // reader displayed its preview. A complete current disk cache is also
        // a ready offer, even when this call required no fetch or cache write.
        let isCompleteCachedContent = result.prepared.source == .cache
        let didUpgradeContent = result.updatedCache != nil &&
            (result.prepared.source == .web || result.didRefreshCache)
        guard isCompleteCachedContent || didUpgradeContent else { return nil }
        return result.prepared
    }

    private func prepareArticleResult(
        for entry: Entry,
        policy: ArticlePreparationPolicy,
        usesMemoryCache: Bool = true
    ) async -> ArticlePreparationResult {
        let allowsAutomaticFetch = automaticallyFetchArticleContent
        let effectivePolicy: ArticlePreparationPolicy = allowsAutomaticFetch ? policy : .storedContent
        let fingerprint = PreparedArticleMemoryCache.contentFingerprint(for: entry)
        if usesMemoryCache,
           let memoized = preparedArticleMemoryCache.article(for: entry.id, contentFingerprint: fingerprint) {
            return ArticlePreparationResult(prepared: memoized, updatedCache: nil, cacheState: .current)
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
            policy: effectivePolicy,
            feedLanguageHints: (try? autoTranslationRepository.languageHints(entry: entry)) ?? []
        )
        // A cancelled selection does not need a reader document, even if the
        // engine produced local fallback content while cancelling its request.
        guard !Task.isCancelled else {
            return ArticlePreparationResult(
                prepared: result.prepared, updatedCache: nil,
                cacheState: .staleFallback, isProvisionalLocal: true
            )
        }
        // 设置切换期间的旧请求不得写回或展示其结果；按最新策略重新准备。
        if allowsAutomaticFetch != automaticallyFetchArticleContent {
            return await prepareArticleResult(
                for: entry, policy: policy, usesMemoryCache: usesMemoryCache
            )
        }
        let prepared = await Task.detached(priority: .userInitiated) {
            result.prepared.preparedForReader(title: entry.title)
        }.value
        if allowsAutomaticFetch != automaticallyFetchArticleContent {
            return await prepareArticleResult(
                for: entry, policy: policy, usesMemoryCache: usesMemoryCache
            )
        }
        // Settings changes, a manual refetch, or an invalidation during CPU work
        // must not write an older article back to either cache.
        guard !Task.isCancelled,
              allowsAutomaticFetch == automaticallyFetchArticleContent,
              generationAtStart == preparedArticleMemoryCache.generation else {
            return ArticlePreparationResult(
                prepared: prepared, updatedCache: nil, cacheState: .staleFallback,
                isProvisionalLocal: true,
                needsBackgroundRefresh: result.needsBackgroundRefresh && automaticallyFetchArticleContent
            )
        }
        var permitsMemoryCaching = true
        if let updatedCache = result.updatedCache, !Task.isCancelled {
            do {
                try localProvider.saveCache(updatedCache)
                if result.didRefreshCache {
                    preparedArticleMemoryCache.invalidate(entryID: entry.id)
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
           !result.needsBackgroundRefresh {
            preparedArticleMemoryCache.store(prepared, entryID: entry.id, contentFingerprint: fingerprint)
        }
        return ArticlePreparationResult(
            prepared: prepared,
            updatedCache: result.updatedCache,
            cacheState: result.cacheState,
            didRefreshCache: result.didRefreshCache,
            isProvisionalLocal: result.isProvisionalLocal,
            needsBackgroundRefresh: result.needsBackgroundRefresh
        )
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
        retainingIDs: Set<String>,
        loadedNextID: String? = nil,
        loadedPreviousID: String? = nil
    ) {
        neighborPrefetchTask?.cancel()
        neighborPrefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let directions: [AdjacentTimelineDirection] = [.next, .previous]
            for direction in directions {
                guard !Task.isCancelled else { return }
                let loadedID: String?
                switch direction {
                case .next: loadedID = loadedNextID
                case .previous: loadedID = loadedPreviousID
                }
                let neighborID: String?
                if let loadedID {
                    neighborID = loadedID
                } else {
                    neighborID = await self.fetchAdjacentItemAsync(
                        scope: scope,
                        unreadOnly: unreadOnly,
                        currentItemID: currentItemID,
                        direction: direction,
                        retainingIDs: retainingIDs
                    )?.id
                }
                guard !Task.isCancelled,
                      let neighborID,
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

    /// 当前本地 SQLite 数据库物理磁盘占用与文章/缓存统计。
    /// 缺省计算当前历史文章保留期限下的超期可清理数据量。
    public func storageStats(cutoffDate: Date? = nil) throws -> LibraryDatabase.StorageStats {
        let cutoff = cutoffDate ?? articleRetentionPolicy.cutoffDate()
        return try localProvider.storageStats(cutoffDate: cutoff)
    }

    /// 一键深度清理历史已读文章、网页正文提取缓存与内存缓存，并回收 SQLite 磁盘空间。
    ///
    /// 遵循安全铁律：未读文章与星标文章绝对保留。
    /// 遵循墓碑机制：仅删除正文与缓存，保留轻量条目身份与已读状态，防止幽灵复活。
    /// 返回淘汰的文章篇数与物理释放的磁盘字节数。
    @discardableResult
    public func deepCleanStorage() async throws -> (prunedArticles: Int, freedBytes: Int64) {
        let provider = localProvider
        let database = libraryDatabase
        let policy = articleRetentionPolicy

        let beforeStats = try storageStats()
        preparedArticleMemoryCache.removeAll()

        let pruned = try await Task.detached(priority: .userInitiated) { () -> Int in
            var count = 0
            if let cutoff = policy.cutoffDate() {
                count = try provider.purgeOldReadArticles(cutoffDate: cutoff, maxDuration: 5.0)
                let tombstoneDays = max(180, (policy.days ?? 180) * 2)
                let tombstoneCutoff = Calendar.current.date(
                    byAdding: .day,
                    value: -tombstoneDays,
                    to: Date()
                ) ?? cutoff
                _ = try? provider.purgeExpiredTombstones(cutoffDate: tombstoneCutoff, maxDuration: 5.0)
            }
            try database.vacuum()
            return count
        }.value

        let afterStats = try storageStats()
        let freedBytes = max(0, beforeStats.totalDiskBytes - afterStats.totalDiskBytes)

        await reloadStateAsync()
        return (pruned, freedBytes)
    }

    private var isPerformingMaintenance = false

    /// 后台空闲或退到后台时的静默维护任务。
    ///
    /// 遵循策略低频节流（默认距上次维护超过 24 小时执行一次），分批渐进清理过期已读文章，
    /// 若清理数量达到阈值则触发 vacuum 回收物理空间。
    public func performBackgroundMaintenance(force: Bool = false) async {
        guard !isPerformingMaintenance else { return }
        isPerformingMaintenance = true
        defer { isPerformingMaintenance = false }

        let now = Date().timeIntervalSince1970
        let lastMaintenance = UserDefaults.standard.double(forKey: PreferenceKey.lastMaintenanceTimestamp)
        if !force && lastMaintenance > 0 && (now - lastMaintenance) < 86400 {
            return
        }

        let policy = articleRetentionPolicy
        guard let days = policy.days, let cutoff = policy.cutoffDate() else {
            return
        }

        let provider = localProvider
        let database = libraryDatabase

        let (pruned, _) = await Task.detached(priority: .utility) { () -> (Int, Int) in
            let count = (try? provider.purgeOldReadArticles(cutoffDate: cutoff, maxDuration: 2.0)) ?? 0
            let tombstoneCutoff = Calendar.current.date(
                byAdding: .day,
                value: -max(180, days * 2),
                to: Date()
            ) ?? cutoff
            let tombstones = (try? provider.purgeExpiredTombstones(cutoffDate: tombstoneCutoff, maxDuration: 2.0)) ?? 0
            if count > 200 {
                try? database.vacuum()
            }
            return (count, tombstones)
        }.value

        UserDefaults.standard.set(now, forKey: PreferenceKey.lastMaintenanceTimestamp)

        if pruned > 0 {
            await reloadStateAsync()
        }
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
           feature != .bilingualTranslation && feature != .titleTranslation && feature != .selectionTranslation {
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

        // 展示结构升级可能复用段落 ID；原文也匹配才算命中，过期片段不能计入完成状态。
        let currentParagraphs = Dictionary(uniqueKeysWithValues: paragraphs.map { ($0.id, $0.original) })
        artifact.segments.removeAll { segment in
            guard let original = currentParagraphs[segment.id] else { return true }
            return !original.isSameReaderParagraph(as: segment.original)
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
                let alignedTM = tmTranslation.aligningNewlines(withOriginal: paragraph.original)
                let seg = BilingualSegment(id: paragraph.id, original: paragraph.original, translation: alignedTM)
                newResolvedSegments.append(seg)
                if let onDelta {
                    await onDelta(paragraph.id, alignedTM)
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
                        let aligned = translation.aligningNewlines(withOriginal: paragraph.original)
                        return (paragraphsBySource[paragraph.original] ?? [paragraph]).map {
                            BilingualSegment(
                                id: $0.id,
                                original: $0.original,
                                translation: aligned,
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
                    current.segments.removeAll { segment in
                        guard let original = currentParagraphs[segment.id] else { return true }
                        return !original.isSameReaderParagraph(as: segment.original)
                    }
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

    /// 列表标题/摘要翻译：一批文本（标题或摘要）合并为少量请求；命中
    /// 翻译记忆的文本不产生请求，结果写回记忆供后续复用。
    public func translateEntryTexts(
        _ texts: [String],
        targetLanguage: String? = nil,
        isRequestCurrent: @MainActor @Sendable @escaping () -> Bool = { true }
    ) async -> TitleTranslationBatchResult {
        var seen = Set<String>()
        let uniqueTexts = texts.filter { text in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(text).inserted
        }
        guard !uniqueTexts.isEmpty, isRequestCurrent() else { return .empty }
        guard let (baseExecution, apiKey) = executionSnapshot(for: .titleTranslation) else { return .empty }
        var configuration = baseExecution.configuration
        if let targetLanguage {
            let normalizedLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedLanguage.isEmpty { configuration.targetLanguage = normalizedLanguage }
        }
        let execution = AIExecutionContext(
            providerID: baseExecution.providerID,
            providerKind: baseExecution.providerKind,
            configuration: configuration
        )

        // 未配置 API Key 属于可预期的环境状态：不计失败，等配置完成后重试。
        guard !apiKey.isEmpty || !providerRequiresAPIKey(execution.providerKind) else {
            emitTransientNotice(LLMServiceError.missingAPIKey.localizedDescription)
            return .empty
        }

        var translations: [String: String] = [:]
        var failed = Set<String>()

        // 1. 翻译记忆命中：不产生请求。
        var unresolved: [String] = []
        for text in uniqueTexts {
            if let cached = cachedTranslation(for: text, configuration: configuration, executionContext: execution) {
                translations[text] = cached
            } else {
                unresolved.append(text)
            }
        }
        guard !unresolved.isEmpty else {
            return TitleTranslationBatchResult(translations: translations)
        }

        // 2. 未命中文本分批发（最多两批并行），字符与数量上限复用正文翻译口径。
        let fingerprint = execution.fingerprint(for: .translation, promptVersion: Self.translationPromptVersion)
        let batches = configuration.usesTranslationAdaptation
            ? unresolved.sorted().map { [$0] }
            : titleTranslationBatches(from: unresolved.sorted())
        let service = llm
        let batchConfiguration = configuration
        await withTaskGroup(of: (translations: [String: String], failed: Set<String>).self) { group in
            var nextBatchIndex = 0
            func enqueueNextBatch() {
                guard nextBatchIndex < batches.count else { return }
                let batch = batches[nextBatchIndex]
                nextBatchIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return ([:], Set(batch)) }
                    return await Self.translateTextSources(
                        batch,
                        configuration: batchConfiguration,
                        apiKey: apiKey,
                        service: service
                    )
                }
            }
            for _ in 0..<min(2, batches.count) { enqueueNextBatch() }
            for await outcome in group {
                // 已返回的批次一律写回记忆（即使请求期间范围变化），保证结果不浪费。
                for (text, translation) in outcome.translations {
                    translations[text] = translation
                    cacheTranslations(
                        [BilingualSegment(
                            id: "text:\(text.stableDigest)",
                            original: text,
                            translation: translation,
                            providerID: execution.providerID,
                            modelID: configuration.model,
                            configurationFingerprint: fingerprint
                        )],
                        configuration: configuration,
                        executionContext: execution
                    )
                }
                failed.formUnion(outcome.failed)
                if isRequestCurrent() { enqueueNextBatch() }
            }
        }
        return TitleTranslationBatchResult(translations: translations, failedTexts: failed)
    }

    /// 单批文本翻译。批量协议不被服务端接受时（400/422 或响应形状错误）
    /// 才回退为逐条；网络、鉴权与限流错误保持整批失败，不放大请求。
    private static func translateTextSources(
        _ sources: [String],
        configuration: LLMConfiguration,
        apiKey: String,
        service: LLMService
    ) async -> (translations: [String: String], failed: Set<String>) {
        do {
            let values = try await service.translateBatch(paragraphs: sources, configuration: configuration, apiKey: apiKey)
            var translations: [String: String] = [:]
            for (source, value) in zip(sources, values) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { translations[source] = trimmed }
            }
            let failed = Set(sources).subtracting(translations.keys)
            return (translations, failed)
        } catch {
            guard sources.count > 1,
                  !Task.isCancelled,
                  Self.shouldRetryTitleIndividually(error) else {
                return ([:], Set(sources))
            }
            var translations: [String: String] = [:]
            var failed = Set<String>()
            for source in sources {
                guard !Task.isCancelled else { break }
                do {
                    let value = try await service.translate(paragraph: source, configuration: configuration, apiKey: apiKey)
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { failed.insert(source) } else { translations[source] = trimmed }
                } catch {
                    failed.insert(source)
                }
            }
            return (translations, failed)
        }
    }

    private static func shouldRetryTitleIndividually(_ error: Error) -> Bool {
        guard let error = error as? LLMServiceError else { return false }
        switch error {
        case .invalidResponse, .truncatedResponse: return true
        case let .httpStatus(code, _): return code == 400 || code == 422
        default: return false
        }
    }

    private func titleTranslationBatches(from sources: [String]) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var characterCount = 0
        for source in sources {
            let wouldExceedLimit = !current.isEmpty && (
                current.count >= Self.maximumTitlesPerTranslationBatch
                    || characterCount + source.count > Self.maximumCharactersPerTranslationBatch
            )
            if wouldExceedLimit {
                batches.append(current)
                current = []
                characterCount = 0
            }
            current.append(source)
            characterCount += source.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
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
    /// 标题很短，单批可比正文段落大得多；仍保留字符上限兜底超长标题。
    private static let maximumTitlesPerTranslationBatch = 20

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
        settings = settings.updatingProvider(profile).selectingProvider(id: destination).updatingFeatures(AIFeaturePreferences(configuration: configuration, translationPreferences: settings.features.translationPreferences, automaticallyTranslate: settings.features.automaticallyTranslate))
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
        settings = settings.updatingProvider(profile).selectingProvider(id: destination).updatingFeatures(AIFeaturePreferences(configuration: configuration, translationPreferences: settings.features.translationPreferences, automaticallyTranslate: settings.features.automaticallyTranslate))
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

    public func setAutomaticallyFetchArticleContent(_ enabled: Bool) {
        guard automaticallyFetchArticleContent != enabled else { return }
        neighborPrefetchTask?.cancel()
        preparedArticleMemoryCache.removeAll()
        automaticallyFetchArticleContent = enabled
        articleFetchPreferences?.set(enabled, forKey: PreferenceKey.automaticallyFetchArticleContent)
    }

    public func setArticleRetentionPolicy(_ policy: ArticleRetentionPolicy) {
        guard articleRetentionPolicy != policy else { return }
        articleRetentionPolicy = policy
        UserDefaults.standard.set(policy.rawValue, forKey: PreferenceKey.articleRetentionPolicy)
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

    public func setReaderLatinFontFamily(_ fontFamilyName: String?) {
        var updated = readerAppearance
        updated.setLatinFontFamilyName(fontFamilyName)
        saveReaderAppearanceIfNeeded(updated)
    }

    public func setReaderCJKFontFamily(_ fontFamilyName: String?) {
        var updated = readerAppearance
        updated.setCJKFontFamilyName(fontFamilyName)
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
