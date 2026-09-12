import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

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

/// Edition grouping is independent of scroll position, hover and animation.
/// Rebuild only when actual article/folder/locale/layout inputs change.
@MainActor
final class MagazineEditionCache: ObservableObject {
    struct Input: Equatable {
        let entries: [EntryListItem]
        let folders: [UUID: String]
        let arrangement: MagazineArrangement
        let capacity: Int
        let locale: String
    }
    @Published private(set) var pages: [MagazinePage] = []
    private var input: Input?
    private var entryIndex: [String: Int] = [:]
    private(set) var rebuildCount = 0

    func update(_ input: Input) {
        guard self.input != input else { return }
        self.input = input
        let next = MagazineEdition.pages(entries: input.entries, arrangement: input.arrangement,
                                          folders: input.folders, capacity: input.capacity)
        entryIndex.removeAll(keepingCapacity: true)
        for (index, page) in next.enumerated() {
            for entry in page.entries { entryIndex[entry.id] = index }
        }
        rebuildCount += 1
        if pages != next { pages = next }
    }

    func pageIndex(containing anchor: String?) -> Int {
        anchor.flatMap { entryIndex[$0] } ?? 0
    }
    func contains(_ anchor: String?) -> Bool { anchor.flatMap { entryIndex[$0] } != nil }
}

private struct MagazinePageFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
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
    let selectedID: String?
    let keyboardRequest: TimelineKeyRequest?
    @ObservedObject var memory: TimelinePresentationMemory
    let onHighlight: (String) -> Void
    let onOpen: (EntryListItem) -> Void
    let onNeedMore: () -> Void
    let tile: (EntryListItem, CGFloat, TimelineTileLayout) -> Tile
    @AppStorage("magazine_arrangement") private var arrangementRaw = MagazineArrangement.balanced.rawValue
    @AppStorage("magazine_turning") private var turningRaw = MagazineTurning.scroll.rawValue
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @StateObject private var edition = MagazineEditionCache()
    @State private var pendingPageIndex: Int?
    @State private var turnRequest: MagazinePageTurnRequest?
    private var isTurning: Bool { turnRequest != nil }

    private var metrics: TimelineLayoutMetrics { .init(availableWidth: availableSize.width) }
    private var arrangement: MagazineArrangement { .init(rawValue: arrangementRaw) ?? .balanced }
    private var turning: MagazineTurning { .init(rawValue: turningRaw) ?? .scroll }
    private var capacity: Int {
        // Keep normal-size pages short enough to fit a laptop. Overflow still
        // scrolls within a page at large accessibility sizes; it is never clipped.
        let rows = availableSize.height > 950 ? 3 : 2
        return max(3, metrics.galleryColumns * rows)
    }
    private var editionInput: MagazineEditionCache.Input {
        .init(entries: entries, folders: folders, arrangement: arrangement, capacity: capacity, locale: locale.identifier)
    }
    private var pages: [MagazinePage] { edition.pages }
    private var pageIndex: Int { edition.pageIndex(containing: memory.magazineAnchor) }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if turning == .scroll {
                    ScrollView {
                        LazyVStack(spacing: 36) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                                pageContent(page, index: index)
                                    .id(page.id)
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: MagazinePageFrames.self,
                                            value: [page.id: geometry.frame(in: .named("magazine-viewport"))])
                                    })
                                    .onAppear { if isBrowsing && page.id == pages.last?.id && hasMore { onNeedMore() } }
                            }
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollIndicators(.never)
                } else {
                    Group {
                        if pages.indices.contains(pageIndex) {
                            let page = pages[pageIndex]
                            #if os(macOS)
                            MagazinePageTurnView(pageID: page.id, request: turnRequest,
                                reduceMotion: reduceMotion, isActive: isBrowsing,
                                background: NSColor(Color(paperHex: palette.backgroundHex)),
                                content: ScrollView {
                                    pageContent(page, index: pageIndex).padding(.vertical, 20)
                                        .frame(maxWidth: .infinity, alignment: .top)
                                }
                                .scrollIndicators(.never).id(page.id)
                                .background(Color(paperHex: palette.backgroundHex))
                                .environment(\.paperAppearancePalette, palette)
                                .environment(\.colorScheme, colorScheme)
                                .environment(\.locale, locale),
                                onComplete: { id in
                                    if turnRequest?.id == id { turnRequest = nil }
                                })
                                .frame(width: metrics.contentWidth)
                            #else
                            ScrollView { pageContent(page, index: pageIndex).padding(.vertical, 20) }
                                .id(page.id)
                            #endif
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .allowsHitTesting(!isTurning)
                    .simultaneousGesture(DragGesture(minimumDistance: 36).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        go(to: pageIndex + (value.translation.width < 0 ? 1 : -1), proxy: proxy)
                    })
                }
            }
            .coordinateSpace(name: "magazine-viewport")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MagazinePageRail(pages: pages, currentIndex: pageIndex, hasMore: hasMore,
                    isTurning: isTurning, availableWidth: availableSize.width,
                    availableHeight: availableSize.height, onSelect: { go(to: $0, proxy: proxy) })
            }
            .onPreferenceChange(MagazinePageFrames.self) { frames in
                guard isBrowsing, turning == .scroll, !memory.isRestoring else { return }
                if let page = pages.first(where: { (frames[$0.id]?.maxY ?? -1) > 24 && (frames[$0.id]?.minY ?? .infinity) < availableSize.height }) {
                    if let anchor = page.entries.first?.id { memory.magazineAnchor = anchor }
                }
            }
            .onChange(of: editionInput, initial: true) { old, new in
                let hadAnchor = edition.contains(memory.magazineAnchor)
                edition.update(new)
                turnRequest = nil
                if let pending = pendingPageIndex, pages.indices.contains(pending) {
                    pendingPageIndex = nil
                    go(to: pending, proxy: proxy)
                } else if old.arrangement != new.arrangement || old.capacity != new.capacity
                            || old.locale != new.locale || !hadAnchor || !edition.contains(memory.magazineAnchor) {
                    restore(proxy: proxy)
                }
                // Appending data / read state updates must not scroll back to
                // the page's top while the user is reading its lower half.
            }
            .task(id: turningRaw) {
                // Wait for the destination scroll container to exist before
                // restoring its anchor when switching reading styles.
                turnRequest = nil
                await Task.yield()
                guard !Task.isCancelled else { return }
                restore(proxy: proxy)
            }
            .onChange(of: hasMore) { _, value in if !value { pendingPageIndex = nil } }
            .onChange(of: keyboardRequest) { _, request in
                guard isBrowsing, let request else { return }
                handle(request, proxy: proxy)
            }
            .task(id: memory.restorationID) {
                guard isBrowsing else { return }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                restore(proxy: proxy, anchor: memory.restoreAnchor)
                memory.finishRestoration()
            }
            .onDisappear { turnRequest = nil }
            .onChange(of: isBrowsing) { _, value in if !value { turnRequest = nil } }
            .onChange(of: availableSize) { _, _ in turnRequest = nil }
            .onChange(of: showsImages) { _, _ in turnRequest = nil }
        }
        .accessibilityIdentifier("magazine.browser")
    }

    private func pageContent(_ page: MagazinePage, index: Int) -> some View {
        let columns = metrics.galleryColumns
        let featured = page.featuredID(showsImages: showsImages)
        // A layout highlight is a presentation decision, never a database sort.
        let ordered = displayedEntries(in: page)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.title).font(.system(size: 15, weight: .semibold, design: .serif))
                Spacer()
                Text(String(format: "%02d", index + 1)).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(paperHex: palette.mutedHex))
            }
            Rectangle().fill(Color(paperHex: palette.mutedHex).opacity(0.23)).frame(height: 0.6)
            MagazineMasonryLayout(columns: columns, spacing: TimelineLayoutMetrics.spacing) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { offset, entry in
                    let span = entry.id == featured && columns >= 3 && arrangement != .chronological ? 2 : 1
                    let width = metrics.galleryTileWidth * CGFloat(span) + TimelineLayoutMetrics.spacing * CGFloat(span - 1)
                    let isSupporting = featured != nil && columns >= 3 && offset > 0 && offset <= 2
                        && arrangement != .chronological
                    let role: TimelineTileLayout = span > 1 ? .lead :
                        (isSupporting ? .supporting : (columns == 1 ? .compact : .gallery))
                    tile(entry, width, role).layoutValue(key: MagazineColumnSpan.self, value: span)
                }
            }
        }
        .frame(width: metrics.contentWidth, alignment: .topLeading)
        .foregroundStyle(Color(paperHex: palette.inkHex))
    }

    private func go(to index: Int, proxy: ScrollViewProxy) {
        guard isBrowsing, !isTurning, index >= 0 else { return }
        if index >= pages.count {
            if hasMore { pendingPageIndex = index; onNeedMore() }
            return
        }
        guard let anchor = pages[index].entries.first?.id else { return }
        if index == pageIndex && turning == .fold { return }
        memory.visibleAnchor = anchor
        if turning == .fold {
            #if os(macOS)
            turnRequest = .init(targetPageID: pages[index].id, forward: index >= pageIndex)
            #endif
            // The native host freezes the old viewport before replacing its
            // content; only the leaf textures animate, not this view hierarchy.
            memory.magazineAnchor = anchor
        } else {
            memory.magazineAnchor = anchor
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(pages[index].id, anchor: .top) }
        }
    }

    private func restore(proxy: ScrollViewProxy, anchor: String? = nil) {
        let anchor = anchor ?? memory.magazineAnchor
        let index = edition.pageIndex(containing: anchor)
        guard pages.indices.contains(index) else { return }
        let validAnchor = anchor.flatMap { value in pages[index].entries.contains { $0.id == value } ? value : nil }
        memory.magazineAnchor = validAnchor ?? pages[index].entries.first?.id
        if turning == .scroll { proxy.scrollTo(pages[index].id, anchor: .top) }
    }

    private func displayedEntries(in page: MagazinePage) -> [EntryListItem] {
        guard arrangement != .chronological, let featured = page.featuredID(showsImages: showsImages) else {
            return page.entries
        }
        return page.entries.filter { $0.id == featured } + page.entries.filter { $0.id != featured }
    }

    private func handle(_ request: TimelineKeyRequest, proxy: ScrollViewProxy) {
        if request.keyCode == 116 || request.keyCode == 121 {
            go(to: pageIndex + (request.keyCode == 121 ? 1 : -1), proxy: proxy)
            return
        }
        guard !isTurning else { return }
        let ordered = pages.flatMap { displayedEntries(in: $0) }
        guard !ordered.isEmpty else { return }
        if request.keyCode == 125 || request.keyCode == 126 {
            let current = ordered.firstIndex { $0.id == selectedID }
            let next = current.map { $0 + (request.keyCode == 125 ? 1 : -1) } ?? 0
            let target = ordered[min(ordered.count - 1, max(0, next))]
            onHighlight(target.id)
            let index = edition.pageIndex(containing: target.id)
            if index != pageIndex { go(to: index, proxy: proxy) }
            else if turning == .scroll { proxy.scrollTo(target.id, anchor: .center) }
        } else if [36, 49, 76].contains(request.keyCode) {
            onOpen(ordered.first { $0.id == selectedID } ?? pages[pageIndex].entries[0])
        }
    }
}
