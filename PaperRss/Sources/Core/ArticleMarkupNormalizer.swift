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
        // 公式内部的 *、_、#、` 等字符会伪造 markdown 结构信号（自指误判），
        // 检测前先剥离全部公式，仅以真实文本特征判定。
        let signalText = ArticleMathDetector.strippingFormulas(in: trimmed)
        let hasMarkdown = containsMarkdownStructure(signalText)

        if hasHTML && hasMarkdown {
            if containsUnescapedMarkdownInText(signalText) {
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
                return renderPureMarkdown(singleDecoded, baseURL: baseURL)
            } else if subFormat == .mixed {
                return normalizeMixedContent(singleDecoded, baseURL: baseURL)
            } else {
                return singleDecoded
            }

        case .markdown:
            return renderPureMarkdown(trimmed, baseURL: baseURL)

        case .mixed:
            return normalizeMixedContent(trimmed, baseURL: baseURL)

        case .plainText:
            let escaped = escapeHTML(trimmed)
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

    private static func renderPureMarkdown(_ source: String, baseURL: URL? = nil) -> String {
        diagnosticASTConstructionCount += 1
        // 公式先占位再还原：防止 swift-markdown 把公式内部的 *、_、\、{} 误解析为强调/转义
        let shielded = ArticleMathDetector.shieldFormulas(in: source)
        // 图片对齐/尺寸语法（wiki 嵌入、kramdown 属性、Typora 尺寸）先展开为受控 <img>
        let expanded = expandingImageEmbeds(in: shielded.shieldedText, baseURL: baseURL)
        let document = Document(parsing: expanded, options: [.parseBlockDirectives, .parseSymbolLinks])
        var renderer = ArticleMarkdownHTMLRenderer(isInlineOnly: false)
        let rendered = renderer.render(document)
        return ArticleMathDetector.unshieldFormulas(rendered, tokens: shielded.tokens)
    }

    // MARK: - Quote-Aware Linear Scanner for Mixed HTML/Markdown

    private static func normalizeMixedContent(_ html: String, baseURL: URL? = nil) -> String {
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
                result += processTextRun(trailingText, tagStack: tagStack, protectedTags: protectedTags, inlineParentTags: inlineParentTags, baseURL: baseURL)
                break
            }

            // 处理标签前的文本段
            if tagStart > cursor {
                let textSegment = String(html[cursor..<tagStart])
                result += processTextRun(textSegment, tagStack: tagStack, protectedTags: protectedTags, inlineParentTags: inlineParentTags, baseURL: baseURL)
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
        inlineParentTags: Set<String>,
        baseURL: URL?
    ) -> String {
        // 1. 如果在受保护的 pre/code/kbd/script 标签中，绝不转换 Markdown
        if tagStack.contains(where: { protectedTags.contains($0) }) {
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 结构检测先剥离公式：公式内部的 *、#、` 等字符不能作为 markdown 转换依据
        guard !trimmed.isEmpty,
              containsMarkdownStructure(ArticleMathDetector.strippingFormulas(in: trimmed)) else {
            return text
        }

        let isInsideInlineContainer = tagStack.contains(where: { inlineParentTags.contains($0) })
        let shielded = ArticleMathDetector.shieldFormulas(in: trimmed)

        if isInsideInlineContainer {
            // 在 <p> 或其他内联容器内：只执行 inline Markdown 转换，严禁输出块级 heading/list/table
            diagnosticASTConstructionCount += 1
            let expanded = expandingImageEmbeds(in: shielded.shieldedText, baseURL: baseURL)
            let document = Document(parsing: expanded, options: [.parseBlockDirectives, .parseSymbolLinks])
            var renderer = ArticleMarkdownHTMLRenderer(isInlineOnly: true)
            let rendered = renderer.render(document).trimmingCharacters(in: .whitespacesAndNewlines)
            let unshielded = ArticleMathDetector.unshieldFormulas(rendered, tokens: shielded.tokens)

            let leadingSpaces = String(text.prefix(while: { $0.isWhitespace || $0.isNewline }))
            let trailingReversed = text.reversed().prefix(while: { $0.isWhitespace || $0.isNewline })
            let trailingSpaces = String(trailingReversed.reversed())
            return leadingSpaces + unshielded + trailingSpaces
        } else {
            // 在顶级或 div/article 块级容器内：允许执行完整块级 Markdown 转换
            // 清理 HTML 排版带来的多余缩进，但保留 fenced code 块内的原始缩进
            let cleanedLines = stripLayoutIndentationPreservingFencedCode(shielded.shieldedText)
            let expanded = expandingImageEmbeds(in: cleanedLines, baseURL: baseURL)

            diagnosticASTConstructionCount += 1
            let document = Document(parsing: expanded, options: [.parseBlockDirectives, .parseSymbolLinks])
            var renderer = ArticleMarkdownHTMLRenderer(isInlineOnly: false)
            let rendered = renderer.render(document).trimmingCharacters(in: .whitespacesAndNewlines)
            let unshielded = ArticleMathDetector.unshieldFormulas(rendered, tokens: shielded.tokens)

            let leadingSpaces = String(text.prefix(while: { $0.isWhitespace || $0.isNewline }))
            let trailingReversed = text.reversed().prefix(while: { $0.isWhitespace || $0.isNewline })
            let trailingSpaces = String(trailingReversed.reversed())
            return leadingSpaces + unshielded + trailingSpaces
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

    // MARK: - Image Embed Expansion

    /// 在 Markdown AST 解析前，把图片对齐/尺寸类语法预展开为受控 <img> HTML。
    /// 支持的常见写法：
    /// - Obsidian wiki 嵌入：`![[name|40|left]]`、`![[name|300x200]]`、`![[https://…|right]]`
    /// - alt 管道参数：`![alt|40|left](url)`
    /// - kramdown/Pandoc 属性：`![alt](url){: .align-left}`、`![alt](url){width=40}`
    /// - Typora 尺寸：`![alt](url =40x)`、`![alt](url =40x30)`
    /// 分组规则：同一行内多图，或紧邻的纯图片行，归入同一 `paper-img-row` wrap 行容器
    /// （总宽不超正文宽度则同行展示，超出自然换行）；单图保持独立块（宽度尊重原文、整体居中）。
    /// fenced code 块内不转换；提取不到对齐/尺寸语义时保持原文，交给 AST 正常渲染。
    static func expandingImageEmbeds(in text: String, baseURL: URL?) -> String {
        guard text.contains("![") else { return text }

        var blocks: [String] = []
        var pendingRowImages: [String] = []
        var inFence = false

        func flushPendingRow() {
            guard !pendingRowImages.isEmpty else { return }
            if pendingRowImages.count == 1 {
                // 单图保持独立块：宽度尊重原文，默认整体居中（对齐 class 仍然生效）
                blocks.append(pendingRowImages[0])
            } else {
                // 多图归入同一 wrap 行容器
                blocks.append("<div class=\"paper-img-row\">" + pendingRowImages.joined() + "</div>")
            }
            pendingRowImages.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                flushPendingRow()
                inFence.toggle()
                blocks.append(line)
            } else if inFence {
                blocks.append(line)
            } else {
                let transformedLine = expandingImageEmbeds(inLine: line, baseURL: baseURL)
                if let lineImages = imageOnlyLineEmbeds(fromTransformedLine: transformedLine) {
                    pendingRowImages.append(contentsOf: lineImages)
                } else {
                    flushPendingRow()
                    blocks.append(transformedLine)
                }
            }
        }
        flushPendingRow()
        return blocks.joined(separator: "\n")
    }

    /// 判断一行转换结果是否完全由 <img> 标签构成（允许标签间空白）。
    /// 是则拆分出 img 标签数组供多图同行分组；否则返回 nil 走普通文本/行内混排路径。
    /// 约束：本转换器生成的 img 属性值均经 HTML 转义且 URL 百分号编码，标签内部不含 `>`。
    private static func imageOnlyLineEmbeds(fromTransformedLine line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<img") else { return nil }

        var images: [String] = []
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            while cursor < trimmed.endIndex, trimmed[cursor].isWhitespace {
                cursor = trimmed.index(after: cursor)
            }
            guard cursor < trimmed.endIndex else { break }
            guard trimmed[cursor...].hasPrefix("<img") else { return nil }
            guard let tagEnd = trimmed[cursor...].firstIndex(of: ">") else { return nil }
            images.append(String(trimmed[cursor...tagEnd]))
            cursor = trimmed.index(after: tagEnd)
        }
        return images.isEmpty ? nil : images
    }

    private static func expandingImageEmbeds(inLine line: String, baseURL: URL?) -> String {
        var result = line

        // 1. Obsidian wiki 嵌入（优先：与后续标准图片语法不重叠）
        result = replacingRegexMatches(
            in: result,
            pattern: "!\\[\\[([^\\]|\\r\\n]+?)(?:\\|([^\\]\\r\\n]*))?\\]\\]"
        ) { groups in
            let target = groups[0]
            let params = groups.count > 1 ? groups[1] : ""
            let parsed = imageEmbedParameters(fromPipeText: params)
            return imageEmbedHTML(
                source: target,
                alt: parsed.alt,
                width: parsed.width,
                alignment: parsed.alignment,
                baseURL: baseURL
            )
        }

        // 2. alt 管道参数 ![alt|40|left](url)
        result = replacingRegexMatches(
            in: result,
            pattern: "!\\[([^|\\]\\r\\n]*)\\|([^\\]\\r\\n]*)\\]\\(([^)\\r\\n]+)\\)"
        ) { groups in
            let parsed = imageEmbedParameters(fromPipeText: groups[1])
            guard parsed.width != nil || parsed.alignment != nil else { return nil }
            let combinedAlt = [groups[0], parsed.alt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return imageEmbedHTML(
                source: groups[2],
                alt: combinedAlt.isEmpty ? nil : combinedAlt,
                width: parsed.width,
                alignment: parsed.alignment,
                baseURL: baseURL
            )
        }

        // 3. kramdown/Pandoc 属性 ![alt](url){: .align-left} / {width=40}
        result = replacingRegexMatches(
            in: result,
            pattern: "!\\[([^\\]\\r\\n]*)\\]\\(([^)\\r\\n]+?)\\)\\s*\\{([^}\\r\\n]*)\\}"
        ) { groups in
            let parsed = imageEmbedAttributes(fromAttrText: groups[2])
            guard parsed.width != nil || parsed.alignment != nil else { return nil }
            return imageEmbedHTML(
                source: groups[1],
                alt: groups[0].isEmpty ? nil : groups[0],
                width: parsed.width,
                alignment: parsed.alignment,
                baseURL: baseURL
            )
        }

        // 4. Typora 尺寸 ![alt](url =40x30)
        result = replacingRegexMatches(
            in: result,
            pattern: "!\\[([^\\]\\r\\n]*)\\]\\(([^)\\r\\n]+?)\\s+=\\s*(\\d{1,5})(?:x(\\d{1,5}))?\\s*\\)"
        ) { groups in
            guard let width = Int(groups[2]), width > 0 else { return nil }
            return imageEmbedHTML(
                source: groups[1],
                alt: groups[0].isEmpty ? nil : groups[0],
                width: width,
                alignment: nil,
                baseURL: baseURL
            )
        }

        return result
    }

    /// 正则替换工具：transform 返回 nil 表示放弃该匹配（保留原文）。
    private static func replacingRegexMatches(
        in text: String,
        pattern: String,
        transform: ([String]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var cursor = text.startIndex
        var didModify = false

        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                if let groupRange = Range(match.range(at: index), in: text) {
                    groups.append(String(text[groupRange]))
                } else {
                    groups.append("")
                }
            }
            guard let replacement = transform(groups) else { return }
            didModify = true
            result += text[cursor..<matchRange.lowerBound]
            result += replacement
            cursor = matchRange.upperBound
        }

        guard didModify else { return text }
        result += text[cursor...]
        return result
    }

    /// 解析管道参数（`40|left`、`300x200`、`caption|40`）为宽度 / 对齐 / 备选 alt。
    private static func imageEmbedParameters(fromPipeText pipeText: String) -> (width: Int?, alignment: String?, alt: String?) {
        var width: Int?
        var alignment: String?
        var altParts: [String] = []

        for rawParam in pipeText.split(separator: "|") {
            let param = rawParam.trimmingCharacters(in: .whitespaces)
            guard !param.isEmpty else { continue }
            if let tokenAlignment = imageAlignment(fromToken: param) {
                alignment = tokenAlignment
            } else if let tokenWidth = parseImageSideLength(param) {
                width = tokenWidth
            } else {
                altParts.append(param)
            }
        }

        let alt = altParts.isEmpty ? nil : altParts.joined(separator: " ")
        return (width, alignment, alt)
    }

    /// 解析 kramdown/Pandoc 属性串（`width=40 align=left`、`.align-left #anchor`）。
    private static func imageEmbedAttributes(fromAttrText attrText: String) -> (width: Int?, alignment: String?) {
        var width: Int?
        var alignment: String?

        // key=value 形式：width=40 / width="40" / align=left
        let keyValuePattern = "([a-zA-Z]+)\\s*=\\s*\"?([^\"\\s}]+)\"?"
        if let keyValueRegex = try? NSRegularExpression(pattern: keyValuePattern) {
            let range = NSRange(attrText.startIndex..., in: attrText)
            keyValueRegex.enumerateMatches(in: attrText, range: range) { match, _, _ in
                guard let match,
                      let keyRange = Range(match.range(at: 1), in: attrText),
                      let valueRange = Range(match.range(at: 2), in: attrText) else { return }
                let key = attrText[keyRange].lowercased()
                let value = String(attrText[valueRange])
                if key == "width" || key == "w" {
                    width = parseImageSideLength(value) ?? width
                } else if key == "align" || key == "alignment" || key == "position" {
                    alignment = imageAlignment(fromToken: value) ?? alignment
                }
            }
        }

        // .class 形式：.align-left / .left
        let classPattern = "\\.([a-zA-Z0-9_-]+)"
        if let classRegex = try? NSRegularExpression(pattern: classPattern) {
            let range = NSRange(attrText.startIndex..., in: attrText)
            classRegex.enumerateMatches(in: attrText, range: range) { match, _, _ in
                guard let match,
                      let nameRange = Range(match.range(at: 1), in: attrText) else { return }
                alignment = imageAlignment(fromToken: String(attrText[nameRange])) ?? alignment
            }
        }

        return (width, alignment)
    }

    /// 解析尺寸标记：`40` / `40px` / `40x` / `40X30` → 宽度（高度交给阅读器按比例自适应）。
    private static func parseImageSideLength(_ value: String) -> Int? {
        var cleaned = value.trimmingCharacters(in: .whitespaces).lowercased()
        if cleaned.hasSuffix("px") {
            cleaned = String(cleaned.dropLast(2))
        }
        if cleaned.hasSuffix("x") {
            cleaned = String(cleaned.dropLast())
        }
        let widthPart = cleaned.split(whereSeparator: { $0 == "x" }).first ?? cleaned[...]
        guard let number = Int(widthPart), number > 0, number <= 10_000 else { return nil }
        return number
    }

    /// 对齐语义词表（与 ArticleExtractor.sanitizedAttributes 的归一化词表保持一致）。
    private static func imageAlignment(fromToken token: String) -> String? {
        let normalized = token.trimmingCharacters(in: .whitespaces).lowercased()
        let leftTokens: Set<String> = ["align-left", "alignleft", "left", "float-left", "floatleft", "image-left", "img-left", "align-l"]
        let rightTokens: Set<String> = ["align-right", "alignright", "right", "float-right", "floatright", "image-right", "img-right", "align-r"]
        let centerTokens: Set<String> = ["align-center", "aligncenter", "center", "image-center", "img-center", "align-c", "center-block", "block-center", "middle"]
        if leftTokens.contains(normalized) { return "left" }
        if rightTokens.contains(normalized) { return "right" }
        if centerTokens.contains(normalized) { return "center" }
        return nil
    }

    /// 解析嵌入目标为绝对 http(s) URL。
    /// 绝对 URL 直接复用；裸文件名/相对路径按 baseURL join（best-effort，wiki 裸名可能指向站点根）。
    /// 非 http(s) 协议一律拒绝。
    private static func resolvingImageEmbedTarget(_ target: String, baseURL: URL?) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return URL(string: trimmed)?.absoluteString
        }
        if lowercased.contains(":") {
            // data:、javascript:、file: 等其他协议一律不嵌入
            return nil
        }

        guard let baseURL else { return nil }

        // 逐段百分号编码，兼容 Obsidian 常见的含空格/中文文件名
        let hasLeadingSlash = trimmed.hasPrefix("/")
        let encodedPath = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let relativePath = (hasLeadingSlash ? "/" : "") + encodedPath
        guard !relativePath.isEmpty,
              let url = URL(string: relativePath, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    /// 生成受控 <img> HTML（属性逐一转义；width/class 交给 sanitizer 与阅读器 CSS 消费）。
    private static func imageEmbedHTML(
        source: String,
        alt: String?,
        width: Int?,
        alignment: String?,
        baseURL: URL?
    ) -> String? {
        guard let resolvedSource = resolvingImageEmbedTarget(source, baseURL: baseURL) else { return nil }
        var html = "<img src=\"\(escapeHTML(resolvedSource))\""
        if let alt, !alt.isEmpty {
            html += " alt=\"\(escapeHTML(alt))\""
        }
        if let width {
            html += " width=\"\(width)\""
        }
        if let alignment {
            html += " class=\"paper-align-\(alignment)\""
        }
        html += ">"
        return html
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
            "!\\[\\[[^\\]\\r\\n]+\\]\\]",                            // Obsidian wiki 图片嵌入 ![[name|40|left]]
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

    static func escapeHTML(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
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
