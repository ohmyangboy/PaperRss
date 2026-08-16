import XCTest
import GRDB
@testable import PaperRssCore

final class LegacyMigrationTests: XCTestCase {
    private var tempDirURL: URL!
    private var dbURL: URL!
    private var database: LibraryDatabase!
    private var migrator: LegacyJSONMigrator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssMigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
        dbURL = tempDirURL.appendingPathComponent("mig-test.sqlite")
        database = try LibraryDatabase(databaseURL: dbURL)
        migrator = LegacyJSONMigrator(database: database)
    }

    override func tearDownWithError() throws {
        migrator = nil
        database = nil
        if let tempDirURL, FileManager.default.fileExists(atPath: tempDirURL.path) {
            try? FileManager.default.removeItem(at: tempDirURL)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Source 不存在 & 空/损坏 JSON 测试

    func testNoLegacySourceReturnsNoLegacySourceWithoutCreatingLocalDefault() throws {
        let nonExistentJSON = tempDirURL.appendingPathComponent("non_existent_library.json")
        let result = try migrator.migrate(from: nonExistentJSON)

        XCTAssertEqual(result, .noLegacySource)

        // 验证数据库中未创建 local-default 账号 (DA-04B 绝不提前 bootstrap)
        try database.dbPool.read { db in
            let accountCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts WHERE id = 'local-default';")
            XCTAssertEqual(accountCount, 0)
        }
    }

    func testCorruptedOrEmptyLegacyJSONFailsCleanlyWithoutModifyingOriginalFile() throws {
        let emptyJSON = tempDirURL.appendingPathComponent("empty_library.json")
        try "".write(to: emptyJSON, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try migrator.migrate(from: emptyJSON)) { error in
            guard let migError = error as? LegacyMigrationError,
                  case .corruptJSON = migError else {
                XCTFail("Expected corruptJSON error, got: \(error)")
                return
            }
        }

        // 验证原文件未被删除或修改
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyJSON.path))
        XCTAssertEqual(try String(contentsOf: emptyJSON), "")

        let corruptJSON = tempDirURL.appendingPathComponent("corrupt_library.json")
        try "{ invalid_json_syntax: ".write(to: corruptJSON, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try migrator.migrate(from: corruptJSON)) { error in
            guard let migError = error as? LegacyMigrationError,
                  case .corruptJSON = migError else {
                XCTFail("Expected corruptJSON error, got: \(error)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptJSON.path))
    }

    // MARK: - 2. 完整全量数据迁移测试

    func testComprehensiveLegacyMigration() throws {
        let feed1ID = UUID()
        let feed2DeletedID = UUID()
        let art1ID = UUID()
        let art2TMID = UUID()
        let art3OrphanID = UUID()

        let legacyData = """
        {
            "feeds": [
                {
                    "id": "\(feed1ID.uuidString)",
                    "title": "Swift Blog",
                    "siteURL": "https://swift.org",
                    "feedURL": "https://swift.org/atom.xml",
                    "folder": "Tech",
                    "etag": "\\"etag1\\"",
                    "lastModified": "Wed, 21 Oct 2025 07:28:00 GMT",
                    "lastRefreshedAt": 1700000000.0,
                    "isDeleted": false,
                    "updatedAt": 1700000000.0,
                    "storedIconURL": "https://swift.org/favicon.ico"
                },
                {
                    "id": "\(feed2DeletedID.uuidString)",
                    "title": "Archived Feed",
                    "feedURL": "https://old.com/rss",
                    "folder": "Archive",
                    "isDeleted": true,
                    "updatedAt": 1700000000.0
                }
            ],
            "entries": [
                {
                    "id": "entry_1",
                    "feedID": "\(feed1ID.uuidString)",
                    "title": "Swift 6",
                    "author": "Ted",
                    "url": "https://swift.org/posts/swift-6",
                    "publishedAt": 1699990000.0,
                    "summary": "<p>Swift 6 is &amp; great</p>",
                    "contentHTML": "<p>Full content</p>",
                    "isRead": false,
                    "isStarred": false,
                    "updatedAt": 1700000000.0
                },
                {
                    "id": "entry_orphaned_from_deleted_feed",
                    "feedID": "\(feed2DeletedID.uuidString)",
                    "title": "Should Be Purged",
                    "isRead": false,
                    "isStarred": false,
                    "updatedAt": 1700000000.0
                }
            ],
            "articleCaches": {
                "entry_1": {
                    "entryID": "entry_1",
                    "text": "Clean extracted text",
                    "html": "<div>Extracted HTML</div>",
                    "imageURLs": ["https://img.com/1.png"],
                    "fetchedAt": 1700000050.0,
                    "sourceURL": "https://swift.org/posts/swift-6",
                    "isSanitized": true
                },
                "orphan_cache_key": {
                    "entryID": "orphan_cache_key",
                    "text": "Orphan Cache",
                    "imageURLs": [],
                    "fetchedAt": 1700000050.0,
                    "isSanitized": false
                }
            },
            "readingStates": {
                "entry_1": {
                    "entryID": "entry_1",
                    "isRead": true,
                    "isStarred": true,
                    "updatedAt": 1700000500.0
                },
                "orphan_state_key": {
                    "entryID": "orphan_state_key",
                    "isRead": true,
                    "isStarred": false,
                    "updatedAt": 1700000500.0
                }
            },
            "artifacts": [
                {
                    "id": "\(art1ID.uuidString)",
                    "entryID": "entry_1",
                    "kind": "summary",
                    "contentHash": "h_sum",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 1,
                    "content": "文章一的摘要",
                    "segments": [
                        {"id": "seg_1", "original": "Swift 6", "translation": "Swift 6 语言"}
                    ],
                    "selectionAnchor": {
                        "paragraphID": "para_1",
                        "startOffset": 0,
                        "endOffset": 7
                    },
                    "isComplete": true,
                    "isDeleted": false,
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                },
                {
                    "id": "\(art2TMID.uuidString)",
                    "entryID": "translation-memory-v2:hash_xyz",
                    "kind": "translation",
                    "contentHash": "h_tm",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 2,
                    "content": "全局翻译记忆产物",
                    "isComplete": true,
                    "isDeleted": false,
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                },
                {
                    "id": "\(art3OrphanID.uuidString)",
                    "entryID": "deleted_article_entry_id",
                    "kind": "summary",
                    "contentHash": "h_del",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 1,
                    "content": "历史已删除文章残留的产物",
                    "isComplete": false,
                    "isDeleted": true,
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                }
            ],
            "llmConfiguration": {
                "providerName": "DeepSeek",
                "providerDescription": "API",
                "baseURL": "https://api.deepseek.com",
                "model": "deepseek-v4-flash",
                "reasoningMode": "自动",
                "temperature": 0.2,
                "targetLanguage": "简体中文",
                "allowInsecureLocalEndpoint": false,
                "showsAISummary": true,
                "automaticallyGenerateSummary": false,
                "showsSelectionExplanation": true,
                "showsSelectionAsk": true,
                "showsSelectionTranslation": true,
                "customPrompt": "My Prompt"
            },
            "customFolders": ["Tech", "EmptyFolder", "Archive"]
        }
        """

        let sourceJSONURL = tempDirURL.appendingPathComponent("library.json")
        try legacyData.write(to: sourceJSONURL, atomically: true, encoding: .utf8)

        let result = try migrator.migrate(from: sourceJSONURL)
        guard case .success(let report) = result else {
            XCTFail("Expected migration success, got: \(result)")
            return
        }

        // 验证报告统计指标
        XCTAssertEqual(report.sourceFeedCount, 2)
        XCTAssertEqual(report.preparedActiveFeedCount, 1)
        XCTAssertEqual(report.preparedDeletedFeedCount, 1)
        XCTAssertEqual(report.migratedFeedCount, 2)
        XCTAssertEqual(report.sourceEntryCount, 2)
        XCTAssertEqual(report.preparedEntryCount, 1, "属于 deleted feed 的 entry 应在 prepare 阶段被 purge")
        XCTAssertEqual(report.migratedItemCount, 1)
        XCTAssertEqual(report.migratedArticleCount, 1)
        XCTAssertEqual(report.migratedStateCount, 1)
        XCTAssertEqual(report.migratedCacheCount, 1)
        XCTAssertEqual(report.orphanCacheCount, 1)
        XCTAssertEqual(report.orphanReadingStateCount, 1)
        XCTAssertEqual(report.articleArtifactCount, 1)
        XCTAssertEqual(report.globalTranslationMemoryCount, 1)
        XCTAssertEqual(report.orphanArtifactCount, 1)
        XCTAssertEqual(report.totalMigratedArtifactCount, 3, "所有 3 个 AI 产物必须 100% 迁移，0 silent loss")
        XCTAssertEqual(report.migratedFolderCount, 3, "customFolders 中的空 Folder 必须完整保留")
        XCTAssertNotNil(report.backupURL)

        // 验证数据库真实持久化状态
        try database.dbPool.read { db in
            // 1. Account & Sync State
            let account = try AccountRecord.filter(Column("id") == "local-default").fetchOne(db)
            XCTAssertNotNil(account)
            XCTAssertEqual(account?.type, "local")
            XCTAssertEqual(account?.displayName, "本地订阅")

            let syncState = try AccountSyncStateRecord.filter(Column("account_id") == "local-default").fetchOne(db)
            XCTAssertTrue(syncState?.initialSyncCompleted == true)

            // 2. Folders & Feeds (Deterministic ID & Canonical UUID)
            let techFolderID = "local-default:folder:Tech".stableDigest
            let emptyFolderID = "local-default:folder:EmptyFolder".stableDigest
            let techFolder = try FolderRecord.filter(Column("id") == techFolderID).fetchOne(db)
            let emptyFolder = try FolderRecord.filter(Column("id") == emptyFolderID).fetchOne(db)
            XCTAssertNotNil(techFolder)
            XCTAssertNotNil(emptyFolder)
            XCTAssertEqual(techFolder?.sortOrder, 0)
            XCTAssertEqual(emptyFolder?.sortOrder, 1)

            let feed1 = try FeedRecord.filter(Column("id") == feed1ID.uuidString).fetchOne(db)
            let feed2 = try FeedRecord.filter(Column("id") == feed2DeletedID.uuidString).fetchOne(db)
            XCTAssertNotNil(feed1)
            XCTAssertNotNil(feed2)
            XCTAssertEqual(feed1?.isDeleted, false)
            XCTAssertEqual(feed2?.isDeleted, true)
            XCTAssertEqual(feed1?.storedIconURL, "https://swift.org/favicon.ico")

            let feedFolders = try FeedFolderRecord.filter(Column("feed_id") == feed1ID.uuidString).fetchAll(db)
            XCTAssertEqual(feedFolders.count, 1)
            XCTAssertEqual(feedFolders.first?.folderID, techFolderID)

            // 3. Item, Article, State (ReadingState 优先级 & Summary 规范化)
            let item = try ItemRecord.filter(Column("id") == "entry_1").fetchOne(db)
            XCTAssertNotNil(item)
            XCTAssertEqual(item?.feedID, feed1ID.uuidString)
            XCTAssertEqual(item?.externalID, "entry_1")

            let article = try ArticleRecord.filter(Column("item_id") == "entry_1").fetchOne(db)
            XCTAssertEqual(article?.title, "Swift 6")
            XCTAssertEqual(article?.summary, "Swift 6 is & great", "Summary 应完成 plainText 规范化")

            let state = try ArticleStateRecord.filter(Column("item_id") == "entry_1").fetchOne(db)
            XCTAssertEqual(state?.isRead, true, "ReadingState 必须优先于 Entry.isRead (false)")
            XCTAssertEqual(state?.isStarred, true)
            XCTAssertEqual(state?.updatedAt, 1700000500.0)

            // 4. Cache
            let cache = try ArticleCacheRecord.filter(Column("item_id") == "entry_1").fetchOne(db)
            XCTAssertNotNil(cache)
            XCTAssertEqual(cache?.imageUrlsJSON, "[\"https://img.com/1.png\"]")

            // 5. AI Artifacts (三分法校验)
            let art1 = try AIArtifactRecord.filter(Column("id") == art1ID.uuidString).fetchOne(db)
            XCTAssertEqual(art1?.accountID, "local-default")
            XCTAssertEqual(art1?.itemID, "entry_1")
            XCTAssertEqual(art1?.subjectKey, "entry_1")

            let art2TM = try AIArtifactRecord.filter(Column("id") == art2TMID.uuidString).fetchOne(db)
            XCTAssertNil(art2TM?.accountID)
            XCTAssertNil(art2TM?.itemID)
            XCTAssertEqual(art2TM?.subjectKey, "translation-memory-v2:hash_xyz")

            let art3Orphan = try AIArtifactRecord.filter(Column("id") == art3OrphanID.uuidString).fetchOne(db)
            XCTAssertEqual(art3Orphan?.accountID, "local-default")
            XCTAssertNil(art3Orphan?.itemID, "孤儿文章产物 item_id 应为 NULL")
            XCTAssertEqual(art3Orphan?.subjectKey, "deleted_article_entry_id")
        }

        // 验证原 JSON 文件与备份文件均存在且完好
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceJSONURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.backupURL!.path))
    }

    // MARK: - 3. 幂等性与重复执行测试

    func testMigrationTwiceReturnsAlreadyCompleted() throws {
        let feedID = UUID()
        let legacyData = """
        {
            "feeds": [{"id": "\(feedID.uuidString)", "title": "F", "feedURL": "https://f.com", "updatedAt": 1000.0}],
            "entries": [{"id": "e1", "feedID": "\(feedID.uuidString)", "title": "T", "updatedAt": 1000.0}],
            "articleCaches": {},
            "readingStates": {},
            "artifacts": [],
            "llmConfiguration": {},
            "customFolders": []
        }
        """
        let sourceURL = tempDirURL.appendingPathComponent("library.json")
        try legacyData.write(to: sourceURL, atomically: true, encoding: .utf8)

        let firstResult = try migrator.migrate(from: sourceURL)
        guard case .success = firstResult else {
            XCTFail("First migration should succeed")
            return
        }

        // 第二次执行必须返回 alreadyCompleted
        let secondResult = try migrator.migrate(from: sourceURL)
        XCTAssertEqual(secondResult, .alreadyCompleted)
    }

    // MARK: - 4. 事务注入失败与原子回滚测试

    func testTransactionInjectedFailureRollbackAndRetry() throws {
        // 构建带有主键冲突的非法 Artifact 数据 (两条 Artifact 具有相同 UUID)
        let dupArtID = UUID()
        let feedID = UUID()
        let invalidData = """
        {
            "feeds": [{"id": "\(feedID.uuidString)", "title": "Feed", "feedURL": "https://f.com", "updatedAt": 1000.0}],
            "entries": [{"id": "e1", "feedID": "\(feedID.uuidString)", "title": "T", "updatedAt": 1000.0}],
            "articleCaches": {},
            "readingStates": {},
            "artifacts": [
                {
                    "id": "\(dupArtID.uuidString)",
                    "entryID": "translation-memory-v2:key1",
                    "kind": "translation",
                    "contentHash": "h1",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 1,
                    "content": "C1",
                    "createdAt": 1000.0,
                    "updatedAt": 1000.0
                },
                {
                    "id": "\(dupArtID.uuidString)",
                    "entryID": "translation-memory-v2:key2",
                    "kind": "translation",
                    "contentHash": "h2",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 1,
                    "content": "C2",
                    "createdAt": 1000.0,
                    "updatedAt": 1000.0
                }
            ],
            "llmConfiguration": {},
            "customFolders": []
        }
        """
        let sourceURL = tempDirURL.appendingPathComponent("invalid_library.json")
        try invalidData.write(to: sourceURL, atomically: true, encoding: .utf8)

        // 第一次迁移因重复主键冲突失败
        XCTAssertThrowsError(try migrator.migrate(from: sourceURL))

        // 验证数据库回滚至完全未迁移状态 (accounts 中无 local-default)
        try database.dbPool.read { db in
            let accountCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts WHERE id = 'local-default';")
            XCTAssertEqual(accountCount, 0)
        }

        // 修正数据后重试迁移
        let validFeedID = UUID()
        let validArtID1 = UUID()
        let validArtID2 = UUID()
        let validData = """
        {
            "feeds": [{"id": "\(validFeedID.uuidString)", "title": "Fixed Feed", "feedURL": "https://fixed.com", "updatedAt": 1000.0}],
            "entries": [{"id": "e_fixed", "feedID": "\(validFeedID.uuidString)", "title": "Fixed", "updatedAt": 1000.0}],
            "articleCaches": {},
            "readingStates": {},
            "artifacts": [
                {
                    "id": "\(validArtID1.uuidString)",
                    "entryID": "translation-memory-v2:key1",
                    "kind": "translation",
                    "contentHash": "h1",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 1,
                    "content": "C1",
                    "createdAt": 1000.0,
                    "updatedAt": 1000.0
                },
                {
                    "id": "\(validArtID2.uuidString)",
                    "entryID": "translation-memory-v2:key2",
                    "kind": "translation",
                    "contentHash": "h2",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 1,
                    "content": "C2",
                    "createdAt": 1000.0,
                    "updatedAt": 1000.0
                }
            ],
            "llmConfiguration": {},
            "customFolders": []
        }
        """
        try validData.write(to: sourceURL, atomically: true, encoding: .utf8)

        let retryResult = try migrator.migrate(from: sourceURL)
        guard case .success(let report) = retryResult else {
            XCTFail("Retry migration should succeed, got: \(retryResult)")
            return
        }
        XCTAssertEqual(report.migratedItemCount, 1)
        XCTAssertEqual(report.totalMigratedArtifactCount, 2)
    }
}
