import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Feed 图标仓库：把"每次渲染现取的远程 URL"升级为"应用级同步可查的本地资源"。
///
/// 架构对标 NetNewsWire 的 IconImageCache / FaviconDownloader：
/// - `cachedImage(feedID:)` 是纯内存字典查询（主线程、同步、绝不触发 I/O），
///   视图首帧即可命中，从根本上消除 AsyncImage 加载期占位徽章的闪烁；
/// - `warmUp(feedID:iconURL:)` 按 内存 → 磁盘 → 网络 逐层回填，完成后经
///   `revision` 通知视图做一次替换；
/// - 图标字节持久化在 Caches 目录（可再生缓存，一 URL 一文件），索引与失败记录
///   在 init 时同步载入内存（体量 KB 级，无感知）；
/// - 非瞬时失败进入失败记忆（5 天重试窗），对永远拿不到图标的 feed 稳定显示
///   兜底徽章而非反复重试闪烁。
@MainActor
public final class FeedIconStore: ObservableObject {
    /// 图标变为可用时递增；订阅方据此在可用那一帧完成一次替换。
    @Published public private(set) var revision: UInt64 = 0

    private var memoryImages: [UUID: CGImage] = [:]
    /// 低内存 flush 后保留的最后已知图标，避免可见单元格被清空。
    private var lastKnownImages: [UUID: CGImage] = [:]
    /// 当前内存图标对应的 URL。Feed 元数据刷新后，必须允许新 URL 替换旧图。
    private var loadedURLByFeedID: [UUID: URL] = [:]
    var iconURLByFeedID: [UUID: URL] = [:]
    /// 失败记忆：absoluteURL → 最后失败时间。重试窗内的 URL 不再发起任何 I/O。
    var failures: [String: Date] = [:]
    private(set) var inFlightFeedIDs = Set<UUID>()
    /// 每个 Feed 当前实际在加载的 URL；旧 URL 完成时不能清理或覆盖新请求。
    private var inFlightURLByFeedID: [UUID: URL] = [:]
    private var persistTask: Task<Void, Never>?

    private let directory: URL
    let indexFileURL: URL
    private let session: URLSession

    /// 落盘前统一降采样的最大像素边长（16pt @3x = 48px，留余量到 144px）。
    nonisolated static let maxPixelSize: CGFloat = 144
    /// 永久性失败后的静默期：期间不再尝试该 URL（对齐 NNW failureRetryDays=5）。
    nonisolated public static let failureRetryInterval: TimeInterval = 5 * 24 * 3600
    /// 失败记录的最长保留期，超期在加载时清理。
    nonisolated static let failureRetentionInterval: TimeInterval = 30 * 24 * 3600

    // MARK: - Init

    /// - Parameters:
    ///   - directory: 图标缓存目录；默认 `Caches/FeedIcons`。测试可注入临时目录。
    ///   - session: 抓取会话；默认共享会话。`file://` URL 同样支持，便于测试。
    public init(directory: URL? = nil, session: URLSession = .shared) {
        self.session = session
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directory = caches.appendingPathComponent("FeedIcons", isDirectory: true)
        }
        self.indexFileURL = self.directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        loadIndexFromDisk()
    }

    deinit {
        persistTask?.cancel()
    }

    // MARK: - 同步查询（行渲染唯一入口）

    /// 同步查询已就绪的图标。纯内存字典读，绝不触发 I/O、绝不挂起——
    /// 这是"零异步空窗"的关键约束，调用方必须能在同一帧内拿到结果或 nil。
    public func cachedImage(feedID: UUID) -> CGImage? {
        memoryImages[feedID] ?? lastKnownImages[feedID]
    }

    /// 该 feed 是否已有确定的图标来源（含尚未拉取成功的）。
    public func hasIconSource(feedID: UUID) -> Bool {
        iconURLByFeedID[feedID] != nil
    }

    // MARK: - 预热

    /// fire-and-forget 预热：内存命中直接返回；否则后台读磁盘、必要才走网络。
    /// 重复调用自动去重（in-flight 与失败窗双重闸门）。
    public func warmUp(feedID: UUID, iconURL: URL?) {
        guard let iconURL else { return } // 无图标源的 feed：兜底徽章即终态

        if iconURLByFeedID[feedID] != iconURL {
            iconURLByFeedID[feedID] = iconURL
            scheduleIndexPersist()
        }

        // 不能只看 cachedImage：这里可能是旧 URL 的最后已知图标。
        // URL 改变后应保留旧图作为过渡，同时继续加载新的图标。
        guard loadedURLByFeedID[feedID] != iconURL,
              inFlightURLByFeedID[feedID] != iconURL,
              !isBlockedByFailure(iconURL)
        else { return }

        // URL 变化时覆盖记录，但不取消旧任务；旧任务完成后会因 URL 不匹配
        // 被丢弃，避免取消 URLSession 任务造成不必要的竞态。
        inFlightURLByFeedID[feedID] = iconURL
        inFlightFeedIDs.insert(feedID)
        let session = session
        let directory = directory
        Task { [weak self] in
            let result = await Self.loadIcon(url: iconURL, directory: directory, session: session)
            self?.completeWarmup(feedID: feedID, url: iconURL, result: result)
        }
    }

    /// 文章列表页预取：按 feedID 去重后批量预热。
    public func warmUp(items: [EntryListItem]) {
        var seen = Set<UUID>()
        for item in items where seen.insert(item.feedID).inserted {
            warmUp(feedID: item.feedID, iconURL: item.feedIconURL)
        }
    }

    /// 订阅源列表预取（侧边栏 / 冷启动）。
    public func warmUp(feeds: [Feed]) {
        for feed in feeds {
            warmUp(feedID: feed.id, iconURL: feed.iconURL)
        }
    }

    // MARK: - 内存压力

    /// 清空热缓存但保留最后已知图标：flush 后可见单元格依然有图可画。
    public func handleLowMemory() {
        lastKnownImages = memoryImages.merging(lastKnownImages) { current, _ in current }
        memoryImages.removeAll()
    }

    // MARK: - 完成回填（主线程）

    private func completeWarmup(feedID: UUID, url: URL, result: IconLoadResult) {
        // 同一个 Feed 的旧 URL 可能晚于新 URL 完成。它不再拥有该 Feed
        // 的 in-flight 槽位，也不能覆盖新图标或清理新请求的状态。
        guard inFlightURLByFeedID[feedID] == url else { return }
        inFlightURLByFeedID.removeValue(forKey: feedID)
        inFlightFeedIDs.remove(feedID)

        // URL 在请求期间再次变化时，结果只作为过期结果丢弃。
        guard iconURLByFeedID[feedID] == url else { return }

        switch result {
        case .success(let image):
            memoryImages[feedID] = image
            lastKnownImages[feedID] = image
            loadedURLByFeedID[feedID] = url
            revision += 1
        case .failure(let error):
            if !error.isTransient {
                failures[url.absoluteString] = Date()
                scheduleIndexPersist()
            }
        }
    }

    func isBlockedByFailure(_ url: URL) -> Bool {
        guard let failedAt = failures[url.absoluteString] else { return false }
        return Date().timeIntervalSince(failedAt) < Self.failureRetryInterval
    }

    /// 测试钩子：强制把当前索引/失败表落盘（正常路径由变更自动触发）。
    func scheduleIndexPersistForTesting() {
        scheduleIndexPersist()
    }

    // MARK: - 索引持久化（init 同步载入 + 写路径 fire-and-forget）

    private struct IconIndexFile: Codable {
        var feeds: [String: String] = [:]
        var failures: [String: Double] = [:]
    }

    private func loadIndexFromDisk() {
        guard let data = try? Data(contentsOf: indexFileURL),
              let index = try? JSONDecoder().decode(IconIndexFile.self, from: data)
        else { return }

        iconURLByFeedID = index.feeds.reduce(into: [UUID: URL]()) { result, pair in
            guard let id = UUID(uuidString: pair.key), let url = URL(string: pair.value) else { return }
            result[id] = url
        }
        let now = Date()
        failures = index.failures.reduce(into: [String: Date]()) { result, pair in
            let date = Date(timeIntervalSince1970: pair.value)
            // 过期失败记录就地清理（保留期外），避免索引无限膨胀。
            guard now.timeIntervalSince(date) < Self.failureRetentionInterval else { return }
            result[pair.key] = date
        }
    }

    private func scheduleIndexPersist() {
        persistTask?.cancel()
        let snapshot = IconIndexFile(
            feeds: Dictionary(
                iconURLByFeedID.map { ($0.key.uuidString, $0.value.absoluteString) },
                uniquingKeysWith: { current, _ in current }
            ),
            failures: failures.mapValues(\.timeIntervalSince1970)
        )
        let fileURL = indexFileURL
        persistTask = Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 后台加载管线（nonisolated）

    enum IconLoadError: Error {
        /// 离线 / DNS / 超时等瞬时问题：不入失败表，网络恢复后图标自然出现。
        case transient(URLError?)
        /// HTTP ≥400、响应不可解码等永久性问题：入失败表，静默期内不再尝试。
        case permanent(String)

        var isTransient: Bool {
            if case .transient = self { return true }
            return false
        }
    }

    typealias IconLoadResult = Result<CGImage, IconLoadError>

    /// 判定是否瞬时错误。判定不了的一律按永久处理——宁可静默显示兜底，
    /// 也不让坏 URL 反复进入加载态造成闪烁循环。
    nonisolated static func isTransientURLError(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed,
             .timedOut, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    nonisolated private static func loadIcon(
        url: URL,
        directory: URL,
        session: URLSession
    ) async -> IconLoadResult {
        // 第一层：磁盘字节缓存（下载时就已降采样，读取+解码毫秒级）
        let diskFile = diskFileURL(for: url, in: directory)
        if let data = try? Data(contentsOf: diskFile), let image = decodeIcon(from: data) {
            return .success(image)
        }

        // 第二层：网络抓取（file:// URL 由 URLSession 本地通道处理，便于测试）
        let data: Data
        do {
            let (payload, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.permanent("HTTP \(http.statusCode)"))
            }
            data = payload
        } catch let error as URLError {
            return .failure(.transient(isTransientURLError(error.code) ? error : nil))
        } catch {
            return .failure(.permanent("\(error)"))
        }

        // 解码 + 就地降采样，PNG 归一化落盘：此后该 URL 永远是本地磁盘命中
        guard let image = decodeIcon(from: data),
              let pngData = pngData(for: image)
        else {
            return .failure(.permanent("undecodable image"))
        }
        try? pngData.write(to: diskFile, options: .atomic)
        return .success(image)
    }

    /// 一 URL 一文件，文件名 = md5(absoluteString)，规避非法字符与长度问题。
    nonisolated static func diskFileURL(for url: URL, in directory: URL) -> URL {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }

    /// 解码并降采样到 maxPixelSize 以内（ICO/WebP/SVG 位帧均由 ImageIO 兜底）。
    nonisolated static func decodeIcon(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    nonisolated static func pngData(for image: CGImage) -> Data? {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutable, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutable as Data
    }
}
