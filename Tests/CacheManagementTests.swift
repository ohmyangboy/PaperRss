import XCTest
import GRDB
@testable import PaperRssCore

/// 缓存管理功能回归测试。
///
/// 覆盖场景：
/// 1. 设置页「清除网页正文缓存」：全量删除 article_caches 并返回删除行数
/// 2. 时间线行「重新拉取正文」：成功覆盖缓存并发布刷新信号；失败保留旧缓存
@MainActor
final class CacheManagementTests: XCTestCase {
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

    /// 播种一个订阅源与一条文章，返回该文章（含稳定生成的 entryID）。
    @discardableResult
    private func seedEntry(
        id: String,
        contentHTML: String?,
        url: URL? = nil,
        summary: String = ""
    ) throws -> Entry {
        let feed = try store.localProvider.addFeed(
            title: "测试源",
            feedURL: URL(string: "https://example.com/\(id).xml")!,
            siteURL: URL(string: "https://example.com")!
        )
        let parsed = ParsedFeedEntry(
            id: id,
            title: "标题",
            author: nil,
            url: url,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            summary: summary,
            contentHTML: contentHTML
        )
        let entries = try store.libraryDatabase.write { db in
            try store.localProvider.articleRepository.mergeParsedEntries(
                accountID: "local-default",
                feedID: feed.id.uuidString,
                parsedEntries: [parsed],
                in: db
            )
        }
        return try XCTUnwrap(entries.first)
    }

    private func makeCache(entryID: String, text: String) -> ArticleCache {
        ArticleCache(
            entryID: entryID,
            text: text,
            html: "<p>\(text)</p>",
            imageURLs: [],
            fetchedAt: .now,
            sourceURL: URL(string: "https://example.com/\(entryID)"),
            isSanitized: true
        )
    }

    // MARK: - F2: 清除网页正文缓存

    func testClearArticleCachesDeletesAllRowsAndReturnsCount() async throws {
        let entry = try seedEntry(id: "a1", contentHTML: "<p>正文</p>")
        try store.localProvider.saveCache(makeCache(entryID: entry.id, text: "缓存正文"))

        let count = try await store.clearArticleCaches()

        XCTAssertEqual(count, 1, "应返回删除的缓存行数")
        let remaining = try store.localProvider.fetchCache(entryID: entry.id)
        XCTAssertNil(remaining, "清除后缓存应不存在")
    }

    func testClearArticleCachesOnEmptyDatabaseReturnsZero() async throws {
        let count = try await store.clearArticleCaches()
        XCTAssertEqual(count, 0, "空库清除应返回 0")
    }

    func testArticleCacheStatsReportsCountAndBytes() async throws {
        let entryA = try seedEntry(id: "s1", contentHTML: "<p>正文A</p>")
        let entryB = try seedEntry(id: "s2", contentHTML: "<p>正文B</p>")
        try store.localProvider.saveCache(makeCache(entryID: entryA.id, text: "缓存正文A"))
        try store.localProvider.saveCache(makeCache(entryID: entryB.id, text: "缓存正文B"))

        let stats = try store.articleCacheStats()

        XCTAssertEqual(stats.count, 2, "应统计 2 条缓存")
        // 字节语义：LENGTH(CAST(... AS BLOB)) 统计 UTF-8 字节而非字符数。
        // 每条缓存 = text "缓存正文A" 13B（4 汉字×3B + "A" 1B）
        //          + html "<p>缓存正文A</p>" 20B（3 + 13 + 4）
        //          + image_urls_json "[]" 2B = 35B；两条共 70B。
        // 若误用 LENGTH(text)（字符数），中文部分会被低估（"缓存正文A" 仅 5 字符）。
        XCTAssertEqual(stats.totalBytes, 70, "应按 UTF-8 字节数统计（而非字符数）")

        _ = try await store.clearArticleCaches()
        let cleared = try store.articleCacheStats()
        XCTAssertEqual(cleared.count, 0, "清除后统计应为 0")
        XCTAssertEqual(cleared.totalBytes, 0, "清除后字节数应为 0")
    }

    // MARK: - F1: 单篇重新拉取正文

    func testRefetchArticleSucceedsWithStrongFeedAndPublishesSignal() async throws {
        let body = String(repeating: "<p>这是详实的长正文段落，提供丰富的见解与细节。</p>\n", count: 30)
        let entry = try seedEntry(id: "strong", contentHTML: body, url: nil)

        let ok = await store.refetchArticle(entryID: entry.id)

        XCTAssertTrue(ok, "强 Feed 内容应使重拉成功")
        let cache = try store.localProvider.fetchCache(entryID: entry.id)
        XCTAssertNotNil(cache, "成功后应写入缓存")
        XCTAssertEqual(store.articleRefreshSignal?.entryID, entry.id, "成功后应发布匹配条目的刷新信号")
    }

    func testRefetchArticleReturnsFalseForMissingEntry() async {
        let ok = await store.refetchArticle(entryID: "does-not-exist")
        XCTAssertFalse(ok, "条目不存在应返回失败")
        XCTAssertNil(store.articleRefreshSignal, "失败不应发布刷新信号")
    }

    func testRefetchArticleFailurePreservesExistingCache() async throws {
        // 无 Feed 正文、无 url：重拉必然走 fallback 失败
        let entry = try seedEntry(id: "cached", contentHTML: nil, url: nil)
        try store.localProvider.saveCache(makeCache(entryID: entry.id, text: "旧缓存正文"))

        let ok = await store.refetchArticle(entryID: entry.id)

        XCTAssertFalse(ok, "无可用新内容应返回失败")
        let cache = try store.localProvider.fetchCache(entryID: entry.id)
        XCTAssertEqual(cache?.text, "旧缓存正文", "失败时旧缓存必须原样保留")
        XCTAssertNil(store.articleRefreshSignal, "失败不应发布刷新信号")
    }
}
