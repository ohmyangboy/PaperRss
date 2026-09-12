#if os(macOS)
import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// 排版和渲染共用字体、行数与图片尺寸；已读状态不改变几何。
struct MagazineStoryStyle: Equatable {
    enum Role: Equatable { case lead, supporting, list, gallery }
    var role: Role = .lead
    var titleSize: CGFloat = 22
    var titleLines = 4
    var summaryLines = 3
    var imageHeight: CGFloat = 0
    var summarySize: CGFloat = 15
    var imageBesideText = false
    var allocatedHeight: CGFloat? = nil
    var stacksImage: Bool { !imageBesideText && (role == .lead || role == .gallery) }
    var textSpacing: CGFloat { role == .lead ? 12 : (role == .supporting ? (titleSize < 18 ? 6 : 8) : 10) }
    var imageSpacing: CGFloat { role == .gallery ? 12 : 20 }
    // 内边距始终参与布局，悬停只改变底色，不挤动图文。
    var contentInset: CGFloat = 12
    func contentWidth(_ width: CGFloat) -> CGFloat { max(1, width - contentInset * 2) }
    static func titleFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) ?? base
    }
    func height(for entry: EntryListItem, width: CGFloat) -> CGFloat {
        let innerWidth = contentWidth(width)
        func measured(_ text: String, font: NSFont, lines: Int) -> CGFloat {
            guard !text.isEmpty, lines > 0 else { return 0 }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let rect = (text as NSString).boundingRect(with: CGSize(width: max(1, !stacksImage && imageHeight > 0 ? innerWidth - imageHeight - imageSpacing : innerWidth), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph])
            let line = ceil(font.ascender - font.descender + font.leading)
            return min(ceil(rect.height) + 2, line * CGFloat(lines) + 2)
        }
        let title = measured(entry.title, font: Self.titleFont(titleSize), lines: titleLines)
        let summary = entry.isSummaryVisible ? measured(entry.summaryPreview,
            font: .systemFont(ofSize: summarySize), lines: summaryLines) : 0
        // SwiftUI Text 与 AppKit 字体测量在中英文混排和缩放下会有少量取整差异。
        // 为文本块留出安全余量，避免固定版面从半行处裁断内容。
        let textSafety = CGFloat((title > 0 ? 1 : 0) + (summary > 0 ? 1 : 0)) * 5
        let textHeight = title + (summary > 0 ? textSpacing + summary : 0) + textSpacing + 14 + textSafety
        let bodyHeight = stacksImage ? textHeight + (imageHeight > 0 ? imageHeight + imageSpacing : 0)
            : max(textHeight, imageHeight)
        return bodyHeight + contentInset * 2 + 4
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
    static let gutter: CGFloat = 40
    static let verticalInset: CGFloat = 28
    static let headingSpacing: CGFloat = 28
    static let supportSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 40
    static let rowSpacing: CGFloat = 32
    // 正文和页眉共用纸面内边距；分页时预留全部页边空间。
    static let headingHeight: CGFloat = 20 + headingSpacing + verticalInset * 2
    static let railHeight: CGFloat = 52
    // 纸面距视口保留约两行文字；渲染器按实际边距限制透视抬起幅度。
    static func turnInset(_ size: CGSize) -> CGFloat { min(32, max(0, size.height - railHeight) * 0.10) }
    static func foldViewport(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: size.height - turnInset(size) * 2)
    }
    static func pageWidth(_ width: CGFloat) -> CGFloat {
        min(1240, max(1, width - (width < 600 ? 64 : 96)))
    }
    static func horizontalInset(_ width: CGFloat) -> CGFloat {
        min(width < 600 ? 20 : 32, (pageWidth(width) - 1) / 2)
    }
    static func contentWidth(_ width: CGFloat) -> CGFloat {
        max(1, pageWidth(width) - horizontalInset(width) * 2)
    }
    static func pages(entries: [EntryListItem], folders: [UUID: String], arrangement: MagazineArrangement,
                      size: CGSize, showsImages: Bool) -> [MagazinePageLayout] {
        let width = contentWidth(size.width)
        let height = max(100, size.height - railHeight - headingHeight)
        // 分组在 Core 内完成。每组最多十二篇，保证单次测量有界。
        let groups = MagazineEdition.pages(entries: entries, arrangement: arrangement, folders: folders, capacity: 12)
        var result: [MagazinePageLayout] = []
        for group in groups {
            var remaining = group.entries
            while !remaining.isEmpty {
                // 固定编辑层级：左侧主稿、右侧三篇短稿，下面按画廊卡片排列。
                // 窄窗或短窗降为单栏，正文身份和时间顺序保持完整。
                if arrangement != .chronological, showsImages,
                   let lead = remaining.firstIndex(where: { $0.previewImageURL != nil }), lead != 0 {
                    remaining.insert(remaining.remove(at: lead), at: 0)
                }
                var placed: [MagazinePlacement] = []
                var accepted: [EntryListItem] = []
                var bottom: CGFloat = 0
                let columnWidth = (width - gutter) / 2
                let hasLeadImage = showsImages && remaining[0].previewImageURL != nil
                let hasLeadText = remaining[0].summaryPreview.count > 140 || remaining[0].title.count > 100
                let usesFeature = width >= 680 && height >= 380 && remaining.count >= 4
                    && (hasLeadImage || hasLeadText)
                func fitted(_ entry: EntryListItem, style: MagazineStoryStyle, width: CGFloat,
                            limit: CGFloat) -> MagazineStoryStyle {
                    var result = style
                    if result.role == .supporting {
                        while result.height(for: entry, width: width) > limit && result.titleLines > 1 {
                            result.titleLines -= 1
                        }
                    }
                    while result.height(for: entry, width: width) > limit && result.summaryLines > 0 {
                        result.summaryLines -= 1
                    }
                    while result.height(for: entry, width: width) > limit && result.titleLines > (result.role == .supporting ? 1 : 2) {
                        result.titleLines -= 1
                    }
                    if result.height(for: entry, width: width) > limit && result.stacksImage {
                        result.imageHeight = max(0, result.imageHeight - (result.height(for: entry, width: width) - limit))
                    }
                    if result.role == .gallery && result.imageHeight > 0 && result.imageHeight < 56 {
                        // 矮视口以文字卡片保留阅读内容，不把图片压成细条。
                        result.imageHeight = 0
                        result.summaryLines = style.summaryLines
                        while result.height(for: entry, width: width) > limit && result.summaryLines > 0 {
                            result.summaryLines -= 1
                        }
                    }
                    return result
                }
                if usesFeature {
                    let featureHeight = hasLeadImage ? min(440, max(368, height * 0.62))
                        : min(400, max(368, height * 0.5))
                    let supportHeight = (featureHeight - supportSpacing * 2) / 3
                    var lead = MagazineStoryStyle(titleSize: 30, titleLines: 3, summaryLines: hasLeadImage ? 3 : 9)
                    if showsImages, remaining[0].previewImageURL != nil {
                        lead.imageHeight = min(columnWidth * 0.52, featureHeight * 0.52)
                    }
                    lead = fitted(remaining[0], style: lead, width: columnWidth, limit: featureHeight)
                    placed.append(.init(entryID: remaining[0].id,
                        frame: CGRect(x: 0, y: 0, width: columnWidth, height: featureHeight), style: lead))
                    accepted.append(remaining[0])
                    for index in 1...3 {
                        let entry = remaining[index]
                        let compact = supportHeight < 125
                        var style = MagazineStoryStyle(role: .supporting, titleSize: compact ? 16 : 18, titleLines: 2,
                            summaryLines: 3, summarySize: compact ? 12 : 13, contentInset: compact ? 8 : 12)
                        if showsImages, entry.previewImageURL != nil { style.imageHeight = max(0, min(104, supportHeight - style.contentInset * 2 - 4)) }
                        style = fitted(entry, style: style, width: columnWidth, limit: supportHeight)
                        placed.append(.init(entryID: entry.id,
                            frame: CGRect(x: columnWidth + gutter, y: CGFloat(index - 1) * (supportHeight + supportSpacing),
                                          width: columnWidth, height: supportHeight), style: style))
                        accepted.append(entry)
                    }
                    bottom = featureHeight + (height < 550 ? 24 : sectionSpacing)
                }
                // 左右纸面独立装箱；最多各三篇，测量只作用于当前分组的前六篇。
                let sides = width >= 680 ? 2 : 1
                let cardWidth = sides == 2 ? columnWidth : width
                let freeHeight = height - bottom
                let candidates = Array(remaining.dropFirst(accepted.count).prefix(sides * 3))
                func galleryStyle(_ entry: EntryListItem) -> MagazineStoryStyle {
                    var style = MagazineStoryStyle(role: .gallery, titleSize: 18, titleLines: 3,
                        summaryLines: 3, summarySize: 13)
                    if showsImages && entry.previewImageURL != nil {
                        style.imageBesideText = !accepted.isEmpty || candidates.count > 2 || freeHeight < 300
                        if style.imageBesideText { style.contentInset = 8; style.titleSize = 16; style.summarySize = 12 }
                        style.imageHeight = style.imageBesideText ? 80 : min(220, style.contentWidth(cardWidth) * 0.45)
                    }
                    return style
                }
                func column(_ items: ArraySlice<EntryListItem>, x: CGFloat) -> [MagazinePlacement]? {
                    guard !items.isEmpty else { return [] }
                    let gap: CGFloat = 12
                    // 每侧内部再组合：两张窄幅图片卡并排，三篇时两篇短稿叠放在图片旁。
                    // 只有单篇或空间不足才退回横向卡片，避免整个页底固定成列表。
                    if usesFeature, items.count >= 2, cardWidth >= 320 {
                        let entries = Array(items)
                        let narrowWidth = (cardWidth - gap) / 2
                        let imageIndices = entries.indices.filter { showsImages && entries[$0].previewImageURL != nil }
                        let groups: [[Int]]
                        if entries.count == 3, let photo = imageIndices.first {
                            let text = entries.indices.filter { $0 != photo }
                            groups = photo == 0 ? [[photo], text] : [text, [photo]]
                        } else if entries.count == 2 {
                            groups = [[0], [1]]
                        } else {
                            groups = []
                        }
                        var mosaic: [MagazinePlacement] = []
                        for (lane, indices) in groups.enumerated() {
                            let allocation = (freeHeight - CGFloat(indices.count - 1) * gap) / CGFloat(indices.count)
                            for (row, index) in indices.enumerated() {
                                let entry = entries[index]
                                var style = MagazineStoryStyle(role: .gallery, titleSize: 16, titleLines: 3,
                                    summaryLines: 3, summarySize: 12, contentInset: 8)
                                if showsImages, entry.previewImageURL != nil {
                                    style.imageHeight = min(120, style.contentWidth(narrowWidth) * 0.65)
                                }
                                style = fitted(entry, style: style, width: narrowWidth, limit: allocation)
                                guard style.height(for: entry, width: narrowWidth) <= allocation else { continue }
                                mosaic.append(.init(entryID: entry.id,
                                    frame: CGRect(x: x + CGFloat(lane) * (narrowWidth + gap),
                                        y: bottom + CGFloat(row) * (allocation + gap), width: narrowWidth,
                                        height: allocation), style: style))
                            }
                        }
                        if mosaic.count == items.count {
                            return entries.compactMap { entry in mosaic.first { $0.entryID == entry.id } }
                        }
                    }
                    let budget = freeHeight - CGFloat(items.count - 1) * gap
                    let styles = items.map { entry in
                        var style = galleryStyle(entry)
                        if items.count == 1, style.imageHeight > 0 {
                            style.imageBesideText = false
                        }
                        return style
                    }
                    let natural = zip(items, styles).map { $1.height(for: $0, width: cardWidth) }
                    let minimum = zip(items, styles).map { entry, style -> CGFloat in
                        var compact = style
                        compact.titleLines = 2; compact.summaryLines = 0
                        if compact.imageHeight > 0 { compact.imageHeight = 80 }
                        return compact.height(for: entry, width: cardWidth)
                    }
                    let floor = minimum.reduce(0, +)
                    guard budget >= floor else { return nil }
                    let extra = budget - floor
                    let demand = zip(natural, minimum).map { max(1, $0 - $1) }
                    let totalDemand = demand.reduce(0, +)
                    var y = bottom
                    return Array(items.enumerated()).map { index, entry in
                        let allocation = minimum[index] + extra * demand[index] / totalDemand
                        var style = styles[index]
                        // 先缩图片，保留可读的标题与摘要；宽裕时让照片自然填充。
                        if usesFeature && style.imageHeight > 0 && !style.imageBesideText {
                            style.imageHeight = max(80, min(300, style.imageHeight + allocation - natural[index]))
                        } else { style.summaryLines = 3 }
                        style = fitted(entry, style: style, width: cardWidth, limit: allocation)
                        let h = usesFeature ? allocation : min(allocation, style.height(for: entry, width: cardWidth))
                        defer { y += h + gap }
                        return .init(entryID: entry.id, frame: CGRect(x: x, y: y, width: cardWidth, height: h), style: style)
                    }
                }
                var best: [MagazinePlacement] = []
                var bestScore = -Double.infinity
                for leftCount in 0...min(3, candidates.count) {
                    for rightCount in 0...(sides == 2 ? min(3, candidates.count - leftCount) : 0) {
                        let count = leftCount + rightCount
                        guard count > 0, let left = column(candidates.prefix(leftCount), x: 0),
                            let right = column(candidates.dropFirst(leftCount).prefix(rightCount), x: columnWidth + gutter) else { continue }
                        let leftHeight = (left.map(\.frame.maxY).max() ?? bottom) - bottom
                        let rightHeight = (right.map(\.frame.maxY).max() ?? bottom) - bottom
                        // 以四篇为常见密度；文字短稿可组合成三篇，种子固定避免重排闪动。
                        let seed = candidates.first?.id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff } ?? 0
                        let preferredLeft = seed % 5 == 0 ? 1 : (seed % 5 == 1 ? 3 : 2)
                        let density = count <= 4 ? Double(count) * 10000 : 40000 - Double(count - 4) * 120
                        let score = density - Double(abs(leftHeight - rightHeight)) * 0.1
                            - Double(abs(leftCount - preferredLeft)) * 20 - (leftCount == 0 ? 100 : 0)
                        if score > bestScore { bestScore = score; best = left + right }
                    }
                }
                if best.isEmpty && placed.isEmpty {
                    // 极矮窗口仍向前推进，不能出现空页或无限分页。
                    let entry = remaining[0]
                    var style = galleryStyle(entry)
                    style.imageHeight = 0; style.summaryLines = 0; style.titleLines = 1
                    best = [.init(entryID: entry.id, frame: CGRect(x: 0, y: 0, width: cardWidth, height: height), style: style)]
                }
                best = best.map { placement in
                    var style = placement.style
                    style.allocatedHeight = usesFeature ? placement.frame.height : nil
                    return .init(entryID: placement.entryID, frame: placement.frame, style: style)
                }
                placed += best
                accepted += candidates.prefix(best.count)
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
        return .init(accountID: entry.accountID, url: url, pixelSize: Int(imageWidth * scale))
    }
    private var imageWidth: CGFloat { style.stacksImage ? style.contentWidth(width) : style.imageHeight }

    @ViewBuilder private var illustration: some View {
        if style.imageHeight > 0 {
            Group {
                if let image = image ?? request.flatMap({ store.cachedImage(for: $0) }), !failed {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFill()
                } else {
                    Color(paperHex: palette.mutedHex).opacity(0.045)
                }
            }
            .frame(width: imageWidth, height: style.imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(paperHex: palette.inkHex).opacity(0.14), lineWidth: 1)
            }
            .accessibilityHidden(true)
        }
    }

    private var storyText: some View {
        VStack(alignment: .leading, spacing: style.textSpacing) {
            Text(entry.title)
                .font(Font(MagazineStoryStyle.titleFont(style.titleSize)))
                .lineLimit(style.titleLines).lineSpacing(1)
                .foregroundStyle(Color(paperHex: palette.inkHex).opacity(entry.isRead ? 0.88 : 1))
            if entry.isSummaryVisible && style.summaryLines > 0 {
                Text(entry.summaryPreview).font(.system(size: style.summarySize))
                    .lineLimit(style.summaryLines).lineSpacing(2)
                    .foregroundStyle(Color(paperHex: palette.mutedHex))
            }
            if style.role == .gallery, style.allocatedHeight != nil {
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if !entry.isRead { Circle().fill(Color(paperHex: palette.accentHex)).frame(width: 4, height: 4) }
                Text(entry.sourceTitle).lineLimit(1)
                if entry.isStarred { Image(systemName: "star.fill") }
                Spacer(minLength: 4)
                if let date = entry.publishedAt { Text(date, format: .dateTime.month().day()) }
            }
            .font(.system(size: 11)).foregroundStyle(Color(paperHex: palette.mutedHex))
        }
    }

    var body: some View {
        Group {
            if style.stacksImage {
                VStack(alignment: .leading, spacing: style.imageSpacing) { illustration; storyText }
            } else {
                HStack(alignment: .top, spacing: style.imageSpacing) {
                    storyText.frame(maxWidth: .infinity, alignment: .leading)
                    illustration
                }
            }
        }
        .frame(width: style.contentWidth(width), alignment: .topLeading)
        .frame(height: style.allocatedHeight.map { max(0, $0 - style.contentInset * 2) }, alignment: .topLeading)
        .padding(style.contentInset)
        .background {
            if style.role == .gallery {
                RoundedRectangle(cornerRadius: 9)
                    .fill(palette.colorScheme == .dark
                        ? Color(paperHex: palette.inkHex).opacity(0.035) : Color.white.opacity(0.32))
            }
            RoundedRectangle(cornerRadius: style.role == .gallery ? 9 : 6)
                .fill(selected ? Color(paperHex: palette.accentHex).opacity(0.09)
                    : Color(paperHex: palette.inkHex).opacity(hovered ? 0.04 : 0))
        }
        .overlay {
            if style.role == .gallery {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color(paperHex: palette.mutedHex).opacity(0.24), lineWidth: 0.7)
            }
        }
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Color(paperHex: palette.accentHex)).frame(width: 2)
                    .padding(.vertical, style.contentInset).offset(x: 4)
            }
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
