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
        HStack(spacing: 10) {
            arrow("chevron.left", label: I18N.localized("上一页"), enabled: currentIndex > 0 && !isTurning,
                  identifier: "magazine.previousPage") { select(currentIndex - 1) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            Button { select(index) } label: {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(paperHex: palette.inkHex).opacity(index == currentIndex ? 0.78 : 0.24))
                                    .frame(width: Self.tickWidth, height: Self.tickHeight)
                                    .frame(width: 14, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .id(page.id)
                            .disabled(isTurning)
                            .focused($focusedID, equals: page.id)
                            .anchorPreference(key: MagazineRailAnchors.self, value: .bounds) { [page.id: $0] }
                            .onHover { inside in hover(inside, id: page.id) }
                            .accessibilityLabel("\(I18N.localized("页面")) \(index + 1) / \(pages.count)")
                            .accessibilityHint(page.entries.map(\.title).joined(separator: "; "))
                            .accessibilityAddTraits(index == currentIndex ? [.isSelected] : [])
                            .accessibilityIdentifier("magazine.page.\(index)")
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(width: railWidth, height: 34)
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
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .overlayPreferenceValue(MagazineRailAnchors.self) { anchors in
            GeometryReader { geometry in
                if let id = hoveredID ?? focusedID, let anchor = anchors[id],
                   let page = pages.first(where: { $0.id == id }) {
                    let width = min(340, max(120, geometry.size.width - 32))
                    let center = min(geometry.size.width - width / 2 - 8,
                                     max(width / 2 + 8, geometry[anchor].midX))
                    preview(page, width: width)
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
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Color(paperHex: palette.mutedHex).opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private func preview(_ page: MagazinePage, width: CGFloat) -> some View {
        // Titles only, matching the chapter title cards. No article summaries
        // or inferred text; each label is from this exact magazine page.
        ViewThatFits(in: .vertical) {
            previewTitles(page)
            ScrollView { previewTitles(page) }.scrollIndicators(.never)
        }
        .frame(maxHeight: min(280, max(80, availableHeight - 100)))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(width: width, alignment: .leading)
        .background(Color(paperHex: palette.backgroundHex), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(paperHex: palette.mutedHex).opacity(0.2), lineWidth: 0.5))
        .shadow(color: Color(paperHex: palette.inkHex).opacity(0.16), radius: 13, y: 5)
        .onHover { hover($0, id: page.id) }
        .accessibilityHidden(true)
    }

    private func previewTitles(_ page: MagazinePage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(page.entries) { entry in
                Text(entry.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(paperHex: palette.inkHex))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
