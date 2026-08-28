import XCTest
import GRDB
@testable import PaperRssCore

/// 应用核心功能与用户操作回归测试套件。
///
/// 覆盖场景：
/// 1. 文章标题、正文与元数据更新/变更回归
/// 2. 点击单个 Feed / 多选 Feed / 点击文件夹的筛选逻辑
/// 3. 阅读状态（已读、星标）与侧边栏未读计数联动
/// 4. 源管理（添加、删除、重命名文件夹、移动源归属）
/// 5. 离线正文缓存与阅读器加载
@MainActor
final class AppFeatureRegressionTests: XCTestCase {
    var tempDir: URL!
    var database: LibraryDatabase!
    var provider: LocalAccountProvider!
    var store: AppStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperRssFeatureRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("library.sqlite")
        database = try LibraryDatabase(databaseURL: dbURL)
        provider = LocalAccountProvider(accountID: "local-default", database: database)
        try provider.ensureAccountExists()

        // 构造沙箱测试 AppStore
        store = AppStore(testDatabase: AppDatabase.empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
    }

    override func tearDown() async throws {
        store = nil
        provider = nil
        database = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - 非阻断式瞬时提示 (toast) 冷却去重回归

    /// 翻译随滚动批量触发，未配置 API Key 等失败会连续多次上报；
    /// 瞬时提示必须在冷却期内去重，只产生一次 toast。
    func testTransientNoticeDeduplicatesRepeatedTranslationFailures() async throws {
        let localStore = AppStore(testDatabase: AppDatabase.empty, feedFetcher: { _ in
            FeedFetchResult.notModified(etag: nil, lastModified: nil)
        })
        let missingKeyMessage = LLMServiceError.missingAPIKey.localizedDescription

        // 首次失败：发出通知
        localStore.emitTransientNotice(missingKeyMessage)
        let first = localStore.transientNotice
        XCTAssertNotNil(first)

        // 冷却期内的重复失败（滚动触发多批次翻译）：不生成新通知
        localStore.emitTransientNotice(missingKeyMessage)
        localStore.emitTransientNotice(missingKeyMessage)
        XCTAssertEqual(localStore.transientNotice?.id, first?.id, "冷却期内重复触发必须去重")

        // 消费后置空；新消息再次触发时生成新通知
        localStore.dismissTransientNotice()
        XCTAssertNil(localStore.transientNotice)
        localStore.emitTransientNotice("网络连接中断")
        XCTAssertNotNil(localStore.transientNotice)
        XCTAssertNotEqual(localStore.transientNotice?.id, first?.id)
    }

    // MARK: - 1. 文章标题与元数据更新回归 (Article Title & Metadata Mutation)

    func testArticleTitleAndMetadataUpdateRegression() async throws {
        // 1. 添加订阅源
        let feed = try store.localProvider.addFeed(
            title: "科技早报",
            feedURL: URL(string: "https://tech.example.com/rss.xml")!,
            siteURL: URL(string: "https://tech.example.com")!,
            folder: "Tech"
        )
        let feedIDString = feed.id.uuidString

        // 2. 初始拉取入库一篇文章
        let initialParsed = ParsedFeedEntry(
            id: "article-101",
            title: "初始标题：Swift 6.0 正式发布",
            author: "Apple",
            url: URL(string: "https://tech.example.com/101"),
            publishedAt: Date(timeIntervalSince1970: 1700000000),
            summary: "这是文章摘要",
            contentHTML: "<p>Swift 6.0 带来了完全并发检查。</p>"
        )

        let initialInserted = try store.libraryDatabase.write { db in
            try self.store.localProvider.articleRepository.mergeParsedEntries(
                accountID: "local-default",
                feedID: feedIDString,
                parsedEntries: [initialParsed],
                in: db
            )
        }
        XCTAssertEqual(initialInserted.count, 1)
        let articleID = initialInserted[0].id

        // 标记为星标，验证状态
        store.toggleStar(entryID: articleID)
        store.reloadState()

        let initialEntry = store.entry(id: articleID)
        XCTAssertNotNil(initialEntry)
        XCTAssertEqual(initialEntry?.title, "初始标题：Swift 6.0 正式发布")
        XCTAssertEqual(initialEntry?.isStarred, true)
        XCTAssertEqual(initialEntry?.isRead, false)

        // 3. 上游发布了标题更正与正文补充（文章 ID 相同，标题与正文发生变更）
        let updatedParsed = ParsedFeedEntry(
            id: "article-101",
            title: "更正后标题：Swift 6.0 正式发布并支持多平台并发模型",
            author: "Apple Core Team",
            url: URL(string: "https://tech.example.com/101"),
            publishedAt: Date(timeIntervalSince1970: 1700000000),
            summary: "更新后的详细摘要",
            contentHTML: "<p>Swift 6.0 带来了完全并发检查及新的数据隔离原语。</p>"
        )

        let updatedInserted = try store.libraryDatabase.write { db in
            try self.store.localProvider.articleRepository.mergeParsedEntries(
                accountID: "local-default",
                feedID: feedIDString,
                parsedEntries: [updatedParsed],
                in: db
            )
        }
        // 已有条目更新不会作为新增未读条目返回
        XCTAssertEqual(updatedInserted.count, 0)

        // 4. 回归验证：缓存清理、数据库与 Store 状态实时反映最新标题与正文
        store.reloadState()

        // 验证详情读取
        let updatedEntry = store.entry(id: articleID)
        XCTAssertEqual(updatedEntry?.title, "更正后标题：Swift 6.0 正式发布并支持多平台并发模型")
        XCTAssertEqual(updatedEntry?.author, "Apple Core Team")
        XCTAssertEqual(updatedEntry?.contentHTML, "<p>Swift 6.0 带来了完全并发检查及新的数据隔离原语。</p>")
        // 关键断言：标题更新绝不篡改用户的已读/星标状态
        XCTAssertEqual(updatedEntry?.isStarred, true, "文章元数据更新必须保留用户的星标状态")
        XCTAssertEqual(updatedEntry?.isRead, false, "文章元数据更新必须保留用户的阅读状态")

        // 验证列表投影 (EntryListItem) 的标题同步更新
        let listItems = store.entryListItems(feedID: feed.id)
        XCTAssertEqual(listItems.count, 1)
        XCTAssertEqual(listItems.first?.title, "更正后标题：Swift 6.0 正式发布并支持多平台并发模型")
    }

    // MARK: - 2. 点击 Feed / 多选 Feed / 点击文件夹筛选逻辑回归 (Feed & Folder Navigation)

    func testFeedAndFolderClickNavigationRegression() async throws {
        // 创建文件夹 "开发" 与 "设计"
        try store.localProvider.addFolder(name: "开发")
        try store.localProvider.addFolder(name: "设计")

        // 创建 3 个 Feed
        let feedSwift = try store.localProvider.addFeed(
            title: "Swift 官方博客",
            feedURL: URL(string: "https://swift.org/rss.xml")!,
            folder: "开发"
        )
        let feedRust = try store.localProvider.addFeed(
            title: "Rust 官方博客",
            feedURL: URL(string: "https://rust.org/rss.xml")!,
            folder: "开发"
        )
        let feedUI = try store.localProvider.addFeed(
            title: "UI 设计周刊",
            feedURL: URL(string: "https://uidesign.org/rss.xml")!,
            folder: "设计"
        )

        // 分别向 3 个 Feed 写入文章
        let now = Date().timeIntervalSince1970
        _ = try store.libraryDatabase.write { db in
            _ = try self.store.localProvider.articleRepository.mergeParsedEntries(
                feedID: feedSwift.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(id: "s1", title: "Swift 2", author: nil, url: nil, publishedAt: Date(timeIntervalSince1970: now - 100), summary: "", contentHTML: nil),
                    ParsedFeedEntry(id: "s2", title: "Swift 1", author: nil, url: nil, publishedAt: Date(timeIntervalSince1970: now - 300), summary: "", contentHTML: nil)
                ],
                in: db
            )
            _ = try self.store.localProvider.articleRepository.mergeParsedEntries(
                feedID: feedRust.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(id: "r1", title: "Rust 1", author: nil, url: nil, publishedAt: Date(timeIntervalSince1970: now - 200), summary: "", contentHTML: nil)
                ],
                in: db
            )
            _ = try self.store.localProvider.articleRepository.mergeParsedEntries(
                feedID: feedUI.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(id: "u1", title: "UI 1", author: nil, url: nil, publishedAt: Date(timeIntervalSince1970: now - 50), summary: "", contentHTML: nil)
                ],
                in: db
            )
        }
        store.reloadState()

        // 场景 A: 用户点击单个 Feed "Swift 官方博客"
        let swiftItems = store.entryListItems(feedID: feedSwift.id)
        XCTAssertEqual(swiftItems.count, 2)
        XCTAssertEqual(swiftItems.map(\.title), ["Swift 2", "Swift 1"], "文章必须严格按发布时间倒序")

        // 场景 B: 用户点击单个 Feed "Rust 官方博客"
        let rustItems = store.entryListItems(feedID: feedRust.id)
        XCTAssertEqual(rustItems.count, 1)
        XCTAssertEqual(rustItems.first?.title, "Rust 1")

        // 场景 C: 用户在侧边栏 Command/Shift 多选 "Swift" + "Rust"
        let multiFeedItems = store.entryListItems(feedIDs: [feedSwift.id, feedRust.id])
        XCTAssertEqual(multiFeedItems.count, 3)
        XCTAssertEqual(multiFeedItems.map(\.title), ["Swift 2", "Rust 1", "Swift 1"], "多选源必须合并并统一按时间倒序")

        // 场景 D: 用户点击文件夹 "开发" (包含 Swift + Rust)
        let devFolderItems = store.entryListItems(folder: "开发")
        XCTAssertEqual(devFolderItems.count, 3)
        XCTAssertEqual(devFolderItems.map(\.title), ["Swift 2", "Rust 1", "Swift 1"])

        // 场景 E: 用户点击文件夹 "设计" (仅包含 UI 1)
        let designFolderItems = store.entryListItems(folder: "设计")
        XCTAssertEqual(designFolderItems.count, 1)
        XCTAssertEqual(designFolderItems.first?.title, "UI 1")
    }

    // MARK: - 3. 阅读状态流转与侧边栏未读计数联动回归 (Reading State & Badge Counters)

    func testReadingStateAndSidebarCountRegression() async throws {
        let feedA = try store.localProvider.addFeed(
            title: "Feed A",
            feedURL: URL(string: "https://a.com/rss.xml")!,
            folder: "Folder 1"
        )
        let feedB = try store.localProvider.addFeed(
            title: "Feed B",
            feedURL: URL(string: "https://b.com/rss.xml")!,
            folder: "Folder 1"
        )

        _ = try store.libraryDatabase.write { db in
            _ = try self.store.localProvider.articleRepository.mergeParsedEntries(
                feedID: feedA.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(id: "a1", title: "A1", author: nil, url: nil, publishedAt: nil, summary: "", contentHTML: nil),
                    ParsedFeedEntry(id: "a2", title: "A2", author: nil, url: nil, publishedAt: nil, summary: "", contentHTML: nil),
                    ParsedFeedEntry(id: "a3", title: "A3", author: nil, url: nil, publishedAt: nil, summary: "", contentHTML: nil)
                ],
                in: db
            )
            _ = try self.store.localProvider.articleRepository.mergeParsedEntries(
                feedID: feedB.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(id: "b1", title: "B1", author: nil, url: nil, publishedAt: nil, summary: "", contentHTML: nil),
                    ParsedFeedEntry(id: "b2", title: "B2", author: nil, url: nil, publishedAt: nil, summary: "", contentHTML: nil)
                ],
                in: db
            )
        }
        store.reloadState()

        // 1. 初始计数验证
        XCTAssertEqual(store.sidebarCounts.allUnread, 5)
        XCTAssertEqual(store.unreadCount(feedID: feedA.id), 3)
        XCTAssertEqual(store.unreadCount(feedID: feedB.id), 2)
        XCTAssertEqual(store.unreadCount(folder: "Folder 1"), 5)

        // 2. 标记 Feed A 的单篇文章已读
        let aItems = store.entryListItems(feedID: feedA.id)
        let firstAItem = try XCTUnwrap(aItems.first)
        store.markRead(entryID: firstAItem.id, read: true)

        XCTAssertEqual(store.sidebarCounts.allUnread, 4)
        XCTAssertEqual(store.unreadCount(feedID: feedA.id), 2)
        XCTAssertEqual(store.unreadCount(feedID: feedB.id), 2)
        XCTAssertEqual(store.unreadCount(folder: "Folder 1"), 4)

        // 3. 将 Feed A 剩余文章批量标记为已读
        store.markAllRead(feedID: feedA.id)

        XCTAssertEqual(store.sidebarCounts.allUnread, 2)
        XCTAssertEqual(store.unreadCount(feedID: feedA.id), 0)
        XCTAssertEqual(store.unreadCount(feedID: feedB.id), 2)
        XCTAssertEqual(store.unreadCount(folder: "Folder 1"), 2)

        // 4. 星标流转验证
        let bItems = store.entryListItems(feedID: feedB.id)
        let firstBItem = try XCTUnwrap(bItems.first)
        XCTAssertFalse(store.entry(id: firstBItem.id)?.isStarred ?? true)
        XCTAssertEqual(store.starredEntryListItems(retainingIDs: []).count, 0)

        store.toggleStar(entryID: firstBItem.id)
        XCTAssertTrue(store.entry(id: firstBItem.id)?.isStarred ?? false)
        XCTAssertEqual(store.starredEntryListItems(retainingIDs: []).count, 1)
        XCTAssertEqual(store.starredEntryListItems(retainingIDs: []).first?.id, firstBItem.id)

        store.toggleStar(entryID: firstBItem.id)
        XCTAssertFalse(store.entry(id: firstBItem.id)?.isStarred ?? true)
        XCTAssertEqual(store.starredEntryListItems(retainingIDs: []).count, 0)
    }

    // MARK: - 4. 源管理与分类移动联动回归 (Feed & Folder Management)

    func testFeedFolderManagementAndReassignmentRegression() async throws {
        // 创建初始文件夹
        try store.localProvider.addFolder(name: "新闻")
        try store.localProvider.addFolder(name: "技术")

        let feed = try store.localProvider.addFeed(
            title: "综合早报",
            feedURL: URL(string: "https://news.com/rss.xml")!,
            folder: "新闻"
        )
        store.reloadState()

        XCTAssertEqual(store.feeds(in: "新闻").map(\.title), ["综合早报"])
        XCTAssertEqual(store.feeds(in: "技术").count, 0)

        // 1. 将 Feed 移动到 "技术" 文件夹
        store.setFeedFolder(feedID: feed.id, folder: "技术")
        XCTAssertEqual(store.feeds(in: "新闻").count, 0)
        XCTAssertEqual(store.feeds(in: "技术").map(\.title), ["综合早报"])

        // 2. 重命名文件夹 "技术" -> "硬核科技"
        store.renameFolder(from: "技术", to: "硬核科技")
        XCTAssertEqual(store.folders, ["新闻", "硬核科技"])
        XCTAssertEqual(store.feeds(in: "硬核科技").map(\.title), ["综合早报"])

        // 3. 将 Feed 移出文件夹（移至根目录）
        store.setFeedFolder(feedID: feed.id, folder: nil)
        XCTAssertEqual(store.feeds(in: "硬核科技").count, 0)
        XCTAssertEqual(store.rootFeeds.map(\.title), ["综合早报"])

        // 4. 删除 Feed（软删除）
        store.deleteFeed(feed)
        XCTAssertEqual(store.feeds.count, 0)
        XCTAssertEqual(store.rootFeeds.count, 0)

        // 5. 重新添加相同 URL 的 Feed，必须平滑恢复原 Feed ID 与关联数据
        let restoredFeed = try store.localProvider.addFeed(
            title: "综合早报恢复版",
            feedURL: URL(string: "https://news.com/rss.xml")!
        )
        store.reloadState()
        XCTAssertEqual(restoredFeed.id, feed.id, "重复添加同一 URL 必须复用原有 Feed UUID")
        XCTAssertEqual(store.feeds.count, 1)
    }

    // MARK: - 5. 离线正文缓存与阅读器正文加载回归 (Article Offline Cache)

    func testArticleOfflineCacheAndDetailLoadingRegression() async throws {
        let feed = try store.localProvider.addFeed(
            title: "阅读源",
            feedURL: URL(string: "https://read.com/rss.xml")!
        )

        // 插入无 HTML 全文的精简条目
        let inserted = try store.libraryDatabase.write { db in
            try self.store.localProvider.articleRepository.mergeParsedEntries(
                feedID: feed.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(
                        id: "cache-test-1",
                        title: "短文",
                        author: nil,
                        url: URL(string: "https://read.com/article/1"),
                        publishedAt: nil,
                        summary: "仅有摘要",
                        contentHTML: nil
                    )
                ],
                in: db
            )
        }
        let articleID = try XCTUnwrap(inserted.first?.id)

        // 验证初始状态下正文为空
        let beforeCache = store.entry(id: articleID)
        XCTAssertNil(beforeCache?.contentHTML)

        // 模拟后台/阅读器抓取离线正文并存入 CacheRepository
        let fullHTML = "<article><h1>完整标题</h1><p>正文第一段</p><p>正文第二段</p></article>"
        let articleCache = ArticleCache(
            entryID: articleID,
            text: "正文第一段 正文第二段",
            html: fullHTML
        )
        try store.localProvider.saveCache(articleCache)

        // 验证 CacheRepository 正确读取
        let cached = try store.localProvider.fetchCache(entryID: articleID)
        XCTAssertEqual(cached?.html, fullHTML)

        // 验证关联 AI 总结产物保存与读取
        let summaryArtifact = AIArtifact(
            entryID: articleID,
            kind: .summary,
            contentHash: "hash-123",
            model: "deepseek-chat",
            targetLanguage: "zh-Hans",
            content: "这是一篇测试文章的核心摘要总结。",
            isComplete: true
        )
        try store.localProvider.saveArtifact(summaryArtifact)

        let fetchedArtifact = try store.localProvider.fetchArtifact(entryID: articleID, kind: .summary)
        XCTAssertEqual(fetchedArtifact?.content, "这是一篇测试文章的核心摘要总结。")
    }

    func testStaleMathFallbackIsNotMemoizedAndForegroundOpenRetries() async throws {
        let loader = MockPageLoader()
        let articleURL = URL(string: "https://read.com/article/legacy-math")!
        loader.errorMap[articleURL] = URLError(.notConnectedToInternet)
        let retryingStore = AppStore(
            testDatabase: .empty,
            feedFetcher: { _ in FeedFetchResult.notModified(etag: nil, lastModified: nil) },
            pageLoader: loader
        )
        let feed = try retryingStore.localProvider.addFeed(
            title: "公式源",
            feedURL: URL(string: "https://read.com/math.xml")!
        )
        let inserted = try retryingStore.libraryDatabase.write { db in
            try retryingStore.localProvider.articleRepository.mergeParsedEntries(
                feedID: feed.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(
                        id: "legacy-math-retry",
                        title: "Legacy math retry",
                        author: nil,
                        url: articleURL,
                        publishedAt: .now,
                        summary: "短摘要",
                        contentHTML: "<p>短摘要</p>"
                    )
                ],
                in: db
            )
        }
        let entryID = try XCTUnwrap(inserted.first?.id)
        let body = String(repeating: "旧缓存仍可供离线阅读，但不能阻止下一次前台恢复。", count: 30)
        try retryingStore.localProvider.saveCache(
            ArticleCache(
                entryID: entryID,
                text: body,
                html: "<article><p>\(body)</p><div>$$c_s^<em>*=x</em>$$</div></article>",
                sourceURL: articleURL,
                isSanitized: true,
                normalizationRevision: 0
            )
        )
        retryingStore.reloadState()
        let entry = try XCTUnwrap(retryingStore.entry(id: entryID))

        _ = await retryingStore.prepareArticle(for: entry)
        XCTAssertNil(retryingStore.memoizedPreparedArticle(for: entry))
        _ = await retryingStore.prepareArticle(for: entry)

        XCTAssertEqual(loader.requestCount, 2)
        XCTAssertNil(retryingStore.memoizedPreparedArticle(for: entry))
        XCTAssertEqual(try retryingStore.localProvider.fetchCache(entryID: entryID)?.normalizationRevision, 0)
    }

    func testSuccessfulStaleMathRecoveryInvalidatesMemoryAndPublishesRefreshSignal() async throws {
        let loader = MockPageLoader()
        let articleURL = URL(string: "https://read.com/article/recovered-math")!
        let recoveredBody = String(repeating: "恢复后的完整正文保留公式结构。", count: 50)
        loader.responseMap[articleURL] =
            "<article><p>\(recoveredBody)</p><div>$$c_s^*=x\\quad s^*=y$$</div></article>"
        let recoveryStore = AppStore(
            testDatabase: .empty,
            feedFetcher: { _ in FeedFetchResult.notModified(etag: nil, lastModified: nil) },
            pageLoader: loader
        )
        let feed = try recoveryStore.localProvider.addFeed(
            title: "公式恢复源",
            feedURL: URL(string: "https://read.com/recovered.xml")!
        )
        let inserted = try recoveryStore.libraryDatabase.write { db in
            try recoveryStore.localProvider.articleRepository.mergeParsedEntries(
                feedID: feed.id.uuidString,
                parsedEntries: [
                    ParsedFeedEntry(
                        id: "successful-math-recovery",
                        title: "Successful math recovery",
                        author: nil,
                        url: articleURL,
                        publishedAt: .now,
                        summary: "短摘要",
                        contentHTML: "<p>短摘要</p>"
                    )
                ],
                in: db
            )
        }
        let entryID = try XCTUnwrap(inserted.first?.id)
        try recoveryStore.localProvider.saveCache(
            ArticleCache(
                entryID: entryID,
                text: String(repeating: "旧缓存", count: 250),
                html: "<article><p>旧缓存</p><div>$$c_s^<em>*=x</em>$$</div></article>",
                sourceURL: articleURL,
                isSanitized: true,
                normalizationRevision: 0
            )
        )
        recoveryStore.reloadState()
        let entry = try XCTUnwrap(recoveryStore.entry(id: entryID))

        let prepared = await recoveryStore.prepareArticle(for: entry)

        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertTrue(prepared.html.contains("c_s^*=x"))
        XCTAssertNil(recoveryStore.memoizedPreparedArticle(for: entry))
        XCTAssertEqual(recoveryStore.articleRefreshSignal?.entryID, entryID)
        XCTAssertEqual(
            try recoveryStore.localProvider.fetchCache(entryID: entryID)?.normalizationRevision,
            ArticleCache.currentNormalizationRevision
        )
    }

    // MARK: - 6. 时间线多作用域与分页查询回归 (Timeline Scopes & Pagination)

    func testTimelineScopesAndPaginationRegression() async throws {
        let feed = try store.localProvider.addFeed(
            title: "分页源",
            feedURL: URL(string: "https://pagination.com/rss.xml")!,
            folder: "分页合集"
        )

        let now = Date().timeIntervalSince1970
        _ = try store.libraryDatabase.write { db in
            _ = try self.store.localProvider.articleRepository.mergeParsedEntries(
                feedID: feed.id.uuidString,
                parsedEntries: (1...5).map { i in
                    ParsedFeedEntry(
                        id: "item-\(i)",
                        title: "文章 \(i)",
                        author: "Author \(i)",
                        url: nil,
                        publishedAt: Date(timeIntervalSince1970: now - Double((6 - i) * 60)),
                        summary: "Summary \(i)",
                        contentHTML: "<p>Content \(i)</p>"
                    )
                },
                in: db
            )
        }
        store.reloadState()

        // 1. 全量作用域查询 (按发布时间倒序: 文章 5, 4, 3, 2, 1)
        let allItems = store.fetchTimelinePage(scope: .all, limit: 10, offset: 0)
        XCTAssertEqual(allItems.count, 5)
        XCTAssertEqual(allItems.map(\.title), ["文章 5", "文章 4", "文章 3", "文章 2", "文章 1"])

        // 2. 分页切片验证 (第 1 页: 2 篇, 第 2 页: 2 篇, 第 3 页: 1 篇)
        let page1 = store.fetchTimelinePage(scope: .all, limit: 2, offset: 0)
        let page2 = store.fetchTimelinePage(scope: .all, limit: 2, offset: 2)
        let page3 = store.fetchTimelinePage(scope: .all, limit: 2, offset: 4)

        XCTAssertEqual(page1.map(\.title), ["文章 5", "文章 4"])
        XCTAssertEqual(page2.map(\.title), ["文章 3", "文章 2"])
        XCTAssertEqual(page3.map(\.title), ["文章 1"])

        // 3. 文件夹作用域查询
        let folderItems = store.fetchTimelinePage(scope: .folder(folderName: "分页合集"))
        XCTAssertEqual(folderItems.count, 5)

        // 4. 单源作用域查询
        let feedItems = store.fetchTimelinePage(scope: .feed(feedID: feed.id.uuidString))
        XCTAssertEqual(feedItems.count, 5)
    }
}
