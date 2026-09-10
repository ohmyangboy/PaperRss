import Foundation
import GRDB

/// PaperRss 本地 SQLite 核心持久化数据库管理类。
///
/// 封装 GRDB `DatabasePool`，负责管理单个 `library.sqlite` 的连接池生命周期、路径解析与迁移执行。
/// 遵循 Architecture Invariants:
/// - INV-01: 单一数据库 (`library.sqlite`)
/// - INV-09: View 不直接访问数据库 (收紧 dbPool 为 internal 可见性，由 Repository 层封装)
/// - INV-11: 通过 `DatabaseMigrator` 执行统一 Schema 迁移
public final class LibraryDatabase: Sendable {
    /// 底层 GRDB 并发数据库连接池 (WAL 模式)，internal 级别防止外部模块绕过 Repository 裸连
    let dbPool: DatabasePool

    /// 数据库文件所在的文件系统绝对路径
    public let databasePath: String

    /// 生产环境默认的数据存储根目录 (`~/Library/Application Support/PaperRss/`)
    public static var defaultDirectoryURL: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("PaperRss", isDirectory: true)
    }

    /// 生产环境默认的 SQLite 文件路径 (`~/Library/Application Support/PaperRss/library.sqlite`)
    public static var defaultDatabaseURL: URL {
        defaultDirectoryURL.appendingPathComponent("library.sqlite")
    }

    /// 初始化 LibraryDatabase 并自动执行迁移。
    ///
    /// - Parameters:
    ///   - databaseURL: 数据库文件路径，默认使用生产路径 `defaultDatabaseURL`。测试时可传入独立临时路径。
    ///   - migrator: 数据库迁移器，默认使用 `DatabaseMigrations.migrator`。
    ///   - configuration: GRDB 数据库连接池配置，默认使用推荐配置（自动开启外键支持等）。
    public init(
        databaseURL: URL = defaultDatabaseURL,
        migrator: DatabaseMigrator = DatabaseMigrations.migrator,
        configuration: Configuration = Configuration()
    ) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = databaseURL.path
        let pool = try DatabasePool(path: path, configuration: configuration)
        try migrator.migrate(pool)

        self.dbPool = pool
        self.databasePath = path
    }

    // MARK: - Internal Transaction & Access Boundary

    /// 在 internal 数据库只读连接上执行查询
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }

    /// 在 internal 数据库写入连接事务中执行操作
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.write(block)
    }

    /// 在 GRDB writer queue 异步执行事务。
    ///
    /// 调用方通常位于 MainActor。同步 `write` 会把整个 SQLite 事务
    /// 直接压在主线程上；刷新、导入等批量路径必须使用这个入口。
    func writeAsync<T: Sendable>(
        _ block: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await dbPool.write(block)
    }

    /// 在 GRDB reader queue 异步执行查询，避免批量状态快照阻塞主线程。
    func readAsync<T: Sendable>(
        _ block: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await dbPool.read(block)
    }

    /// 回收 SQLite 磁盘空间并截断 WAL 日志。`VACUUM` 无法运行在事务内，
    /// 因此必须走 `writeWithoutTransaction` 而非 `write`。
    public func vacuum() throws {
        try dbPool.writeWithoutTransaction { db in
            try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
            try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Storage Statistics

    public struct StorageStats: Sendable, Equatable {
        public let databaseFileSizeBytes: Int64
        public let walFileSizeBytes: Int64
        public let totalDiskBytes: Int64
        public let totalArticlesCount: Int
        public let readArticlesCount: Int
        public let starredArticlesCount: Int
        public let cacheEntriesCount: Int
        public let readArticlesDataSizeBytes: Int64
        public let prunableArticlesCount: Int
        public let prunableDataSizeBytes: Int64

        public init(
            databaseFileSizeBytes: Int64,
            walFileSizeBytes: Int64,
            totalDiskBytes: Int64,
            totalArticlesCount: Int,
            readArticlesCount: Int,
            starredArticlesCount: Int,
            cacheEntriesCount: Int,
            readArticlesDataSizeBytes: Int64 = 0,
            prunableArticlesCount: Int = 0,
            prunableDataSizeBytes: Int64 = 0
        ) {
            self.databaseFileSizeBytes = databaseFileSizeBytes
            self.walFileSizeBytes = walFileSizeBytes
            self.totalDiskBytes = totalDiskBytes
            self.totalArticlesCount = totalArticlesCount
            self.readArticlesCount = readArticlesCount
            self.starredArticlesCount = starredArticlesCount
            self.cacheEntriesCount = cacheEntriesCount
            self.readArticlesDataSizeBytes = readArticlesDataSizeBytes
            self.prunableArticlesCount = prunableArticlesCount
            self.prunableDataSizeBytes = prunableDataSizeBytes
        }
    }

    /// 计算 SQLite 数据库物理磁盘文件尺寸与文章及缓存数量、历史数据量和超期可清理数据统计。
    public func storageStats(cutoffDate: Date? = nil) throws -> StorageStats {
        let fileManager = FileManager.default
        func fileSize(at path: String) -> Int64 {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else {
                return 0
            }
            return size.int64Value
        }

        let dbSize = fileSize(at: databasePath)
        let walSize = fileSize(at: databasePath + "-wal")
        let shmSize = fileSize(at: databasePath + "-shm")
        let totalDiskBytes = dbSize + walSize + shmSize

        return try read { db in
            let totalArticlesCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM articles;") ?? 0
            let readArticlesCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM articles a
                INNER JOIN article_states s ON s.item_id = a.item_id
                WHERE s.is_read = 1;
            """) ?? 0
            let starredArticlesCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM articles a
                INNER JOIN article_states s ON s.item_id = a.item_id
                WHERE s.is_starred = 1;
            """) ?? 0
            let cacheEntriesCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_caches;") ?? 0

            let readArticlesDataSizeBytes = try Int64.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(
                        LENGTH(CAST(COALESCE(a.content_html, '') AS BLOB))
                        + LENGTH(CAST(COALESCE(a.summary, '') AS BLOB))
                        + LENGTH(CAST(COALESCE(c.text, '') AS BLOB))
                        + LENGTH(CAST(COALESCE(c.html, '') AS BLOB))
                        + LENGTH(CAST(COALESCE(c.image_urls_json, '') AS BLOB))
                    ), 0)
                FROM articles a
                INNER JOIN article_states s ON s.item_id = a.item_id
                LEFT JOIN article_caches c ON c.item_id = a.item_id
                WHERE s.is_read = 1
                  AND s.is_starred = 0;
            """) ?? 0

            let prunableArticlesCount: Int
            let prunableDataSizeBytes: Int64
            if let cutoffDate {
                let cutoffTimestamp = cutoffDate.timeIntervalSince1970
                let prunableRow = try Row.fetchOne(db, sql: """
                    SELECT
                        COUNT(a.item_id) AS count,
                        COALESCE(SUM(
                            LENGTH(CAST(COALESCE(a.content_html, '') AS BLOB))
                            + LENGTH(CAST(COALESCE(a.summary, '') AS BLOB))
                            + LENGTH(CAST(COALESCE(c.text, '') AS BLOB))
                            + LENGTH(CAST(COALESCE(c.html, '') AS BLOB))
                            + LENGTH(CAST(COALESCE(c.image_urls_json, '') AS BLOB))
                        ), 0) AS total_bytes
                    FROM articles a
                    INNER JOIN article_states s ON s.item_id = a.item_id
                    INNER JOIN items i ON i.id = a.item_id
                    LEFT JOIN article_caches c ON c.item_id = a.item_id
                    WHERE s.is_read = 1
                      AND s.is_starred = 0
                      AND (s.date_arrived < ? OR (s.date_arrived IS NULL AND i.created_at < ?));
                """, arguments: [cutoffTimestamp, cutoffTimestamp])
                prunableArticlesCount = Int(prunableRow?["count"] ?? 0)
                prunableDataSizeBytes = Int64(prunableRow?["total_bytes"] ?? 0)
            } else {
                prunableArticlesCount = 0
                prunableDataSizeBytes = 0
            }

            return StorageStats(
                databaseFileSizeBytes: dbSize,
                walFileSizeBytes: walSize,
                totalDiskBytes: totalDiskBytes,
                totalArticlesCount: totalArticlesCount,
                readArticlesCount: readArticlesCount,
                starredArticlesCount: starredArticlesCount,
                cacheEntriesCount: cacheEntriesCount,
                readArticlesDataSizeBytes: readArticlesDataSizeBytes,
                prunableArticlesCount: prunableArticlesCount,
                prunableDataSizeBytes: prunableDataSizeBytes
            )
        }
    }
}
