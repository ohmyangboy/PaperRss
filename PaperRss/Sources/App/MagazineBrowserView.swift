import SwiftUI
import QuartzCore
#if SWIFT_PACKAGE
import PaperRssCore
#endif

enum MagazinePaperStyle: String, CaseIterable {
    case paper, white, book

    var title: String {
        switch self {
        case .paper: "Paper"
        case .white: "White"
        case .book: "Book"
        }
    }
}

/// 小尺寸纹理只生成一次并平铺，避免每页和每帧重复绘制随机颗粒。
private enum MagazineBookGrain {
    static let image: NSImage = {
        let side = 192
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x72A1_44EF
        for pixel in 0..<(side * side) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let alpha = UInt8((seed >> 27) + 2)
            let offset = pixel * 4
            pixels[offset] = alpha / 2
            pixels[offset + 1] = alpha / 3
            pixels[offset + 2] = alpha / 5
            pixels[offset + 3] = alpha
        }
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: image, size: NSSize(width: side / 2, height: side / 2))
    }()
}

private struct MagazineColumnSpan: LayoutValueKey { static let defaultValue = 1 }

/// A measured masonry layout: the next story always uses the lowest available
/// column. Unlike LazyVGrid, a short note never inherits a neighbour's height.
struct MagazineMasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat = 20

    static func frames(width: CGFloat, columns: Int, spacing: CGFloat,
                       heights: [CGFloat], spans: [Int]) -> [CGRect] {
        let count = max(1, columns)
        let columnWidth = max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var bottoms = Array(repeating: CGFloat.zero, count: count)
        return heights.enumerated().map { index, height in
            let span = min(count, max(1, index < spans.count ? spans[index] : 1))
            let start = (0...(count - span)).min {
                let lhs = bottoms[$0..<($0 + span)].max() ?? 0
                let rhs = bottoms[$1..<($1 + span)].max() ?? 0
                return lhs == rhs ? $0 < $1 : lhs < rhs
            } ?? 0
            let top = bottoms[start..<(start + span)].max() ?? 0
            let rect = CGRect(x: CGFloat(start) * (columnWidth + spacing), y: top,
                              width: columnWidth * CGFloat(span) + spacing * CGFloat(span - 1),
                              height: max(0, height))
            for column in start..<(start + span) { bottoms[column] = rect.maxY + spacing }
            return rect
        }
    }

    struct Cache {
        var width: CGFloat?
        var columns = 0
        var spacing: CGFloat = 0
        var rects: [CGRect] = []
        mutating func resolve(width: CGFloat, columns: Int, spacing: CGFloat, count: Int,
                              measure: () -> [CGRect]) -> [CGRect] {
            if self.width == width, self.columns == columns, self.spacing == spacing,
               rects.count == count { return rects }
            let measured = measure()
            self = Cache(width: width, columns: columns, spacing: spacing, rects: measured)
            return measured
        }
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func frames(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGRect] {
        cache.resolve(width: width, columns: columns, spacing: spacing, count: subviews.count) {
            let count = max(1, columns)
            let columnWidth = max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
            let spans = subviews.map { min(count, max(1, $0[MagazineColumnSpan.self])) }
            let heights = subviews.enumerated().map { index, view in
                view.sizeThatFits(ProposedViewSize(width: columnWidth * CGFloat(spans[index])
                    + spacing * CGFloat(spans[index] - 1), height: nil)).height
            }
            return Self.frames(width: width, columns: count, spacing: spacing, heights: heights, spans: spans)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: width, height: frames(width: width, subviews: subviews, cache: &cache).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for (index, rect) in frames(width: bounds.width, subviews: subviews, cache: &cache).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

/// 已展示页冻结几何，未展示尾部可合排；内容计算在后台执行并校验版本。
@MainActor
final class MagazineEditionCache: ObservableObject {
    struct Input: Equatable, Sendable {
        let entries: [EntryListItem]
        let folders: [UUID: String]
        let arrangement: MagazineArrangement
        let capacity: Int
        let locale: String
        var viewport: CGSize? = nil
        var showsImages: Bool = true
        var hasMore = false
        var textScale: CGFloat = 1
        var scopeID: UUID? = nil
        var imageRatios: [String: CGFloat] = [:]
        /// entryID → 标题/摘要译文；参与排版测量（按译文换行）但不参与
        /// 已展示页的冻结判断，避免译文到达时整本重排。
        var displayTexts: [String: TranslatedEntryText] = [:]
    }
    @Published private(set) var pages: [MagazinePage] = []
    @Published private(set) var layouts: [String: MagazinePageLayout] = [:]
    @Published private(set) var activeScopeID: UUID?
    private var input: Input?
    private var entryIndex: [String: Int] = [:]
    private var displayed = Set<String>()
    private var revision = 0
    let measurements = MagazineMeasurementCache()
    private(set) var rebuildCount = 0

    func markDisplayed(_ id: String) { displayed.insert(id) }
    func environmentChanged(_ next: Input) -> Bool {
        guard let old = input else { return true }
        return old.viewport != next.viewport || old.textScale != next.textScale || old.locale != next.locale
            || old.showsImages != next.showsImages || old.arrangement != next.arrangement || old.scopeID != next.scopeID
    }

    private func retained(for next: Input) -> [MagazinePageLayout] {
        guard let old = input, old.viewport == next.viewport, old.showsImages == next.showsImages,
              old.arrangement == next.arrangement, old.folders == next.folders, old.locale == next.locale,
              old.textScale == next.textScale, old.scopeID == next.scopeID,
              old.entries.count <= next.entries.count,
              zip(old.entries, next.entries).allSatisfy({ old, new in
                  old.id == new.id && old.title == new.title && old.summaryPreview == new.summaryPreview
                    && old.isSummaryVisible == new.isSummaryVisible && old.sourceTitle == new.sourceTitle
                    && old.feedID == new.feedID && old.accountID == new.accountID
              }) else { displayed.removeAll(); return [] }
        if old.entries.count == next.entries.count && old.hasMore == next.hasMore {
            return pages.compactMap { layouts[$0.id] }
        }
        guard let last = pages.lastIndex(where: { displayed.contains($0.id) }) else { return [] }
        return pages.prefix(last + 1).compactMap { layouts[$0.id] }
    }

    private nonisolated static func calculate(_ next: Input, retained: [MagazinePageLayout],
                                              measurements: MagazineMeasurementCache,
                                              cancelsWithTask: Bool) -> [MagazinePageLayout] {
        guard let size = next.viewport else { return [] }
        let ids = Set(retained.flatMap(\.readingOrder))
        return retained + MagazinePaginator.pages(entries: next.entries.filter { !ids.contains($0.id) },
            folders: next.folders, arrangement: next.arrangement, size: size, showsImages: next.showsImages,
            hasMore: next.hasMore, textScale: next.textScale, locale: next.locale,
            imageRatios: next.imageRatios, displayTexts: next.displayTexts,
            measurements: measurements, cancelsWithTask: cancelsWithTask)
    }

    private func publish(_ next: Input, resolved: [MagazinePageLayout]) {
        let fresh = Dictionary(next.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = resolved.enumerated().map { index, original in
            var layout = original
            layout.page = MagazinePage(id: original.page.id, title: original.page.title,
                entries: original.readingOrder.compactMap { fresh[$0] })
            layout.isEnd = !next.hasMore && index == resolved.count - 1
            return layout
        }
        let nextPages = next.viewport == nil
            ? MagazineEdition.pages(entries: next.entries, arrangement: next.arrangement,
                folders: next.folders, capacity: next.capacity)
            : updated.map(\.page)
        input = next
        if activeScopeID != next.scopeID { activeScopeID = next.scopeID }
        entryIndex.removeAll(keepingCapacity: true)
        for (index, page) in nextPages.enumerated() {
            for entry in page.entries { entryIndex[entry.id] = index }
        }
        rebuildCount += 1
        let nextLayouts = Dictionary(updated.map { ($0.page.id, $0) }, uniquingKeysWith: { first, _ in first })
        if layouts != nextLayouts { layouts = nextLayouts }
        if pages != nextPages { pages = nextPages }
    }

    func update(_ next: Input) {
        revision += 1
        guard input != next else { return }
        let saved = retained(for: next)
        // 主线程同步编排：宿主任务是否取消与本输入无关，不能被误判为空页。
        publish(next, resolved: Self.calculate(next, retained: saved, measurements: measurements,
            cancelsWithTask: false))
    }
    func updateAsync(_ next: Input) async {
        revision += 1
        let token = revision
        guard input != next else { return }
        let saved = retained(for: next)
        let cache = measurements
        let job = Task.detached(priority: .userInitiated) {
            Self.calculate(next, retained: saved, measurements: cache, cancelsWithTask: true)
        }
        let resolved = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
        guard !Task.isCancelled, revision == token else { return }
        publish(next, resolved: resolved)
    }
    func pageIndex(containing anchor: String?) -> Int { anchor.flatMap { entryIndex[$0] } ?? 0 }
    func contains(_ anchor: String?) -> Bool { anchor.flatMap { entryIndex[$0] } != nil }
    func containsScope(_ scopeID: UUID) -> Bool { input?.scopeID == scopeID }

    func openingImageRequests(scopeID: UUID, scale: CGFloat) -> [ArticleThumbnailRequest] {
        imageRequests(forPageAt: 0, scopeID: scopeID, scale: scale)
    }

    func imageRequests(forPageAt index: Int, scopeID: UUID, scale: CGFloat) -> [ArticleThumbnailRequest] {
        guard input?.scopeID == scopeID, input?.showsImages == true,
              pages.indices.contains(index),
              let layout = layouts[pages[index].id] else { return [] }
        let page = pages[index]
        let entries = Dictionary(page.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<ArticleThumbnailRequest>()
        return layout.placements.compactMap { placement in
            guard let entry = entries[placement.entryID],
                  let request = placement.style.thumbnailRequest(for: entry, width: placement.frame.width, scale: scale),
                  seen.insert(request).inserted else { return nil }
            return request
        }
    }
}

private struct MagazinePageVisibility: Equatable {
    let isAtTop: Bool
    let isVisible: Bool

    init(frame: CGRect, viewportHeight: CGFloat) {
        isAtTop = abs(frame.minY) <= 24
        isVisible = frame.maxY > 24 && frame.minY < viewportHeight
    }
}

private struct MagazinePageVisibilityKey: PreferenceKey {
    static let defaultValue: [String: MagazinePageVisibility] = [:]
    static func reduce(value: inout [String: MagazinePageVisibility], nextValue: () -> [String: MagazinePageVisibility]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct MagazineBrowserView<Tile: View>: View {
    let entries: [EntryListItem]
    let folders: [UUID: String]
    let availableSize: CGSize
    let showsImages: Bool
    let isBrowsing: Bool
    let hasMore: Bool
    var isLoading = false
    let selectedID: String?
    let keyboardRequest: TimelineKeyRequest?
    @ObservedObject var memory: TimelinePresentationMemory
    let thumbnailStore: ArticleThumbnailStore
    let onHighlight: (String) -> Void
    let onOpen: (EntryListItem) -> Void
    let onNeedMore: () -> Void
    var onFocusSidebar: () -> Void = {}
    var coverTitle: String = ""
    var onClearSelection: () -> Void = {}
    /// 当前页（含下一页预取）的条目变化回调，用于标题翻译的按需取用。
    var onVisibleEntriesChange: ([TitleTranslationCandidate]) -> Void = { _ in }
    let tile: (EntryListItem, CGFloat, TimelineTileLayout) -> Tile
    @AppStorage("magazine_arrangement") private var arrangementRaw = MagazineArrangement.balanced.rawValue
    @AppStorage("magazine_turning") private var turningRaw = MagazineTurning.fold.rawValue
    @AppStorage("magazine_paper_style") private var paperStyleRaw = MagazinePaperStyle.paper.rawValue
    @AppStorage("magazine_page_sound") private var pageSoundEnabled = true
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.entryTranslations) private var entryTranslations
    @StateObject private var edition = MagazineEditionCache()
    @State private var coverAnimating = false
    @State private var coverOpening = true
    @State private var coverSnapshots: (front: CGImage, back: CGImage, right: CGImage)?
    @State private var coverBounds: CGSize = .zero
    @State private var autoOpenedScope: UUID?
    @State private var edge: Int = 0
    @State private var notice: String?
    @State private var noticeID = UUID()
    @State private var pendingPageIndex: Int?
    @State private var turnRequest: MagazinePageTurnRequest?
    @State private var turnSourceAnchor: String?
    /// 每页最后停留的卡片：从右半页翻出再翻回时恢复到原卡片，而不是阅读顺序的末篇。
    @State private var lastSelectionByPage: [String: String] = [:]
    @State private var railScrubPosition: Double?
    @State private var railScrubSourceAnchor: String?
    @State private var railScrubActive = false
    @State private var railScrubPendingIndex: Int?
    @State private var railScrubForward: Bool?
    @State private var railScrubSessionID: UUID?
    /// 翻页快照存活期间冻结标题显示；新译文先留在上游缓存，落页后再切换。
    @State private var presentedTranslations: [String: TranslatedEntryText] = [:]
    @State private var pendingEditionInput: MagazineEditionCache.Input?
    @State private var scrollTranslationLayoutTask: Task<Void, Never>?
    @State private var scrollPositionReady = false
    @State private var observedMagazineAnchor: String?
    @State private var dragSourcePageIndex: Int?
    @State private var swipeSourcePageIndex: Int?
    @GestureState private var isDraggingPage = false
    private var isTurning: Bool { turnRequest != nil }
    private var usesCoverSurface: Bool { coverAnimating && !reduceMotion && coverSnapshots != nil }
    private var paperWidth: CGFloat { MagazinePaginator.pageWidth(availableSize.width) }
    private var turnInset: CGFloat { MagazinePaginator.turnInset(availableSize) }
    private var stageBackground: NSColor {
        NSColor(Color(paperHex: palette.backgroundHex)).blended(withFraction: palette.colorScheme == .dark ? 0.035 : 0.065,
            of: NSColor(Color(paperHex: palette.inkHex))) ?? .windowBackgroundColor
    }
    private var paperStyle: MagazinePaperStyle { .init(rawValue: paperStyleRaw) ?? .paper }
    // 杂志纸张独立于全局阅读主题；在 White 主题下仍能选回暖色 Paper。
    private var paperBackground: Color {
        switch paperStyle {
        case .white: return Color(paperHex: palette.colorScheme == .dark ? "1C1C1C" : "FFFFFF")
        case .book: return Color(paperHex: palette.colorScheme == .dark ? "2D281F" : "EFE2C8")
        case .paper: return Color(paperHex: palette.colorScheme == .dark ? "211F1A" : "F6F2E7")
        }
    }
    private var paperSheetBackground: some View {
        paperBackground.overlay {
            if paperStyle == .book {
                ZStack {
                    LinearGradient(colors: [.white.opacity(0.04), .clear, .brown.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(nsImage: MagazineBookGrain.image)
                        .resizable(resizingMode: .tile)
                }
                .accessibilityHidden(true)
            }
        }
    }
    private var contentWidth: CGFloat { MagazinePaginator.contentWidth(availableSize.width) }
    private func foldSheetBackground(showsFold: Bool) -> some View {
        paperSheetBackground.overlay {
            if showsFold {
                LinearGradient(colors: [.clear, Color(paperHex: palette.inkHex).opacity(0.035), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                    .overlay { Rectangle().fill(Color(paperHex: palette.inkHex).opacity(0.035)).frame(width: 0.5) }
            }
        }
    }

    private var arrangement: MagazineArrangement { .init(rawValue: arrangementRaw) ?? .balanced }
    private var turning: MagazineTurning { .init(rawValue: turningRaw) ?? .fold }
    private var editionInput: MagazineEditionCache.Input {
        .init(entries: entries, folders: folders, arrangement: arrangement, capacity: 12,
              locale: locale.identifier, viewport: MagazinePaginator.foldViewport(availableSize),
              showsImages: showsImages, hasMore: hasMore, scopeID: memory.magazineScopeID,
              displayTexts: presentedTranslations)
    }
    private var pages: [MagazinePage] { edition.pages }
    /// 空杂志不自动开页；内容排出版面后 id 变化会重新计时，避免在“暂无文章”时开出一本空书。
    private var autoOpenID: String {
        "\(memory.magazineScopeID.uuidString)|\(edition.activeScopeID?.uuidString ?? "pending")|\(isBrowsing)|\(isLoading)|\(pages.first?.id ?? "empty")"
    }
    private var openingImageRequests: [ArticleThumbnailRequest] {
        guard isBrowsing, showsImages else { return [] }
        return edition.openingImageRequests(scopeID: memory.magazineScopeID, scale: displayScale)
    }
    private var nextPageImageRequests: [ArticleThumbnailRequest] {
        guard isBrowsing, showsImages, memory.magazineIsOpen else { return [] }
        let nextIndex = pageIndex + 1
        guard pages.indices.contains(nextIndex) else { return [] }
        return edition.imageRequests(forPageAt: nextIndex, scopeID: memory.magazineScopeID, scale: displayScale)
    }
    private var pageIndex: Int {
        if !memory.magazineIsOpen { return 0 }
        if let request = turnRequest, let target = pages.firstIndex(where: { $0.id == request.targetPageID }) { return target }
        if let position = railScrubPosition {
            return MagazineRailScrub.nearestIndex(position: position, count: pages.count)
        }
        return edition.pageIndex(containing: observedMagazineAnchor ?? memory.magazineAnchor)
    }
    private var railPageIndex: Int {
        guard let position = railScrubPosition else { return pageIndex }
        return MagazineRailScrub.nearestIndex(position: position, count: pages.count)
    }
    private func translationsForSettledPage(_ translations: [String: TranslatedEntryText]) -> [String: TranslatedEntryText] {
        guard turning != .scroll else { return translations }
        let settledIndex = edition.pageIndex(containing: memory.magazineAnchor)
        guard pages.indices.contains(settledIndex) else { return [:] }
        // 邻页不在屏幕上，预取译文可先进入快照；翻过去便直接是译文。
        let nearby = max(0, settledIndex - 1)...min(pages.count - 1, settledIndex + 1)
        let readyIDs = Set(nearby.flatMap { pages[$0].entries.map(\.id) })
        return translations.filter { readyIDs.contains($0.key) || presentedTranslations[$0.key] != nil }
    }
    private func revealSettledTranslations() {
        let next = translationsForSettledPage(entryTranslations)
        if presentedTranslations != next { presentedTranslations = next }
    }

    var body: some View {
        ScrollViewReader { proxy in
            magazinePages(proxy: proxy)
            .environment(\.entryTranslations, presentedTranslations)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 封皮与右页快照在同一个合成器时间轴上移动；实时页面等落页后再接管。
            // 无快照时保留原有 SwiftUI 动画路径。
            .clipShape(Rectangle().offset(x: coverAnimating && !reduceMotion && !usesCoverSurface
                                              ? availableSize.width / 2 : 0))
            .offset(x: !usesCoverSurface && !memory.magazineIsOpen && !reduceMotion ? -paperWidth / 4 : 0)
            .opacity(usesCoverSurface ? 0 : (memory.magazineIsOpen ? 1 : 0))
            .allowsHitTesting(memory.magazineIsOpen && !coverAnimating)
            .accessibilityHidden(!memory.magazineIsOpen)
            .overlay {
                if pages.isEmpty && !isLoading {
                    // 没有文章时不展示可翻开的书；默认给出与列表一致的空态。
                    Text(I18N.shared.localized("暂无文章", "No articles")).foregroundStyle(.secondary)
                } else {
                    bookCover
                        .opacity(!memory.magazineIsOpen || coverAnimating ? 1 : 0)
                        .allowsHitTesting(!memory.magazineIsOpen && !coverAnimating)
                }
            }
            .overlay {
                if memory.magazineIsOpen && !pages.isEmpty && turning != .scroll && !coverAnimating {
                    HStack {
                        edgeButton(-1, proxy: proxy)
                        Spacer(minLength: 0)
                        edgeButton(1, proxy: proxy)
                    }.padding(.horizontal, max(6, (availableSize.width - paperWidth) / 2 - 42))
                }
            }
            .background {
                magazineInputOverlay(proxy: proxy)
            }
            .coordinateSpace(name: "magazine-viewport")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                pageRail(proxy: proxy)
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice).font(.system(size: 13)).padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule()).padding(.bottom, 64)
                        .allowsHitTesting(false).transition(.opacity)
                }
            }
            .task(id: noticeID) {
                guard notice != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                withAnimation(.easeOut(duration: 0.18)) { notice = nil }
            }
            .task(id: autoOpenID) {
                guard isBrowsing, !isLoading, autoOpenedScope != memory.magazineScopeID else { return }
                let scope = memory.magazineScopeID
                guard !memory.magazineIsOpen else { autoOpenedScope = scope; return }
                // 暂无文章时保持封面/空态不翻开；排版完成后 autoOpenID 变化会再走一轮。
                guard !pages.isEmpty, edition.containsScope(scope) else { return }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                guard !Task.isCancelled, scope == memory.magazineScopeID,
                      !isLoading, autoOpenedScope != scope, !pages.isEmpty,
                      edition.containsScope(scope) else { return }
                autoOpenedScope = scope
                openBook()
            }
            .task(id: openingImageRequests) {
                // 与封面计时独立运行；开页时继续共用在途请求，慢图不阻塞动画。
                // 新订阅、隐藏视图或关闭图片会取消旧订阅者，下载限流与解码沿用共享缓存。
                let requests = openingImageRequests
                let store = thumbnailStore
                await withTaskGroup(of: Void.self) { group in
                    for request in requests {
                        group.addTask { _ = try? await store.image(for: request) }
                    }
                }
            }
            .task(id: nextPageImageRequests) {
                guard isBrowsing, showsImages, memory.magazineIsOpen else { return }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard !Task.isCancelled else { return }
                let requests = nextPageImageRequests
                let store = thumbnailStore
                await withTaskGroup(of: Void.self) { group in
                    for request in requests {
                        group.addTask(priority: .utility) {
                            _ = try? await store.image(for: request)
                        }
                    }
                }
            }
            .task(id: memory.magazineIsOpen) {
                if !memory.magazineIsOpen {
                    onClearSelection()
                    cancelTurn()
                }
                // 图层动画以自己的完成回调收尾；主线程延迟挂载时不能按固定计时提前撤掉。
                guard reduceMotion || coverSnapshots == nil else { return }
                do { try await Task.sleep(for: .milliseconds(670)) } catch { return }
                coverAnimating = false
                coverSnapshots = nil
            }
            .onPreferenceChange(MagazinePageVisibilityKey.self) { frames in
                guard isBrowsing, turning == .scroll, !memory.isRestoring, !railScrubActive else { return }
                if !scrollPositionReady {
                    let targetIndex = edition.pageIndex(containing: memory.magazineAnchor)
                    guard pages.indices.contains(targetIndex),
                          frames[pages[targetIndex].id]?.isAtTop == true else { return }
                    scrollPositionReady = true
                    return
                }
                if let page = pages.first(where: { frames[$0.id]?.isVisible == true }) {
                    if let anchor = page.entries.first?.id { memory.magazineAnchor = anchor }
                }
            }
            .onReceive(memory.magazineAnchorUpdates) { observedMagazineAnchor = $0 }
            .onChange(of: editionInput, initial: true) { old, new in
                scrollTranslationLayoutTask?.cancel()
                if turning == .scroll, old.displayTexts != new.displayTexts {
                    var translatedOld = old
                    translatedOld.displayTexts = new.displayTexts
                    if translatedOld == new {
                        // 译文仅影响排版；长杂志的文字测量不能阻塞滚动帧。
                        scrollTranslationLayoutTask = Task { await edition.updateAsync(new) }
                        return
                    }
                }
                scrollTranslationLayoutTask = nil
                if isTurning, old.scopeID == new.scopeID, old.viewport == new.viewport,
                   old.arrangement == new.arrangement, old.locale == new.locale,
                   old.showsImages == new.showsImages {
                    // 阅读/图片等数据到达时，翻页快照和页内几何保持到落页再更新。
                    pendingEditionInput = new
                    return
                }
                let hadAnchor = edition.contains(memory.magazineAnchor)
                if old.scopeID != new.scopeID || old.viewport != new.viewport
                    || old.arrangement != new.arrangement || old.locale != new.locale {
                    scrollPositionReady = false
                }
                pendingEditionInput = nil
                cancelTurn()
                edition.update(new)
                if let pending = pendingPageIndex, pages.indices.contains(pending) {
                    pendingPageIndex = nil
                    withAnimation(.easeOut(duration: 0.15)) { notice = nil }
                    go(to: pending, proxy: proxy)
                } else if old.arrangement != new.arrangement || old.viewport != new.viewport
                            || old.locale != new.locale || !hadAnchor || !edition.contains(memory.magazineAnchor) {
                    restore(proxy: proxy)
                }
                // Appending data / read state updates must not scroll back to
                // the page's top while the user is reading its lower half.
            }
            .task(id: turningRaw) {
                // Wait for the destination scroll container to exist before
                // restoring its anchor when switching reading styles.
                scrollTranslationLayoutTask?.cancel()
                scrollTranslationLayoutTask = nil
                if turning != .scroll { edition.update(editionInput) }
                scrollPositionReady = false
                cancelTurn()
                await Task.yield()
                guard !Task.isCancelled else { return }
                restore(proxy: proxy)
            }
            .onChange(of: turningRaw) { _, _ in scrollPositionReady = false }
            .onChange(of: hasMore) { _, value in if !value { pendingPageIndex = nil } }
            .onChange(of: keyboardRequest) { _, request in
                guard isBrowsing, let request else { return }
                handle(request, proxy: proxy)
            }
            .onChange(of: memory.magazineScopeID) { _, _ in
                lastSelectionByPage.removeAll()
                // 切到新来源时直接落回封面，旧开页动画与旧页快照不再参与绘制。
                cancelCoverAnimation()
                cancelTurn()
            }
            .onChange(of: coverAnimating) { wasAnimating, animating in
                if wasAnimating && !animating && memory.magazineIsOpen {
                    revealSettledTranslations()
                }
            }
            .task(id: memory.restorationID) {
                guard isBrowsing else { return }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                restore(proxy: proxy, anchor: memory.restoreAnchor)
                memory.finishRestoration()
            }
            .onDisappear {
                scrollTranslationLayoutTask?.cancel()
                cancelCoverAnimation()
                cancelTurn()
            }
            .onChange(of: isBrowsing) { _, value in
                if !value {
                    cancelCoverAnimation()
                    cancelTurn()
                }
                else if memory.isRestoring {
                    restore(proxy: proxy, anchor: memory.restoreAnchor)
                    memory.finishRestoration()
                }
            }
            .onChange(of: availableSize) { _, _ in
                cancelCoverAnimation()
                cancelTurn()
            }
            .onChange(of: showsImages) { _, _ in cancelTurn() }
            .onChange(of: entryTranslations, initial: true) { _, _ in
                if !isTurning && !railScrubActive && !coverAnimating { revealSettledTranslations() }
            }
            .onChange(of: pageIndex) { _, index in
                if !isTurning && !railScrubActive && !coverAnimating { revealSettledTranslations() }
                reportVisibleEntries(around: index)
            }
            .onChange(of: pages.map(\.id)) { _, _ in
                if !isTurning && !railScrubActive && !coverAnimating { revealSettledTranslations() }
                reportVisibleEntries(around: pageIndex)
            }
            .onAppear { reportVisibleEntries(around: pageIndex) }
        }
        .background(turning != .scroll ? Color(nsColor: stageBackground) : Color.clear)
        .accessibilityIdentifier("magazine.browser")
    }

    private func handleTurnCompletion(id: UUID, committed: Bool) {
        guard turnRequest?.id == id else { return }
        if let pending = railScrubPendingIndex, pages.indices.contains(pending) {
            // TOC 松手后的吸附只提交最终最近页；中间页面不写入锚点。
            memory.magazineAnchor = pages[pending].entries.first?.id
            memory.visibleAnchor = memory.magazineAnchor
            railScrubPendingIndex = nil
            railScrubPosition = nil
            railScrubSourceAnchor = nil
            railScrubSessionID = nil
        } else if committed {
            memory.magazineAnchor = pages.first(where: { $0.id == turnRequest?.targetPageID })?.entries.first?.id
        } else {
            memory.magazineAnchor = turnSourceAnchor
        }
        memory.visibleAnchor = memory.magazineAnchor
        if committed && pageIndex == pages.count - 1 {
            if hasMore { showLoadMoreNotice() }
            else { showEndNotice() }
        }
        turnRequest = nil
        turnSourceAnchor = nil
        if let pending = pendingEditionInput {
            pendingEditionInput = nil
            edition.update(pending)
        }
        revealSettledTranslations()
    }

    @ViewBuilder
    private func magazinePages(proxy: ScrollViewProxy) -> some View {
        if turning == .scroll {
            ScrollView {
                LazyVStack(spacing: 40) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        magazineScrollPage(page: page, index: index)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.never)
        } else {
            Group {
                if pages.indices.contains(pageIndex) {
                    foldPageView(page: pages[pageIndex], index: pageIndex, proxy: proxy)
                }
            }
            .frame(width: paperWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .onChange(of: isDraggingPage) { _, active in
                // 系统取消手势时不会调用 onEnded，但 GestureState 必定复位。
                guard !active, var request = turnRequest, let progress = request.progress else { return }
                request.commit = progress > 0.4
                request.progress = nil
                turnRequest = request
            }
        }
    }

    private func pageRail(proxy: ScrollViewProxy) -> some View {
        // 封面与展开页共用固定舞台，导航出现时不再挤动书页。
        Color.clear
            .frame(height: MagazinePaginator.railHeight)
            .overlay(alignment: .bottom) {
                if memory.magazineIsOpen && !pages.isEmpty {
                    MagazinePageRail(
                        pages: pages,
                        currentIndex: railPageIndex,
                        isTurning: isTurning && !railScrubActive,
                        availableWidth: availableSize.width,
                        availableHeight: availableSize.height,
                        onSelect: { go(to: $0, proxy: proxy) },
                        onScrubStart: { beginRailScrub(proxy: proxy) },
                        onScrubChanged: { normalized in updateRailScrub(normalized, proxy: proxy) },
                        onScrubEnded: { endRailScrub(proxy: proxy, cancelled: false) },
                        onScrubCancelled: { endRailScrub(proxy: proxy, cancelled: true) }
                    )
                }
            }
    }

    @ViewBuilder
    private func foldPageView(page: MagazinePage, index: Int, proxy: ScrollViewProxy) -> some View {
        MagazinePageTurnView(pageID: page.id, request: turnRequest,
            reduceMotion: reduceMotion, isActive: isBrowsing && memory.magazineIsOpen,
            background: stageBackground, verticalInset: turnInset, playsSound: false,
            fades: usesSingleSheetTransition(page),
            content: foldContent(page: page, index: index, proxy: proxy),
            source: turnRequest?.sourcePageID.flatMap { id in
                pages.firstIndex(where: { $0.id == id }).map {
                    foldContent(page: pages[$0], index: $0, proxy: proxy)
                }
            },
            onComplete: { id, committed in
                handleTurnCompletion(id: id, committed: committed)
            })
    }

    private func usesSingleSheetTransition(_ page: MagazinePage) -> Bool {
        if turning == .fade || edition.layouts[page.id]?.form != .spread { return true }
        let sourceIndex = edition.pageIndex(containing: turnSourceAnchor ?? memory.magazineAnchor)
        guard pages.indices.contains(sourceIndex) else { return false }
        return edition.layouts[pages[sourceIndex].id]?.form != .spread
    }

    private func foldContent(page: MagazinePage, index: Int, proxy: ScrollViewProxy) -> some View {
        let layout = edition.layouts[page.id]
        return pageContent(page, index: index)
                .frame(width: layout?.paperWidth ?? paperWidth, height: layout?.paperHeight, alignment: .top)
                .background(foldSheetBackground(showsFold: layout?.form == .spread))
                .overlay(Rectangle().strokeBorder(Color(paperHex: palette.inkHex).opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(palette.colorScheme == .dark ? 0.16 : 0.08), radius: 10, x: 0, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.vertical, turnInset)
                .background(Color(nsColor: stageBackground))
                .environment(\.paperAppearancePalette, palette)
                .environment(\.colorScheme, colorScheme)
                .environment(\.locale, locale)
                .highPriorityGesture(pageDrag(proxy: proxy))
    }

    private func magazineScrollPage(page: MagazinePage, index: Int) -> some View {
        pageContent(page, index: index)
            // 版面尺寸已经由分页器确定，滚动栈不必用文字子树推测页高。
            .frame(height: (edition.layouts[page.id]?.height ?? 0) + MagazinePaginator.headingHeight, alignment: .top)
            .background(paperSheetBackground)
            .id(page.id)
            .background(GeometryReader { geometry in
                let frame = geometry.frame(in: .named("magazine-viewport"))
                Color.clear.preference(key: MagazinePageVisibilityKey.self,
                    value: [page.id: MagazinePageVisibility(frame: frame, viewportHeight: availableSize.height)])
            })
            .onAppear {
                let isTail = page.id == pages.last?.id
                if isBrowsing && isTail && hasMore { onNeedMore() }
            }
    }

    // 手势必须位于 NSHostingView 内，才能与文章 Button 正确仲裁。
    private func pageDrag(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($isDraggingPage) { _, active, _ in active = true }
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                if dragSourcePageIndex == nil { dragSourcePageIndex = pageIndex }
                if dragSourcePageIndex == 0 && value.translation.width > 0 {
                    if value.translation.width > 36 {
                        closeBook()
                    }
                    return
                }
                if turnRequest == nil {
                    go(to: pageIndex + (value.translation.width < 0 ? 1 : -1), proxy: proxy, interactive: true)
                }
                guard var request = turnRequest, request.progress != nil else { return }
                let distance = value.translation.width * (request.forward ? -1 : 1)
                request.progress = min(1, max(0, distance / (contentWidth * 0.65)))
                turnRequest = request
            }
            .onEnded { value in
                let sourcePageIndex = dragSourcePageIndex ?? pageIndex
                dragSourcePageIndex = nil
                if sourcePageIndex == 0 && value.translation.width > 0 {
                    if value.translation.width > 20 || value.predictedEndTranslation.width > 30 {
                        closeBook()
                    }
                    return
                }
                guard var request = turnRequest, request.progress != nil else { return }
                let predicted = value.predictedEndTranslation.width * (request.forward ? -1 : 1)
                let progress = request.progress ?? 0
                request.releaseVelocity = (predicted - value.translation.width * (request.forward ? -1 : 1)) / (contentWidth * 0.65 * 0.25)
                request.commit = progress > 0.4 || (progress > 0.12 && predicted > contentWidth * 0.35)
                request.progress = nil
                turnRequest = request
            }
    }

    @ViewBuilder
    private func magazineInputOverlay(proxy: ScrollViewProxy) -> some View {
        if turning != .scroll {
            MagazineInputRegion(active: isBrowsing && !coverAnimating,
                articleFrames: memory.magazineIsOpen ? articleFrames : [],
                onArticleDown: { memory.openingFrameInWindow = $0 },
                onTurn: { direction in
                    if !memory.magazineIsOpen {
                        if direction > 0 { openBook() }
                        return
                    }
                    onClearSelection()
                    go(to: pageIndex + direction, proxy: proxy)
                },
                onClear: onClearSelection,
                onEdge: { direction in if edge != direction { edge = direction } },
                onSwipe: { distance, velocity, ended, cancelled in
                    handleMagazineSwipe(distance: distance, velocity: velocity,
                        ended: ended, cancelled: cancelled, proxy: proxy)
                })
        }
    }

    private func handleMagazineSwipe(distance: CGFloat, velocity: CGFloat, ended: Bool,
                                     cancelled: Bool, proxy: ScrollViewProxy) {
        if swipeSourcePageIndex == nil { swipeSourcePageIndex = pageIndex }
        let sourcePageIndex = swipeSourcePageIndex ?? pageIndex
        if ended || cancelled { swipeSourcePageIndex = nil }
        if !memory.magazineIsOpen {
            if distance < 0 && !cancelled {
                if abs(distance) > 24 || (ended && (abs(distance) > 12 || velocity < -80)) {
                    openBook()
                }
            }
            return
        }
        if sourcePageIndex == 0 && distance > 0 {
            if !cancelled && (distance > 24 || (ended && distance > 12)) {
                closeBook()
            }
            return
        }
        if turnRequest == nil && !ended {
            go(to: pageIndex + (distance < 0 ? 1 : -1), proxy: proxy, interactive: true)
        }
        guard var request = turnRequest, request.progress != nil else { return }
        let sign = request.forward ? -1.0 : 1.0
        let progress = min(1, max(0, distance * sign / (contentWidth * 0.5)))
        request.progress = progress
        if ended {
            request.releaseVelocity = velocity * sign / (contentWidth * 0.5)
            let projected = progress + (request.releaseVelocity ?? 0) * 0.16
            request.commit = !cancelled && (progress > 0.4 || projected > 0.45)
            request.progress = nil
        }
        turnRequest = request
    }

    private func beginRailScrub(proxy: ScrollViewProxy) {
        guard isBrowsing, memory.magazineIsOpen, !pages.isEmpty else { return }
        // 轨道可以接管正在收尾的翻页，但起点仍以最后提交的锚点为准，
        // 避免从半页状态开始一次不可逆的长距离拖动。
        let committed = min(max(0, edition.pageIndex(containing: memory.magazineAnchor)), max(0, pages.count - 1))
        cancelTurn()
        railScrubActive = true
        railScrubPosition = Double(committed)
        railScrubSourceAnchor = memory.magazineAnchor ?? pages[committed].entries.first?.id
        railScrubPendingIndex = nil
        railScrubForward = nil
        railScrubSessionID = UUID()
        onClearSelection()
    }

    private func updateRailScrub(_ normalized: Double, proxy: ScrollViewProxy) {
        guard railScrubActive, pages.count > 1 else { return }
        let position = MagazineRailScrub.pagePosition(normalized: normalized, count: pages.count)
        let previous = railScrubPosition ?? position
        railScrubPosition = position

        // 普通滚动模式没有翻页 surface，拖动直接定位到最近页；开启减少动态效果
        // 时也使用同一路径，避免为仅用于透明度过渡的快照分配 Metal 资源。
        if turning == .scroll || reduceMotion {
            let index = MagazineRailScrub.nearestIndex(position: position, count: pages.count)
            if pages.indices.contains(index), index != MagazineRailScrub.nearestIndex(position: previous, count: pages.count) {
                if turning == .scroll {
                    withAnimation(nil) { proxy.scrollTo(pages[index].id, anchor: .top) }
                }
            }
            return
        }

        // 同一页对内反向拖动只反写进度，保留原请求 UUID、Metal 纹理和折页
        // 方向；只有跨出当前区间时才创建下一对页面。
        if let request = turnRequest,
           let targetIndex = pages.firstIndex(where: { $0.id == request.targetPageID }),
           request.progress != nil {
            let sourceIndex = request.forward ? targetIndex - 1 : targetIndex + 1
            if pages.indices.contains(sourceIndex) {
                let existing = MagazineRailScrub.Pair(sourceIndex: sourceIndex, targetIndex: targetIndex,
                    progress: request.progress ?? 0, forward: request.forward)
                if let progress = MagazineRailScrub.progress(position: position, in: existing) {
                    var retained = request
                    retained.progress = progress
                    turnRequest = retained
                    return
                }
            }
        }

        if abs(position - previous) > 0.0001 {
            railScrubForward = position > previous
        }
        let forward = railScrubForward ?? true
        guard let pair = MagazineRailScrub.pair(position: position, count: pages.count, forward: forward),
              pages.indices.contains(pair.targetIndex) else { return }

        if var request = turnRequest,
           request.targetPageID == pages[pair.targetIndex].id,
           request.forward == pair.forward,
           request.progress != nil {
            // 同一页面对只改进度，不重新抓取快照。
            request.progress = pair.progress
            turnRequest = request
        } else {
            // 页面边界只保留最后一个请求；渲染器按明确的源页和目标页取快照，
            // 快速跳过中间页时也不会误用上一对内容，旧请求不排队或回写锚点。
            turnRequest = MagazinePageTurnRequest(targetPageID: pages[pair.targetIndex].id,
                forward: pair.forward, sourcePageID: pages[pair.sourceIndex].id,
                scrubSessionID: railScrubSessionID,
                progress: pair.progress)
        }
    }

    private func endRailScrub(proxy: ScrollViewProxy, cancelled: Bool) {
        guard railScrubActive else { return }
        let origin = min(max(0, edition.pageIndex(containing: railScrubSourceAnchor)), max(0, pages.count - 1))
        if cancelled {
            // 系统取消或窗口离开时直接回到提交位置，不让旧页面对继续播放。
            cancelTurn()
            if pages.indices.contains(origin) {
                memory.magazineAnchor = pages[origin].entries.first?.id
                memory.visibleAnchor = memory.magazineAnchor
                if turning == .scroll { withAnimation(nil) { proxy.scrollTo(pages[origin].id, anchor: .top) } }
            }
            return
        }
        let finalIndex = MagazineRailScrub.nearestIndex(position: railScrubPosition ?? Double(origin), count: pages.count)
        railScrubActive = false
        railScrubForward = nil
        guard pages.indices.contains(finalIndex) else { cancelTurn(); return }

        guard var request = turnRequest,
              let targetIndex = pages.firstIndex(where: { $0.id == request.targetPageID }) else {
            memory.magazineAnchor = pages[finalIndex].entries.first?.id
            memory.visibleAnchor = memory.magazineAnchor
            railScrubPosition = nil
            railScrubSourceAnchor = nil
            railScrubSessionID = nil
            return
        }
        request.commit = targetIndex == finalIndex
        request.settleFrom = request.progress
        request.progress = nil
        request.releaseVelocity = nil
        request.settleDuration = reduceMotion ? 0.12 : 0.18
        railScrubPendingIndex = finalIndex
        turnRequest = request
    }

    private func cancelTurn() {
        if turnRequest != nil, let anchor = turnSourceAnchor { memory.magazineAnchor = anchor }
        if railScrubActive, let anchor = railScrubSourceAnchor {
            memory.magazineAnchor = anchor
            memory.visibleAnchor = anchor
        }
        turnRequest = nil
        turnSourceAnchor = nil
        let pending = pendingEditionInput
        pendingEditionInput = nil
        railScrubActive = false
        railScrubPendingIndex = nil
        railScrubPosition = nil
        railScrubSourceAnchor = nil
        railScrubForward = nil
        railScrubSessionID = nil
        if let pending { edition.update(pending) }
    }

    /// 当前页及前后页的可见标题和描述一并预取；调度器分批并优先处理标题。
    /// 排版尚未完成时不回调，保持上一次的范围。
    private func reportVisibleEntries(around index: Int) {
        guard !pages.isEmpty, pages.indices.contains(index) else { return }
        var candidates: [TitleTranslationCandidate] = []
        var seen = Set<String>()
        for offset in [0, 1, -1] {
            let target = index + offset
            guard pages.indices.contains(target) else { continue }
            for entry in pages[target].entries where seen.insert(entry.id).inserted {
                candidates.append(TitleTranslationCandidate(entryID: entry.id, feedID: entry.feedID,
                    title: entry.title,
                    summary: entry.isSummaryVisible ? entry.summaryPreview : nil))
            }
        }
        guard !candidates.isEmpty else { return }
        onVisibleEntriesChange(candidates)
    }

    private func pageContent(_ page: MagazinePage, index: Int) -> some View {
        let layout = edition.layouts[page.id]
        let entriesByID = Dictionary(page.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pageContentWidth = layout?.contentWidth ?? contentWidth
        let leafWidth = max(1, (pageContentWidth - MagazinePaginator.gutter) / 2)
        let showsBackCover = layout?.form == .spread && (layout?.placements.allSatisfy { $0.frame.maxX <= leafWidth + 1 } ?? false)
        return VStack(alignment: .leading, spacing: MagazinePaginator.headingSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.title).font(.system(size: 15, weight: .semibold, design: .serif))
                Spacer()
                Text(String(format: "%02d", index + 1)).font(.system(size: 11))
                    .foregroundStyle(Color(paperHex: palette.mutedHex))
            }.frame(height: 20)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(paperHex: palette.mutedHex).opacity(0.22))
                        .frame(height: 0.5).offset(y: MagazinePaginator.headingSpacing / 2)
                }
            ZStack(alignment: .topLeading) {
                if let layout {
                    ForEach(layout.placements, id: \.entryID) { placement in
                        if let entry = entriesByID[placement.entryID] {
                            tile(entry, placement.frame.width, .gallery)
                            .environment(\.entryTranslations, presentedTranslations)
                            .environment(\.magazineStoryStyle, placement.style)
                            .frame(width: placement.frame.width, height: placement.frame.height, alignment: .leading)
                            .overlay(alignment: .top) {
                                if placement.frame.minY > 0 {
                                    Rectangle().fill(Color(paperHex: palette.mutedHex).opacity(0.14))
                                        .frame(height: 0.5).offset(y: -MagazinePaginator.rowSpacing / 2)
                                }
                            }
                            .offset(x: placement.frame.minX, y: placement.frame.minY)
                            .id(entry.id)
                        }
                    }
                    if showsBackCover {
                        backCoverLeaf(width: leafWidth, height: layout.height)
                            .offset(x: leafWidth + MagazinePaginator.gutter, y: 0)
                    }
                }
            }
            .frame(width: pageContentWidth, height: layout?.height ?? 0, alignment: .topLeading)
        }
        .frame(width: pageContentWidth, alignment: .topLeading)
        .padding(.horizontal, layout?.inset ?? MagazinePaginator.horizontalInset(availableSize.width))
        .padding(.vertical, MagazinePaginator.verticalInset)
        .foregroundStyle(Color(paperHex: palette.inkHex))
        .onAppear { edition.markDisplayed(page.id) }
    }

    private func backCoverLeaf(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 20) {
            PaperBrandIcon(width: min(64, width * 0.20))
                .opacity(0.8)
            if !coverTitle.isEmpty {
                Text(coverTitle)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(paperHex: palette.inkHex).opacity(0.72))
                    .padding(.horizontal, 24)
            }
            Rectangle()
                .fill(Color(paperHex: palette.mutedHex).opacity(0.24))
                .frame(width: 32, height: 1)
            Text(I18N.shared.localized("本期阅读完成", "End of Edition"))
                .font(.system(size: 13, weight: .regular, design: .serif))
                .foregroundStyle(Color(paperHex: palette.mutedHex))
        }
        .frame(width: width, height: height, alignment: .center)
        .accessibilityHidden(true)
    }

    private func showEndNotice() {
        guard notice == nil else { return }
        noticeID = UUID()
        withAnimation(.easeOut(duration: 0.15)) { notice = I18N.shared.localized("已经是最后一页", "You’ve reached the last page") }
    }

    private func showLoadMoreNotice() {
        guard notice == nil else { return }
        noticeID = UUID()
        withAnimation(.easeOut(duration: 0.15)) { notice = I18N.shared.localized("继续翻页加载更多", "Turn page to load more") }
    }

    private func showLoadingNotice() {
        noticeID = UUID()
        withAnimation(.easeOut(duration: 0.15)) { notice = I18N.shared.localized("正在加载更多文章…", "Loading more…") }
    }

    private func openBook() {
        // 没有可展示的版面时绝不翻开：保持封面/“暂无文章”，避免空书。
        guard !memory.magazineIsOpen, !isLoading, !pages.isEmpty,
              edition.containsScope(memory.magazineScopeID) else { return }
        autoOpenedScope = memory.magazineScopeID
        onClearSelection()
        cancelTurn()
        if let firstID = pages.first?.entries.first?.id {
            memory.magazineAnchor = firstID
            memory.visibleAnchor = firstID
        }
        prepareCoverSnapshots()
        coverOpening = true
        coverAnimating = true
        if pageSoundEnabled { MagazinePageSound.play() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) :
                      .timingCurve(0.77, 0, 0.175, 1, duration: 0.65)) {
            memory.magazineIsOpen = true
        }
    }

    private func cancelCoverAnimation() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            coverAnimating = false
            coverSnapshots = nil
        }
    }

    private func closeBook() {
        guard memory.magazineIsOpen else { return }
        onClearSelection()
        cancelTurn()
        if let firstID = pages.first?.entries.first?.id {
            memory.magazineAnchor = firstID
            memory.visibleAnchor = firstID
        }
        prepareCoverSnapshots()
        coverOpening = false
        coverAnimating = true
        if pageSoundEnabled { MagazinePageSound.play() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) :
                      .timingCurve(0.77, 0, 0.175, 1, duration: 0.65)) {
            memory.magazineIsOpen = false
        }
    }

    private var bookCover: some View {
        GeometryReader { geometry in
            let width = paperWidth / 2
            // 与翻页宿主使用同一视口，不再次扣除底部导航高度。
            let height = max(1, geometry.size.height - turnInset * 2)
            ZStack {
                Button(action: openBook) {
                    if !reduceMotion, coverSnapshots != nil {
                        coverFace(width: width, height: height)
                            .opacity(coverAnimating || memory.magazineIsOpen ? 0 : 1)
                    } else {
                        MagazineCoverLeaf(progress: memory.magazineIsOpen ? 1 : 0, reduced: reduceMotion,
                            width: width, front: coverFace(width: width, height: height),
                            back: coverInside(width: width, height: height))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(coverTitle)
                .accessibilityIdentifier("magazine.cover")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                            if value.translation.width < -20 || value.predictedEndTranslation.width < -30 {
                                openBook()
                            }
                        }
                )
                if coverAnimating, !reduceMotion, let coverSnapshots {
                    let scope = memory.magazineScopeID
                    MagazineCoverAnimationSurface(front: coverSnapshots.front, back: coverSnapshots.back,
                                                  right: coverSnapshots.right,
                                                  opening: coverOpening) {
                        guard coverAnimating, memory.magazineScopeID == scope else { return }
                        coverAnimating = false
                        self.coverSnapshots = nil
                    }
                        .frame(width: paperWidth, height: height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .position(x: geometry.size.width / 2, y: turnInset + height / 2)
            .onChange(of: geometry.size, initial: true) { _, size in
                if coverBounds != size { coverBounds = size }
            }
        }
    }

    private func prepareCoverSnapshots() {
        guard !reduceMotion, !pages.isEmpty, coverBounds.width > 1, coverBounds.height > 1 else {
            coverSnapshots = nil
            return
        }
        let size = CGSize(width: paperWidth / 2, height: max(1, coverBounds.height - turnInset * 2))
        let spreadSize = CGSize(width: paperWidth, height: size.height)
        guard let page = pages.first,
              let front = coverImage(coverFace(width: size.width, height: size.height), size: size),
              let spread = coverImage(pageContent(page, index: 0)
                .frame(width: paperWidth, height: spreadSize.height, alignment: .topLeading)
                .background(foldSheetBackground(showsFold: edition.layouts[page.id]?.form == .spread)),
                size: spreadSize) else {
            coverSnapshots = nil
            return
        }
        let split = spread.width / 2
        guard split > 0,
              let back = spread.cropping(to: CGRect(x: 0, y: 0, width: split, height: spread.height)),
              let right = spread.cropping(to: CGRect(x: split, y: 0,
                                                     width: spread.width - split, height: spread.height)) else {
            coverSnapshots = nil
            return
        }
        coverSnapshots = (front, back, right)
    }

    private func coverImage<Content: View>(_ content: Content, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: content
            .environment(\.paperAppearancePalette, palette)
            .environment(\.colorScheme, colorScheme)
            .environment(\.displayScale, displayScale)
            .environment(\.locale, locale)
            .environment(\.entryTranslations, presentedTranslations))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = min(displayScale, 2, sqrt(2_000_000 / max(1, size.width * size.height)))
        // 封面是圆角，强制不透明会把透明角落烘成黑色像素。
        renderer.isOpaque = false
        return renderer.cgImage
    }

    private func coverInside(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let page = pages.first, !memory.magazineIsOpen || coverAnimating {
                pageContent(page, index: 0)
                    .frame(width: paperWidth, height: height, alignment: .topLeading)
                    .frame(width: width, height: height, alignment: .leading)
                    .clipped()
            } else {
                paperSheetBackground.frame(width: width, height: height)
            }
        }
        .background(paperSheetBackground)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func coverFace(width: CGFloat, height: CGFloat) -> some View {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(paperBackground)
                    .overlay {
                        if paperStyle == .book {
                            paperSheetBackground
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .overlay {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.black.opacity(0.035), .clear],
                                startPoint: .leading, endPoint: .trailing).frame(width: 12)
                            Spacer()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(paperHex: palette.inkHex).opacity(0.035), lineWidth: 0.5)
                    }
                    .background {
                        // 纸页从封皮后露出，只在右侧与底部保留薄薄的层次。
                        ZStack {
                            ForEach((1...3).reversed(), id: \.self) { line in
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(paperBackground)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Color(paperHex: palette.inkHex).opacity(0.065), lineWidth: 0.5)
                                    }
                                    .padding(1)
                                    .offset(x: CGFloat(line), y: CGFloat(line) * 1.2)
                            }
                        }
                        .shadow(color: .black.opacity(0.07), radius: 14, x: 2, y: 6)
                    }
                VStack(spacing: 26) {
                    PaperBrandIcon(width: min(78, width * 0.22))
                    Text(coverTitle).font(.system(size: 23, weight: .medium, design: .serif))
                        .multilineTextAlignment(.center).foregroundStyle(Color(paperHex: palette.inkHex).opacity(0.7))
                }.padding(32)
            }
            .frame(width: width, height: height)
    }

    private func edgeButton(_ direction: Int, proxy: ScrollViewProxy) -> some View {
        Button { onClearSelection(); go(to: pageIndex + direction, proxy: proxy) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 21, weight: .medium)).foregroundStyle(Color(paperHex: palette.inkHex).opacity(0.55))
                .frame(width: 36, height: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(edge == direction ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: edge)
        .accessibilityLabel(direction < 0 ? I18N.localized("上一页") : I18N.localized("下一页"))
        .accessibilityIdentifier(direction < 0 ? "magazine.edge.previous" : "magazine.edge.next")
    }

    private func go(to index: Int, proxy: ScrollViewProxy, interactive: Bool = false) {
        guard isBrowsing, memory.magazineIsOpen else { return }
        if isTurning || railScrubActive { cancelTurn() }
        if index < 0 { closeBook(); return }
        if index >= pages.count {
            if hasMore {
                pendingPageIndex = index
                showLoadingNotice()
                onNeedMore()
            } else {
                showEndNotice()
            }
            return
        }
        guard let anchor = pages[index].entries.first?.id else { return }
        if index == pageIndex && turning != .scroll { return }
        if turning != .scroll {
            turnSourceAnchor = memory.magazineAnchor
            turnRequest = .init(targetPageID: pages[index].id, forward: index > pageIndex,
                                progress: interactive ? 0 : nil)
            // 请求与目标页由同一个 State 原子切换；完成后才写回可观察锚点。
        } else {
            memory.visibleAnchor = anchor
            memory.magazineAnchor = anchor
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(pages[index].id, anchor: .top) }
            if index == pages.count - 1 {
                if hasMore { showLoadMoreNotice() }
                else { showEndNotice() }
            }
        }
    }

    private func restore(proxy: ScrollViewProxy, anchor: String? = nil) {
        guard memory.magazineIsOpen else {
            if let firstID = pages.first?.entries.first?.id {
                memory.magazineAnchor = firstID
            }
            return
        }
        let anchor = anchor ?? memory.magazineAnchor
        let index = edition.pageIndex(containing: anchor)
        guard pages.indices.contains(index) else { return }
        let validAnchor = anchor.flatMap { value in pages[index].entries.contains { $0.id == value } ? value : nil }
        memory.magazineAnchor = validAnchor ?? pages[index].entries.first?.id
        if turning == .scroll { proxy.scrollTo(pages[index].id, anchor: .top) }
    }

    private var articleFrames: [CGRect] {
        guard pages.indices.contains(pageIndex), let layout = edition.layouts[pages[pageIndex].id] else { return [] }
        let x = (availableSize.width - layout.paperWidth) / 2 + layout.inset
        let y = turnInset + MagazinePaginator.verticalInset + 20 + MagazinePaginator.headingSpacing
        return zip(pages[pageIndex].entries, layout.placements).map { entry, placement in
            var frame = placement.frame
            frame.size.height = min(frame.height, placement.style.height(for: entry, width: frame.width))
            return frame.offsetBy(dx: x, dy: y)
        }
    }

    private func handle(_ request: TimelineKeyRequest, proxy: ScrollViewProxy) {
        if request.keyCode == 53 { onClearSelection(); return }
        guard memory.magazineIsOpen else {
            if request.keyCode == 123 { onFocusSidebar() }
            else if [36, 49, 76, 124, 121].contains(request.keyCode) { openBook() }
            return
        }
        if request.keyCode == 116 || request.keyCode == 121 {
            turnPage(to: pageIndex + (request.keyCode == 121 ? 1 : -1),
                     from: currentPlacement, proxy: proxy)
            return
        }
        guard !isTurning else { return }
        guard pages.indices.contains(pageIndex), let layout = edition.layouts[pages[pageIndex].id] else { return }
        let current = layout.placements.first { $0.entryID == selectedID }
        if [UInt16(123), 124, 125, 126].contains(request.keyCode) {
            guard let current else {
                if let first = layout.placements.first { onHighlight(first.entryID) }
                return
            }
            if let target = MagazineSpatialNavigation.neighbor(of: current, in: layout.placements, key: request.keyCode) {
                onHighlight(target.entryID)
            } else if request.keyCode == 123 || request.keyCode == 124 {
                // 只有左右键在页面边缘才翻页：第一页边缘向左合上封面（再按一次才离开杂志去侧栏），
                // 最后一页边缘向右提示读完（还有后续内容时继续加载）。上下键只在页内纵向移动，到顶/到底即停。
                turnPage(to: pageIndex + (request.keyCode == 123 ? -1 : 1), from: current, proxy: proxy)
            }
        } else if [36, 49, 76].contains(request.keyCode), let current,
                  let entry = pages[pageIndex].entries.first(where: { $0.id == current.entryID }) {
            memory.openingFrameInWindow = nil
            onOpen(entry)
        }

    }

    private var currentPlacement: MagazinePlacement? {
        guard pages.indices.contains(pageIndex), let layout = edition.layouts[pages[pageIndex].id] else { return nil }
        return layout.placements.first { $0.entryID == selectedID }
    }

    /// 翻页时记住离开页最后停留的卡片，翻回该页时优先恢复到该卡片：
    /// 例如从右半页翻到下一页，再从下一页左半页翻回，仍落回右半页的原卡片，
    /// 而不是阅读顺序的末篇。没有记录时向前落首篇、向后落末篇。
    private func turnPage(to index: Int, from current: MagazinePlacement?, proxy: ScrollViewProxy) {
        if let current, pages.indices.contains(pageIndex) {
            lastSelectionByPage[pages[pageIndex].id] = current.entryID
        }
        if pages.indices.contains(index), let layout = edition.layouts[pages[index].id] {
            let remembered = lastSelectionByPage[pages[index].id]
                .flatMap { id in layout.placements.first { $0.entryID == id } }
            let landing = remembered ?? (index < pageIndex ? layout.placements.last : layout.placements.first)
            if let landing { onHighlight(landing.entryID) }
        }
        go(to: index, proxy: proxy)
    }
}

/// 封皮正反面共用书脊；过半后只显示背面，避免镜像文字和提前淡走。
@MainActor
private struct MagazineCoverLeaf<Front: View, Back: View>: View, @MainActor Animatable {
    nonisolated var progress: Double
    let reduced: Bool
    let width: CGFloat
    let front: Front
    let back: Back
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        Group {
            if reduced {
                front.opacity(1 - progress)
            } else {
                ZStack {
                    front.opacity(progress < 0.5 ? 1 : 0)
                    back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                        .opacity(progress >= 0.5 ? 1 : 0)
                }
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.08 * sin(progress * .pi)), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .allowsHitTesting(false)
                }
                .rotation3DEffect(.degrees(-180 * progress), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.14)
                .offset(x: width / 2 * progress)
            }
        }
    }
}

/// 封皮旋转只提交两张静态图层，窗口主线程繁忙时仍由合成器继续补帧。
private struct MagazineCoverAnimationSurface: NSViewRepresentable {
    let front: CGImage
    let back: CGImage
    let right: CGImage
    let opening: Bool
    let onComplete: @MainActor () -> Void

    func makeNSView(context: Context) -> MagazineCoverAnimationView {
        MagazineCoverAnimationView(front: front, back: back, right: right,
                                   opening: opening, onComplete: onComplete)
    }
    func updateNSView(_ view: MagazineCoverAnimationView, context: Context) {}
    static func dismantleNSView(_ view: MagazineCoverAnimationView, coordinator: ()) {
        view.cancel()
    }
}

@MainActor
private final class MagazineCoverAnimationView: NSView {
    private let front: CGImage
    private let back: CGImage
    private let rightImage: CGImage
    private let opening: Bool
    private let onComplete: @MainActor () -> Void
    private let leaf = CALayer()
    private let rightPage = CALayer()
    private var started = false
    private var cancelled = false

    init(front: CGImage, back: CGImage, right: CGImage, opening: Bool,
         onComplete: @escaping @MainActor () -> Void) {
        self.front = front
        self.back = back
        self.rightImage = right
        self.opening = opening
        self.onComplete = onComplete
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard !started, bounds.width > 2, bounds.height > 1, let layer else { return }
        started = true
        let width = bounds.width / 2
        let left = width / 2
        let right = width
        let closed = CATransform3DIdentity
        let opened = CATransform3DMakeRotation(-.pi, 0, 1, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(1, width * 7)
        layer.sublayerTransform = perspective
        // 右页与封皮共用同一书脊坐标和 Core Animation 时间轴，避免两套动画错拍露缝。
        rightPage.name = "magazine.cover.rightPage"
        rightPage.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        rightPage.anchorPoint = CGPoint(x: 0, y: 0.5)
        rightPage.position = CGPoint(x: opening ? left : right, y: bounds.midY)
        rightPage.contents = rightImage
        rightPage.contentsGravity = .resize
        rightPage.contentsScale = CGFloat(rightImage.width) / width
        layer.addSublayer(rightPage)
        leaf.name = "magazine.cover.leaf"
        leaf.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        leaf.anchorPoint = CGPoint(x: 0, y: 0.5)
        leaf.position = CGPoint(x: opening ? left : right, y: bounds.midY)
        leaf.transform = opening ? closed : opened
        var faces: [CALayer] = []
        for (image, reversed) in [(front, false), (back, true)] {
            let face = CALayer()
            face.frame = leaf.bounds
            face.contents = image
            face.contentsGravity = .resize
            face.contentsScale = CGFloat(image.width) / width
            // 可见面由 opacity 切换；单面裁剪会在父子层 3D 旋转叠加时误隐藏背面。
            face.isDoubleSided = true
            face.masksToBounds = true
            face.opacity = opening == reversed ? 1 : 0
            if reversed { face.transform = CATransform3DMakeRotation(.pi, 0, 1, 0) }
            leaf.addSublayer(face)
            faces.append(face)
        }
        layer.addSublayer(leaf)
        rightPage.position.x = opening ? right : left
        leaf.position.x = opening ? right : left
        leaf.transform = opening ? opened : closed
        CATransaction.commit()

        let timing = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.onComplete()
            }
        }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.y")
        rotation.fromValue = opening ? 0 : -Double.pi
        rotation.toValue = opening ? -Double.pi : 0
        rotation.duration = 0.65
        rotation.timingFunction = timing
        leaf.add(rotation, forKey: "rotation")
        let position = CABasicAnimation(keyPath: "position.x")
        position.fromValue = opening ? left : right
        position.toValue = opening ? right : left
        position.duration = 0.65
        position.timingFunction = timing
        leaf.add(position, forKey: "position")
        let rightPosition = CABasicAnimation(keyPath: "position.x")
        rightPosition.fromValue = opening ? left : right
        rightPosition.toValue = opening ? right : left
        rightPosition.duration = 0.65
        rightPosition.timingFunction = timing
        rightPage.add(rightPosition, forKey: "position")
        for (index, face) in faces.enumerated() {
            let showsAtStart = opening ? index == 0 : index == 1
            let visibility = CAKeyframeAnimation(keyPath: "opacity")
            visibility.values = showsAtStart ? [1, 1, 0, 0] : [0, 0, 1, 1]
            visibility.keyTimes = [0, 0.48, 0.52, 1]
            visibility.duration = 0.65
            face.add(visibility, forKey: "visibility")
        }
        CATransaction.commit()
    }

    func cancel() {
        cancelled = true
        leaf.removeAllAnimations()
        leaf.removeFromSuperlayer()
        rightPage.removeAllAnimations()
        rightPage.removeFromSuperlayer()
    }
}

/// 方向键按版面几何移动（遥控器模型）：左右只横向、上下只纵向，落在最近的一张卡片上。
/// 横向优先同一水平带（先就近那一栏，再就近那一行），没有同带卡片时取对面整体最近的一篇；
/// 某一方向没有卡片即到达页面边缘，由外层决定翻页或停止。
enum MagazineSpatialNavigation {
    static func neighbor(of current: MagazinePlacement, in placements: [MagazinePlacement], key: UInt16) -> MagazinePlacement? {
        let origin = current.frame
        let others = placements.filter { $0.entryID != current.entryID }

        switch key {
        case 124: return horizontal(origin, in: others, right: true)
        case 123: return horizontal(origin, in: others, right: false)
        case 125: return downward(origin, in: others)
        case 126: return upward(origin, in: others)
        default: return nil
        }
    }

    /// 横向遥控：只考察侧方卡片。同一水平带里先落到最近的一栏，再落到纵向最贴近的一行；
    /// 同带没有卡片时，仍按“就近对面”落点（先比纵向间距，再比栏距）。
    private static func horizontal(_ origin: CGRect, in placements: [MagazinePlacement], right: Bool) -> MagazinePlacement? {
        let side = placements.filter { item in
            right ? item.frame.minX >= origin.maxX - 1 : item.frame.maxX <= origin.minX + 1
        }
        guard !side.isEmpty else { return nil }
        let sameBand = side.filter { verticalOverlap($0.frame, origin) > 0 }
        if !sameBand.isEmpty {
            return sameBand.min { a, b in
                let gapA = columnGap(a.frame, origin, right: right)
                let gapB = columnGap(b.frame, origin, right: right)
                if abs(gapA - gapB) > 8 { return gapA < gapB }
                let rowA = abs(a.frame.midY - origin.midY)
                let rowB = abs(b.frame.midY - origin.midY)
                if abs(rowA - rowB) > 8 { return rowA < rowB }
                return a.frame.minY < b.frame.minY
            }
        }
        return side.min { a, b in
            let distanceA = verticalGap(a.frame, origin)
            let distanceB = verticalGap(b.frame, origin)
            if abs(distanceA - distanceB) > 8 { return distanceA < distanceB }
            let gapA = columnGap(a.frame, origin, right: right)
            let gapB = columnGap(b.frame, origin, right: right)
            if abs(gapA - gapB) > 8 { return gapA < gapB }
            return a.frame.minY < b.frame.minY
        }
    }

    /// 纵向遥控：正下方最近的一行；同行内遵循从左到右。到底即停，不换行、不翻页。
    private static func downward(_ origin: CGRect, in placements: [MagazinePlacement]) -> MagazinePlacement? {
        let strictlyBelow = placements.filter { item in
            let deltaY = item.frame.midY - origin.midY
            let overlapX = min(origin.maxX, item.frame.maxX) - max(origin.minX, item.frame.minX)
            return deltaY > 1 && overlapX > 0 && item.frame.minY >= origin.minY + 4
        }
        if !strictlyBelow.isEmpty {
            return strictlyBelow.min { a, b in
                if abs(a.frame.minY - b.frame.minY) > 8 {
                    return a.frame.minY < b.frame.minY
                }
                return a.frame.minX < b.frame.minX
            }
        }
        let anyBelow = placements.filter { item in
            item.frame.minY >= origin.maxY - 8 && item.frame.midY > origin.midY + 1
        }
        if !anyBelow.isEmpty {
            return anyBelow.min { a, b in
                if abs(a.frame.minY - b.frame.minY) > 8 {
                    return a.frame.minY < b.frame.minY
                }
                return a.frame.minX < b.frame.minX
            }
        }
        return nil
    }

    /// 纵向遥控：正上方最近的一行。到顶即停。
    private static func upward(_ origin: CGRect, in placements: [MagazinePlacement]) -> MagazinePlacement? {
        let strictlyAbove = placements.filter { item in
            let deltaY = origin.midY - item.frame.midY
            let overlapX = min(origin.maxX, item.frame.maxX) - max(origin.minX, item.frame.minX)
            return deltaY > 1 && overlapX > 0 && item.frame.maxY <= origin.maxY - 4
        }
        if !strictlyAbove.isEmpty {
            return strictlyAbove.min { a, b in
                if abs(a.frame.maxY - b.frame.maxY) > 8 {
                    return a.frame.maxY > b.frame.maxY
                }
                return a.frame.minX < b.frame.minX
            }
        }
        let anyAbove = placements.filter { item in
            item.frame.maxY <= origin.minY + 8 && item.frame.midY < origin.midY - 1
        }
        if !anyAbove.isEmpty {
            return anyAbove.min { a, b in
                if abs(a.frame.maxY - b.frame.maxY) > 8 {
                    return a.frame.maxY > b.frame.maxY
                }
                return a.frame.minX < b.frame.minX
            }
        }
        return nil
    }

    private static func verticalOverlap(_ rect: CGRect, _ origin: CGRect) -> CGFloat {
        min(origin.maxY, rect.maxY) - max(origin.minY, rect.minY)
    }

    private static func verticalGap(_ rect: CGRect, _ origin: CGRect) -> CGFloat {
        max(rect.minY - origin.maxY, origin.minY - rect.maxY, 0)
    }

    private static func columnGap(_ rect: CGRect, _ origin: CGRect, right: Bool) -> CGFloat {
        right ? rect.minX - origin.maxX : origin.minX - rect.maxX
    }
}

#if os(macOS)
/// 仅监听本窗口的杂志舞台；空白点击和横向触控板手势不覆盖文章控件。
struct MagazineInputRegion: NSViewRepresentable {
    let active: Bool
    let articleFrames: [CGRect]
    let onArticleDown: (CGRect) -> Void
    let onTurn: (Int) -> Void
    let onClear: () -> Void
    let onEdge: (Int) -> Void
    let onSwipe: (CGFloat, CGFloat, Bool, Bool) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.input = self
        if !active { view.resetInteraction() }
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.stop() }
    final class Surface: NSView {
        var input: MagazineInputRegion?
        var monitor: Any?
        var down: CGPoint?
        var distance: CGFloat = 0
        var consumed = false
        var lastWheel: TimeInterval = 0
        var velocity: CGFloat = 0
        var wheelEnd: Task<Void, Never>?
        var hoverEdge = 0
        var lastWheelTurnTime: TimeInterval = -1
        var accumulatedWheelDelta: CGFloat = 0
        var verticalSwipeActive = false
        var verticalSwipeDelta: CGFloat = 0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .mouseMoved, .mouseExited]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }
        func resetInteraction() {
            wheelEnd?.cancel(); wheelEnd = nil
            if consumed { input?.onSwipe(distance, 0, true, true) }
            consumed = false
            down = nil
            distance = 0; velocity = 0; lastWheel = 0
            accumulatedWheelDelta = 0
            verticalSwipeDelta = 0
            verticalSwipeActive = false
            if hoverEdge != 0 { hoverEdge = 0; input?.onEdge(0) }
        }
        func stop() {
            resetInteraction()
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        }
        func endSwipe(cancelled: Bool = false) {
            wheelEnd?.cancel(); wheelEnd = nil
            guard consumed else { return }
            input?.onSwipe(distance, velocity, true, cancelled)
            consumed = false
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let input, input.active, event.window === window || (event.window == nil && window != nil),
                  window?.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return event }
            let point: CGPoint
            if event.window != nil {
                point = convert(event.locationInWindow, from: nil)
            } else if let window {
                let windowPoint = window.convertPoint(fromScreen: event.locationInWindow)
                let localPoint = convert(windowPoint, from: nil)
                point = bounds.contains(localPoint) ? localPoint : CGPoint(x: bounds.midX, y: bounds.midY)
            } else {
                return event
            }
            if event.type == .mouseMoved || event.type == .mouseExited {
                let margin = max(64, (bounds.width - MagazinePaginator.pageWidth(bounds.width)) / 2 + 20)
                let next = bounds.contains(point) && event.type != .mouseExited
                    ? (point.x < margin ? -1 : (point.x > bounds.width - margin ? 1 : 0)) : 0
                if hoverEdge != next { hoverEdge = next; input.onEdge(next) }
                return event
            }
            if event.type == .scrollWheel && consumed && (event.phase.contains(.ended) || event.phase.contains(.cancelled)) {
                endSwipe(cancelled: event.phase.contains(.cancelled)); return nil
            }
            guard bounds.contains(point), point.y < bounds.height - MagazinePaginator.railHeight else { return event }
            let article = input.articleFrames.first { $0.contains(point) }
            if event.type == .leftMouseDown {
                down = point
                if let article { input.onArticleDown(convert(article, to: nil)) }
            } else if event.type == .leftMouseUp {
                defer { down = nil }
                guard let down, hypot(point.x - down.x, point.y - down.y) < 6,
                      article == nil, !input.articleFrames.contains(where: { $0.contains(down) }) else { return event }
                let paperWidth = MagazinePaginator.pageWidth(bounds.width)
                let paperLeft = (bounds.width - paperWidth) / 2
                if point.x < paperLeft + paperWidth / 3 { input.onTurn(-1); return nil }
                if point.x > paperLeft + paperWidth * 2 / 3 { input.onTurn(1); return nil }
                input.onClear()
            } else if event.type == .scrollWheel {
                let isPrecise = event.hasPreciseScrollingDeltas
                let deltaX = event.scrollingDeltaX
                let rawY = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : (event.deltaY * 10)
                let rawX = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : (event.deltaX * 10)

                if isPrecise && (consumed || abs(deltaX) > abs(rawY) * 1.3) {
                    // 手指离开即按最后速度结算；系统后续惯性事件不再触发第二页。
                    guard event.momentumPhase.isEmpty else { return consumed ? nil : event }
                    if event.phase.contains(.began) || event.timestamp - lastWheel > 0.3 {
                        endSwipe(cancelled: true)
                        distance = 0; velocity = 0
                    }
                    let deltaTime = max(0.008, min(0.05, event.timestamp - lastWheel))
                    lastWheel = event.timestamp
                    distance += event.scrollingDeltaX
                    velocity = velocity * 0.3 + event.scrollingDeltaX / deltaTime * 0.7
                    if abs(distance) > 12 || consumed {
                        consumed = true
                        input.onSwipe(distance, velocity, false, false)
                        wheelEnd?.cancel()
                        wheelEnd = Task { @MainActor [weak self] in
                            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                            self?.endSwipe()
                        }
                    }
                    return nil
                } else if !consumed {
                    // 鼠标滚轮（常规/高精度）滚动切换上下页
                    let effectiveDelta = abs(rawY) >= abs(rawX) ? rawY : rawX
                    if isPrecise {
                        guard event.momentumPhase.isEmpty else { return event }
                        if event.phase.contains(.began) || event.timestamp - lastWheelTurnTime > 0.35 {
                            verticalSwipeActive = true
                            verticalSwipeDelta = 0
                        }
                        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                            verticalSwipeActive = false
                            verticalSwipeDelta = 0
                        }
                        if verticalSwipeActive || !event.phase.isEmpty {
                            verticalSwipeDelta += effectiveDelta
                            if abs(verticalSwipeDelta) >= 24, event.timestamp - lastWheelTurnTime > 0.32 {
                                let direction = verticalSwipeDelta < 0 ? 1 : -1
                                lastWheelTurnTime = event.timestamp
                                verticalSwipeActive = false
                                verticalSwipeDelta = 0
                                input.onTurn(direction)
                                return nil
                            }
                        }
                    } else {
                        // 机械鼠标滚轮滚动
                        if event.timestamp - lastWheelTurnTime > 0.35 {
                            accumulatedWheelDelta = 0
                        }
                        accumulatedWheelDelta += effectiveDelta
                        if abs(accumulatedWheelDelta) >= 1.0, event.timestamp - lastWheelTurnTime > 0.25 {
                            let direction = accumulatedWheelDelta < 0 ? 1 : -1
                            lastWheelTurnTime = event.timestamp
                            accumulatedWheelDelta = 0
                            input.onTurn(direction)
                            return nil
                        }
                    }
                }
            }
            return event
        }
    }
}
#endif
