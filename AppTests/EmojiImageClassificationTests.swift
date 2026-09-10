import XCTest
import WebKit
@testable import PaperRssDesktop

/// 以生产同款 WKUserScript 注入方式验证小图/表情图分类脚本在真实 WebKit 中的行为：
/// 声明尺寸与 URL 特征即时生效，加载后的实测尺寸兜底生效，包装层收敛不越界。
@MainActor
final class EmojiImageClassificationTests: XCTestCase, WKNavigationDelegate {
    private var navigation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView!

    override func setUp() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(PaperReaderBridge.imageEmojiScript)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }

    private func load(_ body: String) async throws {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        \(body)
        </body></html>
        """
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // loadHTMLString 与 WKUserScript 在测试宿主中时序不稳定；
        // 显式执行生产脚本源码，保证断言针对真实 WebKit 语义。
        _ = try await run(PaperReaderBridge.imageEmojiScript.source)
        // 等待 load 事件驱动的实测尺寸分类完成
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func run(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    /// 生产注入顺序不包含 reader 样式；这里只断言分类与包装层标签。
    func testSspaiSmallImagesClassifiedThroughRealWebKit() async throws {
        try await load("""
        <span><div><img id="reaction" src="https://cdnfile.sspai.com/2025/09/22/community/b3840c84.png" alt="鼓掌" width="40"></div><span>10</span></span>
        <div><a id="avatarLink" href="https://sspai.com/u/freotpak/updates"><img id="avatar" src="https://cdnfile.sspai.com/2026/03/23/avatar/c21ccc7a.png?imageMogr2/auto-orient/quality/90/ignore-error/1" alt="张梦"></a></div>
        <img id="hero" src="https://example.com/article/hero.png" width="1200" height="800">
        <img id="tiny" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
        """)

        let result = try await run("""
        const reaction = document.getElementById('reaction');
        const avatar = document.getElementById('avatar');
        const hero = document.getElementById('hero');
        const tiny = document.getElementById('tiny');
        return {
          reaction: reaction.classList.contains('paper-emoji'),
          reactionWrapper: reaction.parentElement.classList.contains('paper-emoji-wrap'),
          reactionCountVisible: reaction.parentElement.nextElementSibling.textContent.trim() === '10',
          avatar: avatar.classList.contains('paper-emoji'),
          avatarLinkWrapped: avatar.closest('a').classList.contains('paper-emoji-wrap'),
          avatarOuterWrapped: avatar.closest('a').parentElement.classList.contains('paper-emoji-wrap'),
          hero: hero.classList.contains('paper-emoji'),
          tinyRenderedSmall: tiny.classList.contains('paper-emoji')
        };
        """) as? [String: Bool]

        XCTAssertEqual(result?["reaction"], true, "width=40 的表态图必须行内化")
        XCTAssertEqual(result?["reactionWrapper"], true, "仅含小图的包装 div 必须收敛为行内")
        XCTAssertEqual(result?["reactionCountVisible"], true, "计数不得被包装收敛吞掉")
        XCTAssertEqual(result?["avatar"], true, "头像 URL 特征必须即时命中")
        XCTAssertEqual(result?["avatarLinkWrapped"], true)
        XCTAssertEqual(result?["avatarOuterWrapped"], true)
        XCTAssertEqual(result?["hero"], false, "内容大图不得被误判")
        XCTAssertEqual(result?["tinyRenderedSmall"], true, "加载后实测小图必须兜底行内化")
    }

    func testTableCellImageKeepsTableStructureAfterClassification() async throws {
        try await load("""
        <table><tr><td id="cell"><img id="cellIcon" src="https://example.com/assets/icon.png" width="24"></td></tr></table>
        """)

        let result = try await run("""
        const icon = document.getElementById('cellIcon');
        return {
          classified: icon.classList.contains('paper-emoji'),
          cellWrapped: document.getElementById('cell').classList.contains('paper-emoji-wrap'),
          rowCount: document.querySelectorAll('tr').length
        };
        """) as? [String: Any]

        XCTAssertEqual(result?["classified"] as? Bool, true)
        XCTAssertEqual(result?["cellWrapped"] as? Bool, false, "td 不属于可收敛包装层")
        XCTAssertEqual(result?["rowCount"] as? Int, 1, "表格结构必须保持")
    }
}
