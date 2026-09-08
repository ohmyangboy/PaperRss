import AppKit
import QuartzCore
import SwiftUI
import XCTest
import Darwin
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
private final class SidebarScrollModel: ObservableObject {
    @Published var completed = 0
    let feedIDs = (0..<3000).map { _ in UUID() }
}

@MainActor
private struct SidebarScrollFixture: View {
    @ObservedObject var model: SidebarScrollModel
    let reduceMotion: Bool
    var flatFeeds = false

    var body: some View {
        List {
            SidebarRow("同步测试账号", systemImage: "desktopcomputer", count: model.completed * 50,
                       syncProgress: AccountRefreshProgress(completed: model.completed, total: 100), pulsesWhileSyncing: !reduceMotion)
                        .equatable()
            if flatFeeds {
                ForEach(0..<3000) { index in
                    SidebarRow("wechat2rss.bestblogs 订阅 \(index)", systemImage: "dot.radiowaves.left.and.right",
                               iconURL: URL(fileURLWithPath: "/tmp/paperrss-perf-missing-icon.png"),
                               count: index < model.completed ? 20 : 10, feedID: model.feedIDs[index])
                        .equatable()
                }
            } else {
            ForEach(0..<500) { folder in
                DisclosureGroup(isExpanded: .constant(folder % 10 == 0)) {
                    ForEach(0..<6) { feed in
                        SidebarRow("订阅 \(folder)-\(feed)", systemImage: "dot.radiowaves.left.and.right", count: 20)
                            .equatable()
                    }
                } label: {
                    SidebarRow("文件夹 \(folder)", systemImage: folder % 10 == 0 ? "folder.fill" : "folder",
                               count: 120 + model.completed,
                               isSyncing: true, pulsesWhileSyncing: !reduceMotion)
                        .equatable()
                }
            }
            }
        }
        .listStyle(.sidebar)
    }
}

@MainActor
private final class SidebarFrameRecorder: NSObject {
    var intervals: [Double] = []
    var scrollView: NSScrollView?
    var model: SidebarScrollModel?
    var previous: Double?
    var started = CACurrentMediaTime()
    var lastBatch = 0.0
    var updateScheduled = false

    @objc func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previous { intervals.append(now - previous) }
        previous = now
        // 显示回调只采样；滚动和模型变更排到下一主线程任务，避免重入 AppKit 布局。
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [self] in
            defer { updateScheduled = false }
            let elapsed = now - started
            if elapsed - lastBatch >= 0.3 {
                model?.completed += 1
                lastBatch = elapsed
            }
            if let scrollView, let document = scrollView.documentView {
                let range = max(0, document.bounds.height - scrollView.contentView.bounds.height)
                let fraction = (1 - cos(elapsed * .pi / 3)) / 2
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: range * fraction))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}

@MainActor
final class SidebarScrollPerformanceTests: XCTestCase {
    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap(findScrollView).first
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func measureScrolling(reduceMotion: Bool, flatFeeds: Bool = false) async throws -> (p95: Double, maximum: Double, cpu: Double) {
        let model = SidebarScrollModel()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-perf-\(UUID())")
        let icons = FeedIconStore(directory: cache)
        defer { try? FileManager.default.removeItem(at: cache) }
        let host = NSHostingView(rootView: SidebarScrollFixture(model: model, reduceMotion: reduceMotion, flatFeeds: flatFeeds).environmentObject(icons))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "侧边栏滚动性能验证"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        let scroll = try XCTUnwrap(findScrollView(host))
        let recorder = SidebarFrameRecorder()
        recorder.scrollView = scroll
        recorder.model = model
        let link = host.displayLink(target: recorder, selector: #selector(SidebarFrameRecorder.tick(_:)))
        let cpuStart = cpuSeconds()
        recorder.started = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        try await Task.sleep(for: .seconds(6))
        link.invalidate()
        let cpu = cpuSeconds() - cpuStart
        let intervals = recorder.intervals.sorted()
        XCTAssertGreaterThan(intervals.count, 100, "必须采集实际绘制期间的显示回调")
        return (intervals[Int(Double(intervals.count - 1) * 0.95)], intervals.last ?? 0, cpu)
    }

    func testFiveHundredFoldersScrollDuringBatchUpdates() async throws {
        guard ProcessInfo.processInfo.environment["PAPERRSS_RUN_SIDEBAR_PERF"] == "1" else {
            throw XCTSkip("需显式开启真实窗口滚动性能验证")
        }
        _ = NSApplication.shared
        let baseline = try await measureScrolling(reduceMotion: true)
        let animated = try await measureScrolling(reduceMotion: false)
        print("SIDEBAR_PERF folders=500 feeds=3000 expandedFolders=50 baseline=\(baseline) animated=\(animated)")
        XCTAssertLessThan(animated.p95, 0.05, "动画与计数更新期间出现持续帧间隔超标")
        XCTAssertLessThan(animated.maximum, 0.15, "滚动出现明显长帧")
        XCTAssertLessThan(animated.cpu, baseline.cpu * 1.75 + 0.4, "动画导致 CPU 开销显著放大")
    }
    func testThreeThousandFeedsScrollDuringImportBatchUpdates() async throws {
        guard ProcessInfo.processInfo.environment["PAPERRSS_RUN_SIDEBAR_PERF"] == "1" else {
            throw XCTSkip("需显式开启真实窗口滚动性能验证")
        }
        _ = NSApplication.shared
        let result = try await measureScrolling(reduceMotion: false, flatFeeds: true)
        print("SIDEBAR_PERF flatFeeds=3000 batches=20 result=\(result)")
        XCTAssertLessThan(result.p95, 0.05)
        XCTAssertLessThan(result.maximum, 0.15)
    }

}
