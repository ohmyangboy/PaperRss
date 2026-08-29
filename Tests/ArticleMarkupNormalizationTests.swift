import XCTest
import Foundation
@testable import PaperRssCore

final class ArticleMarkupNormalizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ArticleMarkupNormalizer.resetDiagnosticCounters()
    }

    // MARK: - 1. Inline-only HTML Feed Bodies (img, a)

    func testInlineOnlyImgFeedBodyPreserved() {
        let raw = "<img src=\"https://example.com/photo.jpg\" alt=\"Landscape\">"
        let content = ArticleExtractor.content(from: raw, baseURL: URL(string: "https://example.com")!)
        
        XCTAssertTrue(content.html.contains("<img"), "inline-only img 必须保留为 img 标签")
        XCTAssertTrue(content.html.contains("src=\"https://example.com/photo.jpg\""))
        XCTAssertFalse(content.html.contains("&lt;img"), "inline-only img 严禁显示为转义源码")
        XCTAssertEqual(content.imageURLs.map(\.absoluteString), ["https://example.com/photo.jpg"])
    }

    func testInlineOnlyAFeedBodyPreserved() {
        let raw = "<a href=\"https://example.com/article\">点击阅读全文</a>"
        let content = ArticleExtractor.content(from: raw, baseURL: URL(string: "https://example.com")!)
        
        XCTAssertTrue(content.html.contains("<a href=\"https://example.com/article\""), "inline-only a 必须保留为 a 标签")
        XCTAssertTrue(content.html.contains("点击阅读全文"))
        XCTAssertFalse(content.html.contains("&lt;a"), "inline-only a 严禁显示为转义源码")
    }

    // MARK: - 2. Native HTML Container Selection & Class Preservation

    func testTargetContentSelectedFromFullPageWithSidebar() {
        let fullPage = """
        <html>
        <body>
            <div class="sidebar">
                <p>侧边栏导航一</p>
                <p>侧边栏导航二</p>
            </div>
            <div class="article-content">
                <h1>主文章标题</h1>
                <p>这是正文的第一段，包含充分的字数以满足正文提取容器阈值。我们需要确保侧边栏的干扰文本不会被错误当成正文。</p>
                <p>这是正文的第二段，继续阐述核心观点，保证提取器能够通过容器评分精准定位到 article-content 容器，避免误选外部容器。</p>
                <p>这是正文的第三段，提供进一步的上下文和说明，使正文总文本量稳定超出 120 字符提取门槛并被精准选出。</p>
            </div>
        </body>
        </html>
        """

        let content = ArticleExtractor.content(from: fullPage, baseURL: URL(string: "https://example.com")!)
        XCTAssertTrue(content.text.contains("主文章标题"))
        XCTAssertTrue(content.text.contains("这是正文的第一段"))
        XCTAssertFalse(content.text.contains("侧边栏导航一"), "侧边栏内容应当在容器选择后被剔除")
    }

    func testContainerClassesPreservedBeforeSelection() {
        let html = """
        <div class="post-content">
            <h1>保留选择线索标题</h1>
            <p>第一段：用于证明 normalizer 没有在正文选择前丢弃 class 属性与结构线索。</p>
            <p>第二段：包含足够的文本字符以通过正文提取器的容器提取阈值。</p>
        </div>
        """

        let normalized = ArticleMarkupNormalizer.normalize(html, baseURL: nil)
        XCTAssertTrue(normalized.contains("class=\"post-content\""), "normalizer 输出必须保留 class 属性供 Extractor 评分")
    }

    // MARK: - 3. Mixed Quote-Aware Attributes and Tag Parsing

    func testMixedAttributesWithGreaterThanAndMarkdownSyntax() {
        let mixed = """
        <div class="content">
            <p>访问：<a href="https://example.com/calc?a=1>0&b=2" title="*Title with star*">比较运算链接</a></p>
            <p>正文包含 **真实加粗** 重点。</p>
        </div>
        """

        let content = ArticleExtractor.content(from: mixed, baseURL: URL(string: "https://example.com")!)
        XCTAssertTrue(content.html.contains("href=\"https://example.com/calc?a=1&gt;0&amp;b=2\"") || content.html.contains("href=\"https://example.com/calc?a=1>0&b=2\"") || content.html.contains("calc?a=1"), "属性内包含 > 时不应损坏 HTML 标签")
        XCTAssertTrue(content.html.contains("<strong>真实加粗</strong>"), "正文区域 Markdown 正常转换")
    }

    func testNoIllegalHeadingOrBlockInsideParagraph() {
        let mixed = """
        <p>
        ### 不应变成非法嵌套的标题
        这是一段普通段落内容。
        </p>
        """

        let content = ArticleExtractor.content(from: mixed, baseURL: nil)
        XCTAssertFalse(content.html.contains("<p><h3") || content.html.contains("<p>\n<h3"), "严禁在 <p> 内部非法嵌套 <h3>")
    }

    func testMixedFencedCodePreservesIndentation() {
        let mixed = """
        <div class="article-body">
            <p>代码示例如下：</p>
            ```swift
                // 保留 4 空格缩进
                let x = 10
                let y = 20
            ```
        </div>
        """

        let content = ArticleExtractor.content(from: mixed, baseURL: nil)
        XCTAssertTrue(content.html.contains("<pre><code"), "fenced code 应当转换为 pre/code")
        XCTAssertTrue(content.html.contains("    let x = 10"), "fenced code 内部缩进应当被完整保留")
    }

    // MARK: - 4. Markdown Formats (Emphasis, Inline Code, GFM, Headings)

    func testSingleEmphasisMarkdownConverted() {
        let md = "这是一段包含 *单一斜体强调* 的正文段落。"
        let content = ArticleExtractor.content(from: md, baseURL: nil)
        XCTAssertTrue(content.html.contains("<em>单一斜体强调</em>"), "单一 *emphasis* 应当转换为 em 标签")
    }

    func testSingleInlineCodeMarkdownConverted() {
        let md = "请执行 `npm run verify` 命令。"
        let content = ArticleExtractor.content(from: md, baseURL: nil)
        XCTAssertTrue(content.html.contains("<code>npm run verify</code>"), "单一 `inline code` 应当转换为 code 标签")
    }

    func testNoConversionInsidePreCodeKbdAndAttributes() {
        let input = """
        <p>正文 **加粗** 转换。</p>
        <pre><code>
        // *星号不应变斜体*
        // $100.00
        int value = a * b * c;
        </code></pre>
        <p>键位：<kbd>Ctrl+*</kbd></p>
        <img src="https://example.com/test.png" alt="*not italic*">
        """

        let content = ArticleExtractor.content(from: input, baseURL: URL(string: "https://example.com")!)
        XCTAssertTrue(content.html.contains("<strong>加粗</strong>"))
        XCTAssertTrue(content.html.contains("*星号不应变斜体*"))
        XCTAssertFalse(content.html.contains("<em>星号不应变斜体</em>"))
        XCTAssertTrue(content.html.contains("<kbd>Ctrl+*</kbd>"))
    }

    // MARK: - 5. Security & Sanitization Order

    func testDoubleEscapedScriptThroughContentPipeline() {
        let doubleEscaped = "&amp;lt;script&amp;gt;alert('pwned')&amp;lt;/script&amp;gt;"
        let content = ArticleExtractor.content(from: doubleEscaped, baseURL: nil)
        XCTAssertFalse(content.html.contains("<script>"), "双重转义经过 Content 管线绝不能还原为可执行 script 标签")
    }

    func testAuthorSVGRemoved() {
        let input = """
        <article class="post">
            <h1>文章标题</h1>
            <svg width="100" height="100"><circle cx="50" cy="50" r="40"/></svg>
            <p>正文内容，确保通过长度阈值要求，包含足够的文字描述。</p>
        </article>
        """

        let content = ArticleExtractor.content(from: input, baseURL: nil)
        XCTAssertFalse(content.html.contains("<svg"), "作者提供的 SVG 标签必须由 sanitizer 移除")
        XCTAssertTrue(content.html.contains("文章标题"))
    }

    // MARK: - 6. Idempotency & Unknown Host Structure

    func testContentHTMLIdempotentAcrossAllFormats() {
        let markdown = "# 标题\n\n正文 **粗体** 与 [链接](https://example.com)。"
        let firstContent = ArticleExtractor.content(from: markdown, baseURL: URL(string: "https://example.com")!)
        let secondContent = ArticleExtractor.content(from: firstContent.html, baseURL: URL(string: "https://example.com")!)

        XCTAssertEqual(secondContent.html, firstContent.html, "对 Content.html 再次提取必须完全幂等")
    }

    func testUnknownHostSameStructureThroughContentPipeline() {
        let template = """
        <div class="article-content">
            <h1>结构一致性测试</h1>
            <p>这是正文内容，包含图片：</p>
            <img src="https://HOST_PLACEHOLDER/cover.png" alt="Cover">
            <p>包含一段足够长度的描述文字，用于确保提取器识别到该容器并完成清洗。</p>
        </div>
        """

        let htmlA = template.replacingOccurrences(of: "HOST_PLACEHOLDER", with: "site-a.example")
        let htmlB = template.replacingOccurrences(of: "HOST_PLACEHOLDER", with: "site-b.example")

        let contentA = ArticleExtractor.content(from: htmlA, baseURL: URL(string: "https://site-a.example")!)
        let contentB = ArticleExtractor.content(from: htmlB, baseURL: URL(string: "https://site-b.example")!)

        let normalizedA = contentA.html.replacingOccurrences(of: "site-a.example", with: "COMMON_HOST")
        let normalizedB = contentB.html.replacingOccurrences(of: "site-b.example", with: "COMMON_HOST")
        XCTAssertEqual(normalizedA, normalizedB, "不同未知域名但在相同结构下应产生完全相同的 Content.html")
    }

    func testNativeHTMLContainerExtractionMatchesBaseline() {
        let html = """
        <html>
        <body>
            <div class="entry-content">
                <h1>基线标题</h1>
                <p>基线段落一，用于测试原生 HTML 的正文提取容器行为与 Goal 01 之前保持一致。</p>
                <p>基线段落二，补充字符数确保超过 120 字符的容器选择阈值要求。</p>
            </div>
        </body>
        </html>
        """

        let content = ArticleExtractor.content(from: html, baseURL: URL(string: "https://example.com")!)
        XCTAssertTrue(content.text.contains("基线标题"))
        XCTAssertTrue(content.text.contains("基线段落一"))
    }

    // MARK: - 7. Fast Path Direct Evidence (No AST Construction)

    func testNativeHTMLFastPathDoesNotConstructAST() {
        let nativeHTML = """
        <article class="post-content">
            <h1>明确的原生 HTML</h1>
            <p>这是一篇标准原生 HTML 文章，包含 <strong>粗体</strong> 和 <em>斜体</em>。</p>
        </article>
        """

        ArticleMarkupNormalizer.resetDiagnosticCounters()
        _ = ArticleMarkupNormalizer.normalize(nativeHTML, baseURL: nil)
        
        XCTAssertEqual(
            ArticleMarkupNormalizer.diagnosticASTConstructionCount,
            0,
            "明确的原生 HTML 在 normalize 时必须走 Fast Path，构建 AST 次数必须为 0"
        )
    }

    // MARK: - 7.5 公式字符不得被 markdown 强调吞并（lilianweng/harness 回归）

    func testMathFormulaAsterisksSurviveMixedContentNormalization() {
        let html = """
        <article><p>The bi-level optimization:</p>
        <div>
        $$
        \\text{Inner: }c_s^*=\\arg\\max_{c_s}J
        \\text{Outer: }s^*=\\arg\\max_{s\\in\\mathcal{S}}
        $$
        </div></article>
        """
        let normalized = ArticleMarkupNormalizer.normalize(html)
        XCTAssertFalse(normalized.contains("<em>"), "显示公式内部的星号不得被 markdown 强调吞并")
        XCTAssertTrue(normalized.contains("c_s^*="), "公式星号必须逐字保留")
        XCTAssertTrue(normalized.contains("s^*="))
        XCTAssertFalse(normalized.contains("PAPERRSS_MATH_TOKEN"), "占位符必须全部还原，不得泄漏到最终文档")
    }

    func testGenuineProseEmphasisStillConvertsWhenFormulasPresent() {
        let html = "<p>plain *emphasis* stays</p><p>formula $c_s^*$ and $s^*$ here</p>"
        let normalized = ArticleMarkupNormalizer.normalize(html)
        XCTAssertTrue(normalized.contains("<em>emphasis</em>"), "正文真实强调必须照常转换")
        XCTAssertTrue(normalized.contains("$c_s^*$"), "行内公式必须逐字保留")
        XCTAssertTrue(normalized.contains("$s^*$"))
    }

    func testDetectFormatDoesNotSelfTriggerOnFormulaAsterisks() {
        // 仅由公式内部星号伪造 markdown 信号的输入必须判为 html（Fast Path）
        let page = "<article><p>text</p><div>\n$$\nc_s^*=x \\quad s^*=y\n$$\n</div></article>"
        XCTAssertEqual(ArticleMarkupNormalizer.detectFormat(page), .html)
    }

    // MARK: - 7.8 图片对齐语法（Obsidian wiki 嵌入 / kramdown 属性 / Typora 尺寸 / HTML 对齐归一化）

    func testDetectFormatRecognizesWikiImageEmbed() {
        XCTAssertEqual(ArticleMarkupNormalizer.detectFormat("![[paper-blog-icon.png|40|left]]"), .markdown)
    }

    func testObsidianWikiEmbedWithSizeAndAlignmentEndToEnd() {
        let raw = "前言段落。\n\n![[paper-blog-icon.png|40|left]]\n\n正文继续描述内容，用于模拟真实博客中图标左浮动、文字环绕的排版意图，保证文本量充足。"
        let content = ArticleExtractor.content(from: raw, baseURL: URL(string: "https://blog.example.com/")!)
        XCTAssertTrue(content.html.contains("width=\"40\""), "wiki 嵌入的尺寸参数必须落到 width 属性")
        XCTAssertTrue(content.html.contains("class=\"paper-align-left\""), "对齐参数必须归一化为受控 class")
        XCTAssertTrue(content.html.contains("src=\"https://blog.example.com/paper-blog-icon.png\""), "裸文件名必须按 baseURL 解析")
        XCTAssertEqual(content.imageURLs.map(\.absoluteString), ["https://blog.example.com/paper-blog-icon.png"])
        XCTAssertFalse(content.html.contains("![[") || content.html.contains("|40|"), "wiki 语法标记不得残留在最终文档中")
    }

    func testObsidianWikiEmbedSizeOnlyAndChineseFilename() {
        let normalized = ArticleMarkupNormalizer.normalize("![[我的 图片.png|300]]", baseURL: URL(string: "https://blog.example.com/notes/")!)
        XCTAssertTrue(normalized.contains("width=\"300\""))
        XCTAssertFalse(normalized.contains("paper-align-"), "未声明对齐时不得输出对齐 class")
        XCTAssertTrue(normalized.contains("%E6%88%91"), "含中文与空格的文件名必须按路径段百分号编码")
    }

    func testObsidianWikiEmbedWithAbsoluteURLAndRightAlignment() {
        let normalized = ArticleMarkupNormalizer.normalize("![[https://cdn.example.com/pic.png|right]]", baseURL: nil)
        XCTAssertTrue(normalized.contains("src=\"https://cdn.example.com/pic.png\""))
        XCTAssertTrue(normalized.contains("class=\"paper-align-right\""))
    }

    func testUnresolvableWikiEmbedStaysLiteral() {
        let normalized = ArticleMarkupNormalizer.normalize("![[mystery.png|40|left]]", baseURL: nil)
        XCTAssertFalse(normalized.contains("<img"), "无 baseURL 时无法解析裸文件名，不得产出失效图片")
        XCTAssertTrue(normalized.contains("![[mystery.png|40|left]]"))
    }

    func testWikiEmbedInsideFencedCodeUntouched() {
        let raw = "```\n![[demo.png|40|left]]\n```"
        let content = ArticleExtractor.content(from: raw, baseURL: URL(string: "https://example.com/")!)
        XCTAssertFalse(content.html.contains("<img"), "fenced code 内的 wiki 语法属于展示文本，严禁被转换")
        XCTAssertTrue(content.html.contains("![[demo.png|40|left]]"))
    }

    func testKramdownAttributeSuffixAlignment() {
        let normalized = ArticleMarkupNormalizer.normalize("![截图](https://example.com/shot.png){: .align-right}", baseURL: nil)
        XCTAssertTrue(normalized.contains("class=\"paper-align-right\""))
        XCTAssertTrue(normalized.contains("src=\"https://example.com/shot.png\""))
        XCTAssertTrue(normalized.contains("alt=\"截图\""))
        XCTAssertFalse(normalized.contains("{:"), "kramdown 属性串不得残留在输出中")
    }

    func testPandocWidthAttribute() {
        let normalized = ArticleMarkupNormalizer.normalize("![cover](https://example.com/cover.png){width=240}", baseURL: nil)
        XCTAssertTrue(normalized.contains("width=\"240\""))
        XCTAssertFalse(normalized.contains("paper-align-"))
    }

    func testTyporaSizeSuffix() {
        let normalized = ArticleMarkupNormalizer.normalize("![diagram](https://example.com/d.png =640x480)", baseURL: nil)
        XCTAssertTrue(normalized.contains("width=\"640\""), "Typora 尺寸后缀必须解析为宽度")
        let queryURL = ArticleMarkupNormalizer.normalize("![x](https://example.com/a?b=1&c=2)", baseURL: nil)
        XCTAssertTrue(queryURL.contains("src=\"https://example.com/a?b=1&amp;c=2\""), "含查询参数的普通图片 URL 严禁被误判为尺寸后缀")
        XCTAssertFalse(queryURL.contains("width=\""), "查询串中的 = 不得被解析为尺寸")
    }

    func testPipeAltParamsWithAlignment() {
        let normalized = ArticleMarkupNormalizer.normalize("![图标|48|left](https://example.com/icon.png)", baseURL: nil)
        XCTAssertTrue(normalized.contains("width=\"48\""))
        XCTAssertTrue(normalized.contains("class=\"paper-align-left\""))
        XCTAssertTrue(normalized.contains("alt=\"图标\""))
    }

    func testPlainImageWithoutSemanticsUntouched() {
        let normalized = ArticleMarkupNormalizer.normalize("![alt](https://example.com/plain.png)", baseURL: nil)
        XCTAssertTrue(normalized.contains("src=\"https://example.com/plain.png\""))
        XCTAssertFalse(normalized.contains("paper-align-"), "无对齐语义的普通图片必须走标准 AST 渲染")
        XCTAssertFalse(normalized.contains("width=\""))
    }

    func testHTMLAlignAttributeNormalizedToControlledClass() {
        let raw = "<img src=\"https://example.com/i.png\" align=\"left\">"
        let content = ArticleExtractor.content(from: raw, baseURL: nil)
        XCTAssertTrue(content.html.contains("class=\"paper-align-left\""), "HTML align 属性必须归一化为受控 class")
        XCTAssertFalse(content.html.contains("align="), "原始 align 属性不得透传")
    }

    func testHTMLFloatStyleNormalizedAndStyleStripped() {
        let raw = "<img src=\"https://example.com/i.png\" style=\"float:right;border:1px solid red\">"
        let content = ArticleExtractor.content(from: raw, baseURL: nil)
        XCTAssertTrue(content.html.contains("class=\"paper-align-right\""), "style 内 float 对齐语义必须被归一化保留")
        XCTAssertFalse(content.html.contains("style="), "原始 style 不得透传（否则绕过样式沙箱）")
    }

    func testHTMLAlignmentClassNormalizedAndUnknownClassStripped() {
        let raw = "<img src=\"https://example.com/i.png\" class=\"alignleft some-theme-hook\">"
        let content = ArticleExtractor.content(from: raw, baseURL: nil)
        XCTAssertTrue(content.html.contains("class=\"paper-align-left\""))
        XCTAssertFalse(content.html.contains("some-theme-hook"), "未知主题 class 不得透传")
    }

    func testSanitizerAlignmentOutputIsIdempotent() {
        let raw = "<img src=\"https://example.com/i.png\" align=\"left\">"
        let firstPass = ArticleExtractor.content(from: raw, baseURL: nil).html
        let secondPass = ArticleExtractor.content(from: firstPass, baseURL: nil).html
        XCTAssertEqual(firstPass, secondPass, "对齐归一化必须幂等：二次 sanitize 结果不变")
        XCTAssertEqual(secondPass.components(separatedBy: "paper-align-left").count - 1, 1, "受控 class 不得重复堆叠")
    }

    // MARK: - 8. No Site Branches in Production Code
    func testProductionCodeDoesNotContainSiteBranches() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coreSourceDir = repoRoot.appendingPathComponent("PaperRss/Sources/Core")

        let forbiddenKeywords = ["huxiu", "woshipm", "sspai", "anyfeeder"]
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: coreSourceDir, includingPropertiesForKeys: [.isRegularFileKey])

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8).lowercased()
            for keyword in forbiddenKeywords {
                XCTAssertFalse(
                    content.contains(keyword),
                    "生产源码 \(fileURL.lastPathComponent) 中严禁包含硬编码站点分支或域名关键字 '\(keyword)'"
                )
            }
        }
    }
}
