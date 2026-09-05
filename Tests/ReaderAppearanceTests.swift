import Foundation
import XCTest
@testable import PaperRssCore

final class ReaderAppearanceTests: XCTestCase {
    func testLineHeightDefaultsPersistenceAndBounds() throws {
        let legacy = Data(#"{"preset":"paper","fontSize":20}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ReaderAppearance.self, from: legacy).lineHeight, 1.72)
        var appearance = ReaderAppearance(lineHeight: 2)
        XCTAssertEqual(appearance.normalized.lineHeight, 2)
        XCTAssertEqual(try JSONDecoder().decode(ReaderAppearance.self, from: JSONEncoder().encode(appearance)), appearance)
        appearance.setLineHeight(9)
        XCTAssertEqual(appearance.lineHeight, 2.4)
        appearance.setLineHeight(0)
        XCTAssertEqual(appearance.lineHeight, 1.2)
        appearance.setLineHeight(.nan)
        XCTAssertEqual(appearance.lineHeight, ReaderAppearance.defaultLineHeight)
    }

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
        XCTAssertTrue(appearanceSection.contains("readerFontPicker"))
        XCTAssertTrue(appearanceSection.contains("filteredReaderFontFamilies"))

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

        let splitView = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/ThreeColumnSplitView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(splitView.contains("window.appearance = chromeAppearance"))
        XCTAssertTrue(splitView.contains("private var chromeInkColor: NSColor"))
        XCTAssertTrue(splitView.contains("label.textColor = chromeInkColor"))
    }

    func testEntryListSelectionUsesAppearancePaletteAndReadableForegrounds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootView = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/RootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(rootView.contains("EntryRowSelectionSurface"))
        XCTAssertTrue(rootView.contains("Color(paperHex: palette.accentHex)"))
        XCTAssertTrue(rootView.contains("palette.colorScheme == .dark ? 0.34 : 0.18"))
        XCTAssertTrue(rootView.contains("let isSelected: Bool"))
        XCTAssertTrue(rootView.contains("EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)"))
        XCTAssertTrue(rootView.contains(".padding(.horizontal, 10)"))
        XCTAssertTrue(rootView.contains(".padding(.vertical, 3)"))
        XCTAssertTrue(rootView.contains("isListFocused"))
        XCTAssertTrue(rootView.contains("Color.white.opacity(0.13)"))
        XCTAssertTrue(rootView.contains("primaryForegroundColor"))
        XCTAssertTrue(rootView.contains("secondaryForegroundColor"))

        let columnContainer = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/PaperFloatingScrollbarView.swift"),
            encoding: .utf8
        )
        let splitView = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/ThreeColumnSplitView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(columnContainer.contains("tableView.selectionHighlightStyle = .none"))
        XCTAssertTrue(splitView.contains("suppressSystemSelectionHighlight: true"))
    }

    func testSettingsVisualShellKeepsCardsControlsAndFeatureRoutingConsistent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settings.contains("static let sidebarWidth: CGFloat = 240"))
        XCTAssertFalse(settings.contains("private var sidebarHeader: some View"))
        XCTAssertTrue(settings.contains("静夜思 · 李白"))
        XCTAssertTrue(settings.contains("赞赏与反馈"))
        XCTAssertTrue(settings.contains("static let cardCornerRadius: CGFloat = 14"))
        XCTAssertTrue(settings.contains("static let rowMinimumHeight: CGFloat = 52"))
        XCTAssertTrue(settings.contains(".background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius"))
        XCTAssertTrue(settings.contains(".controlSize(.regular)"))
        XCTAssertTrue(settings.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(settings.contains("featureConfigurationRow(.summary)"))
        XCTAssertTrue(settings.contains("featureConfigurationRow(.selectionAsk)"))
        XCTAssertTrue(settings.contains("private func aiFeatureCard(_ kind: AIFeatureKind)"))
        XCTAssertTrue(settings.contains("private func aiFeatureSection<Content: View>("))
        XCTAssertTrue(settings.contains("LazyVGrid(columns: aiFeatureColumns"))
        XCTAssertFalse(settings.contains(".frame(maxWidth: .infinity, minHeight: 176"))
        XCTAssertTrue(settings.contains("private var providerPickerAndEditor: some View"))
        XCTAssertTrue(settings.contains("private func providerSidebarRow(_ provider: AIProviderProfile)"))
        XCTAssertTrue(settings.contains(".frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)"))
        XCTAssertTrue(settings.contains(".contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))"))
        XCTAssertTrue(settings.contains("private var providerDetailPanel: some View"))
        XCTAssertTrue(settings.contains("private var providerModelManagementSection: some View"))
        XCTAssertTrue(settings.contains("private var addProviderButton: some View"))
        XCTAssertTrue(settings.contains("private struct AIProviderIcon: View"))
        XCTAssertTrue(settings.contains(#"store.aiSettings.providers.filter(\.isEnabled)"#))
        XCTAssertTrue(settings.contains("private var languageSettings: some View"))
        XCTAssertTrue(settings.contains("private var feedbackSettings: some View"))
        XCTAssertTrue(settings.contains("accessibilityAddTraits(.isToggle)"))
        XCTAssertFalse(settings.contains("showsAIAdvancedOptions"))
        XCTAssertFalse(settings.contains("case language"))
        XCTAssertFalse(settings.contains("case feedback"))
        XCTAssertFalse(settings.contains("private var syncSettings: some View"))
        XCTAssertFalse(settings.contains("case sync"))
        XCTAssertFalse(settings.contains("case .sync"))
        XCTAssertTrue(settings.contains("维护与恢复"))
        XCTAssertTrue(settings.contains("AppearanceThreeColumnPreview("))
        XCTAssertTrue(settings.contains("readerThemeDescription"))
        XCTAssertTrue(settings.contains(".toggleStyle(.switch)"))
        XCTAssertTrue(settings.contains("settingsAppearancePalette"))
        XCTAssertTrue(settings.contains("private var appThemePicker: some View"))
        XCTAssertTrue(settings.contains("background(isSelected ? settingsAccentColor : Color.clear, in: Capsule())"))
        XCTAssertTrue(settings.contains("private var updateChannelPicker: some View"))
        XCTAssertFalse(settings.contains("synchronizeSettingsWindowAppearance"))
        XCTAssertTrue(settings.contains("settings.return"))
        XCTAssertTrue(settings.contains("private struct SettingsInfoButton: View"))
        XCTAssertFalse(settings.contains("Tokyo Night"))
        XCTAssertFalse(settings.contains("contentHeader"))

        let paperTheme = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/PaperTheme.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(paperTheme.contains("struct PaperTopBarBlur: View"))
        XCTAssertTrue(paperTheme.contains("AppearanceHeaderSurface("))
        XCTAssertTrue(paperTheme.contains("tintOpacity: 0.64"))
        XCTAssertTrue(paperTheme.contains(".mask {"))
        XCTAssertTrue(paperTheme.contains("LinearGradient("))

        let actionBarStart = try XCTUnwrap(settings.range(of: "private var actionBar"))
        let actionBar = settings[actionBarStart.lowerBound..<settings.endIndex]
        XCTAssertFalse(actionBar.contains("保存设置"))
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
