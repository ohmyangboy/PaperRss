import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PaperRssCore

final class MacOS14VisualCompatibilityContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLegacyNavbarUsesContentThemeBackgroundWhileLiquidGlassControlsRemainAvailable() throws {
        let source = try sourceText("PaperRss/Sources/App/ThreeColumnSplitView.swift")

        XCTAssertTrue(source.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(source.contains("applyLiquidGlassWindowChrome"))
        XCTAssertTrue(source.contains("applyLegacyPaperNavbarChrome"))
        XCTAssertTrue(source.contains("syncMainWindowTitlebarBackground"))
        XCTAssertTrue(source.contains("firstDescendant(of: container, className: \"NSTitlebarBackgroundView\")?.isHidden = true"))
        XCTAssertTrue(source.contains("window.toolbar?.isVisible = true"))
        XCTAssertEqual(
            source.components(separatedBy: "restoreMainWindowTitlebarBackground(").count - 1,
            3,
            "Only the helper declaration plus the fullscreen and macOS 26+ sync branches may restore the system titlebar background"
        )
        XCTAssertTrue(source.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertFalse(source.contains("window.titlebarAppearsTransparent = false"))
        XCTAssertTrue(source.contains("appearance.backgroundHex("))
        XCTAssertTrue(source.contains("surface: .reader"))
        XCTAssertTrue(source.contains("window.backgroundColor = chromeBackgroundColor"))
    }

    func testPrimaryEmptyStatesUseOnePaperTypographyComponent() throws {
        let theme = try sourceText("PaperRss/Sources/App/PaperTheme.swift")
        let root = try sourceText("PaperRss/Sources/App/RootView.swift")

        XCTAssertTrue(theme.contains("struct PaperEmptyState"))
        XCTAssertTrue(theme.contains("size: 18, weight: .medium, design: .serif"))
        XCTAssertTrue(theme.contains("size: 13, design: .serif"))
        XCTAssertGreaterThanOrEqual(root.components(separatedBy: "PaperEmptyState(").count - 1, 4)
    }

    func testScreenshotRegionsHaveEnglishCopyAndLocaleAwareReaderGlyphs() throws {
        XCTAssertEqual(I18N.localized("管理本地与 FreshRSS 订阅账号及双向状态同步", language: .en),
                       "Manage local and FreshRSS accounts with two-way state sync")
        XCTAssertEqual(I18N.localized("我的 Mac", language: .en), "My Mac")
        XCTAssertEqual(I18N.localized("我的 Mac (本地账号)", language: .en), "My Mac (Local Account)")
        XCTAssertEqual(I18N.localized("本机", language: .en), "Local")
        XCTAssertEqual(I18N.localized("再按一次 C 切换对照翻译", language: .en),
                       "Press C again to toggle bilingual translation")

        let settings = try sourceText("PaperRss/Sources/App/SettingsView.swift")
        XCTAssertTrue(settings.contains("localizedBuiltInProviderName"))
        XCTAssertTrue(settings.contains("localizedBuiltInProviderDescription"))

        let reader = try sourceText("PaperRss/Sources/App/ArticleReaderView.swift")
        XCTAssertFalse(reader.contains("I18N.localized(\"Ai摘要\")"))
        XCTAssertTrue(reader.contains("I18N.localized(\"AI 摘要\")"))
        XCTAssertTrue(reader.contains("I18N.shared.isEnglish ? \"A\" : \"文\""))
    }

    func testMacAppIconUsesInsetTransparentRoundedGeometry() throws {
        let iconURL = repositoryRoot.appendingPathComponent(
            "PaperRss/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
        )
        guard let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("Unable to decode AppIcon")
        }

        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)
        let alpha = try alphaPixels(for: image)
        XCTAssertEqual(alpha[0], 0)
        XCTAssertGreaterThan(alpha[512 * 1024 + 512], 250)

        var minX = 1024
        var minY = 1024
        var maxX = -1
        var maxY = -1
        for y in 0..<1024 {
            for x in 0..<1024 where alpha[y * 1024 + x] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        XCTAssertTrue((95...105).contains(minX))
        XCTAssertTrue((95...105).contains(minY))
        XCTAssertTrue((918...928).contains(maxX))
        XCTAssertTrue((918...928).contains(maxY))

        let iosIconURL = repositoryRoot.appendingPathComponent(
            "PaperRss/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"
        )
        guard let iosSource = CGImageSourceCreateWithURL(iosIconURL as CFURL, nil),
              let iosImage = CGImageSourceCreateImageAtIndex(iosSource, 0, nil) else {
            return XCTFail("Unable to decode iOS AppIcon")
        }
        XCTAssertFalse(iosImage.alphaInfo == .premultipliedLast ||
                       iosImage.alphaInfo == .premultipliedFirst ||
                       iosImage.alphaInfo == .last ||
                       iosImage.alphaInfo == .first)
    }

    private func sourceText(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func alphaPixels(for image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1024,
                height: 1024,
                bitsPerComponent: 8,
                bytesPerRow: 1024 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            return true
        }
        guard rendered else { throw CocoaError(.fileReadCorruptFile) }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
