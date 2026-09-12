import Combine
import SwiftUI
import XCTest
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
final class MagazinePerformanceTests: XCTestCase {
    func testScrollOffsetsOnSamePageDoNotPublishRepeatedChanges() {
        let memory = TimelinePresentationMemory()
        var notifications = 0
        let subscription = memory.objectWillChange.sink { notifications += 1 }
        memory.magazineAnchor = "one"
        for _ in 0..<500 { memory.magazineAnchor = "one" }
        XCTAssertEqual(notifications, 1)
        memory.magazineAnchor = "two"
        XCTAssertEqual(notifications, 2)
        withExtendedLifetime(subscription) {}
    }

    func testThousandArticleEditionIsNotRebuiltByPageLookupsOrSameInput() {
        let feed = UUID()
        let entries = (0..<1000).map { EntryListItem(id: "a\($0)", feedID: feed, title: "Story \($0)", sourceTitle: "Feed") }
        let input = MagazineEditionCache.Input(entries: entries, folders: [:], arrangement: .balanced, capacity: 6, locale: "en")
        let cache = MagazineEditionCache()
        cache.update(input)
        for _ in 0..<120 {
            cache.update(input)
            XCTAssertEqual(cache.pageIndex(containing: "a600"), 100)
        }
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(cache.pages.flatMap(\.entries).map(\.id), entries.map(\.id))
    }

    func testCacheInvalidatesForSameIDContentChangeAndGroupingInputs() {
        let feed = UUID()
        let cache = MagazineEditionCache()
        let first = EntryListItem(id: "one", feedID: feed, title: "Before", sourceTitle: "Feed")
        let changed = EntryListItem(id: "one", feedID: feed, title: "After", sourceTitle: "Feed", isRead: true)
        cache.update(.init(entries: [first], folders: [:], arrangement: .balanced, capacity: 6, locale: "en"))
        cache.update(.init(entries: [changed], folders: [:], arrangement: .balanced, capacity: 6, locale: "en"))
        XCTAssertEqual(cache.pages.first?.entries.first?.title, "After")
        XCTAssertEqual(cache.pages.first?.entries.first?.isRead, true)
        cache.update(.init(entries: [changed], folders: [feed: "Design"], arrangement: .folder, capacity: 3, locale: "zh-Hans"))
        XCTAssertEqual(cache.rebuildCount, 3)
        XCTAssertTrue(cache.contains("one"))
        cache.update(.init(entries: [], folders: [:], arrangement: .balanced, capacity: 6, locale: "en"))
        XCTAssertTrue(cache.pages.isEmpty)
        XCTAssertFalse(cache.contains("one"))
    }

    func testRailIsRotatedReaderTickWithoutCurrentPageWidthExpansion() {
        XCTAssertEqual(MagazinePageRail.tickWidth, 3)
        XCTAssertEqual(MagazinePageRail.tickHeight, 8)
    }

    func testMasonryCacheRetainsMeasurementsOnlyForSameGeometry() {
        var cache = MagazineMasonryLayout.Cache()
        var measurements = 0
        func resolve(width: CGFloat, columns: Int) -> [CGRect] {
            cache.resolve(width: width, columns: columns, spacing: 20, count: 1) {
                measurements += 1
                return [CGRect(x: 0, y: 0, width: width, height: 80)]
            }
        }
        _ = resolve(width: 1100, columns: 3)
        _ = resolve(width: 1100, columns: 3)
        XCTAssertEqual(measurements, 1)
        _ = resolve(width: 800, columns: 2)
        XCTAssertEqual(measurements, 2)
        cache = MagazineMasonryLayout.Cache() // updateCache on changed subviews
        _ = resolve(width: 800, columns: 2)
        XCTAssertEqual(measurements, 3)
    }
}
