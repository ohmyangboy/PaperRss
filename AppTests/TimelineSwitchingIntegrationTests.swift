import AppKit
import PaperRssCore
import SwiftUI
import XCTest
@testable import PaperRssDesktop

@MainActor
private final class TimelineSwitchFixtureState: ObservableObject {
    @Published var selection: SidebarSelection
    @Published var selectedID: String?
    @Published var scrollRequest = UUID()
    @Published var showsReader = true

    init(feedID: UUID) { selection = .feed(feedID) }

    func select(_ selection: SidebarSelection, memory: TimelinePresentationMemory) {
        guard self.selection != selection else { return }
        selectedID = nil
        memory.requestSwitch()
        self.selection = selection
    }
}

private struct TimelineSwitchFixture: View {
    let store: AppStore
    @ObservedObject var state: TimelineSwitchFixtureState
    @ObservedObject var memory: TimelinePresentationMemory
    @State private var retainedIDs: Set<String> = []
    @StateObject private var focus = PaperColumnFocusState()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(memory.displayedContext?.selection.title ?? "")
                    .frame(height: 28)
                EntryListView(store: store, appearanceMode: .light, selection: state.selection,
                    selectedEntryID: $state.selectedID, retainedUnreadIDs: $retainedIDs,
                    columnFocusState: focus, titleTranslator: store.titleTranslator,
                    autoScrollTrigger: state.scrollRequest, presentation: memory)
            }
            .frame(width: 390)
            Group {
                if state.showsReader, let id = state.selectedID, let entry = store.entry(id: id) {
                    ArticleReaderView(store: store, aiWorkspace: store.aiWorkspace, entry: entry, appearanceMode: .light)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity)
        }
        .environmentObject(store.iconStore)
        .frame(width: 900, height: 700)
    }
}

@MainActor
private final class TimelineSwitchLoopState {
    var started = false
    var result: Result<Void, Error>?
}

@MainActor
private func stopTimelineSwitchApplicationLoop() {
    NSApp.stop(nil)
    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(event, atStart: true)
    }
}

/// Native table-layout evidence in a temporary test library. It does not claim
/// pixel first-paint timing; visible execution remains an explicit GUI opt-in.
@MainActor
final class TimelineSwitchingIntegrationTests: XCTestCase {
    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }

    func testNonemptyFeedSwitchesKeepNativeRowsAndRejectPendingSelection() throws {
        try VisibleWindowTestSupport.requireGUI()
        _ = NSApplication.shared
        guard !NSApp.isRunning else { throw XCTSkip("Native switching fixture requires its own AppKit event loop") }
        let state = TimelineSwitchLoopState()
        let work = Task { @MainActor in
            state.started = true
            do {
                try await self.runNonemptyFeedSwitches()
                state.result = .success(())
            } catch {
                state.result = .failure(error)
            }
            stopTimelineSwitchApplicationLoop()
        }
        let watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard state.result == nil else { return }
                state.result = .failure(NSError(domain: "TimelineSwitchingIntegrationTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Native switching fixture exceeded its AppKit run-loop watchdog"]))
                stopTimelineSwitchApplicationLoop()
            }
        }
        defer { watchdog.invalidate(); work.cancel() }
        NSApp.run()
        guard let result = state.result else { XCTFail("AppKit exited before the switching fixture completed"); return }
        try result.get()
    }

    private func runNonemptyFeedSwitches() async throws {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {
            NSApp.setActivationPolicy(previousActivationPolicy)
            if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                VisibleWindowTestSupport.restoreApplication(previousApplication)
            }
        }
        let a = Feed(title: "Switch A", feedURL: URL(string: "https://switch.invalid/a")!)
        let b = Feed(title: "Switch B", feedURL: URL(string: "https://switch.invalid/b")!)
        let empty = Feed(title: "Empty", feedURL: URL(string: "https://switch.invalid/empty")!)
        let now = Date()
        let entries = [(a, 60), (b, 80)].flatMap { feed, count in
            (0..<count).map { index in
                Entry(id: "\(feed.id)-\(index)", feedID: feed.id, title: "\(feed.title) \(index)",
                    publishedAt: now.addingTimeInterval(-Double(index)), summary: "Local fixture",
                    contentHTML: String(repeating: "<p>本地正文，切换测试不请求网络。</p>", count: 30))
            }
        }
        let store = AppStore(testDatabase: AppDatabase(feeds: [a, b, empty], entries: entries,
            articleCaches: [:], readingStates: [:], artifacts: [], llmConfiguration: .default))
        let state = TimelineSwitchFixtureState(feedID: a.id)
        let memory = TimelinePresentationMemory()
        let host = NSHostingController(rootView: TimelineSwitchFixture(store: store, state: state, memory: memory))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        try VisibleWindowTestSupport.show(window: window, makeKey: true)
        try VisibleWindowTestSupport.bringForward(window: window)
        defer { window.close() }
        let activationDeadline = ProcessInfo.processInfo.systemUptime + 3
        while (!NSApp.isActive || !window.isKeyWindow || !window.isOnActiveSpace || !window.occlusionState.contains(.visible)),
              ProcessInfo.processInfo.systemUptime < activationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(NSApp.isActive)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.isOnActiveSpace)
        XCTAssertTrue(window.occlusionState.contains(.visible))
        print("TIMELINE_SWITCH_WINDOW active=\(NSApp.isActive) key=\(window.isKeyWindow) activeSpace=\(window.isOnActiveSpace) visible=\(window.occlusionState.contains(.visible))")

        var sampledCounts: [Int] = []
        func settle(_ feed: Feed, count: Int, requireNonempty: Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            repeat {
                host.view.layoutSubtreeIfNeeded()
                if let table = self.table(in: host.view) {
                    let rows = table.numberOfRows
                    sampledCounts.append(rows)
                    if requireNonempty { XCTAssertGreaterThan(rows, 0, "A nonempty scope switch exposed an empty native table") }
                    if !memory.isSwitching, memory.displayedContext?.selection == .feed(feed.id), rows == count {
                        XCTAssertEqual(memory.displayedContext?.unreadOnly, false)
                        XCTAssertEqual(memory.displayedContext?.scope, .feed(feedID: feed.id.uuidString))
                        // Sample additional layout turns so delayed native reconciliation
                        // cannot make a transient empty page pass as a settled page.
                        for _ in 0..<4 {
                            try await Task.sleep(for: .milliseconds(5))
                            host.view.layoutSubtreeIfNeeded()
                            XCTAssertEqual(self.table(in: host.view)?.numberOfRows, count)
                        }
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(2))
            } while ProcessInfo.processInfo.systemUptime < deadline
            XCTFail("Native table did not commit \(feed.title) with \(count) rows; context=\(String(describing: memory.displayedContext)), pending=\(memory.isSwitching)")
        }
        try await settle(a, count: 60, requireNonempty: false)
        sampledCounts.removeAll()
        let initialUnread = store.sidebarCounts.allUnread
        let nativeTable = try XCTUnwrap(table(in: host.view))
        _ = window.makeFirstResponder(nativeTable)
        nativeTable.scrollRowToVisible(30)
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        print("TIMELINE_SWITCH_SCROLL sourceFirstVisible=\(nativeTable.rows(in: nativeTable.visibleRect).location) visibleHeight=\(nativeTable.visibleRect.height) windowHeight=\(window.frame.height)")
        XCTAssertGreaterThan(nativeTable.rows(in: nativeTable.visibleRect).location, 0)

        state.select(.feed(b.id), memory: memory)
        XCTAssertTrue(memory.isSwitching)
        XCTAssertEqual(memory.displayedContext?.selection, .feed(a.id))
        nativeTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        nativeTable.keyDown(with: down)
        XCTAssertNil(state.selectedID)
        try await settle(b, count: 80, requireNonempty: true)
        let bTable = try XCTUnwrap(table(in: host.view))
        let bFirstVisibleRow = bTable.rows(in: bTable.visibleRect).location
        print("TIMELINE_SWITCH_SCROLL firstVisibleRowAfterSwitch=\(bFirstVisibleRow)")
        XCTAssertEqual(bFirstVisibleRow, 0, "A new feed should retain the existing start-at-top behavior")
        XCTAssertNil(state.selectedID)
        XCTAssertEqual(store.sidebarCounts.allUnread, initialUnread)
        XCTAssertTrue(entries.allSatisfy { store.entry(id: $0.id)?.isRead == false })

        for _ in 0..<3 {
            state.select(.feed(a.id), memory: memory)
            try await settle(a, count: 60, requireNonempty: true)
            state.select(.feed(b.id), memory: memory)
            try await settle(b, count: 80, requireNonempty: true)
        }
        // Both changes can be consumed in the same SwiftUI update. The request
        // nonce must restart loading even though the final context is still B.
        state.select(.feed(a.id), memory: memory)
        state.select(.feed(b.id), memory: memory)
        try await settle(b, count: 80, requireNonempty: true)
        XCTAssertFalse(memory.isSwitching)
        // Programmatic article navigation can arrive before the new feed page.
        // Disable the fixture reader here: this checks list centering, and must
        // preserve the agent-open policy of not marking the target read.
        state.showsReader = false
        state.select(.feed(a.id), memory: memory)
        let agentTarget = "\(a.id)-40"
        state.selectedID = agentTarget
        state.scrollRequest = UUID()
        try await settle(a, count: 60, requireNonempty: true)
        let scrollDeadline = ProcessInfo.processInfo.systemUptime + 2
        var centered = false
        repeat {
            host.view.layoutSubtreeIfNeeded()
            if let table = table(in: host.view), table.numberOfRows > 40,
               table.visibleRect.contains(table.rect(ofRow: 40)) {
                centered = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        } while ProcessInfo.processInfo.systemUptime < scrollDeadline
        if let table = table(in: host.view) {
            print("TIMELINE_SWITCH_TARGET selectedRow=\(table.selectedRow) targetRect=\(table.rect(ofRow: 40)) visibleRect=\(table.visibleRect) generation=\(memory.pageGeneration) geometryWouldCenter=\(memory.shouldCenterSelection(agentTarget))")
        }
        XCTAssertTrue(centered, "Pending programmatic selection must scroll after the page commits")
        XCTAssertEqual(state.selectedID, agentTarget)
        XCTAssertEqual(store.sidebarCounts.allUnread, initialUnread)
        state.select(.feed(b.id), memory: memory)
        try await settle(b, count: 80, requireNonempty: true)
        let nonemptyMinimum = sampledCounts.min() ?? 0
        XCTAssertGreaterThan(nonemptyMinimum, 0)

        state.select(.feed(empty.id), memory: memory)
        XCTAssertEqual(table(in: host.view)?.numberOfRows, 80)
        XCTAssertEqual(memory.displayedContext?.selection, .feed(b.id))
        try await settle(empty, count: 0, requireNonempty: false)
        XCTAssertEqual(table(in: host.view)?.numberOfRows, 0)
        print("TIMELINE_SWITCH_NATIVE_LAYOUT nonemptyMinRows=\(nonemptyMinimum) samples=\(sampledCounts.count) emptyCommitted=true pendingSelectionRejected=true agentTargetCentered=\(centered)")
    }
}
