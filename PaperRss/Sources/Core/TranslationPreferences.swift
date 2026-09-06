import Foundation

public enum TranslationDisplayMode: String, CaseIterable, Codable, Sendable {
    case comparison
    case replacement
}

public enum TranslationColorSource: String, CaseIterable, Codable, Sendable {
    case automatic, custom
}

/// 仅影响本地阅读展示，不参与模型请求及译文缓存身份。
public struct TranslationPreferences: Codable, Hashable, Sendable {
    public var mode: TranslationDisplayMode
    public var lightColorSource: TranslationColorSource
    public var darkColorSource: TranslationColorSource
    public var customLightHex: String?
    public var customDarkHex: String?

    public static let defaultCustomHex = "#5F7355"
    public static let `default` = TranslationPreferences()

    public init(
        mode: TranslationDisplayMode = .comparison,
        lightColorSource: TranslationColorSource = .automatic,
        darkColorSource: TranslationColorSource = .automatic,
        customLightHex: String? = nil,
        customDarkHex: String? = nil
    ) {
        self.mode = mode
        self.lightColorSource = lightColorSource
        self.darkColorSource = darkColorSource
        self.customLightHex = Self.normalizedHex(customLightHex)
        self.customDarkHex = Self.normalizedHex(customDarkHex)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, lightColorSource, darkColorSource, customLightHex, customDarkHex
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: TranslationDisplayMode(rawValue: try values.decodeIfPresent(String.self, forKey: .mode) ?? "") ?? .comparison,
            lightColorSource: TranslationColorSource(rawValue: try values.decodeIfPresent(String.self, forKey: .lightColorSource) ?? "") ?? .automatic,
            darkColorSource: TranslationColorSource(rawValue: try values.decodeIfPresent(String.self, forKey: .darkColorSource) ?? "") ?? .automatic,
            customLightHex: try values.decodeIfPresent(String.self, forKey: .customLightHex),
            customDarkHex: try values.decodeIfPresent(String.self, forKey: .customDarkHex)
        )
    }

    public func colorSource(for mode: ReaderAppearanceMode) -> TranslationColorSource {
        mode == .light ? lightColorSource : darkColorSource
    }

    public mutating func setColorSource(_ source: TranslationColorSource, for mode: ReaderAppearanceMode) {
        if mode == .light { lightColorSource = source } else { darkColorSource = source }
    }

    public mutating func setCustomHex(_ hex: String, for mode: ReaderAppearanceMode) {
        guard let hex = Self.normalizedHex(hex) else { return }
        if mode == .light { customLightHex = hex } else { customDarkHex = hex }
    }

    public func colorHex(palette: ReaderAppearancePalette, mode: ReaderAppearanceMode) -> String {
        switch colorSource(for: mode) {
        case .automatic: return Self.automaticColor(palette: palette)
        case .custom:
            return Self.normalizedHex(mode == .light ? customLightHex : customDarkHex)
                ?? Self.defaultCustomHex
        }
    }

    public static func contrastRatio(_ foreground: String, _ background: String) -> Double {
        let lhs = luminance(foreground), rhs = luminance(background)
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }

    private static func automaticColor(palette: ReaderAppearancePalette) -> String {
        let accent = rgb(palette.accentHex)
        let muted = rgb(palette.mutedHex)
        let ink = rgb(palette.inkHex)
        // 强调色提供区分，次级文字色降低饱和度；对比不足时向正文色收敛。
        let base = zip(accent, muted).map { $0 * 0.65 + $1 * 0.35 }
        for step in 0...100 {
            let amount = Double(step) / 100
            let channels = zip(base, ink).map { Int(($0 + ($1 - $0) * amount).rounded()) }
            let candidate = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
            if contrastRatio(candidate, palette.backgroundHex) >= 4.5 { return candidate }
        }
        return palette.inkHex
    }

    private static func normalizedHex(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt32(value, radix: 16) != nil else { return nil }
        return "#" + value
    }

    private static func rgb(_ hex: String) -> [Double] {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)]
    }

    private static func luminance(_ hex: String) -> Double {
        let values = rgb(hex).map { value in
            let value = value / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
}
