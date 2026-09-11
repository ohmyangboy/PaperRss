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
    public var previewImageURL: String?
    public var previewImageSource: String?
    public var previewInputHash: String?
    public var previewExtractionRevision: Int

    public init(
        itemID: String,
        title: String,
        author: String? = nil,
        url: String? = nil,
        publishedAt: Double? = nil,
        summary: String = "",
        contentHTML: String? = nil,
        contentUpdatedAt: Double = Date().timeIntervalSince1970,
        previewImage: EntryPreviewImage? = nil
    ) {
        self.itemID = itemID
        self.title = title
        self.author = author
        self.url = url
        self.publishedAt = publishedAt
        self.summary = summary
        self.contentHTML = contentHTML
        self.contentUpdatedAt = contentUpdatedAt
        self.previewImageURL = previewImage?.url?.absoluteString
        self.previewImageSource = previewImage?.source
        self.previewInputHash = previewImage?.inputHash
        self.previewExtractionRevision = previewImage?.revision ?? 0
    }

    public mutating func setPreviewImage(_ preview: EntryPreviewImage) {
        previewImageURL = preview.url?.absoluteString
        previewImageSource = preview.source
        previewInputHash = preview.inputHash
        previewExtractionRevision = preview.revision
    }

    /// Older JSON fixtures/exports have no derived preview metadata.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try values.decode(String.self, forKey: .itemID)
        title = try values.decode(String.self, forKey: .title)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        publishedAt = try values.decodeIfPresent(Double.self, forKey: .publishedAt)
        summary = try values.decode(String.self, forKey: .summary)
        contentHTML = try values.decodeIfPresent(String.self, forKey: .contentHTML)
        contentUpdatedAt = try values.decode(Double.self, forKey: .contentUpdatedAt)
        previewImageURL = try values.decodeIfPresent(String.self, forKey: .previewImageURL)
        previewImageSource = try values.decodeIfPresent(String.self, forKey: .previewImageSource)
        previewInputHash = try values.decodeIfPresent(String.self, forKey: .previewInputHash)
        previewExtractionRevision = try values.decodeIfPresent(Int.self, forKey: .previewExtractionRevision) ?? 0
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
        case previewImageURL = "preview_image_url"
        case previewImageSource = "preview_image_source"
        case previewInputHash = "preview_input_hash"
        case previewExtractionRevision = "preview_extraction_revision"
    }
}
