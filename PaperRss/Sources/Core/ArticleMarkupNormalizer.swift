import Foundation
import Markdown

/// 负责将各种来源格式（原生 HTML、转义 HTML、Markdown、混合格式、纯文本）
/// 统一规范化为受控的 markup，供正文提取与清洗管线消费。
enum ArticleMarkupNormalizer: Sendable {

    /// 内容格式分类
    enum ContentFormat: Sendable, Equatable {
        case html
        case escapedHTML
        case markdown
        case mixed
        case plainText
    }

    /// 诊断计数器：用于测试阶段证明 Fast Path 实际未构建 Markdown AST
    nonisolated(unsafe) static var diagnosticASTConstructionCount: Int = 0

    static func resetDiagnosticCounters() {
        diagnosticASTConstructionCount = 0
    }

    /// 识别输入文本的内容格式
    static func detectFormat(_ source: String) -> ContentFormat {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plainText }

        // 1. 检查是否为 XML / JSON 转义的 HTML
        if isEscapedHTML(trimmed) {
            return .escapedHTML
        }

        let hasHTML = containsHTMLStructure(trimmed)
        let hasMarkdown = containsMarkdownStructure(trimmed)

        if hasHTML && hasMarkdown {
            if containsUnescapedMarkdownInText(trimmed) {
                return .mixed
            } else {
                return .html
            }
        } else if hasHTML {
            return .html
        } else if hasMarkdown {
            return .markdown
        } else {
            return .plainText
        }
    }

    /// 将任意支持的 markup 内容规范化为供提取器消费的 markup
    /// 注意：本方法只负责结构规范化，不提前调用 sanitizer，完整保留 class 和选择线索
    static func normalize(_ source: String, baseURL: URL? = nil) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let format = detectFormat(trimmed)

        switch format {
        case .html:
            // Fast path: 明确的原生 HTML 不构建 Markdown AST，原样返回保留所有选择线索
            return source

        case .escapedHTML:
            // 单次受控实体解码，禁止递归解码
            let singleDecoded = decodeStructuralHTMLEntities(trimmed)
            let subFormat = detectFormat(singleDecoded)
            if subFormat == .markdown {
                return renderPureMarkdown(singleDecoded)
            } else if subFormat == .mixed {
                return normalizeMixedContent(singleDecoded)
            } else {
                return singleDecoded
            }

        case .markdown:
            return renderPureMarkdown(trimmed)

        case .mixed:
            return normalizeMixedContent(trimmed)

        case .plainText:
            let escaped = escapeHTMLText(trimmed)
            let paragraphs = escaped
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
                .joined()
            return paragraphs.isEmpty ? "<p>\(escaped)</p>" : paragraphs
        }
    }

    // MARK: - Markdown AST Rendering

    private static func renderPureMarkdown(_ source: String) -> String {
        diagnosticASTConstructionCount += 1
        let document = Document(parsing: source, options: [.parseBlockDirectives, .parseSymbolLinks])
        var renderer = ArticleMarkdownHTMLRenderer(isInlineOnly: false)
        return renderer.render(document)
    }

    // MARK: - Quote-Aware Linear Scanner for Mixed HTML/Markdown

    private static func normalizeMixedContent(_ html: String) -> String {
        var result = ""
        var cursor = html.startIndex
        var tagStack: [String] = []

        let protectedTags: Set<String> = ["pre", "code", "kbd", "script", "style", "noscript", "svg"]
        let inlineParentTags: Set<String> = [
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "figcaption", "th", "td",
            "a", "span", "strong", "b", "em", "i", "u", "s", "del", "mark", "small", "sub", "sup"
        ]
        let voidTags: Set<String> = ["img", "br", "hr", "source", "input", "meta", "link"]

        while cursor < html.endIndex {
            guard let tagStart = html[cursor...].firstIndex(of: "<") else {
                // 剩余全部为文本
                let trailingText = String(html[cursor...])
                result += processTextRun(trailingText, tagStack: tagStack, protectedTags: protectedTags, inlineParentTags: inlineParentTags)
                break
            }

            // 处理标签前的文本段
            if tagStart > cursor {
                let textSegment = String(html[cursor..<tagStart])
                result += processTextRun(textSegment, tagStack: tagStack, protectedTags: protectedTags, inlineParentTags: inlineParentTags)
            }

            // 扫描 HTML 标签（Quote-Aware，跳过属性中的引号）
            var tagEnd = tagStart
            var inSingleQuote = false
            var inDoubleQuote = false
            var scanIndex = html.index(after: tagStart)

            // 处理注释 <!-- ... -->
            if html[scanIndex...].hasPrefix("!--") {
                if let commentEnd = html[scanIndex...].range(of: "-->") {
                    tagEnd = commentEnd.upperBound
                    cursor = tagEnd
                    result += String(html[tagStart..<tagEnd])
                    continue
                }
            }

            while scanIndex < html.endIndex {
                let char = html[scanIndex]
                if char == "\"" && !inSingleQuote {
                    inDoubleQuote.toggle()
                } else if char == "'" && !inDoubleQuote {
                    inSingleQuote.toggle()
                } else if char == ">" && !inSingleQuote && !inDoubleQuote {
                    tagEnd = html.index(after: scanIndex)
                    break
                }
                scanIndex = html.index(after: scanIndex)
            }

            if tagEnd == tagStart {
                // 未找到闭合 >，将剩余文本作为普通文本追加
                result += String(html[tagStart...])
                break
            }

            let fullTag = String(html[tagStart..<tagEnd])
            cursor = tagEnd
            result += fullTag

            // 解析标签名称与栈维护
            if let parsed = parseTag(fullTag) {
                if parsed.isClosing {
                    if let lastIndex = tagStack.lastIndex(of: parsed.name) {
                        tagStack.removeSubrange(lastIndex...)
                    }
                } else if !parsed.isSelfClosing && !voidTags.contains(parsed.name) {
                    tagStack.append(parsed.name)
                }
            }
        }

        return result
    }

    private struct ParsedTag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private static func parseTag(_ tag: String) -> ParsedTag? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") && trimmed.hasSuffix(">") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return nil }

        let isClosing = inner.hasPrefix("/")
        let withoutSlash = isClosing ? inner.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines) : inner
        let isSelfClosing = withoutSlash.hasSuffix("/")
        let cleanNameAndAttrs = isSelfClosing ? withoutSlash.dropLast().trimmingCharacters(in: .whitespacesAndNewlines) : withoutSlash

        let tagName = cleanNameAndAttrs.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }).lowercased()
        guard !tagName.isEmpty else { return nil }

        return ParsedTag(name: tagName, isClosing: isClosing, isSelfClosing: isSelfClosing)
    }

    private static func processTextRun(
        _ text: String,
        tagStack: [String],
        protectedTags: Set<String>,
        inlineParentTags: Set<String>
    ) -> String {
        // 1. 如果在受保护的 pre/code/kbd/script 标签中，绝不转换 Markdown
        if tagStack.contains(where: { protectedTags.contains($0) }) {
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, containsMarkdownStructure(trimmed) else {
            return text
        }

        let isInsideInlineContainer = tagStack.contains(where: { inlineParentTags.contains($0) })

        if isInsideInlineContainer {
            // 在 <p> 或其他内联容器内：只执行 inline Markdown 转换，严禁输出块级 heading/list/table
            diagnosticASTConstructionCount += 1
            let document = Document(parsing: trimmed, options: [.parseBlockDirectives, .parseSymbolLinks])
            var renderer = ArticleMarkdownHTMLRenderer(isInlineOnly: true)
            let rendered = renderer.render(document).trimmingCharacters(in: .whitespacesAndNewlines)

            let leadingSpaces = String(text.prefix(while: { $0.isWhitespace || $0.isNewline }))
            let trailingReversed = text.reversed().prefix(while: { $0.isWhitespace || $0.isNewline })
            let trailingSpaces = String(trailingReversed.reversed())
            return leadingSpaces + rendered + trailingSpaces
        } else {
            // 在顶级或 div/article 块级容器内：允许执行完整块级 Markdown 转换
            // 清理 HTML 排版带来的多余缩进，但保留 fenced code 块内的原始缩进
            let cleanedLines = stripLayoutIndentationPreservingFencedCode(text)

            diagnosticASTConstructionCount += 1
            let document = Document(parsing: cleanedLines, options: [.parseBlockDirectives, .parseSymbolLinks])
            var renderer = ArticleMarkdownHTMLRenderer(isInlineOnly: false)
            let rendered = renderer.render(document).trimmingCharacters(in: .whitespacesAndNewlines)

            let leadingSpaces = String(text.prefix(while: { $0.isWhitespace || $0.isNewline }))
            let trailingReversed = text.reversed().prefix(while: { $0.isWhitespace || $0.isNewline })
            let trailingSpaces = String(trailingReversed.reversed())
            return leadingSpaces + rendered + trailingSpaces
        }
    }

    /// 清理 HTML 结构排版缩进，同时完整保留 ``` fenced code 块内部的真实代码缩进
    private static func stripLayoutIndentationPreservingFencedCode(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var inFencedCode = false
        var resultLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFencedCode.toggle()
                resultLines.append(trimmed)
            } else if inFencedCode {
                // 代码块内部保留原始缩进
                resultLines.append(line)
            } else {
                resultLines.append(trimmed)
            }
        }
        return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Format Detection Helpers

    private static func isEscapedHTML(_ text: String) -> Bool {
        let pattern = "(?i)&lt;\\s*/?\\s*(?:p|div|article|section|h[1-6]|ul|ol|li|blockquote|table|pre|code|img|a|span|figure|figcaption|header|footer|nav|main|video|audio|picture|source|br|hr)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.count >= 1
    }

    private static func containsHTMLStructure(_ text: String) -> Bool {
        let blockPattern = "(?is)</?(?:p|div|article|section|h[1-6]|ul|ol|li|blockquote|table|pre|code|kbd|figure|figcaption|aside|header|footer|nav|main|a|img|span|strong|b|em|i|u|s|del|mark|small|sub|sup|video|audio|picture|source|br|hr)\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: blockPattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func containsMarkdownStructure(_ text: String) -> Bool {
        let patterns = [
            "(?m)^\\s*#{1,6}\\s+\\S+",                                // 标题 # Heading
            "(?m)^\\s*(?:\\*|-|\\+|\\d+\\.)\\s+\\S+",                // 列表项
            "(?m)^\\s*>\\s+\\S+",                                    // 引用块
            "(?m)^\\s*(?:```|~~~)",                                  // Fenced code block
            "(?m)^\\s*(?:---|_{3,}|\\*{3,})\\s*$",                   // 分割线
            "(?m)^\\|?(?:\\s*:?-+:?\\s*\\|)+\\s*$",                  // GFM 表格分隔行
            "!?\\[[^\\]\\r\\n]+\\]\\([^\\)\\r\\n]+\\)",              // 链接与图片 [text](url)
            "(?<!\\\\)\\*\\*[^*\\r\\n]+?\\*\\*",                     // **粗体**
            "(?<!\\\\)~~[^~\\r\\n]+?~~",                             // ~~删除线~~
            "(?<![\\\\*\\w])\\*[^*\\r\\n\\s]+?\\*(?![*\\w])",        // *斜体强调*
            "(?<!\\\\)`+[^`\\r\\n]+`+"                               // `内联代码`
        ]

        let fullPattern = patterns.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: fullPattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func containsUnescapedMarkdownInText(_ html: String) -> Bool {
        var textSegments: [String] = []
        var cursor = html.startIndex
        var inSingleQuote = false
        var inDoubleQuote = false
        var tagStack: [String] = []
        let protectedTags: Set<String> = ["pre", "code", "kbd", "script", "style", "noscript", "svg"]
        let voidTags: Set<String> = ["img", "br", "hr", "source", "input", "meta", "link"]

        while cursor < html.endIndex {
            guard let tagStart = html[cursor...].firstIndex(of: "<") else {
                if !tagStack.contains(where: { protectedTags.contains($0) }) {
                    textSegments.append(String(html[cursor...]))
                }
                break
            }

            if tagStart > cursor {
                if !tagStack.contains(where: { protectedTags.contains($0) }) {
                    textSegments.append(String(html[cursor..<tagStart]))
                }
            }

            var scanIndex = html.index(after: tagStart)
            var tagEnd = tagStart
            inSingleQuote = false
            inDoubleQuote = false

            if html[scanIndex...].hasPrefix("!--") {
                if let commentEnd = html[scanIndex...].range(of: "-->") {
                    cursor = commentEnd.upperBound
                    continue
                }
            }

            while scanIndex < html.endIndex {
                let char = html[scanIndex]
                if char == "\"" && !inSingleQuote {
                    inDoubleQuote.toggle()
                } else if char == "'" && !inDoubleQuote {
                    inSingleQuote.toggle()
                } else if char == ">" && !inSingleQuote && !inDoubleQuote {
                    tagEnd = html.index(after: scanIndex)
                    break
                }
                scanIndex = html.index(after: scanIndex)
            }

            if tagEnd == tagStart {
                if !tagStack.contains(where: { protectedTags.contains($0) }) {
                    textSegments.append(String(html[tagStart...]))
                }
                break
            }

            let fullTag = String(html[tagStart..<tagEnd])
            cursor = tagEnd

            if let parsed = parseTag(fullTag) {
                if parsed.isClosing {
                    if let lastIndex = tagStack.lastIndex(of: parsed.name) {
                        tagStack.removeSubrange(lastIndex...)
                    }
                } else if !parsed.isSelfClosing && !voidTags.contains(parsed.name) {
                    tagStack.append(parsed.name)
                }
            }
        }

        let combinedText = textSegments.joined(separator: "\n")
        return containsMarkdownStructure(combinedText)
    }

    // MARK: - Controlled Single-Pass Entity Decoding

    private static func decodeStructuralHTMLEntities(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    private static func escapeHTMLText(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Markdown AST to Controlled HTML Renderer

private struct ArticleMarkdownHTMLRenderer: MarkupVisitor {
    typealias Result = String

    let isInlineOnly: Bool

    init(isInlineOnly: Bool = false) {
        self.isInlineOnly = isInlineOnly
    }

    mutating func render(_ markup: any Markup) -> String {
        return visit(markup)
    }

    mutating func defaultVisit(_ markup: any Markup) -> String {
        var result = ""
        for child in markup.children {
            result += visit(child)
        }
        return result
    }

    mutating func visitDocument(_ document: Document) -> String {
        return defaultVisit(document)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        if isInlineOnly {
            return defaultVisit(blockQuote)
        }
        return "<blockquote>\(defaultVisit(blockQuote))</blockquote>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        if isInlineOnly {
            return "<code>\(escapeHTML(codeBlock.code))</code>"
        }
        let escapedCode = escapeHTML(codeBlock.code)
        if let language = codeBlock.language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let escapedLang = escapeAttribute(language.trimmingCharacters(in: .whitespacesAndNewlines))
            return "<pre><code class=\"language-\(escapedLang)\">\(escapedCode)</code></pre>"
        } else {
            return "<pre><code>\(escapedCode)</code></pre>"
        }
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        return html.rawHTML
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        if isInlineOnly {
            // 内联模式下不生成 <hN> 块级标签，仅保留内部文本，防止非法嵌套
            return defaultVisit(heading)
        }
        let level = max(1, min(6, heading.level))
        return "<h\(level)>\(defaultVisit(heading))</h\(level)>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        if isInlineOnly { return "" }
        return "<hr>"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        if isInlineOnly { return defaultVisit(orderedList) }
        let start = orderedList.startIndex
        let startAttr = start > 1 ? " start=\"\(start)\"" : ""
        return "<ol\(startAttr)>\(defaultVisit(orderedList))</ol>"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        if isInlineOnly { return defaultVisit(unorderedList) }
        return "<ul>\(defaultVisit(unorderedList))</ul>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        if isInlineOnly { return defaultVisit(listItem) }
        var content = ""
        for child in listItem.children {
            if let para = child as? Paragraph {
                content += defaultVisit(para)
            } else {
                content += visit(child)
            }
        }
        return "<li>\(content)</li>"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = defaultVisit(paragraph)
        if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        if isInlineOnly {
            return inner
        }
        return "<p>\(inner)</p>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        return "<code>\(escapeHTML(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        return "<em>\(defaultVisit(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        return "<strong>\(defaultVisit(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        return "<del>\(defaultVisit(strikethrough))</del>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        return inlineHTML.rawHTML
    }

    mutating func visitLink(_ link: Link) -> String {
        let destination = link.destination ?? ""
        let titleAttr = link.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        return "<a href=\"\(escapeAttribute(destination))\"\(titleAttr)>\(defaultVisit(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let source = image.source ?? ""
        let altText = escapeAttribute(image.plainText)
        let titleAttr = image.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        return "<img src=\"\(escapeAttribute(source))\" alt=\"\(altText)\"\(titleAttr)>"
    }

    mutating func visitText(_ text: Text) -> String {
        return escapeHTML(text.string)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        return "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        return "<br>"
    }

    mutating func visitTable(_ table: Table) -> String {
        if isInlineOnly { return defaultVisit(table) }
        return "<table>\(defaultVisit(table))</table>"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        if isInlineOnly { return defaultVisit(tableHead) }
        return "<thead>\(defaultVisit(tableHead))</thead>"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        if isInlineOnly { return defaultVisit(tableBody) }
        return "<tbody>\(defaultVisit(tableBody))</tbody>"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        if isInlineOnly { return defaultVisit(tableRow) }
        return "<tr>\(defaultVisit(tableRow))</tr>"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        if isInlineOnly { return defaultVisit(tableCell) }
        let tag = tableCell.parent is Table.Head ? "th" : "td"
        return "<\(tag)>\(defaultVisit(tableCell))</\(tag)>"
    }

    private func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func escapeAttribute(_ text: String) -> String {
        return escapeHTML(text)
    }
}
