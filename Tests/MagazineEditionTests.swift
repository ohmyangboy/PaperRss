import XCTest
@testable import PaperRssCore

final class MagazineEditionTests: XCTestCase {
    private let feedA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let feedB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private func entries(_ count: Int) -> [EntryListItem] {
        (0..<count).map { index in
            EntryListItem(id: "article-\(index)", feedID: index.isMultiple(of: 2) ? feedA : feedB,
                title: "Title \(index)", sourceTitle: index.isMultiple(of: 2) ? "Feed A" : "Feed B",
                isRead: index.isMultiple(of: 3), isStarred: index.isMultiple(of: 5),
                previewImageURL: index == 1 ? URL(string: "https://example.org/image.jpg") : nil)
        }
    }
    func testEveryOrderingKeepsAllItemsExactlyOnceAndNeverChangesReadState() {
        let original = entries(103)
        for arrangement in MagazineArrangement.allCases {
            let pages = MagazineEdition.pages(entries: original + [original[0]], arrangement: arrangement,
                folders: [feedA: "Design", feedB: "Design"], capacity: 6)
            let all = pages.flatMap(\.entries)
            XCTAssertEqual(all.count, original.count)
            XCTAssertEqual(Set(all), Set(original))
            XCTAssertEqual(Set(pages.map(\.id)).count, pages.count)
            XCTAssertTrue(pages.allSatisfy { (1...6).contains($0.entries.count) })
        }
    }
    func testChronologicalOptionLeavesQueryOrderUntouched() {
        let original = entries(27)
        let pages = MagazineEdition.pages(entries: original, arrangement: .chronological)
        XCTAssertEqual(pages.flatMap(\.entries).map(\.id), original.map(\.id))
    }
    func testBalancedClustersWithinStablePageBoundariesOnly() {
        let original = entries(18)
        let before = MagazineEdition.pages(entries: Array(original.prefix(12)), arrangement: .balanced)
        let after = MagazineEdition.pages(entries: original, arrangement: .balanced)
        XCTAssertEqual(before, Array(after.prefix(2)))
        XCTAssertEqual(before[0].entries.map(\.id), ["article-0", "article-2", "article-4", "article-1", "article-3", "article-5"])
    }
    func testSourceAndFolderGroupingUsesAccountIdentityNotDisplayNames() {
        let data = [
            EntryListItem(id: "one", feedID: feedA, title: "One", sourceTitle: "Same name", accountID: "local"),
            EntryListItem(id: "two", feedID: feedB, title: "Two", sourceTitle: "Same name", accountID: "remote")
        ]
        for mode in [MagazineArrangement.source, .folder] {
            let pages = MagazineEdition.pages(entries: data, arrangement: mode, folders: [feedA: "Tech", feedB: "Tech"])
            XCTAssertEqual(pages.count, 2)
        }
    }
    func testImageOffAndTextOnlyNeverReserveAFeatureSlot() {
        let page = MagazineEdition.pages(entries: entries(6), arrangement: .balanced)[0]
        XCTAssertEqual(page.featuredID(showsImages: true), "article-1")
        XCTAssertNil(page.featuredID(showsImages: false))
        let text = MagazineEdition.pages(entries: entries(6).filter { $0.previewImageURL == nil }, arrangement: .balanced)[0]
        XCTAssertNil(text.featuredID(showsImages: true))
    }
    func testResizeAndRegroupFindCurrentPageByArticleIdentity() {
        let original = entries(38)
        for mode in MagazineArrangement.allCases {
            for capacity in [1, 3, 6, 9, 12] {
                let pages = MagazineEdition.pages(entries: original, arrangement: mode, capacity: capacity)
                let index = MagazineEdition.pageIndex(containing: "article-20", in: pages)
                XCTAssertTrue(pages[index].entries.contains { $0.id == "article-20" })
            }
        }
    }
    func testEmptyAndOutOfRangeInputsAreSafe() {
        XCTAssertTrue(MagazineEdition.pages(entries: [], arrangement: .balanced).isEmpty)
        XCTAssertEqual(MagazineEdition.pageIndex(containing: "missing", in: []), 0)
        XCTAssertEqual(MagazineEdition.pages(entries: entries(3), arrangement: .balanced, capacity: 0).count, 3)
    }
}
