import XCTest
import SwiftUI
import AppKit
@testable import PaperRssDesktop
import PaperRssCore

@MainActor
final class TimelinePresentationTests: XCTestCase {
    func testLayoutSwitchCapturesScrollAnchorBeforeNewViewsAppear() {
        let memory = TimelinePresentationMemory()
        memory.visibleAnchor = "article-40"
        let before = memory.restorationID
        memory.prepareRestoration()
        XCTAssertNotEqual(memory.restorationID, before)
        XCTAssertEqual(memory.restoreAnchor, "article-40")
        XCTAssertTrue(memory.isRestoring)
        memory.visibleAnchor = "article-1"
        XCTAssertEqual(memory.restoreAnchor, "article-40")
        memory.finishRestoration()
        XCTAssertFalse(memory.isRestoring)
    }

    func testReturnRestoresBrowsingAnchorAndNewScopeClearsMemory() {
        let memory = TimelinePresentationMemory()
        memory.browseAnchor = "article-90"
        memory.visibleAnchor = "article-92"
        memory.prepareRestoration(anchor: memory.browseAnchor)
        XCTAssertEqual(memory.restoreAnchor, "article-90")
        memory.resetScope()
        XCTAssertNil(memory.visibleAnchor)
        XCTAssertNil(memory.browseAnchor)
        XCTAssertNil(memory.restoreAnchor)
        XCTAssertFalse(memory.isRestoring)
    }

    func testToolbarControlsExistWithoutSelectedArticleAndRemainTrailing() {
        let actions = ToolbarActions(onRefresh: {}, onAddFeed: {}, onAddFolder: {}, onImport: {}, onExport: {},
            isRefreshing: false, selectionTitle: "Feed", hasUnread: false, onMarkAllRead: {},
            timelineControls: AnyView(Text("Views")), isTimelineBrowsing: true, usesVisualTimeline: true)
        let coordinator = ThreeColumnSplitViewCoordinator(actions: actions, appearance: .default,
            appearanceMode: .light, appTheme: .system, columnFocusState: PaperColumnFocusState())
        let toolbar = NSToolbar(identifier: "PreviewViewsTest")
        let identifiers = coordinator.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertEqual(identifiers.last, .paperTimelineControls)
        XCTAssertEqual(identifiers.filter { $0 == .paperTimelineControls }.count, 1)
        let item = coordinator.toolbar(toolbar, itemForItemIdentifier: .paperTimelineControls, willBeInsertedIntoToolbar: true)
        XCTAssertNotNil(item?.view)
        XCTAssertEqual(item?.visibilityPriority, .high)
        XCTAssertFalse(actions.showsReaderCapsule)
    }

    func testBrowseCollapseIsIndependentFromZenAndPreservesReaderInstance() {
        let actions = ToolbarActions(onRefresh: {}, onAddFeed: {}, onAddFolder: {}, onImport: {}, onExport: {},
            isRefreshing: false, selectionTitle: "Feed", hasUnread: false, onMarkAllRead: {},
            isTimelineBrowsing: true, usesVisualTimeline: true)
        let coordinator = ThreeColumnSplitViewCoordinator(actions: actions, appearance: .default,
            appearanceMode: .light, appTheme: .system, columnFocusState: PaperColumnFocusState())
        let split = NSSplitViewController()
        for _ in 0..<3 {
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            let item = NSSplitViewItem(viewController: controller)
            item.canCollapse = true
            split.addSplitViewItem(item)
        }
        coordinator.splitViewController = split
        let reader = split.splitViewItems[2].viewController
        coordinator.syncTimelinePresentation()
        XCTAssertTrue(split.splitViewItems[2].isCollapsed)
        XCTAssertFalse(split.splitViewItems[0].isCollapsed)
        XCTAssertFalse(split.splitViewItems[1].isCollapsed)
        coordinator.syncTimelinePresentation()
        XCTAssertTrue(split.splitViewItems[2].viewController === reader)
    }

    func testMagazineMeasureAndBreakpoints() {
        XCTAssertEqual(TimelineLayoutMetrics(availableWidth: 2400).contentWidth, 1100)
        XCTAssertEqual(TimelineLayoutMetrics(availableWidth: 320).contentWidth, 288)
        XCTAssertFalse(TimelineLayoutMetrics(availableWidth: 815).usesEditorialHeader)
        XCTAssertTrue(TimelineLayoutMetrics(availableWidth: 816).usesEditorialHeader)
        for width in [CGFloat(0), 280, 500, 800, 1100, 2400] {
            let metrics = TimelineLayoutMetrics(availableWidth: width)
            XCTAssertGreaterThan(metrics.contentWidth, 0)
            XCTAssertGreaterThan(metrics.galleryTileWidth, 0)
            XCTAssertTrue((1...3).contains(metrics.galleryColumns))
            let total = metrics.galleryTileWidth * CGFloat(metrics.galleryColumns)
                + CGFloat(metrics.galleryColumns - 1) * TimelineLayoutMetrics.spacing
            XCTAssertEqual(total, metrics.contentWidth, accuracy: 0.001)
        }
    }

    private func measuredHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testCompactImageCannotMakeShortTextRowTaller() {
        let height = measuredHeight(TimelineCompactTileLayout(imageWidth: 132) {
            Color.clear.frame(height: 48)
            Color.gray
        }, width: 500)
        XCTAssertEqual(height, 48, accuracy: 1)
    }

    func testTextOnlyTilesHaveNoReservedImageOrMinimumHeight() {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("tile-layout-\(UUID())")
        let store = ArticleThumbnailStore(directory: cache)
        defer { try? FileManager.default.removeItem(at: cache) }
        let entry = EntryListItem(id: "tweet", feedID: UUID(), title: "A short post", sourceTitle: "Test feed")
        for layout in [TimelineTileLayout.lead, .supporting, .compact, .gallery] {
            let tile = TimelineArticleTile(entry: entry, layout: layout, isSelected: false,
                width: 500, showsImages: true, thumbnailStore: store)
            let height = measuredHeight(tile, width: 500)
            XCTAssertGreaterThan(height, 40)
            XCTAssertLessThan(height, 140, "A text-only tile must not reserve a 140–240pt image slot")
        }
    }

    func testLongerTextIncreasesNaturalTileHeight() {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("tile-layout-\(UUID())")
        let store = ArticleThumbnailStore(directory: cache)
        defer { try? FileManager.default.removeItem(at: cache) }
        let short = EntryListItem(id: "short", feedID: UUID(), title: "Short post", sourceTitle: "Feed")
        let long = EntryListItem(id: "long", feedID: UUID(), title: String(repeating: "Longer article title ", count: 8),
                                summaryPreview: String(repeating: "An informative description. ", count: 12), sourceTitle: "Feed")
        func height(_ entry: EntryListItem) -> CGFloat {
            measuredHeight(TimelineArticleTile(entry: entry, layout: .gallery, isSelected: false,
                width: 320, showsImages: false, thumbnailStore: store), width: 320)
        }
        XCTAssertGreaterThan(height(long), height(short) + 30)
    }

    private func actions(visual: Bool = true, browsing: Bool, zen: Bool = false) -> ToolbarActions {
        ToolbarActions(onRefresh: {}, onAddFeed: {}, onAddFolder: {}, onImport: {}, onExport: {},
            isRefreshing: false, selectionTitle: "Feed", hasUnread: false, onMarkAllRead: {},
            isZenMode: zen, showsReaderCapsule: !browsing,
            isTimelineBrowsing: browsing, usesVisualTimeline: visual)
    }

    private func splitFixture() -> NSSplitViewController {
        let split = NSSplitViewController()
        split.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        for _ in 0..<3 {
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 100
            item.canCollapse = true
            split.addSplitViewItem(item)
        }
        return split
    }

    func testVisualArticleRouteHidesListAndBackRestoresBrowserWithoutReplacingControllers() {
        let coordinator = ThreeColumnSplitViewCoordinator(actions: actions(browsing: true), appearance: .default,
            appearanceMode: .light, appTheme: .system, columnFocusState: PaperColumnFocusState())
        let split = splitFixture()
        coordinator.splitViewController = split
        let controllers = split.splitViewItems.map(\.viewController)
        for _ in 0..<3 {
            coordinator.actions = actions(browsing: true)
            coordinator.syncTimelinePresentation()
            XCTAssertEqual(split.splitViewItems.map(\.isCollapsed), [false, false, true])
            coordinator.actions = actions(browsing: false)
            coordinator.syncTimelinePresentation()
            XCTAssertEqual(split.splitViewItems.map(\.isCollapsed), [false, true, false])
            XCTAssertTrue(coordinator.actions.showsTimelineReturn)
            coordinator.actions = actions(browsing: false, zen: true)
            coordinator.syncTimelinePresentation()
            XCTAssertEqual(split.splitViewItems.map(\.isCollapsed), [true, true, false])
            coordinator.actions = actions(browsing: false)
            coordinator.syncTimelinePresentation()
            XCTAssertEqual(split.splitViewItems.map(\.isCollapsed), [false, true, false])
        }
        coordinator.actions = actions(visual: false, browsing: false)
        coordinator.syncTimelinePresentation()
        XCTAssertEqual(split.splitViewItems.map(\.isCollapsed), [false, false, false])
        for (index, item) in split.splitViewItems.enumerated() {
            XCTAssertTrue(item.viewController === controllers[index])
        }
    }

    func testZenRestoresUserCollapsedSidebarInVisualReading() {
        let coordinator = ThreeColumnSplitViewCoordinator(actions: actions(browsing: false), appearance: .default,
            appearanceMode: .light, appTheme: .system, columnFocusState: PaperColumnFocusState())
        let split = splitFixture()
        coordinator.splitViewController = split
        split.splitViewItems[0].isCollapsed = true
        coordinator.syncTimelinePresentation()
        coordinator.actions = actions(browsing: false, zen: true)
        coordinator.syncTimelinePresentation()
        coordinator.actions = actions(browsing: false)
        coordinator.syncTimelinePresentation()
        XCTAssertEqual(split.splitViewItems.map(\.isCollapsed), [true, true, false])
    }

    func testReaderHasBalancedAccessoriesAndBackIsOnLeadingEdge() throws {
        let coordinator = ThreeColumnSplitViewCoordinator(actions: actions(browsing: false), appearance: .default,
            appearanceMode: .light, appTheme: .system, columnFocusState: PaperColumnFocusState())
        let toolbar = NSToolbar(identifier: "ReaderAccessoryTest")
        let order = coordinator.toolbarItemOrder(sidebarCollapsed: false)
        let reader = try XCTUnwrap(order.firstIndex(of: .paperReaderCapsule))
        XCTAssertEqual(Array(order[(reader - 2)...]), [.paperTimelineBack, .flexibleSpace,
                                                     .paperReaderCapsule, .flexibleSpace, .paperTimelineControls])
        XCTAssertFalse(order.contains(.paperTimelineTracker))
        XCTAssertFalse(order.contains(.paperEntryListTitle))
        let back = try XCTUnwrap(coordinator.toolbar(toolbar, itemForItemIdentifier: .paperTimelineBack, willBeInsertedIntoToolbar: true)?.view)
        let control = try XCTUnwrap(coordinator.toolbar(toolbar, itemForItemIdentifier: .paperTimelineControls, willBeInsertedIntoToolbar: true)?.view)
        XCTAssertEqual(back.frame.width, control.frame.width, accuracy: 0.001)
        let button = try XCTUnwrap(back.subviews.first as? NSButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.accessibilityIdentifier(), "timeline.returnToBrowse")
    }
}
