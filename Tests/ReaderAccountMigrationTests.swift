import XCTest
import GRDB
@testable import PaperRssCore

/// accounts.type 约束迁移（v13）的数据完整性与约束验证。
final class ReaderAccountMigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssAccountMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testMigrationPreservesLegacyDataAndAllowsMinifluxAccounts() throws {
        let dbURL = tempDir.appendingPathComponent("legacy.sqlite")
        let queue = try DatabaseQueue(path: dbURL.path)

        // 1. 先构建当前完整 Schema，再回退 accounts 表为 v13 之前的 CHECK 约束，模拟升级前数据库。
        try DatabaseMigrations.migrator.migrate(queue)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
            try db.execute(sql: """
                CREATE TABLE accounts_legacy (
                    id              TEXT PRIMARY KEY NOT NULL,
                    type            TEXT NOT NULL,
                    display_name    TEXT NOT NULL,
                    endpoint_url    TEXT,
                    username        TEXT,
                    is_enabled      INTEGER NOT NULL DEFAULT 1,
                    created_at      REAL NOT NULL,
                    updated_at      REAL NOT NULL,

                    CHECK (type IN ('local', 'freshRSS'))
                );

                INSERT INTO accounts_legacy SELECT * FROM accounts;

                DROP TABLE accounts;

                ALTER TABLE accounts_legacy RENAME TO accounts;

                CREATE INDEX idx_accounts_type ON accounts(type);
                """)
        }

        // 2. 写入升级前的账号与关联业务数据
        let now = Date().timeIntervalSince1970
        let accountID = "freshRSS-legacy"
        let folderID = "folder-legacy"
        let feedID = "feed-legacy"
        let itemID = "item-legacy"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (id, type, display_name, endpoint_url, username, is_enabled, created_at, updated_at)
                VALUES ('local-default', 'local', '本地订阅', NULL, NULL, 1, ?, ?),
                       (?, 'freshRSS', 'Legacy FreshRSS', 'https://legacy.example.com/api/greader.php', 'legacy_user', 1, ?, ?);
                """, arguments: [now, now, accountID, now, now])
            try db.execute(sql: """
                INSERT INTO folders (id, account_id, external_id, name, sort_order, is_deleted, updated_at)
                VALUES (?, ?, 'user/-/label/Legacy', 'Legacy', 0, 0, ?);
                """, arguments: [folderID, accountID, now])
            try db.execute(sql: """
                INSERT INTO feeds (id, account_id, external_id, title, feed_url, is_deleted, updated_at, sort_order)
                VALUES (?, ?, 'feed/legacy', 'Legacy Feed', 'https://legacy.example.com/rss', 0, ?, 0);
                """, arguments: [feedID, accountID, now])
            try db.execute(sql: """
                INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
                VALUES (?, ?, '12345', ?, ?, ?);
                """, arguments: [itemID, accountID, feedID, now, now])
            try db.execute(sql: """
                INSERT INTO article_states (item_id, is_read, is_starred, date_arrived, updated_at)
                VALUES (?, 1, 1, ?, ?);
                """, arguments: [itemID, now, now])
            try db.execute(sql: """
                INSERT INTO article_state_outbox (account_id, item_id, state_key, desired_value, revision, attempt_count, updated_at)
                VALUES (?, ?, 'read', 0, 3, 0, ?);
                """, arguments: [accountID, itemID, now])
            try db.execute(sql: """
                INSERT INTO account_sync_state (account_id, initial_sync_completed, last_sync_started_at, consecutive_failure_count)
                VALUES (?, 1, ?, 0);
                """, arguments: [accountID, now])
        }

        // 3. 运行 v13 升级迁移（受控单迁移，主体与生产迁移共用同一实现）
        var migrator = DatabaseMigrator()
        migrator.registerMigration("test-v13-extend-account-types-miniflux") { db in
            try DatabaseMigrations.extendAccountTypesToMiniflux(db)
        }
        try migrator.migrate(queue)

        // 4. 业务数据完整保留
        try queue.read { db in
            let accounts = try AccountRecord.fetchAll(db)
            XCTAssertEqual(accounts.count, 2)
            let legacy = try XCTUnwrap(accounts.first { $0.id == accountID })
            XCTAssertEqual(legacy.type, AccountType.freshRSS.rawValue)
            XCTAssertEqual(legacy.endpointURL, "https://legacy.example.com/api/greader.php")
            XCTAssertEqual(legacy.username, "legacy_user")

            XCTAssertEqual(try FolderRecord.filter(Column("id") == folderID).fetchOne(db)?.name, "Legacy")
            XCTAssertEqual(try FeedRecord.filter(Column("id") == feedID).fetchOne(db)?.externalID, "feed/legacy")
            XCTAssertEqual(try ItemRecord.filter(Column("id") == itemID).fetchOne(db)?.externalID, "12345")

            let state = try XCTUnwrap(ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db))
            XCTAssertTrue(state.isRead)
            XCTAssertTrue(state.isStarred)

            let outbox = try XCTUnwrap(
                ArticleStateOutboxRecord.filter(Column("account_id") == accountID && Column("item_id") == itemID).fetchOne(db)
            )
            XCTAssertEqual(outbox.revision, 3)
            XCTAssertEqual(outbox.desiredValue, false)

            XCTAssertEqual(try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)?.initialSyncCompleted, true)
        }

        // 5. 约束扩展：允许 miniflux，拒绝未知类型；索引重建；外键完整
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (id, type, display_name, endpoint_url, username, is_enabled, created_at, updated_at)
                VALUES ('miniflux-new', 'miniflux', 'Miniflux', 'https://miniflux.example.com', 'miniflux_user', 1, ?, ?);
                """, arguments: [now, now])
        }
        try queue.read { db in
            XCTAssertNotNil(try AccountRecord.filter(Column("id") == "miniflux-new").fetchOne(db))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_accounts_type';"),
                "idx_accounts_type"
            )
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check;")
            XCTAssertTrue(violations.isEmpty, "迁移后外键检查必须无违规")
        }

        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO accounts (id, type, display_name, is_enabled, created_at, updated_at)
                    VALUES ('bogus', 'unknownService', 'Bogus', 1, ?, ?);
                    """, arguments: [now, now])
            },
            "未知账号类型必须被 CHECK 约束拒绝"
        )
    }
}
