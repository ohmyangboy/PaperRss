import Foundation
import XCTest

final class ThreeColumnTitlebarDragTests: XCTestCase {
    func testThreeColumnSplitViewImplementsUnifiedTitlebarDragging() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let splitViewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/ThreeColumnSplitView.swift"),
            encoding: .utf8
        )

        // 1. 必须包含标题栏可拖拽区域判定函数
        XCTAssertTrue(splitViewSource.contains("private func isTitlebarDraggableArea(at locationInWindow: CGPoint, in window: NSWindow) -> Bool"))

        // 2. 必须计算顶部标题栏/工具栏高度（支持安全区与 52pt fallback）
        XCTAssertTrue(splitViewSource.contains("let titlebarHeight: CGFloat = contentView.safeAreaInsets.top > 0 ? contentView.safeAreaInsets.top : 52"))
        XCTAssertTrue(splitViewSource.contains("locationInWindow.y >= (windowHeight - titlebarHeight) && locationInWindow.y <= windowHeight"))

        // 3. 全屏与模态保护：全屏状态或存在 sheet/modal 时禁用窗口拖拽
        XCTAssertTrue(splitViewSource.contains("guard !window.styleMask.contains(.fullScreen) else { return false }"))
        XCTAssertTrue(splitViewSource.contains("guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }"))

        // 4. 必须排除系统红绿灯按钮
        XCTAssertTrue(splitViewSource.contains("let standardButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]"))

        // 5. 必须排除阅读工具胶囊 (ReaderCapsule)
        XCTAssertTrue(splitViewSource.contains("if let capsuleHost = readerCapsuleHost, !capsuleHost.isHidden, capsuleHost.window === window"))
        XCTAssertTrue(splitViewSource.contains("if capsuleRect.contains(locationInWindow)"))

        // 6. 必须排除刷新与全部已读等已知工具栏按钮
        XCTAssertTrue(splitViewSource.contains("if let refreshButton, !refreshButton.isHidden, refreshButton.window === window"))
        XCTAssertTrue(splitViewSource.contains("if let markAllReadButton, !markAllReadButton.isHidden, markAllReadButton.window === window"))

        // 7. 必须上溯命中视图排除所有 NSControl、NSTextView、NSScroller 交互控件
        XCTAssertTrue(splitViewSource.contains("if view is NSControl || view is NSTextView || view is NSScroller"))

        // 8. 必须调用原生 performDrag 并支持双击标题栏缩放
        XCTAssertTrue(splitViewSource.contains("window.performDrag(with: event)"))
        XCTAssertTrue(splitViewSource.contains("private func handleTitlebarDoubleClick(on window: NSWindow)"))
        XCTAssertTrue(splitViewSource.contains("UserDefaults.standard.string(forKey: \"AppleActionOnDoubleClick\")"))
    }
}
