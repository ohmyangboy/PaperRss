import SwiftUI
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
    let hasMore: Bool
    let isTurning: Bool
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    let onSelect: (Int) -> Void
    @Environment(\.paperAppearancePalette) private var palette
    @State private var hoveredID: String?
    @State private var dismissTask: Task<Void, Never>?
    @FocusState private var focusedID: String?

    static let tickWidth: CGFloat = 3
    static let tickHeight: CGFloat = 8
    private var railWidth: CGFloat {
        min(280, max(14, availableWidth * 0.45), max(14, CGFloat(pages.count) * 14))
    }

    var body: some View {
        HStack(spacing: 8) {
            arrow("chevron.left", label: I18N.localized("上一页"), enabled: currentIndex > 0 && !isTurning,
                  identifier: "magazine.previousPage") { select(currentIndex - 1) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            Button { select(index) } label: {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color(paperHex: palette.inkHex).opacity(index == currentIndex ? 0.88 : 0.22))
                                    .frame(width: Self.tickWidth, height: index == currentIndex ? 12 : Self.tickHeight)
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
                }
                .scrollIndicators(.never)
                .frame(width: railWidth, height: 28)
                .onChange(of: currentIndex, initial: true) { _, index in
                    if pages.indices.contains(index) { proxy.scrollTo(pages[index].id, anchor: .center) }
                }
            }

            arrow("chevron.right", label: I18N.localized("下一页"),
                  enabled: !isTurning && (currentIndex + 1 < pages.count || hasMore),
                  identifier: "magazine.nextPage") { select(currentIndex + 1) }
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
                    preview(page, width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .offset(x: center - geometry.size.width / 2, y: -42)
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

    private func arrow(_ symbol: String, label: String, enabled: Bool, identifier: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color(paperHex: palette.mutedHex).opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private func preview(_ page: MagazinePage, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .vertical) {
                previewTitles(page)
                ScrollView { previewTitles(page) }.scrollIndicators(.never)
            }
            .frame(maxHeight: min(220, max(80, availableHeight - 160)))
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(width: width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(paperHex: palette.backgroundHex))
                .shadow(color: Color.black.opacity(0.14), radius: 14, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(paperHex: palette.mutedHex).opacity(0.18), lineWidth: 0.5))
        .onHover { hover($0, id: page.id) }
        .accessibilityHidden(true)
    }

    private func previewTitles(_ page: MagazinePage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(page.entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(paperHex: palette.mutedHex))
                    Text(entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(paperHex: palette.inkHex))
                        .lineLimit(2)
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
