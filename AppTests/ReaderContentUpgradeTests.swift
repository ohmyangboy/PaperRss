import PaperRssCore
import XCTest
@testable import PaperRssDesktop

final class ReaderContentUpgradeTests: XCTestCase {
    private var fullArticle: PreparedArticle {
        PreparedArticle(text: "Full article", html: "<p>Full article</p>",
                        imageURLs: [], baseURL: nil, source: .web)
    }

    func testBackgroundRequestWaitsForTheLocalDocumentPaint() throws {
        var state = ReaderContentUpgradeState()
        state.begin(entryID: "a", loadSession: 1)
        state.setNeedsRefresh(true)
        XCTAssertNil(state.refreshRequest)
        state.documentPainted(entryID: "old-document")
        XCTAssertNil(state.refreshRequest)
        state.documentPainted(entryID: "a")
        let request = try XCTUnwrap(state.refreshRequest)
        XCTAssertEqual(request.entryID, "a")
        XCTAssertEqual(request.loadSession, 1)
        XCTAssertNil(state.readyArticle)
    }

    func testFullArticleBecomesAnOfferWithoutStartingAnotherLoad() throws {
        var state = ReaderContentUpgradeState()
        state.begin(entryID: "a", loadSession: 1)
        state.setNeedsRefresh(true)
        state.documentPainted(entryID: "a")
        let request = try XCTUnwrap(state.refreshRequest)
        XCTAssertTrue(state.finish(fullArticle, for: request))
        XCTAssertEqual(state.readyArticle, fullArticle)
        XCTAssertNil(state.refreshRequest, "A completed upgrade must not start a refresh loop")
        XCTAssertFalse(state.finish(fullArticle, for: request))
    }

    func testSwitchingArticlesRejectsAnOlderBackgroundResult() throws {
        var state = ReaderContentUpgradeState()
        state.begin(entryID: "a", loadSession: 1)
        state.setNeedsRefresh(true)
        state.documentPainted(entryID: "a")
        let oldRequest = try XCTUnwrap(state.refreshRequest)
        state.begin(entryID: "b", loadSession: 2)
        XCTAssertFalse(state.finish(fullArticle, for: oldRequest))
        XCTAssertNil(state.readyArticle)
    }

    func testReloadingTheSameArticleAlsoRejectsAnOlderResult() throws {
        var state = ReaderContentUpgradeState()
        state.begin(entryID: "a", loadSession: 1)
        state.setNeedsRefresh(true)
        state.documentPainted(entryID: "a")
        let oldRequest = try XCTUnwrap(state.refreshRequest)
        state.begin(entryID: "a", loadSession: 2)
        state.setNeedsRefresh(true)
        state.documentPainted(entryID: "a")
        XCTAssertFalse(state.finish(fullArticle, for: oldRequest))
        XCTAssertEqual(state.refreshRequest?.loadSession, 2)
        XCTAssertNil(state.readyArticle)
    }

    func testCompleteLocalContentDoesNotRequestTheWebAndFailuresLeaveItReadable() throws {
        var state = ReaderContentUpgradeState()
        state.begin(entryID: "a", loadSession: 1)
        state.documentPainted(entryID: "a")
        XCTAssertNil(state.refreshRequest)
        state.setNeedsRefresh(true)
        let request = try XCTUnwrap(state.refreshRequest)
        XCTAssertTrue(state.finish(nil, for: request))
        XCTAssertNil(state.readyArticle)
        XCTAssertNil(state.refreshRequest)
    }
}
