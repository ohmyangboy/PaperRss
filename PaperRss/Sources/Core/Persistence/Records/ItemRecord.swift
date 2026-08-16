import Foundation
import GRDB

/// `items` 表的持久化映射模型（文章身份层）。
///
/// 遵循 Architecture Contract (Section 8.5 / INV-03, INV-04, INV-05)。
public struct ItemRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "items"

    public var id: String
    public var accountID: String
    public var externalID: String
    public var feedID: String
    public var createdAt: Double
    public var updatedAt: Double

    public init(
        id: String,
        accountID: String,
        externalID: String,
        feedID: String,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.accountID = accountID
        self.externalID = externalID
        self.feedID = feedID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case externalID = "external_id"
        case feedID = "feed_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
