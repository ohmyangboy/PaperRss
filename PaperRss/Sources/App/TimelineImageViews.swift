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
    let width: CGFloat
    let height: CGFloat
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
                .frame(width: max(1, width), height: max(1, height))
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

struct TimelineArticleTile: View {
    let entry: EntryListItem
    let style: TimelineViewStyle
    let isLead: Bool
    let isSelected: Bool
    let width: CGFloat
    let showsImages: Bool
    let thumbnailStore: ArticleThumbnailStore
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.displayScale) private var displayScale

    private var isWideMagazine: Bool { style == .magazine && width >= 560 }
    private var imageWidth: CGFloat { isWideMagazine ? (isLead ? width * 0.49 : 172) : max(1, width - 28) }
    private var imageHeight: CGFloat {
        isWideMagazine ? (isLead ? 240 : 114) : min(isLead ? 260 : 176, imageWidth * 0.60)
    }

    var body: some View {
        Group {
            if isWideMagazine {
                HStack(alignment: .top, spacing: 22) {
                    if isLead { thumbnail }
                    textContent.frame(maxWidth: .infinity, alignment: .leading)
                    if !isLead { thumbnail }
                }
                .frame(minHeight: isLead ? 240 : 120, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    thumbnail
                    textContent
                    Spacer(minLength: 0)
                }
                .frame(minHeight: style == .cards ? 232 : 140, alignment: .top)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(paperHex: isSelected ? palette.accentHex : palette.backgroundHex)
            .opacity(isSelected ? 0.14 : (style == .cards ? 0.64 : 0)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(
                Color(paperHex: isSelected ? palette.accentHex : palette.mutedHex)
                    .opacity(isSelected ? 0.55 : (style == .cards ? 0.16 : 0)), lineWidth: 0.7)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(I18N.localized("单击以在右侧打开文章"))
    }

    @ViewBuilder private var thumbnail: some View {
        if showsImages, let url = entry.previewImageURL {
            ArticleThumbnailView(
                request: .init(accountID: entry.accountID, url: url, pixelSize: Int(imageWidth * displayScale)),
                store: thumbnailStore, width: imageWidth, height: imageHeight)
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(entry.isRead ? Color.clear : Color(paperHex: palette.accentHex))
                    .frame(width: 6, height: 6)
                Text(entry.sourceTitle).lineLimit(1)
                Spacer(minLength: 0)
                if entry.isStarred { Image(systemName: "star.fill").foregroundStyle(Color(paperHex: palette.warmHex)) }
            }
            .font(.caption).foregroundStyle(Color(paperHex: palette.mutedHex))
            Text(entry.title)
                .font(.system(size: isLead ? 25 : 18, weight: entry.isRead ? .regular : .semibold, design: .serif))
                .foregroundStyle(Color(paperHex: palette.inkHex))
                .lineLimit(isLead ? 5 : 3)
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
    }
}

#if os(macOS)
struct TimelineViewControls: View {
    let style: TimelineViewStyle
    let showsImages: Bool
    let showsReturn: Bool
    let onSelect: (TimelineViewStyle) -> Void
    let onToggleImages: (Bool) -> Void
    let onReturn: () -> Void
    @State private var showsPopover = false

    var body: some View {
        HStack(spacing: 5) {
            if showsReturn {
                Button(action: onReturn) { Image(systemName: "arrow.uturn.backward") }
                    .help(I18N.localized("返回浏览"))
                    .accessibilityLabel(I18N.localized("返回浏览"))
                    .accessibilityIdentifier("timeline.returnToBrowse")
            } else { Spacer(minLength: 0) }
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
                    Divider()
                    Toggle(I18N.localized("显示文章配图"), isOn: Binding(get: { showsImages }, set: onToggleImages))
                    Text(I18N.localized("图片按需从原网站加载，不会自动抓取原文网页。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).frame(width: 260)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .frame(width: 62, height: 30)
    }
}
#endif
