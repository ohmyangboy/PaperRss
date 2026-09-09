import Foundation
import GRDB

/// 后台订阅源真实图标探测器（对标 NetNewsWire FeedIconDownloader / FaviconDownloader）
///
/// 当远端账号（如 FreshRSS）未提供有效真实图标或仅提供了服务端占位图（/f.php）时，
/// 该探测器在后台轻量探测源的 RSS/Atom 声明（提取 <channel><image><url> 或 <icon>），
/// 探测成功后回写数据库并触发 `FeedIconStore.warmUp`，定向刷新侧栏行。
public actor FeedIconProbeService {
    public static let shared = FeedIconProbeService()

    private var inFlightURLs = Set<URL>()
    private var probedURLs = Set<URL>()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 探测指定 Feed 列表中的无图源
    public func probeMissingIcons(
        for feeds: [Feed],
        database: LibraryDatabase,
        iconStore: FeedIconStore? = nil
    ) {
        for feed in feeds {
            // 已有非占位图真实图标，跳过探测
            if let stored = feed.storedIconURL, !stored.absoluteString.lowercased().contains("f.php") {
                continue
            }
            let feedURL = feed.feedURL
            guard !inFlightURLs.contains(feedURL), !probedURLs.contains(feedURL) else { continue }
            inFlightURLs.insert(feedURL)

            Task.detached(priority: .utility) { [weak self, feedURL, feedID = feed.id] in
                guard let self else { return }
                let realIconURL = await self.probeFeedIcon(feedURL: feedURL)
                await self.finishProbe(
                    feedURL: feedURL,
                    feedID: feedID,
                    realIconURL: realIconURL,
                    database: database,
                    iconStore: iconStore
                )
            }
        }
    }

    private func finishProbe(
        feedURL: URL,
        feedID: UUID,
        realIconURL: URL?,
        database: LibraryDatabase,
        iconStore: FeedIconStore?
    ) async {
        inFlightURLs.remove(feedURL)
        probedURLs.insert(feedURL)

        guard let realIconURL, !realIconURL.absoluteString.lowercased().contains("f.php") else { return }

        // 回写数据库中所有匹配此 feed_url 的订阅记录（跨账号共享）
        let urlString = realIconURL.absoluteString
        let feedURLString = feedURL.absoluteString
        _ = try? await database.writeAsync { db in
            try db.execute(sql: """
                UPDATE feeds
                SET stored_icon_url = ?
                WHERE feed_url = ? AND (stored_icon_url IS NULL OR stored_icon_url = '' OR stored_icon_url LIKE '%f.php%');
            """, arguments: [urlString, feedURLString])
        }

        // 主线程通知 iconStore 预热
        await MainActor.run {
            iconStore?.warmUp(feedID: feedID, iconURL: realIconURL)
        }
    }

    /// 轻量读取 RSS/Atom XML 前 64KB 并解析 channel image
    private func probeFeedIcon(feedURL: URL) async -> URL? {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 10
        request.setValue("PaperRss/0.1 (+personal RSS reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/xml, text/xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let parsed = try FeedParser.parse(data: data, baseURL: feedURL)
            return parsed.iconURL
        } catch {
            return nil
        }
    }
}
