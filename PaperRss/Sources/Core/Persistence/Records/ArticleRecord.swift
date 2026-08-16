import Foundation
import GRDB

/// `articles` 表的持久化映射模型（文章内容层）。
///
/// 遵循 Architecture Contract (Section 8.6 / INV-05)。
public struct ArticleRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "articles"

    public var itemID: String
    public var title: String
    public var author: String?
    public var url: String?
    public var publishedAt: Double?
    public var summary: String
    public var contentHTML: String?
    public var contentUpdatedAt: Double

    public init(
        itemID: String,
        title: String,
        author: String? = nil,
        url: String? = nil,
        publishedAt: Double? = nil,
        summary: String = "",
        contentHTML: String? = nil,
        contentUpdatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.itemID = itemID
        self.title = title
        self.author = author
        self.url = url
        self.publishedAt = publishedAt
        self.summary = summary
        self.contentHTML = contentHTML
        self.contentUpdatedAt = contentUpdatedAt
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case title
        case author
        case url
        case publishedAt = "published_at"
        case summary
        case contentHTML = "content_html"
        case contentUpdatedAt = "content_updated_at"
    }
}
