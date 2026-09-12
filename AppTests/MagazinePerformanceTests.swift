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

    func testRailPreviewAccommodatesMultilineTitlesAndCapsLongPages() {
        let titles = [String(repeating: "需要完整显示的文章标题 ", count: 5), "第二篇文章", "第三篇文章"]
        let height = MagazinePageRail.previewHeight(titles: titles, width: 340, maximum: 400)
        XCTAssertGreaterThan(height, MagazinePageRail.previewHeight(titles: [titles[0]], width: 340, maximum: 400) + 30,
            "预览高度必须容纳本页其余标题，不能被导航条压住")
        XCTAssertLessThan(height, 400)
        XCTAssertEqual(MagazinePageRail.previewHeight(titles: Array(repeating: titles[0], count: 12),
            width: 340, maximum: 400), 400, "长页使用可滚动区域而非截断标题")
        XCTAssertGreaterThan(MagazinePageRail.previewHeight(titles: titles, width: 240, maximum: 400), height)
    }

    func testRailWaveIsLocalSymmetricAndKeepsNeighbouringTicksVisible() {
        XCTAssertGreaterThan(MagazinePageRail.waveHeight(distance: 0), MagazinePageRail.waveHeight(distance: 1))
        XCTAssertGreaterThan(MagazinePageRail.waveHeight(distance: 1), MagazinePageRail.waveHeight(distance: 2))
        XCTAssertEqual(MagazinePageRail.waveHeight(distance: -1.5), MagazinePageRail.waveHeight(distance: 1.5))
        XCTAssertEqual(MagazinePageRail.waveHeight(distance: 3), MagazinePageRail.tickHeight)
        XCTAssertEqual(MagazinePageRail.waveHeight(distance: 10), MagazinePageRail.tickHeight)
    }

    func testAudioWaveHeightFollowsSystemVolumeAndKeepsZeroVolumeQuiet() {
        XCTAssertEqual(MagazinePageRail.audioWaveHeight(index: 0, volume: 0, time: 0, reduceMotion: false),
                       MagazinePageRail.tickHeight)
        XCTAssertGreaterThan(
            MagazinePageRail.audioWaveHeight(index: 0, volume: 0.8, time: 0, reduceMotion: false),
            MagazinePageRail.tickHeight
        )
        XCTAssertLessThan(
            MagazinePageRail.audioWaveHeight(index: 0, volume: 0.2, time: 0, reduceMotion: false),
            MagazinePageRail.audioWaveHeight(index: 0, volume: 1, time: 0, reduceMotion: false)
        )
        XCTAssertEqual(
            MagazinePageRail.audioWaveHeight(index: 0, volume: 4, time: 0, reduceMotion: true),
            MagazinePageRail.audioWaveHeight(index: 0, volume: 1, time: 0, reduceMotion: true)
        )
    }

    func testAudioEnergyRespondsToSoundAndSettlesCompletelyAfterSilence() {
        var wave = AudioWaveEnvelope()
        XCTAssertTrue(wave.advance(rms: 0).allSatisfy { $0 == 0 })
        let quiet = wave.advance(rms: 0.01).last!
        let loud = wave.advance(rms: 0.4).last!
        XCTAssertGreaterThan(loud, quiet)
        let released = wave.advance(rms: 0).last!
        XCTAssertLessThan(released, loud)
        XCTAssertGreaterThan(released, 0)
        for _ in 0..<90 { _ = wave.advance(rms: 0) }
        XCTAssertTrue(wave.advance(rms: 0).allSatisfy { $0 == 0 })
        XCTAssertTrue(wave.advance(rms: .nan).allSatisfy { $0 == 0 })
    }

    func testAudioWaveSeparatesStrongAndWeakBeats() {
        var wave = AudioWaveEnvelope()
        for _ in 0..<60 { _ = wave.advance(rms: 0.1) }
        let strong = wave.advance(rms: 0.1).last!
        for _ in 0..<5 { _ = wave.advance(rms: 0.03) }
        let weak = wave.advance(rms: 0.03).last!
        let nextBeat = wave.advance(rms: 0.1).last!
        XCTAssertGreaterThan(strong, 0.9)
        XCTAssertLessThan(weak, 0.15)
        XCTAssertGreaterThan(nextBeat - weak, 0.7)
    }

    func testAudioWaveDoesNotInventMotionForSteadySoundOrNoise() {
        var wave = AudioWaveEnvelope()
        for _ in 0..<120 { _ = wave.advance(rms: 0.1) }
        let steady = wave.advance(rms: 0.1)
        XCTAssertLessThan(steady.max()! - steady.min()!, 0.001)
        var quiet = AudioWaveEnvelope()
        for _ in 0..<300 { _ = quiet.advance(rms: 0.001) }
        XCTAssertTrue(quiet.advance(rms: 0.001).allSatisfy { $0 == 0 })
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

extension MagazinePerformanceTests {
    func testShortTextEditionDoesNotReserveAnEmptyFeatureColumn() {
        let entries = (0..<12).map { EntryListItem(id: "brief-\($0)", feedID: UUID(),
            title: "一条短讯", sourceTitle: "来源") }
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .chronological,
            size: CGSize(width: 1180, height: 850), showsImages: false)
        XCTAssertTrue(pages[0].placements.allSatisfy { $0.style.role == .gallery })
        let right = pages[0].placements.first { $0.frame.minX > MagazinePaginator.contentWidth(1180) / 2 }
        XCTAssertEqual(pages[0].placements[0].frame.minY, right?.frame.minY)
        XCTAssertLessThan(pages[0].placements[0].frame.width, MagazinePaginator.contentWidth(1180) / 2)
        XCTAssertLessThan(pages[0].placements[1].frame.minY - pages[0].placements[0].style.contentInset * 2,
            120, "扣除明确的交互内边距后，纯短讯仍不能预留主稿空白")
    }

    func testSupportingStoriesUseSpaceForSummariesAndLargerImages() {
        let entries = (0..<8).map { EntryListItem(id: "support-\($0)", feedID: UUID(),
            title: "一篇简短标题", summaryPreview: String(repeating: "描述文字可以展开阅读。", count: 12),
            sourceTitle: "周刊", previewImageURL: URL(string: "https://example.org/image.jpg")) }
        for size in [CGSize(width: 1180, height: 1000),
                     MagazinePaginator.foldViewport(CGSize(width: 926, height: 716))] {
            let page = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .chronological,
                size: size, showsImages: true)[0]
            for placement in page.placements[1...3] {
                XCTAssertEqual(placement.style.role, .supporting)
                XCTAssertGreaterThanOrEqual(placement.style.summaryLines, 2)
                XCTAssertGreaterThan(placement.style.imageHeight, 76)
            }
            XCTAssertEqual(page.placements[2].frame.minY - page.placements[1].frame.maxY, 16, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(page.placements.count, 6, "矮窗口也应保留两侧画廊")
        }
    }

    func testEditorialFeatureKeepsThreeBriefsTogetherAndGalleryBelow() {
        let feed = UUID()
        let entries = (0..<12).map { index in
            EntryListItem(id: "editorial-\(index)", feedID: feed,
                title: "从一篇主稿开始阅读，再顺着三条短讯进入文章列表",
                summaryPreview: "让标题、图片和留白建立清晰的阅读顺序。", sourceTitle: "设计周刊",
                previewImageURL: URL(string: "https://example.org/image.jpg"))
        }
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .chronological,
            size: CGSize(width: 1180, height: 850), showsImages: true)
        let placements = pages[0].placements
        XCTAssertGreaterThan(placements.count, 4)
        XCTAssertEqual(placements[0].style.role, .lead)
        XCTAssertEqual(placements[1...3].map(\.style.role), [.supporting, .supporting, .supporting])
        XCTAssertEqual(placements[3].frame.maxY, placements[0].frame.maxY, accuracy: 0.01)
        XCTAssertGreaterThan(placements[4].frame.minY, placements[0].frame.maxY)
        XCTAssertEqual(placements[4].style.role, .gallery)
        XCTAssertGreaterThanOrEqual(placements.count, 6)
        let rightGallery = placements.dropFirst(4).first { $0.frame.minX > MagazinePaginator.contentWidth(1180) / 2 }
        XCTAssertEqual(placements[4].frame.minY, rightGallery?.frame.minY)
        XCTAssertLessThan(placements[4].frame.width, MagazinePaginator.contentWidth(1180) / 2)
        XCTAssertGreaterThan(rightGallery?.frame.minX ?? 0, placements[4].frame.maxX)
        for page in pages {
            for placement in page.placements {
                let entry = page.page.entries.first { $0.id == placement.entryID }!
                XCTAssertLessThanOrEqual(placement.style.height(for: entry, width: placement.frame.width),
                    placement.frame.height + 0.01, "可见文本不能从固定格子底部截断")
            }
        }
        XCTAssertEqual(pages.flatMap { $0.page.entries.map(\.id) }, entries.map(\.id))
    }
}

extension MagazinePerformanceTests {
    func testMixedGalleryStaysOnItsOwnPaperAndFitsOneToThreeStories() {
        let entries = (0..<30).map { index in
            EntryListItem(id: "mixed-\(index)", feedID: UUID(), title: "混合排版的文章标题",
                summaryPreview: String(repeating: "有图片与没有图片的文章使用各自合适的空间。", count: index % 3 + 1),
                sourceTitle: "杂志", previewImageURL: index % 2 == 0 ? URL(string: "https://example.com/p.jpg") : nil)
        }
        let size = CGSize(width: 1240, height: 1000)
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .chronological, size: size, showsImages: true)
        let middle = MagazinePaginator.contentWidth(size.width) / 2
        XCTAssertEqual(pages.flatMap { $0.page.entries.map(\.id) }, entries.map(\.id))
        for page in pages {
            let cards = page.placements.filter { $0.style.role == .gallery }
            for card in cards {
                XCTAssertTrue(card.frame.maxX < middle || card.frame.minX > middle, "卡片不能跨过书脊")
                XCTAssertLessThanOrEqual(card.frame.maxY, page.height + 0.01)
            }
            for left in [true, false] {
                let column = cards.filter { ($0.frame.midX < middle) == left }
                XCTAssertLessThanOrEqual(column.count, 3)
                for pair in zip(column, column.dropFirst()) {
                    XCTAssertFalse(pair.0.frame.intersects(pair.1.frame))
                }
            }
        }
    }

    func testSpatialNavigationUsesNeighborsAndLeavesOuterEdgesToPaging() {
        let placements = [
            MagazinePlacement(entryID: "lead", frame: CGRect(x: 0, y: 0, width: 300, height: 350), style: .init()),
            MagazinePlacement(entryID: "right-top", frame: CGRect(x: 340, y: 0, width: 300, height: 100), style: .init()),
            MagazinePlacement(entryID: "right-mid", frame: CGRect(x: 340, y: 120, width: 300, height: 100), style: .init()),
            MagazinePlacement(entryID: "bottom", frame: CGRect(x: 0, y: 400, width: 300, height: 150), style: .init())
        ]
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[0], in: placements, key: 124)?.entryID, "right-mid")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[0], in: placements, key: 125)?.entryID, "bottom")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[2], in: placements, key: 126)?.entryID, "right-top")
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: placements[0], in: placements, key: 123))
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: placements[2], in: placements, key: 124))
    }
}

extension MagazinePerformanceTests {
    func testFullEditionUsesOneLeadAndFourCompactGalleryStories() {
        let feed = UUID()
        let entries = (0..<24).map { index in
            EntryListItem(id: "dense-\(index)", feedID: feed, title: "正常长度的周刊文章标题",
                summaryPreview: "图片和文字互相搭配，保留适度的阅读间距。", sourceTitle: "周刊",
                previewImageURL: index % 3 == 0 ? nil : URL(string: "https://example.com/photo.jpg"))
        }
        let size = CGSize(width: 1240, height: 1000)
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced, size: size, showsImages: true)
        let first = pages[0]
        let gallery = first.placements.filter { $0.style.role == .gallery }
        XCTAssertEqual(gallery.count, 4)
        XCTAssertEqual(first.placements.filter { $0.style.role == .lead }.count, 1)
        XCTAssertTrue(gallery.contains { $0.style.imageHeight > 0 && !$0.style.imageBesideText })
        XCTAssertTrue(gallery.allSatisfy {
            $0.style.imageHeight <= 120 || $0.frame.width > MagazinePaginator.contentWidth(size.width) / 4
        })
        XCTAssertTrue(gallery.contains { $0.frame.width < MagazinePaginator.contentWidth(size.width) / 4 })
        for left in [true, false] {
            XCTAssertTrue((1...3).contains(gallery.filter { ($0.frame.midX < MagazinePaginator.contentWidth(size.width) / 2) == left }.count))
        }
        XCTAssertEqual(pages.flatMap { $0.page.entries.map(\.id) }.sorted(), entries.map(\.id).sorted())
        let again = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced, size: size, showsImages: true)
        XCTAssertEqual(first.placements.map(\.frame), again[0].placements.map(\.frame))
    }
}


extension MagazinePerformanceTests {
    func testGalleryFillsAllocatedAreaEvenWithoutSummary() {
        let feed = UUID()
        for count in [5, 7, 8, 9] {
            let entries = (0..<count).map { index in
                EntryListItem(id: "fill-\(index)", feedID: feed, title: "画廊文章",
                    summaryPreview: index % 2 == 0 ? "一段摘要" : "", sourceTitle: "周刊",
                    previewImageURL: URL(string: "https://example.com/photo.jpg"))
            }
            let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .chronological,
                size: CGSize(width: 1240, height: 1000), showsImages: true)
            for page in pages {
                let cards = page.placements.filter { $0.style.role == .gallery }
                guard page.placements.contains(where: { $0.style.role == .lead }) else { continue }
                for card in cards {
                    XCTAssertEqual(card.style.allocatedHeight, card.frame.height)
                }
                for isLeft in [true, false] {
                    let side = cards.filter { ($0.frame.midX < MagazinePaginator.contentWidth(1240) / 2) == isLeft }
                    guard !side.isEmpty else { continue }
                    XCTAssertEqual(side.map(\.frame.maxY).max()!, page.height, accuracy: 0.01)
                    if side.count == 1 {
                        XCTAssertEqual(side[0].frame.width, (MagazinePaginator.contentWidth(1240) - MagazinePaginator.gutter) / 2)
                    }
                }
            }
        }
    }
}


extension MagazinePerformanceTests {
    func testTextOnlyPageDoesNotStretchCardsToPageBottom() {
        let feed = UUID()
        let entries = (0..<3).map { index in
            EntryListItem(id: "text-only-\(index)", feedID: feed, title: "简短文章标题",
                summaryPreview: index == 0 ? "简短摘要。" : "", sourceTitle: "订阅源")
        }
        for viewportHeight: CGFloat in [700, 1000, 1400] {
            let page = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .chronological,
                size: CGSize(width: 1240, height: viewportHeight), showsImages: true)[0]
            XCTAssertEqual(page.placements.count, 3)
            for card in page.placements {
                let entry = entries.first { $0.id == card.entryID }!
                XCTAssertNil(card.style.allocatedHeight)
                XCTAssertEqual(card.frame.height, card.style.height(for: entry, width: card.frame.width), accuracy: 0.01)
                XCTAssertLessThan(card.frame.height, 200)
            }
        }
    }
}

extension MagazinePerformanceTests {
    func testInactiveMagazineDoesNotConsumeSettingsClicks() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = MagazineInputRegion.Surface(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = surface
        defer { surface.stop(); window.close() }
        var turns = 0
        func input(active: Bool) -> MagazineInputRegion {
            MagazineInputRegion(active: active, articleFrames: [], onArticleDown: { _ in },
                onTurn: { _ in turns += 1 }, onClear: {}, onEdge: { _ in }, onSwipe: { _, _, _, _ in })
        }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 850, y: 300), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,
            location: NSPoint(x: 850, y: 300), modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        surface.input = input(active: true)
        XCTAssertNotNil(surface.handle(down))
        XCTAssertNil(surface.handle(up))
        XCTAssertEqual(turns, 1)
        surface.input = input(active: false)
        surface.resetInteraction()
        XCTAssertNotNil(surface.handle(down))
        XCTAssertNotNil(surface.handle(up))
        XCTAssertEqual(turns, 1)
        XCTAssertNil(surface.down)
        surface.input = input(active: true)
        XCTAssertNotNil(surface.handle(up), "返回杂志后不能延续设置页上的点击")
    }
}
