import Foundation

/// Feed 标题/摘要经常来自 CDATA 或二次转义文本，XML 解析不会解开其中的 HTML 实体，
/// 展示层此前会把 `&#8212;`、`&#29233;` 这类原始实体直接显示给用户。
///
/// 这里是全仓唯一的文本实体解码入口：数字实体 + 常用命名实体，表驱动扩展，
/// 最多读三轮以兼容二次转义（`&amp;#8212;`）。只处理“文本”场景；
/// URL 查询串的解码仍由 `ArticleExtractor` 的窄白名单逻辑负责。
public enum HTMLTextDecoder {

    public static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var value = text
        for _ in 0..<3 {
            let next = decodeOnce(value)
            if next == value { break }
            value = next
        }
        return value
    }

    private static func decodeOnce(_ text: String) -> String {
        var value = decodeNamedEntities(in: text)
        if value.contains("&#") {
            value = decodeNumericEntities(in: value)
        }
        return value
    }

    // MARK: - Named Entities

    private static func decodeNamedEntities(in text: String) -> String {
        guard let expression = namedEntityExpression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var replacements: [(Range<String.Index>, String)] = []
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range, in: text),
                  let replacement = namedEntities[String(text[nameRange])] else { return }
            replacements.append((fullRange, replacement))
        }
        guard !replacements.isEmpty else { return text }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static let namedEntityExpression = try? NSRegularExpression(
        pattern: "&([a-zA-Z][a-zA-Z0-9]{1,31});"
    )

    /// 常用命名实体表。与 `plainText` 的历史行为保持一致：`nbsp` 解成普通空格，
    /// 避免列表行出现不可见的不换行空格。表是数据，新增实体只加条目不改逻辑。
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–", "horbar": "―", "minus": "−",
        "middot": "·", "bull": "•", "prime": "′", "Prime": "″", "deg": "°",
        "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼",
        "frac34": "¾", "permil": "‰", "micro": "µ", "sup1": "¹", "sup2": "²",
        "sup3": "³",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶",
        "dagger": "†", "Dagger": "‡",
        "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "sbquo": "‚", "bdquo": "„",
        "ensp": " ", "emsp": " ", "thinsp": " ", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔",
        "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡",
        "infin": "∞", "sum": "∑", "prod": "∏", "radic": "√", "int": "∫",
        "part": "∂", "nabla": "∇", "isin": "∈", "notin": "∉",
        "cap": "∩", "cup": "∪", "sub": "⊂", "sup": "⊃",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤"
    ]

    // MARK: - Numeric Entities

    private static func decodeNumericEntities(in text: String) -> String {
        guard let expression = numericEntityExpression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var cursor = text.startIndex
        var didDecode = false
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let fullRange = Range(match.range, in: text),
                  let valueRange = Range(match.range(at: 1), in: text) else { return }
            let raw = String(text[valueRange])
            let isHex = raw.hasPrefix("x") || raw.hasPrefix("X")
            let digits = isHex ? String(raw.dropFirst()) : raw
            guard let value = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(value) else { return }
            result += text[cursor..<fullRange.lowerBound]
            result.unicodeScalars.append(scalar)
            cursor = fullRange.upperBound
            didDecode = true
        }
        guard didDecode else { return text }
        result += text[cursor...]
        return result
    }

    private static let numericEntityExpression = try? NSRegularExpression(
        pattern: "&#([0-9]{1,7}|[xX][0-9a-fA-F]{1,6});"
    )
}
