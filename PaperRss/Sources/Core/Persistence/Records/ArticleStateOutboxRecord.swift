import Foundation
import GRDB

/// `article_state_outbox` 表的持久化映射模型（待同步至远端的状态突变持久化队列）。
///
/// 遵循 Architecture Contract (Section 9 / INV-06, INV-07, INV-08)。
public struct ArticleStateOutboxRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "article_state_outbox"

    public var accountID: String
    public var itemID: String
    public var stateKey: String
    public var desiredValue: Bool
    public var revision: Int
    public var updatedAt: Double
    public var attemptCount: Int
    public var nextAttemptAt: Double?
    public var lastError: String?

    public init(
        accountID: String,
        itemID: String,
        stateKey: String,
        desiredValue: Bool,
        revision: Int = 1,
        updatedAt: Double,
        attemptCount: Int = 0,
        nextAttemptAt: Double? = nil,
        lastError: String? = nil
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.stateKey = stateKey
        self.desiredValue = desiredValue
        self.revision = revision
        self.updatedAt = updatedAt
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case itemID = "item_id"
        case stateKey = "state_key"
        case desiredValue = "desired_value"
        case revision
        case updatedAt = "updated_at"
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case lastError = "last_error"
    }
}
