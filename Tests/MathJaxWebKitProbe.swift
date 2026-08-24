import AppKit
import Darwin
import WebKit

@MainActor
final class MathJaxWebKitProbe: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    private let configSource: String
    private let runtimeSource: String

    init(configSource: String, runtimeSource: String) {
        self.configSource = configSource
        self.runtimeSource = runtimeSource
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        let html = #"""
        <!doctype html>
        <html>
        <head>
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        </head>
        <body>
          <p>An MCE skill $s \in \mathcal{S}$ defines a context function $c_s=(\rho_s,F_s)$ and maps an input $x$ to context $c = F_s(x;\rho_s)$, where:</p>
          <ul>
            <li>$\rho_s = \{\rho_1,\dots,\rho_m\}$</li>
            <li>$F_s = \{F_1,\dots,F_k\}$</li>
          </ul>
          <p>The best context is $c_s^*$ for skill $s$.</p>
          <div>$$\text{Inner: }c_s^*=\arg\max_{c_s}J_\text{train}(c_s;s)\quad \text{Outer: }s^*=\arg\max_{s\in\mathcal{S}}J_\text{val}(c_s^*)$$</div>
        </body>
        </html>
        """#
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                _ = try await webView.evaluateJavaScript(configSource)
                FileHandle.standardError.write(Data("MathJax WebKit probe: config evaluated\n".utf8))
                _ = try await webView.evaluateJavaScript(runtimeSource)
                FileHandle.standardError.write(Data("MathJax WebKit probe: runtime evaluated\n".utf8))
                let value = try await webView.callAsyncJavaScript(
                    """
                    const startup = window.MathJax?.startup?.promise;
                    if (!startup) throw new Error("MathJax startup promise is unavailable");
                    await startup;
                    return {
                      count: document.querySelectorAll('mjx-container').length,
                      visibleText: document.body.innerText,
                      hasBrokenMarkup: Array.from(document.querySelectorAll('mjx-container')).some(node => node.innerHTML.includes('<em>'))
                    };
                    """,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
                guard let result = value as? [String: Any],
                      let count = (result["count"] as? NSNumber)?.intValue,
                      count == 9,
                      let visibleText = result["visibleText"] as? String,
                      !visibleText.contains("$"),
                      (result["hasBrokenMarkup"] as? Bool) == false else {
                    fail("unexpected MathJax completion result: \(String(describing: value))")
                }
                FileHandle.standardOutput.write(Data("MathJax WebKit probe passed: \(count) formulas rendered\n".utf8))
                exit(EXIT_SUCCESS)
            } catch {
                fail(String(reflecting: error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("MathJax WebKit probe failed: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

@main
@MainActor
struct MathJaxWebKitProbeMain {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: MathJaxWebKitProbe <config.js> <runtime.js>\n".utf8))
            exit(EXIT_FAILURE)
        }
        let configSource = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let runtimeSource = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let app = NSApplication.shared
        let probe = MathJaxWebKitProbe(configSource: configSource, runtimeSource: runtimeSource)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("MathJax WebKit probe timed out\n".utf8))
            exit(EXIT_FAILURE)
        }
        probe.start()
        app.run()
    }
}
