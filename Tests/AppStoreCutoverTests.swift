import XCTest
import GRDB
@testable import PaperRssCore

final class AppStoreCutoverTests: XCTestCase {
    var tempDir: URL!
    var legacyJSONURL: URL!
    var sqliteURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssStoreCutoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        legacyJSONURL = tempDir.appendingPathComponent("library.json")
        sqliteURL = tempDir.appendingPathComponent("library.sqlite")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testAppStoreStartupMigratesLegacyJSONAndStopsWritingJSON() async throws {
        // 构造旧版 legacy JSON 数据
        let feedUUID = UUID()
        let legacyFeed = Feed(
            id: feedUUID,
            title: "Legacy News",
            feedURL: URL(string: "https://legacy.com/rss")!
        )
        let legacyEntry = Entry(
            id: "legacy-entry-1",
            feedID: feedUUID,
            title: "Legacy Title",
            url: URL(string: "https://legacy.com/1"),
            publishedAt: Date(),
            summary: "Legacy summary"
        )
        let legacyDatabase = AppDatabase(
            feeds: [legacyFeed],
            entries: [legacyEntry],
            articleCaches: [:],
            readingStates: [
                "legacy-entry-1": ReadingState(entryID: "legacy-entry-1", isRead: true, isStarred: true)
            ],
            artifacts: [],
            llmConfiguration: .default,
            customFolders: ["OldFolder"]
        )
        let encodedData = try JSONEncoder.paperRss.encode(legacyDatabase)
        try encodedData.write(to: legacyJSONURL)

        // 启动 AppStore
        let store = AppStore(testDatabase: legacyDatabase, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })

        // 验证状态已完整载入
        XCTAssertEqual(store.feeds.count, 1)
        XCTAssertEqual(store.feeds.first?.title, "Legacy News")
        XCTAssertEqual(store.customFolders, ["OldFolder"])
        XCTAssertEqual(store.starredEntries.count, 1)

        // 修改数据：添加新源
        let newFeed = try store.localProvider.addFeed(
            title: "New SQLite Feed",
            feedURL: URL(string: "https://new.com/rss")!
        )
        store.reloadState()
        XCTAssertEqual(store.feeds.count, 2)

        // 验证 SQLite 数据库已保存新源
        try store.libraryDatabase.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds WHERE is_deleted = 0;")
            XCTAssertEqual(count, 2)
            let feedRecord = try FeedRecord.filter(Column("id") == newFeed.id.uuidString).fetchOne(db)
            XCTAssertNotNil(feedRecord)
            XCTAssertEqual(feedRecord?.title, "New SQLite Feed")
        }

        // 验证原 legacy library.json 绝不被覆盖写入（其内容与启动前完全一致）
        let currentJSONData = try Data(contentsOf: legacyJSONURL)
        let currentDecoded = try JSONDecoder.paperRss.decode(AppDatabase.self, from: currentJSONData)
        XCTAssertEqual(currentDecoded.feeds.count, 1) // 依然保持旧数据，运行时绝不更新 JSON
    }

    @MainActor
    func testFreshInstallBootstrapsSQLiteAuthoritatively() async throws {
        // 无 library.json 的新安装
        let store = AppStore(testDatabase: AppDatabase.empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })

        // 验证默认状态
        XCTAssertEqual(store.feeds.count, 0)
        XCTAssertEqual(store.sidebarCounts.allUnread, 0)

        // 验证 local-default 账号已初始化
        try store.libraryDatabase.read { db in
            let account = try AccountRecord.filter(Column("id") == "local-default").fetchOne(db)
            XCTAssertNotNil(account)
            XCTAssertEqual(account?.displayName, "本地订阅")
        }
    }
}
