import Foundation
import GRDB

/// Legacy JSON 数据迁移结果。
public enum LegacyMigrationResult: Sendable, Equatable {
    /// 未发现遗留的 `library.json` 文件（新用户场景，无需迁移）
    case noLegacySource
    /// 数据库中已存在 `local-default` 账号（迁移已完成，直接跳过）
    case alreadyCompleted
    /// 迁移成功完成，附带详细的迁移报告
    case success(LegacyMigrationReport)
}

/// 详细的迁移执行报告。
public struct LegacyMigrationReport: Sendable, Equatable {
    public let backupURL: URL?
    public let sourceFeedCount: Int
    public let preparedActiveFeedCount: Int
    public let preparedDeletedFeedCount: Int
    public let migratedFeedCount: Int
    public let sourceEntryCount: Int
    public let preparedEntryCount: Int
    public let migratedItemCount: Int
    public let migratedArticleCount: Int
    public let migratedStateCount: Int
    public let migratedCacheCount: Int
    public let orphanCacheCount: Int
    public let orphanReadingStateCount: Int
    public let articleArtifactCount: Int
    public let globalTranslationMemoryCount: Int
    public let orphanArtifactCount: Int
    public let totalMigratedArtifactCount: Int
    public let migratedFolderCount: Int
    public let llmConfiguration: LegacyLLMConfiguration
    public let migrationDurationSeconds: Double

    public init(
        backupURL: URL?,
        sourceFeedCount: Int,
        preparedActiveFeedCount: Int,
        preparedDeletedFeedCount: Int,
        migratedFeedCount: Int,
        sourceEntryCount: Int,
        preparedEntryCount: Int,
        migratedItemCount: Int,
        migratedArticleCount: Int,
        migratedStateCount: Int,
        migratedCacheCount: Int,
        orphanCacheCount: Int,
        orphanReadingStateCount: Int,
        articleArtifactCount: Int,
        globalTranslationMemoryCount: Int,
        orphanArtifactCount: Int,
        totalMigratedArtifactCount: Int,
        migratedFolderCount: Int,
        llmConfiguration: LegacyLLMConfiguration,
        migrationDurationSeconds: Double
    ) {
        self.backupURL = backupURL
        self.sourceFeedCount = sourceFeedCount
        self.preparedActiveFeedCount = preparedActiveFeedCount
        self.preparedDeletedFeedCount = preparedDeletedFeedCount
        self.migratedFeedCount = migratedFeedCount
        self.sourceEntryCount = sourceEntryCount
        self.preparedEntryCount = preparedEntryCount
        self.migratedItemCount = migratedItemCount
        self.migratedArticleCount = migratedArticleCount
        self.migratedStateCount = migratedStateCount
        self.migratedCacheCount = migratedCacheCount
        self.orphanCacheCount = orphanCacheCount
        self.orphanReadingStateCount = orphanReadingStateCount
        self.articleArtifactCount = articleArtifactCount
        self.globalTranslationMemoryCount = globalTranslationMemoryCount
        self.orphanArtifactCount = orphanArtifactCount
        self.totalMigratedArtifactCount = totalMigratedArtifactCount
        self.migratedFolderCount = migratedFolderCount
        self.llmConfiguration = llmConfiguration
        self.migrationDurationSeconds = migrationDurationSeconds
    }
}

/// 迁移异常定义。
public enum LegacyMigrationError: LocalizedError, Equatable {
    case corruptJSON(String)
    case backupFailed(String)
    case validationFailed(String)
    case alreadyMigrated

    public var errorDescription: String? {
        switch self {
        case .corruptJSON(let msg): "解析旧版 JSON 数据失败: \(msg)"
        case .backupFailed(let msg): "创建迁移备份文件失败: \(msg)"
        case .validationFailed(let msg): "数据完整性校验失败: \(msg)"
        case .alreadyMigrated: "本地数据库已完成迁移，无需重复执行"
        }
    }
}

/// 负责将旧版 `library.json` 单事务原子迁移至 SQLite 数据库的执行器。
///
/// 遵循 Architecture Contract (DA-04A / DA-04A.1)。
public final class LegacyJSONMigrator: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// 执行 Legacy 迁移。
    ///
    /// - Parameters:
    ///   - sourceJSONURL: 源 `library.json` 文件路径。
    ///   - backupDirectoryURL: 备份文件存放目录（默认与源文件同目录）。
    ///   - fileManager: 文件管理器。
    /// - Returns: `LegacyMigrationResult` 迁移结果。
    public func migrate(
        from sourceJSONURL: URL,
        backupDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> LegacyMigrationResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. 检查 source JSON 是否存在
        guard fileManager.fileExists(atPath: sourceJSONURL.path) else {
            return .noLegacySource
        }

        // 2. 检查 SQLite 中是否已经存在 `local-default` 账号
        let isAlreadyMigrated = try database.read { db in
            try AccountRecord.filter(Column("id") == "local-default").fetchOne(db) != nil
        }
        if isAlreadyMigrated {
            return .alreadyCompleted
        }

        // 3. 读取并解析旧版 JSON 数据
        let rawData: Data
        do {
            rawData = try Data(contentsOf: sourceJSONURL)
        } catch {
            throw LegacyMigrationError.corruptJSON("无法读取源文件: \(error.localizedDescription)")
        }

        guard !rawData.isEmpty else {
            throw LegacyMigrationError.corruptJSON("源 JSON 文件为空")
        }

        let rawDatabase: LegacyAppDatabase
        do {
            rawDatabase = try LegacyMigrationJSONDecoder.decoder.decode(LegacyAppDatabase.self, from: rawData)
        } catch {
            throw LegacyMigrationError.corruptJSON("JSON 反序列化失败: \(error.localizedDescription)")
        }

        // 4. 创建带 UTC 时间戳的只读备份（非破坏性 copy）
        let backupDestinationDir = backupDirectoryURL ?? sourceJSONURL.deletingLastPathComponent()
        let backupURL = try createTimestampedBackup(
            from: sourceJSONURL,
            destinationDirectory: backupDestinationDir,
            fileManager: fileManager
        )

        // 5. 执行内存数据准备与清洗
        let prepared = LegacyDatasetPreparer.prepare(raw: rawDatabase)

        // 6. 开启单 SQLite 写入事务
        var report: LegacyMigrationReport!
        try database.write { db in
            report = try performMigrationTransaction(
                raw: rawDatabase,
                prepared: prepared,
                backupURL: backupURL,
                startTime: startTime,
                in: db
            )
        }

        return .success(report)
    }

    // MARK: - Internal Transaction Implementation

    private func performMigrationTransaction(
        raw: LegacyAppDatabase,
        prepared: PreparedLegacyDataset,
        backupURL: URL,
        startTime: CFAbsoluteTime,
        in db: Database
    ) throws -> LegacyMigrationReport {
        // 单点捕获时间戳
        let capturedMigrationTimestamp = Date().timeIntervalSince1970

        // Step 1: 写入 local-default 账号与同步状态
        let account = AccountRecord(
            id: "local-default",
            type: "local",
            displayName: "本地订阅",
            endpointURL: nil,
            username: nil,
            isEnabled: true,
            createdAt: capturedMigrationTimestamp,
            updatedAt: capturedMigrationTimestamp
        )
        try account.save(db)

        let syncState = AccountSyncStateRecord(
            accountID: "local-default",
            initialSyncCompleted: true,
            lastSyncStartedAt: nil,
            lastSyncCompletedAt: capturedMigrationTimestamp,
            lastFullReconcileAt: nil,
            lastArticleFetchAt: nil,
            consecutiveFailureCount: 0,
            lastError: nil
        )
        try syncState.save(db)

        // Step 2: 合并并写入 Folders
        var folderMap: [String: String] = [:] // [FolderName: FolderID]
        var orderedFolderNames: [String] = []

        let allDistinctFolderNames = Set(prepared.feeds.compactMap(\.folder)).union(prepared.customFolders)
        for folder in prepared.customFolders {
            if allDistinctFolderNames.contains(folder) && !orderedFolderNames.contains(folder) {
                orderedFolderNames.append(folder)
            }
        }
        let remainingFolders = allDistinctFolderNames.subtracting(orderedFolderNames).sorted()
        orderedFolderNames.append(contentsOf: remainingFolders)

        for (index, folderName) in orderedFolderNames.enumerated() {
            let folderID = "local-default:folder:\(folderName)".stableDigest
            folderMap[folderName] = folderID

            let folderRecord = FolderRecord(
                id: folderID,
                accountID: "local-default",
                externalID: nil,
                name: folderName,
                sortOrder: index,
                isDeleted: false,
                updatedAt: capturedMigrationTimestamp
            )
            try folderRecord.save(db)
        }

        // Step 3: 写入 Feeds 与 Feed ↔ Folder 多对多关联
        for (index, feed) in prepared.feeds.enumerated() {
            let feedID = feed.id.uuidString
            let feedRecord = FeedRecord(
                id: feedID,
                accountID: "local-default",
                externalID: nil,
                title: feed.title,
                siteURL: feed.siteURL?.absoluteString,
                feedURL: feed.feedURL.absoluteString,
                etag: feed.etag,
                lastModified: feed.lastModified,
                lastRefreshedAt: feed.lastRefreshedAt?.timeIntervalSince1970,
                isDeleted: feed.isDeleted,
                updatedAt: feed.updatedAt.timeIntervalSince1970,
                storedIconURL: feed.storedIconURL?.absoluteString,
                sortOrder: index
            )
            try feedRecord.save(db)

            if let folderName = feed.folder, let folderID = folderMap[folderName] {
                let feedFolder = FeedFolderRecord(feedID: feedID, folderID: folderID)
                try feedFolder.save(db)
            }
        }

        // Step 4: 写入 Items, Articles, ArticleStates
        for entry in prepared.entries {
            let itemID = entry.id
            let feedID = entry.feedID.uuidString

            let itemRecord = ItemRecord(
                id: itemID,
                accountID: "local-default",
                externalID: itemID,
                feedID: feedID,
                createdAt: capturedMigrationTimestamp,
                updatedAt: entry.updatedAt.timeIntervalSince1970
            )
            try itemRecord.save(db)

            let articleRecord = ArticleRecord(
                itemID: itemID,
                title: entry.title,
                author: entry.author,
                url: entry.url?.absoluteString,
                publishedAt: entry.publishedAt?.timeIntervalSince1970,
                summary: entry.summary,
                contentHTML: entry.contentHTML,
                contentUpdatedAt: capturedMigrationTimestamp
            )
            try articleRecord.save(db)

            let stateUpdatedAt = (prepared.readingStates[entry.id]?.updatedAt ?? entry.updatedAt).timeIntervalSince1970
            let stateRecord = ArticleStateRecord(
                itemID: itemID,
                isRead: entry.isRead,
                isStarred: entry.isStarred,
                dateArrived: capturedMigrationTimestamp,
                updatedAt: stateUpdatedAt
            )
            try stateRecord.save(db)
        }

        // Step 5: 写入 Article Caches (仅写入有效 entries 的 cache)
        for (_, cache) in prepared.articleCaches {
            let imageUrlsJSON: String?
            if cache.imageURLs.isEmpty {
                imageUrlsJSON = nil
            } else {
                imageUrlsJSON = try LegacyMigrationJSONEncoder.encodeString(cache.imageURLs.map(\.absoluteString))
            }

            let cacheRecord = ArticleCacheRecord(
                itemID: cache.entryID,
                text: cache.text,
                html: cache.html,
                imageUrlsJSON: imageUrlsJSON,
                fetchedAt: cache.fetchedAt.timeIntervalSince1970,
                sourceURL: cache.sourceURL?.absoluteString,
                isSanitized: cache.isSanitized
            )
            try cacheRecord.save(db)
        }

        // Step 6: 写入 AI Artifacts (严格三分法，零静默丢失)
        let validEntryIDs = Set(prepared.entries.map(\.id))
        var articleArtifactCount = 0
        var globalTranslationMemoryCount = 0
        var orphanArtifactCount = 0

        for artifact in raw.artifacts {
            let artifactID = artifact.id.uuidString
            let segmentsJSON: String?
            if artifact.segments.isEmpty {
                segmentsJSON = nil
            } else {
                segmentsJSON = try LegacyMigrationJSONEncoder.encodeString(artifact.segments)
            }

            let anchorJSON: String?
            if let anchor = artifact.selectionAnchor {
                anchorJSON = try LegacyMigrationJSONEncoder.encodeString(anchor)
            } else {
                anchorJSON = nil
            }

            let accountID: String?
            let itemID: String?
            let subjectKey = artifact.entryID

            if artifact.entryID.hasPrefix("translation-memory-v2:") {
                // A. 全局翻译记忆
                accountID = nil
                itemID = nil
                globalTranslationMemoryCount += 1
            } else if validEntryIDs.contains(artifact.entryID) {
                // B. 有效文章产物
                accountID = "local-default"
                itemID = artifact.entryID
                articleArtifactCount += 1
            } else {
                // C. 孤儿/历史文章产物 (保留数据，item_id 为 NULL，归属 local-default)
                accountID = "local-default"
                itemID = nil
                orphanArtifactCount += 1
            }

            let artifactRecord = AIArtifactRecord(
                id: artifactID,
                accountID: accountID,
                itemID: itemID,
                subjectKey: subjectKey,
                kind: artifact.kind.rawValue,
                contentHash: artifact.contentHash,
                model: artifact.model,
                targetLanguage: artifact.targetLanguage,
                promptVersion: artifact.promptVersion,
                content: artifact.content,
                segmentsJSON: segmentsJSON,
                selectionText: artifact.selectionText,
                selectionArticleHash: artifact.selectionArticleHash,
                selectionAnchorJSON: anchorJSON,
                isComplete: artifact.isComplete,
                isDeleted: artifact.isDeleted,
                createdAt: artifact.createdAt.timeIntervalSince1970,
                updatedAt: artifact.updatedAt.timeIntervalSince1970
            )
            try artifactRecord.save(db)
        }

        // Step 7: In-Transaction Validations
        try performValidation(raw: raw, prepared: prepared, in: db)

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let preparedActiveFeeds = prepared.feeds.filter { !$0.isDeleted }.count
        let preparedDeletedFeeds = prepared.feeds.filter { $0.isDeleted }.count

        return LegacyMigrationReport(
            backupURL: backupURL,
            sourceFeedCount: raw.feeds.count,
            preparedActiveFeedCount: preparedActiveFeeds,
            preparedDeletedFeedCount: preparedDeletedFeeds,
            migratedFeedCount: prepared.feeds.count,
            sourceEntryCount: raw.entries.count,
            preparedEntryCount: prepared.entries.count,
            migratedItemCount: prepared.entries.count,
            migratedArticleCount: prepared.entries.count,
            migratedStateCount: prepared.entries.count,
            migratedCacheCount: prepared.articleCaches.count,
            orphanCacheCount: prepared.orphanArticleCaches.count,
            orphanReadingStateCount: prepared.orphanReadingStates.count,
            articleArtifactCount: articleArtifactCount,
            globalTranslationMemoryCount: globalTranslationMemoryCount,
            orphanArtifactCount: orphanArtifactCount,
            totalMigratedArtifactCount: raw.artifacts.count,
            migratedFolderCount: orderedFolderNames.count,
            llmConfiguration: raw.llmConfiguration,
            migrationDurationSeconds: duration
        )
    }

    private func performValidation(
        raw: LegacyAppDatabase,
        prepared: PreparedLegacyDataset,
        in db: Database
    ) throws {
        // 1. 外键与快速完整性检查
        let fkErrors = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check;")
        guard fkErrors.isEmpty else {
            throw LegacyMigrationError.validationFailed("外键约束检查未通过: \(fkErrors.count) 处违规")
        }

        let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check;")
        guard quickCheck == "ok" else {
            throw LegacyMigrationError.validationFailed("SQLite quick_check 失败: \(quickCheck ?? "nil")")
        }

        // 2. 行数守恒校验
        let dbFeedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds WHERE account_id = 'local-default';") ?? 0
        guard dbFeedCount == prepared.feeds.count else {
            throw LegacyMigrationError.validationFailed("Feeds 数量不一致: SQLite=\(dbFeedCount), Prepared=\(prepared.feeds.count)")
        }

        let dbActiveFeeds = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds WHERE account_id = 'local-default' AND is_deleted = 0;") ?? 0
        let preparedActiveFeeds = prepared.feeds.filter { !$0.isDeleted }.count
        guard dbActiveFeeds == preparedActiveFeeds else {
            throw LegacyMigrationError.validationFailed("Active Feeds 数量不一致: SQLite=\(dbActiveFeeds), Prepared=\(preparedActiveFeeds)")
        }

        let dbDeletedFeeds = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds WHERE account_id = 'local-default' AND is_deleted = 1;") ?? 0
        let preparedDeletedFeeds = prepared.feeds.filter { $0.isDeleted }.count
        guard dbDeletedFeeds == preparedDeletedFeeds else {
            throw LegacyMigrationError.validationFailed("Deleted Feeds 数量不一致: SQLite=\(dbDeletedFeeds), Prepared=\(preparedDeletedFeeds)")
        }

        let dbItemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE account_id = 'local-default';") ?? 0
        guard dbItemCount == prepared.entries.count else {
            throw LegacyMigrationError.validationFailed("Items 数量不一致: SQLite=\(dbItemCount), Prepared=\(prepared.entries.count)")
        }

        let dbArticleCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM articles INNER JOIN items ON items.id = articles.item_id WHERE items.account_id = 'local-default';"
        ) ?? 0
        guard dbArticleCount == prepared.entries.count else {
            throw LegacyMigrationError.validationFailed("Articles 数量不一致: SQLite=\(dbArticleCount), Prepared=\(prepared.entries.count)")
        }

        let dbStateCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM article_states INNER JOIN items ON items.id = article_states.item_id WHERE items.account_id = 'local-default';"
        ) ?? 0
        guard dbStateCount == prepared.entries.count else {
            throw LegacyMigrationError.validationFailed("ArticleStates 数量不一致: SQLite=\(dbStateCount), Prepared=\(prepared.entries.count)")
        }

        let dbCacheCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM article_caches INNER JOIN items ON items.id = article_caches.item_id WHERE items.account_id = 'local-default';"
        ) ?? 0
        guard dbCacheCount == prepared.articleCaches.count else {
            throw LegacyMigrationError.validationFailed("ArticleCaches 数量不一致: SQLite=\(dbCacheCount), Prepared=\(prepared.articleCaches.count)")
        }

        let dbArtifactCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_artifacts;") ?? 0
        guard dbArtifactCount == raw.artifacts.count else {
            throw LegacyMigrationError.validationFailed("AIArtifacts 数量不一致: SQLite=\(dbArtifactCount), Raw=\(raw.artifacts.count)")
        }
    }

    // MARK: - Backup Helper

    private func createTimestampedBackup(
        from sourceURL: URL,
        destinationDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let timestampString = formatter.string(from: Date())

        var backupFilename = "library.json.pre-sqlite-\(timestampString).backup"
        var targetURL = destinationDirectory.appendingPathComponent(backupFilename)

        if fileManager.fileExists(atPath: targetURL.path) {
            let uniqueSuffix = UUID().uuidString.prefix(8)
            backupFilename = "library.json.pre-sqlite-\(timestampString)-\(uniqueSuffix).backup"
            targetURL = destinationDirectory.appendingPathComponent(backupFilename)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        } catch {
            throw LegacyMigrationError.backupFailed(error.localizedDescription)
        }

        return targetURL
    }
}
