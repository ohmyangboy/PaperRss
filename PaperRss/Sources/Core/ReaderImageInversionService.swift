import Foundation

/// 深色纸面下按需判定正文插图是否需要反相。
///
/// 与 `ArticleThumbnailStore` 同构的受限网络管线：每篇最多分析 `limit` 张、并发
/// ≤ `maximumConcurrent`、单图 ≤ `maximumBytes`，判定结果（含失败）按 URL 会话级
/// 缓存。任何失败都按「不反相」处理，不重试、不阻塞阅读（fail-open）。
///
/// 预算按「长技术长文」定档（colah 的 Visual Information Theory 一篇 55 张图）：
/// 12 张会让第 13 张之后的插图在深色纸面下保持不可读（issue #41 复现）。
/// 取字节走共享 `URLCache`，重复阅读与已上屏图片不产生额外流量。
public actor ReaderImageInversionService {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let shared = ReaderImageInversionService()

    /// 与 `DefaultArticlePageLoader` 同一字面量：部分图片 CDN 按 UA/Referer 防盗链。
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    private static let cacheLimit = 512

    private let loader: Loader
    private let maximumConcurrent: Int
    private let limit: Int
    private let maximumBytes: Int
    private var cache: [URL: Bool] = [:]
    private var cacheOrder: [URL] = []

    public init(
        loader: Loader? = nil,
        maximumConcurrent: Int = 4,
        limit: Int = 64,
        maximumBytes: Int = 8 * 1024 * 1024
    ) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.limit = max(0, limit)
        self.maximumBytes = max(0, maximumBytes)
        if let loader {
            self.loader = loader
        } else {
            // 共享 URLCache：重复阅读同一篇文章时判定命中缓存，不再取字节。
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 8
            let session = URLSession(configuration: configuration)
            self.loader = { request in try await session.data(for: request) }
        }
    }

    /// 按输入顺序返回需要反相的 URL；失败、超时、超限一律按「不反相」缓存。
    /// 装饰性小图（表情、头像）在候选筛选阶段剔除，不占预算。
    public func invertibleURLs(for urls: [URL], referer: URL?) async -> [URL] {
        guard limit > 0 else { return [] }
        var seen = Set<URL>()
        var candidates: [URL] = []
        for url in urls where seen.insert(url).inserted && !ReaderImageInversion.isDecorativeURL(url) {
            candidates.append(url)
            if candidates.count == limit { break }
        }
        guard !candidates.isEmpty else { return [] }

        var verdicts: [URL: Bool] = [:]
        var pending: [URL] = []
        for url in candidates {
            if let cached = cache[url] { verdicts[url] = cached } else { pending.append(url) }
        }
        if !pending.isEmpty {
            let resolved = await analyze(pending, referer: referer)
            // 取消（换篇）时不做缓存写入：中断的请求不代表图片的真实判定。
            if !Task.isCancelled {
                for (url, invertible) in resolved {
                    verdicts[url] = invertible
                    store(invertible, for: url)
                }
            }
        }
        return candidates.filter { verdicts[$0] == true }
    }

    /// 并发窗口 ≤ `maximumConcurrent`：先投满窗口，每完成一个补一个。
    private nonisolated func analyze(_ urls: [URL], referer: URL?) async -> [(URL, Bool)] {
        var results: [(URL, Bool)] = []
        results.reserveCapacity(urls.count)
        await withTaskGroup(of: (URL, Bool).self) { group in
            var iterator = urls.makeIterator()
            var inflight = 0
            while inflight < maximumConcurrent, let url = iterator.next() {
                group.addTask { (url, await self.fetchInvertible(url, referer: referer)) }
                inflight += 1
            }
            while let result = await group.next() {
                results.append(result)
                if let next = iterator.next() {
                    group.addTask { (next, await self.fetchInvertible(next, referer: referer)) }
                }
            }
        }
        return results
    }

    private nonisolated func fetchInvertible(_ url: URL, referer: URL?) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            if let referer {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }
            let (data, response) = try await loader(request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            guard http.expectedContentLength <= Int64(maximumBytes) else { return false }
            guard data.count <= maximumBytes else { return false }
            return ReaderImageInversion.shouldInvert(data: data, contentType: http.mimeType)
        } catch {
            return false
        }
    }

    private func store(_ invertible: Bool, for url: URL) {
        if cache[url] == nil {
            cacheOrder.append(url)
            if cacheOrder.count > Self.cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[url] = invertible
    }
}
