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

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let count = max(1, columns)
        let columnWidth = max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let spans = subviews.map { min(count, max(1, $0[MagazineColumnSpan.self])) }
        let heights = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: columnWidth * CGFloat(spans[index])
                + spacing * CGFloat(spans[index] - 1), height: nil)).height
        }
        return Self.frames(width: width, columns: count, spacing: spacing, heights: heights, spans: spans)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, rect) in frames(width: bounds.width, subviews: subviews).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

/// Local page-only hinge effect. No screen capture, lid sensors, private APIs or
/// continuous rendering loop. The two halves shade toward their common crease.
struct MagazineFoldEffect: ViewModifier, Animatable, Sendable {
    // SwiftUI's interpolation contract is nonisolated. These Sendable value
    // fields have no UI state; only body(content:) needs main-actor isolation.
    nonisolated var progress: CGFloat
    nonisolated let direction: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let amount = min(1, max(0, progress))
        content.opacity(amount < 0.001 ? 1 : 0)
            .overlay {
                if amount >= 0.001 {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            half(content, size: geometry.size, leading: true, amount: amount)
                            half(content, size: geometry.size, leading: false, amount: amount)
                        }
                        .scaleEffect(1 - amount * 0.035)
                        .offset(x: direction * amount * geometry.size.width * 0.12)
                        .opacity(1 - amount)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
    private func half(_ content: Content, size: CGSize, leading: Bool, amount: CGFloat) -> some View {
        content.frame(width: size.width, height: size.height, alignment: .top)
            .frame(width: size.width / 2, height: size.height, alignment: leading ? .leading : .trailing)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.20 * amount)],
                                    startPoint: leading ? .leading : .trailing,
                                    endPoint: leading ? .trailing : .leading))
            .rotation3DEffect(.degrees(Double(amount * (leading ? -78 : 78))),
                              axis: (x: 0, y: 1, z: 0), anchor: leading ? .trailing : .leading,
                              perspective: 0.32)
    }
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
    @State private var hoveredPage: String?
    @State private var turnDirection: CGFloat = 1
    @State private var pendingNext = false
    @State private var isTurning = false
    @State private var turnTask: Task<Void, Never>?

    private var metrics: TimelineLayoutMetrics { .init(availableWidth: availableSize.width) }
    private var arrangement: MagazineArrangement { .init(rawValue: arrangementRaw) ?? .balanced }
    private var turning: MagazineTurning { .init(rawValue: turningRaw) ?? .scroll }
    private var capacity: Int {
        // Keep normal-size pages short enough to fit a laptop. Overflow still
        // scrolls within a page at large accessibility sizes; it is never clipped.
        let rows = availableSize.height > 950 ? 3 : 2
        return max(3, metrics.galleryColumns * rows)
    }
    private var pages: [MagazinePage] {
        MagazineEdition.pages(entries: entries, arrangement: arrangement, folders: folders, capacity: capacity)
    }
    private var pageIndex: Int { MagazineEdition.pageIndex(containing: memory.magazineAnchor, in: pages) }
    private var pageIDs: [String] { pages.map(\.id) }

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
                    ZStack(alignment: .top) {
                        if pages.indices.contains(pageIndex) {
                            let page = pages[pageIndex]
                            ScrollView {
                                pageContent(page, index: pageIndex)
                                    .padding(.vertical, 20)
                                    .frame(maxWidth: .infinity, alignment: .top)
                            }
                            .scrollIndicators(.never)
                            .id(page.id)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .modifier(active: MagazineFoldEffect(progress: 1, direction: -turnDirection),
                                                     identity: MagazineFoldEffect(progress: 0, direction: -turnDirection)),
                                removal: .modifier(active: MagazineFoldEffect(progress: 1, direction: turnDirection),
                                                   identity: MagazineFoldEffect(progress: 0, direction: turnDirection))))
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
            .safeAreaInset(edge: .bottom, spacing: 0) { pageRail(proxy: proxy) }
            .onPreferenceChange(MagazinePageFrames.self) { frames in
                guard isBrowsing, turning == .scroll, !memory.isRestoring else { return }
                if let page = pages.first(where: { (frames[$0.id]?.maxY ?? -1) > 24 && (frames[$0.id]?.minY ?? .infinity) < availableSize.height }) {
                    if let anchor = page.entries.first?.id { memory.magazineAnchor = anchor }
                }
            }
            .onChange(of: pageIDs) { _, _ in
                if pendingNext {
                    pendingNext = false
                    go(to: pageIndex + 1, proxy: proxy)
                }
                restore(proxy: proxy)
            }
            .task(id: turningRaw) {
                // Wait for the destination scroll container to exist before
                // restoring its anchor when switching reading styles.
                await Task.yield()
                guard !Task.isCancelled else { return }
                restore(proxy: proxy)
            }
            .onChange(of: hasMore) { _, value in if !value { pendingNext = false } }
            .onChange(of: arrangementRaw) { _, _ in restore(proxy: proxy) }
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
            .onDisappear { turnTask?.cancel(); isTurning = false }
            .onChange(of: isBrowsing) { _, value in if !value { turnTask?.cancel(); isTurning = false } }
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

    private func pageRail(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            Button { go(to: pageIndex - 1, proxy: proxy) } label: { Image(systemName: "chevron.left") }
                .disabled(pageIndex == 0 || isTurning)
                .help(I18N.localized("上一页"))
                .accessibilityIdentifier("magazine.previousPage")
            ScrollViewReader { rail in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            Button { go(to: index, proxy: proxy) } label: {
                                Capsule().fill(Color(paperHex: index == pageIndex ? palette.accentHex : palette.mutedHex)
                                    .opacity(index == pageIndex ? 1 : 0.3))
                                    .frame(width: index == pageIndex ? 26 : 12, height: 4)
                                    .frame(width: index == pageIndex ? 34 : 22, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .id(page.id)
                            .onHover { hoveredPage = $0 ? page.id : (hoveredPage == page.id ? nil : hoveredPage) }
                            .accessibilityLabel("\(I18N.localized("页面")) \(index + 1): \(page.title)")
                            .accessibilityHint(page.entries.map(\.title).joined(separator: "; "))
                            .accessibilityAddTraits(index == pageIndex ? [.isSelected] : [])
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxWidth: 380)
                .onChange(of: pageIndex) { _, index in
                    if pages.indices.contains(index) { rail.scrollTo(pages[index].id, anchor: .center) }
                }
            }
            Button { go(to: pageIndex + 1, proxy: proxy) } label: { Image(systemName: "chevron.right") }
                .disabled((pageIndex + 1 >= pages.count && !hasMore) || isTurning)
                .help(I18N.localized("下一页"))
                .accessibilityIdentifier("magazine.nextPage")
            Text(pages.isEmpty ? "0 / 0" : "\(pageIndex + 1) / \(pages.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.35) }
        .overlay(alignment: .bottom) {
            if let page = pages.first(where: { $0.id == hoveredPage }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.title).font(.headline)
                    ForEach(page.entries) { entry in
                        Text(entry.title).font(.caption).lineLimit(2)
                    }
                }
                .padding(14).frame(width: min(340, max(180, availableSize.width - 48)), alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .offset(y: -60).allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func go(to index: Int, proxy: ScrollViewProxy) {
        guard isBrowsing, !isTurning, index >= 0 else { return }
        if index >= pages.count {
            if hasMore { pendingNext = true; onNeedMore() }
            return
        }
        guard let anchor = pages[index].entries.first?.id else { return }
        if index == pageIndex && turning == .fold { return }
        hoveredPage = nil
        turnDirection = index >= pageIndex ? 1 : -1
        memory.visibleAnchor = anchor
        let duration = reduceMotion ? 0.12 : 0.42
        if turning == .fold {
            isTurning = true
            withAnimation(.easeInOut(duration: duration)) { memory.magazineAnchor = anchor }
            turnTask?.cancel()
            turnTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                isTurning = false
            }
        } else {
            memory.magazineAnchor = anchor
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(pages[index].id, anchor: .top) }
        }
    }

    private func restore(proxy: ScrollViewProxy, anchor: String? = nil) {
        let anchor = anchor ?? memory.magazineAnchor
        let index = MagazineEdition.pageIndex(containing: anchor, in: pages)
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
            let index = MagazineEdition.pageIndex(containing: target.id, in: pages)
            if index != pageIndex { go(to: index, proxy: proxy) }
            else if turning == .scroll { proxy.scrollTo(target.id, anchor: .center) }
        } else if [36, 49, 76].contains(request.keyCode) {
            onOpen(ordered.first { $0.id == selectedID } ?? pages[pageIndex].entries[0])
        }
    }
}
