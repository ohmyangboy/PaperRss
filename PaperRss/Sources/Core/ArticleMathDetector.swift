import Foundation

/// 负责精确识别文章中是否包含 TeX 或 MathML 数学公式，并严格过滤货币价格与代码块内变量。
public enum ArticleMathDetector: Sendable {

    /// 公式屏蔽结果：shieldedText 中公式被占位注释替换，tokens 依序保存原文用于还原。
    public struct FormulaShieldResult: Sendable {
        public let shieldedText: String
        public let tokens: [String]
    }

    /// 公式占位符前缀；完整形态为 <!--PAPERRSS_MATH_TOKEN_<n>-->。
    /// 选择 HTML 注释形态：swift-markdown 将其解析为 HTMLBlock/InlineHTML 原样透传，
    /// 纯文本场景下也不会触发任何 markdown 结构特征。
    private static let tokenPrefix = "<!--PAPERRSS_MATH_TOKEN_"
    private static let tokenSuffix = "-->"
    private static let tokenPattern = "(?is)<!--PAPERRSS_MATH_TOKEN_\\d+-->"

    /// 将文本中的 TeX 公式（$$...$$, \[...\], \(...\), $...$）替换为安全占位符，
    /// 避免下游 markdown 解析器把公式内部的 *、_、\、{} 误识别为强调或转义。
    /// 单美元公式沿用 containsMath 的货币误报过滤。
    public static func shieldFormulas(in text: String) -> FormulaShieldResult {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else {
            return FormulaShieldResult(shieldedText: text, tokens: [])
        }

        struct FormulaRange {
            let range: Range<String.Index>
            let rawTeX: String
        }

        var ranges: [FormulaRange] = []

        // 1. 显示公式：$$...$$ 与 \[...\]（跨行）
        for pattern in [#"(?s)\$\$.*?\$\$"#, #"(?s)\\\[.*?\\\]"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsRange = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: nsRange) {
                    if let r = Range(match.range, in: text) {
                        ranges.append(FormulaRange(range: r, rawTeX: String(text[r])))
                    }
                }
            }
        }

        // 2. 行内 \( ... \)
        if let regex = try? NSRegularExpression(pattern: #"(?s)\\\(.*?\\\)"#) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                if let r = Range(match.range, in: text) {
                    ranges.append(FormulaRange(range: r, rawTeX: String(text[r])))
                }
            }
        }

        // 3. 单美元 $...$，排除货币金额与转义美元符
        if let regex = try? NSRegularExpression(pattern: #"(?<!\\|\w)\$([^$\r\n]+?)\$(?!\w)"#) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let fullRange = Range(match.range, in: text),
                      let innerRange = Range(match.range(at: 1), in: text) else { continue }
                let innerText = String(text[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !isPriceOrCurrency(innerText) && isMathExpression(innerText) {
                    ranges.append(FormulaRange(range: fullRange, rawTeX: String(text[fullRange])))
                }
            }
        }

        guard !ranges.isEmpty else {
            return FormulaShieldResult(shieldedText: text, tokens: [])
        }

        // 过滤重叠区间并按位置排序（显示公式优先于其内部的单美元匹配）
        ranges.sort { $0.range.lowerBound < $1.range.lowerBound }
        var selected: [FormulaRange] = []
        var lastEnd = text.startIndex
        for item in ranges where item.range.lowerBound >= lastEnd {
            selected.append(item)
            lastEnd = item.range.upperBound
        }

        var result = ""
        var tokens: [String] = []
        var cursor = text.startIndex
        for (index, item) in selected.enumerated() {
            result += text[cursor..<item.range.lowerBound]
            result += "\(tokenPrefix)\(index)\(tokenSuffix)"
            tokens.append(item.rawTeX)
            cursor = item.range.upperBound
        }
        result += text[cursor...]
        return FormulaShieldResult(shieldedText: result, tokens: tokens)
    }

    /// 将占位符替换回原始公式文本；token 数与顺序必须来自对应的 shieldFormulas 结果。
    public static func unshieldFormulas(_ text: String, tokens: [String]) -> String {
        guard !tokens.isEmpty else { return text }
        var result = text
        for (index, rawTeX) in tokens.enumerated() {
            let token = "\(tokenPrefix)\(index)\(tokenSuffix)"
            guard result.contains(token) else { continue }
            result = result.replacingOccurrences(of: token, with: rawTeX)
        }
        return result
    }

    /// 返回剥离全部公式后的文本（占位符以空格代替），仅用于结构特征检测，不用于展示。
    public static func strippingFormulas(in text: String) -> String {
        let shielded = shieldFormulas(in: text)
        guard !shielded.tokens.isEmpty else { return text }
        return shielded.shieldedText.replacingOccurrences(
            of: tokenPattern,
            with: " ",
            options: .regularExpression
        )
    }

    /// 判断文本是否包含公式占位注释。
    static func containsFormulaTokens(_ text: String) -> Bool {
        return text.range(of: tokenPattern, options: .regularExpression) != nil
    }

    /// 识别文本或 HTML 中是否包含真正的数学公式
    public static func containsMath(in content: String) -> Bool {
        guard !content.isEmpty else { return false }

        // 1. 过滤掉 <pre><code> 和 <code> 代码块内容，避免误判 shell 变量（如 $PATH）
        let sanitized = content
            .replacingOccurrences(of: "(?is)<pre\\b[^>]*>.*?</pre>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<code\\b[^>]*>.*?</code>", with: " ", options: .regularExpression)

        // 2. 检查 MathML 标签
        if sanitized.range(of: "(?is)<math\\b", options: .regularExpression) != nil {
            return true
        }

        // 3. 检查标准 TeX 定界符: \(...\), \[...\], $$...$$
        let standardTeXPatterns = [
            #"(?s)\\\(.*?\\\)"#,     // \( ... \)
            #"(?s)\\\[.*?\\\]"#,     // \[ ... \]
            #"(?s)\$\$.*?\$\$"#      // $$ ... $$
        ]

        for pattern in standardTeXPatterns {
            if sanitized.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        // 4. 检查单美元符号公式 $...$，排除货币金额（如 $9.99, $50-$100, $100 million）和转义美元符 (\$100)
        let dollarPattern = #"(?<!\\|\w)\$([^$\r\n]+?)\$(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: dollarPattern) else { return false }
        let range = NSRange(sanitized.startIndex..., in: sanitized)
        let matches = regex.matches(in: sanitized, range: range)

        for match in matches {
            guard let innerRange = Range(match.range(at: 1), in: sanitized) else { continue }
            let innerText = String(sanitized[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // 如果内容为空或纯为价格数字（如 9.99, 100, 50k 等），忽略
            if isPriceOrCurrency(innerText) {
                continue
            }

            // 如果包含典型数学符号或 LaTeX 宏命令，判定为真实公式
            if isMathExpression(innerText) {
                return true
            }
        }

        return false
    }

    /// 检测普通 TeX 定界符内部是否被插入 HTML 标签。MathJax 的 TeX 输入要求
    /// 定界符与公式文本处于同一文本结构；除换行标签和注释外的 HTML 会切断公式。
    public static func containsUnsupportedMarkupInsideFormula(in content: String) -> Bool {
        guard !content.isEmpty else { return false }

        let blockPatterns = [
            #"(?s)\$\$.*?\$\$"#,
            #"(?s)\\\[.*?\\\]"#,
            #"(?s)\\\(.*?\\\)"#
        ]

        for pattern in blockPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(content.startIndex..., in: content)
            for match in regex.matches(in: content, range: range) {
                guard let formulaRange = Range(match.range, in: content) else { continue }
                if containsUnsupportedTag(in: String(content[formulaRange])) {
                    return true
                }
            }
        }

        let inlinePattern = #"(?<!\\|\w)\$([^$\r\n]+?)\$(?!\w)"#
        if let regex = try? NSRegularExpression(pattern: inlinePattern) {
            let range = NSRange(content.startIndex..., in: content)
            for match in regex.matches(in: content, range: range) {
                guard let formulaRange = Range(match.range, in: content),
                      let innerRange = Range(match.range(at: 1), in: content) else { continue }
                let formula = String(content[formulaRange])
                guard containsUnsupportedTag(in: formula) else { continue }
                let textOnlyInner = String(content[innerRange])
                    .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !isPriceOrCurrency(textOnlyInner) && isMathExpression(textOnlyInner) {
                    return true
                }
            }
        }

        return false
    }

    private static func containsUnsupportedTag(in formula: String) -> Bool {
        let stripped = formula
            .replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)</?(?:br|wbr)\b[^>]*>"#, with: "", options: .regularExpression)
        return stripped.range(of: #"(?is)</?[a-z][^>]*>"#, options: .regularExpression) != nil
    }

    private static func isPriceOrCurrency(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty { return true }

        // 纯数字或带小数点的金额
        if Double(cleaned.replacingOccurrences(of: ",", with: "")) != nil {
            return true
        }

        // 包含价格修饰词（如 50 and 100, 10 million, 5 billion, per month, etc.）
        let priceKeywords = ["million", "billion", "thousand", "per", "month", "year", "usd", "aud", "cad", "cny", "eur", "gbp", "and", "or", "-", "–", "—", "to"]
        let words = cleaned.components(separatedBy: CharacterSet.whitespaces.union(.punctuationCharacters)).filter { !$0.isEmpty }
        if !words.isEmpty && words.allSatisfy({ word in
            Double(word) != nil || priceKeywords.contains(word)
        }) {
            return true
        }

        return false
    }

    private static func isMathExpression(_ text: String) -> Bool {
        // 包含 LaTeX 反斜杠宏（如 \alpha, \frac, \sqrt, \int, \times 等）
        if text.contains("\\") {
            return true
        }

        // Single-symbol notation such as `$L$` or `$y$` is common in papers
        // even when it has no operator or LaTeX command.
        if text.range(of: #"^[A-Za-z](?:[_^][A-Za-z0-9]+)?$"#, options: .regularExpression) != nil {
            return true
        }

        // 包含典型数学运算符或关系符（=, +, -, ^, _, \approx, etc.）
        let mathSymbols: [Character] = ["=", "+", "^", "_", "<", ">", "∫", "∑", "∏", "√", "±", "≤", "≥", "≠", "≈", "∈", "⊂"]
        for symbol in mathSymbols {
            if text.contains(symbol) {
                return true
            }
        }

        // 包含函数调用形式，如 f(x), g(x, y), P(A|B)
        if text.range(of: #"[a-zA-Z]\([a-zA-Z0-9,\s+\-*/^_]+\)"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }
}
