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

    func testReaderToolbarCapsuleRetainsSwiftUIFallbackOutsideTheToolbarContainer() throws {
        let source = try appSource("ArticleReaderView.swift")

        XCTAssertTrue(source.contains("PaperTheme.surface(.page, scheme: colorScheme)"))
        XCTAssertTrue(source.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(source.contains("Capsule().fill(.ultraThinMaterial)"))
        XCTAssertTrue(source.contains("Capsule().strokeBorder"))
    }

    func testLegacyReaderCapsuleToolbarDrawsAThemeAwareBackgroundOnMacOS14() throws {
        let source = try appSource("ArticleReaderView.swift")
        let splitViewSource = try appSource("ThreeColumnSplitView.swift")
        let toolbarStart = try XCTUnwrap(source.range(of: "struct ReaderCapsuleToolbar: View"))
        let toolbarSource = source[toolbarStart.lowerBound..<source.endIndex]

        XCTAssertTrue(toolbarSource.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(toolbarSource.contains("else if materialHostedByAppKit"))
        XCTAssertTrue(source.contains("readerCapsuleMaterialHostedByAppKit"))
        XCTAssertTrue(splitViewSource.contains("LegacyReaderCapsuleMaterialContainer"))
        XCTAssertTrue(splitViewSource.contains("blendingMode = .withinWindow"))
        XCTAssertTrue(splitViewSource.contains("material = .popover"))
        XCTAssertTrue(splitViewSource.contains("color.withAlphaComponent(0.14)"))
        XCTAssertTrue(splitViewSource.contains("rootView.environment(\\.readerCapsuleMaterialHostedByAppKit, true)"))
    }

    private func appSource(_ name: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/\(name)"),
            encoding: .utf8
        )
    }
}
