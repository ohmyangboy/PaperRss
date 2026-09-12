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
    var onFocusSidebar: () -> Void = {}
    var coverTitle: String = ""
    var onClearSelection: () -> Void = {}
    let tile: (EntryListItem, CGFloat, TimelineTileLayout) -> Tile
    @AppStorage("magazine_arrangement") private var arrangementRaw = MagazineArrangement.balanced.rawValue
    @AppStorage("magazine_turning") private var turningRaw = MagazineTurning.scroll.rawValue
    @AppStorage("magazine_page_sound") private var pageSoundEnabled = false
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @StateObject private var edition = MagazineEditionCache()
    @State private var coverAnimating = false
    @State private var autoOpenedScope: UUID?
    @State private var edge: Int = 0
    @State private var notice: String?
    @State private var noticeID = UUID()
    @State private var pendingPageIndex: Int?
    @State private var turnRequest: MagazinePageTurnRequest?
    @State private var turnSourceAnchor: String?
    @GestureState private var isDraggingPage = false
    private var isTurning: Bool { turnRequest != nil }
    private var paperWidth: CGFloat { MagazinePaginator.pageWidth(availableSize.width) }
    private var turnInset: CGFloat { MagazinePaginator.turnInset(availableSize) }
    private var stageBackground: NSColor {
        NSColor(Color(paperHex: palette.backgroundHex)).blended(withFraction: palette.colorScheme == .dark ? 0.035 : 0.065,
            of: NSColor(Color(paperHex: palette.inkHex))) ?? .windowBackgroundColor
    }
    // 深色纸面略亮于舞台，并沿用主题墨色混合，保留 Tokyo Night 的蓝灰色相。
    private var paperBackground: Color {
        let base = NSColor(Color(paperHex: palette.backgroundHex))
        guard palette.colorScheme == .dark else { return Color(nsColor: base) }
        return Color(nsColor: base.blended(withFraction: 0.065,
            of: NSColor(Color(paperHex: palette.inkHex))) ?? base)
    }
    private var contentWidth: CGFloat { MagazinePaginator.contentWidth(availableSize.width) }

    private var arrangement: MagazineArrangement { .init(rawValue: arrangementRaw) ?? .balanced }
    private var turning: MagazineTurning { .init(rawValue: turningRaw) ?? .scroll }
    private var editionInput: MagazineEditionCache.Input {
        .init(entries: entries, folders: folders, arrangement: arrangement, capacity: 12,
              locale: locale.identifier, viewport: turning != .scroll ? MagazinePaginator.foldViewport(availableSize) : availableSize,
              showsImages: showsImages)
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
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollIndicators(.never)
                } else {
                    Group {
                        if pages.indices.contains(pageIndex) {
                            let page = pages[pageIndex]
                            MagazinePageTurnView(pageID: page.id, request: turnRequest,
                                reduceMotion: reduceMotion, isActive: isBrowsing && memory.magazineIsOpen,
                                background: stageBackground, verticalInset: turnInset, playsSound: pageSoundEnabled, fades: turning == .fade,
                                content: pageContent(page, index: pageIndex)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                    .background {
                                        paperBackground
                                            .overlay {
                                                LinearGradient(colors: [.clear,
                                                    Color(paperHex: palette.inkHex).opacity(0.035), .clear],
                                                    startPoint: .leading, endPoint: .trailing)
                                                    .frame(width: 12)
                                                    .overlay {
                                                        Rectangle().fill(Color(paperHex: palette.inkHex).opacity(0.035))
                                                            .frame(width: 0.5)
                                                    }
                                            }
                                    }
                                    .overlay(Rectangle().strokeBorder(Color(paperHex: palette.inkHex).opacity(0.14), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(palette.colorScheme == .dark ? 0.16 : 0.08), radius: 10, x: 0, y: 3)
                                    .padding(.vertical, turnInset)
                                    .background(Color(nsColor: stageBackground))
                                    .environment(\.paperAppearancePalette, palette)
                                    .environment(\.colorScheme, colorScheme)
                                    .environment(\.locale, locale)
                                    .highPriorityGesture(pageDrag(proxy: proxy)),
                                onComplete: { id, committed in
                                    guard turnRequest?.id == id else { return }
                                    if committed {
                                        memory.magazineAnchor = pages.first(where: { $0.id == turnRequest?.targetPageID })?.entries.first?.id
                                    } else {
                                        memory.magazineAnchor = turnSourceAnchor
                                    }
                                    memory.visibleAnchor = memory.magazineAnchor
                                    if committed && pageIndex == pages.count - 1 && !hasMore { showEndNotice() }
                                    turnRequest = nil
                                    turnSourceAnchor = nil
                                })
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(alignment: .trailing) {
                Rectangle().frame(width: coverAnimating && !reduceMotion ? availableSize.width / 2 : availableSize.width)
            }
            .offset(x: !memory.magazineIsOpen && !reduceMotion ? -paperWidth / 4 : 0)
            .opacity(memory.magazineIsOpen ? 1 : 0)
            .allowsHitTesting(memory.magazineIsOpen && !coverAnimating)
            .accessibilityHidden(!memory.magazineIsOpen)
            .overlay {
                if !memory.magazineIsOpen || coverAnimating { bookCover }
                if memory.magazineIsOpen && pages.isEmpty {
                    Text(I18N.shared.localized("暂无文章", "No articles")).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if memory.magazineIsOpen && turning != .scroll && !coverAnimating {
                    HStack {
                        edgeButton(-1, proxy: proxy)
                        Spacer(minLength: 0)
                        edgeButton(1, proxy: proxy)
                    }.padding(.horizontal, max(6, (availableSize.width - paperWidth) / 2 - 42))
                }
            }
            .background {
                if turning != .scroll {
                    MagazineInputRegion(active: isBrowsing && memory.magazineIsOpen && !coverAnimating, articleFrames: articleFrames,
                        onArticleDown: { memory.openingFrameInWindow = $0 },
                        onTurn: { onClearSelection(); go(to: pageIndex + $0, proxy: proxy) },
                        onClear: onClearSelection, onEdge: { if edge != $0 { edge = $0 } },
                        onSwipe: { distance, velocity, ended, cancelled in
                            if turnRequest == nil && !ended {
                                go(to: pageIndex + (distance < 0 ? 1 : -1), proxy: proxy, interactive: true)
                            }
                            guard var request = turnRequest, request.progress != nil else { return }
                            let sign = request.forward ? -1.0 : 1.0
                            let progress = min(1, max(0, distance * sign / (contentWidth * 0.5)))
                            request.progress = progress
                            if ended {
                                request.releaseVelocity = velocity * sign / (contentWidth * 0.5)
                                request.commit = !cancelled && (progress > 0.4 || progress + (request.releaseVelocity ?? 0) * 0.16 > 0.45)
                                request.progress = nil
                            }
                            turnRequest = request
                        })
                }
            }
            .coordinateSpace(name: "magazine-viewport")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 封面与展开页共用固定舞台，导航出现时不再挤动书页。
                Color.clear.frame(height: MagazinePaginator.railHeight)
                    .overlay(alignment: .bottom) {
                        if memory.magazineIsOpen && !pages.isEmpty {
                            MagazinePageRail(pages: pages, currentIndex: pageIndex,
                                isTurning: isTurning, availableWidth: availableSize.width,
                                availableHeight: availableSize.height, onSelect: { go(to: $0, proxy: proxy) })
                        }
                    }
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
            .task(id: memory.magazineScopeID.uuidString + String(isBrowsing)) {
                guard isBrowsing, autoOpenedScope != memory.magazineScopeID else { return }
                let scope = memory.magazineScopeID
                guard !memory.magazineIsOpen else { autoOpenedScope = scope; return }
                do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
                guard !Task.isCancelled, scope == memory.magazineScopeID, autoOpenedScope != scope else { return }
                autoOpenedScope = scope
                openBook()
            }
            .task(id: memory.magazineIsOpen) {
                guard memory.magazineIsOpen else { coverAnimating = false; onClearSelection(); cancelTurn(); return }
                do { try await Task.sleep(for: .milliseconds(670)) } catch { return }
                coverAnimating = false
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
            .onChange(of: isBrowsing) { _, value in
                if !value { cancelTurn() }
                else if memory.isRestoring {
                    restore(proxy: proxy, anchor: memory.restoreAnchor)
                    memory.finishRestoration()
                }
            }
            .onChange(of: availableSize) { _, _ in cancelTurn() }
            .onChange(of: showsImages) { _, _ in cancelTurn() }
        }
        .background(turning != .scroll ? Color(nsColor: stageBackground) : Color.clear)
        .accessibilityIdentifier("magazine.browser")
    }

    // 手势必须位于 NSHostingView 内，才能与文章 Button 正确仲裁。
    private func pageDrag(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 20)
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
                let progress = request.progress ?? 0
                request.releaseVelocity = (predicted - value.translation.width * (request.forward ? -1 : 1)) / (contentWidth * 0.65 * 0.25)
                request.commit = progress > 0.4 || (progress > 0.12 && predicted > contentWidth * 0.35)
                request.progress = nil
                turnRequest = request
            }
    }

    private func cancelTurn() {
        if turnRequest != nil, let anchor = turnSourceAnchor { memory.magazineAnchor = anchor }
        turnRequest = nil
        turnSourceAnchor = nil
    }

    private func pageContent(_ page: MagazinePage, index: Int) -> some View {
        let layout = edition.layouts[page.id]
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
                    ForEach(Array(zip(page.entries, layout.placements)), id: \.0.id) { entry, placement in
                        tile(entry, placement.frame.width, .gallery)
                            .environment(\.magazineStoryStyle, placement.style)
                            .frame(width: placement.frame.width, height: placement.frame.height, alignment: .topLeading)
                            .clipped()
                            .overlay(alignment: .top) {
                                if placement.frame.minY > 0 && placement.style.role != .gallery {
                                    Rectangle().fill(Color(paperHex: palette.mutedHex).opacity(0.14))
                                        .frame(height: 0.5).offset(y: placement.style.role == .supporting
                                            ? -MagazinePaginator.supportSpacing / 2 : -MagazinePaginator.rowSpacing / 2)
                                }
                            }
                            .offset(x: placement.frame.minX, y: placement.frame.minY)
                    }
                }
            }
            .frame(width: contentWidth, height: layout?.height ?? 0, alignment: .topLeading)
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .padding(.horizontal, MagazinePaginator.horizontalInset(availableSize.width))
        .padding(.vertical, MagazinePaginator.verticalInset)
        .foregroundStyle(Color(paperHex: palette.inkHex))
    }

    private func showEndNotice() {
        guard notice == nil else { return }
        noticeID = UUID()
        withAnimation(.easeOut(duration: 0.15)) { notice = I18N.shared.localized("已经是最后一页", "You’ve reached the last page") }
    }

    private func openBook() {
        guard !memory.magazineIsOpen else { return }
        autoOpenedScope = memory.magazineScopeID
        onClearSelection()
        coverAnimating = true
        if pageSoundEnabled { MagazinePageSound.play() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .timingCurve(0.77, 0, 0.175, 1, duration: 0.65)) {
            memory.magazineIsOpen = true
        }
    }

    private var bookCover: some View {
        GeometryReader { geometry in
            let width = paperWidth / 2
            // 与翻页宿主使用同一视口，不再次扣除底部导航高度。
            let height = max(1, geometry.size.height - turnInset * 2)
            Button(action: openBook) {
                MagazineCoverLeaf(progress: memory.magazineIsOpen ? 1 : 0, reduced: reduceMotion,
                    width: width, front: coverFace(width: width, height: height),
                    back: coverInside(width: width, height: height))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(coverTitle)
            .accessibilityIdentifier("magazine.cover")
            .position(x: geometry.size.width / 2, y: turnInset + height / 2)
        }
    }

    private func coverInside(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let page = pages.first {
                pageContent(page, index: 0)
                    .frame(width: paperWidth, height: height, alignment: .topLeading)
                    .frame(width: width, height: height, alignment: .leading)
                    .clipped()
            } else {
                paperBackground.frame(width: width, height: height)
            }
        }
        .background(paperBackground)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func coverFace(width: CGFloat, height: CGFloat) -> some View {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(paperBackground)
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
        guard isBrowsing, !isTurning, memory.magazineIsOpen else { return }
        if index < 0 { memory.magazineIsOpen = false; return }
        if index >= pages.count {
            if hasMore { pendingPageIndex = index; onNeedMore() }
            else { showEndNotice() }
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
            if index == pages.count - 1 && !hasMore { showEndNotice() }
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

    private var articleFrames: [CGRect] {
        guard pages.indices.contains(pageIndex), let layout = edition.layouts[pages[pageIndex].id] else { return [] }
        let x = (availableSize.width - paperWidth) / 2 + MagazinePaginator.horizontalInset(availableSize.width)
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
            else if [36, 49, 76, 124, 125, 121].contains(request.keyCode) { openBook() }
            return
        }
        if request.keyCode == 116 || request.keyCode == 121 {
            go(to: pageIndex + (request.keyCode == 121 ? 1 : -1), proxy: proxy)
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
                let index = pageIndex + (request.keyCode == 123 ? -1 : 1)
                if index < 0 { onFocusSidebar(); return }
                if pages.indices.contains(index), let next = edition.layouts[pages[index].id] {
                    let edge = next.placements.filter { request.keyCode == 123
                        ? $0.frame.midX >= contentWidth / 2 : $0.frame.midX < contentWidth / 2 }
                    let target = (edge.isEmpty ? next.placements : edge).min {
                        abs($0.frame.midY - current.frame.midY) < abs($1.frame.midY - current.frame.midY)
                    }
                    if let target { onHighlight(target.entryID) }
                }
                go(to: index, proxy: proxy)
            }
        } else if [36, 49, 76].contains(request.keyCode), let current,
                  let entry = pages[pageIndex].entries.first(where: { $0.id == current.entryID }) {
            memory.openingFrameInWindow = nil
            onOpen(entry)
        }

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

/// 方向优先，再按投影重叠和距离选择相邻文章。
enum MagazineSpatialNavigation {
    static func neighbor(of current: MagazinePlacement, in placements: [MagazinePlacement], key: UInt16) -> MagazinePlacement? {
        let horizontal = key == 123 || key == 124
        let sign: CGFloat = key == 123 || key == 126 ? -1 : 1
        let origin = current.frame
        return placements.filter { item in
            guard item.entryID != current.entryID else { return false }
            let delta = horizontal ? item.frame.midX - origin.midX : item.frame.midY - origin.midY
            let crossOverlap = horizontal
                ? min(origin.maxY, item.frame.maxY) - max(origin.minY, item.frame.minY)
                : min(origin.maxX, item.frame.maxX) - max(origin.minX, item.frame.minX)
            return delta * sign > 1 && (horizontal || crossOverlap > 0)
        }.min { a, b in
            func score(_ rect: CGRect) -> CGFloat {
                let primary = abs(horizontal ? rect.midX - origin.midX : rect.midY - origin.midY)
                let cross = abs(horizontal ? rect.midY - origin.midY : rect.midX - origin.midX)
                let overlap = horizontal ? min(origin.maxY, rect.maxY) - max(origin.minY, rect.minY)
                    : min(origin.maxX, rect.maxX) - max(origin.minX, rect.minX)
                return primary + cross * 2 + (overlap <= 0 ? 10000 : 0)
            }
            return score(a.frame) < score(b.frame)
        }
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
            guard let input, input.active, event.window === window, window?.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return event }
            let point = convert(event.locationInWindow, from: nil)
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
            } else if event.type == .scrollWheel, event.hasPreciseScrollingDeltas {
                // 手指离开即按最后速度结算；系统后续惯性事件不再触发第二页。
                guard event.momentumPhase.isEmpty else { return consumed ? nil : event }
                if event.phase.contains(.began) || event.timestamp - lastWheel > 0.3 {
                    endSwipe(cancelled: true)
                    distance = 0; velocity = 0
                }
                let deltaTime = max(0.008, min(0.05, event.timestamp - lastWheel))
                lastWheel = event.timestamp
                guard consumed || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.3 else { return event }
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
            }
            return event
        }
    }
}
#endif
