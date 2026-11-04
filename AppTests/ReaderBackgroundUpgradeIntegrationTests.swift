import AppKit
import PaperRssCore
import SwiftUI
import WebKit
import XCTest
@testable import PaperRssDesktop

private actor GatedReaderPageLoader: ArticlePageLoading {
    private var continuation: CheckedContinuation<LoadedArticlePage?, Error>?
    private var cancelled = false
    private(set) var requestCount = 0

    func loadPage(for url: URL) async throws -> LoadedArticlePage? {
        requestCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func release(_ page: LoadedArticlePage) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: page)
    }

    func cancel() {
        cancelled = true
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ReaderBackgroundUpgradeLoopState {
    var didStart = false
    var result: Result<Void, Error>?
}

@MainActor
private func stopReaderBackgroundUpgradeLoop() {
    NSApp.stop(nil)
    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(event, atStart: true)
    }
}

/// Uses the real Reader and its WKWebView, with only the webpage response gated.
/// This test never launches the installed application or opens the user's library.
@MainActor
final class ReaderBackgroundUpgradeIntegrationTests: XCTestCase {
    private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }

    private func accessibilityElement(_ identifier: String, in view: NSView, diagnose: Bool = false) -> NSObject? {
        var pending: [Any] = [view]
        if let window = view.window { pending.append(window) }
        var visited: Set<ObjectIdentifier> = []
        var identifiers: [String] = []
        var buttons: [String] = []
        while !pending.isEmpty {
            let node = pending.removeLast()
            guard let object = node as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let accessible = node as? any NSAccessibilityProtocol
            // SwiftUI can expose logical AX nodes through the public informal
            // API without declaring the complete protocol or getter methods.
            let nodeIdentifier = accessible?.accessibilityIdentifier()
                ?? object.accessibilityAttributeValue(.identifier) as? String
            if nodeIdentifier == identifier { return object }
            if let nodeIdentifier { identifiers.append(nodeIdentifier) }
            if accessible?.accessibilityRole() == .button || object.accessibilityAttributeValue(.role) as? String == "AXButton" {
                buttons.append(accessible?.accessibilityLabel() ?? object.accessibilityAttributeValue(.title) as? String ?? "unlabelled")
            }
            let children = accessible?.accessibilityChildren()
                ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
            pending.append(contentsOf: children)
            if let nativeView = node as? NSView { pending.append(contentsOf: nativeView.subviews) }
        }
        if diagnose {
            print("READER_BACKGROUND_UPGRADE AX visited=\(visited.count) identifiers=\(Array(identifiers.prefix(20))) buttons=\(Array(buttons.prefix(20)))")
        }
        return nil
    }

    private func saveFailureSnapshot(of view: NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/reports/reader-background-upgrade-offer.png")
        do {
            try data.write(to: output, options: .atomic)
            print("READER_BACKGROUND_UPGRADE diagnosticSnapshot=\(output.path)")
        } catch {
            print("READER_BACKGROUND_UPGRADE diagnosticSnapshotError=\(error)")
        }
    }

    private func pressReadyOffer(in host: NSView, window: NSWindow) throws -> String {
        if let button = accessibilityElement("reader.fullContentReady", in: host) {
            if let accessible = button as? any NSAccessibilityProtocol {
                XCTAssertTrue(accessible.accessibilityPerformPress())
            } else {
                button.accessibilityPerformAction(.press)
            }
            return "accessibilityIdentifier"
        }
        // This standalone XCTest process may not export SwiftUI's logical AX
        // children until an assistive client connects. Target the visible offer
        // directly before falling back to genuine events in this test window.
        let localPoint = NSPoint(x: host.bounds.maxX - 65,
                                 y: host.isFlipped ? host.bounds.maxY - 26 : host.bounds.minY + 26)
        let windowPoint = host.convert(localPoint, to: nil)
        if let accessible = host.accessibilityHitTest(window.convertPoint(toScreen: windowPoint)) as? any NSAccessibilityProtocol,
           accessible.accessibilityRole() == .button {
            XCTAssertTrue(accessible.accessibilityPerformPress())
            return "accessibilityHitTest"
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
            modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
            modifierFlags: [], timestamp: timestamp + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return "windowMouseEvents (SwiftUI AX subtree unavailable)"
    }

    private func evaluate(_ script: String, in web: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) {
                continuation.resume(with: $0.map { $0 as? String ?? "" })
            }
        }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 12,
                           _ predicate: @MainActor () async throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            NSApp.updateWindows()
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail(description)
        throw NSError(domain: "ReaderBackgroundUpgradeIntegrationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func documentState(in web: WKWebView) async throws -> [String: Any] {
        let json = try await evaluate("""
        JSON.stringify({
          text: document.body.innerText,
          generation: document.querySelector('meta[name="paper-rss-load-generation"]')?.content,
          identity: document.querySelector('meta[name="paper-rss-document-identity"]')?.content,
          token: window.__backgroundUpgradeFixtureToken,
          scrollY: window.scrollY,
          selection: window.getSelection()?.toString()
        })
        """, in: web)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testLocalPaintPrecedesNetworkAndFullContentRequiresExplicitPress() throws {
        try VisibleWindowTestSupport.requireGUI()
        _ = NSApplication.shared
        guard !NSApp.isRunning else {
            throw XCTSkip("Reader 后台全文 GUI 测试需要独立 XCTest 进程负责 AppKit event loop")
        }
        let state = ReaderBackgroundUpgradeLoopState()
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            state.didStart = true
            do {
                try await runLocalPaintAndBackgroundUpgrade()
                state.result = .success(())
            } catch {
                state.result = .failure(error)
            }
            stopReaderBackgroundUpgradeLoop()
        }
        // XCTest's own run loop does not start the AppKit activation/occlusion
        // lifecycle. A real application loop is required for visible WK paints.
        let startupWatchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !state.didStart else { return }
                state.result = .failure(NSError(domain: "ReaderBackgroundUpgradeIntegrationTests", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AppKit event loop did not start the reader test task"]))
                stopReaderBackgroundUpgradeLoop()
            }
        }
        let hardWatchdog = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard state.result == nil else { return }
                state.result = .failure(NSError(domain: "ReaderBackgroundUpgradeIntegrationTests", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Reader background upgrade exceeded its 45-second watchdog"]))
                stopReaderBackgroundUpgradeLoop()
            }
        }
        defer { startupWatchdog.invalidate(); hardWatchdog.invalidate(); task.cancel() }
        NSApp.run()
        guard let result = state.result else {
            XCTFail("AppKit event loop exited before the background upgrade test completed")
            return
        }
        try result.get()
    }

    private func runLocalPaintAndBackgroundUpgrade() async throws {
        let previousPolicy = NSApp.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        XCTAssertTrue(NSApp.setActivationPolicy(.regular))
        defer {
            NSApp.setActivationPolicy(previousPolicy)
            if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate(options: [])
            }
        }
        let loader = GatedReaderPageLoader()
        let feed = Feed(title: "Isolated Reader fixture", feedURL: URL(string: "https://example.invalid/feed")!)
        let localBody = (0..<60).map {
            "<p>LOCAL_READING_MARKER paragraph \($0). " +
            String(repeating: "Existing content remains readable while a complete response is pending. ", count: 3) + "</p>"
        }.joined() + "<p>Read more</p>"
        let fullBody = (0..<150).map {
            "<p>FULL_CONTENT_MARKER paragraph \($0). " +
            String(repeating: "The complete story provides additional background, measurements and conclusions. ", count: 3) + "</p>"
        }.joined()
        let entry = Entry(id: "background-upgrade-fixture", feedID: feed.id, title: "Background upgrade fixture",
                          url: URL(string: "https://example.invalid/story"), contentHTML: localBody)
        var configuration = LLMConfiguration.default
        configuration.showsAISummary = false
        configuration.automaticallyGenerateSummary = false
        let store = AppStore(testDatabase: AppDatabase(feeds: [feed], entries: [entry],
            articleCaches: [:], readingStates: [:], artifacts: [], llmConfiguration: configuration), pageLoader: loader)
        let reader = ArticleReaderView(store: store, aiWorkspace: store.aiWorkspace, entry: entry,
                                       autoMarkRead: false, appearanceMode: .light)
            .environmentObject(store.iconStore)
            .frame(minWidth: 700, minHeight: 640)
        let host = NSHostingView(rootView: reader)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.contentView = host
        try VisibleWindowTestSupport.show(window: window, makeKey: true)
        NSApp.activate(ignoringOtherApps: true)
        window.display()
        NSApp.updateWindows()
        defer {
            webView(in: host)?.stopLoading()
            window.close()
            Task { await loader.cancel() }
        }

        // A background request can start only after Reader's actual painted
        // message. Its response remains suspended throughout these assertions.
        var lastDocumentStatus = "WebView not mounted"
        do {
            try await waitUntil("The local document must paint before the webpage response is released") {
                guard let web = self.webView(in: host), web.window === window else { return false }
                lastDocumentStatus = (try? await self.evaluate("JSON.stringify({visibility: document.visibilityState, ready: document.readyState, local: document.body?.innerText.includes('LOCAL_READING_MARKER') === true})", in: web)) ?? "JavaScript not ready"
                guard await loader.requestCount == 1 else { return false }
                return (try? await self.evaluate("String(document.visibilityState === 'visible' && document.body?.innerText.includes('LOCAL_READING_MARKER') === true)", in: web)) == "true"
            }
        } catch {
            print("READER_BACKGROUND_UPGRADE initialDocument=\(lastDocumentStatus) windowVisible=\(window.isVisible) appActive=\(NSApp.isActive)")
            throw error
        }
        let web = try XCTUnwrap(webView(in: host))
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(web.isHiddenOrHasHiddenAncestor)
        XCTAssertNil(try store.localProvider.fetchCache(entryID: entry.id))
        XCTAssertNil(accessibilityElement("reader.fullContentReady", in: host))
        _ = try await evaluate("""
        (() => {
          window.__backgroundUpgradeFixtureToken = 'original-local-document';
          window.scrollTo(0, 700);
          const paragraph = Array.from(document.querySelectorAll('p')).find(p => p.innerText.includes('paragraph 12.'));
          const range = document.createRange();
          range.setStart(paragraph.firstChild, 0);
          range.setEnd(paragraph.firstChild, 20);
          const selection = window.getSelection();
          selection.removeAllRanges(); selection.addRange(range);
          return 'selected';
        })()
        """, in: web)
        try await Task.sleep(for: .milliseconds(150))
        let before = try await documentState(in: web)
        XCTAssertGreaterThan(try XCTUnwrap(before["scrollY"] as? Double), 100)
        XCTAssertFalse(try XCTUnwrap(before["selection"] as? String).isEmpty)
        XCTAssertEqual(before["identity"] as? String, entry.id)
        XCTAssertFalse(try XCTUnwrap(before["text"] as? String).contains("FULL_CONTENT_MARKER"))
        print("READER_BACKGROUND_UPGRADE localPaintBeforeResponse=true generation=\(before["generation"] ?? "missing")")

        await loader.release(LoadedArticlePage(html: "<html><body><article>\(fullBody)</article></body></html>",
                                              finalURL: try XCTUnwrap(entry.url)))
        var lastOfferStatus = "Not checked"
        do {
            try await waitUntil("The completed background response must become available in the article cache") {
                let cached = try store.localProvider.fetchCache(entryID: entry.id)
                let cachedFullContent = cached?.text.contains("FULL_CONTENT_MARKER") == true
                let buttonExists = self.accessibilityElement("reader.fullContentReady", in: host) != nil
                lastOfferStatus = "cachedFullContent=\(cachedFullContent) cachedCharacters=\(cached?.text.count ?? 0) buttonExists=\(buttonExists)"
                return cachedFullContent
            }
        } catch {
            print("READER_BACKGROUND_UPGRADE offer=\(lastOfferStatus) memorySource=\(store.memoizedPreparedArticle(for: entry)?.source.rawValue ?? "none")")
            _ = accessibilityElement("reader.fullContentReady", in: host, diagnose: true)
            saveFailureSnapshot(of: host)
            throw error
        }
        try await Task.sleep(for: .milliseconds(150))
        let after = try await documentState(in: web)
        XCTAssertEqual(after["generation"] as? String, before["generation"] as? String)
        XCTAssertEqual(after["identity"] as? String, before["identity"] as? String)
        XCTAssertEqual(after["token"] as? String, "original-local-document")
        XCTAssertEqual(after["text"] as? String, before["text"] as? String)
        XCTAssertEqual(after["selection"] as? String, before["selection"] as? String)
        XCTAssertEqual(try XCTUnwrap(after["scrollY"] as? Double),
                       try XCTUnwrap(before["scrollY"] as? Double), accuracy: 1)
        XCTAssertNil(store.articleRefreshSignal)
        saveFailureSnapshot(of: host)
        print("READER_BACKGROUND_UPGRADE readyOffer=true documentScrollAndSelectionPreserved=true")

        let interaction = try pressReadyOffer(in: host, window: window)
        try await waitUntil("The document must change only after the explicit full-content button press") {
            (try? await self.evaluate("String(document.body?.innerText.includes('FULL_CONTENT_MARKER') === true)", in: web)) == "true"
        }
        let applied = try await documentState(in: web)
        XCTAssertNotEqual(applied["generation"] as? String, before["generation"] as? String)
        XCTAssertEqual(applied["identity"] as? String, entry.id)
        XCTAssertNil(applied["token"])
        XCTAssertLessThan(try XCTUnwrap(applied["scrollY"] as? Double), 5)
        let requests = await loader.requestCount
        XCTAssertEqual(requests, 1)
        print("READER_BACKGROUND_UPGRADE explicitButtonApplied=true interaction=\(interaction) webpageRequests=\(requests)")
    }
}
