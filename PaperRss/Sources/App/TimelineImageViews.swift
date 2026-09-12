import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// Scroll memory belongs to the shared timeline, not to an individual layout.
/// Tracking the visible anchor does not publish an update on every scroll frame.
@MainActor
final class TimelinePresentationMemory: ObservableObject {
    var visibleAnchor: String?
    var browseAnchor: String?
    @Published private var storedMagazineAnchor: String?
    var magazineAnchor: String? {
        get { storedMagazineAnchor }
        set {
            // Geometry notifications fire for every scroll delta, even when
            // the visible page has not changed. Do not invalidate the timeline.
            guard storedMagazineAnchor != newValue else { return }
            storedMagazineAnchor = newValue
        }
    }
    private(set) var restoreAnchor: String?
    private(set) var isRestoring = false
    @Published private(set) var restorationID = UUID()

    func prepareRestoration(anchor: String? = nil) {
        restoreAnchor = anchor ?? visibleAnchor
        isRestoring = true
        restorationID = UUID()
    }
    func finishRestoration() { isRestoring = false }
    func resetScope() {
        visibleAnchor = nil
        browseAnchor = nil
        magazineAnchor = nil
        restoreAnchor = nil
        isRestoring = false
    }
}

struct TimelineKeyRequest: Equatable {
    let id = UUID()
    let keyCode: UInt16
}

struct TimelineRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ArticleThumbnailView: View {
    let request: ArticleThumbnailRequest
    let store: ArticleThumbnailStore
    let width: CGFloat?
    let height: CGFloat?
    @Environment(\.paperAppearancePalette) private var palette
    @State private var loaded: ArticleThumbnail?
    @State private var loadedRequest: ArticleThumbnailRequest?
    @State private var failedRequest: ArticleThumbnailRequest?

    var body: some View {
        Group {
            if failedRequest != request {
                Group {
                    if let image = (loadedRequest == request ? loaded : nil) ?? store.cachedImage(for: request) {
                        Image(decorative: image.image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(paperHex: palette.mutedHex).opacity(0.07)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(width: width.map { max(1, $0) }, height: height.map { max(1, $0) })
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            }
        }
        .task(id: request) {
            failedRequest = nil
            do {
                let image = try await store.image(for: request)
                try Task.checkCancellation()
                loadedRequest = request
                loaded = image
            } catch {
                guard !Task.isCancelled else { return }
                loaded = nil
                loadedRequest = nil
                failedRequest = request
            }
        }
    }
}

/// Like the reader's centered text column, visual timelines have a readable
/// maximum measure instead of stretching across every available screen pixel.
struct TimelineLayoutMetrics {
    static let maximumWidth: CGFloat = 1100
    static let editorialBreakpoint: CGFloat = 760
    static let spacing: CGFloat = 20
    let contentWidth: CGFloat

    init(availableWidth: CGFloat) {
        let gutter: CGFloat = availableWidth < 600 ? 16 : 28
        contentWidth = min(Self.maximumWidth, max(1, availableWidth - gutter * 2))
    }

    var usesEditorialHeader: Bool { contentWidth >= Self.editorialBreakpoint }
    var featureColumnWidth: CGFloat { (contentWidth - Self.spacing) / 2 }
    var galleryColumns: Int { min(3, max(1, Int((contentWidth + Self.spacing) / 260))) }
    var galleryTileWidth: CGFloat {
        (contentWidth - CGFloat(galleryColumns - 1) * Self.spacing) / CGFloat(galleryColumns)
    }
}

enum TimelineTileLayout {
    case lead, supporting, compact, gallery
}

/// Text is measured first. A thumbnail may use that height, never force a short
/// tweet to occupy a full image-height row. A failed image takes no space.
struct TimelineCompactTileLayout: Layout {
    var imageWidth: CGFloat
    var imageLeading = false
    var spacing: CGFloat = 14

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard !subviews.isEmpty else { return [] }
        let width = max(1, width)
        var textWidth = width
        var textSize = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        var imageSize = CGSize.zero
        if subviews.count > 1 {
            let proposedImageWidth = min(imageWidth, width * 0.32)
            textWidth = max(1, width - proposedImageWidth - spacing)
            textSize = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            imageSize = subviews[1].sizeThatFits(ProposedViewSize(
                width: proposedImageWidth, height: min(proposedImageWidth, textSize.height)))
            if imageSize.width <= 0 || imageSize.height <= 0 {
                imageSize = .zero
                textWidth = width
                textSize = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
        }
        let textX = imageLeading && imageSize.width > 0 ? imageSize.width + spacing : 0
        let text = CGRect(x: textX, y: 0, width: textWidth, height: textSize.height)
        guard subviews.count > 1 else { return [text] }
        return [text, CGRect(x: imageLeading ? 0 : width - imageSize.width, y: 0,
                             width: imageSize.width, height: imageSize.height)]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 360
        let rects = frames(width: width, subviews: subviews)
        return CGSize(width: max(1, width), height: rects.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rects = frames(width: bounds.width, subviews: subviews)
        for (index, rect) in rects.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

struct TimelineArticleTile: View {
    let entry: EntryListItem
    let layout: TimelineTileLayout
    let isSelected: Bool
    let width: CGFloat
    let showsImages: Bool
    let thumbnailStore: ArticleThumbnailStore
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.displayScale) private var displayScale

    @Environment(\.magazineStoryStyle) private var magazineStyle

    private var isLead: Bool { layout == .lead }
    private var isCompact: Bool { layout == .compact || layout == .supporting }
    private var contentWidth: CGFloat { max(1, width - 24) }
    private var imageWidth: CGFloat { isCompact ? min(132, contentWidth * 0.32) : contentWidth }
    private var imageHeight: CGFloat { min(isLead ? 260 : 180, imageWidth * 9 / 16) }
    private var isTextNote: Bool { (!showsImages || entry.previewImageURL == nil) && !entry.isSummaryVisible }
    private var titleSize: CGFloat {
        if isLead { return entry.title.count > 110 ? 23 : 27 }
        if isTextNote { return entry.title.count < 90 ? 22 : 19 }
        return 18
    }

    @ViewBuilder var body: some View {
        if let magazineStyle {
            MagazineStoryView(entry: entry, style: magazineStyle, width: width,
                selected: isSelected, store: thumbnailStore)
        } else { cardBody }
    }

    private var cardBody: some View {
        Group {
            if isCompact {
                TimelineCompactTileLayout(imageWidth: imageWidth, imageLeading: layout == .supporting) {
                    textContent
                    thumbnail(height: nil)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    thumbnail(height: imageHeight)
                    textContent
                }
            }
        }
        // No minimum tile height and no vertical Spacer: text-only articles
        // remain compact, including the lead article and short social posts.
        .padding(12)
        .frame(width: width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(paperHex: isSelected ? palette.accentHex : palette.backgroundHex)
            .opacity(isSelected ? 0.14 : 0.54))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(
                Color(paperHex: isSelected ? palette.accentHex : palette.mutedHex)
                    .opacity(isSelected ? 0.55 : 0.13), lineWidth: 0.7)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(I18N.localized("打开文章"))
    }

    @ViewBuilder private func thumbnail(height: CGFloat?) -> some View {
        if showsImages, let url = entry.previewImageURL {
            ArticleThumbnailView(
                request: .init(accountID: entry.accountID, url: url, pixelSize: Int(imageWidth * displayScale)),
                store: thumbnailStore, width: isCompact ? nil : imageWidth, height: height)
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !entry.isRead {
                    Circle().fill(Color(paperHex: palette.accentHex)).frame(width: 6, height: 6)
                }
                Text(entry.sourceTitle).lineLimit(1)
                Spacer(minLength: 0)
                if entry.isStarred { Image(systemName: "star.fill").foregroundStyle(Color(paperHex: palette.warmHex)) }
            }
            .font(.caption).foregroundStyle(Color(paperHex: palette.mutedHex))
            Text(entry.title)
                .font(.system(size: titleSize, weight: entry.isRead ? .regular : .semibold, design: .serif))
                .foregroundStyle(Color(paperHex: palette.inkHex))
                .lineLimit(isLead || !entry.isSummaryVisible ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)
            if entry.isSummaryVisible {
                Text(entry.summaryPreview).font(.system(size: 13))
                    .foregroundStyle(Color(paperHex: palette.mutedHex))
                    .lineLimit(isLead ? 4 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(entry.accountSourceBadge).lineLimit(1)
                Spacer(minLength: 0)
                if let date = entry.publishedAt { Text(date, format: .dateTime.month().day()).fixedSize() }
            }
            .font(.caption2).foregroundStyle(Color(paperHex: palette.mutedHex))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(macOS)
struct TimelineViewControls: View {
    let style: TimelineViewStyle
    let showsImages: Bool
    let onSelect: (TimelineViewStyle) -> Void
    let onToggleImages: (Bool) -> Void
    @State private var showsPopover = false
    @AppStorage("magazine_arrangement") private var arrangementRaw = MagazineArrangement.balanced.rawValue
    @AppStorage("magazine_turning") private var turningRaw = MagazineTurning.scroll.rawValue

    var body: some View {
        HStack(spacing: 5) {
            Button { showsPopover.toggle() } label: {
                Image(systemName: style.symbol).frame(width: 18, height: 18)
            }
            .help(I18N.localized("切换文章视图"))
            .accessibilityLabel(I18N.localized("切换文章视图"))
            .accessibilityIdentifier("timeline.viewSwitcher")
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(I18N.localized("文章视图")).font(.headline)
                    HStack(spacing: 10) {
                        ForEach(TimelineViewStyle.allCases, id: \.rawValue) { option in
                            Button {
                                onSelect(option)
                                showsPopover = false
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: option.symbol).font(.system(size: 22))
                                    Text(option.title).font(.caption)
                                }
                                .frame(width: 62, height: 58)
                                .background(style == option ? Color.accentColor.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                                        style == option ? Color.accentColor.opacity(0.6) : .clear)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(style == option ? [.isSelected] : [])
                            .accessibilityIdentifier("timeline.style.\(option.rawValue)")
                        }
                    }
                    if style == .magazine {
                        Divider()
                        Picker(I18N.localized("杂志编排"), selection: $arrangementRaw) {
                            ForEach(MagazineArrangement.allCases, id: \.rawValue) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        Picker(I18N.localized("翻页方式"), selection: $turningRaw) {
                            ForEach(MagazineTurning.allCases, id: \.rawValue) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Divider()
                    Toggle(I18N.localized("显示文章配图"), isOn: Binding(get: { showsImages }, set: { value in onToggleImages(value) }))
                    Text(I18N.localized("图片按需从原网站加载，不会自动抓取原文网页。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).frame(width: 260)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .frame(width: 30, height: 30)
    }
}
#endif
