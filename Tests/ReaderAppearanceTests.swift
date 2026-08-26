import Foundation
import XCTest
@testable import PaperRssCore

final class ReaderAppearanceTests: XCTestCase {
    func testBuiltInPresetsExposeStableReaderPalettes() {
        XCTAssertEqual(ReaderThemePreset.allCases, [.paper, .white, .geek])

        let paper = ReaderAppearance.default
        XCTAssertEqual(paper.preset, .paper)
        XCTAssertFalse(paper.isCustom)
        XCTAssertEqual(paper.backgroundHex(for: .light), "#F6F2E7")
        XCTAssertEqual(paper.backgroundHex(for: .dark), "#1B1A17")

        let white = ReaderAppearance(preset: .white)
        XCTAssertEqual(white.backgroundHex(for: .light), "#FFFFFF")
        XCTAssertEqual(white.backgroundHex(for: .dark), "#171717")

        let geek = ReaderAppearance(preset: .geek)
        XCTAssertEqual(geek.backgroundHex(for: .light), "#1A1B26")
        XCTAssertEqual(geek.backgroundHex(for: .dark), "#1A1B26")
    }

    func testBuiltInPresetsProvideCoordinatedThreeColumnSurfaces() {
        let paper = ReaderAppearance.default
        XCTAssertEqual(paper.backgroundHex(for: .light, surface: .sidebar), "#EAE8E1")
        XCTAssertEqual(paper.backgroundHex(for: .light, surface: .articleList), "#F1EDE4")
        XCTAssertEqual(paper.backgroundHex(for: .light, surface: .reader), "#F6F2E7")

        let white = ReaderAppearance(preset: .white)
        XCTAssertEqual(white.backgroundHex(for: .light, surface: .sidebar), "#F4F4F5")
        XCTAssertEqual(white.backgroundHex(for: .light, surface: .articleList), "#FAFAFA")
        XCTAssertEqual(white.backgroundHex(for: .light, surface: .reader), "#FFFFFF")

        let geek = ReaderAppearance(preset: .geek)
        XCTAssertEqual(geek.backgroundHex(for: .light, surface: .sidebar), "#16161E")
        XCTAssertEqual(geek.backgroundHex(for: .light, surface: .articleList), "#1F2335")
        XCTAssertEqual(geek.backgroundHex(for: .light, surface: .reader), "#1A1B26")

        var custom = ReaderAppearance(preset: .white)
        custom.setBackgroundHex("#334455", for: .dark)
        for surface in AppearanceSurfaceRole.allCases {
            XCTAssertEqual(custom.backgroundHex(for: .dark, surface: surface), "#334455")
        }
    }

    func testCustomBackgroundCreatesCustomStateAndResetKeepsTypography() {
        var appearance = ReaderAppearance(
            preset: .geek,
            fontFamilyName: "Iowan Old Style",
            fontSize: 21
        )

        appearance.setBackgroundHex("#FAFAFA", for: .light)
        XCTAssertTrue(appearance.isCustom)
        XCTAssertEqual(appearance.backgroundHex(for: .light), "#FAFAFA")
        XCTAssertEqual(appearance.preset, .geek)

        appearance.resetToPreset()
        XCTAssertFalse(appearance.isCustom)
        XCTAssertEqual(appearance.backgroundHex(for: .light), "#1A1B26")
        XCTAssertEqual(appearance.fontFamilyName, "Iowan Old Style")
        XCTAssertEqual(appearance.fontSize, 21)
    }

    func testCustomPaletteMaintainsReadableContrastForLightAndDarkColors() throws {
        var appearance = ReaderAppearance.default
        appearance.setBackgroundHex("#FEFDFB", for: .light)
        appearance.setBackgroundHex("#090B10", for: .dark)

        let light = appearance.palette(for: .light)
        let dark = appearance.palette(for: .dark)

        XCTAssertGreaterThan(try contrastRatio(light.inkHex, light.backgroundHex), 7)
        XCTAssertGreaterThan(try contrastRatio(dark.inkHex, dark.backgroundHex), 7)
        XCTAssertEqual(light.colorScheme, .light)
        XCTAssertEqual(dark.colorScheme, .dark)

        appearance.setBackgroundHex("#A0A0A0", for: .light)
        let middleGray = appearance.palette(for: .light)
        XCTAssertEqual(middleGray.inkHex, "#000000")
        XCTAssertGreaterThan(try contrastRatio(middleGray.inkHex, middleGray.backgroundHex), 7)

        appearance.setBackgroundHex("#747474", for: .light)
        let crossoverGray = appearance.palette(for: .light)
        XCTAssertGreaterThan(try contrastRatio(crossoverGray.inkHex, crossoverGray.backgroundHex), 4.5)
        XCTAssertGreaterThanOrEqual(try contrastRatio(crossoverGray.mutedHex, crossoverGray.backgroundHex), 4.5)
        XCTAssertGreaterThanOrEqual(try contrastRatio(crossoverGray.accentHex, crossoverGray.backgroundHex), 4.5)

        appearance.setBackgroundHex("#334455", for: .dark)
        let customDark = appearance.palette(for: .dark)
        XCTAssertGreaterThanOrEqual(try contrastRatio(customDark.mutedHex, customDark.backgroundHex), 4.5)
        XCTAssertGreaterThanOrEqual(try contrastRatio(customDark.accentHex, customDark.backgroundHex), 4.5)
    }

    @MainActor
    func testStorePersistsAppearanceAndMigratesLegacyFontSize() throws {
        let defaults = UserDefaults.standard
        let appearanceKey = "PaperRss.readerAppearance"
        let legacyFontSizeKey = "PaperRss.articleFontSize"
        let previousAppearance = defaults.object(forKey: appearanceKey)
        let previousFontSize = defaults.object(forKey: legacyFontSizeKey)
        defer {
            restore(previousAppearance, key: appearanceKey, defaults: defaults)
            restore(previousFontSize, key: legacyFontSizeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: appearanceKey)
        defaults.set(20, forKey: legacyFontSizeKey)
        var store = AppStore(testDatabase: .empty) { _ in fatalError("Unused in test") }
        XCTAssertEqual(store.readerAppearance.fontSize, 20)

        store.setReaderThemePreset(.white)
        store.setReaderFontFamily("Avenir Next")
        store.setReaderBackgroundHex("#F7F7F8", for: .light)
        XCTAssertTrue(store.readerAppearance.isCustom)
        XCTAssertNotNil(defaults.data(forKey: appearanceKey))

        store = AppStore(testDatabase: .empty) { _ in fatalError("Unused in test") }
        XCTAssertEqual(store.readerAppearance.preset, .white)
        XCTAssertEqual(store.readerAppearance.fontFamilyName, "Avenir Next")
        XCTAssertEqual(store.readerAppearance.backgroundHex(for: .light), "#F7F7F8")

        store.resetReaderAppearanceToPreset()
        XCTAssertFalse(store.readerAppearance.isCustom)
        XCTAssertEqual(store.readerAppearance.fontFamilyName, "Avenir Next")

        store.resetReaderAppearanceToDefault()
        XCTAssertEqual(store.readerAppearance, .default)
    }

    func testAppearanceSettingsAndThreeColumnWiringStayCoordinated() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/SettingsView.swift"),
            encoding: .utf8
        )
        let reader = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/ArticleReaderView.swift"),
            encoding: .utf8
        )
        let appearanceStart = try XCTUnwrap(settings.range(of: "private var appearanceSettings"))
        let languageStart = try XCTUnwrap(settings.range(of: "private var languageSettings", range: appearanceStart.upperBound..<settings.endIndex))
        let appearanceSection = settings[appearanceStart.lowerBound..<languageStart.lowerBound]

        XCTAssertTrue(appearanceSection.contains("ReaderThemePreset.allCases"))
        XCTAssertTrue(appearanceSection.contains("availableReaderFontFamilies"))
        XCTAssertTrue(appearanceSection.contains("setReaderBackgroundHex"))
        XCTAssertTrue(appearanceSection.contains("resetReaderAppearanceToPreset"))
        XCTAssertTrue(appearanceSection.contains("resetReaderAppearanceToDefault"))
        XCTAssertTrue(appearanceSection.contains("setAppTheme"))

        XCTAssertTrue(reader.contains("AppearanceSurface(role: .reader"))
        XCTAssertEqual(reader.components(separatedBy: "synchronizeReaderAppearance(in: webView)").count - 1, 2)
        XCTAssertFalse(reader.contains(".preferredColorScheme(store.readerAppearance"))
        XCTAssertFalse(reader.contains("html, body { background: var(--paper-reader-background)"))
        XCTAssertTrue(reader.contains(".paper-header-container, .paper-summary-card, #paper-rss-toc-rail"))
        XCTAssertTrue(reader.contains("body > :not(.paper-header-container)"))

        let rootView = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/RootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(rootView.contains("role: .sidebar"))
        XCTAssertTrue(rootView.contains("role: .articleList"))
        XCTAssertTrue(rootView.contains("appearanceMode:"))
        XCTAssertTrue(rootView.contains("paperAppearancePalette"))
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func contrastRatio(_ foreground: String, _ background: String) throws -> Double {
        let foregroundLuminance = try luminance(foreground)
        let backgroundLuminance = try luminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ hex: String) throws -> Double {
        let value = String(hex.dropFirst())
        let rgb = try XCTUnwrap(UInt64(value, radix: 16))
        let components = [
            Double((rgb >> 16) & 0xFF) / 255,
            Double((rgb >> 8) & 0xFF) / 255,
            Double(rgb & 0xFF) / 255
        ]
        let linear = components.map { component in
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
