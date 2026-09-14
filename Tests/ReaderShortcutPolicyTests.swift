import XCTest
@testable import PaperRssCore

final class ReaderShortcutPolicyTests: XCTestCase {
    func testDefaultBareCombinationsMapToTheirArticleActions() {
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyC)), .toggleBilingual)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyV)), .showSummary)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyK)), .previousArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyJ)), .nextArticle)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyM)), .toggleStar)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyF)), .toggleFullScreen)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyO)), .openOriginal)
        XCTAssertEqual(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .space)), .scrollDown)
    }

    func testModifiedCombinationsOnlyMatchTheirOwnBinding() {
        XCTAssertNil(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyC, command: true)))
        XCTAssertNil(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .keyJ, option: true)))

        var bindings = ReaderShortcutBindings.default
        try? bindings.setKey(ReaderShortcutCombo(base: .arrowUp, option: true), for: .previousArticle)
        XCTAssertEqual(
            ReaderShortcutPolicy.action(
                for: ReaderShortcutCombo(base: .arrowUp, option: true),
                bindings: bindings
            ),
            .previousArticle
        )
        XCTAssertNil(ReaderShortcutPolicy.action(for: ReaderShortcutCombo(base: .arrowUp, option: true)))
    }

    func testPhysicalKeyCodesResolveToBaseKeys() {
        XCTAssertEqual(ReaderShortcutBaseKey(keyCode: 8), .keyC)
        XCTAssertEqual(ReaderShortcutBaseKey(keyCode: 38), .keyJ)
        XCTAssertEqual(ReaderShortcutBaseKey(keyCode: 49), .space)
        XCTAssertEqual(ReaderShortcutBaseKey(keyCode: 126), .arrowUp)
        XCTAssertEqual(ReaderShortcutBaseKey(keyCode: 125), .arrowDown)
        XCTAssertEqual(ReaderShortcutBaseKey(keyCode: 36), .enter)
        XCTAssertEqual(ReaderShortcutBaseKey(keyCode: 24), .equal)
        XCTAssertNil(ReaderShortcutBaseKey(keyCode: 48), "Tab stays reserved")
        XCTAssertNil(ReaderShortcutBaseKey(keyCode: 53), "Esc stays reserved")
        XCTAssertNil(ReaderShortcutBaseKey(keyCode: 122), "F1 stays unavailable")
    }

    func testCombinationDisplayUsesModifierThenKeyOrder() {
        let combo = ReaderShortcutCombo(base: .keyR, command: true, shift: true)
        XCTAssertEqual(combo.displayCaps, ["⌘", "⇧", "R"])
        XCTAssertEqual(combo.displayString, "⌘⇧R")
        XCTAssertEqual(ReaderShortcutCombo(base: .space).displayString, "Space")
        XCTAssertEqual(ReaderShortcutCombo(base: .arrowUp, option: true).displayString, "⌥↑")
    }

    func testBindingsRejectDuplicateCombinations() {
        var bindings = ReaderShortcutBindings.default
        XCTAssertThrowsError(
            try bindings.setKey(ReaderShortcutCombo(base: .keyV), for: .toggleStar)
        ) { error in
            XCTAssertEqual(
                error as? ReaderShortcutBindings.UpdateError,
                .duplicate(.showSummary)
            )
        }
        XCTAssertEqual(bindings[.toggleStar].combo, ReaderShortcutCombo(base: .keyM))
    }

    func testBindingsPreserveConfirmationModeWhenTheKeyChanges() throws {
        var bindings = ReaderShortcutBindings.default
        bindings.setRequiresConfirmation(false, for: .toggleStar)
        try bindings.setKey(ReaderShortcutCombo(base: .keyS), for: .toggleStar)
        XCTAssertEqual(bindings[.toggleStar].combo, ReaderShortcutCombo(base: .keyS))
        XCTAssertFalse(bindings[.toggleStar].requiresConfirmation)
        XCTAssertTrue(bindings[.toggleBilingual].requiresConfirmation)
    }

    func testModifierCombinationsTurnOffConfirmationAutomatically() throws {
        var bindings = ReaderShortcutBindings.default
        XCTAssertTrue(bindings[.toggleStar].requiresConfirmation)

        try bindings.setKey(ReaderShortcutCombo(base: .keyS, option: true), for: .toggleStar)
        XCTAssertFalse(bindings[.toggleStar].requiresConfirmation)

        // 用户仍可手动改回；恢复默认会回到预设的「防误触」开启状态。
        bindings.setRequiresConfirmation(true, for: .toggleStar)
        XCTAssertTrue(bindings[.toggleStar].requiresConfirmation)
        bindings.reset(.toggleStar)
        XCTAssertEqual(bindings[.toggleStar], ReaderShortcutBindings.default[.toggleStar])
    }

    func testBareCombinationsKeepTheCurrentConfirmationSetting() throws {
        var bindings = ReaderShortcutBindings.default
        try bindings.setKey(ReaderShortcutCombo(base: .keyS), for: .toggleStar)
        XCTAssertTrue(bindings[.toggleStar].requiresConfirmation)

        bindings.setRequiresConfirmation(false, for: .toggleStar)
        try bindings.setKey(ReaderShortcutCombo(base: .keyD), for: .toggleStar)
        XCTAssertFalse(bindings[.toggleStar].requiresConfirmation)
    }

    func testBindingsResetRestoresSingleActionOrEverything() throws {
        var bindings = ReaderShortcutBindings.default
        try bindings.setKey(ReaderShortcutCombo(base: .keyS), for: .toggleStar)
        bindings.setRequiresConfirmation(false, for: .nextArticle)
        XCTAssertFalse(bindings.isDefault)

        bindings.reset(.toggleStar)
        XCTAssertEqual(bindings[.toggleStar].combo, ReaderShortcutCombo(base: .keyM))
        XCTAssertFalse(bindings[.nextArticle].requiresConfirmation)

        bindings.resetAll()
        XCTAssertTrue(bindings.isDefault)
        XCTAssertEqual(bindings, .default)
    }

    func testBindingsDecodeMergesPartialPayloadWithDefaults() throws {
        let json = #"{"nextArticle":{"combo":{"base":"ArrowUp","option":true},"requiresConfirmation":false}}"#
        let decoded = try JSONDecoder().decode(ReaderShortcutBindings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded[.nextArticle].combo, ReaderShortcutCombo(base: .arrowUp, option: true))
        XCTAssertFalse(decoded[.nextArticle].requiresConfirmation)
        XCTAssertEqual(decoded[.previousArticle].combo, ReaderShortcutCombo(base: .keyK))
        XCTAssertEqual(decoded[.openOriginal].combo, ReaderShortcutCombo(base: .keyO))
        XCTAssertTrue(decoded[.openOriginal].requiresConfirmation)
    }

    func testBindingsDecodeIgnoresUnknownActionsAndConflictingDuplicates() throws {
        let unknown = #"{"notAnAction":{"combo":{"base":"KeyZ"}}}"#
        let decodedUnknown = try JSONDecoder().decode(ReaderShortcutBindings.self, from: Data(unknown.utf8))
        XCTAssertEqual(decodedUnknown, .default)

        let conflicting = #"{"previousArticle":{"combo":{"base":"KeyZ"}},"nextArticle":{"combo":{"base":"KeyZ"}}}"#
        let decodedConflicting = try JSONDecoder().decode(
            ReaderShortcutBindings.self,
            from: Data(conflicting.utf8)
        )
        XCTAssertEqual(decodedConflicting[.previousArticle].combo, ReaderShortcutCombo(base: .keyZ))
        XCTAssertEqual(decodedConflicting[.nextArticle].combo, ReaderShortcutCombo(base: .keyJ))
    }

    func testBindingsDecodeRejectsUnknownBaseKeys() {
        let json = #"{"nextArticle":{"combo":{"base":"NotAKey"}}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReaderShortcutBindings.self, from: Data(json.utf8))
        )
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

    func testOpenOriginalUsesItsOwnConfirmationKey() {
        var confirmation = ReaderNavigationConfirmation(timeout: 2.5)

        XCTAssertEqual(confirmation.register(.openOriginal, entryID: "entry-1", at: 10), .armed)
        XCTAssertEqual(confirmation.register(.openOriginal, entryID: "entry-1", at: 11), .confirmed)
        XCTAssertNil(confirmation.pending)
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
