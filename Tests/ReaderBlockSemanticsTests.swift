import XCTest
import Foundation
@testable import PaperRssCore

final class ReaderBlockSemanticsTests: XCTestCase {

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

        XCTAssertEqual(paragraphs.map(\.original).joined(separator: " "), "Before Nested block After Following paragraph")
        XCTAssertTrue(output.contains("Before"))
        XCTAssertTrue(output.contains("Nested block"))
        XCTAssertTrue(output.contains("After"))
        XCTAssertTrue(output.contains("Following paragraph"))
    }
}
