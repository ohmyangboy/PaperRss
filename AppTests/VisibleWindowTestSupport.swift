import Foundation
import AppKit
import XCTest

/// Swift 测试默认留在离屏环境；依赖 WindowServer 呈现的专项需显式开启。
enum VisibleWindowTestSupport {
    static func requireGUI() throws {
        guard ProcessInfo.processInfo.environment["PAPERRSS_RUN_GUI_TESTS"] == "1" else {
            throw XCTSkip("真实窗口测试需显式设置 PAPERRSS_RUN_GUI_TESTS=1，并在独立图形会话运行")
        }
    }

    @MainActor
    static func show(window: NSWindow, makeKey: Bool = false) throws {
        try requireGUI()
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    @MainActor
    static func bringForward(window: NSWindow) throws {
        try requireGUI()
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    @MainActor
    static func restoreApplication(_ application: NSRunningApplication?) {
        guard ProcessInfo.processInfo.environment["PAPERRSS_RUN_GUI_TESTS"] == "1" else { return }
        application?.activate(options: [])
    }

    static func requireMagazineDiagnostics() throws {
        try requireGUI()
        guard ProcessInfo.processInfo.environment["PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("杂志像素诊断需另外设置 PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS=1")
        }
    }
}
