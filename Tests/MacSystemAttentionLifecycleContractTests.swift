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
        XCTAssertTrue(controller.contains("application.setActivationPolicy(hideDockIcon ? .accessory : .regular)"))
        XCTAssertTrue(controller.contains("if showMenuBarIcon {"))
        XCTAssertTrue(controller.contains("static func applyStoredIconVisibilityToLaunchingApplication()"))
        XCTAssertTrue(controller.contains("NSApplication.shared.setActivationPolicy(.accessory)"))
        XCTAssertTrue(controller.contains("private func installStatusItemIfNeeded()"))
        XCTAssertTrue(controller.contains("private func updateStatusItem()"))
        XCTAssertTrue(controller.contains("func registerMainWindowOpener("))
        // 前置限制：只有菜单栏入口开启时才允许隐藏 Dock 图标。
        XCTAssertTrue(controller.contains("MacIconVisibilityPolicy.resolvesHideDockIcon("))
        // 开关只写偏好，图标可见性仅在启动时应用（运行中不切策略、不闪动）。
        XCTAssertTrue(controller.contains("@Published private(set) var appliedHideDockIcon: Bool"))
        XCTAssertTrue(controller.contains("@Published private(set) var appliedShowMenuBarIcon: Bool"))
        XCTAssertFalse(controller.contains("restoreFrontmost"))
        let settersStart = try XCTUnwrap(controller.range(of: "func setHideDockIcon(_ hidden: Bool)")?.lowerBound)
        let settersEnd = try XCTUnwrap(
            controller.range(of: "func setFeedNotificationsEnabled", range: settersStart..<controller.endIndex)?.lowerBound
        )
        XCTAssertFalse(
            controller[settersStart..<settersEnd].contains("applyIconVisibility"),
            "图标可见性开关不得在运行中应用"
        )
        XCTAssertTrue(controller.contains("application.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(controller.contains("if let window = mainWindow(in: application) {"))
        XCTAssertTrue(controller.contains("window.makeKeyAndOrderFront(nil)"))
        XCTAssertFalse(controller.contains("NSApp."))
    }

    func testAppAppliesStoredIconVisibilityBeforeAttentionControllerCreation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/PaperRssApp.swift"),
            encoding: .utf8
        )

        let visibilityCall = try XCTUnwrap(
            app.range(of: "MacSystemAttentionController.applyStoredIconVisibilityToLaunchingApplication()")?.lowerBound
        )
        let attentionCreation = try XCTUnwrap(
            app.range(of: "_attention = StateObject(wrappedValue: MacSystemAttentionController(")?.lowerBound
        )
        XCTAssertLessThan(visibilityCall, attentionCreation)
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
