import XCTest
import GRDB
@testable import PaperRssCore

final class LibraryDatabaseTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL, FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    private func makeTemporaryDatabaseURL() -> URL {
        temporaryDirectoryURL.appendingPathComponent("test-library-\(UUID().uuidString).sqlite")
    }

    func testCanCreateNewLibraryDatabaseAtSpecifiedPath() throws {
        let dbURL = makeTemporaryDatabaseURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))

        let database = try LibraryDatabase(databaseURL: dbURL)
        XCTAssertEqual(database.databasePath, dbURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        // 验证可正常执行基础读写
        try database.dbPool.write { db in
            try db.execute(sql: "CREATE TABLE test_ping (id INTEGER PRIMARY KEY);")
            try db.execute(sql: "INSERT INTO test_ping (id) VALUES (1);")
        }

        let count = try database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM test_ping;")
        }
        XCTAssertEqual(count, 1)
    }

    func testDatabaseUsesDatabasePool() throws {
        let dbURL = makeTemporaryDatabaseURL()
        let database = try LibraryDatabase(databaseURL: dbURL)

        // 验证确实为 DatabasePool 实例
        XCTAssertTrue((database.dbPool as Any) is DatabasePool)

        // 验证 Journal 模式为 WAL (DatabasePool 自动管理)
        let journalMode = try database.dbPool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode;")
        }
        XCTAssertEqual(journalMode?.lowercased(), "wal")
    }

    func testDatabaseCanBeReopenedWithoutError() throws {
        let dbURL = makeTemporaryDatabaseURL()

        // 第一次创建并写入数据
        do {
            let firstInstance = try LibraryDatabase(databaseURL: dbURL)
            try firstInstance.dbPool.write { db in
                try db.execute(sql: "CREATE TABLE test_persist (msg TEXT NOT NULL);")
                try db.execute(sql: "INSERT INTO test_persist (msg) VALUES (?);", arguments: ["hello_reopen"])
            }
        }

        // 第二次 reopen 同一个数据库路径
        do {
            let secondInstance = try LibraryDatabase(databaseURL: dbURL)
            let message = try secondInstance.dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT msg FROM test_persist;")
            }
            XCTAssertEqual(message, "hello_reopen")
        }
    }

    func testDatabaseMigratorCanBeExecutedRepeatedly() throws {
        let dbURL = makeTemporaryDatabaseURL()
        let database = try LibraryDatabase(databaseURL: dbURL)

        // 再次显式执行 default migrator，验证幂等性无错误
        XCTAssertNoThrow(try DatabaseMigrations.migrator.migrate(database.dbPool))
        XCTAssertNoThrow(try DatabaseMigrations.migrator.migrate(database.dbPool))
    }

    func testForeignKeyEnforcementIsEnabled() throws {
        let dbURL = makeTemporaryDatabaseURL()
        let database = try LibraryDatabase(databaseURL: dbURL)

        // 1. 验证 PRAGMA foreign_keys
        let foreignKeysStatus = try database.dbPool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys;")
        }
        XCTAssertEqual(foreignKeysStatus, 1, "GRDB 必须默认开启 Foreign Keys")

        // 2. 使用临时测试表验证外键违反会被拒绝
        try database.dbPool.write { db in
            try db.execute(sql: """
            CREATE TABLE test_parent (id TEXT PRIMARY KEY NOT NULL);
            CREATE TABLE test_child (
                id TEXT PRIMARY KEY NOT NULL,
                parent_id TEXT NOT NULL REFERENCES test_parent(id) ON DELETE CASCADE
            );
            """)

            try db.execute(sql: "INSERT INTO test_parent (id) VALUES ('p1');")
            try db.execute(sql: "INSERT INTO test_child (id, parent_id) VALUES ('c1', 'p1');")

            // 尝试插入不存在的 parent_id，必须抛出 Foreign Key constraint violation
            XCTAssertThrowsError(
                try db.execute(sql: "INSERT INTO test_child (id, parent_id) VALUES ('c2', 'non-existent');")
            ) { error in
                guard let dbError = error as? DatabaseError else {
                    XCTFail("Expected DatabaseError but got \(error)")
                    return
                }
                XCTAssertEqual(dbError.resultCode, .SQLITE_CONSTRAINT)
            }
        }
    }

    func testTemporaryTestDatabaseDoesNotPolluteDefaultDirectory() throws {
        let dbURL = makeTemporaryDatabaseURL()
        XCTAssertFalse(dbURL.path.contains("Application Support/PaperRss"))

        _ = try LibraryDatabase(databaseURL: dbURL)

        // 验证文件在临时路径，而不是默认路径
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(dbURL.path == LibraryDatabase.defaultDatabaseURL.path)
    }
}
