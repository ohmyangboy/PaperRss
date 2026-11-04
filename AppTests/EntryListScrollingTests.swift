import AppKit
import PaperRssCore
import SwiftUI
import WebKit
import XCTest
@testable import PaperRssDesktop

@MainActor
private final class ListSelectionFixture: ObservableObject {
    @Published var selectedID: String?
    @Published var scrollRequest = UUID()
}

private struct ArticleListFixture: View {
    let store: AppStore
    let feed: Feed
    @ObservedObject var selection: ListSelectionFixture
    @State private var retained: Set<String> = []
    @StateObject private var focus = PaperColumnFocusState()
    @StateObject private var memory = TimelinePresentationMemory()

    var body: some View {
        EntryListView(store: store, appearanceMode: .light, selection: .feed(feed.id),
                      selectedEntryID: $selection.selectedID, retainedUnreadIDs: $retained,
                      columnFocusState: focus, titleTranslator: store.titleTranslator,
                      autoScrollTrigger: selection.scrollRequest, presentation: memory)
            .environmentObject(store.iconStore)
    }
}

private struct ArticleDetailFixture: View {
    @ObservedObject var store: AppStore
    @ObservedObject var selection: ListSelectionFixture

    var body: some View {
        if let id = selection.selectedID, let entry = store.entry(id: id) {
            ArticleReaderView(store: store, aiWorkspace: store.aiWorkspace, entry: entry, appearanceMode: .light)
                .environmentObject(store.iconStore)
        }
    }
}

@MainActor
final class EntryListScrollingTests: XCTestCase {
    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }

    func testNativeSelectionAtViewportEdgeAndAcrossPages() async throws {
        try await checkScrolling(reduceMotion: false)
    }

    func testReducedMotionSelectionAtViewportEdgeAndAcrossPages() async throws {
        try await checkScrolling(reduceMotion: true)
    }

    func testEdgeSelectionWhileSwitchingLocalReaderDocuments() async throws {
        try await checkScrolling(reduceMotion: false, withReader: true)
    }

    private func checkScrolling(reduceMotion: Bool, withReader: Bool = false) async throws {
        try VisibleWindowTestSupport.requireGUI()
        _ = NSApplication.shared
        let feed = Feed(title: "Fixture", feedURL: URL(string: "https://example.invalid")!)
        let now = Date()
        let entries = (0..<120).map { index in
            Entry(id: String(index), feedID: feed.id, title: index.isMultiple(of: 2) ? "Article \(index)" : String(repeating: "Long title ", count: 12),
                  publishedAt: now.addingTimeInterval(-Double(index)),
                  summary: index.isMultiple(of: 3) ? String(repeating: "Article summary ", count: 18) : "",
                  contentHTML: withReader ? "<p>fixture-body-\(index)-end</p>" +
                    String(repeating: "<p>A paragraph of local article content.</p>", count: index.isMultiple(of: 2) ? 80 : 3) : nil)
        }
        let store = AppStore(testDatabase: AppDatabase(feeds: [feed], entries: entries,
            articleCaches: [:], readingStates: [:], artifacts: [], llmConfiguration: .default))
        let selection = ListSelectionFixture()
        let column = PaperColumnContainerController(
            rootView: ArticleListFixture(store: store, feed: feed, selection: selection).ignoresSafeArea(),
            suppressSystemSelectionHighlight: true)
        let split = NSSplitViewController()
        split.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let detail: NSViewController
        if withReader {
            detail = NSHostingController(rootView: ArticleDetailFixture(store: store, selection: selection)
                .frame(minWidth: 320, minHeight: 500))
        } else {
            detail = NSHostingController(rootView: Color.clear.frame(minWidth: 320, minHeight: 500))
        }
        split.splitViewItems = [
            NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: Color.clear.frame(minWidth: 240, minHeight: 500))),
            NSSplitViewItem(contentListWithViewController: column),
            NSSplitViewItem(viewController: detail)
        ]
        split.splitViewItems[1].minimumThickness = 280
        let host = column.view
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "TimelineScrollTest")
        window.toolbarStyle = .unified
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 820))
        split.splitView.setPosition(240, ofDividerAt: 0)
        split.splitView.setPosition(530, ofDividerAt: 1)
        try VisibleWindowTestSupport.show(window: window, makeKey: true)
        defer { window.close() }
        for _ in 0..<100 where table(in: host)?.numberOfRows ?? 0 < 100 {
            try await Task.sleep(for: .milliseconds(30))
        }
        let table = try XCTUnwrap(table(in: host))
        XCTAssertEqual(table.numberOfRows, 100)
        func fullyVisible(_ row: Int) -> Bool {
            let rect = table.rect(ofRow: row)
            let inWindow = table.convert(rect, to: nil)
            return table.visibleRect.contains(rect) && inWindow.minY >= 0
        }
        func waitForArticle(_ index: Int) async throws {
            func webView(in view: NSView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                return view.subviews.lazy.compactMap { webView(in: $0) }.first
            }
            for _ in 0..<100 {
                if let web = webView(in: detail.view), let rendered = try? await web.evaluateJavaScript(
                    "document.body?.innerText.includes('fixture-body-\(index)-end') === true"
                ) as? Bool, rendered { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Reader did not render local fixture article \(index)")
        }
        let visible = table.rows(in: table.visibleRect)
        XCTAssertGreaterThan(visible.length, 2, "table viewport: \(table.visibleRect), window: \(window.frame)")
        guard visible.length > 2 else { return }
        var edge = NSMaxRange(visible) - 1
        if table.rect(ofRow: edge).maxY > table.visibleRect.maxY { edge -= 1 }
        XCTAssertGreaterThan(edge, 1)
        let offset = table.visibleRect.minY
        _ = window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: edge), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(350))
        if withReader { try await waitForArticle(edge) }
        XCTAssertEqual(selection.selectedID, String(edge))
        XCTAssertEqual(table.visibleRect.minY, offset, accuracy: 1)

        let coordinator = ThreeColumnSplitViewCoordinator(
            actions: ToolbarActions(onRefresh: {}, onAddFeed: {}, onAddFolder: {}, onImport: {}, onExport: {},
                                    isRefreshing: false, selectionTitle: "Feed", hasUnread: true, onMarkAllRead: {}),
            appearance: .default, appearanceMode: .light, appTheme: .system, columnFocusState: PaperColumnFocusState())
        coordinator.splitViewController = split
        defer { withExtendedLifetime(coordinator) {} }
        func arrow(down: Bool, repeating: Bool = false) throws {
            let characters = down ? "\u{F701}" : "\u{F700}"
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: down ? 125 : 126))
            if reduceMotion {
                XCTAssertTrue(ThreeColumnSplitViewCoordinator.moveArticleSelection(in: table, keyCode: event.keyCode, reduceMotion: true))
            } else {
                NSApp.sendEvent(event)
            }
        }
        // Sample the visible offset from before dispatch so a jump within the key handler is included.
        let start = ProcessInfo.processInfo.systemUptime
        var positions: [(time: Double, y: CGFloat)] = [(0, table.visibleRect.minY)]
        try arrow(down: true)
        repeat {
            positions.append((ProcessInfo.processInfo.systemUptime - start, table.visibleRect.minY))
            try await Task.sleep(for: .milliseconds(5))
        } while ProcessInfo.processInfo.systemUptime - start < 0.65
        let initial = positions[0].y
        let distance = table.visibleRect.minY - initial
        XCTAssertGreaterThan(distance, 1)
        if distance > 1 {
            let nearest = positions.min { abs($0.time - 0.1) < abs($1.time - 0.1) }!
            let steps = zip(positions, positions.dropFirst()).map { before, after in
                (delta: abs(after.y - before.y), interval: after.time - before.time)
            }
            let first = steps.first { $0.delta > 0 }
            let largest = steps.max { $0.delta < $1.delta }
            print(String(format: "CENTER_MOTION reader=%d reduced=%d distance=%.1f firstStep=%.1f progressAt100ms=%.1f%% sampleTimeMs=%.1f maxStep=%.1f maxStepIntervalMs=%.1f",
                         withReader ? 1 : 0, reduceMotion ? 1 : 0, distance, first?.delta ?? 0, 100 * (nearest.y - initial) / distance,
                         nearest.time * 1000, largest?.delta ?? 0, (largest?.interval ?? 0) * 1000))
            if !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertTrue(positions.contains { $0.y > initial + 1 && $0.y < initial + distance - 1 },
                              "A normal edge key press should animate through an intermediate visible offset")
            }
        }
        XCTAssertEqual(table.selectedRow, edge + 1)
        XCTAssertTrue(fullyVisible(edge + 1))
        XCTAssertEqual(table.rect(ofRow: edge + 2).midY, table.visibleRect.midY, accuracy: 2)
        if withReader {
            try await waitForArticle(edge + 1)
            return
        }
        for _ in (edge + 2)...104 {
            try arrow(down: true, repeating: true)
            try await Task.sleep(for: .milliseconds(35))
        }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(table.selectedRow, 104)
        XCTAssertTrue(fullyVisible(104))
        try arrow(down: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(selection.selectedID, "103")
        XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: table.selectedRow)))
        // Reader navigation changes the selection and issues its own scroll request.
        selection.selectedID = "4"
        selection.scrollRequest = UUID()
        for _ in 0..<60 {
            if table.selectedRow == 4 && fullyVisible(4) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(table.selectedRow, 4)
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: 4)))
    }
}
