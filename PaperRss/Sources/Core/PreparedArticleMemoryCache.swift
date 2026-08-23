import Foundation

/// 已准备文章的进程内 LRU 缓存。
///
/// 目标：顺序阅读（Space / nn / bb）时正文在选中瞬间即可用，
/// Reader 无需等待 prepare 管线即可换页，消除 loading 遮罩造成的屏闪。
/// 对齐 NetNewsWire「文章常驻内存、选中即渲染」的体验，同时保留磁盘缓存
/// 与网络抓取作为未命中的回退路径。
@MainActor
public final class PreparedArticleMemoryCache {

    /// 参与决定 PreparedArticle 结果的条目输入指纹。
    /// contentHTML 或标题变化（Feed 刷新等）会使指纹失配，缓存自动失效；
    /// hashValue 按进程随机化，仅用于进程内比较，满足本缓存的用途。
    public static func contentFingerprint(for entry: Entry) -> String {
        let contentHash = entry.contentHTML?.hashValue ?? 0
        let titleHash = entry.title.hashValue
        return "\(contentHash)-\(titleHash)"
    }

    private struct Value {
        let fingerprint: String
        let article: PreparedArticle
    }

    private var values: [String: Value] = [:]
    /// 最近使用顺序，首元素最旧。
    private var order: [String] = []
    private let capacity: Int

    /// 每次失效/清空时递增。调用方在开始耗时的准备前捕获代数，
    /// 完成后比对，避免“准备期间被重抓失效、完成后又把旧结果存回”的竞态。
    public private(set) var generation = 0

    public init(capacity: Int = 12) {
        self.capacity = max(1, capacity)
    }

    public func contains(_ entryID: String) -> Bool {
        values[entryID] != nil
    }

    /// 命中时刷新最近使用顺序；指纹不匹配视为失效并清除。
    public func article(for entryID: String, contentFingerprint: String) -> PreparedArticle? {
        guard let value = values[entryID] else { return nil }
        guard value.fingerprint == contentFingerprint else {
            invalidate(entryID: entryID)
            return nil
        }
        touch(entryID)
        return value.article
    }

    public func store(_ article: PreparedArticle, entryID: String, contentFingerprint: String) {
        values[entryID] = Value(fingerprint: contentFingerprint, article: article)
        touch(entryID)
        trim()
    }

    public func invalidate(entryID: String) {
        values.removeValue(forKey: entryID)
        order.removeAll { $0 == entryID }
        generation += 1
    }

    public func removeAll() {
        values.removeAll()
        order.removeAll()
        generation += 1
    }

    private func touch(_ entryID: String) {
        order.removeAll { $0 == entryID }
        order.append(entryID)
    }

    private func trim() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}
