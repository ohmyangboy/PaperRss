import SwiftUI
import AppKit
import QuartzCore
#if SWIFT_PACKAGE
import PaperRssCore
#endif

private struct MagazineRailAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 将整条 TOC 轨道映射到已经加载的页面。它只负责几何，不持有浏览器状态，
/// 这样拖动的边界、最近页和当前页面对可以在无窗口测试中独立验证。
struct MagazineRailScrub {
    struct Pair: Equatable, Sendable {
        let sourceIndex: Int
        let targetIndex: Int
        let progress: Double
        let forward: Bool
    }

    static func normalizedPosition(locationX: CGFloat, width: CGFloat) -> Double {
        guard width > 0, locationX.isFinite else { return 0 }
        return min(1, max(0, Double(locationX / width)))
    }

    /// 指针下方最近的刻度槽。拖动高亮与波浪峰值共用它，同一帧只允许一个高亮刻度。
    static func slot(position: CGFloat, slotWidth: CGFloat, slots: Int) -> Int {
        guard slots > 0, slotWidth > 0, position.isFinite else { return 0 }
        let slot = Int(((position - slotWidth / 2) / slotWidth).rounded())
        return min(slots - 1, max(0, slot))
    }

    static func tickIndices(count: Int, width: CGFloat, currentIndex: Int? = nil) -> [Int] {
        guard count > 0 else { return [] }
        let slots = min(count, max(2, Int(max(0, width) / 7)))
        guard slots > 1 else { return [0] }
        var indices = (0..<slots).map { Int((Double($0) * Double(count - 1) / Double(slots - 1)).rounded()) }
        if let currentIndex {
            let current = min(count - 1, max(0, currentIndex))
            var slot = Int((Double(current) * Double(slots - 1) / Double(count - 1)).rounded())
            if slots > 2, current > 0, current < count - 1 { slot = min(slots - 2, max(1, slot)) }
            indices[slot] = current
        }
        return indices
    }

    static func pagePosition(normalized: Double, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return min(Double(count - 1), max(0, normalized.isFinite ? normalized : 0) * Double(count - 1))
    }

    static func nearestIndex(position: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(Double(count - 1), max(0, position.isFinite ? position : 0))
        return min(count - 1, max(0, Int(clamped.rounded())))
    }

    static func nearestIndex(normalized: Double, count: Int) -> Int {
        nearestIndex(position: pagePosition(normalized: normalized, count: count), count: count)
    }

    /// 返回当前拖动位置对应的一对页面。正向拖动使用 [floor, ceil]，
    /// 反向拖动使用同一页对的反向面，因此在相邻页面之间可以立即倒放。
    static func pair(position: Double, count: Int, forward: Bool) -> Pair? {
        guard count > 1 else { return nil }
        let p = min(Double(count - 1), max(0, position.isFinite ? position : 0))
        if forward {
            let source = min(count - 2, max(0, Int(floor(p))))
            return Pair(sourceIndex: source, targetIndex: source + 1,
                        progress: min(1, max(0, p - Double(source))), forward: true)
        }
        // 在整数页位置从当前页开始倒放；只有落在两页之间时才取上界。
        // 这样从第 N 页反向拖动的首帧不会先创建 N+1 -> N 的无效页面对。
        let source = min(count - 1, max(1, Int(ceil(p))))
        return Pair(sourceIndex: source, targetIndex: source - 1,
                    progress: min(1, max(0, Double(source) - p)), forward: false)
    }

    static func progress(position: Double, in pair: Pair) -> Double? {
        let low = Double(min(pair.sourceIndex, pair.targetIndex))
        let high = Double(max(pair.sourceIndex, pair.targetIndex))
        let p = position.isFinite ? position : low
        guard p >= low, p <= high else { return nil }
        let value = pair.forward ? p - Double(pair.sourceIndex) : Double(pair.sourceIndex) - p
        return min(1, max(0, value))
    }
}

/// 鼠标事件只覆盖最新坐标；每个显示帧最多发布一次浏览器状态。
@MainActor
final class MagazineRailFrameInput: NSObject, ObservableObject {
    private var clock: CADisplayLink?
    private var pending: (Double, (Double) -> Void)?
    private var flushTask: Task<Void, Never>?

    func submit(_ position: Double, action: @escaping (Double) -> Void) {
        pending = (position, action)
        if clock == nil {
            if let screen = NSScreen.main {
                let clock = screen.displayLink(target: self, selector: #selector(tick(_:)))
                clock.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                self.clock = clock
                clock.add(to: .main, forMode: .common)
            }
        }
        if flushTask == nil {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                self.flush()
            }
        }
    }
    @objc private func tick(_ clock: CADisplayLink) { flush() }
    func flush() {
        let latest = pending
        cancel()
        if let latest { latest.1(latest.0) }
    }
    func cancel() {
        clock?.invalidate(); clock = nil
        flushTask?.cancel(); flushTask = nil
        pending = nil
    }
}

/// The reader TOC rail, rotated: identical quiet ticks, no full-width toolbar or
/// growing current-page pill. Hover/focus belongs here, not to the page layout.
struct MagazinePageRail: View {
    let pages: [MagazinePage]
    let currentIndex: Int
    let isTurning: Bool
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    let onSelect: (Int) -> Void
    let onScrubStart: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: () -> Void
    let onScrubCancelled: () -> Void
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.entryTranslations) private var entryTranslations
    @AppStorage("reader_audio_wave_enabled") private var audioWaveEnabled = false
    @ObservedObject private var outputVolume = SystemOutputVolumeMonitor.shared
    @State private var hoverPosition: CGFloat?
    @State private var hoveredID: String?
    @State private var dismissTask: Task<Void, Never>?
    @State private var scrubbing = false
    @StateObject private var scrubInput = MagazineRailFrameInput()
    @GestureState private var dragIsActive = false
    @FocusState private var focusedID: String?

    init(
        pages: [MagazinePage],
        currentIndex: Int,
        isTurning: Bool,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        onSelect: @escaping (Int) -> Void,
        onScrubStart: @escaping () -> Void = {},
        onScrubChanged: @escaping (Double) -> Void = { _ in },
        onScrubEnded: @escaping () -> Void = {},
        onScrubCancelled: @escaping () -> Void = {}
    ) {
        self.pages = pages
        self.currentIndex = currentIndex
        self.isTurning = isTurning
        self.availableWidth = availableWidth
        self.availableHeight = availableHeight
        self.onSelect = onSelect
        self.onScrubStart = onScrubStart
        self.onScrubChanged = onScrubChanged
        self.onScrubEnded = onScrubEnded
        self.onScrubCancelled = onScrubCancelled
    }

    static let tickWidth: CGFloat = 3
    static let tickHeight: CGFloat = 8
    private var railWidth: CGFloat {
        min(280, max(14, availableWidth * 0.45), max(14, CGFloat(pages.count) * 14))
    }
    private var previewMaxHeight: CGFloat { min(400, max(96, availableHeight - 100)) }
    private var tickIndices: [Int] {
        MagazineRailScrub.tickIndices(count: pages.count, width: railWidth, currentIndex: currentIndex)
    }
    private var tickSlotWidth: CGFloat { railWidth / CGFloat(max(1, tickIndices.count)) }
    // 未激活刻度与拖动进度提示共用同一档弱对比，随主题的墨水色变化。
    private var inactiveTickColor: Color { Color(paperHex: palette.inkHex).opacity(0.22) }

    // 连续距离让相邻刻度依次抬起；只缩放刻度，不改变命中区域或布局。
    static func waveHeight(distance: CGFloat) -> CGFloat {
        let influence = max(0, 1 - abs(distance) / 3)
        return tickHeight + 16 * influence * influence * (3 - 2 * influence)
    }

    static func audioWaveHeight(index: Int, volume: CGFloat, time: TimeInterval,
                                reduceMotion: Bool) -> CGFloat {
        let level = min(1, max(0, volume))
        guard level > 0 else { return tickHeight }
        return reduceMotion ? tickHeight : tickHeight + 16 * level
    }

    static func previewHeight(titles: [String], width: CGFloat, maximum: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = max(1, width - 28 - 28)
        let heights = titles.map {
            ($0 as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height.rounded(.up)
        }
        return min(maximum, 24 + heights.reduce(0, +) + CGFloat(max(0, titles.count - 1)) * 10)
    }

    var body: some View {
        HStack(spacing: 0) { pageTicks(at: nil) }
            .frame(width: railWidth, height: 28)
            .contentShape(Rectangle())
            .highPriorityGesture(scrubGesture(width: railWidth))
        .buttonStyle(.plain)
        .foregroundStyle(Color(paperHex: palette.inkHex))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .overlayPreferenceValue(MagazineRailAnchors.self) { anchors in
            GeometryReader { geometry in
                if !scrubbing, let id = hoveredID ?? focusedID, let anchor = anchors[id],
                   let page = pages.first(where: { $0.id == id }) {
                    let width = min(340, max(1, geometry.size.width - 32))
                    let center = min(geometry.size.width - width / 2 - 8,
                                     max(width / 2 + 8, geometry[anchor].midX))
                    let height = Self.previewHeight(titles: page.entries.map(\.title), width: width, maximum: previewMaxHeight)
                    preview(page, width: width, height: height)
                        .position(x: center, y: -6 - height / 2)
                }
            }
        }
        .onChange(of: focusedID) { _, id in dismissTask?.cancel(); hoveredID = id }
        .onChange(of: currentIndex) { _, _ in dismissTask?.cancel(); hoveredID = nil; focusedID = nil }
        .onChange(of: isTurning) { _, turning in if turning { hoveredID = nil; focusedID = nil } }
        .onDisappear {
            dismissTask?.cancel()
            scrubInput.cancel()
            if scrubbing { scrubbing = false; onScrubCancelled() }
        }
        .onChange(of: dragIsActive) { _, active in
            if !active, scrubbing {
                scrubInput.cancel()
                scrubbing = false
                onScrubCancelled()
            }
        }
        .overlay(alignment: .top) {
            if scrubbing {
                Text("\(currentIndex + 1) / \(max(1, pages.count))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(inactiveTickColor)
                    .offset(y: -25)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("magazine.pageRail")
    }

    @ViewBuilder
    private func pageTicks(at date: Date?) -> some View {
        let indices = tickIndices
        let selected = indices.min { abs($0 - currentIndex) < abs($1 - currentIndex) }
        // 拖动时高亮与波浪峰值共用指针槽位，避免当前页刻度与波浪各亮一处。
        let scrubSlot = scrubbing ? hoverPosition.map {
            MagazineRailScrub.slot(position: $0, slotWidth: tickSlotWidth, slots: indices.count)
        } : nil
        LazyHStack(spacing: 0) {
            ForEach(Array(indices.enumerated()), id: \.element) { slot, index in
                let page = pages[index]
                let highlighted = scrubSlot.map { $0 == slot } ?? (index == selected)
                Button { select(index) } label: {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(highlighted ? Color(paperHex: palette.inkHex).opacity(0.88) : inactiveTickColor)
                        .frame(width: Self.tickWidth, height: Self.tickHeight)
                        .scaleEffect(x: 1, y: tickHeight(index: index, slot: slot, selected: highlighted, date: date) / Self.tickHeight)
                        .frame(width: tickSlotWidth, height: 28)
                        .contentShape(Rectangle())
                }
                .id(page.id)
                .anchorPreference(key: MagazineRailAnchors.self, value: .bounds) { [page.id: $0] }
                .focused($focusedID, equals: page.id)
                .onHover { inside in hover(inside, id: page.id) }
                .accessibilityLabel("\(I18N.localized("页面")) \(index + 1) / \(pages.count)")
                .accessibilityHint(page.entries.map(\.title).joined(separator: "; "))
                .accessibilityAddTraits(index == currentIndex ? [.isSelected] : [])
                .accessibilityIdentifier("magazine.page.\(index)")
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverPosition = point.x
            // 拖动中指针移出轨道时手势仍在继续，波浪位置不能被悬停结束清空。
            case .ended: if !scrubbing { hoverPosition = nil }
            }
        }
        .animation(reduceMotion || scrubbing ? nil : .easeOut(duration: 0.12), value: hoverPosition)
    }

    private func tickHeight(index: Int, slot: Int, selected: Bool, date: Date?) -> CGFloat {
        var height = selected ? 12 : Self.tickHeight
        if audioWaveEnabled {
            height = max(height, Self.audioWaveHeight(
                index: index,
                volume: outputVolume.levels[min(outputVolume.levels.count - 1,
                    index * outputVolume.levels.count / max(1, pages.count))],
                time: date?.timeIntervalSinceReferenceDate ?? 0,
                reduceMotion: reduceMotion
            ))
        }
        if let hoverPosition {
            height = max(height, reduceMotion ? Self.tickHeight : Self.waveHeight(
                distance: (hoverPosition - (CGFloat(slot) * tickSlotWidth + tickSlotWidth / 2)) / max(1, tickSlotWidth)
            ))
        }
        return height
    }

    private func preview(_ page: MagazinePage, width: CGFloat, height: CGFloat) -> some View {
        // 显式高度独立于导航条，长标题可完整换行，超出可用空间时滚动并展示浮动细条。
        PaperFloatingScrollView {
            previewTitles(page).padding(.vertical, 12).padding(.horizontal, 14)
        }
        .frame(width: width, height: height)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(paperHex: palette.backgroundHex))
                .shadow(color: Color.black.opacity(0.14), radius: 14, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(paperHex: palette.mutedHex).opacity(0.18), lineWidth: 0.5))
        .onHover { hover($0, id: page.id) }
        .accessibilityElement(children: .contain)
    }

    private func previewTitles(_ page: MagazinePage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(page.entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(paperHex: palette.mutedHex))
                        .frame(width: 22, alignment: .trailing)
                    Text(entryTranslations[entry.id]?.title ?? entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(paperHex: palette.inkHex))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ index: Int) {
        dismissTask?.cancel()
        hoveredID = nil
        focusedID = nil
        onSelect(index)
    }

    private func hover(_ inside: Bool, id: String) {
        dismissTask?.cancel()
        guard !scrubbing else { return }
        if inside { hoveredID = id; return }
        dismissTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            if hoveredID == id { hoveredID = nil }
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .updating($dragIsActive) { _, active, _ in active = true }
            .onChanged { value in
                if !scrubbing {
                    scrubbing = true
                    dismissTask?.cancel()
                    hoveredID = nil
                    focusedID = nil
                    onScrubStart()
                }
                // 按住拖动时系统不再派发悬停移动事件，波浪必须直接读取手势坐标。
                hoverPosition = value.location.x
                scrubInput.submit(MagazineRailScrub.normalizedPosition(locationX: value.location.x, width: width),
                    action: onScrubChanged)
            }
            .onEnded { value in
                guard scrubbing else { return }
                hoverPosition = value.location.x
                scrubInput.submit(MagazineRailScrub.normalizedPosition(locationX: value.location.x, width: width),
                    action: onScrubChanged)
                scrubInput.flush()
                scrubbing = false
                onScrubEnded()
            }
    }
}
