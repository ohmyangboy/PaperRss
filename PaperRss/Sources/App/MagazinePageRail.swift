import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import PaperRssCore
#endif

private struct MagazineRailAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reader_audio_wave_enabled") private var audioWaveEnabled = false
    @ObservedObject private var outputVolume = SystemOutputVolumeMonitor.shared
    @State private var hoverPosition: CGFloat?
    @State private var hoveredID: String?
    @State private var dismissTask: Task<Void, Never>?
    @FocusState private var focusedID: String?

    static let tickWidth: CGFloat = 3
    static let tickHeight: CGFloat = 8
    private var railWidth: CGFloat {
        min(280, max(14, availableWidth * 0.45), max(14, CGFloat(pages.count) * 14))
    }
    private var previewMaxHeight: CGFloat { min(400, max(96, availableHeight - 100)) }

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
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    pageTicks(at: nil)
                }
                .scrollIndicators(.never)
                .frame(width: railWidth, height: 28)
                .onChange(of: currentIndex, initial: true) { _, index in
                    if pages.indices.contains(index) { proxy.scrollTo(pages[index].id, anchor: .center) }
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(paperHex: palette.inkHex))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .overlayPreferenceValue(MagazineRailAnchors.self) { anchors in
            GeometryReader { geometry in
                if let id = hoveredID ?? focusedID, let anchor = anchors[id],
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
        .onDisappear { dismissTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("magazine.pageRail")
    }

    @ViewBuilder
    private func pageTicks(at date: Date?) -> some View {
        LazyHStack(spacing: 0) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                Button { select(index) } label: {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(paperHex: palette.inkHex).opacity(index == currentIndex ? 0.88 : 0.22))
                        .frame(width: Self.tickWidth, height: Self.tickHeight)
                        .scaleEffect(x: 1, y: tickHeight(index: index, date: date) / Self.tickHeight)
                        .frame(width: 14, height: 28)
                        .contentShape(Rectangle())
                }
                .id(page.id)
                .anchorPreference(key: MagazineRailAnchors.self, value: .bounds) { [page.id: $0] }
                .disabled(isTurning)
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
            case .ended: hoverPosition = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoverPosition)
    }

    private func tickHeight(index: Int, date: Date?) -> CGFloat {
        var height = index == currentIndex ? 12 : Self.tickHeight
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
                distance: (hoverPosition - (CGFloat(index) * 14 + 7)) / 14
            ))
        }
        return height
    }

    private func preview(_ page: MagazinePage, width: CGFloat, height: CGFloat) -> some View {
        // 显式高度独立于导航条，长标题可完整换行，超出可用空间时滚动。
        ScrollView {
            previewTitles(page).padding(.vertical, 12).padding(.horizontal, 14)
        }
        .scrollIndicators(.automatic)
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
                    Text(entry.title)
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
        if inside { hoveredID = id; return }
        dismissTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            if hoveredID == id { hoveredID = nil }
        }
    }
}
