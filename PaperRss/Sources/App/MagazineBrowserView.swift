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
        var viewport: CGSize? = nil
        var showsImages: Bool = true
    }
    @Published private(set) var pages: [MagazinePage] = []
    @Published private(set) var layouts: [String: MagazinePageLayout] = [:]
    private var input: Input?
    private var entryIndex: [String: Int] = [:]
    private(set) var rebuildCount = 0

    func update(_ input: Input) {
        guard self.input != input else { return }
        let previous = self.input
        self.input = input
        let next: [MagazinePage]
        if let size = input.viewport {
            let keepsGeometry = previous.map {
                $0.viewport == input.viewport && $0.showsImages == input.showsImages
                    && $0.arrangement == input.arrangement && $0.folders == input.folders && $0.locale == input.locale
                    && $0.entries.count <= input.entries.count
                    && zip($0.entries, input.entries).allSatisfy { old, new in
                        old.id == new.id && old.title == new.title && old.summaryPreview == new.summaryPreview
                            && old.sourceTitle == new.sourceTitle && old.feedID == new.feedID
                    }
            } ?? false
            let retained = keepsGeometry ? pages.compactMap { layouts[$0.id] } : []
            let start = keepsGeometry ? (previous?.entries.count ?? 0) : 0
            let retainedIDs = Set(retained.flatMap { $0.page.entries.map(\.id) })
            let additions = MagazinePaginator.pages(entries: input.entries.dropFirst(start).filter { !retainedIDs.contains($0.id) },
                folders: input.folders, arrangement: input.arrangement, size: size, showsImages: input.showsImages)
            let fresh = Dictionary(input.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let resolved = (retained + additions).map { layout in
                MagazinePageLayout(page: MagazinePage(id: layout.page.id, title: layout.page.title,
                    entries: layout.page.entries.compactMap { fresh[$0.id] }),
                    placements: layout.placements, height: layout.height)
            }
            layouts = Dictionary(resolved.map { ($0.page.id, $0) }, uniquingKeysWith: { first, _ in first })
            next = resolved.map(\.page)
        } else {
            layouts = [:]
            next = MagazineEdition.pages(entries: input.entries, arrangement: input.arrangement,
                                         folders: input.folders, capacity: input.capacity)
        }
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
    @State private var turnSourceAnchor: String?
    @GestureState private var isDraggingPage = false
    private var isTurning: Bool { turnRequest != nil }
    private var contentWidth: CGFloat { MagazinePaginator.contentWidth(availableSize.width) }

    private var arrangement: MagazineArrangement { .init(rawValue: arrangementRaw) ?? .balanced }
    private var turning: MagazineTurning { .init(rawValue: turningRaw) ?? .scroll }
    private var editionInput: MagazineEditionCache.Input {
        .init(entries: entries, folders: folders, arrangement: arrangement, capacity: 12,
              locale: locale.identifier, viewport: availableSize, showsImages: showsImages)
    }
    private var pages: [MagazinePage] { edition.pages }
    private var pageIndex: Int {
        if let request = turnRequest, let target = pages.firstIndex(where: { $0.id == request.targetPageID }) { return target }
        return edition.pageIndex(containing: memory.magazineAnchor)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if turning == .scroll {
                    ScrollView {
                        LazyVStack(spacing: 40) {
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
                            MagazinePageTurnView(pageID: page.id, request: turnRequest,
                                reduceMotion: reduceMotion, isActive: isBrowsing,
                                background: NSColor(Color(paperHex: palette.backgroundHex)),
                                content: pageContent(page, index: pageIndex)
                                    .padding(.vertical, 20)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                    .background(Color(paperHex: palette.backgroundHex))
                                    .environment(\.paperAppearancePalette, palette)
                                    .environment(\.colorScheme, colorScheme)
                                    .environment(\.locale, locale),
                                onComplete: { id, committed in
                                    guard turnRequest?.id == id else { return }
                                    if committed {
                                        memory.magazineAnchor = pages.first(where: { $0.id == turnRequest?.targetPageID })?.entries.first?.id
                                    } else {
                                        memory.magazineAnchor = turnSourceAnchor
                                    }
                                    memory.visibleAnchor = memory.magazineAnchor
                                    turnRequest = nil
                                    turnSourceAnchor = nil
                                })
                        }
                    }
                    .frame(width: contentWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .simultaneousGesture(DragGesture(minimumDistance: 20)
                        .updating($isDraggingPage) { _, active, _ in active = true }
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                            if turnRequest == nil {
                                go(to: pageIndex + (value.translation.width < 0 ? 1 : -1), proxy: proxy, interactive: true)
                            }
                            guard var request = turnRequest, request.progress != nil else { return }
                            let distance = value.translation.width * (request.forward ? -1 : 1)
                            request.progress = min(1, max(0, distance / (contentWidth * 0.65)))
                            turnRequest = request
                        }
                        .onEnded { value in
                            guard var request = turnRequest, request.progress != nil else { return }
                            let predicted = value.predictedEndTranslation.width * (request.forward ? -1 : 1)
                            request.commit = (request.progress ?? 0) > 0.4 || predicted > contentWidth * 0.35
                            request.progress = nil
                            turnRequest = request
                        })
                    .onChange(of: isDraggingPage) { _, active in
                        // 系统取消手势时不会调用 onEnded，但 GestureState 必定复位。
                        guard !active, var request = turnRequest, let progress = request.progress else { return }
                        request.commit = progress > 0.4
                        request.progress = nil
                        turnRequest = request
                    }
                }
            }
            .coordinateSpace(name: "magazine-viewport")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !pages.isEmpty {
                    MagazinePageRail(pages: pages, currentIndex: pageIndex, hasMore: hasMore,
                        isTurning: isTurning, availableWidth: availableSize.width,
                        availableHeight: availableSize.height, onSelect: { go(to: $0, proxy: proxy) })
                }
            }
            .onPreferenceChange(MagazinePageFrames.self) { frames in
                guard isBrowsing, turning == .scroll, !memory.isRestoring else { return }
                if let page = pages.first(where: { (frames[$0.id]?.maxY ?? -1) > 24 && (frames[$0.id]?.minY ?? .infinity) < availableSize.height }) {
                    if let anchor = page.entries.first?.id { memory.magazineAnchor = anchor }
                }
            }
            .onChange(of: editionInput, initial: true) { old, new in
                let hadAnchor = edition.contains(memory.magazineAnchor)
                cancelTurn()
                edition.update(new)
                if let pending = pendingPageIndex, pages.indices.contains(pending) {
                    pendingPageIndex = nil
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
                cancelTurn()
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
            .onDisappear { cancelTurn() }
            .onChange(of: isBrowsing) { _, value in if !value { cancelTurn() } }
            .onChange(of: availableSize) { _, _ in cancelTurn() }
            .onChange(of: showsImages) { _, _ in cancelTurn() }
        }
        .accessibilityIdentifier("magazine.browser")
    }

    private func cancelTurn() {
        if turnRequest != nil, let anchor = turnSourceAnchor { memory.magazineAnchor = anchor }
        turnRequest = nil
        turnSourceAnchor = nil
    }

    private func pageContent(_ page: MagazinePage, index: Int) -> some View {
        let layout = edition.layouts[page.id]
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.title).font(.system(size: 15, weight: .semibold, design: .serif))
                Spacer()
                Text(String(format: "%02d", index + 1)).font(.system(size: 11))
                    .foregroundStyle(Color(paperHex: palette.mutedHex))
            }.frame(height: 20)
            ZStack(alignment: .topLeading) {
                if let layout {
                    ForEach(Array(zip(page.entries, layout.placements)), id: \.0.id) { entry, placement in
                        tile(entry, placement.frame.width, .gallery)
                            .environment(\.magazineStoryStyle, placement.style)
                            .frame(width: placement.frame.width, height: placement.frame.height, alignment: .topLeading)
                            .clipped()
                            .overlay(alignment: .top) {
                                if placement.frame.minY > 0 {
                                    Rectangle().fill(Color(paperHex: palette.mutedHex).opacity(0.18))
                                        .frame(height: 0.5).offset(y: -16)
                                }
                            }
                            .offset(x: placement.frame.minX, y: placement.frame.minY)
                    }
                }
            }
            .frame(width: contentWidth, height: layout?.height ?? 0, alignment: .topLeading)
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .foregroundStyle(Color(paperHex: palette.inkHex))
    }

    private func go(to index: Int, proxy: ScrollViewProxy, interactive: Bool = false) {
        guard isBrowsing, !isTurning, index >= 0 else { return }
        if index >= pages.count {
            if hasMore { pendingPageIndex = index; onNeedMore() }
            return
        }
        guard let anchor = pages[index].entries.first?.id else { return }
        if index == pageIndex && turning == .fold { return }
        if turning == .fold {
            turnSourceAnchor = memory.magazineAnchor
            turnRequest = .init(targetPageID: pages[index].id, forward: index > pageIndex,
                                progress: interactive ? 0 : nil)
            // 请求与目标页由同一个 State 原子切换；完成后才写回可观察锚点。
        } else {
            memory.visibleAnchor = anchor
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

    private func handle(_ request: TimelineKeyRequest, proxy: ScrollViewProxy) {
        if request.keyCode == 116 || request.keyCode == 121 {
            go(to: pageIndex + (request.keyCode == 121 ? 1 : -1), proxy: proxy)
            return
        }
        guard !isTurning else { return }
        let ordered = pages.flatMap(\.entries)
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
