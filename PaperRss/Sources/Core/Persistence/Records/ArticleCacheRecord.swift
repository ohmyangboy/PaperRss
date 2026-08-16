import Foundation
import GRDB

/// `article_caches` 表的持久化映射模型（文章正文提取离线缓存）。
///
/// 遵循 Architecture Contract (Section 10)。
public struct ArticleCacheRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "article_caches"

    public var itemID: String
    public var text: String
    public var html: String?
    public var imageUrlsJSON: String?
    public var fetchedAt: Double
    public var sourceURL: String?
    public var isSanitized: Bool

    public init(
        itemID: String,
        text: String,
        html: String? = nil,
        imageUrlsJSON: String? = nil,
        fetchedAt: Double,
        sourceURL: String? = nil,
        isSanitized: Bool = false
    ) {
        self.itemID = itemID
        self.text = text
        self.html = html
        self.imageUrlsJSON = imageUrlsJSON
        self.fetchedAt = fetchedAt
        self.sourceURL = sourceURL
        self.isSanitized = isSanitized
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case text
        case html
        case imageUrlsJSON = "image_urls_json"
        case fetchedAt = "fetched_at"
        case sourceURL = "source_url"
        case isSanitized = "is_sanitized"
    }
}
