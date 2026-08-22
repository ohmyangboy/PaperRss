import Foundation
import XCTest

final class ReaderFocusLifecycleContractTests: XCTestCase {
    func testArticleSwitchKeepsReaderWebViewMountedToPreserveFocus() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let articleReader = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/ArticleReaderView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(articleReader.contains("@State private var displayedEntry: Entry?"))
        XCTAssertFalse(articleReader.contains("preparedArticle = nil"))
        XCTAssertTrue(articleReader.contains("if usesNativeHTMLScroller, let preparedArticle, let displayedEntry"))
        XCTAssertTrue(articleReader.contains("entry: displayedEntry"))
        XCTAssertTrue(articleReader.contains("isInteractive: isDisplayedDocumentInteractive"))
        XCTAssertTrue(articleReader.contains("window.paperRssReaderInteractive === false"))
        XCTAssertTrue(articleReader.contains("guard parent.allowsNavigationWhenInactive else { return }"))
        XCTAssertTrue(articleReader.contains("if isLoading || activeLoadEntryID != entry.id"))
        XCTAssertTrue(articleReader.contains("if showsLoadingIndicator"))
        XCTAssertTrue(articleReader.contains("Task.sleep(nanoseconds: 150_000_000)"))
        XCTAssertFalse(articleReader.contains("hasPresentedDocument"))
        XCTAssertTrue(articleReader.contains("pendingScrollOffset = 0"))
        XCTAssertTrue(articleReader.contains("pendingContentOffset = .zero"))
        XCTAssertTrue(articleReader.contains("onDocumentReady: { loadedEntryID in"))
        XCTAssertTrue(articleReader.contains("guard isLoading, activeLoadEntryID == loadedEntryID else { return false }"))
        XCTAssertTrue(articleReader.contains("navigationLoads[ObjectIdentifier(navigation)] = ("))
        XCTAssertTrue(articleReader.contains("navigationLoads.removeValue(forKey: ObjectIdentifier(navigation))"))
        XCTAssertTrue(articleReader.contains("completedArticleKey == renderSignature"))
        XCTAssertTrue(articleReader.contains("guard self.parent.onDocumentReady(entryID) else { return }"))
        XCTAssertTrue(articleReader.contains("handleLoadFailure("))
        XCTAssertTrue(articleReader.contains("parent.onDocumentLoadFailed(entryID)"))
        let identityCheck = try XCTUnwrap(articleReader.range(of: "if loadedDocumentIdentity == parent.entry.id")?.lowerBound)
        let translationInsertion = try XCTUnwrap(articleReader.range(of: "ArticleExtractor.insertingInlineTranslations(", range: identityCheck..<articleReader.endIndex)?.lowerBound)
        XCTAssertLessThan(identityCheck, translationInsertion)
        XCTAssertTrue(articleReader.contains("loadedText.htmlEscaped"))
        XCTAssertTrue(articleReader.contains("private var hasReaderContent: Bool { preparedArticle != nil }"))
    }
}
