import XCTest
import Foundation
@testable import PaperRssCore

final class ReaderBlockSemanticsTests: XCTestCase {

    func testMixedParagraphPreservesMediaLinksAndEmphasis() {
        let source = """
        <img src="https://example.com/cover.jpg">
        <p><strong>工具标题</strong><br>
        <a href="https://example.com/tool">工具链接</a><br>
        介绍文字<br>
        <img src="https://example.com/tool.png"></p>
        """
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
        XCTAssertEqual(ArticleExtractor.imageURLs(from: output, baseURL: nil),
                       ArticleExtractor.imageURLs(from: source, baseURL: nil))
        XCTAssertTrue(output.contains("<strong>工具标题</strong>"))
        XCTAssertTrue(output.contains("<a href=\"https://example.com/tool\">工具链接</a>"))
        XCTAssertEqual(ArticleExtractor.readerParagraphs(in: source).map(\.id), ["p0"])
    }

    func testExplicitBreakParagraphsRetainInlineHTMLAndTranslationAnchors() {
        let source = "<p><strong>第一段</strong><br><br>第二段<img src=\"https://example.com/a.png\"></p>"
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        let segments = paragraphs.map {
            BilingualSegment(id: $0.id, original: $0.original, translation: "译文" + $0.id)
        }
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)
        XCTAssertEqual(paragraphs.map(\.id), ["p0_0", "p0_1"])
        XCTAssertTrue(output.contains("<strong>第一段</strong>"))
        XCTAssertTrue(output.contains("第二段<img src=\"https://example.com/a.png\">"))
        XCTAssertTrue(output.contains("paper-rss-translation-p0_1"))
    }

    func testNestedInlineBreaksFallBackToIntactBlock() {
        let source = "<p><a href=\"https://example.com\">第一行<br><br>第二行<img src=\"https://example.com/a.png\"></a></p>"
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
        XCTAssertEqual(ArticleExtractor.readerParagraphs(in: source).map(\.id), ["p0"])
        XCTAssertEqual(output.replacingOccurrences(of: " data-paper-rss-id=\"p0\"", with: ""), source)
    }

    func testSourceFormattingDoesNotChangeMediaOrParagraphIDs() {
        let compact = "<p><strong>标题</strong><br><a href=\"https://example.com/tool\">链接</a><br>说明<img src=\"https://example.com/a.png\"></p>"
        let formatted = compact.replacingOccurrences(of: "<br>", with: "<br>\n")
        let first = ArticleExtractor.insertingInlineTranslations(into: compact, segments: [])
        let second = ArticleExtractor.insertingInlineTranslations(into: formatted, segments: [])
        XCTAssertEqual(ArticleExtractor.readerParagraphs(in: compact).map(\.id), ArticleExtractor.readerParagraphs(in: formatted).map(\.id))
        XCTAssertEqual(second.replacingOccurrences(of: "\n", with: ""), first)
    }

    func testMalformedAndMediaOnlyFragmentsKeepOriginalHTML() {
        for source in [
            "<p>前文<br><br><img src=\"https://example.com/a.png\"><br><br>后文</p>",
            "<p><strong>未闭合<br><br>文本<img src=\"https://example.com/a.png\"></p>",
            "<p>开头<br><br></p>",
            "<p><code>代码<br><br>仍然是代码</code></p>"
        ] {
            let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
            XCTAssertEqual(output.replacingOccurrences(of: " data-paper-rss-id=\"p0\"", with: ""), source)
        }
    }

    func testOldSubparagraphTranslationCannotAttachToNewIntactBlock() {
        let source = "<p><strong>标题</strong><br>\n说明<img src=\"https://example.com/a.png\"></p>"
        let old = BilingualSegment(id: "p0_0", original: "标题", translation: "旧译文")
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [old], pendingIDs: ["p0"])
        XCTAssertFalse(output.contains("旧译文"))
        XCTAssertTrue(output.contains("paper-rss-translation-p0\""))
        XCTAssertTrue(output.contains("<img"))
    }

    func testInsertingTranslationsPreservesBlockquoteSemantics() {
        let source = """
        <blockquote>
        <p>第一段引用正文，阐述核心观点。</p>
        <p>第二段引用正文，进一步补充说明。</p>
        </blockquote>
        <p>后续普通段落文本。</p>
        """

        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])

        XCTAssertTrue(output.contains("<blockquote"), "多段引用必须在插入注解后保留 blockquote 语义")
        XCTAssertTrue(output.contains("</blockquote>"))
    }

    func testInsertingTranslationsPreservesHeadingAndPreformattedSemantics() {
        let source = """
        <h2 class="jltoc--item">01 显存划的线</h2>
        <pre><code>line one
        line two</code></pre>
        <p>正文段落。</p>
        """

        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])

        XCTAssertTrue(output.contains("<h2"), "h2 标题必须保留标题语义")
        XCTAssertFalse(output.contains("<h2 class=\"paper-rss-subparagraph\""), "标题不应被展平为子段落")
        XCTAssertTrue(output.contains("<pre"), "pre 代码块必须保留 pre 语义")
    }

    func testInsertingTranslationsStableForSimpleParagraphs() {
        let source = "<p>单一普通段落，没有换行拆分。</p>"
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
        XCTAssertTrue(output.contains("data-paper-rss-id"), "普通段落仍需稳定的段落 ID 注解")
    }

    func testInsertingTranslationsPreservesTableAndListSemantics() throws {
        let source = """
        <table>
            <thead><tr><th>Symbol</th><th>Meaning</th></tr></thead>
            <tbody>
                <tr><td>$L$</td><td>Number of unique labels.</td></tr>
                <tr><td>$(\\mathbf{x}^l, y)$</td><td>Labeled dataset.</td></tr>
            </tbody>
        </table>
        <ul><li>第一项</li><li>第二项</li></ul>
        """

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.id), ["p0", "p1"])
        XCTAssertEqual(paragraphs[0].original, "Symbol Meaning\n\n$L$ Number of unique labels.\n$(\\mathbf{x}^l, y)$ Labeled dataset.")
        XCTAssertEqual(paragraphs[1].original, "第一项\n\n第二项")

        let segments = [
            BilingualSegment(id: "p0", original: paragraphs[0].original, translation: "表格译文"),
            BilingualSegment(id: "p1", original: paragraphs[1].original, translation: "列表译文")
        ]
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        XCTAssertTrue(output.contains("<table data-paper-rss-id=\"p0\""), "表格必须成为可观察单元")
        let tableEnd = try XCTUnwrap(output.range(of: "</table>")?.upperBound)
        let tableTranslationStart = try XCTUnwrap(output.range(of: "<aside id=\"paper-rss-translation-p0\"")?.lowerBound)
        XCTAssertLessThanOrEqual(tableEnd, tableTranslationStart, "表格译文必须插入完整表格之后")
        XCTAssertTrue(output.contains("<tr"), "表格行必须保留")
        XCTAssertTrue(output.contains("<ul data-paper-rss-id=\"p1\""), "列表必须成为单一可观察单元")
        XCTAssertTrue(output.contains("<li"), "列表项必须保留 li 语义")
        XCTAssertTrue(output.contains("paper-rss-translation-p1"))
    }

    func testRootDivDoesNotCollapseWholeArticleIntoOneTranslationUnit() {
        let source = """
        <div class="article-content">
            <p>第一段正文。</p>
            <p>第二段正文。</p>
            <p>第三段正文。</p>
        </div>
        """

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)

        XCTAssertEqual(paragraphs.map(\.id), ["p0", "p1", "p2"])
        XCTAssertEqual(paragraphs.map(\.original), ["第一段正文。", "第二段正文。", "第三段正文。"])
    }

    func testNestedListsRemainOneBalancedTranslationUnit() {
        let source = """
        <ul><li>外层第一项<ul><li>内层项目</li></ul></li><li>外层第二项</li></ul>
        <p>列表后的段落。</p>
        """
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        let segments = [
            BilingualSegment(id: "p0", original: paragraphs[0].original, translation: "列表译文")
        ]

        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        XCTAssertEqual(paragraphs.map(\.id), ["p0", "p1"])
        XCTAssertEqual(output.components(separatedBy: "<ul").count, source.components(separatedBy: "<ul").count)
        XCTAssertEqual(output.components(separatedBy: "</ul>").count, source.components(separatedBy: "</ul>").count)
        let outerListEnd = try? XCTUnwrap(output.range(of: "</ul>", options: .backwards)?.upperBound)
        let translationStart = try? XCTUnwrap(output.range(of: "paper-rss-translation-p0")?.lowerBound)
        XCTAssertNotNil(outerListEnd)
        XCTAssertNotNil(translationStart)
        if let outerListEnd, let translationStart {
            XCTAssertLessThanOrEqual(outerListEnd, translationStart)
        }
    }

    func testMalformedNestedBlocksNeverProduceOverlappingTranslationRanges() {
        let source = "<p>Before<div>Nested block</div>After</p><p>Following paragraph</p>"

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])

        XCTAssertEqual(paragraphs.map(\.id), ["p0", "p1"], "不完整嵌套段落整块保留")
        XCTAssertEqual(paragraphs.map(\.original).joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression), "Before Nested block After Following paragraph")
        XCTAssertTrue(output.contains("Before"))
        XCTAssertTrue(output.contains("Nested block"))
        XCTAssertTrue(output.contains("After"))
        XCTAssertTrue(output.contains("Following paragraph"))
    }
}
