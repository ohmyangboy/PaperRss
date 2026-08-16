import Foundation
import GRDB

/// `article_states` 表的持久化映射模型（文章已读/标星状态唯一持久源）。
///
/// 遵循 Architecture Contract (Section 8.7 / INV-05, INV-06)。
public struct ArticleStateRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "article_states"

    public var itemID: String
    public var isRead: Bool
    public var isStarred: Bool
    public var dateArrived: Double
    public var updatedAt: Double

    public init(
        itemID: String,
        isRead: Bool = false,
        isStarred: Bool = false,
        dateArrived: Double = Date().timeIntervalSince1970,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.itemID = itemID
        self.isRead = isRead
        self.isStarred = isStarred
        self.dateArrived = dateArrived
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case isRead = "is_read"
        case isStarred = "is_starred"
        case dateArrived = "date_arrived"
        case updatedAt = "updated_at"
    }
}
