#if os(macOS)
import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// 测量与呈现共用字体、行距、内边距；已读与收藏不影响几何。
struct MagazineStoryStyle: Hashable, Sendable {
    enum Role: Hashable, Sendable { case lead, supporting, list, gallery }
    var role: Role = .lead
    var titleSize: CGFloat = 34
    var titleLines = 5
    var summaryLines = 3
    var imageHeight: CGFloat = 0
    var summarySize: CGFloat = 15
    var imageBesideText = false
    var textScale: CGFloat = 1
    var locale = ""
    var contentInset: CGFloat = 0
    var imageAspectRatio: CGFloat = 1.5
    var sideImageWidth: CGFloat?
    var stacksImage: Bool { !imageBesideText }
    /// 全局内容缩放：字体、行距与来源信息整体略收 5%，为更大的页边距留出呼吸感。
    /// 图片仍按栏宽与既定比例铺满，图文结构与对齐规则不变。
    static let contentScale: CGFloat = 0.95
    var titleFontSize: CGFloat { titleSize * textScale * Self.contentScale }
    var summaryFontSize: CGFloat { summarySize * textScale * Self.contentScale }
    var textSpacing: CGFloat { (role == .lead ? 10 : 6) * textScale * Self.contentScale }
    var metadataSpacing: CGFloat { (role == .lead ? 14 : 10) * textScale * Self.contentScale }
    var imageSpacing: CGFloat { 16 * Self.contentScale }
    var metadataSize: CGFloat { 13 * textScale * Self.contentScale }
    var titleLineSpacing: CGFloat { 2 * textScale * Self.contentScale }
    var summaryLineSpacing: CGFloat { 4 * textScale * Self.contentScale }
    func contentWidth(_ width: CGFloat) -> CGFloat { max(1, width - contentInset * 2) }
    func imageWidth(in width: CGFloat) -> CGFloat {
        stacksImage ? contentWidth(width) : (sideImageWidth ?? min(contentWidth(width) * 0.32, imageHeight * imageAspectRatio))
    }
    // 预加载与实际展示共用尺寸档位，避免开页后又下载另一份缩略图。
    func thumbnailRequest(for entry: EntryListItem, width: CGFloat, scale: CGFloat) -> ArticleThumbnailRequest? {
        guard imageHeight > 0, let url = entry.previewImageURL else { return nil }
        return .init(accountID: entry.accountID, url: url, pixelSize: Int(imageWidth(in: width) * scale))
    }
    static func titleFont(_ size: CGFloat) -> NSFont {
        // 中文使用系统可用的宋体，缺失字形由系统文本栈回退。
        NSFont(name: "Songti SC Bold", size: size)
            ?? NSFont(descriptor: NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.serif)
                ?? NSFont.systemFont(ofSize: size).fontDescriptor, size: size)
            ?? .systemFont(ofSize: size, weight: .semibold)
    }
    func measured(_ text: String, width: CGFloat, font: NSFont, lines: Int, spacing: CGFloat) -> CGFloat {
        guard !text.isEmpty, lines > 0 else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = spacing
        let rect = (text as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
        let line = ceil(font.ascender - font.descender + font.leading)
        return min(ceil(rect.height) + 3, line * CGFloat(lines) + spacing * CGFloat(max(0, lines - 1)) + 3)
    }
    func titleFits(_ entry: EntryListItem, width: CGFloat) -> Bool {
        let font = Self.titleFont(titleFontSize)
        return measured(entry.title, width: contentWidth(width), font: font, lines: 10000, spacing: titleLineSpacing)
            <= measured(entry.title, width: contentWidth(width), font: font, lines: titleLines, spacing: titleLineSpacing) + 1
    }
    func textHeight(for entry: EntryListItem, width: CGFloat) -> CGFloat {
        let textWidth = contentWidth(width) - (imageBesideText && imageHeight > 0 ? imageWidth(in: width) + imageSpacing : 0)
        let title = measured(entry.title, width: textWidth, font: Self.titleFont(titleFontSize),
                             lines: titleLines, spacing: titleLineSpacing)
        let summary = entry.isSummaryVisible ? measured(entry.summaryPreview, width: textWidth,
            font: .systemFont(ofSize: summaryFontSize), lines: summaryLines, spacing: summaryLineSpacing) : 0
        let metadata = ceil(metadataSize * 1.5)
        // 保留少量原生文本取整余量，不把剩余页面高度分摊给文字。
        return title + (summary > 0 ? textSpacing + summary : 0) + textSpacing + metadata + 8
    }
    func matchingSideImage(to entry: EntryListItem, width: CGFloat) -> Self {
        guard imageBesideText, imageHeight > 0 else { return self }
        var result = self
        // 先固定图片宽度，再按剩余文字宽度求高度，避免宽高相互推大。
        result.sideImageWidth = imageWidth(in: width)
        result.imageHeight = ceil(result.textHeight(for: entry, width: width))
        return result
    }
    func height(for entry: EntryListItem, width: CGFloat) -> CGFloat {
        let text = textHeight(for: entry, width: width)
        let body = stacksImage ? text + (imageHeight > 0 ? imageHeight + imageSpacing : 0) : max(text, imageHeight)
        return ceil(body + contentInset * 2)
    }
}

private struct MagazineStoryKey: EnvironmentKey { static let defaultValue: MagazineStoryStyle? = nil }
extension EnvironmentValues {
    var magazineStoryStyle: MagazineStoryStyle? {
        get { self[MagazineStoryKey.self] }
        set { self[MagazineStoryKey.self] = newValue }
    }
}

struct MagazinePlacement: Equatable, Sendable {
    let entryID: String
    let frame: CGRect
    let style: MagazineStoryStyle
}
struct MagazinePageLayout: Equatable, Sendable {
    enum Template: String, Sendable { case imageLead, feature, textLead, briefs, ending }
    enum Form: Sendable { case spread, single, flow }
    var page: MagazinePage
    let placements: [MagazinePlacement]
    let height: CGFloat
    var template: Template = .briefs
    var form: Form = .single
    var paperWidth: CGFloat = 0
    var inset: CGFloat = 32
    var isEnd = false
    var readingOrder: [String] { placements.map(\.entryID) }
    var consumedCount: Int { placements.count }
    var contentWidth: CGFloat { max(1, paperWidth - inset * 2) }
    var paperHeight: CGFloat { height + MagazinePaginator.headingHeight }
}

/// 缓存有界且可以在排版任务中使用，不保存文章对象或图片字节。
final class MagazineMeasurementCache: @unchecked Sendable {
    private struct Key: Hashable {
        let id: String
        let title: String
        let summary: String
        let source: String
        let visibleSummary: Bool
        let width: CGFloat
        let style: MagazineStoryStyle
        let version = 4
    }
    private let lock = NSLock()
    private var values: [Key: CGFloat] = [:]
    private var hits = 0
    var count: Int { lock.withLock { values.count } }
    var hitCount: Int { lock.withLock { hits } }
    func height(_ entry: EntryListItem, style: MagazineStoryStyle, width: CGFloat) -> CGFloat {
        let key = Key(id: entry.id, title: entry.title, summary: entry.summaryPreview, source: entry.sourceTitle,
                      visibleSummary: entry.isSummaryVisible, width: width, style: style)
        if let cached = lock.withLock({ () -> CGFloat? in
            guard let value = values[key] else { return nil }
            hits += 1
            return value
        }) { return cached }
        let measured = style.height(for: entry, width: width)
        lock.withLock {
            if values.count >= 4096 { values.removeAll(keepingCapacity: true) }
            values[key] = measured
        }
        return measured
    }
}

/// 固定栅格、连续队列和自然高度；候选窗口不构成人为分页边界。
enum MagazinePaginator {
    static let gutter: CGFloat = 40
    /// 上下页边一致；较上一版放宽，给纸面留出呼吸感（标题行 + 间距 + 上下内边距）。
    static let verticalInset: CGFloat = 20
    static let headingSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 24
    static let pairSpacing: CGFloat = 24
    static let supportSpacing: CGFloat = 24
    static let sectionSpacing: CGFloat = 32
    static let headingHeight: CGFloat = 20 + headingSpacing + verticalInset * 2
    static let railHeight: CGFloat = 52
    static func turnInset(_ size: CGSize) -> CGFloat { min(32, max(0, size.height - railHeight) * 0.10) }
    static func foldViewport(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: size.height - turnInset(size) * 2)
    }
    static func pageWidth(_ width: CGFloat) -> CGFloat { min(1280, max(1, width - (width < 620 ? 40 : 96))) }
    static func horizontalInset(_ width: CGFloat) -> CGFloat { min(width < 620 ? 24 : 40, (pageWidth(width) - 1) / 2) }
    static func contentWidth(_ width: CGFloat) -> CGFloat { max(1, pageWidth(width) - horizontalInset(width) * 2) }
    static func needsFlow(_ size: CGSize, textScale: CGFloat = 1) -> Bool {
        pageWidth(size.width) < 620 || size.height - railHeight < 460 || textScale >= 1.5
    }

    /// 内容已排完但叶底仍有余量时，让该叶最后一张竖排图按高度增长填平页脚。
    /// 只改图高与占位高度：缩略图按宽度预取，不需要重新下载；图片按 cover 裁切不拉伸。
    static func flushLeafTails(_ placements: [MagazinePlacement], leafWidth: CGFloat, gutter: CGFloat,
                               height: CGFloat, spread: Bool) -> [MagazinePlacement] {
        guard height > 0, !placements.isEmpty else { return placements }
        let columns: [ClosedRange<CGFloat>] = spread
            ? [0...leafWidth, (leafWidth + gutter)...(leafWidth * 2 + gutter)]
            : [0...max(leafWidth, placements.map(\.frame.maxX).max() ?? leafWidth)]
        var result = placements
        for column in columns {
            let indices = result.indices.filter { column.contains(result[$0].frame.minX) }
            guard let target = indices.max(by: { result[$0].frame.maxY < result[$1].frame.maxY }) else { continue }
            let placement = result[target]
            let extra = height - placement.frame.maxY
            guard extra >= 32, placement.style.stacksImage, placement.style.imageHeight > 0,
                  placement.style.imageHeight < leafWidth else { continue }
            // 叶底只处理独占的一张；并列双稿与组内稿件不拉伸。
            guard indices.allSatisfy({ $0 == target || result[$0].frame.maxY <= placement.frame.minY + 1 }) else { continue }
            let cap = floor(min(extra, 200, leafWidth - placement.style.imageHeight))
            guard cap >= 24 else { continue }
            var style = placement.style
            style.imageHeight += cap
            let frame = CGRect(x: placement.frame.minX, y: placement.frame.minY,
                               width: placement.frame.width, height: placement.frame.height + cap)
            result[target] = MagazinePlacement(entryID: placement.entryID, frame: frame, style: style)
        }
        return result
    }

    private struct Row {
        let placements: [MagazinePlacement]
        let height: CGFloat
        let void: CGFloat
    }
    private struct Path {
        var placements: [MagazinePlacement] = []
        var height: CGFloat = 0
        var void: CGFloat = 0
    }

    /// `cancelsWithTask` 仅由后台异步编排显式开启。同步调用默认不响应取消：
    /// 视图更新可能落在已取消的宿主任务上下文里，若把取消当输入，就会
    /// 把有文章的版面算成空页，用户会看到“暂无文章”。
    static func pages(entries: [EntryListItem], folders: [UUID: String], arrangement: MagazineArrangement,
                      size: CGSize, showsImages: Bool, hasMore: Bool = false, textScale: CGFloat = 1,
                      locale: String = "", imageRatios: [String: CGFloat] = [:],
                      measurements: MagazineMeasurementCache = MagazineMeasurementCache(),
                      cancelsWithTask: Bool = false) -> [MagazinePageLayout] {
        let paper = pageWidth(size.width)
        let inset = horizontalInset(size.width)
        let width = contentWidth(size.width)
        let height = max(1, size.height - railHeight - headingHeight)
        let flow = needsFlow(size, textScale: textScale)
        let spread = !flow && paper >= 860
        let leafWidth = spread ? (width - gutter) / 2 : width
        let groups = MagazineEdition.groups(entries: entries, arrangement: arrangement, folders: folders)
        var output: [MagazinePageLayout] = []

        func measure(_ entry: EntryListItem, _ style: MagazineStoryStyle, _ width: CGFloat) -> CGFloat {
            measurements.height(entry, style: style, width: width)
        }
        func normal(_ entry: EntryListItem, width: CGFloat, lead: Bool = false, unlimited: Bool = false) -> MagazineStoryStyle {
            let hasImage = showsImages && entry.previewImageURL != nil
            var style = MagazineStoryStyle(role: .supporting, titleSize: 24, titleLines: 3,
                textScale: textScale, locale: locale)
            if !hasImage && (!entry.isSummaryVisible || measure(entry, style, width) <= 155 * textScale) {
                style.role = .list; style.titleSize = 19; style.titleLines = 4
            }
            if lead { style.role = .lead; style.titleSize = 34; style.titleLines = hasImage ? 3 : 5 }
            if hasImage {
                style.imageBesideText = !lead && width >= 360
                style.imageHeight = style.imageBesideText ? min(112, width * 0.20) : style.contentWidth(width) / 1.5
                // 极长主标题使用文字主稿；不裁成大幅文字截图。
                if lead && !style.titleFits(entry, width: width) { style.imageHeight = 0; style.titleLines = 5 }
            }
            if unlimited { style.titleLines = 10000; style.summaryLines = 10000 }
            return unlimited ? style : style.matchingSideImage(to: entry, width: width)
        }
        func single(_ entry: EntryListItem, width: CGFloat, lead: Bool, unlimited: Bool = false) -> Row {
            let style = normal(entry, width: width, lead: lead, unlimited: unlimited)
            let h = measure(entry, style, width)
            return Row(placements: [.init(entryID: entry.id, frame: CGRect(x: 0, y: 0, width: width, height: h), style: style)],
                       height: h, void: 0)
        }
        func pair(_ first: EntryListItem, _ second: EntryListItem, width: CGFloat) -> Row? {
            let w = (width - pairSpacing) / 2
            guard w >= 220 else { return nil }
            let rows = [single(first, width: w, lead: false), single(second, width: w, lead: false)]
            guard rows[0].placements[0].style.titleFits(first, width: w),
                  rows[1].placements[0].style.titleFits(second, width: w),
                  abs(rows[0].height - rows[1].height) <= 64 else { return nil }
            let placements = rows.enumerated().map { index, row -> MagazinePlacement in
                let p = row.placements[0]
                return .init(entryID: p.entryID, frame: p.frame.offsetBy(dx: CGFloat(index) * (w + pairSpacing), dy: 0), style: p.style)
            }
            return Row(placements: placements, height: rows.map(\.height).max() ?? 0,
                       void: abs(rows[0].height - rows[1].height) * w)
        }
        func fitted(_ entry: EntryListItem, style: MagazineStoryStyle, width: CGFloat,
                    limit: CGFloat, minimumTitleLines: Int = 2, mayHideImage: Bool = false) -> MagazineStoryStyle? {
            var style = style
            while measure(entry, style, width) > limit && style.summaryLines > 0 { style.summaryLines -= 1 }
            while measure(entry, style, width) > limit && style.imageHeight > 72 {
                style.imageHeight = max(72, style.imageHeight - 24)
            }
            while measure(entry, style, width) > limit && style.titleLines > minimumTitleLines { style.titleLines -= 1 }
            if mayHideImage && measure(entry, style, width) > limit { style.imageHeight = 0 }
            style = style.matchingSideImage(to: entry, width: width)
            return measure(entry, style, width) <= limit ? style : nil
        }
        func supporting(_ entry: EntryListItem, width: CGFloat, limit: CGFloat) -> MagazineStoryStyle? {
            var style = MagazineStoryStyle(role: .supporting, titleSize: 19, titleLines: 3,
                summaryLines: 2, summarySize: 13, textScale: textScale, locale: locale)
            if showsImages && entry.previewImageURL != nil {
                style.imageBesideText = true
                style.imageHeight = min(112, width * 0.20)
            }
            return fitted(entry, style: style, width: width, limit: limit, minimumTitleLines: 2, mayHideImage: true)
        }
        /// 整叶主稿仅扩大图像，不拉伸文字；右叶仍连续装入正常图文。
        func featureSpread(_ items: ArraySlice<EntryListItem>) -> Path? {
            guard let first = items.first, showsImages, first.previewImageURL != nil,
                  items.count >= 5, height >= 460 else { return nil }
            var style = normal(first, width: leafWidth, lead: true)
            guard style.imageHeight > 0, style.titleFits(first, width: leafWidth) else { return nil }
            style.imageHeight = 0
            let textHeight = measure(first, style, leafWidth)
            let imageHeight = floor(height - textHeight - style.imageSpacing)
            guard imageHeight >= max(220, height * 0.48) else { return nil }
            style.imageHeight = imageHeight
            let leadHeight = measure(first, style, leafWidth)
            var placements: [MagazinePlacement] = [.init(entryID: first.id,
                frame: CGRect(x: 0, y: 0, width: leafWidth, height: leadHeight), style: style)]
            var y: CGFloat = 0
            for entry in items.dropFirst() {
                guard let side = supporting(entry, width: leafWidth, limit: .greatestFiniteMagnitude) else { break }
                let h = measure(entry, side, leafWidth)
                guard y + h <= height else { break }
                placements.append(.init(entryID: entry.id,
                    frame: CGRect(x: leafWidth + gutter, y: y, width: leafWidth, height: h), style: side))
                y += h + supportSpacing
            }
            // 右叶内容过少时恢复主稿加画廊，不让单幅图片换来半页空白。
            guard placements.count >= 4, y - supportSpacing >= height * 0.56 else { return nil }
            return Path(placements: placements, height: leadHeight)
        }
        func panel(_ entry: EntryListItem, width: CGFloat, wide: Bool, compactImage: Bool = false) -> MagazineStoryStyle {
            var style = MagazineStoryStyle(role: .gallery, titleSize: wide ? 22 : 18, titleLines: wide ? 3 : 4,
                summaryLines: wide ? 3 : 2, summarySize: wide ? 14 : 13,
                textScale: textScale, locale: locale)
            if showsImages && entry.previewImageURL != nil {
                if compactImage {
                    style.imageBesideText = true
                    style.imageHeight = 76
                } else {
                    style.imageHeight = style.contentWidth(width) / 1.85
                }
            }
            return style.matchingSideImage(to: entry, width: width)
        }
        /// 每叶独立向下推进：下一组连续稿件放进剩余空间更大的那一叶，以填满页面为先，
        /// 不再要求左右两组共享横向起点。叶内仍保留整栏、并列、双行短讯与短讯纵组的组合词汇。
        func editorialSpread(_ slice: ArraySlice<EntryListItem>, usesLead: Bool) -> Path {
            let items = Array(slice)
            guard !items.isEmpty else { return Path() }
            let laneWidth = (leafWidth - pairSpacing) / 2
            var placed: [MagazinePlacement] = []
            var cursor = 0
            var leftY: CGFloat = 0
            var rightY: CGFloat = 0

            func moved(_ path: Path, x: CGFloat, y: CGFloat) -> [MagazinePlacement] {
                path.placements.map {
                    .init(entryID: $0.entryID, frame: $0.frame.offsetBy(dx: x, dy: y), style: $0.style)
                }
            }
            func hasImage(_ entry: EntryListItem) -> Bool {
                showsImages && entry.previewImageURL != nil
            }
            func block(at index: Int, limit: CGFloat, compact: Bool) -> [Path] {
                guard index < items.count else { return [] }
                let entry = items[index]
                var options: [Path] = []
                func story(_ index: Int, width: CGFloat, wide: Bool) -> MagazinePlacement? {
                    var style = panel(items[index], width: width, wide: wide)
                    if compact {
                        // 页尾只精简摘要或改为旁图，不把所有标题压到两行。
                        style.summaryLines = min(1, style.summaryLines)
                        if hasImage(items[index]) { style = panel(items[index], width: width, wide: wide, compactImage: true) }
                        style.summaryLines = min(1, style.summaryLines)
                    }
                    style = style.matchingSideImage(to: items[index], width: width)
                    let h = measure(items[index], style, width)
                    guard h > limit else {
                        return .init(entryID: items[index].id,
                            frame: CGRect(x: 0, y: 0, width: width, height: h), style: style)
                    }
                    // 页尾收口：竖排图按剩余高度收缩，尽量保留标题与摘要预算。
                    guard !compact, !style.imageBesideText, style.imageHeight > 0,
                          let fit = fitted(items[index], style: style, width: width,
                                           limit: limit, minimumTitleLines: 2, mayHideImage: false) else { return nil }
                    let fittedHeight = measure(items[index], fit, width)
                    guard fittedHeight <= limit else { return nil }
                    return .init(entryID: items[index].id,
                        frame: CGRect(x: 0, y: 0, width: width, height: fittedHeight), style: fit)
                }
                if let full = story(index, width: leafWidth, wide: true) {
                    // 很短的纯文字短讯独占整栏会产生过长行宽；内容吃紧时也不为此删稿。
                    let brief = !hasImage(entry) && entry.summaryPreview.count < 40 && entry.title.count < 30
                    let cost: CGFloat = brief ? leafWidth * 22 : 0
                    options.append(Path(placements: [full], height: full.frame.height, void: cost))
                }
                if index + 1 < items.count, laneWidth >= 220,
                   let first = story(index, width: laneWidth, wide: false),
                   let second = story(index + 1, width: laneWidth, wide: false) {
                    let h = max(first.frame.height, second.frame.height)
                    let difference = abs(first.frame.height - second.frame.height)
                    // 不让一张高图片拖出相邻短讯下方的大洞。
                    if difference <= max(56, h * 0.24) {
                        let second = MagazinePlacement(entryID: second.entryID,
                            frame: second.frame.offsetBy(dx: laneWidth + pairSpacing, dy: 0), style: second.style)
                        // 并列图文保留完整标题预算；长摘要不再自动推成两条宽列表。
                        options.append(Path(placements: [first, second], height: h,
                            void: difference * laneWidth))
                    }
                }
                // 两行短讯共用行起点，最多四篇，禁止任意高低的四条独立瀑布列。
                if index + 3 < items.count, laneWidth >= 220,
                   items[index..<(index + 4)].allSatisfy({ !hasImage($0) }) {
                    var group: [MagazinePlacement] = []
                    var y: CGFloat = 0
                    var holes: CGFloat = 0
                    for row in 0..<2 {
                        guard let first = story(index + row * 2, width: laneWidth, wide: false),
                              let second = story(index + row * 2 + 1, width: laneWidth, wide: false) else { break }
                        let h = max(first.frame.height, second.frame.height)
                        guard abs(first.frame.height - second.frame.height) <= 56, y + h <= limit else { break }
                        group.append(.init(entryID: first.entryID, frame: first.frame.offsetBy(dx: 0, dy: y), style: first.style))
                        group.append(.init(entryID: second.entryID,
                            frame: second.frame.offsetBy(dx: laneWidth + pairSpacing, dy: y), style: second.style))
                        holes += abs(first.frame.height - second.frame.height) * laneWidth
                        y += h + rowSpacing
                    }
                    if group.count == 4 {
                        options.append(Path(placements: group, height: y - rowSpacing, void: holes))
                    }
                }
                // 短讯纵组可以与对面的跨栏图片配平；不掺入另一种小图卡样式。
                if !hasImage(entry) {
                    var group: [MagazinePlacement] = []
                    var y: CGFloat = 0
                    for i in index..<min(items.count, index + 3) {
                        guard !hasImage(items[i]) else { break }
                        var style = panel(items[i], width: leafWidth, wide: true)
                        style.titleSize = 19; style.summaryLines = compact ? 1 : 2; style.summarySize = 13
                        let h = measure(items[i], style, leafWidth)
                        guard y + h <= limit else { break }
                        group.append(.init(entryID: items[i].id,
                            frame: CGRect(x: 0, y: y, width: leafWidth, height: h), style: style))
                        y += h + rowSpacing
                        if group.count >= 2 {
                            options.append(Path(placements: group, height: y - rowSpacing,
                                void: leafWidth * 70))
                        }
                    }
                }
                return options
            }

            if usesLead {
                var leadStyle = normal(items[0], width: leafWidth, lead: true)
                if !hasImage(items[0]) {
                    // 无图长推文不应仅因标题字数多而成为五行巨型主稿。
                    leadStyle.titleSize = 30; leadStyle.titleLines = 3; leadStyle.summaryLines = 2
                }
                let leadLimit = min(height * 0.62, 520)
                if let fit = fitted(items[0], style: leadStyle, width: leafWidth,
                                    limit: leadLimit, minimumTitleLines: 3) { leadStyle = fit }
                let leadHeight = measure(items[0], leadStyle, leafWidth)
                guard leadHeight <= height else { return Path() }
                placed.append(.init(entryID: items[0].id,
                    frame: CGRect(x: 0, y: 0, width: leafWidth, height: leadHeight), style: leadStyle))
                cursor = 1
                leftY = leadHeight + sectionSpacing

                var rail: [MagazinePlacement] = []
                var railHeight: CGFloat = 0
                // 侧重稿最多四条；只受页面高度限制，不再按主稿高度提前截断。
                while cursor < items.count && rail.count < 4 {
                    let y = rail.isEmpty ? 0 : railHeight + supportSpacing
                    // 使用正常文字预算；不为了塞下一条而删掉图片、压缩标题。
                    guard let style = supporting(items[cursor], width: leafWidth, limit: .greatestFiniteMagnitude) else { break }
                    let h = measure(items[cursor], style, leafWidth)
                    guard y + h <= height else { break }
                    rail.append(.init(entryID: items[cursor].id,
                        frame: CGRect(x: leafWidth + gutter, y: y, width: leafWidth, height: h), style: style))
                    railHeight = y + h
                    cursor += 1
                }
                if rail.isEmpty { return Path() }
                // 仅微调组间距（最多额外 12pt），正文和点击区保持自然高度。
                if rail.count > 1 && leadHeight > railHeight {
                    let extra = min(12, (leadHeight - railHeight) / CGFloat(rail.count - 1))
                    rail = rail.enumerated().map { index, p in
                        .init(entryID: p.entryID, frame: p.frame.offsetBy(dx: 0, dy: CGFloat(index) * extra), style: p.style)
                    }
                    railHeight = rail.last?.frame.maxY ?? railHeight
                }
                placed += rail
                rightY = railHeight + sectionSpacing
            }

            /// 单叶候选：整栏／并列／短讯组，末尾附侧重稿收口，允许该叶本轮轮空。
            func leafOptions(at index: Int, room: CGFloat, compact: Bool) -> [Path] {
                guard index < items.count, room >= 64 else { return [Path()] }
                var options = block(at: index, limit: room, compact: compact)
                if options.isEmpty, let tail = tailStory(at: index, room: room) {
                    options.append(tail)
                }
                options.append(Path())
                return options
            }
            /// 页尾空间不足时，把下一篇压成侧重稿（摘要→旁图→文字列表）收口。
            func tailStory(at index: Int, room: CGFloat) -> Path? {
                guard index < items.count, room >= 64,
                      let style = supporting(items[index], width: leafWidth, limit: room) else { return nil }
                let h = measure(items[index], style, leafWidth)
                guard h <= room else { return nil }
                return Path(placements: [.init(entryID: items[index].id,
                    frame: CGRect(x: 0, y: 0, width: leafWidth, height: h), style: style)], height: h, void: 0)
            }
            /// 组内空洞、篇数与占用高度共同决定；越接近填满的组越优先。
            /// `heightWeight` 在内容吃紧时变大，让大图与整栏稿收口，而不是把短讯堆在页首。
            func leafScore(_ path: Path, room: CGFloat, compact: Bool, heightWeight: CGFloat) -> CGFloat {
                guard !path.placements.isEmpty else {
                    // 轮空意味着浪费该叶空间，只有在没有更好选择时才接受。
                    return room / max(1, height) * 40
                }
                let count = path.placements.count
                let narrow = path.placements.filter { $0.frame.width < leafWidth - 1 }.count
                var score = path.void / (leafWidth * max(1, path.height)) * 200
                score -= CGFloat(count) * 4 + CGFloat(narrow) * 5
                // 占用高度越高越接近填满；内容吃紧时权重大，避免把短讯堆在页首。
                score -= path.height / max(1, room) * heightWeight
                if compact { score += 8 }
                return score
            }

            while cursor < items.count && !(cancelsWithTask && Task.isCancelled) {
                let leftRoom = height - leftY
                let rightRoom = height - rightY
                guard max(leftRoom, rightRoom) >= 64 else { break }
                // 剩余内容按四栏短讯估算能占满多少；估不满时优先大版面块。
                let lanes = laneWidth >= 220 ? 4.0 : 2.0
                let projectedRows = (Double(items.count - cursor) + lanes - 1) / lanes
                let tight = projectedRows * 90 > Double(max(leftRoom, rightRoom))
                let heightWeight: CGFloat = tight ? 30 : 160
                var chosen: (left: Path, right: Path, score: CGFloat)?
                for compact in [false, true] {
                    for left in leafOptions(at: cursor, room: leftRoom, compact: compact) {
                        for right in leafOptions(at: cursor + left.placements.count, room: rightRoom, compact: compact) {
                            if left.placements.isEmpty && right.placements.isEmpty { continue }
                            let score = leafScore(left, room: leftRoom, compact: compact, heightWeight: heightWeight)
                                + leafScore(right, room: rightRoom, compact: compact, heightWeight: heightWeight)
                            if chosen == nil || score < chosen!.score {
                                chosen = (left, right, score)
                            }
                        }
                    }
                }
                guard let chosen else { break }
                // 左右两叶各自从自己的游标向下推进，短的一叶继续接稿而不是留下空洞。
                placed += moved(chosen.left, x: 0, y: leftY)
                placed += moved(chosen.right, x: leafWidth + gutter, y: rightY)
                if !chosen.left.placements.isEmpty { leftY += chosen.left.height + sectionSpacing }
                if !chosen.right.placements.isEmpty { rightY += chosen.right.height + sectionSpacing }
                cursor += chosen.left.placements.count + chosen.right.placements.count
            }
            let bottom = placed.map(\.frame.maxY).max() ?? 0
            return Path(placements: placed, height: bottom)
        }
        func appending(_ row: Row, to path: Path) -> Path {
            let y = path.placements.isEmpty ? 0 : path.height + rowSpacing
            return Path(placements: path.placements + row.placements.map {
                .init(entryID: $0.entryID, frame: $0.frame.offsetBy(dx: 0, dy: y), style: $0.style)
            }, height: y + row.height, void: path.void + row.void)
        }
        // 动态规划每次最多考察十二篇，随后从消费位置继续；每个前缀只保留最紧凑的合法路径。
        func pack(_ items: ArraySlice<EntryListItem>, width: CGFloat, limit: CGFloat, lead: Bool, compact: Bool) -> Path {
            let items = Array(items)
            var result = Path()
            var cursor = 0
            while cursor < items.count && !(cancelsWithTask && Task.isCancelled) {
                let count = min(12, items.count - cursor)
                var states: [Int: Path] = [0: result]
                for offset in 0..<count {
                    guard let path = states[offset] else { continue }
                    var options = [single(items[cursor + offset], width: width, lead: lead && cursor + offset == 0)]
                    if !(lead && cursor + offset == 0), offset + 1 < count,
                       let paired = pair(items[cursor + offset], items[cursor + offset + 1], width: width) { options.append(paired) }
                    for row in options {
                        let next = appending(row, to: path)
                        guard next.height <= limit else { continue }
                        let consumed = offset + row.placements.count
                        if let old = states[consumed], old.height < next.height || (old.height == next.height && old.void <= next.void) { continue }
                        states[consumed] = next
                    }
                }
                let consumed = states.keys.max() ?? 0
                if consumed > 0 { result = states[consumed]!; cursor += consumed }
                if consumed < count { break }
            }
            // 只有自然预算无法继续时精简紧邻页尾的一篇；不连续压缩整页。
            if compact && cursor < items.count {
                let entry = items[cursor]
                var style = normal(entry, width: width, lead: lead && cursor == 0)
                while style.summaryLines > 0 {
                    style.summaryLines -= 1
                    style = style.matchingSideImage(to: entry, width: width)
                    let h = measure(entry, style, width)
                    let row = Row(placements: [.init(entryID: entry.id, frame: CGRect(x: 0, y: 0, width: width, height: h), style: style)], height: h, void: 0)
                    let next = appending(row, to: result)
                    if next.height <= limit { return next }
                }
                if style.imageBesideText && style.imageHeight > 80 {
                    style.imageHeight = 80
                    let h = measure(entry, style, width)
                    let next = appending(Row(placements: [.init(entryID: entry.id,
                        frame: CGRect(x: 0, y: 0, width: width, height: h), style: style)], height: h, void: 0), to: result)
                    if next.height <= limit { return next }
                }
            }
            return result
        }

        for (groupIndex, group) in groups.enumerated() {
            var cursor = 0
            while cursor < group.entries.count {
                if cancelsWithTask && Task.isCancelled { return [] }
                let remaining = group.entries[cursor...]
                let first = remaining.first!
                let firstHasImage = showsImages && first.previewImageURL != nil
                let usesLead = remaining.count >= 4 && (firstHasImage || first.summaryPreview.count >= 96
                    || first.title.count >= 48)
                let leadStyle = normal(first, width: leafWidth, lead: usesLead)
                let template: MagazinePageLayout.Template = !usesLead ? .briefs : (leadStyle.imageHeight > 0 ? .imageLead : .textLead)
                var form: MagazinePageLayout.Form = spread ? .spread : .single
                var chosenPaper = paper
                var chosenHeight = height
                var chosenTemplate = template
                var placements: [MagazinePlacement] = []
                let endOfGroup = groupIndex == groups.count - 1 && !hasMore
                if !flow && endOfGroup {
                    let endingPaper = min(paper, 720)
                    let ending = pack(remaining, width: endingPaper - inset * 2, limit: height, lead: false, compact: false)
                    if ending.placements.count == remaining.count {
                        if spread {
                            let left = pack(remaining, width: leafWidth, limit: height, lead: false, compact: false)
                            if left.placements.count == remaining.count {
                                placements = left.placements
                                chosenHeight = height
                                chosenPaper = paper
                                form = .spread
                                chosenTemplate = .ending
                            }
                        } else {
                            placements = ending.placements
                            chosenHeight = height
                            chosenPaper = endingPaper
                            form = .single
                            chosenTemplate = .ending
                        }
                    }
                }
                if placements.isEmpty && !flow {
                    if spread {
                        // 稳定散列只控制低频穿插；内容充实或收藏稿优先，连续两版不重复整叶主稿。
                        let variation = first.id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                        let prefersFeature = first.isStarred || (first.isSummaryVisible && first.summaryPreview.count >= 160)
                            || (first.isSummaryVisible && variation % 4 == 0)
                        if prefersFeature, output.last?.template != .feature,
                           let feature = featureSpread(remaining) {
                            placements = feature.placements; chosenTemplate = .feature
                        } else {
                            let editorial = editorialSpread(remaining, usesLead: usesLead)
                            placements = editorial.placements
                        }
                    } else {
                        placements = pack(remaining, width: leafWidth, limit: height,
                            lead: usesLead, compact: true).placements
                    }
                    if spread && placements.isEmpty {
                        var left = pack(remaining, width: leafWidth, limit: height, lead: usesLead, compact: true)
                        var right = pack(remaining.dropFirst(left.placements.count), width: leafWidth,
                            limit: height, lead: false, compact: true)
                        let total = left.placements.count + right.placements.count
                        let originalLeftCount = left.placements.count
                        // 先保证消费数量，再在有限分界中比较叶面失衡；不拉伸短讯、不跨页挪稿。
                        if originalLeftCount > 1 {
                            for split in max(1, originalLeftCount - 12)..<originalLeftCount {
                                let candidateLeft = pack(remaining.prefix(split), width: leafWidth, limit: height, lead: usesLead, compact: false)
                                guard candidateLeft.placements.count == split else { continue }
                                let candidateRight = pack(remaining.dropFirst(split).prefix(total - split), width: leafWidth,
                                    limit: height, lead: false, compact: false)
                                guard candidateRight.placements.count == total - split else { continue }
                                let oldDifference = abs(left.height - right.height)
                                let newDifference = abs(candidateLeft.height - candidateRight.height)
                                if newDifference < oldDifference || (newDifference == oldDifference
                                    && candidateLeft.void + candidateRight.void < left.void + right.void) {
                                    left = candidateLeft; right = candidateRight
                                }
                            }
                        }
                        placements = left.placements + right.placements.map {
                            .init(entryID: $0.entryID, frame: $0.frame.offsetBy(dx: leafWidth + gutter, dy: 0), style: $0.style)
                        }
                    }
                }
                if flow || placements.isEmpty {
                    // 超高条目以连续流完整呈现，绝不靠裁成一行保证推进。
                    form = .flow
                    var path = Path()
                    for entry in remaining.prefix(flow ? 12 : 1) {
                        path = appending(single(entry, width: width, lead: false, unlimited: true), to: path)
                    }
                    placements = path.placements; chosenHeight = path.height
                }
                // 内容排完后叶底仍有余量时，让末张竖排图增高收口，避免页脚大面积空白。
                if !flow && chosenTemplate != .ending && !placements.isEmpty {
                    placements = flushLeafTails(placements, leafWidth: leafWidth, gutter: gutter,
                                                height: chosenHeight, spread: spread)
                }
                let accepted = Array(remaining.prefix(placements.count))
                let page = MagazinePage(id: group.id + ":" + first.id, title: group.title, entries: accepted)
                output.append(.init(page: page, placements: placements, height: chosenHeight, template: chosenTemplate,
                    form: form, paperWidth: chosenPaper, inset: inset,
                    isEnd: endOfGroup && placements.count == remaining.count))
                cursor += placements.count
            }
        }
        return output
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
        style.thumbnailRequest(for: entry, width: width, scale: scale)
    }
    private var imageWidth: CGFloat { style.imageWidth(in: width) }

    @ViewBuilder private var illustration: some View {
        if style.imageHeight > 0 {
            let activeImage = image ?? request.flatMap({ store.cachedImage(for: $0, allowFuzzySize: true) })
            Group {
                if let displayImage = activeImage, !failed {
                    Image(decorative: displayImage.image, scale: 1).resizable().scaledToFill()
                        .transition(.opacity)
                } else {
                    Color(paperHex: palette.mutedHex).opacity(0.045)
                        .transition(.opacity)
                }
            }
            .frame(width: imageWidth, height: style.imageHeight)
            .clipped()
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.15), value: activeImage != nil)
        }
    }

    private var metadataView: some View {
        HStack(spacing: 6) {
            if !entry.isRead { Circle().fill(Color(paperHex: palette.accentHex)).frame(width: 4, height: 4) }
            Text(entry.sourceTitle).lineLimit(1)
            if entry.isStarred { Image(systemName: "star.fill") }
            Spacer(minLength: 4)
            if let date = entry.publishedAt { Text(date, format: .dateTime.month().day()) }
        }
        .font(.system(size: style.metadataSize)).foregroundStyle(Color(paperHex: palette.mutedHex))
    }

    private var storyText: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: style.textSpacing) {
                Text(entry.title)
                    .font(Font(MagazineStoryStyle.titleFont(style.titleFontSize)))
                    .lineLimit(style.titleLines >= 10000 ? nil : style.titleLines).lineSpacing(style.titleLineSpacing)
                    .foregroundStyle(Color(paperHex: palette.inkHex).opacity(entry.isRead ? 0.88 : 1))
                if entry.isSummaryVisible && style.summaryLines > 0 {
                    Text(entry.summaryPreview).font(.system(size: style.summaryFontSize))
                        .lineLimit(style.summaryLines >= 10000 ? nil : style.summaryLines).lineSpacing(style.summaryLineSpacing)
                        .foregroundStyle(Color(paperHex: palette.mutedHex))
                }
            }
            if !style.stacksImage && style.imageHeight > 0 {
                Spacer(minLength: style.metadataSpacing)
            } else {
                Spacer(minLength: 0).frame(height: style.metadataSpacing)
            }
            metadataView
        }
    }

    var body: some View {
        Group {
            if style.stacksImage {
                VStack(alignment: .leading, spacing: style.imageSpacing) { illustration; storyText }
            } else {
                HStack(alignment: .top, spacing: style.imageSpacing) {
                    illustration
                    storyText
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: style.imageHeight, alignment: .topLeading)
                }
            }
        }
        .frame(width: style.contentWidth(width), alignment: .topLeading)
        .padding(style.contentInset)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(selected ? Color(paperHex: palette.accentHex).opacity(0.09)
                : Color(paperHex: palette.inkHex).opacity(hovered ? 0.04 : 0))
                .padding(-8)
        }
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Color(paperHex: palette.accentHex)).frame(width: 2)
                    .padding(.vertical, 4).offset(x: -8)
            }
        }
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .task(id: request) {
            failed = false
            guard let request else { image = nil; return }
            if let cached = store.cachedImage(for: request, allowFuzzySize: true) {
                image = cached
            }
            do {
                let loaded = try await store.image(for: request)
                try Task.checkCancellation()
                withAnimation(.easeOut(duration: 0.15)) {
                    image = loaded
                }
            } catch {
                if !Task.isCancelled {
                    image = nil
                    failed = true
                }
            }
        }
    }
}
#endif
