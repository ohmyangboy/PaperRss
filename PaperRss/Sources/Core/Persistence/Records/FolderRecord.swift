import Foundation
import GRDB

/// `folders` 表的持久化映射模型。
///
/// 遵循 Architecture Contract (Section 8.2 / INV-02)。
public struct FolderRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "folders"

    public var id: String
    public var accountID: String
    public var externalID: String?
    public var name: String
    public var sortOrder: Int
    public var isDeleted: Bool
    public var updatedAt: Double

    public init(
        id: String,
        accountID: String,
        externalID: String? = nil,
        name: String,
        sortOrder: Int = 0,
        isDeleted: Bool = false,
        updatedAt: Double
    ) {
        self.id = id
        self.accountID = accountID
        self.externalID = externalID
        self.name = name
        self.sortOrder = sortOrder
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case externalID = "external_id"
        case name
        case sortOrder = "sort_order"
        case isDeleted = "is_deleted"
        case updatedAt = "updated_at"
    }
}
