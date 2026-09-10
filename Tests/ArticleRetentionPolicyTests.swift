import XCTest
import GRDB
@testable import PaperRssCore

@MainActor
final class ArticleRetentionPolicyTests: XCTestCase {
    var store: AppStore!

    override func setUp() async throws {
        try await super.setUp()
        store = AppStore(testDatabase: AppDatabase.empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func seedEntry(
        feedID: String,
        entryID: String,
        publishedAt: Date?,
        createdAt: Date? = nil,
        dateArrived: Date? = nil,
        isRead: Bool,
        isStarred: Bool,
        contentHTML: String = "<p>正文内容</p>",
        hasCache: Bool = false,
        hasArtifact: Bool = false
    ) throws -> String {
        let now = Date().timeIntervalSince1970
        let itemID = "\(feedID)|\(entryID)".stableDigest
        let pubTimestamp = publishedAt?.timeIntervalSince1970
        let createdTimestamp = (createdAt ?? dateArrived ?? publishedAt ?? Date()).timeIntervalSince1970
        let arrivedTimestamp = (dateArrived ?? createdAt ?? publishedAt ?? Date()).timeIntervalSince1970

        try store.libraryDatabase.write { db in
            let item = ItemRecord(
                id: itemID,
                accountID: "local-default",
                externalID: itemID,
                feedID: feedID,
                createdAt: createdTimestamp,
                updatedAt: now
            )
            try item.save(db)

            let article = ArticleRecord(
                itemID: itemID,
                title: "标题 \(entryID)",
                author: "作者",
                url: "https://example.com/\(entryID)",
                publishedAt: pubTimestamp,
                summary: "摘要 \(entryID)",
                contentHTML: contentHTML,
                contentUpdatedAt: now
            )
            try article.save(db)

            let state = ArticleStateRecord(
                itemID: itemID,
                isRead: isRead,
                isStarred: isStarred,
                dateArrived: arrivedTimestamp,
                updatedAt: now
            )
            try state.save(db)

            if hasCache {
                let cache = ArticleCacheRecord(
                    itemID: itemID,
                    text: "提取正文 \(entryID)",
                    html: "<p>提取正文 \(entryID)</p>",
                    imageUrlsJSON: "[]",
                    fetchedAt: now,
                    sourceURL: "https://example.com/\(entryID)",
                    isSanitized: true
                )
                try cache.save(db)
            }

            if hasArtifact {
                let artifact = AIArtifactRecord(
                    id: UUID().uuidString,
                    accountID: "local-default",
                    itemID: itemID,
                    subjectKey: "article:\(itemID)",
                    kind: AIArtifactKind.summary.rawValue,
                    contentHash: "hash123",
                    model: "test-model",
                    targetLanguage: "zh-Hans",
                    promptVersion: 1,
                    content: "AI摘要 \(entryID)",
                    segmentsJSON: nil,
                    selectionText: nil,
                    selectionArticleHash: nil,
                    selectionAnchorJSON: nil,
                    isComplete: true,
                    isDeleted: false,
                    createdAt: now,
                    updatedAt: now
                )
                try artifact.save(db)
            }
        }

        return itemID
    }

    // MARK: - 1. ArticleRetentionPolicy 枚举定义测试

    func testArticleRetentionPolicyProperties() throws {
        XCTAssertEqual(ArticleRetentionPolicy.allCases, [.sixMonths, .oneYear, .forever])
        XCTAssertEqual(ArticleRetentionPolicy.sixMonths.days, 180)
        XCTAssertEqual(ArticleRetentionPolicy.oneYear.days, 365)
        XCTAssertNil(ArticleRetentionPolicy.forever.days)

        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: "PaperRss.appLanguage")
        defaults.set(AppLanguage.zhHans.rawValue, forKey: "PaperRss.appLanguage")
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: "PaperRss.appLanguage")
            } else {
                defaults.removeObject(forKey: "PaperRss.appLanguage")
            }
        }

        XCTAssertEqual(ArticleRetentionPolicy.sixMonths.title, "180 天（默认）")
        XCTAssertEqual(ArticleRetentionPolicy.oneYear.title, "1 年")
        XCTAssertEqual(ArticleRetentionPolicy.forever.title, "永久保留")

        defaults.set(AppLanguage.en.rawValue, forKey: "PaperRss.appLanguage")
        XCTAssertEqual(ArticleRetentionPolicy.sixMonths.title, "180 Days (Default)")
        XCTAssertEqual(ArticleRetentionPolicy.oneYear.title, "1 Year")
        XCTAssertEqual(ArticleRetentionPolicy.forever.title, "Keep Forever")

        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff180 = ArticleRetentionPolicy.sixMonths.cutoffDate(relativeTo: referenceDate)
        XCTAssertNotNil(cutoff180)
        let expected180 = Calendar.current.date(byAdding: .day, value: -180, to: referenceDate)
        XCTAssertEqual(cutoff180, expected180)

        let cutoffYear = ArticleRetentionPolicy.oneYear.cutoffDate(relativeTo: referenceDate)
        XCTAssertNotNil(cutoffYear)
        let expectedYear = Calendar.current.date(byAdding: .day, value: -365, to: referenceDate)
        XCTAssertEqual(cutoffYear, expectedYear)

        XCTAssertNil(ArticleRetentionPolicy.forever.cutoffDate(relativeTo: referenceDate))

        // 验证旧版 30 天 / 60 天 / 90 天及别名平滑迁移至 180 天（默认）
        let legacyKeys = ["1month", "3months", "30days", "60days", "90days", "6months", "180days", "halfYear"]
        for key in legacyKeys {
            XCTAssertEqual(ArticleRetentionPolicy(rawValue: key), .sixMonths, "Key \(key) 应解析或迁移为 .sixMonths")
        }
        XCTAssertEqual(ArticleRetentionPolicy(rawValue: "1year"), .oneYear)
        XCTAssertEqual(ArticleRetentionPolicy(rawValue: "365days"), .oneYear)
        XCTAssertEqual(ArticleRetentionPolicy(rawValue: "forever"), .forever)
        XCTAssertNil(ArticleRetentionPolicy(rawValue: "unknown_value"))

        let legacy30JSON = "\"30days\"".data(using: .utf8)!
        let decoded30 = try JSONDecoder().decode(ArticleRetentionPolicy.self, from: legacy30JSON)
        XCTAssertEqual(decoded30, .sixMonths)

        let legacy60JSON = "\"60days\"".data(using: .utf8)!
        let decoded60 = try JSONDecoder().decode(ArticleRetentionPolicy.self, from: legacy60JSON)
        XCTAssertEqual(decoded60, .sixMonths)

        let legacy90JSON = "\"3months\"".data(using: .utf8)!
        let decoded90 = try JSONDecoder().decode(ArticleRetentionPolicy.self, from: legacy90JSON)
        XCTAssertEqual(decoded90, .sixMonths)
    }

    // MARK: - 2. 深度清理与铁律保护测试

    func testPurgeOldReadArticlesProtectsUnreadAndStarred() async throws {
        let feed = try store.localProvider.addFeed(
            title: "科技资讯",
            feedURL: URL(string: "https://example.com/tech.xml")!
        )
        let feedID = feed.id.uuidString

        let now = Date()
        let oldDate = Calendar.current.date(byAdding: .day, value: -120, to: now)!
        let recentDate = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let ancientDate = Calendar.current.date(byAdding: .day, value: -200, to: now)!

        // 1. 120 天前已读未标星 -> 应当被清理正文与缓存
        let idOldRead = try seedEntry(
            feedID: feedID,
            entryID: "old-read",
            publishedAt: oldDate,
            createdAt: oldDate,
            dateArrived: oldDate,
            isRead: true,
            isStarred: false,
            hasCache: true,
            hasArtifact: true
        )

        // 2. 120 天前未读未标星 -> 铁律：永不清理！
        let idOldUnread = try seedEntry(
            feedID: feedID,
            entryID: "old-unread",
            publishedAt: oldDate,
            createdAt: oldDate,
            dateArrived: oldDate,
            isRead: false,
            isStarred: false,
            hasCache: true
        )

        // 3. 120 天前已读标星 -> 铁律：永不清理！
        let idOldStarred = try seedEntry(
            feedID: feedID,
            entryID: "old-starred",
            publishedAt: oldDate,
            createdAt: oldDate,
            dateArrived: oldDate,
            isRead: true,
            isStarred: true,
            hasCache: true
        )

        // 4. 10 天前已读未标星 -> 保留期内，不应清理！
        let idRecentRead = try seedEntry(
            feedID: feedID,
            entryID: "recent-read",
            publishedAt: recentDate,
            createdAt: recentDate,
            dateArrived: recentDate,
            isRead: true,
            isStarred: false,
            hasCache: true
        )

        // 5. 发布时间老于 200 天但在最近拉取（dateArrived 为 10 天前）-> 对齐 NetNewsWire dateArrived 判定，保留期内绝不清理！
        let idAncientPubRecentArrived = try seedEntry(
            feedID: feedID,
            entryID: "ancient-pub-recent-arrived",
            publishedAt: ancientDate,
            createdAt: recentDate,
            dateArrived: recentDate,
            isRead: true,
            isStarred: false,
            hasCache: true
        )

        // 执行 90 天保留清理
        let cutoff90 = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        let pruned = try store.localProvider.purgeOldReadArticles(cutoffDate: cutoff90)

        XCTAssertEqual(pruned, 1, "只应淘汰 1 篇超过 90 天且已读未标星的文章")

        // 验证 1：淘汰条目的正文、缓存、AI产物被删除
        let article1 = try await store.localProvider.articleRepository.fetchArticle(itemID: idOldRead)
        XCTAssertNil(article1, "正文 articles 应被物理删除")

        let cache1 = try store.localProvider.fetchCache(entryID: idOldRead)
        XCTAssertNil(cache1, "正文提取缓存 article_caches 应被物理删除")

        let artifact1 = try store.localProvider.fetchArtifact(entryID: idOldRead, kind: .summary)
        XCTAssertNil(artifact1, "AI 摘要产物应被物理删除")

        // 验证 2：墓碑机制（Tombstone）——保留 items 与 article_states
        let item1 = try await store.localProvider.articleRepository.fetchItem(id: idOldRead)
        XCTAssertNotNil(item1, "身份 items 必须保留为墓碑")

        let state1 = try store.libraryDatabase.read { db in
            try ArticleStateRecord.filter(Column("item_id") == idOldRead).fetchOne(db)
        }
        XCTAssertNotNil(state1, "已读状态 article_states 必须保留为墓碑")
        XCTAssertEqual(state1?.isRead, true, "墓碑必须保持已读状态")

        // 验证 3：未读文章完好无损
        let article2 = try await store.localProvider.articleRepository.fetchArticle(itemID: idOldUnread)
        XCTAssertNotNil(article2, "未读文章绝对永久保留")

        // 验证 4：标星文章完好无损
        let article3 = try await store.localProvider.articleRepository.fetchArticle(itemID: idOldStarred)
        XCTAssertNotNil(article3, "星标文章绝对永久保留")

        // 验证 5：近期已读文章完好无损
        let article4 = try await store.localProvider.articleRepository.fetchArticle(itemID: idRecentRead)
        XCTAssertNotNil(article4, "保留期内文章完好无损")

        // 验证 6：发布于 200 天前但最近到达的已读文章完好无损（对齐 NetNewsWire dateArrived 判定）
        let article5 = try await store.localProvider.articleRepository.fetchArticle(itemID: idAncientPubRecentArrived)
        XCTAssertNotNil(article5, "发布虽早于 200 天但拉取到达在保留期内的已读文章完好无损")
    }

    // MARK: - 3. 防幽灵复活（Ghost Resurrection Protection）测试

    func testTombstonePreventsGhostResurrection() async throws {
        let feed = try store.localProvider.addFeed(
            title: "防复活测试源",
            feedURL: URL(string: "https://example.com/ghost.xml")!
        )
        let feedID = feed.id.uuidString

        let oldDate = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        let id = try seedEntry(
            feedID: feedID,
            entryID: "ghost-candidate",
            publishedAt: oldDate,
            isRead: true,
            isStarred: false
        )

        // 清理超期文章正文，转为墓碑
        let cutoff90 = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        _ = try store.localProvider.purgeOldReadArticles(cutoffDate: cutoff90)

        // 模拟后续 RSS 刷新：源站 XML 依然包含该条目
        let incomingParsed = ParsedFeedEntry(
            id: "ghost-candidate",
            title: "幽灵文章标题",
            author: "作者",
            url: URL(string: "https://example.com/ghost-candidate"),
            publishedAt: oldDate,
            summary: "摘要",
            contentHTML: "<p>源站重新拉到的正文</p>"
        )

        let newUnreadEntries = try await store.localProvider.articleRepository.mergeParsedEntries(
            accountID: "local-default",
            feedID: feedID,
            parsedEntries: [incomingParsed]
        )

        XCTAssertTrue(newUnreadEntries.isEmpty, "墓碑必须阻止老文章作为新未读文章复活！")

        let state = try store.libraryDatabase.read { db in
            try ArticleStateRecord.filter(Column("item_id") == id).fetchOne(db)
        }
        XCTAssertEqual(state?.isRead, true, "老文章在数据库中必须维持已读状态")
    }

    func testArticleBackfillRestoresPrunedArticleAndPreservesReadState() async throws {
        let feed = try store.localProvider.addFeed(
            title: "正文回填测试源",
            feedURL: URL(string: "https://example.com/backfill.xml")!
        )
        let feedID = feed.id.uuidString

        let oldDate = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        let id = try seedEntry(
            feedID: feedID,
            entryID: "backfill-candidate",
            publishedAt: oldDate,
            isRead: true,
            isStarred: false
        )

        // 1. 清理超期文章正文，转为墓碑（Item 与 State 保留，Article 正文被清理）
        let cutoff90 = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        _ = try store.localProvider.purgeOldReadArticles(cutoffDate: cutoff90)

        // 验证正文已为空且列表查不到
        let purgedArticle = try await store.localProvider.articleRepository.fetchArticle(itemID: id)
        XCTAssertNil(purgedArticle, "清理后 ArticleRecord 正文应被物理删除")
        let purgedEntry = try await store.localProvider.articleRepository.fetchEntry(id: id)
        XCTAssertNil(purgedEntry, "清理后因 INNER JOIN 丢失正文，fetchEntry 应为 nil")

        // 2. 模拟源站重新拉取，源站 XML 依然包含该条目
        let incomingParsed = ParsedFeedEntry(
            id: "backfill-candidate",
            title: "回填恢复文章标题",
            author: "回填作者",
            url: URL(string: "https://example.com/backfill-candidate"),
            publishedAt: oldDate,
            summary: "回填摘要",
            contentHTML: "<p>回填恢复的完整正文内容</p>"
        )

        let newUnreadEntries = try await store.localProvider.articleRepository.mergeParsedEntries(
            accountID: "local-default",
            feedID: feedID,
            parsedEntries: [incomingParsed]
        )

        // 3. 验证回填后特性：
        // (a) 不作为新未读文章入库（不增加未读数，不计入 newUnreadEntries）
        XCTAssertTrue(newUnreadEntries.isEmpty, "回填文章不得作为新未读条目计入 newUnreadEntries")

        // (b) ArticleRecord 正文成功回填恢复
        let restoredArticle = try await store.localProvider.articleRepository.fetchArticle(itemID: id)
        XCTAssertNotNil(restoredArticle, "正文回填后 ArticleRecord 必须恢复存在")
        XCTAssertEqual(restoredArticle?.title, "回填恢复文章标题")
        XCTAssertEqual(restoredArticle?.author, "回填作者")
        XCTAssertEqual(restoredArticle?.contentHTML, "<p>回填恢复的完整正文内容</p>")

        // (c) article_states 维持已读状态
        let state = try store.libraryDatabase.read { db in
            try ArticleStateRecord.filter(Column("item_id") == id).fetchOne(db)
        }
        XCTAssertEqual(state?.isRead, true, "回填文章必须保持已读状态 (is_read == 1)")

        // (d) 时间线投影恢复可见且可正常阅读
        let restoredEntry = try await store.localProvider.articleRepository.fetchEntry(id: id)
        XCTAssertNotNil(restoredEntry, "回填后时间线投影与聚合查询必须恢复可见")
        XCTAssertEqual(restoredEntry?.isRead, true)
    }

    // MARK: - 4. 列表与侧边栏投影测试

    func testTimelineAndSidebarExcludePrunedTombstones() async throws {
        let feed = try store.localProvider.addFeed(
            title: "投影测试源",
            feedURL: URL(string: "https://example.com/projection.xml")!
        )
        let feedID = feed.id.uuidString

        let oldDate = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        let idPruned = try seedEntry(
            feedID: feedID,
            entryID: "pruned-1",
            publishedAt: oldDate,
            isRead: true,
            isStarred: false
        )

        let idUnread = try seedEntry(
            feedID: feedID,
            entryID: "unread-1",
            publishedAt: oldDate,
            isRead: false,
            isStarred: false
        )

        let idStarred = try seedEntry(
            feedID: feedID,
            entryID: "starred-1",
            publishedAt: oldDate,
            isRead: true,
            isStarred: true
        )

        // 清理超期文章
        let cutoff90 = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        _ = try store.localProvider.purgeOldReadArticles(cutoffDate: cutoff90)

        // 1. 验证 Timeline 投影：不包含正文已被删除的墓碑
        let items = try store.localProvider.timelineQueryService.fetchListItems(scope: .all)
        let itemIDs = Set(items.map(\.id))
        XCTAssertFalse(itemIDs.contains(idPruned), "Timeline 列表必须排除正文已淘汰的墓碑条目")
        XCTAssertTrue(itemIDs.contains(idUnread), "Timeline 列表必须包含未读文章")
        XCTAssertTrue(itemIDs.contains(idStarred), "Timeline 列表必须包含星标文章")

        // 2. 验证 fetchAllEntries
        let allEntries = try await store.localProvider.articleRepository.fetchAllEntries()
        let entryIDs = Set(allEntries.map(\.id))
        XCTAssertFalse(entryIDs.contains(idPruned), "fetchAllEntries 必须排除墓碑条目")
        XCTAssertTrue(entryIDs.contains(idUnread))
        XCTAssertTrue(entryIDs.contains(idStarred))

        // 3. 验证侧边栏计数
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let counts = try store.localProvider.timelineQueryService.fetchSidebarCounts(startOfDayTimestamp: startOfDay)
        XCTAssertEqual(counts.allUnread, 1)
        XCTAssertEqual(counts.starred, 1)
    }

    // MARK: - 5. 墓碑超期回收测试

    func testPurgeExpiredTombstones() async throws {
        let feed = try store.localProvider.addFeed(
            title: "墓碑回收源",
            feedURL: URL(string: "https://example.com/tombstone.xml")!
        )
        let feedID = feed.id.uuidString

        let ancientDate = Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        let date120 = Calendar.current.date(byAdding: .day, value: -120, to: Date())!

        // 1. 到达与创建均在 200 天前
        let idAncient = try seedEntry(
            feedID: feedID,
            entryID: "ancient",
            publishedAt: ancientDate,
            createdAt: ancientDate,
            dateArrived: ancientDate,
            isRead: true,
            isStarred: false
        )

        // 2. 创建于 200 天前，但到达于 120 天前 -> 90 天清理后成为墓碑，但在 180 天墓碑回收期内必须受保护，不得提前回收
        let idYoungTombstone = try seedEntry(
            feedID: feedID,
            entryID: "young-tombstone",
            publishedAt: ancientDate,
            createdAt: ancientDate,
            dateArrived: date120,
            isRead: true,
            isStarred: false
        )

        // 变为墓碑（90 天已读文章正文清理）
        let cutoff90 = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let pruned = try store.localProvider.purgeOldReadArticles(cutoffDate: cutoff90)
        XCTAssertEqual(pruned, 2, "两篇正文均超过 90 天，均转化为墓碑")

        // 回收 180 天前的孤立墓碑（按 dateArrived 判定）
        let tombstoneCutoff = Calendar.current.date(byAdding: .day, value: -180, to: Date())!
        let tombstonesPurged = try store.localProvider.purgeExpiredTombstones(cutoffDate: tombstoneCutoff)

        XCTAssertEqual(tombstonesPurged, 1, "只应回收 1 个 dateArrived 超过 180 天的孤立墓碑")

        let item1 = try await store.localProvider.articleRepository.fetchItem(id: idAncient)
        XCTAssertNil(item1, "超期墓碑已彻底从 items 表安全回收")

        let item2 = try await store.localProvider.articleRepository.fetchItem(id: idYoungTombstone)
        XCTAssertNotNil(item2, "到达仅 120 天的墓碑受 dateArrived 保护，未被误删")
    }

    // MARK: - 6. StorageStats 与 DeepCleanStorage 测试

    func testStorageStatsAndDeepCleanStorage() async throws {
        let feed = try store.localProvider.addFeed(
            title: "存储统计源",
            feedURL: URL(string: "https://example.com/stats.xml")!
        )
        let feedID = feed.id.uuidString

        let oldDate = Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        let recentDate = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        let body = String(repeating: "超大正文数据段落，用于占用数据库物理空间。", count: 200)

        let oldReadID = try seedEntry(
            feedID: feedID,
            entryID: "stats-old-read",
            publishedAt: oldDate,
            createdAt: oldDate,
            dateArrived: oldDate,
            isRead: true,
            isStarred: false,
            contentHTML: body,
            hasCache: true
        )

        let oldUnreadID = try seedEntry(
            feedID: feedID,
            entryID: "stats-old-unread",
            publishedAt: oldDate,
            createdAt: oldDate,
            dateArrived: oldDate,
            isRead: false,
            isStarred: false,
            contentHTML: body,
            hasCache: true
        )

        let oldStarredID = try seedEntry(
            feedID: feedID,
            entryID: "stats-old-starred",
            publishedAt: oldDate,
            createdAt: oldDate,
            dateArrived: oldDate,
            isRead: true,
            isStarred: true,
            contentHTML: body,
            hasCache: true
        )

        let recentReadID = try seedEntry(
            feedID: feedID,
            entryID: "stats-recent-read",
            publishedAt: recentDate,
            createdAt: recentDate,
            dateArrived: recentDate,
            isRead: true,
            isStarred: false,
            contentHTML: body,
            hasCache: true
        )

        // 5. 发布时间早于 200 天，但在 5 天前才拉取到达本地的已读文章（对齐 NetNewsWire dateArrived 判定）-> 铁律：保留期内绝不清理！
        let ancientPubRecentID = try seedEntry(
            feedID: feedID,
            entryID: "stats-ancient-pub-recent",
            publishedAt: oldDate,
            createdAt: recentDate,
            dateArrived: recentDate,
            isRead: true,
            isStarred: false,
            contentHTML: body,
            hasCache: true
        )

        // 默认保留期限应为 180 天 (.sixMonths)
        XCTAssertEqual(store.articleRetentionPolicy, .sixMonths)

        let initialStats = try store.storageStats()
        XCTAssertGreaterThan(initialStats.databaseFileSizeBytes, 0)
        XCTAssertGreaterThan(initialStats.totalDiskBytes, 0)
        XCTAssertEqual(initialStats.totalArticlesCount, 5)
        XCTAssertEqual(initialStats.readArticlesCount, 4)
        XCTAssertEqual(initialStats.starredArticlesCount, 1)
        XCTAssertEqual(initialStats.cacheEntriesCount, 5)
        XCTAssertGreaterThan(initialStats.readArticlesDataSizeBytes, 0)
        XCTAssertEqual(initialStats.prunableArticlesCount, 1, "只有 1 篇拉取到达超过 180 天的已读未标星文章可清理")
        XCTAssertGreaterThan(initialStats.prunableDataSizeBytes, 0)

        // 执行一键深度清理
        let cleanResult = try await store.deepCleanStorage()
        XCTAssertEqual(cleanResult.prunedArticles, 1, "深度清理只应清理 1 篇拉取到达过期的已读未标星文章")

        let postStats = try store.storageStats()
        XCTAssertEqual(postStats.totalArticlesCount, 4, "未读、标星、近期已读以及近期拉取的老文章正文均需保留")
        XCTAssertEqual(postStats.cacheEntriesCount, 4, "铁律保护：未读、标星及近期已读网页缓存绝不能被误删！")
        XCTAssertEqual(postStats.prunableArticlesCount, 0, "清理完成后无超期可清理文章")
        XCTAssertEqual(postStats.prunableDataSizeBytes, 0)

        // 验证各文章缓存存在性
        XCTAssertNil(try store.localProvider.fetchCache(entryID: oldReadID), "过期已读缓存应被删除")
        XCTAssertNotNil(try store.localProvider.fetchCache(entryID: oldUnreadID), "未读文章缓存必须完好无损")
        XCTAssertNotNil(try store.localProvider.fetchCache(entryID: oldStarredID), "星标文章缓存必须完好无损")
        XCTAssertNotNil(try store.localProvider.fetchCache(entryID: recentReadID), "近期已读文章缓存必须完好无损")
        XCTAssertNotNil(try store.localProvider.fetchCache(entryID: ancientPubRecentID), "老发布近期拉取文章缓存必须完好无损")
        let ancientPubArticle = try await store.localProvider.articleRepository.fetchArticle(itemID: ancientPubRecentID)
        XCTAssertNotNil(ancientPubArticle, "老发布近期拉取文章正文必须完好无损")
    }

    func testDeepCleanStorageWithForeverPolicyDoesNotPruneAnything() async throws {
        let feed = try store.localProvider.addFeed(
            title: "永久保留测试源",
            feedURL: URL(string: "https://example.com/forever.xml")!
        )
        let feedID = feed.id.uuidString

        let ancientDate = Calendar.current.date(byAdding: .day, value: -500, to: Date())!
        let ancientID = try seedEntry(
            feedID: feedID,
            entryID: "ancient-read",
            publishedAt: ancientDate,
            isRead: true,
            isStarred: false,
            hasCache: true
        )

        store.setArticleRetentionPolicy(.forever)
        XCTAssertEqual(store.articleRetentionPolicy, .forever)

        let initialStats = try store.storageStats()
        XCTAssertEqual(initialStats.prunableArticlesCount, 0, "永久保留策略下可清理文章数为 0")
        XCTAssertEqual(initialStats.prunableDataSizeBytes, 0)
        XCTAssertGreaterThan(initialStats.readArticlesDataSizeBytes, 0, "历史数据量正常统计")

        let cleanResult = try await store.deepCleanStorage()
        XCTAssertEqual(cleanResult.prunedArticles, 0, "永久保留策略下一键清理不淘汰任何文章")

        let postStats = try store.storageStats()
        XCTAssertEqual(postStats.totalArticlesCount, 1)
        XCTAssertEqual(postStats.cacheEntriesCount, 1)
        XCTAssertNotNil(try store.localProvider.fetchCache(entryID: ancientID), "永久保留策略下缓存完整保留")
    }

    // MARK: - 7. 策略切换对可清理数据量计算的动态响应测试

    func testStorageStatsPrunableCalculationWithDifferentPolicies() throws {
        let feed = try store.localProvider.addFeed(
            title: "策略动态计算源",
            feedURL: URL(string: "https://example.com/policies.xml")!
        )
        let feedID = feed.id.uuidString

        let date200 = Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        let date500 = Calendar.current.date(byAdding: .day, value: -500, to: Date())!

        _ = try seedEntry(
            feedID: feedID,
            entryID: "entry-200d",
            publishedAt: date200,
            isRead: true,
            isStarred: false,
            contentHTML: "<p>200天前的正文内容</p>",
            hasCache: true
        )

        _ = try seedEntry(
            feedID: feedID,
            entryID: "entry-500d",
            publishedAt: date500,
            isRead: true,
            isStarred: false,
            contentHTML: "<p>500天前的正文内容</p>",
            hasCache: true
        )

        // 1. .sixMonths (180 天)：200 天和 500 天均超期
        store.setArticleRetentionPolicy(.sixMonths)
        let stats6m = try store.storageStats()
        XCTAssertEqual(stats6m.prunableArticlesCount, 2)
        XCTAssertGreaterThan(stats6m.prunableDataSizeBytes, 0)
        XCTAssertEqual(stats6m.readArticlesDataSizeBytes, stats6m.prunableDataSizeBytes)

        // 2. .oneYear (365 天)：仅 500 天超期，200 天仍在保留期内
        store.setArticleRetentionPolicy(.oneYear)
        let stats1y = try store.storageStats()
        XCTAssertEqual(stats1y.prunableArticlesCount, 1)
        XCTAssertGreaterThan(stats1y.prunableDataSizeBytes, 0)
        XCTAssertLessThan(stats1y.prunableDataSizeBytes, stats6m.prunableDataSizeBytes)
        XCTAssertEqual(stats1y.readArticlesDataSizeBytes, stats6m.readArticlesDataSizeBytes)

        // 3. .forever：不可清理
        store.setArticleRetentionPolicy(.forever)
        let statsForever = try store.storageStats()
        XCTAssertEqual(statsForever.prunableArticlesCount, 0)
        XCTAssertEqual(statsForever.prunableDataSizeBytes, 0)
        XCTAssertEqual(statsForever.readArticlesDataSizeBytes, stats6m.readArticlesDataSizeBytes)
    }

    func testStorageStatsWithMissingPublishedAtFallbackAndEmptyContent() throws {
        let feed = try store.localProvider.addFeed(
            title: "回退边界测试源",
            feedURL: URL(string: "https://example.com/fallback.xml")!
        )
        let feedID = feed.id.uuidString

        let oldDate = Calendar.current.date(byAdding: .day, value: -250, to: Date())!
        let recentDate = Calendar.current.date(byAdding: .day, value: -10, to: Date())!

        // 1. publishedAt 为 nil，但 createdAt 超过 180 天 -> 应当通过 i.created_at 回退被统计为可清理
        _ = try seedEntry(
            feedID: feedID,
            entryID: "no-pub-ancient",
            publishedAt: nil,
            createdAt: oldDate,
            isRead: true,
            isStarred: false,
            contentHTML: "<p>缺失发布时间的老文章</p>",
            hasCache: false
        )

        // 2. publishedAt 为 nil，createdAt 近期 -> 不应被统计为可清理
        _ = try seedEntry(
            feedID: feedID,
            entryID: "no-pub-recent",
            publishedAt: nil,
            createdAt: recentDate,
            isRead: true,
            isStarred: false,
            contentHTML: "<p>缺失发布时间的近期文章</p>",
            hasCache: false
        )

        // 3. 正文内容与摘要为空字符，且无缓存 -> 验证 COUNT 正确，字节安全累加 0
        _ = try seedEntry(
            feedID: feedID,
            entryID: "empty-content",
            publishedAt: oldDate,
            createdAt: oldDate,
            isRead: true,
            isStarred: false,
            contentHTML: "",
            hasCache: false
        )

        store.setArticleRetentionPolicy(.sixMonths)
        let stats = try store.storageStats()
        // 2 篇超期：no-pub-ancient 与 empty-content
        XCTAssertEqual(stats.prunableArticlesCount, 2)
        XCTAssertGreaterThan(stats.prunableDataSizeBytes, 0)
        XCTAssertGreaterThan(stats.readArticlesDataSizeBytes, stats.prunableDataSizeBytes)
    }

    // MARK: - 8. 后台维护调度与节流测试

    func testPerformBackgroundMaintenanceThrottling() async throws {
        let feed = try store.localProvider.addFeed(
            title: "维护调度源",
            feedURL: URL(string: "https://example.com/maint.xml")!
        )
        let feedID = feed.id.uuidString

        let oldDate = Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        _ = try seedEntry(
            feedID: feedID,
            entryID: "maint-article",
            publishedAt: oldDate,
            isRead: true,
            isStarred: false
        )

        store.setArticleRetentionPolicy(.sixMonths)

        // 第一次维护（force = true）：成功执行清理
        await store.performBackgroundMaintenance(force: true)
        let statsAfterFirst = try store.storageStats()
        XCTAssertEqual(statsAfterFirst.totalArticlesCount, 0)

        // 插入新超期文章
        _ = try seedEntry(
            feedID: feedID,
            entryID: "maint-article-2",
            publishedAt: oldDate,
            isRead: true,
            isStarred: false
        )

        // 第二次维护（force = false，距上次不到 24h）：被节流拦截
        await store.performBackgroundMaintenance(force: false)
        let statsAfterThrottle = try store.storageStats()
        XCTAssertEqual(statsAfterThrottle.totalArticlesCount, 1, "节流期内不应触发重复维护")

        // 强制维护（force = true）：绕过节流立即执行
        await store.performBackgroundMaintenance(force: true)
        let statsAfterForce = try store.storageStats()
        XCTAssertEqual(statsAfterForce.totalArticlesCount, 0, "强制维护应立即清理")
    }

    // MARK: - 9. 保留期限判定基准对齐 NetNewsWire dateArrived 测试

    func testRetentionCutoffUsesDateArrivedRatherThanPublishedAt() async throws {
        let feed = try store.localProvider.addFeed(
            title: "到达时间判定源",
            feedURL: URL(string: "https://example.com/arrived.xml")!
        )
        let feedID = feed.id.uuidString

        let date250 = Calendar.current.date(byAdding: .day, value: -250, to: Date())!
        let date200 = Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        let date5 = Calendar.current.date(byAdding: .day, value: -5, to: Date())!

        // 1. 发布于 250 天前，拉取到达于 200 天前（超过 180 天保留期） -> 应当被清理
        let idExpired = try seedEntry(
            feedID: feedID,
            entryID: "arrived-expired",
            publishedAt: date250,
            createdAt: date200,
            dateArrived: date200,
            isRead: true,
            isStarred: false,
            hasCache: true
        )

        // 2. 发布于 250 天前，但在 5 天前才刚拉取到达本地 -> 享有完整的 180 天留存期，绝不应被统计或清理！
        let idRecentlyArrived = try seedEntry(
            feedID: feedID,
            entryID: "arrived-recent",
            publishedAt: date250,
            createdAt: date5,
            dateArrived: date5,
            isRead: true,
            isStarred: false,
            hasCache: true
        )

        // 3. 发布于 5 天前（近期发布），但本地到达记录早于 200 天前（超期到达） -> 到达超期即清理，彻底证明以到达时间为准
        let idRecentPubOldArrived = try seedEntry(
            feedID: feedID,
            entryID: "recent-pub-old-arrived",
            publishedAt: date5,
            createdAt: date200,
            dateArrived: date200,
            isRead: true,
            isStarred: false,
            hasCache: true
        )

        store.setArticleRetentionPolicy(.sixMonths)

        // storageStats 统计核查：2 篇超期（idExpired 与 idRecentPubOldArrived）
        let stats = try store.storageStats()
        XCTAssertEqual(stats.prunableArticlesCount, 2, "按拉取到达时间判定，2 篇到达超期的文章可清理")

        // 执行清理
        let result = try await store.deepCleanStorage()
        XCTAssertEqual(result.prunedArticles, 2, "只应淘汰到达超期的文章")

        // 验证正文
        let expiredArticle = try await store.localProvider.articleRepository.fetchArticle(itemID: idExpired)
        XCTAssertNil(expiredArticle, "拉取到达超期文章已被淘汰")

        let recentPubOldArrivedArticle = try await store.localProvider.articleRepository.fetchArticle(itemID: idRecentPubOldArrived)
        XCTAssertNil(recentPubOldArrivedArticle, "即使发布时间很新，但拉取到达已超期的已读文章同样被淘汰")

        let recentArticle = try await store.localProvider.articleRepository.fetchArticle(itemID: idRecentlyArrived)
        XCTAssertNotNil(recentArticle, "发布虽早但最近下载拉取的文章必须完整享有留存期，绝不清理（对齐 NetNewsWire）")
    }
}
