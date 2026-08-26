import Foundation

public enum ReaderThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case paper
    case white
    case geek

    public var id: String { rawValue }
}

public enum ReaderAppearanceMode: String, Codable, Sendable {
    case light
    case dark
}

public enum AppearanceSurfaceRole: String, CaseIterable, Codable, Sendable {
    case sidebar
    case articleList
    case reader
}

public struct ReaderAppearancePalette: Equatable, Sendable {
    public let colorScheme: ReaderAppearanceMode
    public let backgroundHex: String
    public let inkHex: String
    public let mutedHex: String
    public let accentHex: String
    public let warmHex: String
    public let ruleCSS: String
    public let washCSS: String
    public let codeCSS: String
    public let cardCSS: String

    public var cssVariables: [String: String] {
        [
            "--paper-reader-background": backgroundHex,
            "--paper-ink": inkHex,
            "--paper-muted": mutedHex,
            "--paper-accent": accentHex,
            "--paper-warm": warmHex,
            "--paper-rule": ruleCSS,
            "--paper-wash": washCSS,
            "--paper-code": codeCSS,
            "--paper-card": cardCSS
        ]
    }
}

public struct ReaderAppearance: Codable, Equatable, Sendable {
    public static let defaultFontSize = 17
    public static let minimumFontSize = 13
    public static let maximumFontSize = 25
    public static let `default` = ReaderAppearance()

    public private(set) var preset: ReaderThemePreset
    public private(set) var fontFamilyName: String?
    public private(set) var fontSize: Int
    public private(set) var customLightBackgroundHex: String?
    public private(set) var customDarkBackgroundHex: String?

    public init(
        preset: ReaderThemePreset = .paper,
        fontFamilyName: String? = nil,
        fontSize: Int = ReaderAppearance.defaultFontSize,
        customLightBackgroundHex: String? = nil,
        customDarkBackgroundHex: String? = nil
    ) {
        self.preset = preset
        self.fontFamilyName = Self.normalizedFontFamily(fontFamilyName)
        self.fontSize = Self.clampedFontSize(fontSize)
        self.customLightBackgroundHex = Self.normalizedHex(customLightBackgroundHex)
        self.customDarkBackgroundHex = Self.normalizedHex(customDarkBackgroundHex)
    }

    public var isCustom: Bool {
        customLightBackgroundHex != nil || customDarkBackgroundHex != nil
    }

    public mutating func selectPreset(_ preset: ReaderThemePreset) {
        self.preset = preset
        resetToPreset()
    }

    public mutating func setFontFamilyName(_ name: String?) {
        fontFamilyName = Self.normalizedFontFamily(name)
    }

    public mutating func setFontSize(_ size: Int) {
        fontSize = Self.clampedFontSize(size)
    }

    public mutating func setBackgroundHex(_ hex: String, for mode: ReaderAppearanceMode) {
        guard let normalized = Self.normalizedHex(hex) else { return }
        switch mode {
        case .light: customLightBackgroundHex = normalized
        case .dark: customDarkBackgroundHex = normalized
        }
    }

    public mutating func resetToPreset() {
        customLightBackgroundHex = nil
        customDarkBackgroundHex = nil
    }

    public func backgroundHex(for mode: ReaderAppearanceMode) -> String {
        switch mode {
        case .light:
            return customLightBackgroundHex ?? presetPalette(for: mode).backgroundHex
        case .dark:
            return customDarkBackgroundHex ?? presetPalette(for: mode).backgroundHex
        }
    }

    public func backgroundHex(
        for mode: ReaderAppearanceMode,
        surface: AppearanceSurfaceRole
    ) -> String {
        if isCustom { return backgroundHex(for: mode) }

        switch (preset, mode, surface) {
        case (_, _, .reader):
            return backgroundHex(for: mode)
        case (.paper, .light, .sidebar):
            return "#EAE8E1"
        case (.paper, .light, .articleList):
            return "#F1EDE4"
        case (.paper, .dark, .sidebar):
            return "#23221F"
        case (.paper, .dark, .articleList):
            return "#1F1E1B"
        case (.white, .light, .sidebar):
            return "#F4F4F5"
        case (.white, .light, .articleList):
            return "#FAFAFA"
        case (.white, .dark, .sidebar):
            return "#222225"
        case (.white, .dark, .articleList):
            return "#1C1C1E"
        case (.geek, _, .sidebar):
            return "#16161E"
        case (.geek, _, .articleList):
            return "#1F2335"
        }
    }

    public func palette(for mode: ReaderAppearanceMode) -> ReaderAppearancePalette {
        let presetPalette = presetPalette(for: mode)
        let customBackground: String?
        switch mode {
        case .light: customBackground = customLightBackgroundHex
        case .dark: customBackground = customDarkBackgroundHex
        }
        guard let customBackground else { return presetPalette }
        return Self.customPalette(backgroundHex: customBackground, accentHex: presetPalette.accentHex)
    }

    public func palette(
        for mode: ReaderAppearanceMode,
        surface: AppearanceSurfaceRole
    ) -> ReaderAppearancePalette {
        let base = palette(for: mode)
        let background = backgroundHex(for: mode, surface: surface)
        guard background != base.backgroundHex else { return base }
        return ReaderAppearancePalette(
            colorScheme: base.colorScheme,
            backgroundHex: background,
            inkHex: base.inkHex,
            mutedHex: base.mutedHex,
            accentHex: base.accentHex,
            warmHex: base.warmHex,
            ruleCSS: base.ruleCSS,
            washCSS: base.washCSS,
            codeCSS: base.codeCSS,
            cardCSS: base.cardCSS
        )
    }

    public var normalized: ReaderAppearance {
        ReaderAppearance(
            preset: preset,
            fontFamilyName: fontFamilyName,
            fontSize: fontSize,
            customLightBackgroundHex: customLightBackgroundHex,
            customDarkBackgroundHex: customDarkBackgroundHex
        )
    }

    private func presetPalette(for mode: ReaderAppearanceMode) -> ReaderAppearancePalette {
        switch (preset, mode) {
        case (.paper, .light):
            return ReaderAppearancePalette(
                colorScheme: .light,
                backgroundHex: "#F6F2E7",
                inkHex: "#302D27",
                mutedHex: "#6F695E",
                accentHex: "#5F7355",
                warmHex: "#9F5843",
                ruleCSS: "rgba(72, 65, 52, .22)",
                washCSS: "rgba(95, 115, 85, .10)",
                codeCSS: "rgba(100, 88, 65, .09)",
                cardCSS: "rgba(250, 248, 240, .97)"
            )
        case (.paper, .dark):
            return ReaderAppearancePalette(
                colorScheme: .dark,
                backgroundHex: "#1B1A17",
                inkHex: "#E4DED1",
                mutedHex: "#AAA397",
                accentHex: "#9EAF91",
                warmHex: "#D18B73",
                ruleCSS: "rgba(225, 215, 197, .18)",
                washCSS: "rgba(158, 175, 145, .10)",
                codeCSS: "rgba(224, 211, 185, .08)",
                cardCSS: "rgba(48, 45, 40, .97)"
            )
        case (.white, .light):
            return ReaderAppearancePalette(
                colorScheme: .light,
                backgroundHex: "#FFFFFF",
                inkHex: "#18181B",
                mutedHex: "#626269",
                accentHex: "#506447",
                warmHex: "#96533F",
                ruleCSS: "rgba(24, 24, 27, .16)",
                washCSS: "rgba(80, 100, 71, .08)",
                codeCSS: "rgba(24, 24, 27, .06)",
                cardCSS: "rgba(250, 250, 250, .98)"
            )
        case (.white, .dark):
            return ReaderAppearancePalette(
                colorScheme: .dark,
                backgroundHex: "#171717",
                inkHex: "#F4F4F5",
                mutedHex: "#A1A1AA",
                accentHex: "#A7BE9A",
                warmHex: "#E69A82",
                ruleCSS: "rgba(244, 244, 245, .16)",
                washCSS: "rgba(167, 190, 154, .09)",
                codeCSS: "rgba(244, 244, 245, .07)",
                cardCSS: "rgba(38, 38, 38, .98)"
            )
        case (.geek, _):
            return ReaderAppearancePalette(
                colorScheme: .dark,
                backgroundHex: "#1A1B26",
                inkHex: "#C0CAF5",
                mutedHex: "#A9B1D6",
                accentHex: "#7AA2F7",
                warmHex: "#F7768E",
                ruleCSS: "rgba(122, 162, 247, .24)",
                washCSS: "rgba(122, 162, 247, .11)",
                codeCSS: "rgba(65, 72, 104, .48)",
                cardCSS: "rgba(36, 40, 59, .97)"
            )
        }
    }

    private static func customPalette(backgroundHex: String, accentHex: String) -> ReaderAppearancePalette {
        let backgroundLuminance = relativeLuminance(of: backgroundHex)
        let lightInk = "#FFFFFF"
        let darkInk = "#000000"
        let lightContrast = contrastRatio(relativeLuminance(of: lightInk), backgroundLuminance)
        let darkContrast = contrastRatio(relativeLuminance(of: darkInk), backgroundLuminance)
        let isDark = lightContrast >= darkContrast
        let inkHex = isDark ? lightInk : darkInk
        let preferredMuted = isDark ? "#B7BDC8" : "#5E6168"
        let preferredWarm = isDark ? "#F0A087" : "#93503D"
        return ReaderAppearancePalette(
            colorScheme: isDark ? .dark : .light,
            backgroundHex: backgroundHex,
            inkHex: inkHex,
            mutedHex: readableColor(preferredMuted, backgroundHex: backgroundHex, fallback: inkHex),
            accentHex: readableColor(accentHex, backgroundHex: backgroundHex, fallback: inkHex),
            warmHex: readableColor(preferredWarm, backgroundHex: backgroundHex, fallback: inkHex),
            ruleCSS: isDark ? "rgba(245, 247, 250, .18)" : "rgba(23, 23, 23, .16)",
            washCSS: isDark ? "rgba(245, 247, 250, .08)" : "rgba(23, 23, 23, .055)",
            codeCSS: isDark ? "rgba(245, 247, 250, .08)" : "rgba(23, 23, 23, .06)",
            cardCSS: isDark ? "rgba(255, 255, 255, .07)" : "rgba(255, 255, 255, .72)"
        )
    }

    private static func readableColor(
        _ preferredHex: String,
        backgroundHex: String,
        fallback: String
    ) -> String {
        let ratio = contrastRatio(
            relativeLuminance(of: preferredHex),
            relativeLuminance(of: backgroundHex)
        )
        return ratio >= 4.5 ? preferredHex : fallback
    }

    private static func normalizedFontFamily(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return name
    }

    private static func clampedFontSize(_ size: Int) -> Int {
        max(minimumFontSize, min(maximumFontSize, size))
    }

    private static func normalizedHex(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt64(value, radix: 16) != nil else { return nil }
        return "#\(value)"
    }

    private static func relativeLuminance(of hex: String) -> Double {
        let raw = String(hex.dropFirst())
        guard let value = UInt64(raw, radix: 16) else { return 1 }
        let components = [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        ]
        let linear = components.map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func contrastRatio(_ lhs: Double, _ rhs: Double) -> Double {
        (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}
