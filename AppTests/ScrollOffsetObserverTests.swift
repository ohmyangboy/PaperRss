import AppKit
import XCTest
@testable import PaperRssDesktop

/// `ScrollOffsetObserver` 的宿主边界解析回归：
/// 顶部导航模糊必须绑定当前栏目自己的滚动视图，绝不越出 NSHostingView
/// 误绑相邻栏目（侧边栏/阅读栏）；否则列表 ↔ 杂志切换后绑定无法恢复，
/// 顶部模糊消失。
@MainActor
final class ScrollOffsetObserverTests: XCTestCase {
    /// 类名含 "HostingView"，与真实 NSHostingView 一样被解析器识别为宿主边界。
    private final class TestHostingView: NSView {}

    func testResolvesHostingViewTableScrollView() {
        let host = TestHostingView()
        let scrollView = NSScrollView()
        scrollView.documentView = NSTableView()
        host.addSubview(scrollView)
        let probe = NSView()
        host.addSubview(probe)

        XCTAssertTrue(ScrollOffsetObserver.findScrollView(from: probe) === scrollView)
    }

    func testIgnoresScrollViewsOutsideHostingView() {
        // 模拟 NSSplitView：侧边栏列有滚动视图，内容列宿主内没有。
        let splitView = NSView()
        let sidebar = NSView()
        let sidebarScrollView = NSScrollView()
        sidebar.addSubview(sidebarScrollView)
        splitView.addSubview(sidebar)

        let contentHost = TestHostingView()
        let probe = NSView()
        contentHost.addSubview(probe)
        splitView.addSubview(contentHost)

        XCTAssertNil(ScrollOffsetObserver.findScrollView(from: probe))
    }

    func testFallsBackToScrollViewInsideHostingView() {
        // 卡片/杂志滚动模式没有 NSTableView，回退也仅限宿主视图内部。
        let host = TestHostingView()
        let scrollView = NSScrollView()
        host.addSubview(scrollView)
        let probe = NSView()
        host.addSubview(probe)

        XCTAssertTrue(ScrollOffsetObserver.findScrollView(from: probe) === scrollView)
    }

    func testNearestHostingViewStopsAtColumnBoundary() {
        let splitView = NSView()
        let outerHost = TestHostingView()
        splitView.addSubview(outerHost)
        let innerHost = TestHostingView()
        outerHost.addSubview(innerHost)
        let probe = NSView()
        innerHost.addSubview(probe)

        XCTAssertTrue(ScrollOffsetObserver.nearestHostingView(from: probe) === innerHost)
        XCTAssertTrue(ScrollOffsetObserver.nearestHostingView(from: splitView) == nil)
    }

    /// 复现「列表 → 杂志 → 列表」：旧列表滚动视图被杂志替换时必须解绑，
    /// 而不是越过宿主误绑侧边栏；回到列表后必须改绑到新的列表滚动视图。
    func testRebindsWhenTimelineStyleSwitches() {
        let splitView = NSView()
        let sidebar = NSView()
        let sidebarScrollView = NSScrollView()
        sidebar.addSubview(sidebarScrollView)
        splitView.addSubview(sidebar)

        let contentHost = TestHostingView()
        let probe = NSView()
        contentHost.addSubview(probe)
        splitView.addSubview(contentHost)

        var reportedOffsets: [CGFloat] = []
        let observer = ScrollOffsetObserver { reportedOffsets.append($0) }
        let coordinator = observer.makeCoordinator()

        // 列表模式：绑定本栏 NSTableView 的滚动视图。
        let listScrollView = NSScrollView()
        listScrollView.documentView = NSTableView()
        contentHost.addSubview(listScrollView)
        coordinator.refreshAttachment(for: probe)
        XCTAssertTrue(coordinator.clipView === listScrollView.contentView)

        // 切到杂志折页：本栏没有滚动容器，必须解绑而不是误绑侧边栏。
        listScrollView.removeFromSuperview()
        coordinator.refreshAttachment(for: probe)
        XCTAssertNil(coordinator.clipView)
        XCTAssertEqual(reportedOffsets.last, 0)

        // 切回列表：改绑到重建后的列表滚动视图，后续滚动继续驱动模糊。
        let rebuiltListScrollView = NSScrollView()
        rebuiltListScrollView.documentView = NSTableView()
        contentHost.addSubview(rebuiltListScrollView)
        coordinator.refreshAttachment(for: probe)
        XCTAssertTrue(coordinator.clipView === rebuiltListScrollView.contentView)

        rebuiltListScrollView.contentView.scroll(to: NSPoint(x: 0, y: 42))
        coordinator.refreshAttachment(for: probe)
        XCTAssertEqual(reportedOffsets.last, 42)
    }
}
