import Foundation
import XCTest

final class MacSystemAttentionLifecycleContractTests: XCTestCase {
    func testAttentionControllerDefersAppKitWorkUntilApplicationIsReady() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PaperRss/Sources/App/MacSystemAttentionController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(controller.contains("private weak var application: NSApplication?"))
        XCTAssertTrue(controller.contains("private var hasStarted = false"))
        XCTAssertTrue(controller.contains("func start(application: NSApplication)"))
        XCTAssertFalse(controller.contains("NSApp."))

        let initializerStart = try XCTUnwrap(
            controller.range(of: "    init(\n        store: AppStore,")?.lowerBound
        )
        let startMethod = try XCTUnwrap(
            controller.range(of: "    func start(application: NSApplication)")
        )
        let initializer = controller[initializerStart..<startMethod.lowerBound]
        XCTAssertFalse(initializer.contains("notificationCenter.delegate = self"))
        XCTAssertFalse(initializer.contains("observeStore()"))
        XCTAssertFalse(initializer.contains("updateDockBadge()"))

        let startEnd = try XCTUnwrap(
            controller.range(of: "    func setDockBadgeEnabled", range: startMethod.upperBound..<controller.endIndex)?.lowerBound
        )
        let startBody = controller[startMethod.lowerBound..<startEnd]
        let guardIndex = try XCTUnwrap(startBody.range(of: "guard !hasStarted else { return }")?.lowerBound)
        let applicationIndex = try XCTUnwrap(startBody.range(of: "self.application = application")?.lowerBound)
        let observeIndex = try XCTUnwrap(startBody.range(of: "observeStore()")?.lowerBound)
        let updateIndex = try XCTUnwrap(startBody.range(of: "updateDockBadge()")?.lowerBound)
        XCTAssertLessThan(guardIndex, applicationIndex)
        XCTAssertLessThan(applicationIndex, observeIndex)
        XCTAssertLessThan(observeIndex, updateIndex)
        XCTAssertTrue(controller.contains("guard let application else { return }"))
    }

    func testAppStartsAttentionControllerFromWindowAppearance() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/PaperRssApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(app.contains(".onAppear {\n                    let application = NSApplication.shared"))
        XCTAssertTrue(app.contains("attention.start(application: application)"))
        XCTAssertTrue(app.contains("application.activate(ignoringOtherApps: true)"))
    }

    func testIconVisibilitySwitchesUseInjectedApplicationAndDefersStatusItemWork() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PaperRss/Sources/App/MacSystemAttentionController.swift"
            ),
            encoding: .utf8
        )

        // 隐藏 Dock 图标只切激活策略，显示菜单栏图标只建状态栏项。
        XCTAssertTrue(controller.contains("func setHideDockIcon(_ hidden: Bool)"))
        XCTAssertTrue(controller.contains("func setShowMenuBarIcon(_ visible: Bool)"))
        XCTAssertTrue(controller.contains("application.setActivationPolicy(policy)"))
        XCTAssertTrue(controller.contains("MacIconVisibilityPolicy.hidesDockIcon("))
        XCTAssertTrue(controller.contains("if showMenuBarIcon {"))
        XCTAssertTrue(controller.contains("private func installStatusItemIfNeeded()"))
        XCTAssertTrue(controller.contains("private func updateStatusItem()"))
        XCTAssertTrue(controller.contains("func registerMainWindowOpener("))
        // 前置限制：只有菜单栏入口开启时才允许隐藏 Dock 图标。
        XCTAssertTrue(controller.contains("MacIconVisibilityPolicy.resolvesHideDockIcon("))
        // Dock 图标跟随窗口显隐：窗口通知驱动策略同步，最后一个窗口关闭后才切辅助策略。
        XCTAssertTrue(controller.contains("NSWindow.didBecomeMainNotification"))
        XCTAssertTrue(controller.contains("NSWindow.willCloseNotification"))
        XCTAssertTrue(controller.contains("private func scheduleIconVisibilitySync()"))
        XCTAssertTrue(controller.contains("private func hasPresentedWindow(in application: NSApplication) -> Bool"))
        // 最小化窗口仍算入口：留着 Dock 图标，唤出时还原原窗口而不是再开一个。
        XCTAssertTrue(controller.contains("NSWindow.didMiniaturizeNotification"))
        XCTAssertTrue(controller.contains("private func miniaturizedWindow(in application: NSApplication) -> NSWindow?"))
        XCTAssertTrue(controller.contains("miniaturized.deminiaturize(nil)"))
        XCTAssertFalse(controller.contains("restoreFrontmost"))
        let settersStart = try XCTUnwrap(controller.range(of: "func setHideDockIcon(_ hidden: Bool)")?.lowerBound)
        let settersEnd = try XCTUnwrap(
            controller.range(of: "func setFeedNotificationsEnabled", range: settersStart..<controller.endIndex)?.lowerBound
        )
        XCTAssertTrue(
            controller[settersStart..<settersEnd].contains("applyIconVisibility()"),
            "图标可见性开关必须即时应用"
        )
        XCTAssertTrue(controller.contains("application.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(controller.contains("if let window = mainWindow(in: application) {"))
        XCTAssertTrue(controller.contains("window.makeKeyAndOrderFront(nil)"))
        XCTAssertFalse(controller.contains("NSApp."))
    }

    func testAppLeavesActivationPolicyToAttentionController() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/PaperRssApp.swift"),
            encoding: .utf8
        )

        // 启动阶段不预置激活策略：Dock 图标只由窗口显隐决定，避免与窗口上屏时的判定来回切换。
        XCTAssertFalse(app.contains("setActivationPolicy"))
    }

    func testRootViewRegistersMainWindowOpenerForMenuBarMode() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/RootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(rootView.contains("attention.registerMainWindowOpener { openWindow(id: \"main\") }"))
    }
}
