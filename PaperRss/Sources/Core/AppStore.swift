import Combine
import Foundation
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

@MainActor
public final class AppStore: ObservableObject {
    @Published public var appLanguage: AppLanguage = I18N.shared.language {
        didSet {
            I18N.shared.language = appLanguage
        }
    }
    @Published public private(set) var appTheme: AppTheme = .system
    @Published public private(set) var articleFontSize: Int = 17

    @Published public private(set) var feeds: [Feed] = []
    @Published public private(set) var customFolders: [String] = []
    @Published public private(set) var sidebarCounts: SidebarCounts = SidebarCounts()
    @Published public private(set) var entryListItems: [EntryListItem] = []
    @Published public private(set) var todayEntryListItems: [EntryListItem] = []
    @Published public private(set) var unreadEntryListItems: [EntryListItem] = []
    @Published public private(set) var starredEntryListItems: [EntryListItem] = []
    @Published public var llmConfiguration: LLMConfiguration = .default

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
    private let persistenceURL: URL
    private let feedFetcher: @Sendable (Feed) async throws -> FeedFetchResult
    private let llm = LLMService()
    private var automaticRefreshTask: Task<Void, Never>?
    private var summaryStreamNotificationTask: Task<Void, Never>?

    private static let summaryStreamNotificationInterval: UInt64 = 30_000_000

    private enum PreferenceKey {
        static let refreshInterval = "PaperRss.refreshInterval"
        static let refreshOnLaunch = "PaperRss.refreshOnLaunch"
        static let appTheme = "PaperRss.appTheme"
        static let articleFontSize = "PaperRss.articleFontSize"
        static let ignoredVersion = "PaperRss.ignoredVersion"
        static let llmConfiguration = "PaperRss.llmConfiguration"
    }

    // MARK: - Initializer

    public init(
        fileManager: FileManager = .default,
        databaseURL: URL? = nil
    ) {
        self.feedFetcher = { try await FeedService.fetch($0) }
        let applicationSupport = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        let directory = applicationSupport.appendingPathComponent("PaperRss", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.persistenceURL = directory.appendingPathComponent("library.json")
        let sqliteURL = databaseURL ?? directory.appendingPathComponent("library.sqlite")

        do {
            self.libraryDatabase = try LibraryDatabase(databaseURL: sqliteURL)
        } catch {
            fatalError("Failed to initialize LibraryDatabase: \(error)")
        }

        self.localProvider = LocalAccountProvider(
            accountID: "local-default",
            database: libraryDatabase,
            feedFetcher: feedFetcher
        )

        // 1. Startup Migration Sequence: legacy library.json exists -> Migration detection FIRST
        if fileManager.fileExists(atPath: persistenceURL.path) {
            let migrator = LegacyJSONMigrator(database: libraryDatabase)
            if let result = try? migrator.migrate(from: persistenceURL), case .success(let report) = result {
                let legacyLLM = report.llmConfiguration
                let currentData = UserDefaults.standard.data(forKey: PreferenceKey.llmConfiguration)
                if currentData == nil {
                    let config = LLMConfiguration(
                        providerName: legacyLLM.providerName,
                        providerDescription: legacyLLM.providerDescription,
                        baseURL: legacyLLM.baseURL,
                        model: legacyLLM.model,
                        reasoningMode: legacyLLM.reasoningMode,
                        temperature: legacyLLM.temperature,
                        targetLanguage: legacyLLM.targetLanguage,
                        allowInsecureLocalEndpoint: legacyLLM.allowInsecureLocalEndpoint,
                        showsAISummary: legacyLLM.showsAISummary,
                        automaticallyGenerateSummary: legacyLLM.automaticallyGenerateSummary,
                        showsSelectionExplanation: legacyLLM.showsSelectionExplanation,
                        showsSelectionAsk: legacyLLM.showsSelectionAsk,
                        showsSelectionTranslation: legacyLLM.showsSelectionTranslation,
                        customPrompt: legacyLLM.customPrompt
                    )
                    if let data = try? JSONEncoder().encode(config) {
                        UserDefaults.standard.set(data, forKey: PreferenceKey.llmConfiguration)
                    }
                }
            }
        }

        // 2. Ensure Bootstrap
        try? localProvider.ensureAccountExists()

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

        // 4. Reload State from SQLite
        reloadState()

        Task { [weak self] in
            await self?.checkForUpdates(isUserInitiated: false)
        }
    }

    /// 测试用初始化器（隔离测试沙箱）
    public init(
        testDatabase: AppDatabase,
        feedFetcher: @escaping @Sendable (Feed) async throws -> FeedFetchResult
    ) {
        self.feedFetcher = feedFetcher
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

        self.localProvider = LocalAccountProvider(
            accountID: "local-default",
            database: libraryDatabase,
            feedFetcher: feedFetcher
        )

        // 写入测试 JSON 并执行迁移
        if let data = try? JSONEncoder.paperRss.encode(testDatabase) {
            try? data.write(to: persistenceURL)
            let migrator = LegacyJSONMigrator(database: libraryDatabase)
            _ = try? migrator.migrate(from: persistenceURL)
        }

        try? localProvider.ensureAccountExists()

        let preferences = UserDefaults.standard
        refreshInterval = FeedRefreshInterval(rawValue: preferences.string(forKey: PreferenceKey.refreshInterval) ?? "") ?? .twoHours
        refreshOnLaunch = preferences.object(forKey: PreferenceKey.refreshOnLaunch) as? Bool ?? true
        let rawTheme = preferences.string(forKey: PreferenceKey.appTheme) ?? ""
        appTheme = AppTheme(rawValue: rawTheme) ?? .system
        let storedFontSize = preferences.integer(forKey: PreferenceKey.articleFontSize)
        articleFontSize = (13...25).contains(storedFontSize) ? storedFontSize : 17
        ignoredVersion = preferences.string(forKey: PreferenceKey.ignoredVersion)
        llmConfiguration = testDatabase.llmConfiguration

        reloadState()
    }

    // MARK: - State Reload & Querying

    public func reloadState() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date()).timeIntervalSince1970

        self.feeds = (try? localProvider.fetchFeeds()) ?? []
        self.customFolders = (try? localProvider.fetchFolderNames()) ?? []
        self.sidebarCounts = (try? localProvider.timelineQueryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)) ?? SidebarCounts()

        self.entryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .all)) ?? []
        self.todayEntryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .today(startOfDayTimestamp: startOfDay))) ?? []
        self.unreadEntryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .unread)) ?? []
        self.starredEntryListItems = (try? localProvider.timelineQueryService.fetchListItems(scope: .starred)) ?? []
    }

    // MARK: - Computed Public Accessors

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

    public var entries: [Entry] {
        (try? localProvider.fetchAllEntries()) ?? []
    }

    public var todayEntries: [Entry] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date()).timeIntervalSince1970
        return entries.filter {
            let ts = $0.publishedAt?.timeIntervalSince1970 ?? $0.updatedAt.timeIntervalSince1970
            return ts >= startOfDay
        }
    }

    public var todayUnreadCount: Int { sidebarCounts.todayUnread }
    public var unreadEntries: [Entry] { entries.filter { !$0.isRead } }
    public var starredEntries: [Entry] { entries.filter { $0.isStarred } }

    public func unreadCount(feedID: UUID) -> Int { sidebarCounts.unreadByFeed[feedID, default: 0] }
    public func unreadCount(folder: String) -> Int { sidebarCounts.unreadByFolder[folder, default: 0] }

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
        return entryListItems.filter { feedIDs.contains($0.feedID) }
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
        try? localProvider.fetchEntry(id: id)
    }

    public func feed(for entry: Entry) -> Feed? {
        feeds.first { $0.id == entry.feedID }
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
        guard let url = normalizedURL(urlText) else { lastError = I18N.localized("请输入有效的 Feed URL。"); return }
        guard !feeds.contains(where: { $0.feedURL == url && !$0.isDeleted }) else { lastError = I18N.localized("这个订阅已经存在。"); return }

        let title = url.host ?? url.absoluteString
        guard let feed = try? localProvider.addFeed(title: title, feedURL: url, folder: folder) else { return }
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
        refreshStatus = .refreshing

        let targetFeeds: [Feed]
        if let feedIDs {
            targetFeeds = feeds.filter { feedIDs.contains($0.id) && !$0.isDeleted }
        } else {
            targetFeeds = feeds.filter { !$0.isDeleted }
        }

        let total = targetFeeds.count
        refreshProgress = (0, total)
        defer {
            refreshProgress = nil
            isRefreshing = false
        }

        var failures: [String] = []
        var updatedFeeds = 0
        var newUnreadEntries: [Entry] = []
        var completedCount = 0

        let maxConcurrency = 6
        let provider = self.localProvider

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

        reloadState()

        let finishedAt = Date.now
        var reportedEntryIDs: Set<String> = []
        let finalNewUnreads = newUnreadEntries.compactMap { candidate -> Entry? in
            guard reportedEntryIDs.insert(candidate.id).inserted,
                  let current = try? provider.fetchEntry(id: candidate.id),
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

    public func markRead(_ entry: Entry, read: Bool = true) {
        markRead(entryID: entry.id, read: read)
    }

    public func markRead(entryID: String, read: Bool = true) {
        try? localProvider.markRead(entryID: entryID, read: read)
        reloadState()
    }

    public func markRead(entryIDs: [String], read: Bool = true) {
        guard !entryIDs.isEmpty else { return }
        try? localProvider.markRead(entryIDs: entryIDs, read: read)
        reloadState()
    }

    public func markStarred(_ entry: Entry, starred: Bool = true) {
        markStarred(entryID: entry.id, starred: starred)
    }

    public func markStarred(entryID: String, starred: Bool = true) {
        try? localProvider.markStarred(entryID: entryID, starred: starred)
        reloadState()
    }

    public func toggleStar(_ entry: Entry) {
        markStarred(entry, starred: !entry.isStarred)
    }

    public func toggleStar(entryID: String) {
        if let entry = entry(id: entryID) {
            markStarred(entryID: entryID, starred: !entry.isStarred)
        }
    }

    public func markAllRead(feedID: UUID? = nil, folder: String? = nil) {
        try? localProvider.markAllRead(feedID: feedID, folderName: folder)
        reloadState()
    }

    // MARK: - Article Caches & Details

    public func cachedText(for entry: Entry) -> String? {
        (try? localProvider.fetchCache(entryID: entry.id))?.text
    }

    public func articleText(for entry: Entry) async throws -> String {
        if let feedContent = preferredFeedContent(for: entry) {
            return feedContent.text.isEmpty ? entry.sourceText : feedContent.text
        }
        if let cached = cachedText(for: entry) {
            return cached
        }
        return try await fetchFullArticle(for: entry)
    }

    public func articleHTML(for entry: Entry) -> String? {
        if let feedContent = preferredFeedContent(for: entry) {
            let existing = try? localProvider.fetchCache(entryID: entry.id)
            let text = feedContent.text.isEmpty ? entry.sourceText : feedContent.text
            if existing?.html != feedContent.html || existing?.text != text || existing?.imageURLs != feedContent.imageURLs || existing?.sourceURL != entry.url || existing?.isSanitized != true {
                let cache = ArticleCache(
                    entryID: entry.id,
                    text: text,
                    html: feedContent.html,
                    imageURLs: feedContent.imageURLs,
                    fetchedAt: existing?.fetchedAt ?? .now,
                    sourceURL: entry.url,
                    isSanitized: true
                )
                try? localProvider.saveCache(cache)
            }
            return feedContent.html
        }

        if let cache = try? localProvider.fetchCache(entryID: entry.id), let html = cache.html, !html.isEmpty {
            if cache.isSanitized {
                let sourceURL = cache.sourceURL ?? entry.url
                var repairedHTML = ArticleExtractor.sanitizedHTML(html, baseURL: sourceURL)
                if let sourceHTML = entry.contentHTML {
                    repairedHTML = ArticleExtractor.repairingCollapsedWhitespaceImageURLs(
                        in: repairedHTML,
                        sourceHTML: sourceHTML,
                        baseURL: sourceURL
                    )
                }
                if repairedHTML != html {
                    var repaired = cache
                    repaired.html = repairedHTML
                    repaired.imageURLs = ArticleExtractor.imageURLs(from: repairedHTML, baseURL: sourceURL)
                    repaired.sourceURL = sourceURL
                    try? localProvider.saveCache(repaired)
                }
                return repairedHTML
            }
            return ArticleExtractor.sanitizedHTML(html, baseURL: cache.sourceURL ?? entry.url)
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
        let fallback = entry.sourceText
        guard let url = entry.url else { return fallback }
        var cache = try await ArticleExtractor.extract(from: url)
        cache.entryID = entry.id
        cache.isSanitized = true
        try? localProvider.saveCache(cache)
        return cache.text
    }

    private func preferredFeedContent(for entry: Entry) -> ArticleExtractor.Content? {
        guard let rawHTML = entry.contentHTML,
              !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let entryHost = entry.url?.host?.lowercased() ?? ""
        let isTwitterStatus = entryHost == "x.com" || entryHost == "www.x.com" || entryHost == "twitter.com" || entryHost == "www.twitter.com"

        let feedURL = feed(for: entry)?.feedURL
        let feedHost = feedURL?.host?.lowercased() ?? ""
        let feedPath = feedURL?.path.lowercased() ?? ""
        let isTwitterRoute = feedPath.contains("/twitter/") || feedPath.hasPrefix("/twitter") || feedPath.contains("/x/")
        let isRSSHub = feedHost.contains("rsshub") || feedHost == "47.251.82.23"

        guard isTwitterRoute || isTwitterStatus || isRSSHub else { return nil }

        return ArticleExtractor.content(from: rawHTML, baseURL: entry.url)
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

    public func isGeneratingAI(for entry: Entry, kind: AIArtifactKind) -> Bool {
        guard let status = activeAIStatus(for: kind) else { return false }
        return status.entryID == entry.id && status.kind == kind
    }

    public func generateSummary(entry: Entry, text: String, force: Bool = false) async {
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
        let accumulator = StreamAccumulator()
        let isComplete = false

        let initialArtifact = AIArtifact(
            id: targetArtifactID,
            entryID: entry.id,
            kind: .summary,
            contentHash: hash,
            model: configuration.model,
            targetLanguage: configuration.targetLanguage,
            promptVersion: 1,
            content: "",
            isComplete: isComplete
        )
        try? localProvider.saveArtifact(initialArtifact)

        startSummaryStreamNotifications()

        do {
            let result = try await llm.summary(text: text, configuration: configuration, apiKey: apiKey) { [weak self] delta in
                guard let self, !Task.isCancelled else { return }
                let currentBuffer = accumulator.append(delta)
                var updated = initialArtifact
                updated.content = currentBuffer
                updated.updatedAt = .now
                try? self.localProvider.saveArtifact(updated)
            }
            stopSummaryStreamNotifications()

            var finalArtifact = initialArtifact
            finalArtifact.content = result
            finalArtifact.isComplete = true
            finalArtifact.updatedAt = .now
            try? localProvider.saveArtifact(finalArtifact)
            activeSummaryRequest = nil
        } catch {
            stopSummaryStreamNotifications()
            activeSummaryRequest = nil
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
        }
    }

    public func generateBilingualTranslation(entry: Entry, text: String, targetLanguage: String = "zh-Hans") async {
        let configuration = llmConfiguration
        let hash = text.stableDigest
        if let existing = bilingualArtifact(for: entry, text: text), existing.isComplete {
            return
        }
        guard activeBilingualRequest == nil else { return }

        let paragraphs = ArticleExtractor.readerParagraphs(in: text, title: entry.title)
        guard !paragraphs.isEmpty else { return }

        lastError = nil
        activeBilingualRequest = AIRequestStatus(entryID: entry.id, kind: .bilingual, phase: .loadingLocalConfiguration)
        let apiKey = loadAPIKey()
        guard !apiKey.isEmpty else {
            activeBilingualRequest = nil
            lastError = LLMServiceError.missingAPIKey.localizedDescription
            return
        }

        activeBilingualRequest = AIRequestStatus(entryID: entry.id, kind: .bilingual, phase: .generating)

        let targetArtifactID = UUID()
        let paragraphOrder: [String: Int] = Dictionary(uniqueKeysWithValues: paragraphs.enumerated().map { ($1.id, $0) })

        var initialArtifact = AIArtifact(
            id: targetArtifactID,
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
        try? localProvider.saveArtifact(initialArtifact)

        var uncachedParagraphs: [ReaderParagraph] = []
        var cachedSegments: [BilingualSegment] = []

        for paragraph in paragraphs {
            if let cached = cachedTranslation(for: paragraph.original, configuration: configuration) {
                cachedSegments.append(BilingualSegment(id: paragraph.id, original: paragraph.original, translation: cached))
            } else {
                uncachedParagraphs.append(paragraph)
            }
        }

        if !cachedSegments.isEmpty {
            initialArtifact.segments = cachedSegments
            initialArtifact.content = cachedSegments.map(\.translation).joined(separator: "\n\n")
            try? localProvider.saveArtifact(initialArtifact)
        }

        if uncachedParagraphs.isEmpty {
            initialArtifact.isComplete = true
            initialArtifact.updatedAt = .now
            try? localProvider.saveArtifact(initialArtifact)
            activeBilingualRequest = nil
            return
        }

        let batches = translationBatches(from: uncachedParagraphs)
        activeBilingualTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for batch in batches {
                    guard !Task.isCancelled else { break }
                    let translatedTexts = try await self.llm.translateBatch(
                        paragraphs: batch.map(\.original),
                        configuration: configuration,
                        apiKey: apiKey
                    )
                    guard !Task.isCancelled else { break }
                    let segments = zip(batch, translatedTexts).map {
                        BilingualSegment(id: $0.id, original: $0.original, translation: $1)
                    }
                    self.cacheTranslations(segments, configuration: configuration)

                    var current = (try? self.localProvider.fetchArtifact(entryID: entry.id, kind: .bilingual, isCompleteOnly: false)) ?? initialArtifact
                    for seg in segments {
                        if let idx = current.segments.firstIndex(where: { $0.id == seg.id }) {
                            current.segments[idx] = seg
                        } else {
                            current.segments.append(seg)
                        }
                    }
                    current.segments.sort { paragraphOrder[$0.id, default: .max] < paragraphOrder[$1.id, default: .max] }
                    current.content = current.segments.map(\.translation).joined(separator: "\n\n")
                    current.updatedAt = .now
                    try? self.localProvider.saveArtifact(current)
                }

                if var finalArt = try? self.localProvider.fetchArtifact(entryID: entry.id, kind: .bilingual, isCompleteOnly: false) {
                    finalArt.isComplete = true
                    finalArt.updatedAt = .now
                    try? self.localProvider.saveArtifact(finalArt)
                }
                self.activeBilingualRequest = nil
            } catch {
                self.activeBilingualRequest = nil
                if !Task.isCancelled {
                    self.lastError = error.localizedDescription
                }
            }
        }
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
        await generateBilingualTranslation(entry: entry, text: text)
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

    private func cacheTranslations(_ segments: [BilingualSegment], configuration: LLMConfiguration) {
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

    private func startSummaryStreamNotifications() {
        guard summaryStreamNotificationTask == nil else { return }
        summaryStreamNotificationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.summaryStreamNotificationInterval)
                guard let self, !Task.isCancelled else { return }
                self.objectWillChange.send()
            }
        }
    }

    private func stopSummaryStreamNotifications() {
        summaryStreamNotificationTask?.cancel()
        summaryStreamNotificationTask = nil
        objectWillChange.send()
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

