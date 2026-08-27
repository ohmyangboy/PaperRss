import Foundation
import XCTest

final class MacOS14ZenModeToolbarContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLegacyZenModeRemovesAndRestoresToolbarItemsWithoutHideSupport() throws {
        let source = try appSource("ThreeColumnSplitView.swift")

        XCTAssertTrue(source.contains("syncLegacyToolbarItemVisibility"))
        XCTAssertTrue(source.contains(".paperSidebarTracker"))
        XCTAssertTrue(source.contains(".paperTimelineTracker"))
        XCTAssertTrue(source.contains("toolbar.removeItem(at: index)"))
        XCTAssertTrue(source.contains("toolbar.insertItem(withItemIdentifier: identifier"))
        XCTAssertTrue(source.contains("zenRemovedToolbarItemIndexes"))

        let syncCall = try XCTUnwrap(source.range(of: "syncLegacyToolbarItemVisibility(in: toolbar"))
        let itemLoop = try XCTUnwrap(
            source.range(of: "for item in toolbar.items", range: syncCall.upperBound..<source.endIndex)
        )
        XCTAssertLessThan(syncCall.lowerBound, itemLoop.lowerBound)
    }

    func testReaderToolbarCapsuleKeepsOpaqueFallbackBehindLegacyMaterial() throws {
        let source = try appSource("ArticleReaderView.swift")

        XCTAssertTrue(source.contains("PaperTheme.surface(.page, scheme: colorScheme)"))
        XCTAssertTrue(source.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(source.contains("Capsule().fill(.ultraThinMaterial)"))
        XCTAssertTrue(source.contains("Capsule().strokeBorder"))
    }

    func testLegacyReaderCapsuleToolbarDrawsAThemeAwareBackgroundOnMacOS14() throws {
        let source = try appSource("ArticleReaderView.swift")
        let toolbarStart = try XCTUnwrap(source.range(of: "struct ReaderCapsuleToolbar: View"))
        let toolbarSource = source[toolbarStart.lowerBound..<source.endIndex]

        XCTAssertTrue(toolbarSource.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(toolbarSource.contains("private var legacyCapsuleBackground: some View"))
        XCTAssertTrue(toolbarSource.contains("Color(paperHex: appearancePalette.backgroundHex).opacity(0.82)"))
        XCTAssertTrue(toolbarSource.contains("Capsule().fill(.ultraThinMaterial)"))
        XCTAssertTrue(toolbarSource.contains(".shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.14)"))
    }

    private func appSource(_ name: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/\(name)"),
            encoding: .utf8
        )
    }
}
