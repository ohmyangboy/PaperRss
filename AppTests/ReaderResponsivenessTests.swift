import AppKit
import Foundation
import PaperRssCore
import SwiftUI
import WebKit
import XCTest
@testable import PaperRssDesktop

@MainActor
private final class ReaderPerfSelection: ObservableObject {
    @Published var entry: Entry
    init(entry: Entry) { self.entry = entry }
}

private struct ReaderPerfHost: View {
    @ObservedObject var store: AppStore
    @ObservedObject var selection: ReaderPerfSelection

    var body: some View {
        ArticleReaderView(store: store, aiWorkspace: store.aiWorkspace, entry: selection.entry,
                          autoMarkRead: false, appearanceMode: .light)
            .environmentObject(store.iconStore)
            .frame(minWidth: 800, minHeight: 700)
    }
}

private actor ReaderPerfPageLoader: ArticlePageLoading {
    private(set) var requestCount = 0

    func loadPage(for url: URL) async throws -> LoadedArticlePage? {
        requestCount += 1
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
private final class ReaderPaintRecorder: NSObject, WKScriptMessageHandler {
    static let messageName = "paperRssTestDocumentPainted"
    private var expectedID: String?
    private var startedAt: TimeInterval = 0
    private(set) var elapsedMS: Double?

    func arm(entryID: String) {
        expectedID = entryID
        elapsedMS = nil
        startedAt = ProcessInfo.processInfo.systemUptime
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              body["entryID"] as? String == expectedID,
              body["visible"] as? Bool == true,
              elapsedMS == nil else { return }
        elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    }

    static let script = WKUserScript(source: """
    (() => {
      const entryID = document.querySelector('meta[name="paper-rss-document-identity"]')?.content;
      if (!entryID) return;
      requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(() => {
        window.webkit.messageHandlers.paperRssTestDocumentPainted.postMessage({
          entryID,
          visible: document.visibilityState === 'visible' && document.body.getBoundingClientRect().height > 0
        });
      }, 0)));
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
}

@MainActor
private final class ReaderPerfLoopState {
    var didStart = false
    var result: Result<Void, Error>?
}

@MainActor
private func stopReaderPerfApplicationLoop() {
    NSApp.stop(nil)
    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(event, atStart: true)
    }
}

/// Explicit GUI-only benchmark. Use the identical file against HEAD and the
/// optimized source with `swift test -c release --filter ReaderResponsivenessTests`.
/// Measurements end at the target Web document's double-rAF paint message, not
/// at SQL completion, DOM-ready, didFinish, or the beginning of navigation.
@MainActor
final class ReaderResponsivenessTests: XCTestCase {
    private struct Sample: Codable {
        let scenario: String
        let iteration: Int
        let entryID: String
        let milliseconds: Double
    }

    private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }

    private func scriptString(_ script: String, in web: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) {
                continuation.resume(with: $0.map { $0 as? String ?? "" })
            }
        }
    }

    private func saveSnapshot(of web: WKWebView, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = web.bounds
            web.takeSnapshot(with: configuration) { image, error in
                do {
                    if let error { throw error }
                    guard let data = image?.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: data),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "ReaderResponsivenessTests", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "WebView snapshot returned no image"])
                    }
                    try png.write(to: url, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func testReleaseSelectionThroughFirstDocumentPaint() throws {
        try VisibleWindowTestSupport.requireGUI()
        guard ProcessInfo.processInfo.environment["PAPERRSS_RUN_READER_PERF"] == "1" else {
            throw XCTSkip("Reader 首帧性能测试需另外设置 PAPERRSS_RUN_READER_PERF=1")
        }
        _ = NSApplication.shared
        guard !NSApp.isRunning else {
            throw XCTSkip("Reader 基准需要独立 XCTest 进程负责 AppKit event loop")
        }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousActivationPolicy = NSApp.activationPolicy()
        defer {
            NSApp.setActivationPolicy(previousActivationPolicy)
            if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate(options: [])
            }
        }
        let state = ReaderPerfLoopState()
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            state.didStart = true
            do {
                try await runSelectionThroughFirstDocumentPaint()
                state.result = .success(())
            } catch {
                state.result = .failure(error)
            }
            stopReaderPerfApplicationLoop()
        }
        // Running NSApplication is necessary for a command-line XCTest host
        // to register its windows on the active Space and receive occlusion.
        // A timer bounds startup if this runner cannot service actor tasks.
        let startupWatchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !state.didStart else { return }
                state.result = .failure(NSError(domain: "ReaderResponsivenessTests", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "AppKit event loop did not service the benchmark task"]))
                stopReaderPerfApplicationLoop()
            }
        }
        let hardWatchdog = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard state.result == nil else { return }
                state.result = .failure(NSError(domain: "ReaderResponsivenessTests", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Reader fixture exceeded the 45-second AppKit run-loop watchdog"]))
                stopReaderPerfApplicationLoop()
            }
        }
        defer { startupWatchdog.invalidate(); hardWatchdog.invalidate(); task.cancel() }
        NSApp.run()
        guard let result = state.result else {
            XCTFail("AppKit event loop exited before the benchmark completed")
            return
        }
        try result.get()
    }

    private func runSelectionThroughFirstDocumentPaint() async throws {
        NSApp.setActivationPolicy(.regular)
        if !NSApp.isRunning { NSApp.finishLaunching() }
        let artifactDirectory: URL
        if let output = ProcessInfo.processInfo.environment["PAPERRSS_READER_PERF_OUTPUT"] {
            artifactDirectory = URL(fileURLWithPath: output, isDirectory: true)
        } else {
            artifactDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-responsiveness")
        }
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        let feedID = UUID(uuidString: "DA27D532-0235-4A32-983B-7EAB454F5063")!
        let feed = Feed(id: feedID, title: "Reader responsiveness fixture",
                        feedURL: URL(fileURLWithPath: "/reader-responsiveness-fixture.xml"))
        let short = Entry(id: "reader-perf-bootstrap", feedID: feed.id, title: "Bootstrap",
                          publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
                          contentHTML: "<p>reader-perf-bootstrap 本地短正文。</p>")
        let warmup = Entry(id: "reader-perf-warmup", feedID: feed.id, title: "Warmup",
                           publishedAt: Date(timeIntervalSince1970: 1_800_000_001),
                           contentHTML: "<p>reader-perf-warmup 本地短正文。</p>")
        let paragraph = "中文长正文👨‍👩‍👧‍👦与组合字符é，介绍背景、过程、证据和结论。"
        let body = String(repeating: "<div class=\"content-section\"><div><p>\(paragraph)</p></div></div>\n", count: 1_000)
        let longEntries = (0..<7).map { index in
            Entry(id: "reader-perf-long-\(index)", feedID: feed.id,
                  title: "确定性长文 \(index)", publishedAt: Date(timeIntervalSince1970: 1_800_000_010 + Double(index)),
                  contentHTML: "<article><p>reader-perf-long-\(index) 文章开头。</p>\(body)<p>文章结尾 \(index)。</p></article>")
        }
        let loader = ReaderPerfPageLoader()
        let store = AppStore(testDatabase: AppDatabase(feeds: [feed], entries: [short, warmup] + longEntries,
            articleCaches: [:], readingStates: [:], artifacts: [], llmConfiguration: .default), pageLoader: loader)
        let selection = ReaderPerfSelection(entry: short)
        let host = NSHostingView(rootView: ReaderPerfHost(store: store, selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PaperRss isolated reader benchmark"
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.contentView = host
        try VisibleWindowTestSupport.show(window: window, makeKey: true)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        NSApp.updateWindows()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        var web: WKWebView?
        let bootstrapDeadline = ProcessInfo.processInfo.systemUptime + 30
        repeat {
            if let candidate = webView(in: host),
               (try? await scriptString("document.body?.innerText || ''", in: candidate))?.contains(short.id) == true {
                web = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < bootstrapDeadline
        let readerWeb = try XCTUnwrap(web, "Isolated Reader did not create and display its bootstrap WebView")
        XCTAssertTrue(window.isVisible, "A paint benchmark requires a visible WindowServer surface")
        print("READER_PERF_SURFACE appActive=\(NSApp.isActive) appRunning=\(NSApp.isRunning) windowVisible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible)) activeSpace=\(window.isOnActiveSpace) windowFrame=\(window.frame) hostFrame=\(host.frame) webFrame=\(readerWeb.frame) webBounds=\(readerWeb.bounds) webHiddenAncestor=\(readerWeb.isHiddenOrHasHiddenAncestor)")
        try await saveSnapshot(of: readerWeb, to: artifactDirectory.appendingPathComponent("bootstrap.png"))
        let recorder = ReaderPaintRecorder()
        readerWeb.configuration.userContentController.add(recorder, contentWorld: .defaultClient,
                                                         name: ReaderPaintRecorder.messageName)
        readerWeb.configuration.userContentController.addUserScript(ReaderPaintRecorder.script)
        defer {
            readerWeb.configuration.userContentController.removeScriptMessageHandler(
                forName: ReaderPaintRecorder.messageName, contentWorld: .defaultClient)
        }

        func switchAndMeasure(_ entry: Entry) async throws -> Double {
            recorder.arm(entryID: entry.id)
            selection.entry = entry
            let deadline = ProcessInfo.processInfo.systemUptime + (entry.id == warmup.id ? 5 : 90)
            while recorder.elapsedMS == nil, ProcessInfo.processInfo.systemUptime < deadline {
                NSApp.updateWindows()
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let elapsed = recorder.elapsedMS else {
                let state = try? await scriptString("JSON.stringify({identity:document.querySelector('meta[name=\"paper-rss-document-identity\"]')?.content,visibility:document.visibilityState,ready:document.readyState})", in: readerWeb)
                let currentWeb = webView(in: host)
                XCTFail("Target document never reported a visible painted frame: \(entry.id), state=\(state ?? "unavailable"), visibleWindow=\(window.isVisible), webAttached=\(readerWeb.window === window), webHidden=\(readerWeb.isHidden), sameWeb=\(currentWeb === readerWeb)")
                throw NSError(domain: "ReaderResponsivenessTests", code: 2)
            }
            let content = try await scriptString("document.body?.innerText || ''", in: readerWeb)
            XCTAssertTrue(content.contains(entry.id), "The painted document must contain the selected fixture")
            return elapsed
        }

        // Confirm the test script gets a real visible render callback before
        // collecting samples; initial WebView process startup is excluded.
        _ = try await switchAndMeasure(warmup)
        var samples: [Sample] = []
        for index in 0..<3 {
            let entry = longEntries[index]
            let elapsed = try await switchAndMeasure(entry)
            samples.append(Sample(scenario: "cold-local", iteration: index, entryID: entry.id, milliseconds: elapsed))
            if index == 0 { try await saveSnapshot(of: readerWeb, to: artifactDirectory.appendingPathComponent("cold-local.png")) }
        }
        for index in 0..<3 {
            _ = try await switchAndMeasure(short)
            let entry = longEntries[0]
            let elapsed = try await switchAndMeasure(entry)
            samples.append(Sample(scenario: "memory-warm", iteration: index, entryID: entry.id, milliseconds: elapsed))
        }
        try await saveSnapshot(of: readerWeb, to: artifactDirectory.appendingPathComponent("memory-warm.png"))
        for index in 3..<7 {
            let entry = longEntries[index]
            let elapsed = try await switchAndMeasure(entry)
            samples.append(Sample(scenario: "sequential-local", iteration: index - 3, entryID: entry.id, milliseconds: elapsed))
        }
        try await saveSnapshot(of: readerWeb, to: artifactDirectory.appendingPathComponent("sequential-local.png"))
        let requests = await loader.requestCount
        XCTAssertEqual(requests, 0, "This benchmark must remain entirely local")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: artifactDirectory.appendingPathComponent("samples.json"), options: .atomic)
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        print("READER_FIRST_PAINT fixtureBodyBytes=\(body.utf8.count) nestedDivCount=2000 configuration=\(configuration) networkRequests=\(requests)")
        for scenario in ["cold-local", "memory-warm", "sequential-local"] {
            let values = samples.filter { $0.scenario == scenario }.map(\.milliseconds).sorted()
            let median = (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
            let p95 = values[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)]
            print("READER_FIRST_PAINT scenario=\(scenario) samplesMS=\(values) medianMS=\(median) p95MS=\(p95)")
        }
        print("READER_FIRST_PAINT artifacts=\(artifactDirectory.path)")
    }
}
