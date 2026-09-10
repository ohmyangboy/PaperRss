import Foundation
import GRDB

/// 后台订阅源真实图标探测器（对标 NetNewsWire FeedIconDownloader / FaviconDownloader / FeedIconURLTable）
///
/// 当远端账号（如 FreshRSS）未提供有效真实图标或仅提供了服务端占位图（/f.php）时，
/// 该探测器在后台受控队列中轻量探测源的 RSS/Atom/JSON 声明（提取 <channel><image><url>、<icon> 或 JSON icon/favicon），
/// 探测成功后回写数据库并触发 `FeedIconStore.warmUp`，定向刷新侧栏行。
///
/// 关键防护设计：
/// 1. 并发上限与队列化：严格限制最大并发任务数（默认 2），超额请求进入 FIFO 排队，绝不打满后台线程池；
/// 2. 轻量解析剪枝：专用 XML 探针只要遇到第一个 `<item>` / `<entry>` 即刻中止解析，绝不反序列化文章列表或提取 HTML，毫秒级退出；
/// 3. 持久化失败记忆：探测结果（无论成功或无图 nil）记录时间戳并落盘 `probe_cache.json`，在冷却期（5 天）内跨进程重启绝不重复发起无效网络探测；
/// 4. 彻底解耦高频投影：不再绑定于 `reloadState` 同步周期，仅由受控防抖调度器延时发起。
public actor FeedIconProbeService {
    public static let shared = FeedIconProbeService()

    /// 冷却期：探测过的源（特别是无图源）在 5 天内不再重复发起 I/O（对齐 NNW）
    public static let probeRetryInterval: TimeInterval = 5 * 24 * 3600
    /// 缓存保留期：超期记录就地清理
    public static let probeRetentionInterval: TimeInterval = 30 * 24 * 3600

    private struct ProbeRequest: Sendable {
        let feedURL: URL
        let feedID: UUID
        let database: LibraryDatabase
        let iconStore: FeedIconStore?
        let onIconDiscovered: (@MainActor @Sendable ([UUID], URL) -> Void)?
    }

    private var inFlightURLs = Set<URL>()
    private var pendingQueue: [ProbeRequest] = []
    private var pendingURLs = Set<URL>()
    private var probedAt: [String: Date] = [:]

    private let maxConcurrentProbes: Int
    private var activeProbeCount = 0
    private let session: URLSession
    private let cacheFileURL: URL
    private var persistTask: Task<Void, Never>?

    public init(
        cacheFileURL: URL? = nil,
        session: URLSession? = nil,
        maxConcurrentProbes: Int = 2
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: config)
        }
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
        let resolvedURL: URL
        if let cacheFileURL {
            resolvedURL = cacheFileURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = caches.appendingPathComponent("FeedIcons", isDirectory: true)
            resolvedURL = dir.appendingPathComponent("probe_cache.json")
        }
        let parentDir = resolvedURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        self.cacheFileURL = resolvedURL
        self.probedAt = Self.loadCacheFromDisk(at: resolvedURL)
    }

    deinit {
        persistTask?.cancel()
    }

    /// 探测指定 Feed 列表中的无图源
    ///
    /// - Parameters:
    ///   - feeds: 候选订阅源
    ///   - database: 资料库
    ///   - iconStore: 图标缓存服务
    ///   - force: 是否强制绕过 5 天冷却期（如用户手动强制刷新场景）
    ///   - onIconDiscovered: 成功探测到真实图标时的回调（通知在内存更新订阅源，定向触发侧栏行重绘）
    public func probeMissingIcons(
        for feeds: [Feed],
        database: LibraryDatabase,
        iconStore: FeedIconStore? = nil,
        force: Bool = false,
        onIconDiscovered: (@MainActor @Sendable ([UUID], URL) -> Void)? = nil
    ) {
        for feed in feeds {
            // 已有非占位图真实图标，跳过探测
            if let stored = feed.storedIconURL,
               !stored.absoluteString.isEmpty,
               !stored.absoluteString.lowercased().contains("f.php") {
                continue
            }
            let feedURL = feed.feedURL
            guard !inFlightURLs.contains(feedURL),
                  !pendingURLs.contains(feedURL),
                  (force || !isBlockedByCooldown(feedURL))
            else { continue }

            pendingQueue.append(ProbeRequest(
                feedURL: feedURL,
                feedID: feed.id,
                database: database,
                iconStore: iconStore,
                onIconDiscovered: onIconDiscovered
            ))
            pendingURLs.insert(feedURL)
        }

        pumpProbes()
    }

    /// 驱动并发池任务
    private func pumpProbes() {
        while activeProbeCount < maxConcurrentProbes && !pendingQueue.isEmpty {
            let request = pendingQueue.removeFirst()
            let feedURL = request.feedURL
            pendingURLs.remove(feedURL)

            guard !inFlightURLs.contains(feedURL) else { continue }

            activeProbeCount += 1
            inFlightURLs.insert(feedURL)

            Task.detached(priority: .utility) { [weak self, request] in
                guard let self else { return }
                let realIconURL = await self.probeFeedIcon(feedURL: request.feedURL)
                await self.finishProbe(
                    request: request,
                    realIconURL: realIconURL
                )
            }
        }
    }

    private func finishProbe(
        request: ProbeRequest,
        realIconURL: URL?
    ) async {
        activeProbeCount = max(0, activeProbeCount - 1)
        inFlightURLs.remove(request.feedURL)
        recordProbed(feedURL: request.feedURL)

        defer {
            pumpProbes()
        }

        guard let realIconURL, !realIconURL.absoluteString.lowercased().contains("f.php") else { return }

        // 回写数据库中所有匹配此 feed_url 的订阅记录（跨账号共享）
        let urlString = realIconURL.absoluteString
        let feedURLString = request.feedURL.absoluteString
        _ = try? await request.database.writeAsync { db in
            try db.execute(sql: """
                UPDATE feeds
                SET stored_icon_url = ?
                WHERE feed_url = ? AND (stored_icon_url IS NULL OR stored_icon_url = '' OR stored_icon_url LIKE '%f.php%');
            """, arguments: [urlString, feedURLString])
        }

        // 查出该 feed_url 下所有关联的 feedID，在主线程同步触发预热更新与应用内订阅源更新
        let affectedFeedIDs = (try? await request.database.readAsync { db -> [UUID] in
            try String.fetchAll(db, sql: "SELECT id FROM feeds WHERE feed_url = ?", arguments: [feedURLString])
                .compactMap(UUID.init(uuidString:))
        }) ?? [request.feedID]

        await MainActor.run {
            for id in affectedFeedIDs {
                request.iconStore?.warmUp(feedID: id, iconURL: realIconURL)
            }
            request.onIconDiscovered?(affectedFeedIDs, realIconURL)
        }
    }

    /// 轻量读取 RSS/Atom/JSON 并极速提取图标（绝不解析历史文章）
    /// nonisolated：完全在后台协同线程池执行网络与流式解析，绝不占用或阻塞 Actor 调度循环
    private nonisolated func probeFeedIcon(feedURL: URL) async -> URL? {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 8
        request.setValue("PaperRss/0.1 (+personal RSS reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/xml, text/xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return Self.extractIcon(from: data, baseURL: feedURL)
        } catch {
            return nil
        }
    }

    // MARK: - 极速轻量图标提取器 (Lightweight Icon Extractor)

    /// 从 Feed 数据中提取图标 URL，毫秒级快速剪枝
    public nonisolated static func extractIcon(from data: Data, baseURL: URL) -> URL? {
        let trimmed = data.drop(while: { $0 == 9 || $0 == 10 || $0 == 13 || $0 == 32 })
        if trimmed.first == UInt8(ascii: "{") {
            return extractJSONIcon(from: data, baseURL: baseURL)
        }
        return extractXMLIcon(from: data, baseURL: baseURL)
    }

    private nonisolated static func extractJSONIcon(from data: Data, baseURL: URL) -> URL? {
        struct LightweightJSONFeed: Decodable {
            var icon: String?
            var favicon: String?
        }
        guard let decoded = try? JSONDecoder().decode(LightweightJSONFeed.self, from: data) else {
            return nil
        }
        let raw = decoded.icon ?? decoded.favicon
        return raw.flatMap { resolveCandidateURL($0, baseURL: baseURL) }
    }

    private nonisolated static func extractXMLIcon(from data: Data, baseURL: URL) -> URL? {
        let delegate = FeedIconProbeXMLDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.extractedIconURL
    }

    /// 统一校验并规范化候选图标 URL（过滤 f.php，支持相对路径与非法字符容错）
    public nonisolated static func resolveCandidateURL(_ raw: String, baseURL: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().contains("f.php") else { return nil }
        if let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil {
            return url
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil {
            return url
        }
        return nil
    }

    // MARK: - 持久化失败记忆与冷却窗

    public func isBlockedByCooldown(_ url: URL) -> Bool {
        guard let date = probedAt[url.absoluteString] else { return false }
        return Date().timeIntervalSince(date) < Self.probeRetryInterval
    }

    private func recordProbed(feedURL: URL) {
        probedAt[feedURL.absoluteString] = Date()
        scheduleCachePersist()
    }

    private struct ProbeCacheFile: Codable {
        var probedAt: [String: Double] = [:]
    }

    private nonisolated static func loadCacheFromDisk(at url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ProbeCacheFile.self, from: data)
        else { return [:] }

        let now = Date()
        return file.probedAt.reduce(into: [String: Date]()) { result, pair in
            let date = Date(timeIntervalSince1970: pair.value)
            if now.timeIntervalSince(date) < probeRetentionInterval {
                result[pair.key] = date
            }
        }
    }

    private func scheduleCachePersist() {
        persistTask?.cancel()
        let snapshot = probedAt.mapValues { $0.timeIntervalSince1970 }
        let fileURL = cacheFileURL
        persistTask = Task(priority: .utility) { [snapshot, fileURL] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms 轻度防抖
            guard !Task.isCancelled else { return }
            let file = ProbeCacheFile(probedAt: snapshot)
            if let data = try? JSONEncoder().encode(file) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// 测试辅助：立即强制落盘
    public func flushCacheForTesting() {
        persistTask?.cancel()
        persistTask = nil
        let file = ProbeCacheFile(probedAt: probedAt.mapValues { $0.timeIntervalSince1970 })
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }

    /// 清空探测记忆
    public func clearCache() {
        persistTask?.cancel()
        persistTask = nil
        probedAt.removeAll()
        inFlightURLs.removeAll()
        pendingQueue.removeAll()
        pendingURLs.removeAll()
        try? FileManager.default.removeItem(at: cacheFileURL)
    }
}

/// 专用于 RSS/Atom 图标提取的快速流式解析器
/// 遇到首个 <item> 或 <entry> 即刻 abortParsing()，绝不遍历文章
private final class FeedIconProbeXMLDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var inImageTag = false
    private var currentText = ""
    var extractedIconURL: URL?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private static func localName(of elementName: String) -> String {
        elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        let local = Self.localName(of: elementName)
        // 剪枝黄金法则：只要开始进入文章节点，feed 级元数据已经宣告结束，直接终止解析！
        if local == "item" || local == "entry" {
            parser.abortParsing()
            return
        }
        if local == "image" {
            inImageTag = true
            // 兼容属性声明：<image href="..." />、<itunes:image href="..." /> 或 <image rdf:resource="..." />
            let attrCandidate = attributeDict["href"]
                ?? attributeDict["url"]
                ?? attributeDict["rdf:resource"]
                ?? attributeDict["resource"]
            if let attrCandidate,
               let candidate = FeedIconProbeService.resolveCandidateURL(attrCandidate, baseURL: baseURL) {
                extractedIconURL = candidate
                parser.abortParsing()
                return
            }
        }
        // 兼容 Atom <link rel="icon" href="..." /> / <link rel="apple-touch-icon" href="..." />
        if local == "link", let rel = attributeDict["rel"]?.lowercased(),
           ["icon", "shortcut icon", "apple-touch-icon", "fluid-icon"].contains(rel),
           let href = attributeDict["href"],
           let candidate = FeedIconProbeService.resolveCandidateURL(href, baseURL: baseURL) {
            extractedIconURL = candidate
            parser.abortParsing()
            return
        }

        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        currentText += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = Self.localName(of: elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if (local == "icon" || local == "logo" || (local == "url" && inImageTag)),
           !text.isEmpty,
           extractedIconURL == nil {
            if let candidate = FeedIconProbeService.resolveCandidateURL(text, baseURL: baseURL) {
                extractedIconURL = candidate
                // 成功提取图标，立刻中止解析
                parser.abortParsing()
                return
            }
        }

        if local == "image" {
            inImageTag = false
        }
        currentText = ""
    }
}
