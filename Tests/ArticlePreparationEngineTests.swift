import XCTest
import Foundation
@testable import PaperRssCore

final class MockPageLoader: ArticlePageLoading, @unchecked Sendable {
    var requestCount: Int = 0
    var requestedURLs: [URL] = []
    var responseMap: [URL: String] = [:]
    var errorMap: [URL: Error] = [:]
    var delay: TimeInterval = 0

    func loadHTML(for url: URL) async throws -> String? {
        requestCount += 1
        requestedURLs.append(url)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if let error = errorMap[url] {
            throw error
        }
        return responseMap[url]
    }
}

final class ArticlePreparationEngineTests: XCTestCase {

    let defaultFeedID = UUID()

    // MARK: - 1. Strong Feed: 0 Web Requests


    func testStrongFeedRequiresZeroWebRequests() async {
        let loader = MockPageLoader()
        let engine = ArticlePreparationEngine(pageLoader: loader)

        let longBody = String(repeating: "<p>这是详实的长正文段落，提供丰富的见解与细节。</p>\n", count: 25)
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
        let cacheHTML = "<p>\(longText)</p>"
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
}
