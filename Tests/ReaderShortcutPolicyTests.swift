import XCTest
@testable import PaperRssCore

final class ReaderShortcutPolicyTests: XCTestCase {
    func testBareReaderKeysMapToTheirArticleActions() {
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "c"), .toggleBilingual)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "V"), .showSummary)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "b"), .previousArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "N"), .nextArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "m"), .toggleStar)
    }

    func testModifiedRepeatedAndUnknownKeysStayWithTheCurrentResponder() {
        XCTAssertNil(ReaderShortcutPolicy.action(for: "c", hasDisallowedModifiers: true))
        XCTAssertNil(ReaderShortcutPolicy.action(for: "v", isRepeat: true))
        XCTAssertNil(ReaderShortcutPolicy.action(for: "x"))
        XCTAssertNil(ReaderShortcutPolicy.action(for: nil))
    }

    func testNavigationRequiresTheSameKeyTwiceBeforeTheDeadline() {
        var confirmation = ReaderNavigationConfirmation(timeout: 2.5)

        XCTAssertEqual(
            confirmation.register(.nextArticle, entryID: "entry-1", at: 10),
            .armed
        )
        XCTAssertEqual(
            confirmation.register(.nextArticle, entryID: "entry-1", at: 12.4),
            .confirmed
        )
        XCTAssertNil(confirmation.pending)
    }

    func testNavigationExpiresAndChangingDirectionStartsAReplacementConfirmation() {
        var confirmation = ReaderNavigationConfirmation(timeout: 2.5)

        XCTAssertEqual(confirmation.register(.nextArticle, entryID: "entry-1", at: 10), .armed)
        XCTAssertEqual(confirmation.register(.previousArticle, entryID: "entry-1", at: 11), .armed)
        XCTAssertEqual(confirmation.pending?.action, .previousArticle)
        XCTAssertEqual(confirmation.register(.previousArticle, entryID: "entry-1", at: 13.6), .armed)
        XCTAssertEqual(confirmation.register(.previousArticle, entryID: "entry-1", at: 15), .confirmed)
    }

    func testNavigationConfirmationCannotCarryAcrossArticlesOrOtherReaderActions() {
        var confirmation = ReaderNavigationConfirmation(timeout: 2.5)

        XCTAssertEqual(confirmation.register(.nextArticle, entryID: "entry-1", at: 10), .armed)
        XCTAssertEqual(confirmation.register(.nextArticle, entryID: "entry-2", at: 11), .armed)
        XCTAssertEqual(confirmation.pending?.entryID, "entry-2")

        confirmation.cancel()
        XCTAssertNil(confirmation.pending)
        XCTAssertEqual(confirmation.register(.nextArticle, entryID: "entry-2", at: 12), .armed)
    }

    func testSpaceUsesAnIndependentConfirmationKey() {
        var confirmation = ReaderNavigationConfirmation(timeout: 2.5)

        XCTAssertEqual(confirmation.register(.spaceNextArticle, entryID: "entry-1", at: 10), .armed)
        XCTAssertEqual(confirmation.register(.nextArticle, entryID: "entry-1", at: 11), .armed)
        XCTAssertEqual(confirmation.register(.nextArticle, entryID: "entry-1", at: 12), .confirmed)
    }
}
