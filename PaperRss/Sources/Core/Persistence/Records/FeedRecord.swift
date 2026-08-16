import Foundation
import GRDB

/// `feeds` 表的持久化映射模型。
///
/// 遵循 Architecture Contract (Section 8.3 / INV-02, INV-03)。
public struct FeedRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "feeds"

    public var id: String
    public var accountID: String
    public var externalID: String?
    public var title: String
    public var siteURL: String?
    public var feedURL: String
    public var etag: String?
    public var lastModified: String?
    public var lastRefreshedAt: Double?
    public var isDeleted: Bool
    public var updatedAt: Double
    public var storedIconURL: String?
    public var sortOrder: Int

    public init(
        id: String,
        accountID: String,
        externalID: String? = nil,
        title: String,
        siteURL: String? = nil,
        feedURL: String,
        etag: String? = nil,
        lastModified: String? = nil,
        lastRefreshedAt: Double? = nil,
        isDeleted: Bool = false,
        updatedAt: Double,
        storedIconURL: String? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.externalID = externalID
        self.title = title
        self.siteURL = siteURL
        self.feedURL = feedURL
        self.etag = etag
        self.lastModified = lastModified
        self.lastRefreshedAt = lastRefreshedAt
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
        self.storedIconURL = storedIconURL
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case externalID = "external_id"
        case title
        case siteURL = "site_url"
        case feedURL = "feed_url"
        case etag
        case lastModified = "last_modified"
        case lastRefreshedAt = "last_refreshed_at"
        case isDeleted = "is_deleted"
        case updatedAt = "updated_at"
        case storedIconURL = "stored_icon_url"
        case sortOrder = "sort_order"
    }
}
