import XCTest
import WebKit
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
final class TranslationPresentationTests: XCTestCase, WKNavigationDelegate {
    private var navigation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView!

    private func load(_ content: String) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration)
        webView.navigationDelegate = self
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'">
        <style>:root { --paper-ink: #302D27; --paper-muted: #6F695E; }
        body { font: 17px/1.72 sans-serif; } p { margin: 1em 0; }
        .paper-rss-translation p { margin: 0; }
        \(ReaderTranslationPresentation.style)</style></head><body>
        \(content)<button id="outside">Outside</button></body></html>
        """
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        _ = try await run(ReaderTranslationPresentation.bootstrapScript)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }

    private func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    private func update(_ id: String = "p0", text: String = "译文", loading: Bool = false) async throws {
        _ = try await run(PaperReaderBridge.translationSynchronizationScript, arguments: [
            "updates": [["id": id, "text": text, "isLoading": loading]], "removals": [String]()
        ])
    }

    func testIncrementalTranslationHasStyleAndReplacementPreservesDOMAndHeight() async throws {
        try await load("<p data-paper-rss-id='p0'>A long original paragraph with <a id='link' href='https://example.com'>a link</a>. " + String(repeating: "More original text. ", count: 35) + "</p><p id='next'>Next paragraph</p>")
        _ = try await run("window.original = document.querySelector('[data-paper-rss-id]');")
        try await update(text: "短译文")
        let styled = try await run("return document.getElementById('paper-rss-translation-p0').classList.contains('paper-rss-translation');")
        XCTAssertEqual(styled as? Bool, true)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let before = try await run("window.host = document.querySelector('.paper-rss-replacement'); return document.getElementById('next').getBoundingClientRect().top;") as? Double
        let hidden = try await run("return window.original.inert && window.original.getAttribute('aria-hidden') === 'true';")
        XCTAssertEqual(hidden as? Bool, true)
        _ = try await run("window.host.focus();")
        let after = try await run("return document.getElementById('next').getBoundingClientRect().top;") as? Double
        XCTAssertEqual(try XCTUnwrap(before), try XCTUnwrap(after), accuracy: 0.5)
        let original = try await run("return document.querySelector('[data-paper-rss-id]') === window.original && !window.original.inert && !!document.getElementById('link');")
        XCTAssertEqual(original as? Bool, true)
        let opacity = try await run("""
        document.getAnimations().forEach(animation => animation.finish());
        return getComputedStyle(window.original).opacity === '1' &&
          getComputedStyle(document.getElementById('paper-rss-translation-p0')).opacity === '0';
        """) as? Bool
        XCTAssertEqual(opacity, true)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('comparison', '#123456');")
        let restored = try await run("return !document.querySelector('.paper-rss-replacement') && document.querySelector('[data-paper-rss-id]') === window.original && !window.original.hasAttribute('aria-hidden') && !window.original.inert;")
        XCTAssertEqual(restored as? Bool, true)
    }

    func testPendingFailureAndRemovalNeverHideSource() async throws {
        try await load("<p data-paper-rss-id='p0'>Original</p>")
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        try await update(loading: true)
        let pending = try await run("return !document.querySelector('.paper-rss-replacement') && getComputedStyle(document.querySelector('.paper-rss-translation')).display === 'none';")
        XCTAssertEqual(pending as? Bool, true)
        try await update()
        _ = try await run(PaperReaderBridge.translationSynchronizationScript, arguments: ["updates": [[String: Any]](), "removals": ["p0"]])
        let removed = try await run("return !document.querySelector('.paper-rss-replacement') && !document.querySelector('.paper-rss-translation') && document.querySelector('[data-paper-rss-id]').textContent === 'Original';")
        XCTAssertEqual(removed as? Bool, true)
    }

    func testCachedMarkupAndSemanticBlocksUseSamePresentation() async throws {
        let sources = [
            "<h1 data-paper-rss-id='title'>Title</h1>",
            "<blockquote data-paper-rss-id='p0'><p>Quoted words</p></blockquote>",
            "<ul data-paper-rss-id='p1'><li>First</li><li>Second</li></ul>",
            "<table data-paper-rss-id='p2'><tbody><tr><td>Cell</td></tr></tbody></table>"
        ]
        let ids = ["title", "p0", "p1", "p2"]
        let html = zip(sources, ids).map { $0.0 + ArticleExtractor.translationMarkup(for: "译文", id: $0.1) }.joined()
        try await load(html)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let result1 = try await run("return document.querySelectorAll('.paper-rss-replacement').length;") as? Int
        XCTAssertEqual(result1, 4)
        let valid = try await run("return !!document.querySelector('ul > li') && !!document.querySelector('table > tbody > tr > td') && !!document.querySelector('blockquote > p');")
        XCTAssertEqual(valid as? Bool, true)
        try await update("p1", text: "新译文")
        let result2 = try await run("return document.querySelectorAll('.paper-rss-replacement').length;") as? Int
        XCTAssertEqual(result2, 4)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('comparison', '#494640');")
        let result3 = try await run("return document.querySelectorAll('[data-paper-rss-id]').length;") as? Int
        XCTAssertEqual(result3, 4)
    }

    func testSelectionAndLinkFocusKeepOriginalVisible() async throws {
        try await load("<p data-paper-rss-id='p0'>Original <a id='link' href='https://example.com'>linked text</a></p>")
        try await update()
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640'); document.querySelector('.paper-rss-replacement').focus(); document.getElementById('link').focus();")
        let result4 = try await run("return !document.querySelector('[data-paper-rss-id]').inert;") as? Bool
        XCTAssertEqual(result4, true)
        // WebKit 聚焦外部按钮会自行清空选区；用真正的悬浮离开来验证选择保持。
        _ = try await run("""
        document.getElementById('outside').focus();
        const host = document.querySelector('.paper-rss-replacement');
        host.dispatchEvent(new PointerEvent('pointerover', {bubbles: true, pointerType: 'mouse'}));
        const range = document.createRange();
        range.selectNodeContents(document.getElementById('link'));
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
        document.dispatchEvent(new Event('selectionchange'));
        host.dispatchEvent(new PointerEvent('pointerout', {bubbles: true, pointerType: 'mouse', relatedTarget: document.body}));
        """)
        let result5 = try await run("return !document.querySelector('[data-paper-rss-id]').inert;") as? Bool
        XCTAssertEqual(result5, true)
        _ = try await run("window.getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange'));")
        let result6 = try await run("return document.querySelector('[data-paper-rss-id]').inert;") as? Bool
        XCTAssertEqual(result6, true)
    }
    func testPointerReversalAndLongArticleAvoidLayoutReadsDuringHover() async throws {
        let html = (0..<150).map { "<p data-paper-rss-id='p\($0)'>Original paragraph \($0)</p>" }.joined()
        try await load(html)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let updates = (0..<150).map { ["id": "p\($0)", "text": "译文", "isLoading": false] as [String: Any] }
        _ = try await run(PaperReaderBridge.translationSynchronizationScript, arguments: ["updates": updates, "removals": [String]()])
        let count = try await run("return document.querySelectorAll('.paper-rss-replacement').length;") as? Int
        XCTAssertEqual(count, 150)
        let result = try await run("""
        const host = document.querySelector('.paper-rss-replacement');
        const source = host.querySelector('[data-paper-rss-id]');
        const originalBounds = Element.prototype.getBoundingClientRect;
        let layoutReads = 0;
        Element.prototype.getBoundingClientRect = function() { layoutReads++; return originalBounds.call(this); };
        let reveals = true;
        const fine = matchMedia('(hover: hover) and (pointer: fine)').matches;
        for (let i = 0; i < 30; i++) {
          host.dispatchEvent(new PointerEvent('pointerover', {bubbles: true, pointerType: 'mouse'}));
          if (fine) reveals = reveals && !source.inert;
          host.dispatchEvent(new PointerEvent('pointerout', {bubbles: true, pointerType: 'mouse', relatedTarget: document.body}));
          reveals = reveals && source.inert;
        }
        Element.prototype.getBoundingClientRect = originalBounds;
        return reveals && layoutReads === 0;
        """) as? Bool
        XCTAssertEqual(result, true)
    }

    func testDefinitionAndCaptionKeepValidContainers() async throws {
        try await load("<dl><dt data-paper-rss-id='p0'>Term</dt></dl><figure><figcaption data-paper-rss-id='p1'>Caption</figcaption></figure>")
        try await update("p0")
        try await update("p1")
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let valid = try await run("return !!document.querySelector('dl > dt > .paper-rss-replacement') && !!document.querySelector('figure > figcaption > .paper-rss-replacement');") as? Bool
        XCTAssertEqual(valid, true)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('comparison', '#494640');")
        let restored = try await run("return document.querySelector('dt').textContent === 'Term' && document.querySelector('figcaption').textContent === 'Caption';") as? Bool
        XCTAssertEqual(restored, true)
    }

    func testClearingMultiParagraphSelectionRestoresIntermediateParagraphs() async throws {
        try await load((0..<3).map { "<p data-paper-rss-id='p\($0)'>Original paragraph \($0)</p>" }.joined())
        for i in 0..<3 { try await update("p\(i)") }
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let result = try await run("""
        const hosts = Array.from(document.querySelectorAll('.paper-rss-replacement'));
        const enter = host => host.dispatchEvent(new PointerEvent('pointerover', {bubbles: true, pointerType: 'mouse'}));
        const leave = host => host.dispatchEvent(new PointerEvent('pointerout', {bubbles: true, pointerType: 'mouse', relatedTarget: document.body}));
        enter(hosts[1]);
        const selection = window.getSelection();
        const range = document.createRange();
        range.setStart(hosts[0], 0);
        range.setEndAfter(hosts[2]);
        selection.addRange(range);
        document.dispatchEvent(new Event('selectionchange'));
        leave(hosts[1]);
        enter(hosts[1]); leave(hosts[1]);
        enter(hosts[2]); leave(hosts[2]);
        document.dispatchEvent(new Event('selectionchange'));
        selection.removeAllRanges();
        document.dispatchEvent(new Event('selectionchange'));
        return hosts.every(host => host.querySelector('[data-paper-rss-id]').inert);
        """) as? Bool
        XCTAssertEqual(result, true)
    }

}
