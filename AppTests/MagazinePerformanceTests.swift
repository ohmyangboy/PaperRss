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

extension MagazinePerformanceTests {
    func testMeasuredPagesFitAndKeepEveryArticleInDisplayOrder() {
        let feed = UUID()
        for size in [CGSize(width: 400, height: 400), CGSize(width: 1000, height: 700), CGSize(width: 1600, height: 1000)] {
            for images in [false, true] {
                let entries = (0..<65).map { i in
                    EntryListItem(id: "p\(i)", feedID: feed,
                        title: i.isMultiple(of: 2) ? String(repeating: "中英文排版 Long title ", count: 5) : "短讯",
                        summaryPreview: i.isMultiple(of: 3) ? String(repeating: "摘要内容与空间测量。", count: 30) : "",
                        sourceTitle: "来源", previewImageURL: i.isMultiple(of: 4) ? URL(string: "https://example.org/cover.jpg") : nil)
                }
                let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .chronological, size: size, showsImages: images)
                XCTAssertEqual(pages.flatMap { $0.page.entries.map(\.id) }, entries.map(\.id))
                for page in pages {
                    XCTAssertEqual(page.placements.map(\.entryID), page.page.entries.map(\.id))
                    for (index, item) in page.placements.enumerated() {
                        XCTAssertLessThanOrEqual(item.frame.maxY, page.height + 0.01)
                        XCTAssertLessThanOrEqual(item.frame.maxX, MagazinePaginator.contentWidth(size.width) + 0.01)
                        for other in page.placements.dropFirst(index + 1) { XCTAssertFalse(item.frame.intersects(other.frame)) }
                    }
                }
            }
        }
    }

    func testLateImageMetadataKeepsPagesAndResizePublishesGeometry() {
        let feed = UUID()
        let plain = EntryListItem(id: "story", feedID: feed, title: "文字主稿", sourceTitle: "来源")
        let image = EntryListItem(id: plain.id, feedID: feed, title: plain.title, sourceTitle: plain.sourceTitle,
            previewImageURL: URL(string: "https://example.org/late.jpg"))
        let cache = MagazineEditionCache()
        func input(_ entry: EntryListItem, width: CGFloat) -> MagazineEditionCache.Input {
            .init(entries: [entry], folders: [:], arrangement: .balanced, capacity: 12, locale: "zh",
                  viewport: CGSize(width: width, height: 700), showsImages: true)
        }
        cache.update(input(plain, width: 1000))
        let before = cache.layouts.values.first?.placements
        cache.update(input(image, width: 1000))
        XCTAssertEqual(cache.layouts.values.first?.placements, before)
        XCTAssertEqual(cache.pages.first?.entries.first?.previewImageURL, image.previewImageURL)
        var updates = 0
        let observation = cache.$layouts.dropFirst().sink { _ in updates += 1 }
        cache.update(input(image, width: 500))
        XCTAssertEqual(updates, 1)
        XCTAssertNotEqual(cache.layouts.values.first?.placements, before)
        withExtendedLifetime(observation) {}
    }

    func testMeasuredEditionAppendAndReadFlagsRetainExistingPageGeometry() {
        let feed = UUID()
        let original = (0..<17).map { EntryListItem(id: "p\($0)", feedID: feed, title: "标题 \($0)", sourceTitle: "来源") }
        let cache = MagazineEditionCache()
        var input = MagazineEditionCache.Input(entries: original, folders: [:], arrangement: .balanced,
            capacity: 12, locale: "zh", viewport: CGSize(width: 1000, height: 700), showsImages: false)
        cache.update(input)
        let before = cache.pages
        let layout = cache.layouts
        let read = original.map { EntryListItem(id: $0.id, feedID: feed, title: $0.title, sourceTitle: $0.sourceTitle, isRead: true) }
        input = .init(entries: read + [EntryListItem(id: "later", feedID: feed, title: "后来", sourceTitle: "来源")],
            folders: [:], arrangement: .balanced, capacity: 12, locale: "zh", viewport: CGSize(width: 1000, height: 700), showsImages: false)
        cache.update(input)
        XCTAssertEqual(Array(cache.pages.prefix(before.count)).map(\.id), before.map(\.id))
        for page in before { XCTAssertEqual(cache.layouts[page.id]?.placements, layout[page.id]?.placements) }
        XCTAssertTrue(cache.pages.first?.entries.allSatisfy(\.isRead) == true)
    }
}
