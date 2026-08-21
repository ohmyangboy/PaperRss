import Foundation

/// Builds ordinary Markdown files that can be saved directly into an Obsidian vault.
///
/// The exporter deliberately has no file-system or UI responsibilities. AppKit owns
/// the save panel, while this type keeps the document format independently testable.
public enum MarkdownExporter {
    public static func render(
        entry: Entry,
        feedTitle: String?,
        html: String?,
        plainText: String,
        sourceURL: URL?
    ) -> String {
        var metadata: [(key: String, value: String)] = [
            ("title", yamlQuoted(entry.title)),
            ("paper_rss_id", yamlQuoted(entry.id)),
            ("read", entry.isRead ? "true" : "false"),
            ("starred", entry.isStarred ? "true" : "false")
        ]

        if let feedTitle = nonEmpty(feedTitle) {
            metadata.append(("feed", yamlQuoted(feedTitle)))
        }
        if let author = nonEmpty(entry.author) {
            metadata.append(("author", yamlQuoted(author)))
        }
        if let publishedAt = entry.publishedAt {
            metadata.append(("date", yamlQuoted(iso8601String(publishedAt))))
        }
        if let sourceURL {
            metadata.append(("url", yamlQuoted(sourceURL.absoluteString)))
        }

        let frontmatter = metadata
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        let body: String
        if let html = html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sanitized = ArticleExtractor.sanitizedHTML(html, baseURL: sourceURL)
            let renderedHTML = Renderer.render(sanitized)
            body = renderedHTML.isEmpty ? renderPlainText(plainText) : renderedHTML
        } else {
            body = renderPlainText(plainText)
        }

        return "---\n\(frontmatter)\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Returns a filesystem-safe default name while preserving readable Unicode titles.
    public static func suggestedFilename(for title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:<>\"|?*\n\r\t")
        var result = title.unicodeScalars.map { invalidCharacters.contains($0) ? "-" : String($0) }.joined()
        result = result.replacingOccurrences(of: "[[:space:]]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        if result.isEmpty { result = "PaperRss Article" }
        if result.count > 120 {
            result = String(result.prefix(120)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        }
        return result + ".md"
    }

    /// Returns the first filename that does not collide with the supplied directory entries.
    /// The suffix starts at 2 so the first note keeps the readable title unchanged.
    public static func nextAvailableFilename(for title: String, existingNames: Set<String>) -> String {
        let existing = Set(existingNames.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let base = suggestedFilename(for: title)
        guard existing.contains(base.precomposedStringWithCanonicalMapping.lowercased()) else {
            return base
        }

        let stem = String(base.dropLast(".md".count))
        var suffix = 2
        while true {
            let candidate = "\(stem)-\(suffix).md"
            if !existing.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func yamlQuoted(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(normalized)\""
    }

    private static func renderPlainText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        return normalized
            .components(separatedBy: "\n")
            .map { line in
                if line.range(of: "^\\s{0,3}(#{1,6}|>|[-+*]\\s|\\d+[.]\\s)", options: .regularExpression) != nil {
                    return "\\\(line)"
                }
                return line
            }
            .joined(separator: "\n")
    }

    private indirect enum Node {
        case root([Node])
        case element(name: String, attributes: [String: String], children: [Node])
        case text(String)
    }

    private struct Frame {
        let name: String
        let attributes: [String: String]
        var children: [Node]
    }

    private enum Renderer {
        private static let voidTags: Set<String> = ["br", "hr", "img", "source", "audio", "video"]
        private static let ignoredTags: Set<String> = ["script", "style", "noscript", "iframe", "form", "object", "embed", "meta", "link", "base", "template", "nav", "footer", "aside"]

        static func render(_ html: String) -> String {
            let root = parse(html)
            let rendered: String
            if case let .root(children) = root {
                rendered = children.map { render($0, context: .init()) }.joined()
            } else {
                rendered = ""
            }
            return normalize(rendered)
        }

        private struct Context {
            var inPre = false
            var blockquoteDepth = 0
        }

        private static func render(_ node: Node, context: Context) -> String {
            switch node {
            case let .root(children):
                return children.map { render($0, context: context) }.joined()
            case let .text(value):
                return decodeEntities(value)
            case let .element(name, attributes, children):
                if ignoredTags.contains(name) { return "" }

                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    let level = Int(name.dropFirst()) ?? 1
                    let content = inlineText(children, context: context)
                    return content.isEmpty ? "" : "\n\n\(String(repeating: "#", count: level)) \(content)\n\n"
                case "p", "div", "section", "article", "figure", "figcaption", "dt", "dd":
                    let content = renderChildren(children, context: context).trimmedMarkdown
                    return content.isEmpty ? "" : "\n\n\(content)\n\n"
                case "br":
                    return "\n"
                case "hr":
                    return "\n\n---\n\n"
                case "strong", "b":
                    let content = inlineText(children, context: context)
                    return content.isEmpty ? "" : "**\(content)**"
                case "em", "i":
                    let content = inlineText(children, context: context)
                    return content.isEmpty ? "" : "*\(content)*"
                case "del", "s":
                    let content = inlineText(children, context: context)
                    return content.isEmpty ? "" : "~~\(content)~~"
                case "code":
                    guard !context.inPre else { return renderChildren(children, context: context) }
                    return inlineCode(inlineText(children, context: context))
                case "pre":
                    let code = renderChildren(children, context: Context(inPre: true, blockquoteDepth: context.blockquoteDepth))
                        .trimmingCharacters(in: .newlines)
                    guard !code.isEmpty else { return "" }
                    let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
                    return "\n\n\(fence)\n\(code)\n\(fence)\n\n"
                case "blockquote":
                    let content = renderChildren(children, context: Context(inPre: context.inPre, blockquoteDepth: context.blockquoteDepth + 1)).trimmedMarkdown
                    guard !content.isEmpty else { return "" }
                    let prefix = String(repeating: "> ", count: context.blockquoteDepth + 1)
                    let quoted = content.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { line in line.isEmpty ? ">" : "\(prefix)\(line)" }
                        .joined(separator: "\n")
                    return "\n\n\(quoted)\n\n"
                case "a":
                    let content = inlineText(children, context: context)
                    guard !content.isEmpty else { return attributes["href"] ?? "" }
                    guard let href = attributes["href"], !href.isEmpty else { return content }
                    let destination = href.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: ">", with: "%3E")
                    return "[\(content)](<\(destination)>)"
                case "img":
                    guard let src = attributes["src"], !src.isEmpty else { return "" }
                    let alt = (attributes["alt"] ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "]", with: "\\]")
                    let destination = src.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: ">", with: "%3E")
                    return "![\(alt)](<\(destination)>)"
                case "ul":
                    return renderList(children, ordered: false, depth: 0)
                case "ol":
                    return renderList(children, ordered: true, depth: 0)
                case "li":
                    return renderChildren(children, context: context)
                case "table":
                    return renderTable(children, context: context)
                case "tr", "th", "td", "thead", "tbody", "tfoot", "dl":
                    return renderChildren(children, context: context)
                default:
                    return renderChildren(children, context: context)
                }
            }
        }

        private static func renderChildren(_ children: [Node], context: Context) -> String {
            children.map { render($0, context: context) }.joined()
        }

        private static func inlineText(_ children: [Node], context: Context) -> String {
            renderChildren(children, context: context)
                .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func renderList(_ children: [Node], ordered: Bool, depth: Int) -> String {
            let items = children.compactMap { node -> (String, [Node])? in
                guard case let .element(name, _, itemChildren) = node, name == "li" else { return nil }
                return (name, itemChildren)
            }
            guard !items.isEmpty else { return "" }

            var result = "\n\n"
            for (index, (_, itemChildren)) in items.enumerated() {
                let nestedLists = itemChildren.filter {
                    guard case let .element(name, _, _) = $0 else { return false }
                    return name == "ul" || name == "ol"
                }
                let contentNodes = itemChildren.filter {
                    guard case let .element(name, _, _) = $0 else { return true }
                    return name != "ul" && name != "ol"
                }
                let content = renderChildren(contentNodes, context: .init()).trimmedMarkdown
                let marker = ordered ? "\(index + 1)." : "-"
                let indent = String(repeating: "  ", count: depth)
                if content.isEmpty {
                    result += "\(indent)\(marker)\n"
                } else {
                    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                    result += "\(indent)\(marker) \(lines.first ?? "")\n"
                    for line in lines.dropFirst() {
                        result += "\(indent)  \(line)\n"
                    }
                }
                for nested in nestedLists {
                    guard case let .element(name, _, nestedChildren) = nested else { continue }
                    result += renderList(nestedChildren, ordered: name == "ol", depth: depth + 1)
                }
            }
            return result + "\n"
        }

        private static func renderTable(_ children: [Node], context: Context) -> String {
            let rows = tableRows(children)
            guard !rows.isEmpty else { return "" }
            let renderedRows = rows.map { cells in
                "| " + cells.map { renderChildren($0, context: context).trimmedMarkdown.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            guard renderedRows.count > 1 else { return "\n\n\(renderedRows[0])\n\n" }
            let columnCount = rows[0].count
            let separator = "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
            return "\n\n\(renderedRows[0])\n\(separator)\n" + renderedRows.dropFirst().joined(separator: "\n") + "\n\n"
        }

        private static func tableRows(_ nodes: [Node]) -> [[[Node]]] {
            var rows: [[[Node]]] = []
            for node in nodes {
                guard case let .element(name, _, children) = node else { continue }
                if name == "tr" {
                    let cells = children.compactMap { child -> [Node]? in
                        guard case let .element(cellName, _, cellChildren) = child, cellName == "th" || cellName == "td" else { return nil }
                        return cellChildren
                    }
                    if !cells.isEmpty { rows.append(cells) }
                } else if name == "thead" || name == "tbody" || name == "tfoot" {
                    rows.append(contentsOf: tableRows(children))
                }
            }
            return rows
        }

        private static func inlineCode(_ value: String) -> String {
            guard !value.isEmpty else { return "" }
            let fence = String(repeating: "`", count: max(1, longestRun(of: "`", in: value) + 1))
            let padding = value.hasPrefix("`") || value.hasSuffix("`") ? " " : ""
            return "\(fence)\(padding)\(value)\(padding)\(fence)"
        }

        private static func longestRun(of character: Character, in value: String) -> Int {
            var longest = 0
            var current = 0
            for item in value {
                if item == character {
                    current += 1
                    longest = max(longest, current)
                } else {
                    current = 0
                }
            }
            return longest
        }

        private static func normalize(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func parse(_ html: String) -> Node {
            var stack = [Frame(name: "root", attributes: [:], children: [])]
            let tagPattern = "(?is)<\\/?([a-z][a-z0-9]*)\\b([^>]*)>"
            guard let expression = try? NSRegularExpression(pattern: tagPattern) else { return .root([.text(html)]) }
            let range = NSRange(html.startIndex..., in: html)
            var cursor = html.startIndex

            func append(_ node: Node) {
                stack[stack.count - 1].children.append(node)
            }

            func closeFrame(at index: Int) {
                guard index > 0, index < stack.count else { return }
                while stack.count > index {
                    let frame = stack.removeLast()
                    stack[stack.count - 1].children.append(.element(name: frame.name, attributes: frame.attributes, children: frame.children))
                }
            }

            for match in expression.matches(in: html, range: range) {
                guard let tagRange = Range(match.range, in: html),
                      let nameRange = Range(match.range(at: 1), in: html),
                      let attributeRange = Range(match.range(at: 2), in: html) else { continue }
                if cursor < tagRange.lowerBound {
                    append(.text(String(html[cursor..<tagRange.lowerBound])))
                }
                cursor = tagRange.upperBound

                let rawTag = String(html[tagRange])
                let name = String(html[nameRange]).lowercased()
                let isClosing = rawTag.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
                if isClosing {
                    if let index = stack.lastIndex(where: { $0.name == name }) {
                        closeFrame(at: index)
                    }
                    continue
                }

                if ignoredTags.contains(name) {
                    continue
                }
                let attributes = parseAttributes(String(html[attributeRange]))
                let isSelfClosing = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>") || voidTags.contains(name)
                if isSelfClosing {
                    append(.element(name: name, attributes: attributes, children: []))
                } else {
                    stack.append(Frame(name: name, attributes: attributes, children: []))
                }
            }
            if cursor < html.endIndex {
                append(.text(String(html[cursor...])))
            }
            while stack.count > 1 {
                let frame = stack.removeLast()
                stack[stack.count - 1].children.append(.element(name: frame.name, attributes: frame.attributes, children: frame.children))
            }
            return .root(stack[0].children)
        }

        private static func parseAttributes(_ source: String) -> [String: String] {
            let pattern = "(?is)([a-z_:][a-z0-9_.:-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
            var result: [String: String] = [:]
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let valueIndex = [2, 3, 4].first { match.range(at: $0).location != NSNotFound }
                guard let valueIndex,
                      let valueRange = Range(match.range(at: valueIndex), in: source) else { continue }
                result[String(source[keyRange]).lowercased()] = decodeEntities(String(source[valueRange]))
            }
            return result
        }

        private static func decodeEntities(_ value: String) -> String {
            var result = value
            let replacements = [
                "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                "&quot;": "\"", "&apos;": "'", "&#39;": "'"
            ]
            for (entity, replacement) in replacements {
                result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
            }
            guard let expression = try? NSRegularExpression(pattern: "(?i)&#x([0-9a-f]+);|&#([0-9]+);") else { return result }
            let range = NSRange(result.startIndex..., in: result)
            let matches = expression.matches(in: result, range: range).reversed()
            for match in matches {
                guard let fullRange = Range(match.range, in: result) else { continue }
                let hex: String?
                if let hexRange = Range(match.range(at: 1), in: result) {
                    hex = String(result[hexRange])
                } else {
                    hex = nil
                }
                let decimal: String?
                if let decimalRange = Range(match.range(at: 2), in: result) {
                    decimal = String(result[decimalRange])
                } else {
                    decimal = nil
                }
                let scalarValue = hex.flatMap { UInt32($0, radix: 16) } ?? decimal.flatMap { UInt32($0) }
                if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                    result.replaceSubrange(fullRange, with: String(scalar))
                }
            }
            return result
        }
    }
}

private extension String {
    var trimmedMarkdown: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    }
}
