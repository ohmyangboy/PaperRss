import Foundation
import XCTest
@testable import PaperRssCore

final class TranslationPreferencesTests: XCTestCase {
    func testLegacyPreferencesDecodeWithoutChangingExistingValues() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AISettings.default)) as? [String: Any])
        var features = try XCTUnwrap(json["features"] as? [String: Any])
        features.removeValue(forKey: "translationPreferences")
        features["targetLanguage"] = "日本語"
        features["customPrompt"] = "保留已有提示词"
        json["features"] = features
        let restored = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.features.translationPreferences, .default)
        XCTAssertEqual(restored.features.targetLanguage, "日本語")
        XCTAssertEqual(restored.features.customPrompt, "保留已有提示词")
        XCTAssertEqual(restored.providers, AISettings.default.providers)
        XCTAssertEqual(restored.featureConfigurations, AISettings.default.featureConfigurations)
        XCTAssertEqual(restored.schema, AISettings.schemaVersion)
    }

    func testRoundTripAndOtherSettingsEditsPreserveBothColorModes() throws {
        var settings = AISettings.default
        settings.features.translationPreferences = TranslationPreferences(
            mode: .replacement, lightColorSource: .custom, darkColorSource: .automatic,
            customLightHex: "abcdef", customDarkHex: "#c0caf5"
        )
        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        var features = decoded.features
        features.targetLanguage = "French"
        XCTAssertEqual(decoded.updatingFeatures(features).features.translationPreferences, settings.features.translationPreferences)
        let legacy = AIFeaturePreferences(configuration: .deepSeek, translationPreferences: features.translationPreferences)
        XCTAssertEqual(legacy.translationPreferences, features.translationPreferences)
        XCTAssertEqual(settings.migratedToCurrentSchema().features.translationPreferences, features.translationPreferences)
    }

    func testAutomaticColorUsesMutedAccentAndRemainsReadableAcrossThemes() {
        XCTAssertEqual(TranslationPreferences.default.colorHex(palette: ReaderAppearance().palette(for: .light), mode: .light), "#657058")
        for preset in ReaderThemePreset.allCases {
            for mode in [ReaderAppearanceMode.light, .dark] {
                let palette = ReaderAppearance(preset: preset).palette(for: mode)
                let color = TranslationPreferences.default.colorHex(palette: palette, mode: mode)
                XCTAssertGreaterThanOrEqual(TranslationPreferences.contrastRatio(color, palette.backgroundHex), 4.5)
            }
        }
        for background in ["#000000", "#FFFFFF", "#777777", "#A0BA8F", "#24385B"] {
            let appearance = ReaderAppearance(customLightBackgroundHex: background, customDarkBackgroundHex: background)
            for mode in [ReaderAppearanceMode.light, .dark] {
                let palette = appearance.palette(for: mode)
                let color = TranslationPreferences.default.colorHex(palette: palette, mode: mode)
                XCTAssertGreaterThanOrEqual(TranslationPreferences.contrastRatio(color, background), 4.5)
            }
        }
    }

    func testThemeTokensCustomColorsAndUnknownFields() throws {
        let palette = ReaderAppearance(preset: .geek).palette(for: .dark)
        XCTAssertEqual(TranslationColorSource.allCases, [.automatic, .custom])
        for legacy in ["ink", "muted", "accent", "warm"] {
            let data = Data("{\"lightColorSource\":\"\(legacy)\"}".utf8)
            let restored = try JSONDecoder().decode(TranslationPreferences.self, from: data)
            XCTAssertEqual(restored.lightColorSource, .automatic)
        }
        XCTAssertEqual(TranslationPreferences(lightColorSource: .custom).colorHex(palette: palette, mode: .light), "#5F7355")
        var custom = TranslationPreferences(lightColorSource: .custom)
        custom.setCustomHex("#ffffff", for: .light)
        custom.setCustomHex("not-a-color", for: .dark)
        XCTAssertEqual(custom.colorHex(palette: palette, mode: .light), "#FFFFFF")
        XCTAssertNil(custom.customDarkHex)
        let unknown = try JSONDecoder().decode(TranslationPreferences.self, from: Data(#"{"mode":"future","lightColorSource":"future","customLightHex":"invalid"}"#.utf8))
        XCTAssertEqual(unknown, .default)
    }
}
