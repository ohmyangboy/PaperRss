import XCTest
import GRDB
@testable import PaperRssCore

final class DatabaseSchemaTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var database: LibraryDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        let dbURL = temporaryDirectoryURL.appendingPathComponent("schema-test.sqlite")
        database = try LibraryDatabase(databaseURL: dbURL)
    }

    override func tearDownWithError() throws {
        database = nil
        if let temporaryDirectoryURL, FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    // MARK: - A. 完整表集合测试

    func testMigrationCreatesExact11BusinessTables() throws {
        let expectedTables: Set<String> = [
            "accounts",
            "folders",
            "feeds",
            "feed_folders",
            "items",
            "articles",
            "article_states",
            "article_state_outbox",
            "article_caches",
            "ai_artifacts",
            "account_sync_state"
        ]

        let existingTables = try database.dbPool.read { db -> Set<String> in
            let tableNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations';"
            )
            return Set(tableNames)
        }

        XCTAssertEqual(existingTables, expectedTables, "数据库必须且只能包含规范定义的 11 张业务表")
    }

    // MARK: - B. Column Contract 结构内省

    struct ColumnInfo: FetchableRecord, Decodable {
        let cid: Int
        let name: String
        let type: String
        let notnull: Int
        let pk: Int
    }

    func testColumnContractsForCoreTables() throws {
        try database.dbPool.read { db in
            // 1. accounts
            let accountsColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(accounts);")
            let accountsDict = Dictionary(uniqueKeysWithValues: accountsColumns.map { ($0.name, $0) })
            XCTAssertEqual(accountsDict["id"]?.type.uppercased(), "TEXT")
            XCTAssertEqual(accountsDict["id"]?.pk, 1)
            XCTAssertEqual(accountsDict["type"]?.notnull, 1)
            XCTAssertEqual(accountsDict["is_enabled"]?.type.uppercased(), "INTEGER")
            XCTAssertEqual(accountsDict["created_at"]?.type.uppercased(), "REAL")
            XCTAssertEqual(accountsDict["updated_at"]?.type.uppercased(), "REAL")

            // 2. items
            let itemsColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(items);")
            let itemsDict = Dictionary(uniqueKeysWithValues: itemsColumns.map { ($0.name, $0) })
            XCTAssertEqual(itemsDict["id"]?.pk, 1)
            XCTAssertEqual(itemsDict["external_id"]?.type.uppercased(), "TEXT")
            XCTAssertEqual(itemsDict["external_id"]?.notnull, 1)

            // 3. articles
            let articlesColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(articles);")
            let articlesDict = Dictionary(uniqueKeysWithValues: articlesColumns.map { ($0.name, $0) })
            XCTAssertEqual(articlesDict["item_id"]?.pk, 1)
            XCTAssertNil(articlesDict["is_read"], "articles 表不得包含 is_read")
            XCTAssertNil(articlesDict["is_starred"], "articles 表不得包含 is_starred")

            // 4. article_states
            let statesColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(article_states);")
            let statesDict = Dictionary(uniqueKeysWithValues: statesColumns.map { ($0.name, $0) })
            XCTAssertEqual(statesDict["item_id"]?.pk, 1)
            XCTAssertEqual(statesDict["is_read"]?.type.uppercased(), "INTEGER")
            XCTAssertEqual(statesDict["is_starred"]?.type.uppercased(), "INTEGER")

            // 5. article_state_outbox
            let outboxColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(article_state_outbox);")
            let outboxDict = Dictionary(uniqueKeysWithValues: outboxColumns.map { ($0.name, $0) })
            XCTAssertEqual(outboxDict["account_id"]?.pk, 1)
            XCTAssertEqual(outboxDict["item_id"]?.pk, 2)
            XCTAssertEqual(outboxDict["state_key"]?.pk, 3)

            // 6. article_caches
            let cachesColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(article_caches);")
            let cachesDict = Dictionary(uniqueKeysWithValues: cachesColumns.map { ($0.name, $0) })
            XCTAssertEqual(cachesDict["item_id"]?.pk, 1)
            XCTAssertEqual(cachesDict["image_urls_json"]?.type.uppercased(), "TEXT")

            // 7. ai_artifacts
            let aiColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(ai_artifacts);")
            let aiDict = Dictionary(uniqueKeysWithValues: aiColumns.map { ($0.name, $0) })
            XCTAssertEqual(aiDict["id"]?.pk, 1)
            XCTAssertEqual(aiDict["account_id"]?.notnull, 0, "ai_artifacts.account_id 必须允许 NULL 以支持全局翻译记忆")
            XCTAssertEqual(aiDict["item_id"]?.notnull, 0, "ai_artifacts.item_id 必须允许 NULL")

            // 8. account_sync_state
            let syncColumns = try ColumnInfo.fetchAll(db, sql: "PRAGMA table_info(account_sync_state);")
            let syncDict = Dictionary(uniqueKeysWithValues: syncColumns.map { ($0.name, $0) })
            XCTAssertEqual(syncDict["account_id"]?.pk, 1)
            XCTAssertNil(syncDict["cursor"], "v1 不得私自添加未定义 cursor")
            XCTAssertNil(syncDict["token"], "v1 不得私自添加 token")
        }
    }

    // MARK: - C. Foreign Keys & Cascades

    func testForeignKeysAreEnforcedAcrossAllTables() throws {
        try database.dbPool.write { db in
            // 未创建 account 时插入 folder 应失败
            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO folders (id, account_id, name, updated_at)
                VALUES ('f1', 'non-existent-account', 'Tech', 1000.0);
                """)
            ) { error in
                XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
            }

            // 未创建 feed 时插入 item 应失败
            try db.execute(sql: """
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('acc1', 'local', 'Local Account', 1000.0, 1000.0);
            """)

            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
                VALUES ('item1', 'acc1', 'ext1', 'non-existent-feed', 1000.0, 1000.0);
                """)
            ) { error in
                XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
            }
        }
    }

    // MARK: - D. Composite / Remote Identity

    func testRemoteIdentityUniquenessAndCrossAccountIsolation() throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('acc1', 'freshRSS', 'Server A', 1000.0, 1000.0),
                   ('acc2', 'freshRSS', 'Server B', 1000.0, 1000.0);

            INSERT INTO feeds (id, account_id, title, feed_url, updated_at)
            VALUES ('feed1', 'acc1', 'Feed 1', 'https://a.com/rss', 1000.0),
                   ('feed2', 'acc2', 'Feed 2', 'https://b.com/rss', 1000.0);
            """)

            // 1. 同一 account 下相同的 external_id 必须冲突
            try db.execute(sql: """
            INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
            VALUES ('i1', 'acc1', 'remote-item-123', 'feed1', 1000.0, 1000.0);
            """)

            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
                VALUES ('i2', 'acc1', 'remote-item-123', 'feed1', 1000.0, 1000.0);
                """)
            ) { error in
                XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
            }

            // 2. 不同 account 下相同的 external_id 允许共存 (INV-02 隔离)
            XCTAssertNoThrow(
                try db.execute(sql: """
                INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
                VALUES ('i3', 'acc2', 'remote-item-123', 'feed2', 1000.0, 1000.0);
                """)
            )

            // 3. Partial Unique Index 测试 (feeds / folders 在 external_id 为 NULL 时允许多行，非 NULL 时同账号内唯一)
            try db.execute(sql: """
            INSERT INTO feeds (id, account_id, external_id, title, feed_url, updated_at)
            VALUES ('f_local_1', 'acc1', NULL, 'Local 1', 'https://l1.com', 1000.0),
                   ('f_local_2', 'acc1', NULL, 'Local 2', 'https://l2.com', 1000.0);
            """)

            try db.execute(sql: """
            INSERT INTO feeds (id, account_id, external_id, title, feed_url, updated_at)
            VALUES ('f_remote_1', 'acc1', 'ext_feed_1', 'Remote 1', 'https://r1.com', 1000.0);
            """)

            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO feeds (id, account_id, external_id, title, feed_url, updated_at)
                VALUES ('f_remote_dup', 'acc1', 'ext_feed_1', 'Remote Dup', 'https://r2.com', 1000.0);
                """)
            ) { error in
                XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
            }
        }
    }

    // MARK: - E. Feed / Folder Many-to-Many

    func testFeedFolderManyToManyRelationship() throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('acc1', 'local', 'Local', 1000.0, 1000.0);

            INSERT INTO folders (id, account_id, name, updated_at)
            VALUES ('folder1', 'acc1', 'Folder A', 1000.0),
                   ('folder2', 'acc1', 'Folder B', 1000.0);

            INSERT INTO feeds (id, account_id, title, feed_url, updated_at)
            VALUES ('feed1', 'acc1', 'Feed 1', 'https://feed1.com', 1000.0);

            INSERT INTO feed_folders (feed_id, folder_id)
            VALUES ('feed1', 'folder1'),
                   ('feed1', 'folder2');
            """)

            let folderCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM feed_folders WHERE feed_id = 'feed1';"
            )
            XCTAssertEqual(folderCount, 2, "单个 Feed 可同时归属于多个 Folder")
        }
    }

    // MARK: - F. Item Without Article (INV-05)

    func testItemCanExistWithoutArticleRow() throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('acc1', 'freshRSS', 'FreshRSS', 1000.0, 1000.0);

            INSERT INTO feeds (id, account_id, title, feed_url, updated_at)
            VALUES ('feed1', 'acc1', 'Feed 1', 'https://feed.com', 1000.0);

            INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
            VALUES ('item_header_only', 'acc1', 'ext_999', 'feed1', 1000.0, 1000.0);

            INSERT INTO article_states (item_id, is_read, is_starred, date_arrived, updated_at)
            VALUES ('item_header_only', 0, 0, 1000.0, 1000.0);
            """)

            let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE id = 'item_header_only';")
            let stateCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_states WHERE item_id = 'item_header_only';")
            let articleCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM articles WHERE item_id = 'item_header_only';")

            XCTAssertEqual(itemCount, 1)
            XCTAssertEqual(stateCount, 1)
            XCTAssertEqual(articleCount, 0, "INV-05: 允许仅存在 Item 与 State 而尚未拉取 Article 正文")
        }
    }

    // MARK: - G. Outbox Primary Key & Check

    func testOutboxCompositePrimaryKeyAndCheckConstraints() throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('acc1', 'freshRSS', 'FreshRSS', 1000.0, 1000.0);

            INSERT INTO feeds (id, account_id, title, feed_url, updated_at)
            VALUES ('feed1', 'acc1', 'Feed 1', 'https://feed.com', 1000.0);

            INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
            VALUES ('item1', 'acc1', 'ext_1', 'feed1', 1000.0, 1000.0);

            -- 同一 item 可同时存在 read 和 starred 两个 outbox 期望状态
            INSERT INTO article_state_outbox (account_id, item_id, state_key, desired_value, revision, updated_at)
            VALUES ('acc1', 'item1', 'read', 1, 1, 1000.0),
                   ('acc1', 'item1', 'starred', 1, 1, 1000.0);
            """)

            let outboxCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_state_outbox WHERE item_id = 'item1';")
            XCTAssertEqual(outboxCount, 2)

            // 验证 state_key CHECK 约束 (只允许 read 或 starred)
            XCTAssertThrowsError(
                try db.execute(sql: """
                INSERT INTO article_state_outbox (account_id, item_id, state_key, desired_value, revision, updated_at)
                VALUES ('acc1', 'item1', 'invalid_key', 1, 1, 1000.0);
                """)
            ) { error in
                XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
            }
        }
    }

    // MARK: - H. AI Global Artifact (Translation Memory)

    func testGlobalAIArtifactAllowsNullAccountAndItem() throws {
        try database.dbPool.write { db in
            XCTAssertNoThrow(
                try db.execute(sql: """
                INSERT INTO ai_artifacts (
                    id, account_id, item_id, subject_key, kind, content_hash,
                    model, target_language, prompt_version, content, is_complete,
                    created_at, updated_at
                ) VALUES (
                    'art_global_1', NULL, NULL, 'tm_paragraph_hash_abc', 'translation', 'hash123',
                    'deepseek-chat', 'zh-Hans', 1, '全局翻译记忆内容', 1,
                    1000.0, 1000.0
                );
                """)
            )

            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM ai_artifacts WHERE account_id IS NULL AND item_id IS NULL;"
            )
            XCTAssertEqual(count, 1)
        }
    }

    // MARK: - I. Cascade 级联清理测试

    func testCascadeDeleteFromFeedAndAccount() throws {
        try database.dbPool.write { db in
            // 准备完整关联数据
            try db.execute(sql: """
            INSERT INTO accounts (id, type, display_name, created_at, updated_at)
            VALUES ('acc1', 'freshRSS', 'FreshRSS Acc', 1000.0, 1000.0);

            INSERT INTO folders (id, account_id, name, updated_at)
            VALUES ('fol1', 'acc1', 'Folder 1', 1000.0);

            INSERT INTO feeds (id, account_id, title, feed_url, updated_at)
            VALUES ('feed1', 'acc1', 'Feed 1', 'https://feed1.com', 1000.0);

            INSERT INTO feed_folders (feed_id, folder_id)
            VALUES ('feed1', 'fol1');

            INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at)
            VALUES ('item1', 'acc1', 'ext_1', 'feed1', 1000.0, 1000.0);

            INSERT INTO articles (item_id, title, content_updated_at)
            VALUES ('item1', 'Article Title', 1000.0);

            INSERT INTO article_states (item_id, is_read, is_starred, date_arrived, updated_at)
            VALUES ('item1', 1, 0, 1000.0, 1000.0);

            INSERT INTO article_caches (item_id, text, fetched_at)
            VALUES ('item1', 'Clean extracted text', 1000.0);

            INSERT INTO article_state_outbox (account_id, item_id, state_key, desired_value, updated_at)
            VALUES ('acc1', 'item1', 'read', 1, 1000.0);

            INSERT INTO ai_artifacts (
                id, account_id, item_id, subject_key, kind, content_hash,
                model, target_language, created_at, updated_at
            ) VALUES (
                'ai1', 'acc1', 'item1', 'item1', 'summary', 'h1',
                'deepseek-chat', 'zh-Hans', 1000.0, 1000.0
            );

            INSERT INTO ai_artifacts (
                id, account_id, item_id, subject_key, kind, content_hash,
                model, target_language, created_at, updated_at
            ) VALUES (
                'ai_global', NULL, NULL, 'global_key', 'translation', 'hg',
                'deepseek-chat', 'zh-Hans', 1000.0, 1000.0
            );

            INSERT INTO account_sync_state (account_id, initial_sync_completed)
            VALUES ('acc1', 1);
            """)

            // 1. 删除 feed1，级联清理 feed_folders, items, articles, states, caches, outbox
            try db.execute(sql: "DELETE FROM feeds WHERE id = 'feed1';")

            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_folders WHERE feed_id = 'feed1';"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE id = 'item1';"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM articles WHERE item_id = 'item1';"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_states WHERE item_id = 'item1';"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_caches WHERE item_id = 'item1';"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_state_outbox WHERE item_id = 'item1';"), 0)

            // ai_artifacts 的 item_id 应该被 SET NULL 而不是删除该行
            let aiItem = try String.fetchOne(db, sql: "SELECT item_id FROM ai_artifacts WHERE id = 'ai1';")
            XCTAssertNil(aiItem, "ai_artifacts.item_id 必须被 ON DELETE SET NULL 置空")

            // 2. 删除 account1，级联清理 accounts, folders, account_sync_state, ai1 (其 account_id CASCADE)
            try db.execute(sql: "DELETE FROM accounts WHERE id = 'acc1';")

            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders WHERE account_id = 'acc1';"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account_sync_state WHERE account_id = 'acc1';"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_artifacts WHERE id = 'ai1';"), 0)

            // 全局 ai_artifacts (account_id = NULL) 必须不受影响保留
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_artifacts WHERE id = 'ai_global';"), 1)
        }
    }
}
