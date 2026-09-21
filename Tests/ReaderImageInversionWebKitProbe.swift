import AppKit
import Darwin
import WebKit

/// 深色纸面插图反相 Tier 3 探针：用阅读器真实样式与用户脚本在 WKWebView 里
/// 复现 issue #41（深色纸面下黑字线稿不可读），再验证反相类名生效、行内小图不被
/// 排除、浅色纸面零影响。样式与脚本都从 ArticleReaderView.swift 源码提取，
/// 保证探针验证的就是交付代码。
@MainActor
final class ReaderImageInversionProbe: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    private let articleStyle: String
    private let displayImageURL: String
    private let inlineImageURL: String
    private let startedAt = Date()

    init(articleStyle: String, emojiScript: String, inversionScript: String) {
        self.articleStyle = articleStyle
        self.displayImageURL = Self.dataURL(for: Self.displaySVG)
        self.inlineImageURL = Self.dataURL(for: Self.inlineSVG)
        super.init()
        webView.navigationDelegate = self
        for script in [emojiScript, inversionScript] {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(
                    source: script,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true,
                    in: .defaultClient
                )
            )
        }
    }

    func start() {
        webView.loadHTMLString(documentHTML, baseURL: nil)
    }

    private var documentHTML: String {
        """
        <!doctype html>
        <html class="paper-scheme-dark">
        <head>
        <meta charset="utf-8">
        <style>
        \(articleStyle)
        :root {
          color-scheme: dark;
          --paper-ink: #e4ded1;
          --paper-muted: #aaa397;
          --paper-accent: #9eaf91;
          --paper-warm: #d18b73;
          --paper-rule: rgba(225, 215, 197, .18);
          --paper-wash: rgba(158, 175, 145, .10);
          --paper-code: rgba(224, 211, 185, .08);
          --paper-card: rgba(48, 45, 40, .97);
          --paper-reader-background: #1B1A17;
        }
        html, body { background: #1B1A17; }
        </style>
        </head>
        <body>
        <p>正文段落，用于复现阅读器排版。</p>
        <figure><img id="display" src="\(displayImageURL)"></figure>
        <p id="inline-line">行内公式 <img id="inline" width="30" height="22" src="\(inlineImageURL)"> 后接正文文字。</p>
        </body>
        </html>
        """
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let before = try await measureDisplayRegion()
                note("before: brightFraction=\(before.brightFraction) maxLuminance=\(before.maxLuminance)")
                guard before.brightFraction < 0.005 else {
                    fail("深色纸面下黑字线稿本应不可读，实测 brightFraction=\(before.brightFraction)")
                }

                let applied = try await webView.callAsyncJavaScript(
                    "return window.paperRssImageInversion.apply(urls);",
                    arguments: ["urls": [displayImageURL, inlineImageURL]],
                    in: nil,
                    contentWorld: .defaultClient
                )
                note("applied = \(String(describing: applied))")

                // 样式带 180ms 的 filter 过渡。探针里的 WKWebView 不在窗口内，
                // WebKit 不驱动过渡时间轴，这里显式把过渡推进到终态再量像素。
                _ = try await webView.evaluateJavaScript(
                    "(() => { const list = document.getAnimations(); list.forEach(item => { try { item.finish(); } catch (_) {} }); return list.length; })()"
                )
                let computedFilter = try await webView.evaluateJavaScript(
                    "getComputedStyle(document.getElementById('display')).filter"
                )
                note("computed filter = \(String(describing: computedFilter))")
                guard (computedFilter as? String) == "invert(1) hue-rotate(180deg)" else {
                    fail("深色纸面下反相样式未命中：\(String(describing: computedFilter))")
                }
                try await Task.sleep(for: .milliseconds(200))

                let after = try await measureDisplayRegion()
                note("after: brightFraction=\(after.brightFraction) maxLuminance=\(after.maxLuminance)")
                guard after.brightFraction >= 0.01, after.maxLuminance > 0.8 else {
                    fail("反相后线稿必须变浅：brightFraction=\(after.brightFraction) maxLuminance=\(after.maxLuminance)")
                }

                let classes = try await imageClasses()
                guard classes.inline.contains("paper-emoji") else {
                    fail("行内小图必须被 emoji 分类器标记为 paper-emoji，实测 \(classes.inline)")
                }
                guard classes.inline.contains("paper-img-invert") else {
                    fail("行内小图不得被排除在反相之外，实测 \(classes.inline)")
                }
                guard classes.display.contains("paper-img-invert") else {
                    fail("块级线稿必须被标记为 paper-img-invert，实测 \(classes.display)")
                }
                note("inline classes = \(classes.inline)")

                let lightFilters = try await removeDarkSchemeAndReadFilters()
                guard lightFilters == ["display": "none", "inline": "none"] else {
                    fail("浅色纸面必须零影响，实测 \(lightFilters)")
                }
                note("light scheme filters = \(lightFilters)")

                let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
                FileHandle.standardOutput.write(Data("ReaderImageInversionWebKitProbe passed in \(elapsed)s\n".utf8))
                exit(EXIT_SUCCESS)
            } catch {
                fail(String(reflecting: error))
            }
        }
    }

    // MARK: - 断言辅助

    private func measureDisplayRegion() async throws -> (brightFraction: Double, maxLuminance: Double) {
        let rectRaw = try await webView.evaluateJavaScript(
            "(() => { const r = document.getElementById('display').getBoundingClientRect(); return JSON.stringify({ x: r.x, y: r.y, width: r.width, height: r.height }); })()"
        )
        guard let json = rectRaw as? String,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = object["x"], let y = object["y"],
              let width = object["width"], let height = object["height"], width > 0, height > 0 else {
            fail("cannot read display image rect: \(String(describing: rectRaw))")
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: x, y: y, width: width, height: height)
        configuration.snapshotWidth = 240
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fail("snapshot has no bitmap")
        }
        return try luminanceStatistics(of: cgImage)
    }

    private func luminanceStatistics(of image: CGImage) throws -> (brightFraction: Double, maxLuminance: Double) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            fail("cannot create bitmap context for snapshot \(width)x\(height)")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            fail("snapshot context has no buffer")
        }
        var bright = 0
        var maximum = 0.0
        for index in 0..<(width * height) {
            let offset = index * 4
            let red = Double(buffer[offset]) / 255
            let green = Double(buffer[offset + 1]) / 255
            let blue = Double(buffer[offset + 2]) / 255
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            if luminance > 0.5 { bright += 1 }
            maximum = max(maximum, luminance)
        }
        return (Double(bright) / Double(width * height), maximum)
    }

    private func imageClasses() async throws -> (display: [String], inline: [String]) {
        let raw = try await webView.evaluateJavaScript(
            """
            (() => {
              const classes = id => Array.from(document.getElementById(id).classList);
              return JSON.stringify({ display: classes('display'), inline: classes('inline') });
            })()
            """
        )
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: [String]],
              let display = object["display"], let inline = object["inline"] else {
            fail("cannot read image classes: \(String(describing: raw))")
        }
        return (display, inline)
    }

    private func removeDarkSchemeAndReadFilters() async throws -> [String: String] {
        let raw = try await webView.evaluateJavaScript(
            """
            (() => {
              document.documentElement.classList.remove('paper-scheme-dark');
              const filter = id => getComputedStyle(document.getElementById(id)).filter;
              return JSON.stringify({ display: filter('display'), inline: filter('inline') });
            })()
            """
        )
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            fail("cannot read computed filters: \(String(describing: raw))")
        }
        return object
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("ReaderImageInversionWebKitProbe: \(message)\n".utf8))
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ReaderImageInversionWebKitProbe failed: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }

    // MARK: - Fixture

    /// 块级场景：透明底黑色线稿（公式图形态）。
    private static let displaySVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="480" height="200" viewBox="0 0 480 200">
      <rect x="12" y="12" width="456" height="176" fill="none" stroke="#000000" stroke-width="2"/>
      <path d="M40 160 C 140 40, 300 40, 440 120" fill="none" stroke="#000000" stroke-width="3"/>
      <text x="64" y="186" font-size="26" font-family="Helvetica" fill="#000000">input (2)</text>
    </svg>
    """

    /// 行内场景：同一线稿的窄版，声明尺寸 30×22。
    private static let inlineSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="60" height="44" viewBox="0 0 480 200">
      <rect x="12" y="12" width="456" height="176" fill="none" stroke="#000000" stroke-width="6"/>
      <path d="M40 160 C 140 40, 300 40, 440 120" fill="none" stroke="#000000" stroke-width="9"/>
    </svg>
    """

    private static func dataURL(for svg: String) -> String {
        "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    }
}

@main
@MainActor
struct ReaderImageInversionProbeMain {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: ReaderImageInversionWebKitProbe <ArticleReaderView.swift>\n".utf8))
            exit(EXIT_FAILURE)
        }
        let readerSource = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let articleStyle = try extractStyle(named: "paperArticleStyle", from: readerSource)
        let emojiScript = try extractScript(named: "imageEmojiScript", from: readerSource)
        let inversionScript = try extractScript(named: "imageInversionScript", from: readerSource)

        let app = NSApplication.shared
        let probe = ReaderImageInversionProbe(
            articleStyle: articleStyle,
            emojiScript: emojiScript,
            inversionScript: inversionScript
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("ReaderImageInversionWebKitProbe timed out\n".utf8))
            exit(EXIT_FAILURE)
        }
        probe.start()
        app.run()
    }

    /// 提取 `static let <name> = WKUserScript(source: """…""",` 里的脚本正文，
    /// 并还原 Swift 多行字面量的转义（`\\s` → `\s`）。
    private static func extractScript(named name: String, from source: String) throws -> String {
        guard let start = source.range(of: "static let \(name) = WKUserScript(") else {
            throw ProbeError.missing("static let \(name)")
        }
        let remainder = source[start.upperBound...]
        let parts = remainder.components(separatedBy: "source: \"\"\"")
        guard parts.count > 1, let literal = parts[1].components(separatedBy: "\"\"\",").first else {
            throw ProbeError.missing("\(name) 的 source 字面量")
        }
        return literal.replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func extractStyle(named name: String, from source: String) throws -> String {
        guard let start = source.range(of: "private let \(name) = \"\"\"\n"),
              let end = source.range(of: "\n\"\"\"", range: start.upperBound..<source.endIndex) else {
            throw ProbeError.missing("private let \(name)")
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private enum ProbeError: Error {
        case missing(String)
    }
}
