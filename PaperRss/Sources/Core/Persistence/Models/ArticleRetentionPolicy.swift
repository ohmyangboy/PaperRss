import Foundation

/// 历史文章保留期限策略。
///
/// 用于根据已读历史文章的拉取到达时间（`date_arrived`，对齐 NetNewsWire）自动淘汰正文及离线网页缓存。
/// 保护铁律：未读文章（`is_read = 0`）与星标文章（`is_starred = 1`）无论发布多久，绝对永久保留，永不清理。
public enum ArticleRetentionPolicy: String, CaseIterable, Identifiable, Sendable, Codable {
    case sixMonths = "6months"    // 180 天 (默认)
    case oneYear = "1year"        // 365 天
    case forever = "forever"      // 永久保留

    public var id: String { rawValue }

    /// 保留天数；若为永久保留则返回 nil。
    public var days: Int? {
        switch self {
        case .sixMonths: return 180
        case .oneYear: return 365
        case .forever: return nil
        }
    }

    /// 显示标题（支持双语国际化）。
    public var title: String {
        switch self {
        case .sixMonths:
            return I18N.localized("180 天（默认）", englishFallback: "180 Days (Default)")
        case .oneYear:
            return I18N.localized("1 年", englishFallback: "1 Year")
        case .forever:
            return I18N.localized("永久保留", englishFallback: "Keep Forever")
        }
    }

    /// 计算相对于给定时间（默认为当前时间）的淘汰截止日期。
    /// 若策略为 `.forever`，则返回 `nil`。
    public func cutoffDate(relativeTo date: Date = Date()) -> Date? {
        guard let days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: date)
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "6months", "180days", "halfYear":
            self = .sixMonths
        case "1year", "365days", "year":
            self = .oneYear
        case "forever", "keepForever", "never":
            self = .forever
        case "1month", "3months", "30days", "60days", "90days":
            // 剔除的短周期选项平滑向下兼容迁移至 180 天默认
            self = .sixMonths
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ArticleRetentionPolicy(rawValue: raw) ?? .sixMonths
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
