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
}
