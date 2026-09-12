#if os(macOS)
import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// 排版和渲染共用字体、行数与图片尺寸；已读状态不改变几何。
struct MagazineStoryStyle: Equatable {
    var titleSize: CGFloat = 22
    var titleLines = 4
    var summaryLines = 3
    var imageHeight: CGFloat = 0
    var summarySize: CGFloat = 15
    static func titleFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) ?? base
    }
    func height(for entry: EntryListItem, width: CGFloat) -> CGFloat {
        func measured(_ text: String, font: NSFont, lines: Int) -> CGFloat {
            guard !text.isEmpty, lines > 0 else { return 0 }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let rect = (text as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph])
            let line = ceil(font.ascender - font.descender + font.leading)
            return min(ceil(rect.height) + 2, line * CGFloat(lines) + 2)
        }
        let title = measured(entry.title, font: Self.titleFont(titleSize), lines: titleLines)
        let summary = entry.isSummaryVisible ? measured(entry.summaryPreview,
            font: .systemFont(ofSize: summarySize), lines: summaryLines) : 0
        return 16 + 12 + title + (summary > 0 ? 12 + summary : 0) + 12 + 14
            + (imageHeight > 0 ? imageHeight + 16 : 0) + 8
    }
}

private struct MagazineStoryKey: EnvironmentKey {
    static let defaultValue: MagazineStoryStyle? = nil
}
extension EnvironmentValues {
    var magazineStoryStyle: MagazineStoryStyle? {
        get { self[MagazineStoryKey.self] }
        set { self[MagazineStoryKey.self] = newValue }
    }
}

struct MagazinePlacement: Equatable {
    let entryID: String
    let frame: CGRect
    let style: MagazineStoryStyle
}
struct MagazinePageLayout: Equatable {
    let page: MagazinePage
    let placements: [MagazinePlacement]
    let height: CGFloat
}

/// App 层负责点尺寸；Core 只负责分组与文章身份。
enum MagazinePaginator {
    static let gutter: CGFloat = 32
    static let headingHeight: CGFloat = 60
    static let railHeight: CGFloat = 48
    static func contentWidth(_ width: CGFloat) -> CGFloat {
        min(1100, max(1, width - (width < 600 ? 40 : 80)))
    }
    static func pages(entries: [EntryListItem], folders: [UUID: String], arrangement: MagazineArrangement,
                      size: CGSize, showsImages: Bool) -> [MagazinePageLayout] {
        let width = contentWidth(size.width)
        let height = max(100, size.height - railHeight - 40 - headingHeight)
        // 分组在 Core 内完成。每组最多十二篇，保证单次测量有界。
        let groups = MagazineEdition.pages(entries: entries, arrangement: arrangement, folders: folders, capacity: 12)
        var result: [MagazinePageLayout] = []
        for group in groups {
            var remaining = group.entries
            while !remaining.isEmpty {
                let columns = width >= 680 && remaining.count > 1 ? 2 : 1
                let columnWidth = columns == 1 ? min(720, width) : (width - gutter) / 2
                let isBrief = remaining.allSatisfy { !$0.isSummaryVisible && (!showsImages || $0.previewImageURL == nil) }
                // 时间模式不移动主稿；其他模式在有界组内优先选取有图文章。
                if arrangement != .chronological, showsImages,
                   let lead = remaining.firstIndex(where: { $0.previewImageURL != nil }), lead != 0 {
                    remaining.insert(remaining.remove(at: lead), at: 0)
                }
                var bottoms = Array(repeating: CGFloat.zero, count: columns)
                var placed: [MagazinePlacement] = []
                var accepted: [EntryListItem] = []
                for entry in remaining {
                    let column = bottoms.indices.min { bottoms[$0] == bottoms[$1] ? $0 < $1 : bottoms[$0] < bottoms[$1] } ?? 0
                    let isLead = placed.isEmpty && (!isBrief || remaining.count == 1)
                    var style = MagazineStoryStyle(titleSize: isLead ? (remaining.count <= 2 ? 36 : 32) : (isBrief ? 20 : 22),
                        titleLines: isLead ? 5 : 4, summaryLines: isLead ? 5 : 3)
                    if showsImages, entry.previewImageURL != nil {
                        style.imageHeight = min(isLead ? 240 : 130, columnWidth * 0.56, height * (isLead ? 0.36 : 0.22))
                    }
                    var measured = style.height(for: entry, width: columnWidth)
                    // 页首必须容纳至少一篇，先收摘要和图片，再收标题行数。
                    if placed.isEmpty && measured > height {
                        style.imageHeight = 0
                        style.summaryLines = 0
                        style.titleSize = 20
                        style.titleLines = max(1, min(4, Int((height - 70) / 25)))
                        measured = style.height(for: entry, width: columnWidth)
                    }
                    if !placed.isEmpty && bottoms[column] + measured > height {
                        // 剩余空间可容纳文字短稿时，收起配图和摘要，不留下整栏空洞。
                        style.imageHeight = 0
                        style.summaryLines = 2
                        style.titleLines = 3
                        measured = style.height(for: entry, width: columnWidth)
                        if bottoms[column] + measured > height { break }
                    }
                    let frame = CGRect(x: columns == 1 ? (width - columnWidth) / 2 : CGFloat(column) * (columnWidth + gutter), y: bottoms[column],
                                       width: columnWidth, height: min(height, measured))
                    placed.append(.init(entryID: entry.id, frame: frame, style: style))
                    accepted.append(entry)
                    bottoms[column] = frame.maxY + 32
                }
                let page = MagazinePage(id: group.id + ":" + accepted[0].id, title: group.title, entries: accepted)
                result.append(.init(page: page, placements: placed, height: height))
                remaining.removeFirst(accepted.count)
            }
        }
        return result
    }
}

struct MagazineStoryView: View {
    let entry: EntryListItem
    let style: MagazineStoryStyle
    let width: CGFloat
    let selected: Bool
    let store: ArticleThumbnailStore
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var image: ArticleThumbnail?
    @State private var failed = false
    @State private var hovered = false

    private var request: ArticleThumbnailRequest? {
        guard style.imageHeight > 0, let url = entry.previewImageURL else { return nil }
        return .init(accountID: entry.accountID, url: url, pixelSize: Int(width * scale))
    }
    private var textStyle: MagazineStoryStyle {
        var result = style
        if failed { result.summaryLines += Int(style.imageHeight / 20) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if !entry.isRead { Circle().fill(Color(paperHex: palette.accentHex)).frame(width: 5, height: 5) }
                Text(entry.sourceTitle).lineLimit(1)
                Spacer(minLength: 0)
                if entry.isStarred { Image(systemName: "star.fill") }
            }
            .font(.system(size: 11)).foregroundStyle(Color(paperHex: palette.mutedHex))
            if style.imageHeight > 0 && !failed {
                Group {
                    if let image = image ?? request.flatMap({ store.cachedImage(for: $0) }) { Image(decorative: image.image, scale: 1).resizable().scaledToFill() }
                    else { Color(paperHex: palette.mutedHex).opacity(0.06) }
                }
                .frame(width: width, height: style.imageHeight).clipped().padding(.bottom, 4)
                .accessibilityHidden(true)
            }
            Text(entry.title)
                .font(Font(MagazineStoryStyle.titleFont(textStyle.titleSize)))
                .lineLimit(textStyle.titleLines).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color(paperHex: palette.inkHex).opacity(entry.isRead ? 0.72 : 1))
            if entry.isSummaryVisible && textStyle.summaryLines > 0 {
                Text(entry.summaryPreview).font(.system(size: textStyle.summarySize))
                    .lineLimit(textStyle.summaryLines).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color(paperHex: palette.mutedHex))
            }
            HStack {
                Text(entry.accountSourceBadge).lineLimit(1)
                Spacer(minLength: 0)
                if let date = entry.publishedAt { Text(date, format: .dateTime.month().day()) }
            }.font(.system(size: 11)).foregroundStyle(Color(paperHex: palette.mutedHex))
        }
        .frame(width: width, alignment: .topLeading)
        .background(Color(paperHex: palette.accentHex).opacity(selected ? 0.09 : (hovered ? 0.035 : 0)))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color(paperHex: palette.accentHex)).frame(width: 2).offset(x: -8) }
        }
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .task(id: request) {
            image = nil; failed = false
            guard let request else { return }
            do {
                let loaded = try await store.image(for: request)
                try Task.checkCancellation()
                image = loaded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
#endif
