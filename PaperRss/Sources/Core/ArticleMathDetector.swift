import Foundation

/// 负责精确识别文章中是否包含 TeX 或 MathML 数学公式，并严格过滤货币价格与代码块内变量。
public enum ArticleMathDetector: Sendable {

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

        // 包含典型数学运算符或关系符（=, +, -, ^, _, <, >, \approx, etc.）
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
