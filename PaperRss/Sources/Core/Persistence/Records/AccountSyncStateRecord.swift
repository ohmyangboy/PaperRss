import Foundation
import GRDB

/// `account_sync_state` 表的持久化映射模型（账号同步游标与健康状态）。
///
/// 遵循 Architecture Contract (Section 12)。
public struct AccountSyncStateRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "account_sync_state"

    public var accountID: String
    public var initialSyncCompleted: Bool
    public var lastSyncStartedAt: Double?
    public var lastSyncCompletedAt: Double?
    public var lastFullReconcileAt: Double?
    public var lastArticleFetchAt: Double?
    public var consecutiveFailureCount: Int
    public var lastError: String?

    public init(
        accountID: String,
        initialSyncCompleted: Bool = false,
        lastSyncStartedAt: Double? = nil,
        lastSyncCompletedAt: Double? = nil,
        lastFullReconcileAt: Double? = nil,
        lastArticleFetchAt: Double? = nil,
        consecutiveFailureCount: Int = 0,
        lastError: String? = nil
    ) {
        self.accountID = accountID
        self.initialSyncCompleted = initialSyncCompleted
        self.lastSyncStartedAt = lastSyncStartedAt
        self.lastSyncCompletedAt = lastSyncCompletedAt
        self.lastFullReconcileAt = lastFullReconcileAt
        self.lastArticleFetchAt = lastArticleFetchAt
        self.consecutiveFailureCount = consecutiveFailureCount
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case initialSyncCompleted = "initial_sync_completed"
        case lastSyncStartedAt = "last_sync_started_at"
        case lastSyncCompletedAt = "last_sync_completed_at"
        case lastFullReconcileAt = "last_full_reconcile_at"
        case lastArticleFetchAt = "last_article_fetch_at"
        case consecutiveFailureCount = "consecutive_failure_count"
        case lastError = "last_error"
    }
}
