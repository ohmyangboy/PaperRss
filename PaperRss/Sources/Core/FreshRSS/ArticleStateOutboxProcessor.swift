import Foundation
import GRDB

/// 负责将本地离线/异步状态突变 (ArticleStateOutbox) 可靠推送到 FreshRSS 远端。
///
/// 遵循 Architecture Contract (Section 9, 12 / INV-07, INV-08)。
/// 严格遵守 In-flight Race 保护机制：成功时仅根据当时的 (item_id, state_key, revision) 原子删除。
public actor ArticleStateOutboxProcessor {
    private let accountID: String
    private let database: LibraryDatabase
    private let apiClient: ReaderAPIClient

    public init(
        accountID: String,
        database: LibraryDatabase,
        apiClient: ReaderAPIClient
    ) {
        self.accountID = accountID
        self.database = database
        self.apiClient = apiClient
    }

    public struct ProcessResult: Sendable, Equatable {
        public var processedCount: Int
        public var successCount: Int
        public var failureCount: Int

        public init(processedCount: Int = 0, successCount: Int = 0, failureCount: Int = 0) {
            self.processedCount = processedCount
            self.successCount = successCount
            self.failureCount = failureCount
        }
    }

    /// 处理当前就绪的待出站状态记录。
    @discardableResult
    public func processOutbox(forceAll: Bool = false) async throws -> ProcessResult {
        let now = Date().timeIntervalSince1970

        // 1. 读取 ready rows
        let readyRows: [ArticleStateOutboxRecord] = try database.read { db in
            var query = ArticleStateOutboxRecord.filter(Column("account_id") == self.accountID)
            if !forceAll {
                query = query.filter(Column("next_attempt_at") == nil || Column("next_attempt_at") <= now)
            }
            return try query.order(Column("updated_at").asc).fetchAll(db)
        }

        guard !readyRows.isEmpty else {
            return ProcessResult()
        }

        // 2. 映射 item_id 到 external_id (remote item ID)
        let itemIDs = Array(Set(readyRows.map(\.itemID)))
        let externalIDMap: [String: String] = try database.read { db in
            let items = try ItemRecord
                .filter(Column("account_id") == self.accountID && itemIDs.contains(Column("id")))
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: items.map { item in
                (item.id, item.externalID)
            })
        }

        var result = ProcessResult(processedCount: readyRows.count)

        for row in readyRows {
            guard let externalID = externalIDMap[row.itemID], !externalID.isEmpty else {
                // 严禁静默删除用户持久突变：保留记录，递增失败计数并记录错误
                result.failureCount += 1
                let attempt = row.attemptCount + 1
                let backoffSeconds = min(pow(2.0, Double(min(attempt, 6))), 60.0)
                let nextAttempt = Date().timeIntervalSince1970 + backoffSeconds
                let errorMessage = "Missing item or external_id for itemID: \(row.itemID)"

                try? database.write { db in
                    if var current = try ArticleStateOutboxRecord
                        .filter(
                            Column("account_id") == self.accountID &&
                            Column("item_id") == row.itemID &&
                            Column("state_key") == row.stateKey
                        )
                        .fetchOne(db) {
                        if current.revision == row.revision {
                            current.attemptCount = attempt
                            current.nextAttemptAt = nextAttempt
                            current.lastError = errorMessage
                            current.updatedAt = Date().timeIntervalSince1970
                            try current.save(db)
                        }
                    }
                }
                continue
            }

            do {
                if row.stateKey == "read" {
                    try await apiClient.markRead(itemIDs: [externalID], isRead: row.desiredValue)
                } else if row.stateKey == "starred" {
                    try await apiClient.markStarred(itemIDs: [externalID], isStarred: row.desiredValue)
                }

                // 远端成功：带 revision 原子删除
                let deleted = try database.write { db in
                    try ArticleStateOutboxRecord
                        .filter(
                            Column("account_id") == self.accountID &&
                            Column("item_id") == row.itemID &&
                            Column("state_key") == row.stateKey &&
                            Column("revision") == row.revision
                        )
                        .deleteAll(db) > 0
                }

                if deleted {
                    result.successCount += 1
                }
            } catch {
                result.failureCount += 1
                // 失败：保留记录，累加 attempt_count 并计算指数退避
                let attempt = row.attemptCount + 1
                let backoffSeconds = min(pow(2.0, Double(min(attempt, 6))), 60.0) // 2s, 4s, 8s, 16s, 32s, 60s
                let nextAttempt = Date().timeIntervalSince1970 + backoffSeconds
                let errorMessage = error.localizedDescription

                try? database.write { db in
                    if var current = try ArticleStateOutboxRecord
                        .filter(
                            Column("account_id") == self.accountID &&
                            Column("item_id") == row.itemID &&
                            Column("state_key") == row.stateKey
                        )
                        .fetchOne(db) {
                        // 仅在 revision 没有被本地新写入覆盖时更新 retry 状态
                        if current.revision == row.revision {
                            current.attemptCount = attempt
                            current.nextAttemptAt = nextAttempt
                            current.lastError = errorMessage
                            current.updatedAt = Date().timeIntervalSince1970
                            try current.save(db)
                        }
                    }
                }
            }
        }

        return result
    }
}
