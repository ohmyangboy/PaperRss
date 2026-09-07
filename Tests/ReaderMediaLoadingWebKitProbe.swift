import AppKit
import WebKit

/// 用永不完成的本地媒体请求验证：DOM 已就绪时，空格不受 didFinish 阻塞。
@MainActor
final class ReaderMediaLoadingProbe: NSObject, WKNavigationDelegate, WKURLSchemeHandler,
  WKScriptMessageHandler
{
  var finished = false
  var ready = false
  var next = false
  var view: WKWebView!
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {}
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    if message.name == "paperRssDocumentReady" {
      ready = true
      view.evaluateJavaScript("window.paperRssReaderInteractive=true", in: nil, in: .defaultClient)
      { _ in }
    }
    if message.name == "paperRssNextArticle" { next = true }
  }
  func start() {
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(self, forURLScheme: "pending")
    let source = try! String(
      contentsOfFile: "PaperRss/Sources/App/ArticleReaderView.swift", encoding: .utf8)
    for name in ["spacebarScript", "documentReadyScript"] {
      guard let start = source.range(of: "static let \(name) = WKUserScript(") else { continue }
      let script = source[start.upperBound...].components(separatedBy: "source: \"\"\"")[1]
        .components(separatedBy: "\"\"\",")[0].replacingOccurrences(
          of: "\\(nextArticleMessageName)", with: "paperRssNextArticle"
        ).replacingOccurrences(of: "\\(focusListMessageName)", with: "paperRssFocusList")
        .replacingOccurrences(of: "\\(documentReadyMessageName)", with: "paperRssDocumentReady")
      config.userContentController.addUserScript(
        WKUserScript(
          source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
      )
    }
    config.userContentController.addUserScript(
      WKUserScript(
        source: "window.paperRssReaderInteractive=false", injectionTime: .atDocumentStart,
        forMainFrameOnly: true, in: .defaultClient))
    for name in ["paperRssDocumentReady", "paperRssNextArticle"] {
      config.userContentController.add(self, contentWorld: .defaultClient, name: name)
    }
    view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
    view.navigationDelegate = self
    let media = CommandLine.arguments.dropFirst().first == "video"
      ? "<video width='400' height='200' controls poster='pending://media/poster'></video>"
      : "<img width='400' height='200' src='pending://media/image'>"
    view.loadHTMLString(
      "<!doctype html><head><meta name='paper-rss-load-generation' content='1'></head><body>推文正文\(media)</body>",
      baseURL: nil)
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      view.evaluateJavaScript(
        "window.dispatchEvent(new KeyboardEvent('keydown',{key:' ', repeat:true})); undefined",
        in: nil, in: .defaultClient)
      try? await Task.sleep(for: .milliseconds(100))
      guard !next else { print("FAIL: 长按不应切篇"); exit(1) }
      view.evaluateJavaScript(
        "window.dispatchEvent(new KeyboardEvent('keydown',{key:' '})); undefined", in: nil,
        in: .defaultClient)
      try? await Task.sleep(for: .milliseconds(100))
      print("didFinish=\(finished), DOM ready=\(ready), 下一篇=\(next)")
      exit(!finished && next ? 0 : 1)
    }
  }
}
@main struct Main {
  @MainActor static func main() {
    let app = NSApplication.shared
    let probe = ReaderMediaLoadingProbe()
    probe.start()
    app.run()
  }
}
