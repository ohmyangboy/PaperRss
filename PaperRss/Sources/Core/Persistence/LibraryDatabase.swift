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

    /// 回收 SQLite 磁盘空间。`VACUUM` 无法运行在事务内，
    /// 因此必须走 `writeWithoutTransaction` 而非 `write`。
    func vacuum() throws {
        try dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }
}
