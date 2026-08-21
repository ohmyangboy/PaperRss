import XCTest
import Foundation
@testable import PaperRssCore

final class ReaderDocumentRendererTests: XCTestCase {

    // MARK: - 1. Document Structure & CSP Integrity

    func testRenderHTMLDocumentIncludesStrictCSPAndProperDoctype() {
        let body = "<p>正文内容测试</p>"
        let doc = ReaderDocumentRenderer.renderHTMLDocument(
            bodyHTML: body,
            headerHTML: "<header><h1>标题</h1></header>",
            topInset: 24,
            fontSize: 18,
            features: ArticleFeatures(containsMath: false),
            extraStyleCSS: ".custom-class { color: red; }"
        )

        XCTAssertTrue(doc.hasPrefix("<!doctype html>"))
        XCTAssertTrue(doc.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(doc.contains("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"))
        XCTAssertTrue(doc.contains("http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(doc.contains("default-src 'none'"))
        XCTAssertTrue(doc.contains("script-src 'none'"), "普通模式下脚本必须严格被 CSP 禁用")
        XCTAssertTrue(doc.contains("<style>:root { --paper-reader-top-inset: 24.0px; --paper-font-size: 18px; }"))
        XCTAssertTrue(doc.contains(".custom-class { color: red; }"))
        XCTAssertTrue(doc.contains("<body><header><h1>标题</h1></header><p>正文内容测试</p></body>"))
    }

    // MARK: - 2. Font Size & Inset Boundary Clamping

    func testFontSizeAndTopInsetBoundaries() {
        let docNegative = ReaderDocumentRenderer.renderHTMLDocument(
            bodyHTML: "<p>负向边距与异常字号测试</p>",
            topInset: -10,
            fontSize: 8
        )
        XCTAssertTrue(docNegative.contains("--paper-reader-top-inset: 0.0px"), "负数 inset 必须被约束为 0")
        XCTAssertTrue(docNegative.contains("--paper-font-size: 12px"), "过小字号必须被保底约束")

        let docOverlarge = ReaderDocumentRenderer.renderHTMLDocument(
            bodyHTML: "<p>过大字号测试</p>",
            topInset: 200,
            fontSize: 100
        )
        XCTAssertTrue(docOverlarge.contains("--paper-font-size: 36px"), "过大字号必须被上限约束")
    }

    // MARK: - 3. Math Feature Extension Point Preparation

    func testRenderHTMLDocumentWithMathFeaturePlaceholder() {
        let mathBody = "<p>公式 \\(E = mc^2\\)</p>"
        let docMath = ReaderDocumentRenderer.renderHTMLDocument(
            bodyHTML: mathBody,
            features: ArticleFeatures(containsMath: true)
        )
        XCTAssertTrue(docMath.contains(mathBody))
    }
}
