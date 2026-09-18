import AppKit
import XCTest
#if SWIFT_PACKAGE
@testable import PaperRssCore
@testable import PaperRssDesktop
#else
@testable import PaperRss
#endif

@MainActor
final class ReaderShortcutReservedCatalogTests: XCTestCase {
    // MARK: - 菜单遍历（与扫描时机解耦的纯逻辑）

    /// 回归：官方 v1.4.1 在 macOS 15 冷启动时，SwiftUI 场景构建早于
    /// `NSApp.mainMenu` 建立，`guard let mainMenu = NSApp.mainMenu` 触发
    /// 隐式解包 trap（EXC_BREAKPOINT，imageOffset 0x11B9C8）。遍历逻辑必须
    /// 接受 nil 菜单并返回空表，绝不在调用点强制解包。
    func testMenuWalkerAcceptsMissingMainMenu() {
        XCTAssertTrue(ReaderShortcutReservedCatalog.walkMenuEntries(nil).isEmpty)
    }

    func testMenuWalkerCollectsKeyEquivalentsAndIgnoresItemsWithoutThem() {
        let menu = NSMenu(title: "main")
        let copy = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "c")
        copy.keyEquivalentModifierMask = [.command]
        menu.addItem(copy)
        menu.addItem(NSMenuItem(title: "No Key", action: nil, keyEquivalent: ""))

        let submenu = NSMenu(title: "View")
        let refresh = NSMenuItem(title: "  Refresh  ", action: nil, keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = [.command, .shift]
        submenu.addItem(refresh)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = submenu
        menu.addItem(viewItem)

        let entries = ReaderShortcutReservedCatalog.walkMenuEntries(menu)

        XCTAssertEqual(entries.count, 2, "只收集带组合键的菜单项，含子菜单")
        XCTAssertEqual(entries[0].combo, ReaderShortcutCombo(base: .keyC, command: true))
        XCTAssertEqual(entries[0].label, "Copy")
        XCTAssertEqual(entries[1].combo, ReaderShortcutCombo(base: .keyR, command: true, shift: true))
        XCTAssertEqual(entries[1].label, "Refresh", "标签去除首尾空白")
    }

    func testMenuWalkerInfersShiftFromUppercaseKeyEquivalent() {
        let menu = NSMenu(title: "main")
        let item = NSMenuItem(title: "Import", action: nil, keyEquivalent: "i")
        item.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(item)
        let plain = NSMenuItem(title: "Close", action: nil, keyEquivalent: "w")
        plain.keyEquivalentModifierMask = [.command]
        menu.addItem(plain)

        let entries = ReaderShortcutReservedCatalog.walkMenuEntries(menu)

        XCTAssertEqual(entries.count, 2, "未列入自定义表的按键（如 W）不参与保留")
        XCTAssertEqual(entries[0].combo, ReaderShortcutCombo(base: .keyI, command: true, shift: true))
    }

    // MARK: - 启动安全（运行时）

    /// 运行时回归：测试进程没有 `NSApplication` 实例（`NSApp == nil`），
    /// 正是 macOS 14.8 虚拟机冷启动崩溃时的条件。初始化单例、补扫描、
    /// 走一遍保留校验都必须不崩，且静态保留表立即生效。
    func testCatalogInitializesAndSanitizesWithoutNSApp() {
        let catalog = ReaderShortcutReservedCatalog.shared
        XCTAssertFalse(catalog.hasScannedMenu, "测试进程没有 NSApplication，不可能完成菜单扫描")

        // 扫描路径在 NSApp == nil 下必须安全且不缓存空结果。
        catalog.scanMenuIfNeeded()
        catalog.scanMenuIfNeeded()
        XCTAssertFalse(catalog.hasScannedMenu, "无 NSApp 时不得把空菜单当成扫描结果")

        // 静态保留表不依赖菜单，立即可用。
        XCTAssertTrue(catalog.isReserved(ReaderShortcutCombo(base: .arrowLeft)))
        XCTAssertTrue(catalog.isReserved(ReaderShortcutCombo(base: .keyR, command: true, shift: true)))
        XCTAssertTrue(catalog.isReserved(ReaderShortcutCombo(base: .equal, command: true)))
        XCTAssertFalse(catalog.isReserved(ReaderShortcutCombo(base: .keyJ, option: true)))

        // 被保留的组合不得进入绑定表：sanitize 必须回落到默认键位。
        var polluted = ReaderShortcutBindings.default
        try? polluted.setKey(ReaderShortcutCombo(base: .keyR, command: true, shift: true), for: .toggleStar)
        let sanitized = catalog.sanitize(polluted)
        XCTAssertEqual(sanitized[.toggleStar].combo, ReaderShortcutCombo(base: .keyM))
    }

    // MARK: - 启动安全约束（契约）

    /// 启动期崩溃的根因是在 Scene 构建期强制解包 `NSApp`（macOS 15 上是
    /// `NSApp.mainMenu`，macOS 14.8 上是 `NSApp.isRunning`）。两条约束：
    /// 1. 初始化路径不得读取任何 AppKit 单例；
    /// 2. 唯一的自定义表扫描入口必须通过可选链读取 `NSApp?.mainMenu`。
    func testReservedCatalogReadsMainMenuOnlyInsideScanPath() throws {
        let source = try appSource("ReaderShortcutReservedCatalog.swift")
        let code = codeLines(of: source)

        XCTAssertTrue(code.contains("NSApp?.mainMenu"), "扫描入口必须用可选链，禁止隐式解包")
        XCTAssertFalse(
            code.contains("NSApp.mainMenu") || code.contains("NSApp.isRunning"),
            "不允许再出现 `NSApp.` 形式的隐式解包读取"
        )
        XCTAssertTrue(source.contains("static func walkMenuEntries(_ mainMenu: NSMenu?)"))
        XCTAssertTrue(source.contains("NSApplication.didFinishLaunchingNotification"), "扫描必须挂在完成启动之后")

        // 初始化路径（private init 的完整花括号作用域）不得读取 AppKit 单例；
        // 只允许 `NSApplication.didFinishLaunchingNotification` 这种常量引用。
        let initScope = try XCTUnwrap(
            balancedBody(startingAt: "private init() {", in: code),
            "找不到 init 定义"
        )
        XCTAssertFalse(initScope.contains("NSApp."), "init 不得读取 NSApp 属性")
        XCTAssertFalse(initScope.contains("NSApplication.shared"), "init 不得实例化 NSApplication")
    }

    /// 从 `{` 起按花括号配对截取一个完整作用域。
    private func balancedBody(startingAt marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        var depth = 0
        var index = markerRange.upperBound
        let bodyStart = text.index(before: markerRange.upperBound)
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[bodyStart...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 主窗口首帧兜底：`RootView.onAppear` 在无需崩溃路径的时机补一次扫描。
    func testRootViewPrimesCatalogAfterWindowAppears() throws {
        let source = try appSource("RootView.swift")
        XCTAssertTrue(source.contains("ReaderShortcutReservedCatalog.shared.scanMenuIfNeeded()"))
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PaperRss/Sources/App/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 去掉整行注释（含 `///` 文档注释）与 `/* ... */` 块注释，返回代码部分，
    /// 避免注释里的示例代码误伤契约断言。
    private func codeLines(of source: String) -> String {
        var inBlockComment = false
        var result: [String] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if line.contains("*/") { inBlockComment = false }
                continue
            }
            if line.hasPrefix("/*") {
                if !line.contains("*/") { inBlockComment = true }
                continue
            }
            if line.hasPrefix("///") || line.hasPrefix("//") { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }
}
