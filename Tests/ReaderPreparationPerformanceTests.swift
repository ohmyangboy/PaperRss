import XCTest
import Foundation
@testable import PaperRssCore

final class ReaderPreparationPerformanceTests: XCTestCase {
    func testContainerRangesRemainCorrectAfterUnicodeAndEmoji() throws {
        let html = "前缀👨‍👩‍👧‍👦e\u{301}<div class=\"outer\"><section><div>中文🧑🏽‍💻正文</div></section></div>结尾"
        let containers = ArticleExtractor.scanBalancedContainers(from: html)
        XCTAssertEqual(containers.count, 3)
        for container in containers {
            XCTAssertEqual(String(html[container.range]), container.fullHTML)
            let utf16Range = NSRange(container.range, in: html)
            XCTAssertEqual(container.startOffset, utf16Range.location)
            XCTAssertEqual(container.endOffset, NSMaxRange(utf16Range))
        }
        let outer = try XCTUnwrap(containers.first { $0.attributes.contains("outer") })
        XCTAssertGreaterThan(outer.startOffset, html.distance(from: html.startIndex, to: outer.range.lowerBound),
                             "UTF-16 位置不能再被当作 Character offset")
        XCTAssertTrue(containers.allSatisfy {
            $0.startOffset >= outer.startOffset && $0.endOffset <= outer.endOffset
        })
    }

    func testChromeRemovalPreservesUnicodeAroundNestedAndAdjacentContainers() {
        let html = """
        <article>
        <p>前文👨‍👩‍👧‍👦与组合字符é必须完整保留。</p>
        <div class="share"><section class="social"><a href="/share">应当删除的分享工具</a></section></div>
        <p>中间正文🧑🏽‍💻必须完整保留。</p>
        <div class="sidebar"><a href="/profile">应当删除的推荐工具</a></div>
        <p>后文🇨🇳必须完整保留。</p>
        </article>
        """
        let content = ArticleExtractor.content(from: html, baseURL: nil)
        XCTAssertTrue(content.text.contains("前文👨‍👩‍👧‍👦与组合字符é必须完整保留。"))
        XCTAssertTrue(content.text.contains("中间正文🧑🏽‍💻必须完整保留。"))
        XCTAssertTrue(content.text.contains("后文🇨🇳必须完整保留。"))
        XCTAssertFalse(content.text.contains("应当删除"))
    }

    func testPreparedReaderContentSharesStableIDsAcrossMixedBlocks() throws {
        let html = """
        <h1>文章标题</h1>
        <p>第一段👨‍👩‍👧‍👦<br><br><strong>第二段</strong></p>
        <table><tr><td>$L$</td><td>指标说明。</td><td>额外说明。</td></tr></table>
        <ul><li>父条目<ul><li>子条目</li></ul></li><li>第二项</li></ul>
        <pre><code>let value = "代码禁区"</code></pre>
        <p>结尾正文。</p><img src="https://example.com/a.png">
        """
        let imageURL = URL(string: "https://example.com/a.png")!
        let source = PreparedArticle(text: html.plainText, html: html, imageURLs: [imageURL],
                                     baseURL: URL(string: "https://example.com/article"), source: .feed,
                                     features: ArticleFeatures(containsMath: true))
        let prepared = source.preparedForReader(title: "文章标题")
        let paragraphs = try XCTUnwrap(prepared.readerParagraphs)
        let annotated = try XCTUnwrap(prepared.annotatedHTML)
        XCTAssertFalse(prepared.html.contains("<h1>"))
        XCTAssertEqual(paragraphs.map(\.id), ["title", "p0_0", "p0_1", "p1_0", "p1_1", "p2_0", "p2_1", "p2_2", "p3"])
        for paragraph in paragraphs where paragraph.id != "title" {
            XCTAssertTrue(annotated.contains("data-paper-rss-id=\"\(paragraph.id)\""))
        }
        XCTAssertFalse(paragraphs.contains { $0.original.contains("代码禁区") })
        XCTAssertTrue(annotated.contains("<pre><code>let value = \"代码禁区\"</code></pre>"))
        XCTAssertEqual(prepared.imageURLs, source.imageURLs)
        XCTAssertEqual(prepared.baseURL, source.baseURL)
        XCTAssertEqual(prepared.features, source.features)
        XCTAssertEqual(prepared.preparedForReader(title: "文章标题"), prepared)
        XCTAssertEqual(annotated, ArticleExtractor.insertingInlineTranslations(into: prepared.html, segments: []))
        XCTAssertEqual(paragraphs, ArticleExtractor.readerParagraphs(in: prepared.html, title: "文章标题"))
    }

    func testTextOnlyReaderFallbackEscapesMarkupAndPreservesLineBreaks() throws {
        let source = PreparedArticle(text: "中文 <example> & 👨‍👩‍👧‍👦\n下一行", html: " \n", imageURLs: [],
                                     baseURL: nil, source: .cache)
        let prepared = source.preparedForReader(title: "标题")
        XCTAssertTrue(prepared.html.contains("&lt;example&gt; &amp;"))
        XCTAssertTrue(prepared.html.contains("<br>下一行"))
        XCTAssertFalse(prepared.html.contains("<example>"))
        XCTAssertEqual(try XCTUnwrap(prepared.readerParagraphs).map(\.id), ["title", "p0"])
    }

    func testBalancedContainerScanDoesNotRegressToQuadraticUnicodeOffsets() {
        func sample(_ count: Int) -> String {
            String(repeating: "<div><p>中文段落👨‍👩‍👧‍👦包含背景、过程和结论，保持所有正文。</p></div>", count: count)
        }
        func medianSeconds(_ html: String, expectedCount: Int) -> Double {
            var times: [Double] = []
            for _ in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                let containers = ArticleExtractor.scanBalancedContainers(from: html)
                times.append(ProcessInfo.processInfo.systemUptime - start)
                XCTAssertEqual(containers.count, expectedCount)
            }
            return times.sorted()[1]
        }
        _ = ArticleExtractor.scanBalancedContainers(from: sample(20))
        let smallHTML = sample(250)
        let largeHTML = sample(2_000)
        let small = medianSeconds(smallHTML, expectedCount: 250)
        let large = medianSeconds(largeHTML, expectedCount: 2_000)
        print("READER_CONTAINER_SCAN blocks=250 bytes=\(smallHTML.utf8.count) medianMS=\(small * 1_000)")
        print("READER_CONTAINER_SCAN blocks=2000 bytes=\(largeHTML.utf8.count) medianMS=\(large * 1_000)")
        // 输入放大 8 倍；给调度噪声充分余量，同时拦截原来的约 64 倍增长。
        XCTAssertLessThan(large, small * 24 + 0.01)
    }
}
