import Foundation

/// Google Reader API 协议条目标识编解码器（仅限 Transport 兼容层使用）。
///
/// 遵循 Architecture Contract 与 FreshRSS 官方 wire 行为：
/// - FreshRSS 在 `/reader/api/0/stream/items/ids` 中返回十进制数字字符串（例如 `"1572638017615972"`）或 JSON 数字；
/// - FreshRSS 在 `/reader/api/0/stream/contents` 中返回完整 Tag URI（例如 `"tag:google.com,2005:reader/item/000596395b28d064"`，其中后缀为 16 位 16 进制）；
/// - 两者在数值上表示同一个 FreshRSS entry（`0x000596395b28d064 == 1572638017615972`）。
///
/// 本编解码器仅在 Transport 层进行无损转换与比较键规范化，
/// 严禁将数字类型扩散到 Persistence、Repository、Domain 或 UI 层（所有远端 ID 在业务层一律为 opaque String）。
public enum ReaderItemIDCodec: Sendable {
    public static let tagPrefix = "tag:google.com,2005:reader/item/"

    /// 将任意形态的 Reader Item ID（十进制数字字符串、完整 tag: URI、十六进制字符串、或任意 opaque 字符串）
    /// 转换为统一的比较规范键（Canonical Comparison Key）。
    ///
    /// 规则：
    /// 1. 若为 `tag:google.com,2005:reader/item/<hex>` 且后缀为合法十六进制，解析为 UInt64 并格式化为十进制字符串；
    /// 2. 若为纯十进制数字字符串且可解析为 UInt64，格式化为规范十进制字符串；
    /// 3. 若为其他任意非数字的 opaque 字符串，原样返回作为比较键（保证非标准 ID 不冲突、不丢失）。
    public static func canonicalComparisonKey(for id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)

        // 情况 1: 带有 tag:google.com,2005:reader/item/ 前缀
        if trimmed.hasPrefix(tagPrefix) {
            let hexPart = String(trimmed.dropFirst(tagPrefix.count))
            if let value = UInt64(hexPart, radix: 16) {
                return String(value)
            }
            return trimmed
        }

        // 情况 2: 纯十进制数字字符串
        if !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber), let value = UInt64(trimmed, radix: 10) {
            return String(value)
        }

        // 情况 3: 纯 16 位小写/大写十六进制字符串（少数兼容客户端场景）
        if trimmed.count == 16, let value = UInt64(trimmed, radix: 16) {
            return String(value)
        }

        // 情况 4: 其他 opaque 字符串
        return trimmed
    }

    /// 判断两个原始远端 ID 是否表示同一个 Reader 条目
    public static func areEquivalent(_ id1: String, _ id2: String) -> Bool {
        if id1 == id2 { return true }
        return canonicalComparisonKey(for: id1) == canonicalComparisonKey(for: id2)
    }

    /// 将十进制数字字符串转换为 16 位 0 填充的标准 Google Reader Tag ID
    public static func formatTagID(fromDecimal decimalString: String) -> String? {
        guard let value = UInt64(decimalString, radix: 10) else { return nil }
        let hex = String(format: "%016llx", value)
        return "\(tagPrefix)\(hex)"
    }

    /// 将远端 ID 集合构造成快速比对的 Canonical Key Set
    public static func buildCanonicalKeySet(from ids: some Sequence<String>) -> Set<String> {
        var set = Set<String>()
        for id in ids {
            set.insert(canonicalComparisonKey(for: id))
        }
        return set
    }
}
