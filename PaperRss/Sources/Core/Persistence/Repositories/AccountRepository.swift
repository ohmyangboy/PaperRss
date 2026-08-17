import Foundation
import GRDB

/// 管理账号主数据与同步状态的持久化仓库。
///
/// 遵循 Architecture Contract (Section 13.1 / INV-01, INV-02)。
public final class AccountRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Database-Scoped Primitives (for Migration & Atomic Transactions)

    public func fetchAllAccounts(in db: Database) throws -> [AccountRecord] {
        try AccountRecord.order(Column("created_at").asc).fetchAll(db)
    }

    public func fetchAccount(id: String, in db: Database) throws -> AccountRecord? {
        try AccountRecord.filter(Column("id") == id).fetchOne(db)
    }

    public func saveAccount(_ record: AccountRecord, in db: Database) throws {
        try record.save(db)
    }

    public func updateAccountEnabled(id: String, isEnabled: Bool, in db: Database) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: "UPDATE accounts SET is_enabled = ?, updated_at = ? WHERE id = ?;",
            arguments: [isEnabled ? 1 : 0, now, id]
        )
    }

    public func deleteAccount(id: String, in db: Database) throws {
        _ = try AccountRecord.filter(Column("id") == id).deleteAll(db)
    }

    public func fetchSyncState(accountID: String, in db: Database) throws -> AccountSyncStateRecord? {
        try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)
    }

    public func saveSyncState(_ record: AccountSyncStateRecord, in db: Database) throws {
        try record.save(db)
    }

    // MARK: - Async Public APIs

    public func fetchAllAccounts() async throws -> [AccountRecord] {
        try database.read { db in
            try fetchAllAccounts(in: db)
        }
    }

    public func fetchAccount(id: String) async throws -> AccountRecord? {
        try database.read { db in
            try fetchAccount(id: id, in: db)
        }
    }

    public func updateAccountEnabled(id: String, isEnabled: Bool) async throws {
        try database.write { db in
            try updateAccountEnabled(id: id, isEnabled: isEnabled, in: db)
        }
    }

    public func saveAccount(_ record: AccountRecord) async throws {
        try database.write { db in
            try saveAccount(record, in: db)
        }
    }

    public func saveAccountAtomicWithDuplicateCheck(_ record: AccountRecord) async throws {
        try database.write { db in
            if record.type == AccountType.freshRSS.rawValue, let ep = record.endpointURL, let un = record.username {
                let canonical = (URL(string: ep).map { ReaderAPIClient.canonicalBaseURL(for: $0).absoluteString }) ?? ep
                let existing = try AccountRecord
                    .filter(Column("type") == AccountType.freshRSS.rawValue && Column("username") == un)
                    .fetchAll(db)
                    .first { acc in
                        guard let existingEP = acc.endpointURL else { return false }
                        let existingCanonical = (URL(string: existingEP).map { ReaderAPIClient.canonicalBaseURL(for: $0).absoluteString }) ?? existingEP
                        return existingCanonical == canonical
                    }
                if let existing {
                    throw ReaderAPIError.accountAlreadyExists("\(un) @ \(canonical) (ID: \(existing.id))")
                }
            }
            try saveAccount(record, in: db)
        }
    }

    public func deleteAccount(id: String) async throws {
        try database.write { db in
            try deleteAccount(id: id, in: db)
        }
    }

    public func fetchSyncState(accountID: String) async throws -> AccountSyncStateRecord? {
        try database.read { db in
            try fetchSyncState(accountID: accountID, in: db)
        }
    }

    public func saveSyncState(_ record: AccountSyncStateRecord) async throws {
        try database.write { db in
            try saveSyncState(record, in: db)
        }
    }
}
