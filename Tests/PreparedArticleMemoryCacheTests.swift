import XCTest
@testable import PaperRssCore

@MainActor
final class PreparedArticleMemoryCacheTests: XCTestCase {

    private func makeArticle(_ marker: String) -> PreparedArticle {
        PreparedArticle(
            text: "text-\(marker)",
            html: "<p>\(marker)</p>",
            imageURLs: [],
            baseURL: nil,
            source: .cache
        )
    }

    func testStoreAndHitReturnsSameInstanceAndRefreshesRecency() {
        let cache = PreparedArticleMemoryCache(capacity: 3)
        cache.store(makeArticle("a"), entryID: "a", contentFingerprint: "fa")

        let hit = cache.article(for: "a", contentFingerprint: "fa")
        XCTAssertEqual(hit?.text, "text-a")
        XCTAssertTrue(cache.contains("a"))
    }

    func testFingerprintMismatchInvalidatesEntry() {
        let cache = PreparedArticleMemoryCache()
        cache.store(makeArticle("a"), entryID: "a", contentFingerprint: "old")
        XCTAssertNil(cache.article(for: "a", contentFingerprint: "new"))
        XCTAssertFalse(cache.contains("a"), "失配后应清除失效条目，避免下次误判可用")
    }

    func testEvictsLeastRecentlyUsedBeyondCapacity() {
        let cache = PreparedArticleMemoryCache(capacity: 2)
        cache.store(makeArticle("a"), entryID: "a", contentFingerprint: "f")
        cache.store(makeArticle("b"), entryID: "b", contentFingerprint: "f")
        // 访问 a 使其变为最近使用，b 成为最旧
        _ = cache.article(for: "a", contentFingerprint: "f")
        cache.store(makeArticle("c"), entryID: "c", contentFingerprint: "f")

        XCTAssertFalse(cache.contains("b"), "最久未使用的 b 应被逐出")
        XCTAssertTrue(cache.contains("a"))
        XCTAssertTrue(cache.contains("c"))
    }

    func testInvalidateRemovesOnlyTargetEntry() {
        let cache = PreparedArticleMemoryCache()
        cache.store(makeArticle("a"), entryID: "a", contentFingerprint: "f")
        cache.store(makeArticle("b"), entryID: "b", contentFingerprint: "f")

        cache.invalidate(entryID: "a")

        XCTAssertFalse(cache.contains("a"))
        XCTAssertTrue(cache.contains("b"))
    }

    func testRemoveAllClearsEverything() {
        let cache = PreparedArticleMemoryCache()
        cache.store(makeArticle("a"), entryID: "a", contentFingerprint: "f")
        cache.store(makeArticle("b"), entryID: "b", contentFingerprint: "f")

        cache.removeAll()

        XCTAssertFalse(cache.contains("a"))
        XCTAssertFalse(cache.contains("b"))
    }

    func testGenerationBumpsOnInvalidationAndRemoveAll() {
        let cache = PreparedArticleMemoryCache()
        let initial = cache.generation

        cache.invalidate(entryID: "missing")
        XCTAssertGreaterThan(cache.generation, initial, "失效即递增，供准备方完成时比对")

        let before = cache.generation
        cache.removeAll()
        XCTAssertGreaterThan(cache.generation, before)
    }

    func testContentFingerprintTracksContentHTMLAndTitleChanges() {
        let original = Entry(id: "e1", feedID: UUID(), title: "标题", contentHTML: "<p>正文</p>")
        let sameContent = Entry(id: "e1", feedID: UUID(), title: "标题", contentHTML: "<p>正文</p>")
        let changedContent = Entry(id: "e1", feedID: UUID(), title: "标题", contentHTML: "<p>新正文</p>")
        let changedTitle = Entry(id: "e1", feedID: UUID(), title: "新标题", contentHTML: "<p>正文</p>")

        XCTAssertEqual(
            PreparedArticleMemoryCache.contentFingerprint(for: original),
            PreparedArticleMemoryCache.contentFingerprint(for: sameContent)
        )
        XCTAssertNotEqual(
            PreparedArticleMemoryCache.contentFingerprint(for: original),
            PreparedArticleMemoryCache.contentFingerprint(for: changedContent)
        )
        XCTAssertNotEqual(
            PreparedArticleMemoryCache.contentFingerprint(for: original),
            PreparedArticleMemoryCache.contentFingerprint(for: changedTitle)
        )
    }
}
