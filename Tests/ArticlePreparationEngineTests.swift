import XCTest
import Foundation
@testable import PaperRssCore

final class MockPageLoader: ArticlePageLoading, @unchecked Sendable {
    var requestCount: Int = 0
    var requestedURLs: [URL] = []
    var responseMap: [URL: String] = [:]
    var finalURLMap: [URL: URL] = [:]
    var errorMap: [URL: Error] = [:]
    var delay: TimeInterval = 0

    func loadPage(for url: URL) async throws -> LoadedArticlePage? {
        requestCount += 1
        requestedURLs.append(url)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if let error = errorMap[url] {
            throw error
        }
        guard let html = responseMap[url] else { return nil }
        return LoadedArticlePage(html: html, finalURL: finalURLMap[url] ?? url)
    }
}

final class ArticlePreparationEngineTests: XCTestCase {

    let defaultFeedID = UUID()

    private func legacyCorruptedMathCache(entryID: String, url: URL, revision: Int = 0) -> ArticleCache {
        let prose = String(repeating: "旧缓存正文包含完整背景、实验过程与结论，用于确保它会被判断为高质量缓存。", count: 25)
        let html = """
        <article>
          <p>\(prose)</p>
          <p>An MCE skill $s \\in \\mathcal{S}$ defines a context function.</p>
          <div><p>$$
          \\text{Inner: }c_s^<em>=\\arg\\max_{c_s}J_\\text{train}(c_s;s)\\quad
          \\text{Outer: }s^</em>=\\arg\\max_{s\\in\\mathcal{S}}J_\\text{val}(c_s^*)
          $$</p></div>
        </article>
        """
        return ArticleCache(
            entryID: entryID,
            text: prose,
            html: html,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceURL: url,
            isSanitized: true,
            normalizationRevision: revision
        )
    }

    private func cleanMathPage() -> String {
        let prose = String(repeating: "新网页正文提供完整背景、实验过程、证据与结论。", count: 30)
        return """
        <html><body><article class="article-content">
          <p>\(prose)</p>
          <p>An MCE skill $s \\in \\mathcal{S}$ defines a context function.</p>
          <div>$$
          \\text{Inner: }c_s^*=\\arg\\max_{c_s}J_\\text{train}(c_s;s)\\quad
          \\text{Outer: }s^*=\\arg\\max_{s\\in\\mathcal{S}}J_\\text{val}(c_s^*)
          $$</div>
        </article></body></html>
        """
    }

    // MARK: - 1. Strong Feed: 0 Web Requests


    func testStrongFeedRequiresZeroWebRequests() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)

        let longBody = String(repeating: "<p>这是详实的长正文段落，提供丰富的见解与细节。</p>\n", count: 30)
        let entry = Entry(
            id: "entry-strong-1",
            feedID: defaultFeedID,
            title: "深度长文",
            url: URL(string: "https://example.com/post-1"),
            publishedAt: .now,
            summary: "文章摘要",
            contentHTML: "<div class=\"post-content\">\(longBody)</div>"
        )

        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)

        XCTAssertEqual(loader.requestCount, 0, "强 Feed 必须直接采用，网页抓取请求必须为 0")
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertTrue(prepared.text.contains("这是详实的长正文段落"))
    }

    // MARK: - 2. High Quality Cache: 0 Web Requests & 0 Unchanged Writes

    func testHighQualityCacheRequiresZeroWebRequestsAndZeroUnchangedWrites() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)

        let longText = String(repeating: "高价值缓存文本内容，经过前期清洗与离线保存。", count: 20)
        let cacheHTML = "<p>\(longText)</p><img src=\"https://example.com/cached.jpg\" loading=\"eager\" decoding=\"async\">"
        let existingCache = ArticleCache(
            entryID: "entry-cache-1",
            text: longText,
            html: cacheHTML,
            imageURLs: [URL(string: "https://example.com/cached.jpg")!],
            fetchedAt: .now,
            sourceURL: URL(string: "https://example.com/post-2"),
            isSanitized: true
        )

        let weakEntry = Entry(
            id: "entry-cache-1",
            feedID: defaultFeedID,
            title: "缓存长文",
            url: URL(string: "https://example.com/post-2"),
            publishedAt: .now,
            summary: "弱摘要",
            contentHTML: "<p>弱摘要</p>"
        )

        let (prepared, updatedCache) = await engine.prepare(entry: weakEntry, cached: existingCache)

        XCTAssertEqual(loader.requestCount, 0, "高质量 cache 必须优先采用，网页请求必须为 0")
        XCTAssertEqual(prepared.source, .cache)
        XCTAssertNil(updatedCache, "内容未变化时，缓存回写必须为 nil (0 写入)")
    }

    // MARK: - 3. Weak Local Candidate: Exactly 1 Web Request

    func testWeakLocalCandidateTriggersExactlyOneWebRequest() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/short-post")!
        loader.responseMap[postURL] = """
        <html>
        <body>
            <article class="article-content">
                <h1>网页抓取全文</h1>
                <p>从原站网页抓取到的丰富正文第一段，字数充分扩展并提供详尽事实分析。</p>
                <p>从原站网页抓取到的丰富正文第二段，字数进一步扩充并提供完整论证论据。</p>
                <p>从原站网页抓取到的丰富正文第三段，彻底消除 Feed 截断带来的阅读体验损失。</p>
            </article>
        </body>
        </html>
        """

        let engine = ArticlePreparationEngine(pageLoader: loader)

        let weakEntry = Entry(
            id: "entry-weak-1",
            feedID: defaultFeedID,
            title: "短正文文章",
            url: postURL,
            publishedAt: .now,
            summary: "截断正文",
            contentHTML: "<p>截断正文…… <a href=\"https://example.com/short-post\">阅读全文</a></p>"
        )

        let (prepared, updatedCache) = await engine.prepare(entry: weakEntry, cached: nil)

        XCTAssertEqual(loader.requestCount, 1, "弱本地候选必须触发恰好 1 次网页抓取")
        XCTAssertEqual(prepared.source, .web)
        XCTAssertTrue(prepared.text.contains("从原站网页抓取到的丰富正文"))
        XCTAssertNotNil(updatedCache, "抓取到新内容后应当产生待写入缓存")
    }

    // MARK: - 4. Web Significantly Better Replaces Local

    func testWebReplacesLocalWhenSignificantlyBetter() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/better-post")!
        loader.responseMap[postURL] = """
        <div class="post-content">
            <h1>完整版正文</h1>
            <p>这是从网页端抓取的详尽分析，包含三个完整段落和插图，提供充分细节论据以满足字数提升门槛。</p>
            <img src="https://example.com/chart.png" alt="Chart">
            <p>这是第二段深度阐述，篇幅远远超过 RSS 摘要，包含更多背景与行业调研数据。</p>
            <p>这是第三段总结结论，确保文章具有完整的论证逻辑与行动建议。</p>
        </div>
        """

        let engine = ArticlePreparationEngine(pageLoader: loader)
        let weakEntry = Entry(
            id: "entry-better-1",
            feedID: defaultFeedID,
            title: "摘要文章",
            url: postURL,
            publishedAt: .now,
            summary: "简略介绍",
            contentHTML: "<p>仅包含几句话的简略介绍，未包含核心图片与后续段落。</p>"
        )

        let (prepared, _) = await engine.prepare(entry: weakEntry, cached: nil)
        XCTAssertEqual(prepared.source, .web)
        XCTAssertTrue(prepared.imageURLs.map(\.absoluteString).contains("https://example.com/chart.png"))
    }

    // MARK: - 5. Web Not Significantly Better Retains Local

    func testWebRetainsLocalWhenNotSignificantlyBetter() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/same-post")!
        loader.responseMap[postURL] = """
        <div>
            <p>仅包含几句话的简略介绍，未包含核心图片与后续段落。</p>
            <p>版权声明信息。</p>
        </div>
        """

        let engine = ArticlePreparationEngine(pageLoader: loader)
        let entry = Entry(
            id: "entry-same-1",
            feedID: defaultFeedID,
            title: "简短但自包含文章",
            url: postURL,
            publishedAt: .now,
            summary: "简略介绍",
            contentHTML: "<p>仅包含几句话的简略介绍，未包含核心图片与后续段落。</p>"
        )

        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)
        XCTAssertEqual(prepared.source, .feed, "当网页内容无明显改善时，必须保留本地 Feed 候选")
    }

    // MARK: - 6. Web Failure Fallback to Best Local

    func testWebFailureFallbacksToBestLocal() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/fail-post")!
        loader.errorMap[postURL] = URLError(.timedOut)

        let engine = ArticlePreparationEngine(pageLoader: loader)
        let entry = Entry(
            id: "entry-fail-1",
            feedID: defaultFeedID,
            title: "本地保底文章",
            url: postURL,
            publishedAt: .now,
            summary: "本地正文",
            contentHTML: "<p>本地可读 Feed 正文，网络超时后依然能够正常阅读。</p>"
        )

        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertTrue(prepared.text.contains("本地可读 Feed 正文"))
    }

    // MARK: - 6.5 弱本地候选不得投毒缓存（摘要 Feed 回归）

    func testWebFailureWithWeakFeedSummaryDoesNotWriteDiskCache() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/summary-feed-post")!
        loader.errorMap[postURL] = URLError(.timedOut)

        let engine = ArticlePreparationEngine(pageLoader: loader)
        // 摘要 Feed：两段短文（不足 strong 阈值），有网页 URL 可升级
        let entry = Entry(
            id: "entry-summary-1",
            feedID: defaultFeedID,
            title: "摘要文章",
            url: postURL,
            publishedAt: .now,
            summary: "摘要",
            contentHTML: "<p>第一段摘要。</p><p>第二段摘要。</p>"
        )

        let result = await engine.prepare(entry: entry, cached: nil, policy: .foregroundRefresh)
        XCTAssertEqual(result.prepared.source, .feed)
        // 关键回归：弱摘要不得写入磁盘缓存，否则下次打开命中可用缓存永久顶替全文
        XCTAssertNil(result.updatedCache)
    }

    func testWebFailureWithoutURLStillCachesFeedContent() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let entry = Entry(
            id: "entry-nourl-1",
            feedID: defaultFeedID,
            title: "无链接文章",
            url: nil,
            publishedAt: .now,
            summary: "",
            contentHTML: "<p>第一段。</p><p>第二段。</p>"
        )

        let result = await engine.prepare(entry: entry, cached: nil, policy: .foregroundRefresh)
        XCTAssertEqual(result.prepared.source, .feed)
        // 无 URL 时 Feed 即权威内容，照常入缓存
        XCTAssertNotNil(result.updatedCache)
    }

    func testWebFailureWithStrongFeedStillCachesFeedContent() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/fullfeed-post")!
        loader.errorMap[postURL] = URLError(.timedOut)

        let engine = ArticlePreparationEngine(pageLoader: loader)
        // 全文 Feed：三段以上长正文（strong），有 URL 但内容已是最终形态
        let long = String(repeating: "这是一段完整的正文内容，包含背景、方法与结论。", count: 20)
        let entry = Entry(
            id: "entry-fullfeed-1",
            feedID: defaultFeedID,
            title: "全文文章",
            url: postURL,
            publishedAt: .now,
            summary: "",
            contentHTML: "<p>\(long)</p><p>\(long)</p><p>\(long)</p>"
        )

        let result = await engine.prepare(entry: entry, cached: nil, policy: .foregroundRefresh)
        XCTAssertEqual(result.prepared.source, .feed)
        XCTAssertNotNil(result.updatedCache)
    }

    func testLocalOnlyWeakSummaryWithURLIsProvisional() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/prefetch-summary")!
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let entry = Entry(
            id: "entry-prefetch-1",
            feedID: defaultFeedID,
            title: "预取摘要",
            url: postURL,
            publishedAt: .now,
            summary: "摘要",
            contentHTML: "<p>第一段摘要。</p><p>第二段摘要。</p>"
        )

        let result = await engine.prepare(entry: entry, cached: nil, policy: .localOnly)
        XCTAssertEqual(result.prepared.source, .feed)
        XCTAssertTrue(result.isProvisionalLocal, "弱摘要+有 URL 的 localOnly 结果必须是降级预览")
        XCTAssertEqual(loader.requestCount, 0)
    }

    func testLocalOnlyStrongFeedWithURLIsNotProvisional() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/prefetch-fullfeed")!
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let long = String(repeating: "这是一段完整的正文内容，包含背景、方法与结论。", count: 20)
        let entry = Entry(
            id: "entry-prefetch-2",
            feedID: defaultFeedID,
            title: "预取全文",
            url: postURL,
            publishedAt: .now,
            summary: "",
            contentHTML: "<p>\(long)</p><p>\(long)</p><p>\(long)</p>"
        )

        let result = await engine.prepare(entry: entry, cached: nil, policy: .localOnly)
        XCTAssertEqual(result.prepared.source, .feed)
        XCTAssertFalse(result.isProvisionalLocal, "全文 Feed 预取结果即最终内容，不得标记降级")
    }

    // MARK: - 7. PreparedArticle Fields Provenance (Same-Origin)

    func testPreparedArticleFieldsAreStrictlySameOrigin() async {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/same-origin")!
        loader.responseMap[postURL] = """
        <article class="post-content">
            <h1>同源字段测试</h1>
            <p>来自 Web 候选的完整正文，包含详细的内容描述与插图。</p>
            <p>第二段：继续阐释，确保字数充分超过门槛。</p>
            <img src="https://example.com/web-pic.png" alt="Pic">
        </article>
        """

        let engine = ArticlePreparationEngine(pageLoader: loader)
        let weakEntry = Entry(
            id: "entry-origin-1",
            feedID: defaultFeedID,
            title: "同源测试",
            url: postURL,
            publishedAt: .now,
            summary: "截断",
            contentHTML: "<p>Feed 截断…… <a href=\"https://example.com/same-origin\">全文</a></p>"
        )

        let (prepared, _) = await engine.prepare(entry: weakEntry, cached: nil)
        XCTAssertEqual(prepared.source, .web)
        XCTAssertTrue(prepared.text.contains("来自 Web 候选的完整正文"))
        XCTAssertTrue(prepared.html.contains("来自 Web 候选的完整正文"))
        XCTAssertEqual(prepared.imageURLs.map(\.absoluteString), ["https://example.com/web-pic.png"])
        XCTAssertEqual(prepared.baseURL, postURL)
    }

    func testRedirectedResponseURLBecomesWebCandidateBaseURL() async {
        let loader = MockPageLoader()
        let requestedURL = URL(string: "https://example.com/redirect")!
        let finalURL = URL(string: "https://cdn.example.net/articles/final/")!
        loader.responseMap[requestedURL] = """
        <article>
            <p>重定向后的完整正文包含足够上下文，并通过多段内容证明相对资源必须基于最终响应地址解析。</p>
            <p>第二段继续补充事实、证据和结论，使网页候选明显优于截断的 Feed 内容。</p>
            <img src="images/chart.png">
        </article>
        """
        loader.finalURLMap[requestedURL] = finalURL
        let entry = Entry(
            id: "redirected-page",
            feedID: defaultFeedID,
            title: "Redirected article",
            url: requestedURL,
            publishedAt: .now,
            summary: "",
            contentHTML: "<p>截断……</p>"
        )

        let (prepared, _) = await ArticlePreparationEngine(pageLoader: loader).prepare(entry: entry, cached: nil)

        XCTAssertEqual(prepared.source, .web)
        XCTAssertEqual(prepared.baseURL, finalURL)
        XCTAssertEqual(prepared.imageURLs, [URL(string: "https://cdn.example.net/articles/final/images/chart.png")!])
        XCTAssertTrue(prepared.html.contains("https://cdn.example.net/articles/final/images/chart.png"))
    }

    // MARK: - 8. Cancellation Prevents Stale Results and Cache Writes

    func testTaskCancellationPreventsCacheWrites() async throws {
        let loader = MockPageLoader()
        let postURL = URL(string: "https://example.com/cancel-post")!
        loader.delay = 0.2
        loader.responseMap[postURL] = "<p>异步返回的内容</p>"

        let engine = ArticlePreparationEngine(pageLoader: loader)
        let entry = Entry(
            id: "entry-cancel-1",
            feedID: defaultFeedID,
            title: "取消测试",
            url: postURL,
            publishedAt: .now,
            summary: "短",
            contentHTML: "<p>短正文……</p>"
        )

        let task = Task { () -> (PreparedArticle, ArticleCache?) in
            return await engine.prepare(entry: entry, cached: nil)
        }

        task.cancel()
        let (_, updatedCache) = await task.value
        XCTAssertNil(updatedCache, "取消后的任务绝不能产生待写入缓存")
    }

    // MARK: - 9. Cache Update When Stale Cache Normalized

    func testStaleCacheUpdateWritesExactlyOnce() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)

        let unnormalizedHTML = "<p>包含 &lt;strong&gt;转义实体&lt;/strong&gt; 的旧版缓存正文，需重新规范化。</p>"
        let staleCache = ArticleCache(
            entryID: "entry-stale-1",
            text: "包含转义实体的旧版缓存正文",
            html: unnormalizedHTML,
            imageURLs: [],
            fetchedAt: .now,
            sourceURL: URL(string: "https://example.com/post"),
            isSanitized: false
        )

        let entry = Entry(
            id: "entry-stale-1",
            feedID: defaultFeedID,
            title: "旧缓存文章",
            url: URL(string: "https://example.com/post"),
            publishedAt: .now,
            summary: ""
        )

        let (prepared, updatedCache) = await engine.prepare(entry: entry, cached: staleCache)
        XCTAssertEqual(prepared.source, .cache)
        XCTAssertNotNil(updatedCache, "旧版未清洗缓存规范化后应当产生 1 次缓存回写")
        XCTAssertEqual(updatedCache?.isSanitized, true)
    }

    func testLegacyCorruptedMathCacheForegroundRefreshesAndUpgradesRevision() async {
        let loader = MockPageLoader()
        let url = URL(string: "https://example.com/legacy-math")!
        loader.responseMap[url] = cleanMathPage()
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let cache = legacyCorruptedMathCache(entryID: "legacy-math", url: url)
        let entry = Entry(
            id: cache.entryID,
            feedID: defaultFeedID,
            title: "Legacy math",
            url: url,
            publishedAt: .now,
            summary: ""
        )

        let result = await engine.prepare(
            entry: entry,
            cached: cache,
            policy: .foregroundRefresh
        )

        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertEqual(result.prepared.source, .web)
        XCTAssertEqual(result.cacheState, .current)
        XCTAssertEqual(result.updatedCache?.normalizationRevision, ArticleCache.currentNormalizationRevision)
        XCTAssertGreaterThan(result.updatedCache?.fetchedAt ?? .distantPast, cache.fetchedAt)
        XCTAssertTrue(result.prepared.html.contains("c_s^*="))
        XCTAssertTrue(result.prepared.html.contains("s^*="))
        XCTAssertFalse(result.prepared.html.contains("<em>"))
    }

    func testLegacyCorruptedMathCacheNetworkFailureRemainsRetryableFallback() async {
        let loader = MockPageLoader()
        let url = URL(string: "https://example.com/legacy-math-offline")!
        loader.errorMap[url] = URLError(.notConnectedToInternet)
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let cache = legacyCorruptedMathCache(entryID: "legacy-math-offline", url: url)
        let entry = Entry(
            id: cache.entryID,
            feedID: defaultFeedID,
            title: "Legacy math offline",
            url: url,
            publishedAt: .now,
            summary: ""
        )

        let first = await engine.prepare(entry: entry, cached: cache, policy: .foregroundRefresh)
        let second = await engine.prepare(entry: entry, cached: cache, policy: .foregroundRefresh)

        XCTAssertEqual(loader.requestCount, 2, "旧缓存失败后不得被标记为已升级，下一次打开必须能重试")
        XCTAssertEqual(first.prepared.source, .cache)
        XCTAssertEqual(first.cacheState, .staleFallback)
        XCTAssertNil(first.updatedCache)
        XCTAssertEqual(second.cacheState, .staleFallback)
        XCTAssertNil(second.updatedCache)
    }

    func testLegacyCorruptedMathCacheLocalOnlyUsesFallbackWithoutNetworkOrWrite() async {
        let loader = MockPageLoader()
        let url = URL(string: "https://example.com/legacy-math-prefetch")!
        loader.responseMap[url] = cleanMathPage()
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let cache = legacyCorruptedMathCache(entryID: "legacy-math-prefetch", url: url)
        let entry = Entry(
            id: cache.entryID,
            feedID: defaultFeedID,
            title: "Legacy math prefetch",
            url: url,
            publishedAt: .now,
            summary: ""
        )

        let result = await engine.prepare(entry: entry, cached: cache, policy: .localOnly)

        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertEqual(result.prepared.source, .cache)
        XCTAssertEqual(result.cacheState, .staleFallback)
        XCTAssertNil(result.updatedCache)
    }

    func testCurrentRevisionCacheWithMarkupInsideFormulaStillRefreshes() async {
        let loader = MockPageLoader()
        let url = URL(string: "https://example.com/current-corrupted-math")!
        loader.responseMap[url] = cleanMathPage()
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let cache = legacyCorruptedMathCache(
            entryID: "current-corrupted-math",
            url: url,
            revision: ArticleCache.currentNormalizationRevision
        )
        let entry = Entry(
            id: cache.entryID,
            feedID: defaultFeedID,
            title: "Current corrupted math",
            url: url,
            publishedAt: .now,
            summary: ""
        )

        let result = await engine.prepare(entry: entry, cached: cache, policy: .foregroundRefresh)

        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertEqual(result.cacheState, .current)
        XCTAssertFalse(result.prepared.html.contains("<em>"))
    }

    func testHighQualityCacheWinsOverShorterStrongFeed() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let entryID = "entry-cache-vs-feed"
        let url = URL(string: "https://example.com/cache-vs-feed")!
        let feedBody = String(repeating: "Feed 正文刚刚达到强候选门槛。", count: 45)
        let cachedBody = String(repeating: "缓存中的完整网页正文包含更多上下文、证据和结论。", count: 120)
        let cache = ArticleCache(
            entryID: entryID,
            text: cachedBody,
            html: "<article><p>\(cachedBody)</p></article>",
            imageURLs: [],
            sourceURL: url,
            isSanitized: true
        )
        let entry = Entry(
            id: entryID,
            feedID: defaultFeedID,
            title: "缓存优先级",
            url: url,
            publishedAt: .now,
            summary: "",
            contentHTML: "<p>\(feedBody)</p><p>\(feedBody)</p><p>\(feedBody)</p>"
        )

        let (prepared, _) = await engine.prepare(entry: entry, cached: cache)

        XCTAssertEqual(prepared.source, .cache)
        XCTAssertTrue(prepared.text.contains("缓存中的完整网页正文"))
        XCTAssertEqual(loader.requestCount, 0)
    }

    func testMuchStrongerFeedReplacesUsableButStaleCache() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let entryID = "entry-feed-vs-stale-cache"
        let cachedBody = String(repeating: "旧缓存只有有限上下文。", count: 15)
        let feedBody = String(repeating: "新 Feed 正文包含完整背景、证据、分析和结论。", count: 80)
        let cache = ArticleCache(
            entryID: entryID,
            text: cachedBody,
            html: "<p>\(cachedBody)</p><p>缓存补充段。</p>",
            imageURLs: [],
            isSanitized: true
        )
        let entry = Entry(
            id: entryID,
            feedID: defaultFeedID,
            title: "Feed 更新",
            url: nil,
            publishedAt: .now,
            summary: "",
            contentHTML: "<p>\(feedBody)</p><p>\(feedBody)</p><p>\(feedBody)</p>"
        )

        let (prepared, _) = await engine.prepare(entry: entry, cached: cache)

        XCTAssertEqual(prepared.source, .feed)
        XCTAssertTrue(prepared.text.contains("新 Feed 正文"))
        XCTAssertEqual(loader.requestCount, 0)
    }

    func testTextOnlyLegacyCacheRemainsAvailableOffline() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)
        let cachedText = String(repeating: "旧缓存仍保存着可离线阅读的完整正文。", count: 30)
        let cache = ArticleCache(
            entryID: "entry-text-only-cache",
            text: cachedText,
            html: nil,
            imageURLs: [],
            sourceURL: URL(string: "https://example.com/text-cache"),
            isSanitized: false
        )
        let entry = Entry(
            id: cache.entryID,
            feedID: defaultFeedID,
            title: "旧缓存",
            url: nil,
            publishedAt: .now,
            summary: "很短的 Feed 摘要"
        )

        let (prepared, updatedCache) = await engine.prepare(entry: entry, cached: cache)

        XCTAssertEqual(prepared.source, .cache)
        XCTAssertEqual(prepared.text, cachedText)
        XCTAssertTrue(prepared.html.contains("<p>"))
        XCTAssertNotNil(updatedCache, "text-only 旧缓存应惰性升级为清洗后的 HTML 缓存")
        XCTAssertEqual(loader.requestCount, 0)
    }

    func testTextOnlyLegacyCachePreservesLiteralAngleBracketExamples() async {
        let loader = MockPageLoader()
        let literalText = String(repeating: "示例 <strong> 只是正文，不是标签。\n", count: 20)
        let cache = ArticleCache(
            entryID: "literal-text-cache",
            text: literalText,
            html: nil,
            imageURLs: [],
            isSanitized: false
        )
        let entry = Entry(
            id: cache.entryID,
            feedID: defaultFeedID,
            title: "Literal markup",
            url: nil,
            publishedAt: .now,
            summary: ""
        )

        let (prepared, _) = await ArticlePreparationEngine(pageLoader: loader).prepare(entry: entry, cached: cache)

        XCTAssertEqual(prepared.source, .cache)
        XCTAssertTrue(prepared.text.contains("<strong> 只是正文"))
        XCTAssertTrue(prepared.html.contains("&lt;strong&gt;"))
        XCTAssertFalse(prepared.html.contains("<strong>"))
    }

    // MARK: - 10. Fallback on Completely Empty

    func testFallbackToSourceTextWhenAllSourcesAreEmpty() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)

        let emptyEntry = Entry(
            id: "entry-empty-1",
            feedID: defaultFeedID,
            title: "纯空文章",
            url: nil,
            publishedAt: .now,
            summary: ""
        )

        let (prepared, updatedCache) = await engine.prepare(entry: emptyEntry, cached: nil)
        XCTAssertEqual(prepared.source, .fallback)
        XCTAssertEqual(prepared.text, emptyEntry.sourceText)
        XCTAssertNil(updatedCache)
    }

    // MARK: - 11. Unknown Host Consistency

    func testUnknownHostSameStructureSelectionConsistency() async {
        let loader = MockPageLoader()
        let urlA = URL(string: "https://unknown-a.org/article")!
        let urlB = URL(string: "https://unknown-b.org/article")!

        let template = """
        <div class="article-content">
            <h1>文章标题一致性</h1>
            <p>第一段：阐述客观事实并提供丰富上下文，确保字数充分超过 200 字要求。</p>
            <p>第二段：继续提供详细分析，结构在两个不同域名下完全保持一致。</p>
            <p>第三段：总结最终结论，测试两者的来源判定与 PreparedArticle 结构完全一致。</p>
        </div>
        """

        loader.responseMap[urlA] = template
        loader.responseMap[urlB] = template

        let engine = ArticlePreparationEngine(pageLoader: loader)

        let entryA = Entry(id: "a", feedID: defaultFeedID, title: "A", url: urlA, publishedAt: .now, summary: "", contentHTML: "<p>截断……</p>")
        let entryB = Entry(id: "b", feedID: defaultFeedID, title: "B", url: urlB, publishedAt: .now, summary: "", contentHTML: "<p>截断……</p>")

        let (preparedA, _) = await engine.prepare(entry: entryA, cached: nil)
        let (preparedB, _) = await engine.prepare(entry: entryB, cached: nil)

        XCTAssertEqual(preparedA.source, preparedB.source)
        XCTAssertEqual(preparedA.imageURLs.count, preparedB.imageURLs.count)
    }

    // MARK: - 12. Twitter/X Short Status Compatibility

    func testTwitterShortStatusPreservedAsFeedSource() async {
        let loader = MockPageLoader()
        let twitterURL = URL(string: "https://x.com/jack/status/123456")!
        let engine = ArticlePreparationEngine(pageLoader: loader)

        let feedID = UUID()
        let twitterEntry = Entry(
            id: "tweet-1",
            feedID: feedID,
            title: "jack on X",
            url: twitterURL,
            publishedAt: .now,
            summary: "just setting up my twttr",
            contentHTML: "just setting up my twttr"
        )

        let feed = Feed(
            id: feedID,
            title: "Twitter",
            siteURL: twitterURL,
            feedURL: URL(string: "https://rsshub.app/twitter/user/jack")!
        )

        let (prepared, _) = await engine.prepare(entry: twitterEntry, cached: nil, feed: feed)
        XCTAssertEqual(loader.requestCount, 0, "Twitter 短正文自包含 Feed 严禁触发网页抓取")
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertTrue(prepared.text.contains("just setting up my twttr"))
    }

    // MARK: - 13. Fast Entry Switching Isolation

    func testFastEntrySwitchingDoesNotOverwriteNewerEntry() async {
        let loader = MockPageLoader()
        let url1 = URL(string: "https://example.com/slow")!
        let url2 = URL(string: "https://example.com/fast")!

        loader.delay = 0.1
        loader.responseMap[url1] = "<article><h1>Slow</h1><p>Slow article web content with sufficient length for testing.</p></article>"
        loader.responseMap[url2] = "<article><h1>Fast</h1><p>Fast article web content with sufficient length and detail for testing.</p></article>"

        let engine = ArticlePreparationEngine(pageLoader: loader)

        let entry1 = Entry(id: "e1", feedID: defaultFeedID, title: "E1", url: url1, publishedAt: .now, summary: "", contentHTML: "<p>截断……</p>")
        let entry2 = Entry(id: "e2", feedID: defaultFeedID, title: "E2", url: url2, publishedAt: .now, summary: "", contentHTML: "<p>截断……</p>")

        let task1 = Task { () -> (PreparedArticle, ArticleCache?) in
            return await engine.prepare(entry: entry1, cached: nil)
        }

        task1.cancel()
        let (prepared2, _) = await engine.prepare(entry: entry2, cached: nil)

        XCTAssertEqual(prepared2.source, .web)
        XCTAssertTrue(prepared2.html.contains("Fast article web content"))
    }

    // MARK: - 14. Strong Feed Strict Boundaries (Spec Alignment)

    func testStrongFeedStrictThresholdBoundaries() async {
        let loader = MockPageLoader()
        loader.responseMap[URL(string: "https://example.com/web-article")!] = "<article><p>Web article content with sufficient details.</p></article>"
        let engine = ArticlePreparationEngine(pageLoader: loader)

        // Case A1: 599 chars, 3 blocks -> 弱 Feed (应发起 1 次 web 请求)
        // plainText 将段落间以 \n\n (2字符) 分隔，3 个段落包含 2 处分隔共 4 个换行字符
        let p198 = String(repeating: "字", count: 198)
        let p199 = String(repeating: "字", count: 199)
        let html599 = "<p>\(p198)</p><p>\(p198)</p><p>\(p199)</p>" // 198 + 2 + 198 + 2 + 199 = 599 字符
        let entry599 = Entry(id: "e599", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html599)
        _ = await engine.prepare(entry: entry599, cached: nil)
        XCTAssertEqual(loader.requestCount, 1, "599 字不足 600 字，必须判定为弱 Feed 并请求网页")

        // Case A2: 600 chars, 3 blocks -> 强 Feed (0 web 请求)
        loader.requestCount = 0
        let html600 = "<p>\(p198)</p><p>\(p199)</p><p>\(p199)</p>" // 198 + 2 + 199 + 2 + 199 = 600 字符
        let entry600 = Entry(id: "e600", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html600)
        let (prepared600, _) = await engine.prepare(entry: entry600, cached: nil)
        XCTAssertEqual(loader.requestCount, 0, "600 字且 3 个语义块必须判定为强 Feed，0 web 请求")
        XCTAssertEqual(prepared600.source, .feed)

        // Case A3: 600 chars, 2 blocks -> 弱 Feed (应发起 1 次 web 请求)
        loader.requestCount = 0
        let p299 = String(repeating: "字", count: 299)
        let html600_2blocks = "<p>\(p299)</p><p>\(p299)</p>" // 299 + 2 + 299 = 600 字符，2 个块
        let entry600_2b = Entry(id: "e600_2b", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html600_2blocks)
        _ = await engine.prepare(entry: entry600_2b, cached: nil)
        XCTAssertEqual(loader.requestCount, 1, "600 字但只有 2 块不满足 >= 3 块要求，必须请求网页")

        // Case A4: 500 chars single block -> 弱 Feed (应发起 1 次 web 请求)
        loader.requestCount = 0
        let block500 = String(repeating: "字", count: 500)
        let html500_1b = "<p>\(block500)</p>"
        let entry500_1b = Entry(id: "e500_1b", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html500_1b)
        _ = await engine.prepare(entry: entry500_1b, cached: nil)
        XCTAssertEqual(loader.requestCount, 1, "500 字单块不得放宽为强 Feed，必须请求网页")

        // Case B1: 199 chars, 2 blocks, 1 image -> 弱 Feed (应发起 1 次 web 请求)
        // 2 个段落包含 1 处 \n\n (2字符) 分隔：98 + 2 + 99 = 199 字符
        loader.requestCount = 0
        let p98 = String(repeating: "字", count: 98)
        let p99 = String(repeating: "字", count: 99)
        let html199_img = "<p>\(p98)</p><p>\(p99)<img src=\"https://example.com/a.jpg\"></p>"
        let entry199_img = Entry(id: "e199_img", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html199_img)
        _ = await engine.prepare(entry: entry199_img, cached: nil)
        XCTAssertEqual(loader.requestCount, 1, "199 字带图不足 200 字，必须判定为弱 Feed 并请求网页")

        // Case B2: 200 chars, 2 blocks, 1 image -> 强 Feed (0 web 请求)
        // 99 + 2 + 99 = 200 字符
        loader.requestCount = 0
        let html200_img = "<p>\(p99)</p><p>\(p99)<img src=\"https://example.com/a.jpg\"></p>"
        let entry200_img = Entry(id: "e200_img", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html200_img)
        let (prepared200_img, _) = await engine.prepare(entry: entry200_img, cached: nil)
        XCTAssertEqual(loader.requestCount, 0, "200 字且 2 个语义块且 1 张有效图片必须判定为强 Feed，0 web 请求")
        XCTAssertEqual(prepared200_img.source, .feed)

        // Case B3: 200 chars, 1 block, 1 image -> 弱 Feed (应发起 1 次 web 请求)
        loader.requestCount = 0
        let block200 = String(repeating: "字", count: 200)
        let html200_1b_img = "<p>\(block200)<img src=\"https://example.com/a.jpg\"></p>"
        let entry200_1b_img = Entry(id: "e200_1b_img", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html200_1b_img)
        _ = await engine.prepare(entry: entry200_1b_img, cached: nil)
        XCTAssertEqual(loader.requestCount, 1, "200 字带图但只有 1 个语义块不足 2 块，必须判定为弱 Feed 并请求网页")

        // Case C: 600 chars, 3 blocks with truncation signal -> 弱 Feed (应发起 1 次 web 请求)
        loader.requestCount = 0
        let html600_trunc = "<p>\(p198)</p><p>\(p199)</p><p>\(p199)……阅读全文</p>"
        let entry600_trunc = Entry(id: "e600_trunc", feedID: defaultFeedID, title: "T", url: URL(string: "https://example.com/web-article"), publishedAt: .now, summary: "", contentHTML: html600_trunc)
        _ = await engine.prepare(entry: entry600_trunc, cached: nil)
        XCTAssertEqual(loader.requestCount, 1, "存在截断信号的长文章必须判定为弱 Feed 并请求网页")
    }

    // MARK: - 15. Fallback HTML Security Pipeline (Finding 3)

    func testFallbackArticleEscapingAndSanitization() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)

        // 空内容且带危险 sourceText 的 entry
        let dangerousText = "<script>alert('xss')</script><img src=\"x\" onerror=\"alert(1)\"><b>粗体纯文本</b>\n\n第二行内容 & 特殊字符 < >"
        let entry = Entry(
            id: "e-fallback-sec",
            feedID: defaultFeedID,
            title: "安全回退测试",
            url: URL(string: "https://example.com/safe"),
            publishedAt: .now,
            summary: dangerousText,
            contentHTML: nil
        )

        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)

        XCTAssertEqual(prepared.source, .fallback)
        // 验证 raw script 和 onerror 不得存在于 HTML 中
        XCTAssertFalse(prepared.html.contains("<script>"), "fallback HTML 严禁包含未经转义的 script 标签")
        XCTAssertFalse(prepared.html.contains("onerror"), "fallback HTML 严禁包含 onerror 事件属性")
        // 验证纯文本换行保留
        XCTAssertTrue(prepared.html.contains("<p>") || prepared.html.contains("<br>"), "fallback HTML 必须保留可读段落换行")
        // 验证同源性与特殊符号 escaping
        XCTAssertTrue(prepared.html.contains("&lt;") || prepared.html.contains("&gt;") || prepared.html.contains("&amp;"), "fallback HTML 必须执行 HTML escaping")
    }
}
