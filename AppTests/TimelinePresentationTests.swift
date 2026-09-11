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
}
