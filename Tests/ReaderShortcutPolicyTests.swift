import XCTest
@testable import PaperRssCore

final class ReaderShortcutPolicyTests: XCTestCase {
    func testBareReaderKeysMapToTheirArticleActions() {
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "c"), .toggleBilingual)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "V"), .showSummary)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "k"), .previousArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "K"), .previousArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "j"), .nextArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "J"), .nextArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "m"), .toggleStar)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "F"), .toggleFullScreen)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: "f"), .toggleFullScreen)
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

    func testBilingualShortcutCanTurnOffWhileBusyButCannotStart() {
        XCTAssertEqual(
            ReaderShortcutPolicy.bilingualDecision(isBilingualActive: true, isAIRequestActive: true),
            .toggle
        )
        XCTAssertEqual(
            ReaderShortcutPolicy.bilingualDecision(isBilingualActive: false, isAIRequestActive: true),
            .rejectBusy
        )
        XCTAssertEqual(
            ReaderShortcutPolicy.bilingualDecision(isBilingualActive: false, isAIRequestActive: false),
            .toggle
        )
    }

    func testSummaryShortcutPrioritizesVisibilityAndCachedContentBeforeBusyState() {
        XCTAssertEqual(
            ReaderShortcutPolicy.summaryDecision(
                showsAISummary: false,
                hasCachedSummary: true,
                isAIRequestActive: false
            ),
            .promptToEnable
        )
        XCTAssertEqual(
            ReaderShortcutPolicy.summaryDecision(
                showsAISummary: true,
                hasCachedSummary: true,
                isAIRequestActive: true
            ),
            .revealCached
        )
        XCTAssertEqual(
            ReaderShortcutPolicy.summaryDecision(
                showsAISummary: true,
                hasCachedSummary: false,
                isAIRequestActive: true
            ),
            .rejectBusy
        )
        XCTAssertEqual(
            ReaderShortcutPolicy.summaryDecision(
                showsAISummary: true,
                hasCachedSummary: false,
                isAIRequestActive: false
            ),
            .generate
        )
    }
}
