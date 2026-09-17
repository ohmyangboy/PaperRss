import XCTest
import Foundation
@testable import PaperRssCore

final class ArticleMediaAndExtractionTests: XCTestCase {

    // MARK: - 1. Container Scorer: Semantic & Class Tokens Scoring

    func testContainerScorerPrefersHighScoringArticleContentOverSidebarAndComments() {
        let rawHTML = """
        <html>
        <body>
            <header class="site-header"><a href="/">Site Name</a></header>
            <div class="site-layout">
                <aside class="sidebar-widget">
                    <h3>热门推荐</h3>
                    <p>推荐文章 1 2 3 4 5</p>
                </aside>
                <div class="post-detail-content">
                    <h1>核心文章标题</h1>
                    <p>这是正文的第一段，详细叙述了行业背景与核心观点，确保字数充实且论证充分。</p>
                    <p>这是正文的第二段，继续阐述论点，提供了详实的分析与案例佐证。</p>
                    <p>这是正文的第三段，总结全部分析并给出明确的行动建议。</p>
                </div>
                <div class="comment-list-box">
                    <p>评论 1：写得很好！</p>
                    <p>评论 2：赞同观点。</p>
                </div>
            </div>
            <footer class="site-footer"><p>版权所有 © 2026</p></footer>
        </body>
        </html>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post-1"))

        XCTAssertTrue(content.text.contains("这是正文的第一段"), "提取结果必须包含正文内容")
        XCTAssertTrue(content.text.contains("这是正文的第三段"), "提取结果必须包含全部段落")
        XCTAssertFalse(content.text.contains("热门推荐"), "提取结果严禁包含侧边栏推荐")
        XCTAssertFalse(content.text.contains("评论 1：写得很好"), "提取结果严禁包含评论区")
    }

    // MARK: - 2. Nested Container Extraction

    func testNestedContainerExtractsDeepestAccurateContent() {
        let rawHTML = """
        <div class="main-wrapper">
            <div class="page-body">
                <article class="article-body">
                    <div class="article-rich-text">
                        <p>嵌套最深的核心正文段落 1，阐述核心逻辑与数据。</p>
                        <p>嵌套最深的核心正文段落 2，进一步展开论证。</p>
                        <p>嵌套最深的核心正文段落 3，得出最终结论。</p>
                    </div>
                </article>
            </div>
        </div>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/nested"))
        XCTAssertTrue(content.text.contains("嵌套最深的核心正文段落 1"))
        XCTAssertTrue(content.text.contains("嵌套最深的核心正文段落 3"))
        XCTAssertEqual(content.html.components(separatedBy: "<p").count - 1, 3, "必须保留恰好 3 个段落")
    }

    // MARK: - 3. Lazy Load Images: data-src, data-original, data-lazy-src, data-actualsrc

    func testLazyLoadedImageAttributesAreExtractedAndPromotedToSrc() {
        let rawHTML = """
        <article class="article-content">
            <p>包含多种懒加载格式的图片正文。</p>
            <img class="lazy" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-src="https://example.com/real-data-src.jpg" alt="Data Src Image">
            <img class="lazy-load" src="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%3E%3C/svg%3E" data-original="https://example.com/real-original.png" alt="Original Image">
            <img src="https://example.com/placeholder-1x1.png" data-lazy-src="https://example.com/real-lazy.jpg" alt="Lazy Src Image">
            <img data-actualsrc="https://example.com/real-actual.webp" alt="Actual Src Image">
        </article>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))
        let imageURLs = content.imageURLs.map(\.absoluteString)

        XCTAssertTrue(imageURLs.contains("https://example.com/real-data-src.jpg"))
        XCTAssertTrue(imageURLs.contains("https://example.com/real-original.png"))
        XCTAssertTrue(imageURLs.contains("https://example.com/real-lazy.jpg"))
        XCTAssertTrue(imageURLs.contains("https://example.com/real-actual.webp"))
        XCTAssertFalse(imageURLs.contains("https://example.com/placeholder-1x1.png"), "占位图必须被过滤")

        XCTAssertTrue(content.html.contains("src=\"https://example.com/real-data-src.jpg\""))
        XCTAssertTrue(content.html.contains("src=\"https://example.com/real-original.png\""))
        XCTAssertTrue(content.html.contains("src=\"https://example.com/real-lazy.jpg\""))
    }

    // MARK: - 4. Srcset Parsing: Pick Best Candidate

    func testSrcsetParsingSelectsHighResolutionImage() {
        let rawHTML = """
        <div class="entry-content">
            <p>测试 srcset 多分辨率候选。</p>
            <img src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
                 srcset="https://example.com/image-320w.jpg 320w, https://example.com/image-768w.jpg 768w, https://example.com/image-1200w.jpg 1200w"
                 alt="Responsive Image">
        </div>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/responsive"))
        let imageURLs = content.imageURLs.map(\.absoluteString)

        XCTAssertTrue(imageURLs.contains("https://example.com/image-1200w.jpg"), "应当从 srcset 中选取高分辨率候选")
        XCTAssertTrue(content.html.contains("https://example.com/image-1200w.jpg"))
    }

    /// Substack/Cloudinary 型 CDN 的路径自带逗号（`$s_!id!,w_424,...`），
    /// 按逗号切分 srcset 会把完整地址截断成前缀（线上返回 404，渲染成破图）。
    /// 解析必须按 HTML 规范以空白分词，逗号只作候选分隔符。
    func testSrcsetKeepsCommasInsideCDNURLs() {
        let small = "https://substackcdn.com/image/fetch/$s_!hNAj!,w_424,c_limit,f_webp,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fcover_2560x1440.png"
        let large = "https://substackcdn.com/image/fetch/$s_!hNAj!,w_1456,c_limit,f_webp,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fcover_2560x1440.png"
        let rawHTML = """
        <div class="captioned-image-container">
            <figure>
                <picture>
                    <source type="image/webp" srcset="\(small) 424w, \(large) 1456w">
                    <img src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
                         srcset="\(small) 424w, \(large) 1456w"
                         sizes="100vw" alt="">
                </picture>
            </figure>
        </div>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://www.latent.space/p/post"))
        let imageURLs = content.imageURLs.map(\.absoluteString)

        XCTAssertEqual(imageURLs, [large], "带逗号的 CDN URL 必须原样保留，且按最高分辨率取候选")
        XCTAssertTrue(content.html.contains("w_1456"))
    }

    func testImageFallsBackToSrcWhenAllSrcsetCandidatesArePlaceholders() {
        let rawHTML = """
        <article class="article-content">
            <p>回退用例：srcset 全是占位图时应使用 src。</p>
            <img src="https://example.com/valid.jpg"
                 srcset="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw== 1x, https://example.com/1x1.png 2x"
                 alt="Fallback">
        </article>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))

        XCTAssertEqual(content.imageURLs.map(\.absoluteString), ["https://example.com/valid.jpg"])
    }

    /// Substack 等「全文 Feed」的正文是顶层平铺的段落流，没有包裹全文的容器；
    /// 评分器曾把带 figcaption 的图片 div 当正文容器（正文只剩一句话），
    /// 进而触发网页降级并把页面 chrome 混进正文。碎片候选必须退回整篇清洗。
    func testFlatFeedBodyWithCaptionedFigureKeepsAllParagraphs() {
        let paragraphBody = String(repeating: "这是一段足够长的正文内容，用于验证碎片护栏不会截断文章主体。", count: 8)
        let caption = "Grok 4 Fast is the least likely to betray you in Diplomacy, according to these September 2026 rankings."
        let imageURL = "https://substackcdn.com/image/fetch/$s_!Zv_Y!,w_1456,c_limit,f_webp,q_auto:good/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fdiplomacy_2202x1194.png"
        let paragraphs = (1...6)
            .map { "<p>正文第\($0)段：\(paragraphBody)</p>" }
            .joined()
        let rawHTML = """
        <div class="captioned-image-container">
            <figure>
                <a href="/img"><img src="\(imageURL)" alt=""></a>
                <figcaption>\(caption)</figcaption>
            </figure>
        </div>
        \(paragraphs)
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://www.latent.space/p/post"))

        XCTAssertTrue(content.text.contains("正文第1段"))
        XCTAssertTrue(content.text.contains("正文第6段"), "碎片护栏命中时必须保留整篇正文")
        XCTAssertTrue(content.text.contains("Grok 4 Fast"), "图注仍应保留")
        XCTAssertGreaterThanOrEqual(content.html.components(separatedBy: "<p").count - 1, 6)
    }

    /// 单段长文容器（>1500 字）即便页面还有其它文本，也不属于媒体碎片，不得回退整篇。
    func testSingleLongParagraphContainerIsNotTreatedAsFragment() {
        let longParagraph = String(repeating: "正文内容重复用于拉长篇幅。", count: 140)
        let noise = (1...12).map { "<p>站点噪声段落 \($0)，与正文无关的推荐文本。</p>" }.joined()
        let rawHTML = """
        <html><body>
            <div class="noise-block">\(noise)</div>
            <article class="article-content"><p>\(longParagraph)</p></article>
        </body></html>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))

        XCTAssertTrue(content.text.contains("正文内容重复用于拉长篇幅"))
        XCTAssertFalse(content.text.contains("站点噪声段落"), "长文容器不得被碎片护栏误伤")
    }

    /// 网页兜底路径的通用 chrome 裁剪：站点导航、作者行、点赞/分享工具栏都带
    /// 交互元素（链接/按钮），必须整体剔除；正文与图注保留。
    func testInteractiveChromeBlocksAreStrippedFromWebFallback() {
        let rawHTML = """
        <html><body>
            <div class="main-menu">
                <a href="/"><img src="https://example.com/logo.png" alt="Logo"></a>
                <button type="button">Subscribe</button>
                <a href="/sign-in">Sign in</a>
            </div>
            <div class="single-post">
                <div class="post-header">
                    <h1>文章标题</h1>
                    <a href="https://example.com/@author">作者名</a>
                    <div>Sep 05, 2026</div>
                    <div>87</div>
                    <div>Share</div>
                </div>
                <div class="post-body">
                    <p>这是正文的第一段，包含足够的内容用于验证页面 chrome 会被剔除而正文被保留。</p>
                    <p>这是正文的第二段，继续提供文章主体内容与论证。</p>
                    <p>这是正文的第三段，收束全文观点并给出结论。</p>
                </div>
            </div>
        </body></html>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))

        XCTAssertTrue(content.text.contains("这是正文的第一段"))
        XCTAssertTrue(content.text.contains("这是正文的第三段"))
        XCTAssertFalse(content.text.contains("Share"), "分享工具栏属于页面 chrome，必须剔除")
        XCTAssertFalse(content.text.contains("Sep 05, 2026"), "作者/日期行不得进入正文")
        XCTAssertFalse(content.text.contains("87"), "点赞计数不得进入正文")
        XCTAssertFalse(
            content.imageURLs.map(\.absoluteString).contains("https://example.com/logo.png"),
            "站点 logo 不得进入正文"
        )
    }

    /// 只含标题与文本的正文分节不得被 chrome 裁剪误伤。
    func testNonInteractiveSectionHeaderIsKept() {
        let rawHTML = """
        <article class="article-content">
            <div class="section-header"><h2>章节标题一</h2></div>
            <p>章节正文段落，说明该分节的具体内容与结论，长度足够形成正文容器。</p>
            <p>章节正文第二段，继续展开论述并补充证据。</p>
            <p>章节正文第三段，收尾总结。</p>
        </article>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))

        XCTAssertTrue(content.text.contains("章节标题一"), "不含交互元素的正文小标题不得被 chrome 裁剪误伤")
    }

    /// class 含 `ad` 子串（如 additional）时不得按广告误删：匹配必须按词元而不是子串。
    func testContentBlockWithAdSubstringIsKept() {
        let rawHTML = """
        <article class="article-content">
            <p>正文引言段落，用于建立文章容器与上下文。</p>
            <div class="additional-material">
                <p>延伸阅读：<a href="https://example.com/ref">参考资料</a>，包含少量辅助说明。</p>
            </div>
            <p>正文结论段落，总结全文。</p>
        </article>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))

        XCTAssertTrue(content.text.contains("参考资料"), "additional 含 ad 子串但并非广告词元")
    }

    // MARK: - 5. Figure and Figcaption Preservation

    func testFigureAndFigcaptionAreFullyPreserved() {
        let rawHTML = """
        <article class="post-content">
            <p>段落前述内容。</p>
            <figure class="image-container">
                <img src="https://example.com/chart.png" alt="2026年趋势图">
                <figcaption>图 1：2026 年度行业演进趋势与核心洞察</figcaption>
            </figure>
            <p>段落后续内容。</p>
        </article>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/figure"))

        XCTAssertTrue(content.html.contains("<figure"))
        XCTAssertTrue(content.html.contains("<figcaption>图 1：2026 年度行业演进趋势与核心洞察</figcaption>"))
        XCTAssertTrue(content.text.contains("图 1：2026 年度行业演进趋势与核心洞察"))
    }

    // MARK: - 6. Image Loading Strategy: First 2 Eager, Rest Lazy, Async Decoding

    func testImageLoadingPolicyFirstTwoEagerRestLazy() {
        let rawHTML = """
        <div class="article-body">
            <p>段落</p>
            <img src="https://example.com/img1.jpg">
            <img src="https://example.com/img2.jpg">
            <img src="https://example.com/img3.jpg">
            <img src="https://example.com/img4.jpg">
        </div>
        """

        let output = ArticleExtractor.sanitizedHTML(rawHTML)

        XCTAssertEqual(output.components(separatedBy: "loading=\"eager\"").count - 1, 2, "前 2 张图片必须标记为 loading=eager")
        XCTAssertEqual(output.components(separatedBy: "loading=\"lazy\"").count - 1, 2, "第 3 张及以后的图片必须标记为 loading=lazy")
        XCTAssertEqual(output.components(separatedBy: "decoding=\"async\"").count - 1, 4, "全部图片必须包含 decoding=async")
    }

    // MARK: - 7. Link Density Filter: High Link Density Container Rejected

    func testHighLinkDensityContainerRejected() {
        let rawHTML = """
        <div>
            <div class="nav-links">
                <a href="/1">链接 1</a> | <a href="/2">链接 2</a> | <a href="/3">链接 3</a> |
                <a href="/4">链接 4</a> | <a href="/5">链接 5</a> | <a href="/6">链接 6</a>
            </div>
            <div class="story-body">
                <p>真实正文内容，具有长篇幅且不包含密集跳转外链。</p>
                <p>第二段深度分析，保证正文质量与段落完整性。</p>
            </div>
        </div>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/links"))

        XCTAssertTrue(content.text.contains("真实正文内容"))
        XCTAssertFalse(content.text.contains("链接 1 | 链接 2"), "高链接密度导航块应被过滤")
    }

    // MARK: - 8. Unknown Host Consistent Extraction

    func testUnknownHostExtractionConsistency() {
        let rawTemplate = """
        <div class="site-wrapper">
            <div class="article-main">
                <h1>统一模板测试</h1>
                <p>第一段：跨域名提取一致性验证，内容详实且格式规范。</p>
                <img src="https://%@/banner.jpg" data-original="https://%@/banner-hd.jpg" alt="Banner">
                <p>第二段：继续提供分析与结论。</p>
            </div>
        </div>
        """

        let htmlA = String(format: rawTemplate, "alpha.org", "alpha.org")
        let htmlB = String(format: rawTemplate, "beta.org", "beta.org")

        let contentA = ArticleExtractor.content(from: htmlA, baseURL: URL(string: "https://alpha.org/post"))
        let contentB = ArticleExtractor.content(from: htmlB, baseURL: URL(string: "https://beta.org/post"))

        XCTAssertEqual(contentA.imageURLs.count, contentB.imageURLs.count)
        XCTAssertEqual(contentA.imageURLs.first?.path, contentB.imageURLs.first?.path)
    }

    // MARK: - 9. Unified Markdown and HTML Image Pipeline

    func testMarkdownAndHTMLImagesNormalizedInSamePipeline() {
        let mixedContent = """
        # 混合标题
        
        <p>HTML 段落与图片：</p>
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" data-src="https://example.com/html-lazy.jpg" alt="HTML Lazy">
        
        Markdown 图片如下：
        ![Markdown Alt](https://example.com/markdown-img.png "Markdown Title")
        """

        let content = ArticleExtractor.content(from: mixedContent, baseURL: URL(string: "https://example.com/mixed"))
        let imageURLs = content.imageURLs.map(\.absoluteString)

        XCTAssertTrue(imageURLs.contains("https://example.com/html-lazy.jpg"))
        XCTAssertTrue(imageURLs.contains("https://example.com/markdown-img.png"))
        XCTAssertEqual(content.imageURLs.count, 2)
    }

    // MARK: - 10. Media Sibling Around Article Body

    func testArticleContainerRetainsAdjacentMediaSibling() {
        let rawHTML = """
        <section class="section">
            <div class="card">
                <div class="card-image">
                    <img src="https://example.com/cover.jpg" alt="Cover">
                </div>
                <article class="card-content article">
                    <p>正文第一段，包含足够的内容用于识别真实文章容器。</p>
                    <p>正文第二段，继续说明文章观点并保持媒体顺序。</p>
                    <p><img src="https://example.com/body-1.jpg" alt="Body one"></p>
                    <p><img src="https://example.com/body-2.jpg" alt="Body two"></p>
                </article>
            </div>
        </section>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))
        let imageURLs = content.imageURLs.map(\.absoluteString)

        XCTAssertEqual(imageURLs, [
            "https://example.com/cover.jpg",
            "https://example.com/body-1.jpg",
            "https://example.com/body-2.jpg"
        ])
        XCTAssertTrue(content.html.contains("src=\"https://example.com/cover.jpg\""))
    }

    func testArticleContainerDoesNotExpandIntoNoisyParentMedia() {
        let rawHTML = """
        <div class="page-shell">
            <div class="recommendations"><img src="https://example.com/sidebar.jpg" alt="Sidebar"></div>
            <article class="article-content">
                <p>真实正文第一段，包含足够文字用于识别文章容器。</p>
                <p>真实正文第二段，继续提供文章内容和结论。</p>
                <p><img src="https://example.com/body.jpg" alt="Body"></p>
            </article>
        </div>
        """

        let content = ArticleExtractor.content(from: rawHTML, baseURL: URL(string: "https://example.com/post"))

        XCTAssertEqual(content.imageURLs.map(\.absoluteString), ["https://example.com/body.jpg"])
        XCTAssertFalse(content.html.contains("sidebar.jpg"), "媒体扩展不得把侧栏图片带入正文")
    }

    // MARK: - 11. Safe Heading Anchors

    func testSanitizerPreservesSafeHeadingIDWithoutSourceStyling() {
        let html = "<h2 id=\"toc-1\" class=\"jltoc--item\">01 显存划的线</h2>"

        let sanitized = ArticleExtractor.sanitizedHTML(html)

        XCTAssertTrue(sanitized.contains("<h2 id=\"toc-1\">") )
        XCTAssertFalse(sanitized.contains("jltoc--item"), "来源站点 class 不应进入统一 Reader 样式")
    }

    func testSanitizerPreservesSameDocumentFragmentLinks() {
        let html = "<p><a href=\"#toc-1\">跳到章节</a></p>"

        let sanitized = ArticleExtractor.sanitizedHTML(html, baseURL: URL(string: "https://example.com/post"))

        XCTAssertTrue(sanitized.contains("href=\"#toc-1\""))
        XCTAssertFalse(sanitized.contains("https://example.com/post#toc-1"))
    }

    // MARK: - 12. Twitter Profile Avatar Stripping

    /// x.com 网页抽取会把作者头像壳作为正文首块带进阅读器（大图顶在推文前）。
    /// sanitizer 必须整标签剔除 pbs.twimg.com/profile_images/ 头像，
    /// 同时保留推文媒体（/media/、/amplify_video_thumb/）。
    func testSanitizerStripsTwitterProfileAvatarButKeepsTweetMedia() {
        let html = """
        <div><div><div><a href="https://x.com/dotey"><div><img src="https://pbs.twimg.com/profile_images/561086911561736192/6_g58vEs_400x400.jpeg" alt="user avatar" loading="eager" decoding="async"></div></a></div></div>
        <div><span>推文正文内容。</span></div>
        <div><img src="https://pbs.twimg.com/amplify_video_thumb/2093539587096211456/img/zgvZdrM6wTPwPEho?format=webp&amp;name=medium" alt=""></div>
        <div><img src="https://pbs.twimg.com/media/GAbcdef.jpeg?format=jpg&amp;name=medium" alt="推文配图"></div>
        """

        let sanitized = ArticleExtractor.sanitizedHTML(html, baseURL: URL(string: "https://x.com/dotey/status/1"))

        XCTAssertFalse(sanitized.contains("profile_images"), "作者头像必须整标签剔除")
        XCTAssertFalse(sanitized.contains("user avatar"), "头像 alt 不得残留")
        XCTAssertTrue(sanitized.contains("amplify_video_thumb"), "推文视频封面必须保留")
        XCTAssertTrue(sanitized.contains("pbs.twimg.com/media"), "推文配图必须保留")
        XCTAssertTrue(sanitized.contains("推文正文内容"), "推文正文必须保留")
    }
}
