import AppKit
import Darwin
import WebKit

/// 代码高亮 Tier 3 探针：用真实文章 HTML（含 feed 自带 Pygments 标记）在
/// Reader 同款 CSP（script-src 'none'）下复现完整注入管线。
/// 胶水脚本从 ArticleReaderView.swift 源码提取，保证探针验证的就是交付代码。
@MainActor
final class CodeHighlightWebKitProbe: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    private let runtimeSource: String
    private let glueSource: String
    private let articleHTML: String

    init(runtimeSource: String, glueSource: String, articleHTML: String) {
        self.runtimeSource = runtimeSource
        self.glueSource = glueSource
        self.articleHTML = articleHTML
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https: data: blob:; style-src 'unsafe-inline'; font-src 'none'; media-src http: https: data: blob:; object-src 'none'; frame-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'">
        </head>
        <body>
        <p>intro paragraph</p>
        \(articleHTML)
        <pre><code>this block has
        no language marker at all
        and multiple lines</code></pre>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                // 1. 门控查询：真实文章的两个带标注块 + 一个未标注块
                let gateRaw = try await webView.evaluateJavaScript(
                    "document.querySelectorAll('pre code[class*=\"language-\"], pre code[class*=\"lang-\"]').length"
                )
                guard let gateCount = (gateRaw as? NSNumber)?.intValue, gateCount == 2 else {
                    fail("gate count expected 2, got \(String(describing: gateRaw))")
                }
                note("gate count = \(gateCount)")

                // 2. 运行时求值（原生求值不受 CSP 约束）
                _ = try await webView.evaluateJavaScript(runtimeSource)
                note("runtime evaluated")

                // 3. 首次着色：真实文章 2 块 + 未标注块应被跳过（v1 无语言标注不做猜测）
                let first = try await runGlue()
                guard let firstCount = first?.intValue, firstCount == 2 else {
                    fail("first pass expected 2 highlighted, got \(String(describing: first))")
                }
                note("first pass highlighted = \(firstCount)")

                let tsState = try await inspectBlock(index: 1)
                guard tsState.hasHljsSpan else {
                    fail("typescript block missing hljs spans: \(tsState.innerHTML.prefix(200))")
                }
                guard !tsState.hasPygmentsSpan else {
                    fail("typescript block still contains feed Pygments spans: \(tsState.innerHTML.prefix(200))")
                }
                note("typescript block re-highlighted: \(tsState.innerHTML.prefix(120))")

                let pyState = try await inspectBlock(index: 0)
                guard pyState.hasHljsSpan else {
                    fail("python block missing hljs spans: \(pyState.innerHTML.prefix(200))")
                }
                note("python block re-highlighted: \(pyState.innerHTML.prefix(120))")

                let unmarkedState = try await inspectUnmarked()
                guard !unmarkedState.hasHljsSpan else {
                    fail("unmarked block must stay untouched in v1: \(unmarkedState.innerHTML.prefix(200))")
                }
                note("unmarked block untouched")

                // 布局刷新事件（必须在二次幂等验证前读取，后者不会派发事件）
                let eventFired = (try await webView.callAsyncJavaScript(
                    "return window.__paperHljsProbeEvent === true;",
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                ) as? Bool) == true
                guard eventFired else {
                    fail("paperRssLayoutRefresh event was not dispatched")
                }
                note("layout refresh event dispatched")

                // 4. 幂等：再次执行必须 0
                let second = try await runGlue()
                guard let secondCount = second?.intValue, secondCount == 0 else {
                    fail("second pass expected 0 highlighted, got \(String(describing: second))")
                }
                note("second pass idempotent = \(secondCount)")

                FileHandle.standardOutput.write(Data("CodeHighlightWebKitProbe passed\n".utf8))
                exit(EXIT_SUCCESS)
            } catch {
                fail(String(reflecting: error))
            }
        }
    }

    private func runGlue() async throws -> NSNumber? {
        // 记录 paperRssLayoutRefresh 是否派发（与胶水同在 .page 世界注册与读取）
        _ = try await webView.callAsyncJavaScript(
            "window.__paperHljsProbeEvent = false; window.addEventListener('paperRssLayoutRefresh', () => { window.__paperHljsProbeEvent = true; });",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        return try await webView.callAsyncJavaScript(
            glueSource,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? NSNumber
    }

    private func inspectBlock(index: Int) async throws -> (hasHljsSpan: Bool, hasPygmentsSpan: Bool, innerHTML: String) {
        let raw = try await webView.evaluateJavaScript(
            "(() => { const el = document.querySelectorAll('pre code')[\(index)]; return JSON.stringify({ h: /hljs-/.test(el.innerHTML), p: /class=\"(kn|nn|k|kd|w|nf|mi|o|p|s2|sd|nb|bp)\"/.test(el.innerHTML), i: el.innerHTML }); })()"
        )
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let h = obj["h"] as? Bool,
              let p = obj["p"] as? Bool,
              let i = obj["i"] as? String else {
            fail("cannot inspect block \(index): \(String(describing: raw))")
        }
        return (h, p, i)
    }

    private func inspectUnmarked() async throws -> (hasHljsSpan: Bool, hasPygmentsSpan: Bool, innerHTML: String) {
        let raw = try await webView.evaluateJavaScript(
            "(() => { const blocks = Array.from(document.querySelectorAll('pre code')); const el = blocks[blocks.length - 1]; return JSON.stringify({ h: /hljs-/.test(el.innerHTML), p: false, i: el.innerHTML }); })()"
        )
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let h = obj["h"] as? Bool,
              let p = obj["p"] as? Bool,
              let i = obj["i"] as? String else {
            fail("cannot inspect unmarked block: \(String(describing: raw))")
        }
        return (h, p, i)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("CodeHighlightWebKitProbe: \(message)\n".utf8))
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("CodeHighlightWebKitProbe failed: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

@main
@MainActor
struct CodeHighlightWebKitProbeMain {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: CodeHighlightWebKitProbe <highlight.min.js> <ArticleReaderView.swift> <article.html>\n".utf8))
            exit(EXIT_FAILURE)
        }
        let runtimeSource = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let readerSource = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let articleHTML = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)

        // 从 Swift 源码提取 codeHighlightScriptBody（"""...""" 字面量），还原 Swift 转义
        guard let bodyRange = readerSource.range(of: "codeHighlightScriptBody = \"\"\"\n"),
              let endRange = readerSource.range(of: "\n    \"\"\"", range: bodyRange.upperBound..<readerSource.endIndex) else {
            FileHandle.standardError.write(Data("CodeHighlightWebKitProbe failed: cannot locate codeHighlightScriptBody in source\n".utf8))
            exit(EXIT_FAILURE)
        }
        var glue = String(readerSource[bodyRange.upperBound..<endRange.lowerBound])
        glue = glue.replacingOccurrences(of: "\\\\(", with: "\\(") // 占位，避免误替换插值
        glue = glue.replacingOccurrences(of: "\\\\", with: "\\")
        glue = glue.replacingOccurrences(of: "\\(", with: "(") // 理论上不应存在；防御
        // 去除每行公共缩进（源码中为 4 空格 + Swift 多行字面量闭合缩进已由 range 保证）
        let lines = glue.components(separatedBy: "\n")
        let indented = lines.map { line -> String in
            if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
            return line
        }
        let finalGlue = indented.joined(separator: "\n")

        let app = NSApplication.shared
        let probe = CodeHighlightWebKitProbe(runtimeSource: runtimeSource, glueSource: finalGlue, articleHTML: articleHTML)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("CodeHighlightWebKitProbe timed out\n".utf8))
            exit(EXIT_FAILURE)
        }
        probe.start()
        app.run()
    }
}
