import XCTest
import Foundation
@testable import PaperRssCore

final class ReaderDocumentRendererTests: XCTestCase {

    private func article(
        _ html: String,
        baseURL: URL? = nil,
        features: ArticleFeatures = ArticleFeatures()
    ) -> PreparedArticle {
        PreparedArticle(
            text: html.plainText,
            html: html,
            imageURLs: [],
            baseURL: baseURL,
            source: .feed,
            features: features
        )
    }

    // MARK: - 1. Document Structure & CSP Integrity

    func testRenderHTMLDocumentIncludesStrictCSPAndProperDoctype() {
        let body = "<p>正文内容测试</p>"
        let document = ReaderDocumentRenderer.renderDocument(
            article: article(body, baseURL: URL(string: "https://example.com/articles/1")),
            documentIdentity: "entry-1",
            headerHTML: "<header><h1>标题</h1></header>",
            topInset: 24,
            fontSize: 18,
            extraStyleCSS: ".custom-class { color: red; }"
        )
        let doc = document.html

        XCTAssertTrue(doc.hasPrefix("<!doctype html>"))
        XCTAssertTrue(doc.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(doc.contains("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"))
        XCTAssertTrue(doc.contains("http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(doc.contains("default-src 'none'"))
        XCTAssertTrue(doc.contains("script-src 'none'"), "普通模式下脚本必须严格被 CSP 禁用")
        XCTAssertTrue(doc.contains("<style>:root { --paper-reader-top-inset: 24.0px; --paper-font-size: 18px; }"))
        XCTAssertTrue(doc.contains(".custom-class { color: red; }"))
        XCTAssertTrue(doc.contains("<body><header><h1>标题</h1></header><p>正文内容测试</p></body>"))
        XCTAssertEqual(document.baseURL, URL(string: "https://example.com/articles/1"))
        XCTAssertEqual(document.features, ArticleFeatures(containsMath: false))
        XCTAssertFalse(document.renderSignature.isEmpty)
    }

    // MARK: - 2. Font Size & Inset Boundary Clamping

    func testFontSizeAndTopInsetBoundaries() {
        let docNegative = ReaderDocumentRenderer.renderDocument(
            article: article("<p>负向边距与异常字号测试</p>"),
            documentIdentity: "negative",
            topInset: -10,
            fontSize: 8
        ).html
        XCTAssertTrue(docNegative.contains("--paper-reader-top-inset: 0.0px"), "负数 inset 必须被约束为 0")
        XCTAssertTrue(docNegative.contains("--paper-font-size: 12px"), "过小字号必须被保底约束")

        let docOverlarge = ReaderDocumentRenderer.renderDocument(
            article: article("<p>过大字号测试</p>"),
            documentIdentity: "overlarge",
            topInset: 200,
            fontSize: 100
        ).html
        XCTAssertTrue(docOverlarge.contains("--paper-font-size: 36px"), "过大字号必须被上限约束")
    }

    // MARK: - 3. Math Feature Extension Point Preparation

    func testRenderHTMLDocumentWithMathFeaturePlaceholder() {
        let mathBody = "<p>公式 \\(E = mc^2\\)</p>"
        let docMath = ReaderDocumentRenderer.renderDocument(
            article: article(mathBody, features: ArticleFeatures(containsMath: true)),
            documentIdentity: "math"
        ).html
        XCTAssertTrue(docMath.contains(mathBody))
    }

    // MARK: - 4. Referrer Policy for Hotlink-Protected Image CDNs

    func testRenderHTMLDocumentEmitsReferrerPolicyForSubresources() {
        let doc = ReaderDocumentRenderer.renderDocument(
            article: article("<p>正文</p><img src=\"https://cdn.example.com/a.jpg\">"),
            documentIdentity: "referrer"
        ).html
        XCTAssertTrue(doc.contains("<meta name=\"referrer\" content=\"strict-origin-when-cross-origin\">"),
                      "跨域子资源不得收到文章完整路径或 query")
    }

    func testRenderSignatureTracksOnlyFullReloadInputs() {
        let first = ReaderDocumentRenderer.renderDocument(
            article: article("<p>初始正文和动态摘要 A</p>", baseURL: URL(string: "https://example.com/a")),
            documentIdentity: "entry-a",
            headerHTML: "<header>摘要 A</header>",
            topInset: 84,
            fontSize: 16
        )
        let dynamicUpdate = ReaderDocumentRenderer.renderDocument(
            article: article("<p>初始正文和动态摘要 A</p>", baseURL: URL(string: "https://example.com/a")),
            documentIdentity: "entry-a",
            bodyHTML: "<p>初始正文和动态摘要 A</p><aside>增量译文</aside>",
            headerHTML: "<header>流式摘要 B</header>",
            topInset: 64,
            fontSize: 20
        )
        let newArticle = ReaderDocumentRenderer.renderDocument(
            article: article(
                "<p>另一篇正文</p>",
                baseURL: URL(string: "https://example.com/b"),
                features: ArticleFeatures(containsMath: true)
            ),
            documentIdentity: "entry-b"
        )

        XCTAssertEqual(first.renderSignature, dynamicUpdate.renderSignature, "摘要、inset 和字号使用增量更新，不应触发整页重载")
        XCTAssertNotEqual(first.renderSignature, newArticle.renderSignature)
    }

    func testRendererRejectsUnsafeBaseURLSchemes() {
        let document = ReaderDocumentRenderer.renderDocument(
            article: article("<p>正文</p>", baseURL: URL(string: "file:///private/secret")),
            documentIdentity: "unsafe-base"
        )

        XCTAssertNil(document.baseURL)
    }
}
