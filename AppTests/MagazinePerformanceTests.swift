import Combine
import SwiftUI
import XCTest
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
private final class OpeningThumbnailProbe {
    var requests: [ArticleThumbnailRequest] = []
}

@MainActor
final class MagazinePerformanceTests: XCTestCase {
    func testClosedBookPreloadsDecodedImagesWithoutImageViews() async throws {
        let memory = TimelinePresentationMemory()
        let probe = OpeningThumbnailProbe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MagazinePreload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let requested = expectation(description: "封面等待时开始下载")
        let store = ArticleThumbnailStore(directory: directory, loader: { request in
            await MainActor.run {
                XCTAssertFalse(memory.magazineIsOpen)
                probe.requests.append(request)
                requested.fulfill()
            }
            return data
        })
        let entry = EntryListItem(id: "opening", feedID: UUID(), title: "开页预加载", sourceTitle: "测试",
            previewImageURL: URL(string: "https://example.org/opening.png"))
        let view = MagazineBrowserView(entries: [entry], folders: [:], availableSize: CGSize(width: 1000, height: 720),
            showsImages: true, isBrowsing: true, hasMore: false, selectedID: nil, keyboardRequest: nil,
            memory: memory, thumbnailStore: store, onHighlight: { _ in }, onOpen: { _ in }, onNeedMore: {},
            tile: { _, _, _ in Color.clear })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        await fulfillment(of: [requested], timeout: 5)
        let request = try XCTUnwrap(probe.requests.first)
        for _ in 0..<100 where store.cachedImage(for: request) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.cachedImage(for: request), "下载结果已解码，开页可同步命中")
        _ = try await store.image(for: request)
        XCTAssertEqual(probe.requests.count, 1, "实际展示复用缓存，不重复请求")
    }

    func testOpeningPreloadIsLimitedToFirstPageAndRejectsOldScopeOrDisabledImages() throws {
        let scope = UUID(), feed = UUID()
        let entries = (0..<30).map { index in
            EntryListItem(id: "preload-\(index)", feedID: feed, title: "首屏图片 \(index)",
                sourceTitle: "预加载测试", previewImageURL: URL(string: "https://example.org/\(index).jpg"))
        }
        let cache = MagazineEditionCache()
        let input = MagazineEditionCache.Input(entries: entries, folders: [:], arrangement: .balanced,
            capacity: 12, locale: "zh-Hans", viewport: CGSize(width: 1000, height: 720), scopeID: scope)
        cache.update(input)
        XCTAssertGreaterThan(cache.pages.count, 1)
        let requests = cache.openingImageRequests(scopeID: scope, scale: 2)
        XCTAssertFalse(requests.isEmpty)
        XCTAssertEqual(requests.count, Set(requests).count)
        let firstPageURLs = Set(try XCTUnwrap(cache.pages.first).entries.compactMap(\.previewImageURL))
        XCTAssertTrue(Set(requests.map(\.url)).isSubset(of: firstPageURLs))
        XCTAssertTrue(cache.openingImageRequests(scopeID: UUID(), scale: 2).isEmpty,
            "订阅切换但新版式尚未发布时，不预取旧订阅图片")
        let nextRequests = cache.imageRequests(forPageAt: 1, scopeID: scope, scale: 2)
        XCTAssertFalse(nextRequests.isEmpty)
        let secondPageURLs = Set(cache.pages[1].entries.compactMap(\.previewImageURL))
        XCTAssertTrue(Set(nextRequests.map(\.url)).isSubset(of: secondPageURLs))
        XCTAssertTrue(cache.imageRequests(forPageAt: 999, scopeID: scope, scale: 2).isEmpty)
        var disabled = input
        disabled.showsImages = false
        cache.update(disabled)
        XCTAssertTrue(cache.openingImageRequests(scopeID: scope, scale: 2).isEmpty)
        XCTAssertTrue(cache.imageRequests(forPageAt: 1, scopeID: scope, scale: 2).isEmpty)
    }

    func testOpeningThumbnailUsesDisplaySizeAndOmitsTextOnlyStories() throws {
        let entry = EntryListItem(id: "image", feedID: UUID(), title: "图片", sourceTitle: "测试",
            previewImageURL: URL(string: "https://example.org/image.jpg"))
        var style = MagazineStoryStyle(imageHeight: 180, contentInset: 20)
        XCTAssertEqual(try XCTUnwrap(style.thumbnailRequest(for: entry, width: 350, scale: 2)).pixelSize, 640)
        XCTAssertEqual(try XCTUnwrap(style.thumbnailRequest(for: entry, width: 700, scale: 2)).pixelSize, 1280)
        style.imageBesideText = true
        XCTAssertEqual(try XCTUnwrap(style.thumbnailRequest(for: entry, width: 700, scale: 2)).pixelSize, 640)
        style.imageAspectRatio = 2
        XCTAssertEqual(try XCTUnwrap(style.thumbnailRequest(for: entry, width: 700, scale: 2)).pixelSize, 640,
            "旁图宽度受文字栏比例约束，原图比例不应放大预取尺寸")
        style.sideImageWidth = 360
        XCTAssertEqual(try XCTUnwrap(style.thumbnailRequest(for: entry, width: 700, scale: 2)).pixelSize, 1280)
        style.imageHeight = 0
        XCTAssertNil(style.thumbnailRequest(for: entry, width: 700, scale: 2))
    }

    func testRailFrameInputCoalescesAndFlushesReleaseWithoutOldCallbacks() async throws {
        let input = MagazineRailFrameInput()
        var positions: [Double] = []
        for value in 0..<100 { input.submit(Double(value)) { positions.append($0) } }
        XCTAssertTrue(positions.isEmpty)
        for _ in 0..<50 where positions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(positions, [99])
        input.submit(150) { positions.append($0) }
        input.flush()
        input.submit(200) { positions.append($0) }
        input.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(positions, [99, 150])
    }

    func testRailTickCountIsBoundedWhilePositionStillAddressesEveryPage() {
        for count in [1, 2, 30, 100, 10_000] {
            let indices = MagazineRailScrub.tickIndices(count: count, width: 280)
            XCTAssertLessThanOrEqual(indices.count, 40)
            XCTAssertEqual(indices.first, 0)
            XCTAssertEqual(indices.last, count - 1)
            XCTAssertEqual(indices, Array(Set(indices)).sorted())
            for index in 0..<count {
                let normalized = count > 1 ? Double(index) / Double(count - 1) : 0
                XCTAssertEqual(MagazineRailScrub.nearestIndex(normalized: normalized, count: count), index)
            }
            for current in [0, count / 2, count - 1] {
                let selected = MagazineRailScrub.tickIndices(count: count, width: 280, currentIndex: current)
                XCTAssertTrue(selected.contains(current), "合并刻度后当前页仍须可以被选中和朗读")
                XCTAssertLessThanOrEqual(selected.count, 40)
                XCTAssertEqual(selected, Array(Set(selected)).sorted())
            }
        }
    }

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

    func testRailScrubMapsWholeLoadedRangeAndClampsEdges() {
        XCTAssertEqual(MagazineRailScrub.normalizedPosition(locationX: -20, width: 280), 0)
        XCTAssertEqual(MagazineRailScrub.normalizedPosition(locationX: 400, width: 280), 1)
        XCTAssertEqual(MagazineRailScrub.pagePosition(normalized: 0.5, count: 1), 0)
        XCTAssertEqual(MagazineRailScrub.nearestIndex(position: 0, count: 1), 0)
        XCTAssertEqual(MagazineRailScrub.pagePosition(normalized: 0.5, count: 31), 15)
        XCTAssertEqual(MagazineRailScrub.nearestIndex(position: 14.6, count: 31), 15)
        XCTAssertEqual(MagazineRailScrub.nearestIndex(position: -4, count: 31), 0)
        XCTAssertEqual(MagazineRailScrub.nearestIndex(position: 50, count: 31), 30)
    }

    func testRailScrubPairReusesAdjacentPagesInBothDirections() {
        let forward = MagazineRailScrub.pair(position: 4.25, count: 20, forward: true)
        XCTAssertEqual(forward, .init(sourceIndex: 4, targetIndex: 5, progress: 0.25, forward: true))
        let backward = MagazineRailScrub.pair(position: 4.25, count: 20, forward: false)
        XCTAssertEqual(backward, .init(sourceIndex: 5, targetIndex: 4, progress: 0.75, forward: false))
        XCTAssertEqual(MagazineRailScrub.pair(position: 4, count: 20, forward: false),
                       .init(sourceIndex: 4, targetIndex: 3, progress: 0, forward: false))
        let last = MagazineRailScrub.pair(position: 19, count: 20, forward: true)
        XCTAssertEqual(last?.targetIndex, 19)
        XCTAssertEqual(last?.progress, 1)
        let first = MagazineRailScrub.pair(position: 0, count: 20, forward: false)
        XCTAssertEqual(first?.targetIndex, 0)
        XCTAssertEqual(first?.progress, 1)
        if let forward {
            XCTAssertEqual(MagazineRailScrub.progress(position: 4.75, in: forward), 0.75)
            XCTAssertEqual(MagazineRailScrub.progress(position: 3.9, in: forward), nil)
        }
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

    func testRailScrubHighlightSlotMatchesWavePeakAndClampsEdges() {
        // 拖动时高亮与波浪共用指针槽位：高亮刻度必须就是波浪最高的那一个，不能各亮一处。
        let slotWidth: CGFloat = 8
        let slots = 10
        for position in stride(from: CGFloat(-12), through: 84, by: 1.3) {
            let slot = MagazineRailScrub.slot(position: position, slotWidth: slotWidth, slots: slots)
            let heights = (0..<slots).map {
                MagazinePageRail.waveHeight(distance: (position - (CGFloat($0) * slotWidth + slotWidth / 2)) / slotWidth)
            }
            XCTAssertEqual(heights[slot], heights.max() ?? 0, accuracy: 0.0001,
                "位置 \(position) 的高亮必须落在波浪峰值刻度")
        }
        XCTAssertEqual(MagazineRailScrub.slot(position: -100, slotWidth: slotWidth, slots: slots), 0)
        XCTAssertEqual(MagazineRailScrub.slot(position: 1000, slotWidth: slotWidth, slots: slots), slots - 1)
        XCTAssertEqual(MagazineRailScrub.slot(position: .nan, slotWidth: slotWidth, slots: slots), 0)
        XCTAssertEqual(MagazineRailScrub.slot(position: 10, slotWidth: 0, slots: slots), 0)
        XCTAssertEqual(MagazineRailScrub.slot(position: 10, slotWidth: slotWidth, slots: 0), 0)
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
        before.forEach { cache.markDisplayed($0.id) }
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
    func testShortTextEditionCrossesFormerTwelveArticleBoundary() {
        let entries = editorialEntries(40)
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1250), showsImages: false, hasMore: true)
        XCTAssertGreaterThan(pages[0].consumedCount, 12)
        XCTAssertTrue(pages[0].placements.allSatisfy { $0.style.role == .gallery })
        XCTAssertEqual(Set(pages[0].placements.map { $0.frame.minX }).count, 4)
        XCTAssertEqual(pages.flatMap(\.readingOrder), entries.map(\.id))
    }

    func testNormalImageStoriesKeepSummaryAndImageBudget() {
        let entries = Array(editorialEntries(21, images: true).dropFirst())
        let page = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1100), showsImages: true)[0]
        XCTAssertEqual(page.template, .imageLead)
        XCTAssertEqual(page.placements.first?.style.titleSize, 34)
        XCTAssertTrue(page.placements.dropFirst().contains { $0.style.role == .supporting && $0.style.imageHeight >= 72 })
        XCTAssertTrue(page.placements.dropFirst().contains { $0.style.role == .gallery && $0.style.imageHeight > 0 })
    }

    func testTextLeadContinuesWithNaturalHeightStoriesBelow() {
        let first = EntryListItem(id: "lead", feedID: UUID(), title: String(repeating: "中英文长标题 SwiftUI ", count: 4),
            summaryPreview: String(repeating: "保留真实摘要与文字层级。", count: 10), sourceTitle: "来源")
        let entries = [first] + editorialEntries(20, images: true)
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1100), showsImages: true)
        XCTAssertEqual(pages[0].template, .textLead)
        XCTAssertEqual(pages[0].readingOrder.first, "lead")
        let lead = pages[0].placements[0]
        let secondary = pages[0].placements.dropFirst().prefix { $0.style.role == .supporting }
        XCTAssertEqual(lead.frame.minX, 0)
        XCTAssertFalse(secondary.isEmpty)
        XCTAssertTrue(secondary.allSatisfy { $0.frame.minX > lead.frame.maxX })
        XCTAssertTrue(pages[0].placements.contains { $0.style.role == .gallery && $0.frame.minY > lead.frame.minY })
        assertEditorialGeometry(pages)
    }
}

extension MagazinePerformanceTests {
    func testMixedModulesStayWithinLeafAndPreserveReadingOrder() {
        let entries = editorialEntries(43, images: true)
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1000), showsImages: true)
        XCTAssertEqual(pages.flatMap(\.readingOrder), entries.map(\.id))
        assertEditorialGeometry(pages)
        for page in pages where page.form == .spread {
            let middle = page.contentWidth / 2
            for placement in page.placements {
                XCTAssertTrue(placement.frame.maxX < middle || placement.frame.minX > middle)
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
        // 遥控式向右：同一水平带里选纵向最贴近的 right-mid；向左回到 lead
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[0], in: placements, key: 124)?.entryID, "right-mid")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[1], in: placements, key: 123)?.entryID, "lead")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[0], in: placements, key: 125)?.entryID, "bottom")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[2], in: placements, key: 126)?.entryID, "right-top")
        // 右端没有卡片即页面边缘：返回 nil 交给外层翻页/提示读完，不再换行前进
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: placements[0], in: placements, key: 123))
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: placements[1], in: placements, key: 124))
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: placements[2], in: placements, key: 124))
        // 左端没有卡片同样交给外层：bottom 与 lead 同栏，左侧为空
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: placements[3], in: placements, key: 123))
        // 左半页底部跨带向右仍就近落到右半页最近的 right-mid
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: placements[3], in: placements, key: 124)?.entryID, "right-mid")
    }

    func testSpatialNavigationPrefersAdjacentRightColumnBeforeHigherFarColumn() {
        let staggered = [
            MagazinePlacement(entryID: "left", frame: CGRect(x: 0, y: 0, width: 200, height: 260), style: .init()),
            MagazinePlacement(entryID: "near-column", frame: CGRect(x: 220, y: 60, width: 200, height: 120), style: .init()),
            MagazinePlacement(entryID: "far-column-top", frame: CGRect(x: 440, y: 0, width: 200, height: 120), style: .init())
        ]
        // 从左到右优先：即使远处一栏的卡片更靠上，也应先落到相邻栏的 near-column
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: staggered[0], in: staggered, key: 124)?.entryID, "near-column")
        // 反向左移同样就近回到 near-column
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: staggered[1], in: staggered, key: 123)?.entryID, "left")
    }

    func testSpatialNavigationCrossesToNearestRightHalfWithoutRowOverlap() {
        let spread = [
            MagazinePlacement(entryID: "left-low", frame: CGRect(x: 0, y: 420, width: 300, height: 320), style: .init()),
            MagazinePlacement(entryID: "right-top", frame: CGRect(x: 340, y: 0, width: 300, height: 180), style: .init()),
            MagazinePlacement(entryID: "right-low", frame: CGRect(x: 340, y: 200, width: 300, height: 180), style: .init())
        ]
        // 左半页底部同带没有右侧卡片时，仍然落到右半页就近的那篇（right-low 比 right-top 更贴近）
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: spread[0], in: spread, key: 124)?.entryID, "right-low")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: spread[2], in: spread, key: 123)?.entryID, "left-low")
        // 右半页末尾向右返回 nil，由外层提示读完或继续加载
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: spread[2], in: spread, key: 124))
    }

    func testSpatialNavigationStopsAtPageTopAndBottomWithoutPaging() {
        let column = [
            MagazinePlacement(entryID: "first", frame: CGRect(x: 0, y: 0, width: 300, height: 120), style: .init()),
            MagazinePlacement(entryID: "second", frame: CGRect(x: 0, y: 160, width: 300, height: 120), style: .init()),
            MagazinePlacement(entryID: "last", frame: CGRect(x: 0, y: 320, width: 300, height: 120), style: .init())
        ]
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: column[0], in: column, key: 125)?.entryID, "second")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: column[2], in: column, key: 126)?.entryID, "second")
        // 上下键只做纵向移动：到达页底/页顶即停，不换行到下一篇、也不翻页
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: column[2], in: column, key: 125))
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: column[0], in: column, key: 126))
    }

    func testMagazineSpatialNavigationFollowsLeftToRightTopToBottomRule() {
        // 标准 2x2 网格测试
        let grid = [
            MagazinePlacement(entryID: "card-1", frame: CGRect(x: 0, y: 0, width: 200, height: 100), style: .init()),
            MagazinePlacement(entryID: "card-2", frame: CGRect(x: 220, y: 0, width: 200, height: 100), style: .init()),
            MagazinePlacement(entryID: "card-3", frame: CGRect(x: 0, y: 120, width: 200, height: 100), style: .init()),
            MagazinePlacement(entryID: "card-4", frame: CGRect(x: 220, y: 120, width: 200, height: 100), style: .init())
        ]
        // 向右移动：只横向；右列尽头返回 nil 交给翻页
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[0], in: grid, key: 124)?.entryID, "card-2")
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: grid[1], in: grid, key: 124))
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[2], in: grid, key: 124)?.entryID, "card-4")
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: grid[3], in: grid, key: 124))

        // 向左移动：只横向；左列尽头返回 nil 交给翻页/合上封面
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[3], in: grid, key: 123)?.entryID, "card-3")
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: grid[2], in: grid, key: 123))
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[1], in: grid, key: 123)?.entryID, "card-1")
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: grid[0], in: grid, key: 123))

        // 垂直移动：1 -> 3, 2 -> 4, 3 -> 1, 4 -> 2
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[0], in: grid, key: 125)?.entryID, "card-3")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[1], in: grid, key: 125)?.entryID, "card-4")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[2], in: grid, key: 126)?.entryID, "card-1")
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: grid[3], in: grid, key: 126)?.entryID, "card-2")

        // 宽卡片下方有两列：按下键遵循从左到右优先选中左侧卡片
        let wideTop = [
            MagazinePlacement(entryID: "banner", frame: CGRect(x: 0, y: 0, width: 440, height: 120), style: .init()),
            MagazinePlacement(entryID: "sub-left", frame: CGRect(x: 0, y: 140, width: 200, height: 100), style: .init()),
            MagazinePlacement(entryID: "sub-right", frame: CGRect(x: 220, y: 140, width: 200, height: 100), style: .init())
        ]
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: wideTop[0], in: wideTop, key: 125)?.entryID, "sub-left")
    }

    /// 还原用户截图的遥控路径：1→2→3→4→5→6→7→8→9 依次按 →、↓、↓、←、↓、↓、→、→，再从 9 按 → 翻页。
    func testRemoteControlWalkReplaysAnnotatedSpreadPath() {
        let walk = [
            MagazinePlacement(entryID: "1", frame: CGRect(x: 0, y: 0, width: 900, height: 300), style: .init()),
            MagazinePlacement(entryID: "2", frame: CGRect(x: 960, y: 10, width: 910, height: 170), style: .init()),
            MagazinePlacement(entryID: "3", frame: CGRect(x: 960, y: 200, width: 910, height: 240), style: .init()),
            MagazinePlacement(entryID: "4", frame: CGRect(x: 960, y: 460, width: 910, height: 240), style: .init()),
            MagazinePlacement(entryID: "5", frame: CGRect(x: 20, y: 330, width: 780, height: 280), style: .init()),
            MagazinePlacement(entryID: "left-extra", frame: CGRect(x: 20, y: 650, width: 490, height: 240), style: .init()),
            MagazinePlacement(entryID: "6", frame: CGRect(x: 520, y: 640, width: 280, height: 190), style: .init()),
            MagazinePlacement(entryID: "7", frame: CGRect(x: 520, y: 880, width: 280, height: 200), style: .init()),
            MagazinePlacement(entryID: "8", frame: CGRect(x: 960, y: 900, width: 320, height: 300), style: .init()),
            MagazinePlacement(entryID: "9", frame: CGRect(x: 1300, y: 900, width: 570, height: 300), style: .init())
        ]
        let keys: [UInt16] = [124, 125, 125, 123, 125, 125, 124, 124]
        var current = walk[0]
        for (index, key) in keys.enumerated() {
            guard let next = MagazineSpatialNavigation.neighbor(of: current, in: walk, key: key) else {
                XCTFail("第 \(index + 1) 步按键 \(key) 不应到达页边：\(current.entryID)")
                return
            }
            current = next
            XCTAssertEqual(current.entryID, "\(index + 2)", "第 \(index + 1) 步按键 \(key) 的落点不正确")
        }
        XCTAssertNil(MagazineSpatialNavigation.neighbor(of: current, in: walk, key: 124), "9 向右应交给外层翻到下一页")
        // 同一行里 6 向左落到左侧邻栏，说明横向只按几何就近选择
        XCTAssertEqual(MagazineSpatialNavigation.neighbor(of: walk[6], in: walk, key: 123)?.entryID, "left-extra")
    }

    func testKeyboardNavigationTerminatesAtPageEdgesOnRealPaginatorPages() {
        // 遥控器式移动每一步都朝按键方向前进，有限步内必然停在页边（返回 nil），不会折返到已访问卡片。
        let entries = editorialEntries(43, images: true)
        let sizes = [CGSize(width: 1450, height: 1000), CGSize(width: 1250, height: 900),
                     CGSize(width: 900, height: 900), CGSize(width: 480, height: 800)]
        for arrangement in MagazineArrangement.allCases {
            for size in sizes {
                let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: arrangement,
                    size: size, showsImages: true)
                for (pageIndex, page) in pages.enumerated() {
                    for start in page.placements {
                        for key in [UInt16(123), 124, 125, 126] {
                            var visited: Set<String> = [start.entryID]
                            var current = start
                            var steps = 0
                            while let next = MagazineSpatialNavigation.neighbor(of: current, in: page.placements, key: key) {
                                XCTAssertTrue(visited.insert(next.entryID).inserted,
                                    "\(arrangement) \(size) 第 \(pageIndex) 页 key \(key) 折返到已访问卡片")
                                current = next
                                steps += 1
                                guard steps <= page.placements.count else {
                                    XCTFail("\(arrangement) \(size) 第 \(pageIndex) 页 key \(key) 未在有限步内到达页边")
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension MagazinePerformanceTests {
    func testCompositionIsDeterministicAcrossWindowsAndImagePolicies() {
        let entries = editorialEntries(65, images: true)
        for size in [CGSize(width: 400, height: 400), CGSize(width: 900, height: 900), CGSize(width: 1450, height: 1100)] {
            for images in [false, true] {
                let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced, size: size, showsImages: images)
                let again = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced, size: size, showsImages: images)
                XCTAssertEqual(pages, again)
                XCTAssertEqual(pages.flatMap(\.readingOrder), entries.map(\.id))
                XCTAssertTrue(pages.allSatisfy { $0.consumedCount > 0 })
                if !images { XCTAssertTrue(pages.flatMap(\.placements).allSatisfy { $0.style.imageHeight == 0 }) }
                assertEditorialGeometry(pages)
            }
        }
    }
}


extension MagazinePerformanceTests {
    func testBriefHeightDoesNotGrowWithViewport() {
        let entries = editorialEntries(30)
        var heights: [CGFloat] = []
        for h: CGFloat in [850, 1000, 1400] {
            let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
                size: CGSize(width: 1450, height: h), showsImages: false, hasMore: true)
            heights.append(pages[0].placements[0].frame.height)
            assertEditorialGeometry(pages)
        }
        XCTAssertEqual(Set(heights).count, 1)
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

    func testRailPreviewUsesCustomFloatingScrollViewRatherThanNativeScrollIndicators() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let railSource = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/MagazinePageRail.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(railSource.contains("PaperFloatingScrollView"), "预览溢出滚动必须使用系统统一的自定义细条滚动容器")
        XCTAssertFalse(railSource.contains(".scrollIndicators(.automatic)"), "不得使用系统默认原生粗滚动条")

        let scrollbarSource = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/PaperFloatingScrollbarView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(scrollbarSource.contains("struct PaperFloatingScrollView"), "必须提供通用的 PaperFloatingScrollView 容器")
    }

    func testMagazineScrollWheelTurnsPages() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = MagazineInputRegion.Surface(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = surface
        defer { surface.stop(); window.close() }

        var turnDirections: [Int] = []
        let input = MagazineInputRegion(active: true, articleFrames: [], onArticleDown: { _ in },
            onTurn: { turnDirections.append($0) }, onClear: {}, onEdge: { _ in }, onSwipe: { _, _, _, _ in })
        surface.input = input

        guard let cgDown = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0) else {
            XCTFail("无法创建 CGEvent")
            return
        }
        cgDown.timestamp = 1_000_000_000
        cgDown.location = window.convertPoint(toScreen: NSPoint(x: 450, y: 350))
        let eventDown = try XCTUnwrap(NSEvent(cgEvent: cgDown))

        let handledDown = surface.handle(eventDown)
        XCTAssertNil(handledDown, "向下滚动应被消费并触发翻页")
        XCTAssertEqual(turnDirections, [1], "向下滚动滚轮应翻到下一页")

        guard let cgUp = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0) else {
            XCTFail("无法创建 CGEvent")
            return
        }
        cgUp.timestamp = 1_500_000_000
        cgUp.location = window.convertPoint(toScreen: NSPoint(x: 450, y: 350))
        let eventUp = try XCTUnwrap(NSEvent(cgEvent: cgUp))

        let handledUp = surface.handle(eventUp)
        XCTAssertNil(handledUp, "向上滚动应被消费并触发翻页")
        XCTAssertEqual(turnDirections, [1, -1], "向上滚动滚轮应翻到上一页")
    }

    func testMagazineSoundPlaysOnlyOnBookOpenAndNotOnSubsequentPageTurns() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let browserSource = try String(
            contentsOf: root.appendingPathComponent("PaperRss/Sources/App/MagazineBrowserView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(browserSource.contains("if pageSoundEnabled { MagazinePageSound.play() }"), "开书合页到开页时必须触发音效")
        XCTAssertTrue(browserSource.contains("playsSound: false"), "开书之后的翻页切换页面必须保持静音 (playsSound: false)")
    }
}

extension MagazinePerformanceTests {
    private func editorialEntries(_ count: Int, images: Bool = false) -> [EntryListItem] {
        let feed = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        return (0..<count).map { index in
            EntryListItem(id: "edition-\(index)", feedID: feed, title: "第 \(index) 篇文章的标题",
                summaryPreview: images ? "保留来源摘要，图文一起决定文章的自然高度。" : "", sourceTitle: "测试订阅",
                previewImageURL: images ? URL(string: "https://example.com/\(index).png") : nil)
        }
    }
    private func assertEditorialGeometry(_ pages: [MagazinePageLayout], file: StaticString = #filePath, line: UInt = #line) {
        for page in pages {
            XCTAssertEqual(page.readingOrder, page.page.entries.map(\.id), file: file, line: line)
            for (index, placement) in page.placements.enumerated() {
                let entry = page.page.entries.first { $0.id == placement.entryID }!
                XCTAssertEqual(placement.frame.height, placement.style.height(for: entry, width: placement.frame.width), accuracy: 0.01, file: file, line: line)
                XCTAssertLessThanOrEqual(placement.frame.maxY, page.height + 0.01, file: file, line: line)
                XCTAssertLessThanOrEqual(placement.frame.maxX, page.contentWidth + 0.01, file: file, line: line)
                for other in page.placements.dropFirst(index + 1) {
                    XCTAssertFalse(placement.frame.intersects(other.frame), file: file, line: line)
                }
            }
        }
    }
    func testEndingRequiresKnownEndAndPreservesSpreadLayout() {
        for count in [1, 2, 3] {
            let entries = editorialEntries(count, images: count == 2)
            // 宽屏对开模式：保持双页布局，文章排在左叶，右叶预留给封底底图
            let final = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
                size: CGSize(width: 1450, height: 1200), showsImages: true)
            XCTAssertEqual(final.count, 1)
            XCTAssertEqual(final[0].template, .ending)
            XCTAssertEqual(final[0].form, .spread, "宽屏对开模式下最后一页必须保留双页布局，不得退化为单页")
            XCTAssertGreaterThan(final[0].paperWidth, 1000)
            XCTAssertTrue(final[0].isEnd)
            let leafWidth = (final[0].contentWidth - MagazinePaginator.gutter) / 2
            XCTAssertTrue(final[0].placements.allSatisfy { $0.frame.maxX <= leafWidth + 1 }, "不足双页的文章全部排在左叶")
            let expectedHeight = max(1, 1200 - MagazinePaginator.railHeight - MagazinePaginator.headingHeight)
            XCTAssertEqual(final[0].height, expectedHeight, "最后一页必须保持正常的杂志页面高度，不得截断")

            // 单页视口模式：正常保持单页布局
            let singleFinal = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
                size: CGSize(width: 800, height: 1000), showsImages: true)
            XCTAssertEqual(singleFinal.count, 1)
            XCTAssertEqual(singleFinal[0].form, .single)
            let expectedSingleHeight = max(1, 1000 - MagazinePaginator.railHeight - MagazinePaginator.headingHeight)
            XCTAssertEqual(singleFinal[0].height, expectedSingleHeight, "单页模式下最后一页也必须保持正常的杂志页面高度")

            let loading = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
                size: CGSize(width: 1450, height: 1200), showsImages: true, hasMore: true)
            XCTAssertFalse(loading.last!.isEnd)
            XCTAssertNotEqual(loading.last!.template, .ending)
        }
    }
    func testUnseenTailRepacksButDisplayedPrefixKeepsGeometry() {
        let cache = MagazineEditionCache()
        var input = MagazineEditionCache.Input(entries: editorialEntries(31), folders: [:], arrangement: .balanced,
            capacity: 12, locale: "zh", viewport: CGSize(width: 1450, height: 900), showsImages: false, hasMore: true)
        cache.update(input)
        let first = cache.pages[0]
        cache.markDisplayed(first.id)
        let original = cache.layouts[first.id]
        input = .init(entries: editorialEntries(45), folders: [:], arrangement: .balanced, capacity: 12, locale: "zh",
            viewport: input.viewport, showsImages: false, hasMore: false)
        cache.update(input)
        XCTAssertEqual(cache.layouts[first.id]?.placements, original?.placements)
        XCTAssertEqual(cache.pages.flatMap(\.entries).map(\.id), input.entries.map(\.id))
        XCTAssertTrue(cache.layouts[cache.pages.last!.id]!.isEnd)
        let rebuilt = MagazinePaginator.pages(entries: Array(input.entries.dropFirst(first.entries.count)), folders: [:],
            arrangement: .balanced, size: input.viewport!, showsImages: false)
        XCTAssertEqual(cache.pages.dropFirst().map { $0.entries.map(\.id) }, rebuilt.map { $0.readingOrder })
    }
    func testLargeTextAndLowWindowUseUnrestrictedFlow() {
        let entry = EntryListItem(id: "long", feedID: UUID(), title: String(repeating: "标题 👩‍💻 https://example.com/long ", count: 80),
            summaryPreview: "全文入口保持不变。", sourceTitle: String(repeating: "超长来源", count: 20))
        for (size, scale) in [(CGSize(width: 500, height: 900), CGFloat(1)),
                              (CGSize(width: 1450, height: 500), CGFloat(1)),
                              (CGSize(width: 1450, height: 1000), CGFloat(1.5))] {
            let pages = MagazinePaginator.pages(entries: [entry], folders: [:], arrangement: .balanced,
                size: size, showsImages: false, textScale: scale)
            XCTAssertEqual(pages[0].form, .flow)
            XCTAssertEqual(pages[0].placements[0].style.titleLines, 10000)
            assertEditorialGeometry(pages)
        }
    }
    func testMeasurementCacheSeparatesTypographyAndReusesReadChanges() {
        let cache = MagazineMeasurementCache()
        var entry = editorialEntries(1)[0]
        let style = MagazineStoryStyle()
        let first = cache.height(entry, style: style, width: 400)
        entry.isRead = true; entry.isStarred = true
        XCTAssertEqual(cache.height(entry, style: style, width: 400), first)
        XCTAssertEqual(cache.hitCount, 1)
        var large = style; large.textScale = 1.5
        XCTAssertGreaterThan(cache.height(entry, style: large, width: 400), first)
        _ = cache.height(entry, style: style, width: 220)
        XCTAssertEqual(cache.count, 3)
    }
    func testCancelledCompositionCannotPublishStaleScope() async {
        let cache = MagazineEditionCache()
        let large = MagazineEditionCache.Input(entries: editorialEntries(1000), folders: [:], arrangement: .balanced,
            capacity: 12, locale: "zh", viewport: CGSize(width: 1450, height: 900))
        let task = Task { await cache.updateAsync(large) }
        await Task.yield()
        task.cancel()
        cache.update(.init(entries: [], folders: [:], arrangement: .balanced, capacity: 12, locale: "zh", scopeID: UUID()))
        await task.value
        XCTAssertTrue(cache.pages.isEmpty)
    }

    func testSynchronousCompositionIgnoresAmbientTaskCancellation() async {
        let cache = MagazineEditionCache()
        let input = MagazineEditionCache.Input(entries: editorialEntries(40), folders: [:], arrangement: .balanced,
            capacity: 12, locale: "zh", viewport: CGSize(width: 1450, height: 1000), showsImages: false)
        // 同步 update 可能被子视图事务落在已取消的宿主任务里；此时仍必须产出
        // 有文章的版面，否则会误显示“暂无文章”，直到下一次输入变化才恢复。
        let cancelled = Task { cache.update(input) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertFalse(cache.pages.isEmpty, "同步排版不得被宿主任务的取消状态误伤")
        XCTAssertEqual(cache.pages.flatMap { $0.entries.map(\.id) }, input.entries.map(\.id))
    }
}

extension MagazinePerformanceTests {
    func testNativeTextFitsMeasuredModuleBudget() {
        let store = ArticleThumbnailStore()
        let texts = ["短讯", String(repeating: "中英文混排 SwiftUI 👩‍💻 ", count: 8),
                     "https://example.com/" + String(repeating: "verylongunbrokenurl", count: 12)]
        for width: CGFloat in [220, 480, 656] {
            for title in texts {
                let entry = EntryListItem(id: title, feedID: UUID(), title: title,
                    summaryPreview: "来源摘要必须跟随标题，保留正常行距。", sourceTitle: "来源与日期")
                for role in [MagazineStoryStyle.Role.lead, .supporting, .list] {
                    let style = MagazineStoryStyle(role: role, titleSize: role == .lead ? 34 : (role == .list ? 19 : 24))
                    let host = NSHostingView(rootView: MagazineStoryView(entry: entry, style: style, width: width, selected: false, store: store))
                    let nativeHeight = host.fittingSize.height
                    XCTAssertLessThanOrEqual(nativeHeight, style.height(for: entry, width: width) + 1,
                        "实际 SwiftUI 文字高度不能超出测量预算，宽度 \(width)，角色 \(role)")
                }
            }
        }
    }
}

extension MagazinePerformanceTests {
    func testCompleteTextSpreadUsesAlignedRowsWithNaturalStoryHeights() {
        // 已知末页会收成左叶 + 封底；这里保留还可加载更多内容的前提，验证正常跨叶编排。
        let entries = editorialEntries(20)
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1000), showsImages: false, hasMore: true)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].form, .spread)
        XCTAssertEqual(pages[0].consumedCount, 20)
        let lanes = Dictionary(grouping: pages[0].placements, by: { $0.frame.minX })
        XCTAssertEqual(lanes.count, 4, "每叶两小栏")
        XCTAssertTrue(pages[0].placements.allSatisfy { $0.style.role == .gallery })
        XCTAssertTrue(pages[0].placements.allSatisfy { $0.frame.width < pages[0].contentWidth / 3 })
        // 两叶各自连续续排，高度接近；不再要求跨叶逐行共享起点。
        let leaf = (pages[0].contentWidth - MagazinePaginator.gutter) / 2
        func leafBottom(_ x: CGFloat) -> CGFloat {
            pages[0].placements.filter { $0.frame.minX >= x && $0.frame.minX < x + leaf }
                .map(\.frame.maxY).max() ?? 0
        }
        let leftBottom = leafBottom(0)
        let rightBottom = leafBottom(leaf + MagazinePaginator.gutter)
        XCTAssertGreaterThan(leftBottom, 0)
        XCTAssertGreaterThan(rightBottom, 0)
        XCTAssertLessThan(abs(leftBottom - rightBottom), pages[0].height * 0.35, "两叶高度接近，不偏科")
        for placement in pages[0].placements {
            let entry = entries.first { $0.id == placement.entryID }!
            XCTAssertEqual(placement.frame.height, placement.style.height(for: entry, width: placement.frame.width))
        }
        assertEditorialGeometry(pages)
    }

    func testImageLeadCreatesHierarchyWithAlignedSmallerImages() {
        let entries = Array(editorialEntries(37, images: true).dropFirst())
        let page = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1200), showsImages: true, hasMore: true)[0]
        let lead = page.placements[0]
        let supporting = page.placements.filter { $0.style.role == .supporting }
        let panels = page.placements.filter { $0.style.role == .gallery }
        XCTAssertEqual(lead.style.role, .lead)
        XCTAssertGreaterThan(lead.style.imageHeight, 180)
        XCTAssertFalse(supporting.isEmpty)
        XCTAssertTrue(supporting.allSatisfy { $0.frame.minX > lead.frame.maxX })
        XCTAssertFalse(panels.isEmpty)
        XCTAssertGreaterThan(Set(page.placements.map { $0.frame.width }).count, 1)
        XCTAssertTrue(panels.allSatisfy { $0.style.imageHeight < lead.style.imageHeight }, "同类短图文保持一致尺度，主图仍最突出")
        XCTAssertEqual(page.readingOrder, Array(entries.prefix(page.consumedCount)).map(\.id))
        assertEditorialGeometry([page])
    }
}

extension MagazinePerformanceTests {
    func testVariedBriefsPreferFourColumnsOverTwoFullWidthLists() {
        let titles = ["设计一份可以自然延伸的阅读版面", "SwiftUI 图文混排：保持文章顺序，给文字合适的空间",
                      "没有配图的推文也能紧凑排列", "Short notes deserve a natural reading rhythm"]
        let entries = (0..<40).map { index in
            EntryListItem(id: "varied-\(index)", feedID: UUID(), title: titles[index % titles.count], sourceTitle: "纯文字短讯")
        }
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1100), showsImages: false, hasMore: true)
        let first = pages[0]
        XCTAssertEqual(Set(first.placements.map { $0.frame.minX }).count, 4)
        XCTAssertTrue(first.placements.allSatisfy { $0.frame.width < first.contentWidth / 3 })
        XCTAssertEqual(pages.flatMap(\.readingOrder), entries.map(\.id))
        assertEditorialGeometry(pages)
    }

    func testAlternatingLongAndShortStoriesFillLeavesWithVisibleImages() {
        let feed = UUID()
        let entries = (0..<40).map { index in
            EntryListItem(id: "rhythm-\(index)", feedID: feed,
                title: index.isMultiple(of: 5) ? "从文字到图像：观察日常生活中的设计细节" : "第 \(index) 条编辑短讯",
                summaryPreview: index.isMultiple(of: 5) ? String(repeating: "图片与正文保持关联，以适当行距呈现真实内容。", count: 5) : "简短的内容摘要。",
                sourceTitle: "设计观察", previewImageURL: index.isMultiple(of: 5) ? URL(string: "https://example.com/\(index).jpg") : nil)
        }
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1100), showsImages: true, hasMore: true)
        XCTAssertEqual(pages.flatMap(\.readingOrder), entries.map(\.id))
        assertEditorialGeometry(pages)
        for page in pages {
            // 图片必须始终可见；每叶不再要求跨叶共享起点，但都要尽量填满页面。
            let images = page.placements.filter { $0.style.imageHeight > 0 }
            XCTAssertFalse(images.isEmpty, "含图稿件的页面必须保留图片")
            let bottom = page.placements.map(\.frame.maxY).max() ?? 0
            XCTAssertGreaterThan(bottom, page.height * 0.75, "内容吃紧时也要把页面填满，而不是在页首堆完后留白")
        }
    }

    func testLeftLeafContinuesBelowLeadInsteadOfLeavingHalfPageBlank() {
        // 图三 05 页场景：无图文字稿与整栏大图稿相邻时，矮的一叶必须继续接稿。
        let feed = UUID()
        var entries: [EntryListItem] = [
            EntryListItem(id: "lead-text", feedID: feed, title: "体验碎周报第 272 期（2026.3.16）",
                summaryPreview: String(repeating: "系统的知识来源于对碎片的整理和思考。", count: 4), sourceTitle: "龙爪槐守望者"),
            EntryListItem(id: "panel", feedID: feed, title: "体验碎周报第283期(2026.6.15)",
                summaryPreview: String(repeating: "系统的知识来源于对碎片的整理和思考。", count: 3),
                sourceTitle: "龙爪槐守望者", previewImageURL: URL(string: "https://example.com/panel.png"))
        ]
        for index in 2..<30 {
            entries.append(EntryListItem(id: "brief-\(index)", feedID: feed,
                title: "体验碎周报第 \(240 + index) 期（2026.4.\(index)）",
                summaryPreview: "系统的知识来源于对碎片的整理和思考。", sourceTitle: "龙爪槐守望者"))
        }
        let page = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1250), showsImages: true, hasMore: true)[0]
        let leaf = (page.contentWidth - MagazinePaginator.gutter) / 2
        func bottom(_ x: CGFloat) -> CGFloat {
            page.placements.filter { $0.frame.minX >= x && $0.frame.minX < x + leaf }
                .map(\.frame.maxY).max() ?? 0
        }
        XCTAssertGreaterThan(bottom(0), page.height * 0.8, "矮的一叶要继续向下接稿，而不是留半页空洞")
        XCTAssertGreaterThan(bottom(leaf + MagazinePaginator.gutter), page.height * 0.8)
        assertEditorialGeometry([page])
    }

    func testLeafTailGrowthFillsPageBottomAndSkipsRowSiblings() {
        var style = MagazineStoryStyle(role: .gallery, titleSize: 22, titleLines: 3, summaryLines: 3, summarySize: 14)
        style.imageHeight = 200
        let lone = MagazinePlacement(entryID: "lone", frame: CGRect(x: 0, y: 0, width: 400, height: 300), style: style)
        let flushed = MagazinePaginator.flushLeafTails([lone], leafWidth: 400, gutter: 40, height: 700, spread: true)
        XCTAssertEqual(flushed.count, 1)
        XCTAssertGreaterThan(flushed[0].style.imageHeight, 200, "末张竖排图应增高填满叶底")
        XCTAssertLessThanOrEqual(flushed[0].style.imageHeight, 400, "增长以方形为上限，不拉伸成竖图")
        XCTAssertEqual(flushed[0].frame.maxY, 500, accuracy: 0.01)
        XCTAssertEqual(flushed[0].frame.height, 300 + (flushed[0].style.imageHeight - 200), accuracy: 0.01)

        // 并列双稿共享行高，不能只拉长其中一张。
        let left = MagazinePlacement(entryID: "left", frame: CGRect(x: 0, y: 0, width: 180, height: 300), style: style)
        let right = MagazinePlacement(entryID: "right", frame: CGRect(x: 220, y: 0, width: 180, height: 260), style: style)
        let unchanged = MagazinePaginator.flushLeafTails([left, right], leafWidth: 400, gutter: 40, height: 700, spread: true)
        XCTAssertEqual(unchanged.map(\.style.imageHeight), [200, 200])

        // 小余量不触发拉伸，避免无意义的裁切。
        let tiny = MagazinePlacement(entryID: "tiny", frame: CGRect(x: 0, y: 0, width: 400, height: 690), style: style)
        XCTAssertEqual(MagazinePaginator.flushLeafTails([tiny], leafWidth: 400, gutter: 40, height: 700, spread: true).map(\.style.imageHeight), [200])
    }

    func testEditorialGroupsDoNotCollapseTitlesToFitOneMoreStory() {
        let entries = editorialEntries(36, images: true)
        for height: CGFloat in [850, 1000, 1200] {
            let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
                size: CGSize(width: 1450, height: height), showsImages: true, hasMore: true)
            for placement in pages.flatMap(\.placements) where placement.style.role == .gallery {
                XCTAssertGreaterThanOrEqual(placement.style.titleLines, 3)
                XCTAssertEqual(placement.style.contentInset, 0, "所有稿件共用栏边，不叠加卡片内边距")
            }
            assertEditorialGeometry(pages)
        }
    }
}


extension MagazinePerformanceTests {
    func testFeatureSpreadKeepsMainStoryEntirelyOnLeftLeafAndVariesStably() {
        let entries = (0..<35).map { index in
            EntryListItem(id: "feature-\(index)", feedID: UUID(), title: "城市与建筑：第 \(index) 份深度观察",
                summaryPreview: String(repeating: "图像、文字和生活空间共同构成这一期的专题。", count: 12),
                sourceTitle: "专题", previewImageURL: URL(string: "https://example.com/\(index).jpg"))
        }
        let size = CGSize(width: 1450, height: 1200)
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: size, showsImages: true, hasMore: true)
        XCTAssertEqual(pages.first?.template, .feature)
        XCTAssertEqual(pages, MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: size, showsImages: true, hasMore: true))
        for (index, page) in pages.enumerated() where page.template == .feature {
            let lead = page.placements[0]
            XCTAssertEqual(lead.frame.height, page.height, accuracy: 1)
            XCTAssertGreaterThan(lead.style.imageHeight, page.height * 0.5)
            XCTAssertLessThan(lead.frame.maxX, page.contentWidth / 2)
            XCTAssertTrue(page.placements.dropFirst().allSatisfy { $0.frame.minX > page.contentWidth / 2 })
            if index > 0 { XCTAssertNotEqual(pages[index - 1].template, .feature) }
        }
        XCTAssertEqual(pages.flatMap(\.readingOrder), entries.map(\.id))
        assertEditorialGeometry(pages)
    }

    func testFeatureRequiresImageAndEnoughCompanionContent() {
        let first = EntryListItem(id: "starred-main", feedID: UUID(), title: "一篇值得仔细阅读的专题", sourceTitle: "专题",
            isStarred: true, previewImageURL: URL(string: "https://example.com/main.jpg"))
        let entries = [first] + editorialEntries(30, images: true)
        let size = CGSize(width: 1450, height: 1100)
        XCTAssertEqual(MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: size, showsImages: true, hasMore: true)[0].template, .feature)
        XCTAssertFalse(MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: size, showsImages: false).contains { $0.template == .feature })
        XCTAssertFalse(MagazinePaginator.pages(entries: Array(entries.prefix(3)), folders: [:], arrangement: .balanced,
            size: size, showsImages: true, hasMore: true).contains { $0.template == .feature })
    }

    func testFeatureSpreadActivatesOnMacBookViewportSizes() {
        let first = EntryListItem(id: "macbook-starred", feedID: UUID(), title: "MacBook 适配专题报道", sourceTitle: "深度",
            isStarred: true, previewImageURL: URL(string: "https://example.com/macbook.jpg"))
        let entries = [first] + editorialEntries(20, images: true)

        let macBookSizes = [
            CGSize(width: 1200, height: 750),
            CGSize(width: 1100, height: 680),
            CGSize(width: 1000, height: 720)
        ]

        for size in macBookSizes {
            let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
                size: size, showsImages: true, hasMore: true)
            guard let firstPage = pages.first else {
                XCTFail("MacBook 尺寸下必须能够生成页面: \(size)")
                continue
            }
            XCTAssertEqual(firstPage.template, .feature, "在 MacBook 视口 \(size) 下应当成功激活 .feature 整叶大图排版")
            XCTAssertEqual(firstPage.form, .spread, "版心宽度满足要求时必须维持双页对开模式")
            let lead = firstPage.placements[0]
            XCTAssertEqual(lead.entryID, first.id)
            XCTAssertGreaterThanOrEqual(lead.style.imageHeight, firstPage.height * 0.48)
            XCTAssertLessThan(lead.frame.maxX, firstPage.contentWidth / 2)
            XCTAssertTrue(firstPage.placements.dropFirst().allSatisfy { $0.frame.minX > firstPage.contentWidth / 2 })
            assertEditorialGeometry(pages)
        }
    }

    func testImageFramesUseUniformGalleryRatioAndTextMatchedSideHeight() {
        let entries = Array(editorialEntries(40, images: true).dropFirst())
        let page = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: CGSize(width: 1450, height: 1200), showsImages: true, hasMore: true)[0]
        for p in page.placements where p.style.imageHeight > 0 {
            if p.style.imageBesideText {
                let entry = entries.first { $0.id == p.entryID }!
                XCTAssertEqual(p.style.imageHeight, ceil(p.style.textHeight(for: entry, width: p.frame.width)), accuracy: 1)
                XCTAssertLessThanOrEqual(p.style.imageWidth(in: p.frame.width), p.frame.width * 0.32)
                if p.style.role == .supporting { XCTAssertGreaterThan(p.style.imageWidth(in: p.frame.width), 140) }
            } else if p.style.role == .gallery {
                XCTAssertEqual(p.style.imageWidth(in: p.frame.width) / p.style.imageHeight, 1.85, accuracy: 0.01)
            }
        }
    }

    func testSideImageAndSelectionKeepNativeContentWithinMeasuredBudget() {
        let entry = EntryListItem(id: "native-side", feedID: UUID(), title: "长标题与旁图共同参与宽度测量，不侵入旁边的图像区域",
            summaryPreview: "图像和文字共享自然高度，悬停与选中底色不挤动正文。", sourceTitle: "测试")
        let style = MagazineStoryStyle(role: .supporting, titleSize: 19, titleLines: 3,
            imageHeight: 112, imageBesideText: true)
        let store = ArticleThumbnailStore()
        let idle = NSHostingView(rootView: MagazineStoryView(entry: entry, style: style, width: 588, selected: false, store: store))
        let selected = NSHostingView(rootView: MagazineStoryView(entry: entry, style: style, width: 588, selected: true, store: store))
        XCTAssertEqual(idle.fittingSize, selected.fittingSize)
        XCTAssertLessThanOrEqual(idle.fittingSize.height, style.height(for: entry, width: 588))
    }
}


extension MagazinePerformanceTests {
    func testLongSideStoryImageGrowsWithTextWithoutTakingMoreWidth() {
        let short = EntryListItem(id: "short-side", feedID: UUID(), title: "短标题", sourceTitle: "来源")
        let long = EntryListItem(id: "long-side", feedID: UUID(), title: String(repeating: "you see these numbers. we are in the numbers business. ", count: 4),
            summaryPreview: "图片高度必须匹配正文，不能在长段落旁边只留下一张矮图。", sourceTitle: "来源")
        let base = MagazineStoryStyle(role: .supporting, titleSize: 19, titleLines: 3, imageHeight: 112, imageBesideText: true)
        let a = base.matchingSideImage(to: short, width: 588)
        let b = base.matchingSideImage(to: long, width: 588)
        XCTAssertEqual(a.imageWidth(in: 588), b.imageWidth(in: 588))
        XCTAssertGreaterThan(b.imageHeight, a.imageHeight + 40)
        XCTAssertEqual(b.imageHeight, ceil(b.textHeight(for: long, width: 588)))
        XCTAssertEqual(b, b.matchingSideImage(to: long, width: 588), "重复排版不改变宽高")
    }

    func testSideStoryMetadataAlignsToImageBottomAndHarmoniousSpacing() {
        let entry = EntryListItem(id: "numbers-business", feedID: UUID(),
            title: "you see these numbers. we've got the biggest numbers. we're in the numbers business. make the numbers go bigger. it's that easy. for us.",
            summaryPreview: "you see these numbers. we've got the biggest numbers. we're in the...",
            sourceTitle: "Twitter @dax")
        let baseStyle = MagazineStoryStyle(role: .supporting, titleSize: 19, titleLines: 4,
            imageHeight: 112, imageBesideText: true)
        let matched = baseStyle.matchingSideImage(to: entry, width: 588)
        let store = ArticleThumbnailStore()
        let view = MagazineStoryView(entry: entry, style: matched, width: 588, selected: false, store: store)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        XCTAssertEqual(size.height, matched.imageHeight, accuracy: 2.0,
            "图文并排时整块卡片高度必须与图片高度精确对齐，底端来源时间与图片下端对齐")

        // 当图片高度大于紧凑文字时，文字卡片必须拉伸至与图片高度一致
        var tallImageStyle = baseStyle
        tallImageStyle.imageHeight = 220
        let tallView = MagazineStoryView(entry: entry, style: tallImageStyle, width: 588, selected: false, store: store)
        let tallHost = NSHostingView(rootView: tallView)
        XCTAssertEqual(tallHost.fittingSize.height, 220, accuracy: 2.0,
            "当图片比文字高时，来源时间应推到图片下端并保持整体等高")
    }
}
