import Foundation
import GRDB

/// `accounts` 表的持久化映射模型。
///
/// 遵循 Architecture Contract (Section 8.1 / INV-01, INV-02)。
public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "accounts"

    public var id: String
    public var type: String
    public var displayName: String
    public var endpointURL: String?
    public var username: String?
    public var isEnabled: Bool
    public var createdAt: Double
    public var updatedAt: Double

    public init(
        id: String,
        type: String,
        displayName: String,
        endpointURL: String? = nil,
        username: String? = nil,
        isEnabled: Bool = true,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.username = username
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case displayName = "display_name"
        case endpointURL = "endpoint_url"
        case username
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
