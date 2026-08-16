import Foundation

/// 统一的 Legacy 迁移 JSON 序列化工具。
///
/// 遵循 Architecture Contract (DA-04A.1 Section 14)：统一使用 `[.sortedKeys, .withoutEscapingSlashes]` 输出确定性且无多余转义的 JSON 字符串。
enum LegacyMigrationJSONEncoder {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func encodeString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

/// 统一的 Legacy 迁移 JSON 反序列化工具。
///
/// 同时兼容 ISO8601 字符串格式与 Unix Timestamp (秒数) 浮点数格式。
enum LegacyMigrationJSONDecoder {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            if let dateString = try? container.decode(String.self) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: dateString) {
                    return date
                }
                let fallbackFormatter = ISO8601DateFormatter()
                fallbackFormatter.formatOptions = [.withInternetDateTime]
                if let date = fallbackFormatter.date(from: dateString) {
                    return date
                }
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected date timestamp or ISO8601 string")
            )
        }
        return decoder
    }()
}
