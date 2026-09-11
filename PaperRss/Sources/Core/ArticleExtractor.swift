import Foundation

public enum ArticleExtractor {
    private static let positiveContainerTokens = [
        "article", "content", "post", "entry", "main", "body", "story", "detail",
        "text", "rich-text", "article-body", "post-content", "entry-content",
        "article-content", "markdown-body", "story-body"
    ]

    private static let negativeContainerTokens = [
        "sidebar", "nav", "footer", "header", "comment", "share", "ad", "recommend",
        "related", "widget", "modal", "dialog", "popover", "author-bio", "nav-links",
        "menu", "banner", "copyright"
    ]

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

    static func parseAttributesMap(from source: String) -> [String: String] {
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
        let startOffset: Int
        let endOffset: Int
    }

    /// 基于语义标签、通用 class 词元、段落/媒体密度与链接密度评估并提取最佳正文容器
    private static func extractBestArticleContainer(from html: String, baseURL: URL?) -> String? {
        let candidates = scanBalancedContainers(from: html)
        guard !candidates.isEmpty else { return nil }

        var bestScore: Double = -100
        var bestCandidate: ScannedContainer?

        for candidate in candidates {
            // RSSHub 约定 class 含 rsshub-quote 的容器是“内嵌引用内容”，
            // 永远不是正文容器。转推/引用推文的描述把推文主文本放在顶层，
            // 只把被引用推文包进该容器；若让它参与评分，富媒体引用（多图）
            // 会以高分胜出并被当作正文容器，导致容器外的推文主内容整体丢弃。
            if isEmbeddedQuoteContainer(candidate) { continue }
            let score = scoreCandidateContainer(tag: candidate.tag, attributes: candidate.attributes, bodyHTML: candidate.innerHTML)
            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }

        guard bestScore >= 35, let bestCandidate else { return nil }

        // Some layouts keep a cover or media rail in a sibling of the text
        // container. Expand only to the nearest containing candidate when it
        // adds media without adding a substantial amount of unrelated text.
        let bestMediaCount = mediaCount(in: bestCandidate.fullHTML)
        let bestTextCount = bestCandidate.fullHTML.plainText.count
        let expandedCandidate = candidates
            .filter {
                $0.startOffset < bestCandidate.startOffset &&
                $0.endOffset > bestCandidate.endOffset &&
                mediaCount(in: $0.fullHTML) > bestMediaCount &&
                $0.fullHTML.plainText.count <= bestTextCount + max(120, bestTextCount / 4) &&
                isLowNoiseContainer($0) &&
                scoreCandidateContainer(tag: $0.tag, attributes: $0.attributes, bodyHTML: $0.innerHTML) >= 35
            }
            .min { lhs, rhs in
                (lhs.endOffset - lhs.startOffset) < (rhs.endOffset - rhs.startOffset)
            }

        if let expandedCandidate {
            return expandedCandidate.fullHTML
        }
        return bestCandidate.fullHTML
    }

    private static func mediaCount(in html: String) -> Int {
        let pattern = "(?is)<(img|figure|video)\\b"
        return (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        ) ?? 0
    }

    /// RSSHub 把内嵌引用（引用推文/转推来源）包进 `class="rsshub-quote"` 的容器，
    /// 清洗后归一化为 `class="paper-quote-card"`。该容器语义上永远是“被引用的附属内容”而非正文容器。
    private static func isEmbeddedQuoteContainer(_ candidate: ScannedContainer) -> Bool {
        let attributes = parseAttributesMap(from: candidate.attributes)
        let classAndID = "\(attributes["class"] ?? "") \(attributes["id"] ?? "")".lowercased()
        return classAndID.contains("rsshub-quote") || classAndID.contains("paper-quote-card")
    }

    private static func isLowNoiseContainer(_ candidate: ScannedContainer) -> Bool {
        let attributes = parseAttributesMap(from: candidate.attributes)
        let classAndID = "\(attributes["class"] ?? "") \(attributes["id"] ?? "")".lowercased()
        if negativeContainerTokens.contains(where: { classAndID.contains($0) }) {
            return false
        }

        let tokenPattern = negativeContainerTokens.joined(separator: "|")
        let pattern = "(?is)<[a-z][^>]*\\b(?:class|id)\\s*=\\s*[\"'][^\"']*(?:\(tokenPattern))[^\"']*[\"']"
        return (try? NSRegularExpression(pattern: pattern))?.firstMatch(
            in: candidate.innerHTML,
            range: NSRange(candidate.innerHTML.startIndex..., in: candidate.innerHTML)
        ) == nil
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
                    let startOffset = html.distance(from: html.startIndex, to: opened.tagStart)
                    let endOffset = html.distance(from: html.startIndex, to: fullRange.upperBound)
                    candidates.append(
                        ScannedContainer(
                            tag: tagName,
                            attributes: opened.attributes,
                            innerHTML: inner,
                            fullHTML: full,
                            startOffset: startOffset,
                            endOffset: endOffset
                        )
                    )
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

        for token in positiveContainerTokens {
            if classAndID.contains(token) { score += 30 }
        }
        for token in negativeContainerTokens {
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
            "img", "a", "video", "source", "audio", "picture",
            "math", "mrow", "mi", "mn", "mo", "mtext", "mspace", "mfrac", "msqrt", "mroot",
            "mstyle", "merror", "mpadded", "mphantom", "mfenced", "menclose", "msub", "msup",
            "msubsup", "munder", "mover", "munderover", "mmultiscripts", "mprescripts", "none",
            "mtable", "mtr", "mtd", "mlabeledtr", "semantics", "annotation", "annotation-xml",
            "maction", "maligngroup", "malignmark", "ms", "mlongdiv", "mscarries", "mscarry",
            "msgroup", "msline", "msrow", "mstack"
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
                if name == "img",
                   isProfileAvatarImage(String(withoutExecutableBlocks[attributesRange]), baseURL: baseURL) {
                    // 作者头像是页面装饰而非文章内容：x.com 网页抽取会把头像壳
                    // 作为正文首块带进阅读器（大图顶在推文前）。整标签剔除，
                    // 推文媒体（/media/、/amplify_video_thumb/）不受影响。
                    return
                }
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

    private struct ReaderBlockMatch {
        let range: Range<String.Index>
        let tag: String
        let hasNestedReaderBlock: Bool
    }

    private static func readerBlockMatches(in html: String) -> [ReaderBlockMatch] {
        // pre 不是翻译单元，而是翻译禁区：pre 完整保留渲染与选择解释。
        // 语法高亮会把代码包进 div/span（React.dev 等），只移除 pre 匹配会让
        // 代码内部的 div 变成翻译单元；因此任何与 pre 区域相交的块都不进入管线。
        let pattern = "(?is)</?(blockquote|table|ul|ol|h[1-6]|figcaption|dt|dd|p|li|div)\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var stack: [(tag: String, start: String.Index, hasNestedReaderBlock: Bool)] = []
        var matches: [ReaderBlockMatch] = []

        for token in expression.matches(in: html, range: range) {
            guard let tokenRange = Range(token.range, in: html),
                  let nameRange = Range(token.range(at: 1), in: html) else { continue }
            let tag = html[nameRange].lowercased()
            let sourceTag = html[tokenRange]
            let isClosing = sourceTag.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            if !isClosing {
                for index in stack.indices {
                    stack[index].hasNestedReaderBlock = true
                }
                stack.append((tag, tokenRange.lowerBound, false))
                continue
            }

            guard let openingIndex = stack.lastIndex(where: { $0.tag == tag }) else { continue }
            let opening = stack[openingIndex]
            stack.removeSubrange(openingIndex...)
            matches.append(ReaderBlockMatch(
                range: opening.start..<tokenRange.upperBound,
                tag: tag,
                hasNestedReaderBlock: opening.hasNestedReaderBlock
            ))
        }

        matches.sort {
            if $0.range.lowerBound == $1.range.lowerBound {
                return $0.range.upperBound > $1.range.upperBound
            }
            return $0.range.lowerBound < $1.range.lowerBound
        }

        let preRanges = preformattedRanges(in: html)
        var selected: [ReaderBlockMatch] = []
        var selectedEnd: String.Index?
        for candidate in matches {
            if candidate.tag == "div" && candidate.hasNestedReaderBlock {
                continue
            }
            if preRanges.contains(where: { $0.overlaps(candidate.range) }), candidate.tag != "table" {
                // 代码禁区：任何相交块都不进入翻译管线。表格例外——
                // 表格可由单元格拆分计划排除含代码的单元格后继续翻译文本格。
                continue
            }
            if let end = selectedEnd, candidate.range.lowerBound < end {
                continue
            }
            selected.append(candidate)
            selectedEnd = candidate.range.upperBound
        }
        return selected
    }

    /// 全部 preformatted 区域。代码块（含语法高亮内部标记）是翻译禁区。
    private static func preformattedRanges(in html: String) -> [Range<String.Index>] {
        let pattern = "(?is)<pre\\b[^>]*>.*?</pre>"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { Range($0.range, in: html) }
    }

    /// 结构适配只作用于已经清洗的正文；按固定顺序尝试，无法安全拆分时整块保留。
    /// 两种真实策略共用一个内部接口，段落索引与 HTML 标注不得各自重新推断结构。
    private enum ReaderBlockAdapter: CaseIterable {
        case explicitBreakParagraph
        case preservedBlock

        func fragments(for block: String, tag: String, hasNestedBlock: Bool) -> [String]? {
            switch self {
            case .explicitBreakParagraph:
                guard tag == "p", !hasNestedBlock else { return nil }
                return ArticleExtractor.splitHTMLParagraphAtExplicitBreaks(block)
            case .preservedBlock:
                return [block]
            }
        }
    }

    /// 表格按单元格成为翻译单元：整表一段会把译文平铺在表格之外，
    /// 单元格级拆分让每格的译文放回本格内，形成原文/译文对照。
    /// 校验失败（嵌套表格、单元格外存在文本等异常形态）时返回 nil，
    /// 整表退回旧的"单一翻译单元"路径，绝不破坏表格结构。
    private struct ReaderTableCell {
        /// 单元格之前的结构空隙（table/thead/tr 等标签），必须原样保留。
        let gapBefore: String
        let html: String
        let isTranslatable: Bool
    }

    private static func tableCellFragments(in block: String) -> (cells: [ReaderTableCell], gapAfter: String)? {
        let cellPattern = "(?is)<(t[dh])\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>([\\s\\S]*?)</\\1>"
        guard let expression = try? NSRegularExpression(pattern: cellPattern) else { return nil }
        let range = NSRange(block.startIndex..., in: block)

        var cells: [(fragment: String, isTranslatable: Bool)] = []
        var gaps: [String] = []
        var cursor = block.startIndex
        for match in expression.matches(in: block, range: range) {
            guard let fullRange = Range(match.range, in: block),
                  let innerRange = Range(match.range(at: 3), in: block) else { return nil }
            let inner = block[innerRange].lowercased()
            // 内层单元格开标签意味着嵌套表格：非贪婪 inner 会让外层片段提前闭合，
            // 拆分结果结构不可信，整表保留。
            guard !inner.contains("<td"), !inner.contains("<th") else { return nil }
            gaps.append(String(block[cursor..<fullRange.lowerBound]))
            let fragment = String(block[fullRange])
            let cellText = fragment.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空单元格、纯公式单元格与含代码块的单元格不是自然语言，
            // 不进入翻译管线，但必须原样保留渲染。
            let isTranslatable = !cellText.isEmpty
                && !inner.contains("<pre")
                && !ArticleMathDetector.strippingFormulas(in: cellText)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            cells.append((fragment, isTranslatable))
            cursor = fullRange.upperBound
        }
        let gapAfter = String(block[cursor...])
        guard cells.contains(where: { $0.isTranslatable }) else { return nil }

        // 完整性校验：单元格之间的空隙必须只有表格结构标签（thead/tr 等），
        // 不允许承载任何可见文本；这保证拆分不会丢失或搬动任何内容。
        guard gaps.allSatisfy({
            $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }

        let plan = cells.enumerated().map { index, cell in
            ReaderTableCell(gapBefore: gaps[index], html: cell.fragment, isTranslatable: cell.isTranslatable)
        }
        return (plan, gapAfter)
    }

    /// 段落拆分的统一入口。`tablePlan` 非 nil 表示该表格拆分成了单元格级
    /// 翻译单元；`fragments` 只含可翻译单元格（段落 ID 依此编号），
    /// 不可翻译单元格与结构空隙由渲染层按拆分计划原样保留。
    /// `isPreformatted` 表示该块位于代码禁区且无法单元格化——保留渲染、绝不翻译。
    private static func readerBlockFragmentPlan(
        _ block: String,
        match: ReaderBlockMatch
    ) -> (fragments: [String], tablePlan: (cells: [ReaderTableCell], gapAfter: String)?, isPreformatted: Bool) {
        if match.tag == "table", let tablePlan = tableCellFragments(in: block) {
            return (tablePlan.cells.filter(\.isTranslatable).map(\.html), tablePlan, false)
        }
        if block.range(of: "(?is)<pre\\b", options: .regularExpression) != nil {
            return ([block], nil, true)
        }
        for adapter in ReaderBlockAdapter.allCases {
            if let fragments = adapter.fragments(for: block, tag: match.tag, hasNestedBlock: match.hasNestedReaderBlock) {
                // 新增适配策略也必须保留文本及非布局标签的顺序、属性；失败则尝试保留策略。
                if fragments.count == 1 && fragments[0] == block { return (fragments, nil, false) }
                if readerContentSignature(block) == readerContentSignature(fragments.joined()) {
                    return (fragments, nil, false)
                }
            }
        }
        return ([block], nil, false)
    }

    /// p/br 是允许改写的分段标记，其余标签（含媒体与链接属性）必须逐一保持。
    private static func readerContentSignature(_ html: String) -> [String] {
        let pattern = "(?is)</?(?!p\\b|br\\b)[a-z][a-z0-9]*\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>"
        let expression = try? NSRegularExpression(pattern: pattern)
        let tags = expression?.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        } ?? []
        return [html.plainText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)] + tags
    }

    /// 仅以段落直属的连续 br 为分隔符。保留原始片段和属性，源码换行不参与拆分。
    /// 嵌套链接/强调内部的 br、未闭合标签和纯媒体片段均保守保留，避免拆坏结构。
    private static func splitHTMLParagraphAtExplicitBreaks(_ block: String) -> [String]? {
        let pattern = "(?is)</?([a-z][a-z0-9]*)\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let tokens = expression.matches(in: block, range: NSRange(block.startIndex..., in: block))
        guard let first = tokens.first, let last = tokens.last,
              let opening = Range(first.range, in: block),
              let closing = Range(last.range, in: block), opening.upperBound <= closing.lowerBound,
              block[closing].lowercased().hasPrefix("</p") else { return nil }
        let voidTags: Set<String> = ["br", "hr", "img", "source", "wbr", "area", "base", "col", "embed", "input", "link", "meta", "param", "track"]
        var stack: [String] = []
        var breaks: [Range<String.Index>] = []
        for token in tokens.dropFirst().dropLast() {
            guard let range = Range(token.range, in: block),
                  let nameRange = Range(token.range(at: 1), in: block) else { return nil }
            let tag = block[nameRange].lowercased()
            let isClosing = block[range].hasPrefix("</")
            if isClosing {
                guard stack.last == tag else { return nil }
                stack.removeLast()
            } else if tag == "br" && stack.isEmpty {
                breaks.append(range)
            } else if !voidTags.contains(tag) {
                stack.append(tag)
            }
        }
        guard stack.isEmpty else { return nil }

        var separators: [Range<String.Index>] = []
        var run: Range<String.Index>?
        var count = 0
        for range in breaks {
            if let previous = run,
               block[previous.upperBound..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                run = previous.lowerBound..<range.upperBound
                count += 1
            } else {
                if let previous = run, count >= 2 { separators.append(previous) }
                run = range
                count = 1
            }
        }
        if let run, count >= 2 { separators.append(run) }
        guard !separators.isEmpty else { return nil }

        var fragments: [String] = []
        var cursor = opening.upperBound
        for separator in separators {
            fragments.append(String(block[cursor..<separator.lowerBound]))
            cursor = separator.upperBound
        }
        fragments.append(String(block[cursor..<closing.lowerBound]))
        // 图片不能因为所在片段没有可翻译文本而消失，也不能被搬到其他段落。
        guard fragments.allSatisfy({ !$0.plainText.isEmpty }) else { return nil }
        return fragments.map { String(block[opening]) + $0 + String(block[closing]) }
    }

    public static func readerParagraphs(in html: String, title: String? = nil) -> [ReaderParagraph] {
        var paragraphs: [ReaderParagraph] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            paragraphs.append(ReaderParagraph(id: "title", original: title))
        }
        var paragraphIndex = 0
        for match in readerBlockMatches(in: html) {
            let block = String(html[match.range])
            let original = block.plainText
            guard !original.isEmpty else { continue }

            let plan = readerBlockFragmentPlan(block, match: match)
            guard !plan.isPreformatted else { continue }
            let fragments = plan.fragments
            for (index, fragment) in fragments.enumerated() {
                let id = fragments.count > 1 ? "p\(paragraphIndex)_\(index)" : "p\(paragraphIndex)"
                paragraphs.append(ReaderParagraph(id: id, original: fragment.plainText))
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
        var rendered = ""
        var cursor = html.startIndex
        var paragraphIndex = 0
        let segmentsByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        for match in readerBlockMatches(in: html) {
            rendered += html[cursor..<match.range.lowerBound]
            let block = String(html[match.range])
            cursor = match.range.upperBound

            let original = block.plainText
            if original.isEmpty {
                rendered += block
                continue
            }

            let plan = readerBlockFragmentPlan(block, match: match)
            if plan.isPreformatted {
                // 代码禁区：完整保留渲染与选择解释，绝不注解、绝不翻译。
                rendered += block
                continue
            }
            if let tablePlan = plan.tablePlan {
                // 单元格级翻译：译文插入本格闭合标签之前，保证对照关系留在表格内。
                // 结构空隙（table/thead/tr 等）与不可翻译单元格（空白/纯公式）
                // 原样保留，不注解也不翻译。
                let translatableCount = tablePlan.cells.filter(\.isTranslatable).count
                var cellIndex = 0
                for cell in tablePlan.cells {
                    rendered += cell.gapBefore
                    guard cell.isTranslatable else {
                        rendered += cell.html
                        continue
                    }
                    let id = translatableCount > 1 ? "p\(paragraphIndex)_\(cellIndex)" : "p\(paragraphIndex)"
                    cellIndex += 1
                    let translationHTML: String?
                    if let segment = segmentsByID[id],
                       cell.html.plainText.isSameReaderParagraph(as: segment.original) {
                        translationHTML = translationMarkup(for: segment.translation, id: id)
                    } else if pendingIDs.contains(id) {
                        translationHTML = pendingTranslationMarkup(for: id)
                    } else {
                        translationHTML = nil
                    }
                    rendered += annotatedTableCell(cell.html, id: id, translationHTML: translationHTML)
                }
                rendered += tablePlan.gapAfter
                paragraphIndex += 1
                continue
            }

            let fragments = plan.fragments
            for (index, fragment) in fragments.enumerated() {
                let id = fragments.count > 1 ? "p\(paragraphIndex)_\(index)" : "p\(paragraphIndex)"
                rendered += annotatedReaderBlock(fragment, id: id)
                if let segment = segmentsByID[id],
                   fragment.plainText.isSameReaderParagraph(as: segment.original) {
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

    private static func annotatedReaderBlock(_ block: String, id: String) -> String {
        guard let closingBracket = block.firstIndex(of: ">") else { return block }
        var output = block
        output.insert(contentsOf: " data-paper-rss-id=\"\(id)\"", at: closingBracket)
        return output
    }

    /// 单元格片段：注解落在 td/th 开标签，译文插在本格闭合标签之前，
    /// 使原文与译文始终停留在同一个表格单元内。
    private static func annotatedTableCell(_ cellHTML: String, id: String, translationHTML: String?) -> String {
        var output = annotatedReaderBlock(cellHTML, id: id)
        guard let translationHTML else { return output }
        let closingTag = output.lowercased().hasPrefix("<th") ? "</th>" : "</td>"
        guard let closingRange = output.range(of: closingTag, options: .backwards) else { return output }
        output.insert(contentsOf: translationHTML, at: closingRange.lowerBound)
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

    /// 判断 img 属性串是否指向 Twitter/X 的作者头像。
    /// `pbs.twimg.com/profile_images/` 路径专用于头像；推文媒体在
    /// `/media/` 与 `/amplify_video_thumb/` 下，不会误伤正文图。
    private static func isProfileAvatarImage(_ attributes: String, baseURL: URL?) -> Bool {
        guard let url = extractBestImageURL(from: attributes, baseURL: baseURL) else { return false }
        return url.host?.lowercased() == "pbs.twimg.com" && url.path.lowercased().hasPrefix("/profile_images/")
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
            if let alignment = extractImageAlignment(attrMap: attrMap) {
                attributes.append(" class=\"paper-align-\(alignment)\"")
            }

            attributes.append(" loading=\"\(eagerImage ? "eager" : "lazy")\"")
            attributes.append(" decoding=\"async\"")
            return attributes.joined()
        }

        var allowed: Set<String>
        switch tag {
        case "a": allowed = ["href", "title"]
        case "code": allowed = ["class"]
        case "video": allowed = ["src", "poster", "controls", "autoplay", "loop", "muted", "playsinline", "webkit-playsinline", "allowfullscreen", "preload", "width", "height"]
        case "source": allowed = ["src", "type"]
        case "audio": allowed = ["src", "controls", "autoplay", "loop", "muted", "preload"]
        case "th", "td": allowed = ["colspan", "rowspan"]
        case "h1", "h2", "h3", "h4", "h5", "h6": allowed = ["id"]
        case "div": allowed = ["class"]
        case "math": allowed = ["display"]
        case "mi", "mn", "mo", "mtext", "mstyle": allowed = ["mathvariant"]
        case "mspace": allowed = ["width", "height", "depth"]
        case "menclose": allowed = ["notation"]
        case "mtable": allowed = ["columnalign", "rowalign", "columnspacing", "rowspacing", "frame"]
        case "mtd": allowed = ["columnalign", "rowalign", "columnspan", "rowspan"]
        case "annotation", "annotation-xml": allowed = ["encoding"]
        case "maction": allowed = ["actiontype", "selection"]
        default: allowed = []
        }
        allowed.insert("lang")
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
                if name == "href", value.hasPrefix("#") {
                    guard isSafeFragmentReference(value) else { return }
                } else if name == "href" || name == "src" || name == "poster" {
                    guard let resolvedURL = safeRemoteURL(value, baseURL: baseURL) else { return }
                    value = resolvedURL.absoluteString
                } else if name == "width" || name == "height" || name == "colspan" || name == "rowspan" {
                    guard let number = Int(value), number > 0, number <= 10_000 else { return }
                    value = String(number)
                } else if name == "class" {
                    let tokens = value
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    if tag == "div" {
                        // div 的 class 放行受控的图片行容器与引用卡片容器标记，
                        // 并将 RSSHub 的 rsshub-quote 归一化为内部受控类 paper-quote-card，其余一律剥离。
                        var controlledTokens: [String] = []
                        for token in tokens {
                            let lower = token.lowercased()
                            if lower == "paper-img-row" || lower == "paper-quote-card" {
                                if !controlledTokens.contains(lower) { controlledTokens.append(lower) }
                            } else if lower == "rsshub-quote" {
                                if !controlledTokens.contains("paper-quote-card") { controlledTokens.append("paper-quote-card") }
                            }
                        }
                        guard !controlledTokens.isEmpty else { return }
                        value = controlledTokens.joined(separator: " ")
                    } else if tag == "code" {
                        // code 的 class 透传语言标注（language-* / lang-* 等，供阅读器代码高亮消费），
                        // 但剥离阅读器自身命名空间 paper-*，防止 feed 伪造阅读器内部样式钩子。
                        let passthroughTokens = tokens.filter { !$0.lowercased().hasPrefix("paper-") }
                        guard !passthroughTokens.isEmpty else { return }
                        value = passthroughTokens.joined(separator: " ")
                    } else {
                        return
                    }
                } else if name == "id" {
                    guard isSafeHeadingID(value) else { return }
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

    /// 提取图片对齐语义并归一化为受控 class 名（left/right/center）。
    /// 来源覆盖三类常见写法：
    /// 1. `align="left|right|center"` 属性
    /// 2. `class` 中的常见对齐类名（align-left / alignleft / float-right 等）
    /// 3. `style` 内联样式的 `float:left|right`
    /// 只输出归一化 class，不透传原始 style/class，保证幂等（二次 sanitize 结果不变）。
    private static func extractImageAlignment(attrMap: [String: String]) -> String? {
        let leftClasses: Set<String> = ["align-left", "alignleft", "left", "float-left", "floatleft", "image-left", "img-left", "align-l"]
        let rightClasses: Set<String> = ["align-right", "alignright", "right", "float-right", "floatright", "image-right", "img-right", "align-r"]
        let centerClasses: Set<String> = ["align-center", "aligncenter", "center", "image-center", "img-center", "align-c", "center-block", "block-center"]

        // 已归一化的受控类直接复用（幂等）
        if let classTokens = attrMap["class"]?.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init),
           let existing = classTokens.first(where: { $0.hasPrefix("paper-align-") }) {
            let suffix = existing.dropFirst("paper-align-".count)
            if suffix == "left" || suffix == "right" || suffix == "center" { return String(suffix) }
        }

        if let align = attrMap["align"]?.lowercased().trimmingCharacters(in: .whitespaces) {
            if align == "left" || align == "right" || align == "center" { return align }
            if align == "middle" { return "center" }
        }

        if let classTokens = attrMap["class"]?.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if classTokens.contains(where: leftClasses.contains) { return "left" }
            if classTokens.contains(where: rightClasses.contains) { return "right" }
            if classTokens.contains(where: centerClasses.contains) { return "center" }
        }

        if let style = attrMap["style"]?.lowercased() {
            if style.range(of: "float\\s*:\\s*left", options: .regularExpression) != nil { return "left" }
            if style.range(of: "float\\s*:\\s*right", options: .regularExpression) != nil { return "right" }
            // margin 左右同时 auto 的居中与阅读器默认样式一致，无需专门归一化
        }

        return nil
    }

    private static func isSafeHeadingID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || "-_:.".contains(character)
        }
    }

    private static func isSafeFragmentReference(_ value: String) -> Bool {
        guard value.count <= 500, value.first == "#", value.count > 1 else { return false }
        return !value.unicodeScalars.contains(where: { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ||
            CharacterSet.controlCharacters.contains(scalar)
        })
    }

    static func safeRemoteURL(_ rawValue: String, baseURL: URL?) -> URL? {
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
