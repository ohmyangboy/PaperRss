import Combine
import Foundation

public enum AIRequestPhase: Sendable, Equatable {
    case loadingLocalConfiguration
    case generating

    public var message: String {
        switch self {
        case .loadingLocalConfiguration: "正在读取本机 AI 配置…"
        case .generating: "正在生成，完成后会自动显示。"
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

/// A read-optimized snapshot of the article library.
///
/// SwiftUI's `List` already creates rows lazily, but it still needs a stable
/// collection and stable identities when its selection changes. Keeping the
/// sort and grouping work here means a sidebar click only swaps an existing
/// array instead of sorting and filtering the full library several times while
/// SwiftUI evaluates the three-column hierarchy.
struct EntryLibraryIndex: Sendable {
    static let empty = EntryLibraryIndex(entries: [], feeds: [])

    let all: [Entry]
    let today: [Entry]
    let unread: [Entry]
    let starred: [Entry]
    let byID: [String: Entry]
    let byFeed: [UUID: [Entry]]
    let byFolder: [String: [Entry]]
    let unreadByFeed: [UUID: Int]
    let unreadByFolder: [String: Int]
    let allListItems: [EntryListItem]
    let todayListItems: [EntryListItem]
    let unreadListItems: [EntryListItem]
    let starredListItems: [EntryListItem]
    let listItemsByFeed: [UUID: [EntryListItem]]
    let listItemsByFolder: [String: [EntryListItem]]

    init(entries: [Entry], feeds: [Feed], now: Date = .now, calendar: Calendar = .current) {
        let ordered = entries.sorted {
            let left = $0.publishedAt ?? .distantPast
            let right = $1.publishedAt ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
        let feedsByID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        let folderByFeed = Dictionary(uniqueKeysWithValues: feeds.compactMap { feed in
            feed.folder.map { (feed.id, $0) }
        })
        let titleByFeed = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0.title) })

        var todayEntries: [Entry] = []
        var unreadEntries: [Entry] = []
        var starredEntries: [Entry] = []
        var entriesByID: [String: Entry] = [:]
        var entriesByFeed: [UUID: [Entry]] = [:]
        var entriesByFolder: [String: [Entry]] = [:]
        var feedUnreadCounts: [UUID: Int] = [:]
        var folderUnreadCounts: [String: Int] = [:]
        var listItems: [EntryListItem] = []
        var todayRowItems: [EntryListItem] = []
        var unreadRowItems: [EntryListItem] = []
        var starredRowItems: [EntryListItem] = []
        var rowItemsByFeed: [UUID: [EntryListItem]] = [:]
        var rowItemsByFolder: [String: [EntryListItem]] = [:]

        todayEntries.reserveCapacity(min(ordered.count, 128))
        unreadEntries.reserveCapacity(ordered.count)
        starredEntries.reserveCapacity(min(ordered.count, 128))
        entriesByID.reserveCapacity(ordered.count)
        listItems.reserveCapacity(ordered.count)

        for entry in ordered {
            let feed = feedsByID[entry.feedID]
            let listItem = EntryListItem(
                entry: entry,
                sourceTitle: feed?.title ?? titleByFeed[entry.feedID] ?? "订阅",
                feedIconURL: feed?.iconURL
            )
            entriesByID[entry.id] = entry
            entriesByFeed[entry.feedID, default: []].append(entry)
            listItems.append(listItem)
            rowItemsByFeed[entry.feedID, default: []].append(listItem)
            if let publishedAt = entry.publishedAt, calendar.isDate(publishedAt, inSameDayAs: now) {
                todayEntries.append(entry)
                todayRowItems.append(listItem)
            }
            if entry.isStarred {
                starredEntries.append(entry)
                starredRowItems.append(listItem)
            }
            if !entry.isRead {
                unreadEntries.append(entry)
                unreadRowItems.append(listItem)
                feedUnreadCounts[entry.feedID, default: 0] += 1
            }
            if let folder = folderByFeed[entry.feedID] {
                entriesByFolder[folder, default: []].append(entry)
                rowItemsByFolder[folder, default: []].append(listItem)
                if !entry.isRead {
                    folderUnreadCounts[folder, default: 0] += 1
                }
            }
        }

        all = ordered
        today = todayEntries
        unread = unreadEntries
        starred = starredEntries
        byID = entriesByID
        byFeed = entriesByFeed
        byFolder = entriesByFolder
        unreadByFeed = feedUnreadCounts
        unreadByFolder = folderUnreadCounts
        allListItems = listItems
        todayListItems = todayRowItems
        unreadListItems = unreadRowItems
        starredListItems = starredRowItems
        listItemsByFeed = rowItemsByFeed
        listItemsByFolder = rowItemsByFolder
    }
}

@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var database: AppDatabase
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var isICloudSyncEnabled = false
    @Published public private(set) var iCloudSyncStatus = "未启用"
    @Published public private(set) var activeAIRequest: AIRequestStatus?

    private let persistenceURL: URL
    private let llm = LLMService()
    private let persistenceWriter = DatabasePersistenceWriter()
    private var iCloudSyncTask: Task<Void, Never>?
    private var persistenceRevision = 0
    private var entryIndex: EntryLibraryIndex

    public init(fileManager: FileManager = .default) {
        let applicationSupport = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        let directory = applicationSupport.appendingPathComponent("PaperRss", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        persistenceURL = directory.appendingPathComponent("library.json")
        var loadedDatabase = Self.load(from: persistenceURL) ?? .empty
        // Older builds kept some HTML descriptions in `summary`. Normalize
        // those once at load time instead of running a regular-expression HTML
        // pass from every visible row whenever the user changes feeds.
        for index in loadedDatabase.entries.indices where loadedDatabase.entries[index].summary.needsPlainTextNormalization {
            loadedDatabase.entries[index].summary = loadedDatabase.entries[index].summary.plainText
        }
        database = loadedDatabase
        entryIndex = EntryLibraryIndex(entries: loadedDatabase.entries, feeds: loadedDatabase.feeds)
        isICloudSyncEnabled = UserDefaults.standard.bool(forKey: "PaperRss.iCloudSyncEnabled")
        iCloudSyncStatus = isICloudSyncEnabled ? "等待同步" : "未启用"
    }

    public var feeds: [Feed] { database.feeds.filter { !$0.isDeleted }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
    public var folders: [String] { Array(Set(feeds.compactMap(\.folder))).sorted() }
    public var entries: [Entry] { entryIndex.all }
    public var todayEntries: [Entry] { entryIndex.today }
    public var unreadEntries: [Entry] { entryIndex.unread }
    public var starredEntries: [Entry] { entryIndex.starred }
    public var entryListItems: [EntryListItem] { entryIndex.allListItems }
    public var todayEntryListItems: [EntryListItem] { entryIndex.todayListItems }
    public var unreadEntryListItems: [EntryListItem] { entryIndex.unreadListItems }
    public var starredEntryListItems: [EntryListItem] { entryIndex.starredListItems }
    public func unreadCount(feedID: UUID) -> Int { entryIndex.unreadByFeed[feedID, default: 0] }
    public func unreadCount(folder: String) -> Int { entryIndex.unreadByFolder[folder, default: 0] }

    public func entries(feedID: UUID?) -> [Entry] {
        guard let feedID else { return entries }
        return entryIndex.byFeed[feedID] ?? []
    }

    public func entries(folder: String) -> [Entry] { entryIndex.byFolder[folder] ?? [] }
    public func entryListItems(feedID: UUID) -> [EntryListItem] { entryIndex.listItemsByFeed[feedID] ?? [] }
    public func entryListItems(folder: String) -> [EntryListItem] { entryIndex.listItemsByFolder[folder] ?? [] }
    public func entry(id: String) -> Entry? { entryIndex.byID[id] }
    public func feed(for entry: Entry) -> Feed? { database.feeds.first { $0.id == entry.feedID } }
    public func artifact(for entry: Entry, kind: AIArtifactKind) -> AIArtifact? {
        database.artifacts.filter { $0.entryID == entry.id && $0.kind == kind && $0.isComplete && !$0.isDeleted }.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    /// Returns the saved progressive translation that matches the article's
    /// current text and model. Unlike `artifact(for:kind:)`, this intentionally
    /// includes an incomplete artifact so the reader can render finished
    /// paragraphs while the rest remains lazy.
    public func bilingualArtifact(for entry: Entry, text: String) -> AIArtifact? {
        let configuration = database.llmConfiguration
        let hash = text.stableDigest
        return database.artifacts
            .filter {
                $0.entryID == entry.id
                    && $0.kind == .bilingual
                    && $0.contentHash == hash
                    && $0.model == configuration.model
                    && !$0.isDeleted
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    public func isGeneratingAI(for entry: Entry, kind: AIArtifactKind) -> Bool {
        activeAIRequest?.entryID == entry.id && activeAIRequest?.kind == kind
    }

    public func addFeed(urlText: String, folder: String? = nil) async {
        guard let url = normalizedURL(urlText) else { lastError = "请输入有效的 Feed URL。"; return }
        guard !database.feeds.contains(where: { $0.feedURL == url && !$0.isDeleted }) else { lastError = "这个订阅已经存在。"; return }
        let feed = Feed(title: url.host ?? url.absoluteString, feedURL: url, folder: folder?.nonEmpty)
        database.feeds.append(feed)
        persist()
        await refresh(feedIDs: [feed.id])
    }

    public func importOPML(_ data: Data) async {
        let urls = OPMLService.importURLs(data: data)
        for url in urls where !database.feeds.contains(where: { $0.feedURL == url && !$0.isDeleted }) {
            database.feeds.append(Feed(title: url.host ?? url.absoluteString, feedURL: url))
        }
        persist()
        await refresh()
    }

    public func exportOPML() -> Data { OPMLService.export(feeds: database.feeds) }

    public func refresh(feedIDs: [UUID]? = nil) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let ids = feedIDs ?? feeds.map(\.id)
        var failures: [String] = []
        for id in ids {
            guard let index = database.feeds.firstIndex(where: { $0.id == id }), !database.feeds[index].isDeleted else { continue }
            let oldFeed = database.feeds[index]
            do {
                switch try await FeedService.fetch(oldFeed) {
                case let .notModified(etag, lastModified):
                    database.feeds[index].etag = etag
                    database.feeds[index].lastModified = lastModified
                    database.feeds[index].lastRefreshedAt = .now
                    database.feeds[index].updatedAt = .now
                case let .updated(parsed, etag, lastModified):
                    database.feeds[index].title = parsed.title
                    database.feeds[index].siteURL = parsed.siteURL
                    database.feeds[index].etag = etag
                    database.feeds[index].lastModified = lastModified
                    database.feeds[index].lastRefreshedAt = .now
                    database.feeds[index].updatedAt = .now
                    merge(entries: parsed.entries, into: oldFeed.id)
                }
            } catch {
                failures.append("\(oldFeed.title)：\(error.localizedDescription)")
            }
        }
        rebuildEntryIndex()
        persist()
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
    }

    public func markRead(_ entry: Entry, read: Bool = true) {
        markRead(entryID: entry.id, read: read)
    }

    public func markRead(entryID: String, read: Bool = true) {
        guard entryIndex.byID[entryID]?.isRead != read else { return }
        update(entryID: entryID) { item in item.isRead = read; item.updatedAt = .now }
    }

    /// Applies a folder/feed-wide read state as one database transaction.
    /// The previous row-by-row path rewrote the whole JSON database and
    /// rescheduled CloudKit once per entry, which caused visible stalls for
    /// feeds with hundreds of unread items.
    public func markRead(entryIDs: [String], read: Bool = true) {
        let targetIDs = Set(entryIDs)
        guard !targetIDs.isEmpty else { return }

        var updatedDatabase = database
        let updatedAt = Date.now
        var didChange = false
        for index in updatedDatabase.entries.indices {
            let id = updatedDatabase.entries[index].id
            guard targetIDs.contains(id), updatedDatabase.entries[index].isRead != read else { continue }
            updatedDatabase.entries[index].isRead = read
            updatedDatabase.entries[index].updatedAt = updatedAt
            updatedDatabase.readingStates[id] = ReadingState(
                entryID: id,
                isRead: read,
                isStarred: updatedDatabase.entries[index].isStarred,
                updatedAt: updatedAt
            )
            didChange = true
        }
        guard didChange else { return }
        database = updatedDatabase
        rebuildEntryIndex()
        persist()
    }

    public func toggleStar(_ entry: Entry) {
        toggleStar(entryID: entry.id)
    }

    public func toggleStar(entryID: String) {
        update(entryID: entryID) { item in item.isStarred.toggle(); item.updatedAt = .now }
    }

    public func deleteFeed(_ feed: Feed) {
        guard let index = database.feeds.firstIndex(of: feed) else { return }
        let entryIDs = Set(database.entries.lazy.filter { $0.feedID == feed.id }.map(\.id))
        let deletedAt = Date.now
        database.feeds[index].isDeleted = true
        database.feeds[index].updatedAt = deletedAt
        database.entries.removeAll { entryIDs.contains($0.id) }
        database.articleCaches = database.articleCaches.filter { !entryIDs.contains($0.key) }
        database.readingStates = database.readingStates.filter { !entryIDs.contains($0.key) }
        for artifactIndex in database.artifacts.indices where entryIDs.contains(database.artifacts[artifactIndex].entryID) {
            // Keep only a small tombstone so CloudKit can remove the synced
            // result instead of restoring it from another offline device.
            database.artifacts[artifactIndex].content = ""
            database.artifacts[artifactIndex].segments = []
            database.artifacts[artifactIndex].selectionText = nil
            database.artifacts[artifactIndex].selectionArticleHash = nil
            database.artifacts[artifactIndex].selectionAnchor = nil
            database.artifacts[artifactIndex].isComplete = false
            database.artifacts[artifactIndex].isDeleted = true
            database.artifacts[artifactIndex].updatedAt = deletedAt
        }
        rebuildEntryIndex()
        persist()
    }

    public func deleteArtifact(_ artifact: AIArtifact) {
        database.artifacts.removeAll { $0.id == artifact.id }
        persist()
    }

    public func articleText(for entry: Entry) async throws -> String {
        // RSSHub's Twitter/X route already provides a compact, semantic feed
        // description. The linked status page is a web application shell with
        // duplicated avatar cards and empty layout containers; extracting that
        // page makes the reader look worse than the feed itself. Prefer the
        // feed body for these entries and migrate any legacy page cache lazily.
        if let feedContent = preferredFeedContent(for: entry) {
            let existing = database.articleCaches[entry.id]
            let cache = ArticleCache(
                entryID: entry.id,
                text: feedContent.text.isEmpty ? entry.sourceText : feedContent.text,
                html: feedContent.html,
                imageURLs: feedContent.imageURLs,
                fetchedAt: existing?.fetchedAt ?? .now,
                sourceURL: entry.url,
                isSanitized: true
            )
            if existing?.html != cache.html || existing?.text != cache.text || existing?.imageURLs != cache.imageURLs || existing?.sourceURL != cache.sourceURL || existing?.isSanitized != true {
                database.articleCaches[entry.id] = cache
                persist()
            }
            return cache.text
        }

        let fallback = entry.sourceText
        if var cached = database.articleCaches[entry.id], !cached.text.isEmpty {
            let sourceURL = cached.sourceURL ?? entry.url
            if let html = cached.html, !html.isEmpty {
                if cached.isSanitized {
                    return cached.text
                }
                // Caches from earlier builds may contain permissive HTML. Re-sanitize
                // them before handing anything to WebKit, then persist the migration.
                let safeHTML = ArticleExtractor.sanitizedHTML(html, baseURL: sourceURL)
                let safeText = safeHTML.plainText
                let safeImages = ArticleExtractor.imageURLs(from: safeHTML, baseURL: sourceURL)
                if safeHTML != html || cached.imageURLs != safeImages || cached.sourceURL != sourceURL || (!safeText.isEmpty && cached.text != safeText) {
                    cached.html = safeHTML
                    cached.imageURLs = safeImages
                    cached.sourceURL = sourceURL
                    if !safeText.isEmpty { cached.text = safeText }
                }
                cached.isSanitized = true
                database.articleCaches[entry.id] = cached
                persist()
                return cached.text
            }

            // Legacy text-only caches cannot preserve image placement. Rebuild a
            // structured cache from the feed body when possible; otherwise the
            // extraction path below refreshes it from the article URL.
            if !ArticleExtractor.needsExtraction(entry) {
                let content = ArticleExtractor.content(from: entry.contentHTML ?? "", baseURL: sourceURL)
                cached.html = content.html
                cached.imageURLs = content.imageURLs
                cached.sourceURL = sourceURL
                if !content.text.isEmpty { cached.text = content.text }
                cached.isSanitized = true
                database.articleCaches[entry.id] = cached
                persist()
                return cached.text
            }
        }
        guard ArticleExtractor.needsExtraction(entry) else {
            let content = ArticleExtractor.content(from: entry.contentHTML ?? "", baseURL: entry.url)
            let text = content.text.isEmpty ? fallback : content.text
            database.articleCaches[entry.id] = ArticleCache(entryID: entry.id, text: text, html: content.html, imageURLs: content.imageURLs, sourceURL: entry.url, isSanitized: true)
            persist()
            return text
        }
        guard let url = entry.url else { return fallback }
        var cache = try await ArticleExtractor.extract(from: url)
        cache.entryID = entry.id
        cache.isSanitized = true
        database.articleCaches[entry.id] = cache
        persist()
        return cache.text
    }

    public func cachedText(for entry: Entry) -> String? { database.articleCaches[entry.id]?.text }
    public func articleHTML(for entry: Entry) -> String? {
        if let feedContent = preferredFeedContent(for: entry) {
            let existing = database.articleCaches[entry.id]
            let text = feedContent.text.isEmpty ? entry.sourceText : feedContent.text
            if existing?.html != feedContent.html || existing?.text != text || existing?.imageURLs != feedContent.imageURLs || existing?.sourceURL != entry.url || existing?.isSanitized != true {
                database.articleCaches[entry.id] = ArticleCache(
                    entryID: entry.id,
                    text: text,
                    html: feedContent.html,
                    imageURLs: feedContent.imageURLs,
                    fetchedAt: existing?.fetchedAt ?? .now,
                    sourceURL: entry.url,
                    isSanitized: true
                )
                persist()
            }
            return feedContent.html
        }

        if let cache = database.articleCaches[entry.id], let html = cache.html, !html.isEmpty {
            if cache.isSanitized {
                // A previous build marked RSSHub HTML as sanitized before
                // normalizing nested entities in image query strings. Repair
                // that cache lazily so existing Twitter/X articles do not
                // need to be fetched again.
                let sourceURL = cache.sourceURL ?? entry.url
                let repairedHTML = ArticleExtractor.sanitizedHTML(html, baseURL: sourceURL)
                if repairedHTML != html {
                    var repaired = cache
                    repaired.html = repairedHTML
                    repaired.imageURLs = ArticleExtractor.imageURLs(from: repairedHTML, baseURL: sourceURL)
                    repaired.sourceURL = sourceURL
                    database.articleCaches[entry.id] = repaired
                    persist()
                }
                return repairedHTML
            }
            return ArticleExtractor.sanitizedHTML(html, baseURL: cache.sourceURL ?? entry.url)
        }
        return entry.contentHTML.map { ArticleExtractor.sanitizedHTML($0, baseURL: entry.url) }
    }
    public func articleSourceURL(for entry: Entry) -> URL? {
        database.articleCaches[entry.id]?.sourceURL ?? entry.url
    }
    public func articleImageURLs(for entry: Entry) -> [URL] {
        let sourceURL = articleSourceURL(for: entry)
        if let html = articleHTML(for: entry) {
            return ArticleExtractor.imageURLs(from: html, baseURL: sourceURL)
        }
        return []
    }

    /// Returns the feed-provided body for RSSHub Twitter/X entries. These
    /// feeds intentionally expose a concise status body, while the status URL
    /// itself is a dynamic social webpage whose DOM is not suitable for a
    /// read-only RSS reader. Keeping this decision here also lets old article
    /// caches be replaced without another network request.
    private func preferredFeedContent(for entry: Entry) -> ArticleExtractor.Content? {
        guard let rawHTML = entry.contentHTML,
              !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let feed = feed(for: entry) else { return nil }

        let feedURL = feed.feedURL
        let feedHost = feedURL.host?.lowercased() ?? ""
        let feedPath = feedURL.path.lowercased()
        let entryHost = entry.url?.host?.lowercased() ?? ""
        let isTwitterRoute = feedPath.contains("/twitter/") || feedPath.hasPrefix("/twitter") || feedPath.contains("/x/")
        let isTwitterStatus = entryHost == "x.com" || entryHost == "www.x.com" || entryHost == "twitter.com" || entryHost == "www.twitter.com"
        let isRSSHub = feedHost.contains("rsshub") || feedHost == "47.251.82.23"
        guard isTwitterRoute || (isRSSHub && isTwitterStatus) else { return nil }

        return ArticleExtractor.content(from: rawHTML, baseURL: entry.url)
    }

    @discardableResult
    public func saveLLMConfiguration(_ configuration: LLMConfiguration, apiKey: String) -> LocalAPIKeyStore.Storage {
        let storage = LocalAPIKeyStore.saveAPIKey(apiKey)
        database.llmConfiguration = configuration
        persist()
        return storage
    }

    public func loadAPIKey() -> String { LocalAPIKeyStore.loadAPIKey() }

    public func testLLM(configuration: LLMConfiguration, apiKey: String) async throws {
        try await llm.test(configuration: configuration, apiKey: apiKey)
    }

    public func setICloudSyncEnabled(_ enabled: Bool) {
        isICloudSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "PaperRss.iCloudSyncEnabled")
        iCloudSyncStatus = enabled ? "等待同步" : "未启用"
        if enabled { scheduleICloudSync() }
    }

    public func syncICloud() async {
        guard isICloudSyncEnabled else { return }
        do {
            let remote = try await CloudSyncService.shared.synchronize(CloudLibrary.from(database))
            apply(cloud: remote)
            persist(scheduleICloud: false)
            iCloudSyncStatus = "上次同步：\(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            iCloudSyncStatus = "同步失败：\(error.localizedDescription)"
        }
    }

    public func generateSummary(entry: Entry, text: String, force: Bool = false) async {
        let configuration = database.llmConfiguration
        let hash = text.stableDigest
        if !force, database.artifacts.contains(where: {
            $0.entryID == entry.id
                && $0.kind == .summary
                && $0.contentHash == hash
                && $0.model == configuration.model
                && !$0.isDeleted
                && $0.isComplete
        }) { return }
        guard activeAIRequest == nil else {
            lastError = "已有 AI 任务正在进行，请等待它完成后再试。"
            return
        }

        activeAIRequest = AIRequestStatus(entryID: entry.id, kind: .summary, phase: .loadingLocalConfiguration)
        defer { activeAIRequest = nil }
        let apiKey = loadAPIKey()
        if configuration.usesDeepSeekAPI && apiKey.isEmpty {
            lastError = "尚未设置 DeepSeek API Key。请在 AI 配置中粘贴并保存；它只保存在此 Mac 的本地应用配置中。"
            return
        }

        activeAIRequest = AIRequestStatus(entryID: entry.id, kind: .summary, phase: .generating)
        let artifact = AIArtifact(
            entryID: entry.id,
            kind: .summary,
            contentHash: hash,
            model: configuration.model,
            targetLanguage: configuration.targetLanguage
        )
        let artifactID = artifact.id
        database.artifacts.removeAll { $0.entryID == entry.id && $0.kind == .summary && !$0.isComplete }
        database.artifacts.append(artifact)
        persist()
        do {
            let result = try await llm.summary(
                text: text,
                configuration: configuration,
                apiKey: apiKey,
                onDelta: { delta in
                    await MainActor.run {
                        if let index = self.database.artifacts.firstIndex(where: { $0.id == artifactID }) {
                            self.database.artifacts[index].content += delta
                            self.objectWillChange.send()
                        }
                    }
                }
            )
            completeArtifact(id: artifactID, content: result)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func explainSelection(
        entry: Entry,
        selection: String,
        localContext: String,
        articleText: String,
        selectionAnchor: AISelectionAnchor? = nil,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let configuration = database.llmConfiguration
        let promptVersion = 4
        let articleHash = articleText.stableDigest
        let normalizedSelection = selection.paperRssNormalizedWhitespace
        let normalizedLocalContext = localContext.paperRssNormalizedWhitespace
        let explanationHash = [
            articleHash,
            normalizedSelection.stableDigest,
            normalizedLocalContext.stableDigest,
            configuration.model,
            configuration.targetLanguage,
            String(promptVersion)
        ].joined(separator: "|").stableDigest

        if let cached = database.artifacts
            .filter({
                $0.entryID == entry.id
                    && $0.kind == .selectionExplanation
                    && $0.contentHash == explanationHash
                    && $0.model == configuration.model
                    && $0.targetLanguage == configuration.targetLanguage
                    && $0.promptVersion == promptVersion
                    && $0.isComplete
                    && !$0.isDeleted
            })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first {
            if let index = database.artifacts.firstIndex(where: { $0.id == cached.id }),
               database.artifacts[index].selectionText == nil || database.artifacts[index].selectionAnchor == nil {
                database.artifacts[index].selectionText = normalizedSelection
                database.artifacts[index].selectionArticleHash = articleHash
                database.artifacts[index].selectionAnchor = selectionAnchor
                database.artifacts[index].updatedAt = .now
                persist()
            }
            return cached.content
        }

        guard activeAIRequest == nil else { throw LLMServiceError.requestInProgress }

        activeAIRequest = AIRequestStatus(
            entryID: entry.id,
            kind: .selectionExplanation,
            phase: .loadingLocalConfiguration
        )
        defer { activeAIRequest = nil }

        let apiKey = loadAPIKey()
        if configuration.usesDeepSeekAPI && apiKey.isEmpty {
            throw LLMServiceError.missingAPIKey
        }

        activeAIRequest = AIRequestStatus(
            entryID: entry.id,
            kind: .selectionExplanation,
            phase: .generating
        )

        let articleContext: String
        if let cachedContext = database.artifacts
            .filter({
                $0.entryID == entry.id
                    && $0.kind == .articleContext
                    && $0.contentHash == articleHash
                    && $0.model == configuration.model
                    && $0.targetLanguage == configuration.targetLanguage
                    && $0.promptVersion == promptVersion
                    && $0.isComplete
                    && !$0.isDeleted
            })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first {
            articleContext = cachedContext.content
        } else {
            // Keep the first explanation to one network round trip. The old
            // path generated an AI context memo and only then asked for the
            // explanation, which made the first visible answer wait for two
            // sequential requests. This deterministic excerpt preserves the
            // article opening, the selected passage's neighborhood, and the
            // ending without spending another request; it is cached locally
            // and reused for later selections in the same article.
            articleContext = ArticleChunker.contextualArticle(
                articleText,
                around: "\(selection)\n\n\(localContext)",
                maximumCharacters: 24_000
            )
            database.artifacts.append(
                AIArtifact(
                    entryID: entry.id,
                    kind: .articleContext,
                    contentHash: articleHash,
                    model: configuration.model,
                    targetLanguage: configuration.targetLanguage,
                    promptVersion: promptVersion,
                    content: articleContext,
                    isComplete: true
                )
            )
            persist()
        }

        let result = try await llm.explainSelection(
            selection: selection,
            localContext: localContext,
            articleContext: articleContext,
            configuration: configuration,
            apiKey: apiKey,
            onDelta: onDelta
        )
        try Task.checkCancellation()
        database.artifacts.append(
            AIArtifact(
                entryID: entry.id,
                kind: .selectionExplanation,
                contentHash: explanationHash,
                model: configuration.model,
                targetLanguage: configuration.targetLanguage,
                promptVersion: promptVersion,
                content: result,
                selectionText: normalizedSelection,
                selectionArticleHash: articleHash,
                selectionAnchor: selectionAnchor,
                isComplete: true
            )
        )
        persist()
        return result
    }

    /// Translates only the current selection.  Selection translation shares
    /// the same content-addressed translation memory as lazy bilingual reading,
    /// so revisiting a sentence is an in-memory/local hit and never sends the
    /// same text to the provider twice for the same model and language.
    public func translateSelection(
        entry: Entry,
        selection: String,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let configuration = database.llmConfiguration
        let normalizedSelection = selection.paperRssNormalizedWhitespace
        guard !normalizedSelection.isEmpty else { throw LLMServiceError.emptyResponse }

        if let cached = cachedTranslation(for: normalizedSelection, configuration: configuration) {
            return cached
        }
        guard activeAIRequest == nil else { throw LLMServiceError.requestInProgress }

        activeAIRequest = AIRequestStatus(entryID: entry.id, kind: .translation, phase: .loadingLocalConfiguration)
        defer { activeAIRequest = nil }
        let apiKey = loadAPIKey()
        if configuration.usesDeepSeekAPI && apiKey.isEmpty {
            throw LLMServiceError.missingAPIKey
        }
        activeAIRequest = AIRequestStatus(entryID: entry.id, kind: .translation, phase: .generating)

        let result = try await llm.translate(
            paragraph: normalizedSelection,
            configuration: configuration,
            apiKey: apiKey,
            onDelta: onDelta
        )
        try Task.checkCancellation()
        cacheTranslations(
            [BilingualSegment(id: "selection-\(normalizedSelection.stableDigest)", original: normalizedSelection, translation: result)],
            configuration: configuration,
            persistChanges: true
        )
        return result
    }

    /// Translates only the reader blocks requested by the viewport observer.
    /// Completed blocks are persisted independently, so scrolling away,
    /// cancellation, or an API failure never discards earlier work.
    public func translateBilingualParagraphs(
        entry: Entry,
        text: String,
        paragraphs: [ReaderParagraph],
        paragraphIDs: [String],
        onDelta: (@Sendable (String, String) async -> Void)? = nil
    ) async {
        let configuration = database.llmConfiguration
        let hash = text.stableDigest
        guard !paragraphs.isEmpty else {
            lastError = "没有可翻译的正文。"
            return
        }

        let paragraphsByID = Dictionary(uniqueKeysWithValues: paragraphs.map { ($0.id, $0) })
        let requestedParagraphs = paragraphIDs
            .reduce(into: [ReaderParagraph]()) { result, id in
                guard let paragraph = paragraphsByID[id],
                      !result.contains(where: { $0.id == id }) else { return }
                result.append(paragraph)
            }
        guard !requestedParagraphs.isEmpty else { return }

        let existingSegments = bilingualArtifact(for: entry, text: text)?.segments ?? []
        let validExistingIDs = Set(existingSegments.compactMap { segment -> String? in
            guard let paragraph = paragraphsByID[segment.id],
                  paragraph.original.isSameReaderParagraph(as: segment.original) else { return nil }
            return segment.id
        })
        let missingParagraphs = requestedParagraphs.filter { !validExistingIDs.contains($0.id) }
        let cachedParagraphs = missingParagraphs.compactMap { paragraph -> BilingualSegment? in
            guard let translation = cachedTranslation(for: paragraph.original, configuration: configuration) else { return nil }
            return BilingualSegment(id: paragraph.id, original: paragraph.original, translation: translation)
        }
        let cachedIDs = Set(cachedParagraphs.map(\.id))
        let pendingParagraphs = missingParagraphs.filter { !cachedIDs.contains($0.id) }
        let artifactID: UUID
        if let existing = bilingualArtifact(for: entry, text: text) {
            artifactID = existing.id
            if let index = database.artifacts.firstIndex(where: { $0.id == artifactID }) {
                database.artifacts[index].isComplete = false
            }
        } else {
            let artifact = AIArtifact(entryID: entry.id, kind: .bilingual, contentHash: hash, model: configuration.model, targetLanguage: configuration.targetLanguage)
            artifactID = artifact.id
            database.artifacts.append(artifact)
        }

        let paragraphOrder = Dictionary(uniqueKeysWithValues: paragraphs.enumerated().map { ($0.element.id, $0.offset) })
        if !cachedParagraphs.isEmpty {
            upsertSegments(cachedParagraphs, to: artifactID, paragraphOrder: paragraphOrder, persistChanges: false)
            persist()
        }
        guard !pendingParagraphs.isEmpty else { return }
        guard activeAIRequest == nil else { return }

        activeAIRequest = AIRequestStatus(entryID: entry.id, kind: .bilingual, phase: .loadingLocalConfiguration)
        defer { activeAIRequest = nil }
        let apiKey = loadAPIKey()
        if configuration.usesDeepSeekAPI && apiKey.isEmpty {
            lastError = "尚未设置 DeepSeek API Key。请在 AI 配置中粘贴并保存；它只保存在此 Mac 的本地应用配置中。"
            return
        }

        activeAIRequest = AIRequestStatus(entryID: entry.id, kind: .bilingual, phase: .generating)
        let service = llm
        do {
            // The viewport path opts into one paragraph per streamed request.
            // This lets the first visible translation appear immediately and
            // keeps each paragraph independently cacheable. Batch JSON remains
            // available for non-interactive callers that do not need deltas.
            if let onDelta {
                for paragraph in pendingParagraphs {
                    let translation = try await service.translate(
                        paragraph: paragraph.original,
                        configuration: configuration,
                        apiKey: apiKey,
                        onDelta: { delta in
                            await onDelta(paragraph.id, delta)
                        }
                    )
                    let segment = BilingualSegment(id: paragraph.id, original: paragraph.original, translation: translation)
                    upsertSegments([segment], to: artifactID, paragraphOrder: paragraphOrder, persistChanges: false)
                    cacheTranslations([segment], configuration: configuration, persistChanges: false)
                    persist()
                }
                let artifact = database.artifacts.first(where: { $0.id == artifactID })
                let translatedIDs = Set((artifact?.segments ?? []).map(\.id))
                if translatedIDs.isSuperset(of: Set(paragraphs.map(\.id))) {
                    completeArtifact(id: artifactID, content: artifact?.segments.map(\.translation).joined(separator: "\n\n") ?? "")
                }
                return
            }
            for batch in translationBatches(from: pendingParagraphs) {
                let translations: [String]
                do {
                    translations = try await service.translateBatch(
                        paragraphs: batch.map(\.original),
                        configuration: configuration,
                        apiKey: apiKey
                    )
                } catch LLMServiceError.invalidResponse {
                    // A small number of OpenAI-compatible endpoints ignore the
                    // JSON-only instruction. Preserve correctness and progress
                    // by retrying only this batch as independently cached units.
                    translations = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                        for (index, paragraph) in batch.enumerated() {
                            group.addTask {
                                (index, try await service.translate(paragraph: paragraph.original, configuration: configuration, apiKey: apiKey))
                            }
                        }
                        var ordered = Array(repeating: "", count: batch.count)
                        for try await (index, translation) in group { ordered[index] = translation }
                        return ordered
                    }
                }

                let translatedSegments = zip(batch, translations).map {
                    BilingualSegment(id: $0.0.id, original: $0.0.original, translation: $0.1)
                }
                upsertSegments(translatedSegments, to: artifactID, paragraphOrder: paragraphOrder, persistChanges: false)
                cacheTranslations(translatedSegments, configuration: configuration, persistChanges: false)
                persist()
            }

            let artifact = database.artifacts.first(where: { $0.id == artifactID })
            let translatedIDs = Set((artifact?.segments ?? []).compactMap { segment -> String? in
                guard let paragraph = paragraphsByID[segment.id],
                      paragraph.original.isSameReaderParagraph(as: segment.original) else { return nil }
                return segment.id
            })
            if translatedIDs.count == paragraphs.count {
                let content = artifact?.segments.map(\.translation).joined(separator: "\n\n") ?? ""
                completeArtifact(id: artifactID, content: content)
            }
        } catch {
            // Existing paragraphs stay usable. A later viewport report retries
            // only the IDs that are still missing.
            lastError = error.localizedDescription
        }
    }

    public func dismissError() { lastError = nil }

    private func merge(entries parsed: [ParsedFeedEntry], into feedID: UUID) {
        // `firstIndex(where:)` for every incoming item made a refresh O(n*m).
        // A feed refresh can finish while the user is clicking the sidebar, so
        // that main-actor work showed up as an apparently slow selection.
        var entryIndexByID = Dictionary(
            uniqueKeysWithValues: database.entries.indices.map { (database.entries[$0].id, $0) }
        )
        entryIndexByID.reserveCapacity(database.entries.count + parsed.count)

        for incoming in parsed {
            let id = "\(feedID.uuidString)|\(incoming.id)".stableDigest
            let summary = incoming.summary.needsPlainTextNormalization ? incoming.summary.plainText : incoming.summary
            if let index = entryIndexByID[id] {
                let state = database.entries[index]
                let readingState = database.readingStates[id] ?? ReadingState(entryID: id, isRead: state.isRead, isStarred: state.isStarred, updatedAt: state.updatedAt)
                database.entries[index] = Entry(id: id, feedID: feedID, title: incoming.title, author: incoming.author, url: incoming.url, publishedAt: incoming.publishedAt, summary: summary, contentHTML: incoming.contentHTML, isRead: readingState.isRead, isStarred: readingState.isStarred, updatedAt: readingState.updatedAt)
            } else {
                let readingState = database.readingStates[id]
                database.entries.append(Entry(id: id, feedID: feedID, title: incoming.title, author: incoming.author, url: incoming.url, publishedAt: incoming.publishedAt, summary: summary, contentHTML: incoming.contentHTML, isRead: readingState?.isRead ?? false, isStarred: readingState?.isStarred ?? false, updatedAt: readingState?.updatedAt ?? .now))
                entryIndexByID[id] = database.entries.count - 1
            }
        }
    }

    private func update(entryID: String, operation: (inout Entry) -> Void) {
        guard let index = database.entries.firstIndex(where: { $0.id == entryID }) else { return }
        operation(&database.entries[index])
        let entry = database.entries[index]
        database.readingStates[entryID] = ReadingState(entryID: entryID, isRead: entry.isRead, isStarred: entry.isStarred, updatedAt: entry.updatedAt)
        rebuildEntryIndex()
        persist()
    }

    private func upsertSegments(
        _ newSegments: [BilingualSegment],
        to artifactID: UUID,
        paragraphOrder: [String: Int],
        persistChanges: Bool
    ) {
        guard let index = database.artifacts.firstIndex(where: { $0.id == artifactID }) else { return }
        for segment in newSegments {
            if let segmentIndex = database.artifacts[index].segments.firstIndex(where: { $0.id == segment.id }) {
                database.artifacts[index].segments[segmentIndex] = segment
            } else {
                database.artifacts[index].segments.append(segment)
            }
        }
        database.artifacts[index].segments.sort {
            paragraphOrder[$0.id, default: .max] < paragraphOrder[$1.id, default: .max]
        }
        database.artifacts[index].content = database.artifacts[index].segments
            .map(\.translation)
            .joined(separator: "\n\n")
        database.artifacts[index].updatedAt = .now
        if persistChanges { persist() }
    }

    /// Translation memory is content-addressed instead of article-addressed.
    /// A recurring RSS disclaimer, quote, or syndicated paragraph therefore
    /// reuses its prior translation across articles and feeds. We store it as a
    /// normal AI artifact, so it also follows the app's existing iCloud result
    /// synchronization without ever including the API key.
    private func cachedTranslation(for source: String, configuration: LLMConfiguration) -> String? {
        let key = translationMemoryKey(for: source, configuration: configuration)
        let entryID = translationMemoryEntryID(for: key)
        return database.artifacts
            .filter {
                $0.entryID == entryID
                    && $0.kind == .translation
                    && $0.contentHash == key
                    && $0.model == configuration.model
                    && $0.targetLanguage == configuration.targetLanguage
                    && $0.promptVersion == Self.translationPromptVersion
                    && $0.isComplete
                    && !$0.isDeleted
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .content
    }

    private func cacheTranslations(_ segments: [BilingualSegment], configuration: LLMConfiguration, persistChanges: Bool) {
        for segment in segments {
            let key = translationMemoryKey(for: segment.original, configuration: configuration)
            let entryID = translationMemoryEntryID(for: key)
            if let index = database.artifacts.firstIndex(where: {
                $0.entryID == entryID && $0.kind == .translation && $0.contentHash == key
            }) {
                database.artifacts[index].content = segment.translation
                database.artifacts[index].model = configuration.model
                database.artifacts[index].targetLanguage = configuration.targetLanguage
                database.artifacts[index].promptVersion = Self.translationPromptVersion
                database.artifacts[index].isComplete = true
                database.artifacts[index].isDeleted = false
                database.artifacts[index].updatedAt = .now
            } else {
                database.artifacts.append(
                    AIArtifact(
                        entryID: entryID,
                        kind: .translation,
                        contentHash: key,
                        model: configuration.model,
                        targetLanguage: configuration.targetLanguage,
                        promptVersion: Self.translationPromptVersion,
                        content: segment.translation,
                        isComplete: true
                    )
                )
            }
        }

        // A personal reader rarely needs more than this, and keeping the memory
        // bounded prevents long-lived JSON/CloudKit payloads from slowing every
        // normal library write.
        let memoryIndexes = database.artifacts.indices.filter {
            database.artifacts[$0].entryID.hasPrefix(Self.translationMemoryEntryPrefix)
        }
        if memoryIndexes.count > Self.maximumTranslationMemoryEntries {
            let surplus = memoryIndexes
                .sorted { database.artifacts[$0].updatedAt < database.artifacts[$1].updatedAt }
                .prefix(memoryIndexes.count - Self.maximumTranslationMemoryEntries)
            let IDs = Set(surplus.map { database.artifacts[$0].id })
            database.artifacts.removeAll { IDs.contains($0.id) }
        }
        if persistChanges { persist() }
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
    private static let maximumTranslationMemoryEntries = 2_000
    private static let maximumParagraphsPerTranslationBatch = 4
    // Read Frog's production queue defaults to roughly 1,000 characters and
    // four blocks per batch.  A larger 7K batch reduces request count, but it
    // increases time-to-first-translation because the model must finish one
    // large JSON response before any visible paragraph can be inserted.
    private static let maximumCharactersPerTranslationBatch = 1_200

    private func completeArtifact(id: UUID, content: String) {
        guard let index = database.artifacts.firstIndex(where: { $0.id == id }) else { return }
        database.artifacts[index].content = content
        database.artifacts[index].isComplete = true
        database.artifacts[index].updatedAt = .now
        persist()
    }

    private func apply(cloud remote: CloudLibrary) {
        let merged = CloudLibrary.merged(local: CloudLibrary.from(database), remote: remote)
        database.feeds = merged.feeds
        database.readingStates = merged.readingStates
        database.artifacts = merged.artifacts

        // Feed tombstones are synchronized, while article bodies are local to
        // each device. Apply the same cascade on every device so an iPhone does
        // not retain articles after their feed was deleted on the Mac.
        let deletedFeedIDs = Set(database.feeds.lazy.filter(\.isDeleted).map(\.id))
        if !deletedFeedIDs.isEmpty {
            let deletedEntryIDs = Set(
                database.entries.lazy
                    .filter { deletedFeedIDs.contains($0.feedID) }
                    .map(\.id)
            )
            database.entries.removeAll { deletedEntryIDs.contains($0.id) }
            database.articleCaches = database.articleCaches.filter { !deletedEntryIDs.contains($0.key) }
            database.readingStates = database.readingStates.filter { !deletedEntryIDs.contains($0.key) }
        }

        for index in database.entries.indices {
            if let state = merged.readingStates[database.entries[index].id] {
                database.entries[index].isRead = state.isRead
                database.entries[index].isStarred = state.isStarred
                database.entries[index].updatedAt = state.updatedAt
            }
        }
        rebuildEntryIndex()
    }

    private func persist(scheduleICloud: Bool = true) {
        // Encoding a multi-megabyte offline library on the main actor stalls
        // selection and scrolling. The revisioned actor serializes snapshots
        // off-main and drops an older write if tasks arrive out of order.
        persistenceRevision += 1
        let revision = persistenceRevision
        let snapshot = database
        let url = persistenceURL
        let writer = persistenceWriter
        Task.detached(priority: .utility) {
            await writer.write(snapshot, to: url, revision: revision)
        }
        if scheduleICloud { scheduleICloudSync() }
    }

    private func rebuildEntryIndex() {
        entryIndex = EntryLibraryIndex(entries: database.entries, feeds: database.feeds)
    }

    private func scheduleICloudSync() {
        guard isICloudSyncEnabled else { return }
        iCloudSyncTask?.cancel()
        iCloudSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncICloud()
        }
    }

    private static func load(from url: URL) -> AppDatabase? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.paperRss.decode(AppDatabase.self, from: data)
    }

    private func normalizedURL(_ text: String) -> URL? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = candidate.contains("://") ? candidate : "https://\(candidate)"
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

private actor DatabasePersistenceWriter {
    private var latestRevision = 0

    func write(_ database: AppDatabase, to url: URL, revision: Int) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder.paperRss.encode(database) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static let paperRss: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let paperRss: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }

    var needsPlainTextNormalization: Bool {
        range(of: #"(?is)<\s*/?\s*[a-z][^>]*>"#, options: .regularExpression) != nil
            || contains("&nbsp;")
            || contains("&amp;")
            || contains("&lt;")
            || contains("&gt;")
            || contains("&quot;")
    }

    var paperRssNormalizedWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
