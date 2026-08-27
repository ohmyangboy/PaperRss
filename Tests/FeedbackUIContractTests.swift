import Foundation
import XCTest

final class FeedbackUIContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSidebarFeedbackPopoverPrioritizesIssueAndShowsBothSupportChannels() throws {
        let root = try sourceText("PaperRss/Sources/App/RootView.swift")
        let feedbackView = try sourceText("PaperRss/Sources/App/FeedbackPopoverView.swift")

        let issuePosition = try XCTUnwrap(feedbackView.range(of: "openFeedback(.issue)")).lowerBound
        let emailPosition = try XCTUnwrap(feedbackView.range(of: "openFeedback(.email)")).lowerBound

        XCTAssertLessThan(issuePosition, emailPosition)
        XCTAssertTrue(root.contains("@State private var showsFeedbackPopover = false"))
        XCTAssertTrue(root.contains(".popover(isPresented: $showsFeedbackPopover, arrowEdge: .bottom)"))
        XCTAssertTrue(root.contains("FeedbackPopoverView(store: store)"))
        XCTAssertTrue(root.contains("Image(systemName: \"exclamationmark.bubble\")"))
        XCTAssertFalse(root.contains("Image(systemName: \"bubble.left\")"))
        XCTAssertFalse(root.contains("Label(I18N.shared.localized(\"反馈\", \"Feedback\"), systemImage: \"bubble.left\")"))
        XCTAssertTrue(feedbackView.contains("遇到问题了？"))
        XCTAssertTrue(feedbackView.contains("随时反馈，让 PaperRss 更好"))
        XCTAssertFalse(feedbackView.contains("遇到问题了？随时反馈，让 PaperRss 更好"))
        XCTAssertFalse(feedbackView.contains("Text(I18N.shared.localized(\"反馈与联系\", \"Feedback & Contact\"))"))
        XCTAssertTrue(feedbackView.contains(".lineLimit(1)"))
        XCTAssertFalse(feedbackView.contains("ScrollView {"))
        XCTAssertFalse(feedbackView.contains("复制完整反馈"))
        let privacyPosition = try XCTUnwrap(feedbackView.range(of: "反馈会自动带入")).lowerBound
        let dividerPosition = try XCTUnwrap(feedbackView.range(of: "Divider().opacity")).lowerBound
        XCTAssertLessThan(privacyPosition, dividerPosition)
        XCTAssertTrue(feedbackView.contains("关注社交媒体，支持 PaperRss 开发"))
        XCTAssertTrue(feedbackView.contains("XiaohongshuContact"))
        XCTAssertTrue(feedbackView.contains("SponsorQR"))
        XCTAssertTrue(feedbackView.contains("FeedbackDiagnosticsProvider.makeSnapshot"))
        XCTAssertTrue(feedbackView.contains("FeedbackComposer.url(for: channel"))
        XCTAssertTrue(feedbackView.contains("AppInfo.openMailURL"))

        let appInfo = try sourceText("PaperRss/Sources/App/AppInfo.swift")
        XCTAssertTrue(appInfo.contains("com.apple.mail"))
    }

    private func sourceText(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
