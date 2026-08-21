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
        let pattern = "(?is)<img\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<URL>()
        var result: [URL] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let attrRange = Range(match.range(at: 1), in: html) else { return }
            let attrString = String(html[attrRange])
            guard let url = extractBestImageURL(from: attrString, baseURL: baseURL),
                  seen.insert(url).inserted else { return }
            result.append(url)
        }
        return result
    }

    /// 从 img 标签属性中提取最合适的非占位图片 URL，依次支持 data-original, data-src, data-lazy-src, data-actualsrc, srcset 和 src
    static func extractBestImageURL(from attributesString: String, baseURL: URL?) -> URL? {
        let attrMap = parseAttributesMap(from: attributesString)

        // 1. 尝试从常见懒加载属性提取
        let lazyKeys = ["data-original", "data-src", "data-lazy-src", "data-actualsrc", "data-full-url", "data-url"]
        for key in lazyKeys {
            if let val = attrMap[key], !val.isEmpty, !isPlaceholderImageURL(val),
               let url = safeRemoteURL(val, baseURL: baseURL) {
                return url
            }
        }

        // 2. 尝试从 srcset 解析多分辨率并选取高分辨率项
        if let srcsetVal = attrMap["srcset"], !srcsetVal.isEmpty,
           let url = parseBestURLFromSrcset(srcsetVal, baseURL: baseURL) {
            return url
        }

        // 3. 尝试从 src 提取
        if let srcVal = attrMap["src"], !srcVal.isEmpty, !isPlaceholderImageURL(srcVal),
           let url = safeRemoteURL(srcVal, baseURL: baseURL) {
            return url
        }

        return nil
    }

    static func isPlaceholderImageURL(_ raw: String) -> Bool {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("data:image/") { return true }
        if lower.contains("1x1") || lower.contains("placeholder") || lower.contains("spacer") || lower.contains("blank.gif") {
            return true
        }
        return false
    }

    static func parseBestURLFromSrcset(_ srcset: String, baseURL: URL?) -> URL? {
        let items = srcset.components(separatedBy: ",")
        var bestURL: URL?
        var maxDescriptorValue: Double = -1

        for item in items {
            let parts = item.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard let first = parts.first, !isPlaceholderImageURL(first),
                  let url = safeRemoteURL(first, baseURL: baseURL) else { continue }

            var descriptorVal: Double = 1.0
            if parts.count > 1, let desc = parts.last {
                let cleanDesc = desc.lowercased()
                if cleanDesc.hasSuffix("w"), let w = Double(cleanDesc.dropLast()) {
                    descriptorVal = w
                } else if cleanDesc.hasSuffix("x"), let x = Double(cleanDesc.dropLast()) {
                    descriptorVal = x * 1000
                }
            }

            if descriptorVal > maxDescriptorValue {
                maxDescriptorValue = descriptorVal
                bestURL = url
            }
        }
        return bestURL
    }

    private static func parseAttributesMap(from source: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: "(?is)([a-z][a-z0-9:-]*)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+)))?") else { return [:] }
        let range = NSRange(source.startIndex..., in: source)
        var map: [String: String] = [:]
        expression.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: source) else { return }
            let name = source[nameRange].lowercased()
            let valueRange = [2, 3, 4].lazy.compactMap { index -> Range<String.Index>? in
                let candidate = match.range(at: index)
                return candidate.location == NSNotFound ? nil : Range(candidate, in: source)
            }.first
            if let valueRange {
                map[name] = String(source[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                map[name] = ""
            }
        }
        return map
    }

    /// Repairs image URLs written by older builds that removed legal spaces
    /// from remote paths before caching the sanitized article HTML.
    static func repairingCollapsedWhitespaceImageURLs(
        in sanitizedHTML: String,
        sourceHTML: String,
        baseURL: URL?
    ) -> String {
        let pattern = "(?is)<img\\b[^>]*?\\b(?:src|data-src|data-original|data-lazy-src)\\s*=\\s*(?:[\"']([^\"']+)[\"']|([^\\s>]+))[^>]*>"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return sanitizedHTML }
        let range = NSRange(sourceHTML.startIndex..., in: sourceHTML)
        var repairedHTML = sanitizedHTML

        expression.enumerateMatches(in: sourceHTML, range: range) { match, _, _ in
            guard let match else { return }
            let captureRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let swiftRange = Range(captureRange, in: sourceHTML) else { return }
            let source = htmlEntityDecoded(String(sourceHTML[swiftRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard source.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
                  let correctedURL = safeRemoteURL(source, baseURL: baseURL) else { return }

            let collapsedSource = source.unicodeScalars.reduce(into: "") { result, scalar in
                if scalar.value >= 0x20,
                   scalar.value != 0x7F,
                   !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    result.unicodeScalars.append(scalar)
                }
            }
            guard let collapsedURL = URL(string: collapsedSource, relativeTo: baseURL)?.absoluteURL,
                  collapsedURL != correctedURL else { return }

            repairedHTML = repairedHTML.replacingOccurrences(
                of: htmlAttributeEscaped(collapsedURL.absoluteString),
                with: htmlAttributeEscaped(correctedURL.absoluteString)
            )
        }
        return repairedHTML
    }

    public static func content(from html: String, baseURL: URL?) -> Content {
        let normalized = ArticleMarkupNormalizer.normalize(html, baseURL: baseURL)
        let cleaned = stripNoiseBlocks(normalized)
            .replacingOccurrences(of: "(?is)<(script|style|noscript|svg|canvas|iframe|form|nav|footer|aside)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)

        // 运行容器评分器寻找最佳正文容器
        if let bestContainer = extractBestArticleContainer(from: cleaned, baseURL: baseURL) {
            let safeHTML = sanitizedHTML(bestContainer, baseURL: baseURL)
            let text = safeHTML.plainText
            if !text.isEmpty {
                return Content(text: text, html: safeHTML, imageURLs: imageURLs(from: safeHTML, baseURL: baseURL))
            }
        }

        let safeHTML = sanitizedHTML(cleaned, baseURL: baseURL)
        return Content(text: safeHTML.plainText, html: safeHTML, imageURLs: imageURLs(from: safeHTML, baseURL: baseURL))
    }

    struct ScannedContainer: Sendable {
        let tag: String
        let attributes: String
        let innerHTML: String
        let fullHTML: String
    }

    /// 基于语义标签、通用 class 词元、段落/媒体密度与链接密度评估并提取最佳正文容器
    private static func extractBestArticleContainer(from html: String, baseURL: URL?) -> String? {
        let candidates = scanBalancedContainers(from: html)
        guard !candidates.isEmpty else { return nil }

        var bestScore: Double = -100
        var bestFragment: String?

        for candidate in candidates {
            let score = scoreCandidateContainer(tag: candidate.tag, attributes: candidate.attributes, bodyHTML: candidate.innerHTML)
            if score > bestScore {
                bestScore = score
                bestFragment = candidate.fullHTML
            }
        }

        if bestScore >= 35 {
            return bestFragment
        }
        return nil
    }

    /// 使用标签栈扫描平衡容器，天然安全支持同名与多级嵌套
    private static func scanBalancedContainers(from html: String) -> [ScannedContainer] {
        let targetTags: Set<String> = ["article", "main", "section", "div"]
        let tagPattern = "(?is)</?([a-z][a-z0-9]*)\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>"
        guard let expression = try? NSRegularExpression(pattern: tagPattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let matches = expression.matches(in: html, range: range)

        struct OpenTag {
            let name: String
            let attributes: String
            let tagStart: String.Index
            let innerStart: String.Index
        }

        var stacks: [String: [OpenTag]] = ["article": [], "main": [], "section": [], "div": []]
        var candidates: [ScannedContainer] = []

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: html),
                  let attrRange = Range(match.range(at: 2), in: html),
                  let fullRange = Range(match.range, in: html) else { continue }

            let tagName = String(html[nameRange]).lowercased()
            guard targetTags.contains(tagName) else { continue }
            let attrString = String(html[attrRange])
            let tagString = html[fullRange]
            let isClosing = tagString.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")

            if isClosing {
                if var tagStack = stacks[tagName], let opened = tagStack.popLast() {
                    stacks[tagName] = tagStack
                    let inner = String(html[opened.innerStart..<fullRange.lowerBound])
                    let full = String(html[opened.tagStart..<fullRange.upperBound])
                    candidates.append(ScannedContainer(tag: tagName, attributes: opened.attributes, innerHTML: inner, fullHTML: full))
                }
            } else {
                let opened = OpenTag(name: tagName, attributes: attrString, tagStart: fullRange.lowerBound, innerStart: fullRange.upperBound)
                stacks[tagName, default: []].append(opened)
            }
        }

        return candidates
    }

    private static func scoreCandidateContainer(tag: String, attributes: String, bodyHTML: String) -> Double {
        var score: Double = 0

        // 1. 语义标签基础分
        switch tag {
        case "article": score += 40
        case "main": score += 30
        case "section": score += 15
        default: score += 5
        }

        // 2. 通用 class / id 词元评分
        let attrMap = parseAttributesMap(from: attributes)
        let classAndID = "\(attrMap["class"] ?? "") \(attrMap["id"] ?? "")".lowercased()

        let positiveTokens = [
            "article", "content", "post", "entry", "main", "body", "story", "detail",
            "text", "rich-text", "article-body", "post-content", "entry-content",
            "article-content", "markdown-body", "story-body"
        ]
        let negativeTokens = [
            "sidebar", "nav", "footer", "header", "comment", "share", "ad", "recommend",
            "related", "widget", "modal", "dialog", "popover", "author-bio", "nav-links",
            "menu", "banner", "copyright"
        ]

        for token in positiveTokens {
            if classAndID.contains(token) { score += 30 }
        }
        for token in negativeTokens {
            if classAndID.contains(token) { score -= 45 }
        }

        // 3. 语义段落数
        let pCount = (try? NSRegularExpression(pattern: "(?is)<p\\b[^>]*>.*?</p>"))?.numberOfMatches(in: bodyHTML, range: NSRange(bodyHTML.startIndex..., in: bodyHTML)) ?? 0
        score += Double(pCount * 12)

        // 4. 图片与多媒体数
        let imgCount = (try? NSRegularExpression(pattern: "(?is)<(img|figure|video)\\b[^>]*>"))?.numberOfMatches(in: bodyHTML, range: NSRange(bodyHTML.startIndex..., in: bodyHTML)) ?? 0
        score += Double(min(4, imgCount) * 15)

        // 5. 纯文本长度
        let plain = bodyHTML.plainText
        score += Double(min(150, plain.count / 10))

        // 6. 链接文本密度计算
        let linkPattern = "(?is)<a\\b[^>]*>(.*?)</a>"
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let matches = regex.matches(in: bodyHTML, range: NSRange(bodyHTML.startIndex..., in: bodyHTML))
            var linkTextCount = 0
            for match in matches {
                if let r = Range(match.range(at: 1), in: bodyHTML) {
                    linkTextCount += String(bodyHTML[r]).plainText.count
                }
            }
            if plain.count > 0 {
                let linkDensity = Double(linkTextCount) / Double(plain.count)
                if linkDensity > 0.35 {
                    score *= max(0.05, 1.0 - linkDensity * 1.5)
                }
                if linkDensity > 0.55 {
                    score -= 150
                }
            }
        }

        return score
    }

    private static func stripNoiseBlocks(_ html: String) -> String {
        var current = html
        let noiseKeywords = [
            "author-popover", "author-item", "author__info", "author__bio",
            "article__header__author", "article-header-author", "author-card", "author-box", "user-card",
            "article__charge", "post__comments", "comment-box", "comment-list",
            "share-bar", "social-share", "action-bar", "phoneBindDialog", "dialog-title",
            "comp__Directory", "directory__overlay"
        ]
        let keywordPattern = noiseKeywords.joined(separator: "|")
        let pattern = "(?is)<(div|section|aside|form|ul|ol|blockquote|button)\\b[^>]*?\\b(?:class|id|data-[a-z-]+)\\s*=\\s*[\"'][^\"']*?\\b(\(keywordPattern))\\b[^\"']*?[\"'][^>]*?>.*?</\\1>"

        for _ in 0..<3 {
            let updated = current.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            if updated.count == current.count { break }
            current = updated
        }
        return current
    }

    /// Retains only the small, document-oriented HTML subset used by the reader.
    /// Attributes are rebuilt rather than edited in place so malformed markup cannot
    /// smuggle event handlers, styles, or executable URL schemes into WebKit.
    public static func sanitizedHTML(_ html: String, baseURL: URL? = nil) -> String {
        let stripped = stripNoiseBlocks(html)
        let withoutExecutableBlocks = stripped
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
        let tagPattern = "(?is)</?([a-z][a-z0-9]*)\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>"
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
        let tagPattern = "(?is)</?([a-z][a-z0-9]*)\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>"
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

    private static func splitBlockTextIntoParagraphs(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var current = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            } else {
                if !current.isEmpty {
                    current += "\n"
                }
                current += line
            }
        }
        if !current.isEmpty {
            result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.filter { !$0.isEmpty }
    }

    /// Presentation-stage helper: examines the first leading heading block (h1/h2/h3).
    /// If its normalized text is semantically identical to the article title rendered in the Reader header,
    /// removes that leading heading block from the display HTML so it doesn't appear twice.
    public static func removingDuplicateLeadingHeading(
        from html: String?,
        articleTitle: String
    ) -> String? {
        guard let html, !html.isEmpty else { return html }
        let cleanTitle = normalizeHeadingText(articleTitle)
        guard !cleanTitle.isEmpty else { return html }

        // 查找 HTML 前部的第一个 <h1|h2|h3...>...</h1> 标签
        let pattern = "<(?i:h[1-3])[^>]*>([\\s\\S]*?)</(?i:h[1-3])>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return html
        }

        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let fullMatchRange = Range(match.range, in: html),
              let contentRange = Range(match.range(at: 1), in: html) else {
            return html
        }

        // 检查 heading 前面的前置内容：若仅为轻量元数据/空白（如日期、分类、作者，且在段落 <p> 之前，纯文本少于 120 字符），
        // 且 heading 文本与 articleTitle 语义一致，则移除该标题标签
        let prefixHTML = String(html[..<fullMatchRange.lowerBound])
        let hasPriorParagraph = prefixHTML.range(of: "<(?i:p)[^>]*>", options: .regularExpression) != nil
        guard !hasPriorParagraph else { return html }

        let prefixPlainText = normalizeHeadingText(prefixHTML.plainText)

        let headingContentHTML = String(html[contentRange])
        let headingText = normalizeHeadingText(headingContentHTML.plainText)

        if headingText == cleanTitle && prefixPlainText.count <= 120 {
            var result = html
            result.removeSubrange(fullMatchRange)
            return result
        }

        return html
    }

    private static func normalizeHeadingText(_ text: String) -> String {
        return text
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    /// Returns the source blocks WebKit can observe while the reader scrolls.
    /// The same expression is used by the renderer below, keeping paragraph IDs
    /// stable between translation requests and document reloads.
    public static func readerParagraphs(in html: String, title: String? = nil) -> [ReaderParagraph] {
        var paragraphs: [ReaderParagraph] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            paragraphs.append(ReaderParagraph(id: "title", original: title))
        }
        guard let expression = readerBlockExpression else { return paragraphs }
        let range = NSRange(html.startIndex..., in: html)
        var paragraphIndex = 0
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let blockRange = Range(match.range, in: html) else { return }
            let original = String(html[blockRange]).plainText
            guard !original.isEmpty else { return }

            let subParagraphs = splitBlockTextIntoParagraphs(original)
            if subParagraphs.count > 1 {
                for (subIdx, subText) in subParagraphs.enumerated() {
                    paragraphs.append(ReaderParagraph(id: "p\(paragraphIndex)_\(subIdx)", original: subText))
                }
            } else {
                paragraphs.append(ReaderParagraph(id: "p\(paragraphIndex)", original: original))
            }
            paragraphIndex += 1
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

            let subParagraphs = splitBlockTextIntoParagraphs(original)
            if subParagraphs.count > 1 {
                for (subIdx, subText) in subParagraphs.enumerated() {
                    let subID = "p\(paragraphIndex)_\(subIdx)"
                    let escapedSubText = htmlTextEscaped(subText).replacingOccurrences(of: "\n", with: "<br>")
                    rendered += "<p class=\"paper-rss-subparagraph\" data-paper-rss-id=\"\(subID)\">\(escapedSubText)</p>"
                    if let segment = segmentsByID[subID], subText.isSameReaderParagraph(as: segment.original) {
                        rendered += translationMarkup(for: segment.translation, id: subID)
                    } else if pendingIDs.contains(subID) {
                        rendered += pendingTranslationMarkup(for: subID)
                    }
                }
            } else {
                let id = "p\(paragraphIndex)"
                rendered += annotatedReaderBlock(block, id: id)

                if let segment = segmentsByID[id],
                   original.isSameReaderParagraph(as: segment.original) {
                    rendered += translationMarkup(for: segment.translation, id: id)
                } else if pendingIDs.contains(id) {
                    rendered += pendingTranslationMarkup(for: id)
                }
            }
            paragraphIndex += 1
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

    private static func annotatedReaderSpanBlock(_ blockHTML: String, id: String) -> String {
        guard let closingBracket = blockHTML.firstIndex(of: ">") else {
            return "<span data-paper-rss-id=\"\(id)\">\(blockHTML)</span>"
        }
        var output = blockHTML
        output.insert(contentsOf: " data-paper-rss-id=\"\(id)\"", at: closingBracket)
        return output
    }

    public static func translationMarkup(for translation: String, id: String) -> String {
        """
        <aside id="paper-rss-translation-\(id)" class="paper-rss-translation" data-paper-rss-translation-for="\(id)" aria-label="中文翻译">
        <p><span class="paper-rss-translation-label" aria-label="译文">
          <span class="paper-rss-language-chip" aria-hidden="true">A</span>
          <span class="paper-rss-language-chip" aria-hidden="true">文</span>
        </span><span class="paper-rss-translation-text">\(htmlTextEscaped(translation).replacingOccurrences(of: "\\n", with: "<br>"))</span></p>
        </aside>
        """
    }

    public static func pendingTranslationMarkup(for id: String) -> String {
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
        if tag == "img" {
            var attributes: [String] = []
            let attrMap = parseAttributesMap(from: source)

            if let targetURL = extractBestImageURL(from: source, baseURL: baseURL) {
                attributes.append(" src=\"\(htmlAttributeEscaped(targetURL.absoluteString))\"")
            } else if let rawSrc = attrMap["src"], let safeURL = safeRemoteURL(rawSrc, baseURL: baseURL) {
                attributes.append(" src=\"\(htmlAttributeEscaped(safeURL.absoluteString))\"")
            }

            if let alt = attrMap["alt"] {
                attributes.append(" alt=\"\(htmlAttributeEscaped(alt))\"")
            }
            if let title = attrMap["title"] {
                attributes.append(" title=\"\(htmlAttributeEscaped(title))\"")
            }
            if let width = attrMap["width"], let num = Int(width), num > 0, num <= 10_000 {
                attributes.append(" width=\"\(num)\"")
            }
            if let height = attrMap["height"], let num = Int(height), num > 0, num <= 10_000 {
                attributes.append(" height=\"\(num)\"")
            }

            attributes.append(" loading=\"\(eagerImage ? "eager" : "lazy")\"")
            attributes.append(" decoding=\"async\"")
            return attributes.joined()
        }

        let allowed: Set<String>
        switch tag {
        case "a": allowed = ["href", "title"]
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
        if tag == "video" {
            // Guarantee controls and fullscreen behavior for HTML5 videos in WKWebView
            if !seenNames.contains("controls") { attributes.append(" controls") }
            if !seenNames.contains("playsinline") { attributes.append(" playsinline") }
            if !seenNames.contains("webkit-playsinline") { attributes.append(" webkit-playsinline") }
            if !seenNames.contains("allowfullscreen") { attributes.append(" allowfullscreen") }
        }
        return attributes.joined()
    }

    private static func safeRemoteURL(_ rawValue: String, baseURL: URL?) -> URL? {
        let normalized = htmlEntityDecoded(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
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
        case .unsupportedEncoding: I18N.localized("网页编码无法读取。")
        case .noReadableContent: I18N.localized("没有提取到足够的正文；可打开原网页阅读。")
        }
    }
}
