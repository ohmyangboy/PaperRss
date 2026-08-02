import Foundation

public enum ArticleExtractor {
    public struct Content: Sendable {
        public var text: String
        public var html: String
        public var imageURLs: [URL]

        public init(text: String, html: String, imageURLs: [URL]) {
            self.text = text
            self.html = html
            self.imageURLs = imageURLs
        }
    }

    public static func needsExtraction(_ entry: Entry) -> Bool {
        entry.sourceText.count < 500 && entry.url != nil
    }

    public static func extract(from url: URL) async throws -> ArticleCache {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("PaperRss/0.1 (+personal RSS reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let html = String(data: data.prefix(4_000_000), encoding: .utf8) ?? String(data: data.prefix(4_000_000), encoding: .isoLatin1) else { throw ExtractionError.unsupportedEncoding }
        let sourceURL = response.url ?? url
        let content = content(from: html, baseURL: sourceURL)
        guard content.text.count >= 120 else { throw ExtractionError.noReadableContent }
        return ArticleCache(entryID: "", text: content.text, html: content.html, imageURLs: content.imageURLs, sourceURL: sourceURL)
    }

    public static func mainText(from html: String) -> String {
        content(from: html, baseURL: nil).text
    }

    public static func imageURLs(from html: String, baseURL: URL?) -> [URL] {
        let pattern = "(?is)<img\\b[^>]*?\\b(?:src|data-src|data-original|data-lazy-src)\\s*=\\s*(?:[\\\"']([^\\\"']+)[\\\"']|([^\\s>]+))[^>]*>"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<URL>()
        var result: [URL] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match else { return }
            let captureRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let swiftRange = Range(captureRange, in: html) else { return }
            let source = String(html[swiftRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: source, relativeTo: baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  seen.insert(url).inserted else { return }
            result.append(url)
        }
        return result
    }

    public static func content(from html: String, baseURL: URL?) -> Content {
        let cleaned = html
            .replacingOccurrences(of: "(?is)<(script|style|noscript|svg|canvas|iframe|form|nav|footer|aside)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)
        let candidates = ["article", "main", "body"]
        for tag in candidates {
            let pattern = "(?is)<\(tag)[^>]*>(.*?)</\(tag)>"
            if let range = cleaned.range(of: pattern, options: .regularExpression) {
                let fragment = String(cleaned[range])
                let safeHTML = sanitizedHTML(fragment, baseURL: baseURL)
                let text = safeHTML.plainText
                if text.count >= 120 {
                    return Content(text: text, html: safeHTML, imageURLs: imageURLs(from: safeHTML, baseURL: baseURL))
                }
            }
        }
        let safeHTML = sanitizedHTML(cleaned, baseURL: baseURL)
        return Content(text: safeHTML.plainText, html: safeHTML, imageURLs: imageURLs(from: safeHTML, baseURL: baseURL))
    }

    /// Retains only the small, document-oriented HTML subset used by the reader.
    /// Attributes are rebuilt rather than edited in place so malformed markup cannot
    /// smuggle event handlers, styles, or executable URL schemes into WebKit.
    public static func sanitizedHTML(_ html: String, baseURL: URL? = nil) -> String {
        let withoutExecutableBlocks = html
            .replacingOccurrences(of: "(?is)<(script|style|noscript|svg|canvas|iframe|form|object|embed|meta|link|base|template|nav|footer|aside)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<(script|style|noscript|svg|canvas|iframe|form|object|embed|meta|link|base|template|nav|footer|aside)\\b[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<!--.*?-->", with: "", options: .regularExpression)

        let allowedTags: Set<String> = [
            "p", "br", "hr", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6",
            "strong", "b", "em", "i", "u", "s", "del", "mark", "small", "sub", "sup",
            "blockquote", "pre", "code", "kbd", "ul", "ol", "li", "dl", "dt", "dd",
            "figure", "figcaption", "table", "thead", "tbody", "tfoot", "tr", "th", "td",
            "img", "a", "video", "source", "audio", "picture"
        ]
        let voidTags: Set<String> = ["br", "hr", "img", "source"]
        let tagPattern = "(?is)</?([a-z][a-z0-9]*)\\b([^>]*)>"
        guard let expression = try? NSRegularExpression(pattern: tagPattern) else { return "" }
        let range = NSRange(withoutExecutableBlocks.startIndex..., in: withoutExecutableBlocks)
        var result = ""
        var cursor = withoutExecutableBlocks.startIndex
        var imageIndex = 0

        expression.enumerateMatches(in: withoutExecutableBlocks, range: range) { match, _, _ in
            guard let match, let tagRange = Range(match.range, in: withoutExecutableBlocks),
                  let nameRange = Range(match.range(at: 1), in: withoutExecutableBlocks),
                  let attributesRange = Range(match.range(at: 2), in: withoutExecutableBlocks) else { return }
            result += withoutExecutableBlocks[cursor..<tagRange.lowerBound]
            cursor = tagRange.upperBound

            let name = withoutExecutableBlocks[nameRange].lowercased()
            guard allowedTags.contains(name) else { return }
            let sourceTag = withoutExecutableBlocks[tagRange]
            let isClosingTag = sourceTag.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            if isClosingTag {
                if !voidTags.contains(name) { result += "</\(name)>" }
            } else {
                let eagerImage = name == "img" && imageIndex < 2
                if name == "img" { imageIndex += 1 }
                result += "<\(name)\(sanitizedAttributes(String(withoutExecutableBlocks[attributesRange]), for: name, baseURL: baseURL, eagerImage: eagerImage))>"
            }
        }
        result += withoutExecutableBlocks[cursor...]
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return wrappingTopLevelTextRuns(trimmedResult)
    }

    /// Wraps bare text at the top level of a sanitized fragment in `<p>`
    /// elements. RSSHub feeds (notably Twitter/X tweets) frequently place the
    /// status text directly in the feed body without any block element, so the
    /// reader's block observer would never see it and bilingual translation
    /// would silently skip the tweet. Inline-only runs (a lone `<img>`, `<br>`
    /// or whitespace) stay untouched, and text already inside a block element
    /// is never duplicated.
    private static func wrappingTopLevelTextRuns(_ html: String) -> String {
        let blockTags: Set<String> = [
            "p", "div", "li", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
            "figcaption", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "ul", "ol", "hr"
        ]
        let voidTags: Set<String> = ["br", "hr", "img", "source"]
        let tagPattern = "(?is)</?([a-z][a-z0-9]*)\\b[^>]*>"
        guard let expression = try? NSRegularExpression(pattern: tagPattern) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        var output = ""
        var stack: [String] = []
        var loose = ""
        var cursor = html.startIndex

        func flush() {
            let trimmed = loose.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.plainText.isEmpty {
                output += loose
            } else {
                output += "<p>\(trimmed)</p>"
            }
            loose = ""
        }

        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let tagRange = Range(match.range, in: html),
                  let nameRange = Range(match.range(at: 1), in: html) else { return }
            let segment = html[cursor..<tagRange.lowerBound]
            if stack.isEmpty { loose += segment } else { output += segment }
            cursor = tagRange.upperBound

            let tag = html[tagRange]
            let name = html[nameRange].lowercased()
            let isClosing = tag.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            if isClosing {
                if stack.isEmpty && !voidTags.contains(name) {
                    // An inline closing tag at top level belongs to the loose
                    // run, so wrapping later keeps the tags balanced.
                    loose += tag
                } else {
                    output += tag
                }
                if !stack.isEmpty, stack.last == name {
                    stack.removeLast()
                    flush()
                }
            } else if blockTags.contains(name) {
                flush()
                output += tag
                if !voidTags.contains(name) { stack.append(name) }
            } else if stack.isEmpty {
                loose += tag
            } else {
                output += tag
            }
        }
        if stack.isEmpty {
            loose += html[cursor...]
        } else {
            output += html[cursor...]
        }
        flush()
        return output
    }

    /// Returns the source blocks WebKit can observe while the reader scrolls.
    /// The same expression is used by the renderer below, keeping paragraph IDs
    /// stable between translation requests and document reloads.
    public static func readerParagraphs(in html: String) -> [ReaderParagraph] {
        guard let expression = readerBlockExpression else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var paragraphs: [ReaderParagraph] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let blockRange = Range(match.range, in: html) else { return }
            let original = String(html[blockRange]).plainText
            guard !original.isEmpty else { return }
            paragraphs.append(ReaderParagraph(id: "p\(paragraphs.count)", original: original))
        }
        return paragraphs
    }

    /// Annotates every source paragraph for viewport observation and adds any
    /// completed translation directly beneath its matching source block.
    /// Pending placeholders are local UI only; untranslated off-screen content
    /// remains untouched and is never sent to the model.
    public static func insertingInlineTranslations(
        into html: String,
        segments: [BilingualSegment],
        pendingIDs: Set<String> = []
    ) -> String {
        guard let expression = readerBlockExpression else { return html }

        let range = NSRange(html.startIndex..., in: html)
        var rendered = ""
        var cursor = html.startIndex
        var paragraphIndex = 0
        let segmentsByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let blockRange = Range(match.range, in: html) else { return }
            rendered += html[cursor..<blockRange.lowerBound]
            let block = String(html[blockRange])
            cursor = blockRange.upperBound

            let original = block.plainText
            guard !original.isEmpty else {
                rendered += block
                return
            }

            let id = "p\(paragraphIndex)"
            paragraphIndex += 1
            rendered += annotatedReaderBlock(block, id: id)

            if let segment = segmentsByID[id],
               original.isSameReaderParagraph(as: segment.original) {
                rendered += translationMarkup(for: segment.translation, id: id)
            } else if pendingIDs.contains(id) {
                rendered += pendingTranslationMarkup(for: id)
            }
        }
        rendered += html[cursor...]
        return rendered
    }

    private static var readerBlockExpression: NSRegularExpression? {
        try? NSRegularExpression(pattern: "(?is)<(p|div|li|blockquote|pre|h[1-6]|figcaption|dt|dd)\\b[^>]*>.*?</\\1>")
    }

    private static func annotatedReaderBlock(_ block: String, id: String) -> String {
        guard let closingBracket = block.firstIndex(of: ">") else { return block }
        var output = block
        output.insert(contentsOf: " data-paper-rss-id=\"\(id)\"", at: closingBracket)
        return output
    }

    private static func translationMarkup(for translation: String, id: String) -> String {
        """
        <aside id="paper-rss-translation-\(id)" class="paper-rss-translation" data-paper-rss-translation-for="\(id)" aria-label="中文翻译">
        <p><span class="paper-rss-translation-label" aria-label="译文">
          <span class="paper-rss-language-chip" aria-hidden="true">A</span>
          <span class="paper-rss-language-chip" aria-hidden="true">文</span>
        </span><span class="paper-rss-translation-text">\(htmlTextEscaped(translation).replacingOccurrences(of: "\\n", with: "<br>"))</span></p>
        </aside>
        """
    }

    private static func pendingTranslationMarkup(for id: String) -> String {
        """
        <aside id="paper-rss-translation-\(id)" class="paper-rss-translation is-loading" data-paper-rss-translation-for="\(id)" aria-label="正在生成中文翻译" aria-live="polite">
        <p><span class="paper-rss-translation-label" aria-label="译文">
          <span class="paper-rss-language-chip" aria-hidden="true">A</span>
          <span class="paper-rss-language-chip" aria-hidden="true">文</span>
        </span><span class="paper-rss-translation-text">正在翻译…</span></p>
        </aside>
        """
    }

    private static func htmlTextEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func sanitizedAttributes(_ source: String, for tag: String, baseURL: URL?, eagerImage: Bool = false) -> String {
        let allowed: Set<String>
        switch tag {
        case "a": allowed = ["href", "title"]
        case "img": allowed = ["src", "alt", "title", "width", "height"]
        case "video": allowed = ["src", "poster", "controls", "autoplay", "loop", "muted", "playsinline", "webkit-playsinline", "allowfullscreen", "preload", "width", "height"]
        case "source": allowed = ["src", "type"]
        case "audio": allowed = ["src", "controls", "autoplay", "loop", "muted", "preload"]
        case "th", "td": allowed = ["colspan", "rowspan"]
        default: allowed = []
        }
        guard !allowed.isEmpty,
              let expression = try? NSRegularExpression(pattern: "(?is)([a-z][a-z0-9:-]*)(?:\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+)))?") else { return "" }
        let range = NSRange(source.startIndex..., in: source)
        var attributes: [String] = []
        var seenNames = Set<String>()
        expression.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: source) else { return }
            let name = source[nameRange].lowercased()
            guard allowed.contains(name), seenNames.insert(name).inserted else { return }
            let valueRange = [2, 3, 4].lazy.compactMap { index -> Range<String.Index>? in
                let candidate = match.range(at: index)
                return candidate.location == NSNotFound ? nil : Range(candidate, in: source)
            }.first

            if let valueRange {
                var value = String(source[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "href" || name == "src" || name == "poster" {
                    guard let resolvedURL = safeRemoteURL(value, baseURL: baseURL) else { return }
                    value = resolvedURL.absoluteString
                } else if name == "width" || name == "height" || name == "colspan" || name == "rowspan" {
                    guard let number = Int(value), number > 0, number <= 10_000 else { return }
                    value = String(number)
                }
                attributes.append(" \(name)=\"\(htmlAttributeEscaped(value))\"")
            } else {
                // Boolean HTML attributes like `controls`, `playsinline`, `allowfullscreen`
                attributes.append(" \(name)")
            }
        }
        if tag == "img" {
            attributes.append(" loading=\"\(eagerImage ? "eager" : "lazy")\"")
            attributes.append(" decoding=\"async\"")
        } else if tag == "video" {
            // Guarantee controls and fullscreen behavior for HTML5 videos in WKWebView
            if !seenNames.contains("controls") { attributes.append(" controls") }
            if !seenNames.contains("playsinline") { attributes.append(" playsinline") }
            if !seenNames.contains("webkit-playsinline") { attributes.append(" webkit-playsinline") }
            if !seenNames.contains("allowfullscreen") { attributes.append(" allowfullscreen") }
        }
        return attributes.joined()
    }

    private static func safeRemoteURL(_ rawValue: String, baseURL: URL?) -> URL? {
        let normalized = htmlEntityDecoded(rawValue).unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value >= 0x20 && scalar.value != 0x7F && !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        guard !normalized.isEmpty,
              let url = URL(string: normalized, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return nil }

        // Twitter/X media endpoints can advertise WebP while returning a
        // variant that older WKWebView decoders fail to paint (the element
        // keeps its width/height and appears as an empty frame). Ask the CDN
        // for its JPEG representation instead. This is scoped to pbs.twimg.com
        // media URLs; unrelated article images keep their original format.
        guard url.host?.lowercased() == "pbs.twimg.com", url.path.contains("/media/") else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if var queryItems = components?.queryItems,
           let formatIndex = queryItems.firstIndex(where: { $0.name.caseInsensitiveCompare("format") == .orderedSame }),
           queryItems[formatIndex].value?.caseInsensitiveCompare("webp") == .orderedSame {
            queryItems[formatIndex].value = "jpg"
            components?.queryItems = queryItems
            return components?.url ?? url
        }
        return url
    }

    private static func htmlEntityDecoded(_ value: String) -> String {
        // Feed bodies frequently arrive from CDATA, so XMLParser does not
        // decode entities for us. Decode before resolving a URL; otherwise a
        // query such as `?format=webp&amp;name=medium` is turned into the
        // literal parameter `format=webp&amp;name=medium`. Older PaperRss
        // versions could encode that value a second time (`&amp;amp;`), so
        // apply the small allow-list more than once to repair cached HTML as
        // well. We deliberately do not decode arbitrary entities here.
        var decoded = value
        for _ in 0..<3 {
            let next = decoded
                .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
                .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
                .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
                .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
                .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
                .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
                .replacingOccurrences(of: "&colon;", with: ":", options: .caseInsensitive)
                .replacingOccurrences(of: "&tab;", with: "\t", options: .caseInsensitive)
                .replacingOccurrences(of: "&newline;", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "&#x3a;", with: ":", options: .caseInsensitive)
                .replacingOccurrences(of: "&#58;", with: ":", options: .caseInsensitive)
            if next == decoded { break }
            decoded = next
        }
        return decoded
    }

    private static func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension String {
    public func isSameReaderParagraph(as other: String) -> Bool {
        func normalized(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\u{00A0}", with: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized(self) == normalized(other)
    }
}

public enum ExtractionError: LocalizedError {
    case unsupportedEncoding
    case noReadableContent

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: "网页编码无法读取。"
        case .noReadableContent: "没有提取到足够的正文；可打开原网页阅读。"
        }
    }
}
