import XCTest
import Foundation
@testable import PaperRssCore

private struct NoNetworkPageLoader: ArticlePageLoading {
    func loadPage(for url: URL) async throws -> LoadedArticlePage? { nil }
}

final class ReaderEngineEndToEndTests: XCTestCase {

    let defaultFeedID = UUID()

    func testStructureVariantsPreserveMediaThroughActualRenderer() async throws {
        let description = String(repeating: "这是一段完整的文章说明，包含足够的正文用于直接采用订阅内容。", count: 12)
        let variants: [(String, String, Int)] = [
            ("mixed-inline", "<p><strong>工具标题</strong><br>\n<a href=\"https://unknown.example/tool\">工具链接</a><br>\n介绍<img src=\"/one.png\"></p>", 1),
            ("explicit-breaks", "<p>第一段<img src=\"/one.png\"><br><br><em>第二段</em><img src=\"/two.png\"></p>", 2),
            ("nested-link", "<p><a href=\"/tool\">第一行<br><br>第二行<img src=\"/one.png\"></a></p>", 1),
            ("media-only-fragment", "<p>正文<br><br><img src=\"/one.png\"><br><br>后续正文</p>", 1),
            ("lazy-image", "<p>说明<img data-src=\"/one.png\" src=\"placeholder.gif\"></p>", 1),
            ("nested-figure", "<div><figure><img src=\"/one.png\"><figcaption>图片说明</figcaption></figure><p>后续文字</p></div>", 1),
            ("table-media", "<table><tr><td>说明<img src=\"/one.png\"></td></tr></table>", 1)
        ]
        for (name, body, count) in variants {
            let entry = Entry(id: name, feedID: defaultFeedID, title: "结构验证",
                              url: URL(string: "https://unknown.example/article"), publishedAt: .now,
                              summary: "", contentHTML: "<p>\(description)</p>" + body + "<p>文章结束。</p>")
            let (prepared, _) = await ArticlePreparationEngine(pageLoader: NoNetworkPageLoader()).prepare(entry: entry, cached: nil)
            XCTAssertEqual(prepared.source, .feed, name)
            XCTAssertEqual(prepared.imageURLs.count, count, name)
            let paragraphs = ArticleExtractor.readerParagraphs(in: prepared.html)
            let translations = paragraphs.map { BilingualSegment(id: $0.id, original: $0.original, translation: "译文" + $0.id) }
            for segments in [[], translations] {
                let document = ReaderDocumentRenderer.renderDocument(article: prepared, documentIdentity: name, translations: segments)
                XCTAssertEqual(ArticleExtractor.imageURLs(from: document.html, baseURL: document.baseURL), prepared.imageURLs, name)
                for paragraph in paragraphs {
                    XCTAssertTrue(document.html.contains("data-paper-rss-id=\"\(paragraph.id)\""), name)
                    if !segments.isEmpty {
                        XCTAssertTrue(document.html.contains("paper-rss-translation-\(paragraph.id)\""), name)
                    }
                }
                for tag in ["img", "a", "strong", "em", "figure", "figcaption", "table"] {
                    let expression = try NSRegularExpression(pattern: "<" + tag + "\\b[^>]*>")
                    func countTags(_ html: String) -> Int {
                        expression.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
                    }
                    XCTAssertEqual(countTags(document.html), countTags(prepared.html), "\(name): \(tag)")
                }
            }
        }
    }

    // MARK: - 1. Mixed Markup & Markdown End-to-End Pipeline

    func testMixedMarkupAndMarkdownEndToEndPipeline() async {
        let rawContent = """
        # Comprehensive Architecture Review

        This is an introductory paragraph with **bold text** and <mark>highlighted term</mark>.

        > [!NOTE]
        > Core design principles must remain inviolable.

        Here is a code block:
        ```bash
        export PAPERRSS_MODE=production
        echo $PAPERRSS_MODE
        ```

        And a closing paragraph with an image:
        <img data-original="https://example.com/hero-hires.jpg" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" alt="Architecture Diagram">
        """

        let entry = Entry(
            id: "e2e-entry-mixed-1",
            feedID: defaultFeedID,
            title: "Architecture Review",
            url: URL(string: "https://example.com/arch-review"),
            publishedAt: .now,
            summary: "Overview of architecture",
            contentHTML: rawContent
        )

        let engine = ArticlePreparationEngine(pageLoader: NoNetworkPageLoader())
        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)

        // 1. 同源与来源断言
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertEqual(prepared.baseURL, URL(string: "https://example.com/arch-review"))

        // 2. 正文 HTML 包含规范化标签
        XCTAssertTrue(prepared.html.contains("<h1>Comprehensive Architecture Review</h1>"))
        XCTAssertTrue(prepared.html.contains("<mark>highlighted term</mark>"))
        XCTAssertTrue(prepared.html.contains("<blockquote"))

        // 3. 多源懒加载高清图片提取与 eager 优先级
        XCTAssertEqual(prepared.imageURLs.count, 1)
        XCTAssertEqual(prepared.imageURLs.first?.absoluteString, "https://example.com/hero-hires.jpg")
        XCTAssertTrue(prepared.html.contains("src=\"https://example.com/hero-hires.jpg\""))
        XCTAssertTrue(prepared.html.contains("loading=\"eager\""))

        // 4. 数学公式特征（无公式，代码块变量被安全排除）
        XCTAssertFalse(prepared.features.containsMath)

        // 5. 渲染为最终 Reader HTML 文档
        let renderedDocument = ReaderDocumentRenderer.renderDocument(
            article: prepared,
            documentIdentity: entry.id,
            headerHTML: "<header class=\"paper-header-container\"><h1>\(entry.title)</h1></header>",
            topInset: 84,
            fontSize: 17
        )
        let finalDocument = renderedDocument.html

        XCTAssertTrue(finalDocument.hasPrefix("<!doctype html>"))
        XCTAssertTrue(finalDocument.contains("http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(finalDocument.contains("default-src 'none'"))
        XCTAssertTrue(finalDocument.contains("--paper-reader-top-inset: 84.0px"))
        XCTAssertTrue(finalDocument.contains("--paper-font-size: 17px"))
        XCTAssertEqual(renderedDocument.baseURL, prepared.baseURL)
        XCTAssertEqual(renderedDocument.features, prepared.features)
    }

    // MARK: - 2. Math & Currency Disambiguation End-to-End

    func testMathArticleEndToEndPipeline() async {
        let mathHTML = """
        <div class="article-content">
          <p>This paper explores the wave equation in multiple spatial dimensions:</p>
          <p>\\[ \\frac{\\partial^2 u}{\\partial t^2} = c^2 \\nabla^2 u \\]</p>
          <p>Equipment was procured for $4500 with a warranty of $200 per year.</p>
        </div>
        """

        let entry = Entry(
            id: "e2e-entry-math-1",
            feedID: defaultFeedID,
            title: "Wave Equation Analysis",
            url: URL(string: "https://example.com/physics"),
            publishedAt: .now,
            summary: "Mathematical physics post",
            contentHTML: mathHTML
        )

        let engine = ArticlePreparationEngine(pageLoader: NoNetworkPageLoader())
        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)

        XCTAssertTrue(prepared.features.containsMath, "必须精准识别块级 TeX 公式并忽略金额")
        XCTAssertEqual(prepared.source, .feed)
    }

    // MARK: - 3. Multi-Image Lazy Loading Sequence

    func testMultiImageLazyLoadingSequence() async {
        let multiImgHTML = """
        <div class="post-images">
          <p>First paragraph with <img src="https://example.com/img1.jpg" alt="1"></p>
          <p>Second paragraph with <img src="https://example.com/img2.jpg" alt="2"></p>
          <p>Third paragraph with <img src="https://example.com/img3.jpg" alt="3"></p>
          <p>Fourth paragraph with <img src="https://example.com/img4.jpg" alt="4"></p>
        </div>
        """

        let entry = Entry(
            id: "e2e-entry-imgs-1",
            feedID: defaultFeedID,
            title: "Photo Gallery",
            url: URL(string: "https://example.com/gallery"),
            publishedAt: .now,
            summary: "Gallery summary",
            contentHTML: multiImgHTML
        )

        let engine = ArticlePreparationEngine(pageLoader: NoNetworkPageLoader())
        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)

        XCTAssertEqual(prepared.imageURLs.count, 4)
        XCTAssertTrue(prepared.html.contains("src=\"https://example.com/img1.jpg\"") && prepared.html.contains("loading=\"eager\""))
        XCTAssertTrue(prepared.html.contains("src=\"https://example.com/img2.jpg\"") && prepared.html.contains("loading=\"eager\""))
        XCTAssertTrue(prepared.html.contains("src=\"https://example.com/img3.jpg\"") && prepared.html.contains("loading=\"lazy\""))
        XCTAssertTrue(prepared.html.contains("src=\"https://example.com/img4.jpg\"") && prepared.html.contains("loading=\"lazy\""))
    }
}
