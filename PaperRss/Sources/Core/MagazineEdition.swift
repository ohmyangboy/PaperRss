import Foundation

/// Presentation-only ordering. Database queries and the list reader's chronology
/// remain unchanged. Every loaded ID appears exactly once in an edition.
public enum MagazineArrangement: String, CaseIterable, Sendable {
    case balanced, source, folder, chronological
    public var title: String {
        switch self {
        case .balanced: I18N.localized("智能编排")
        case .source: I18N.localized("按订阅源")
        case .folder: I18N.localized("按文件夹")
        case .chronological: I18N.localized("按时间")
        }
    }
}

public enum MagazineTurning: String, CaseIterable, Sendable {
    case scroll, fold, fade
    public var title: String {
        switch self {
        case .scroll: I18N.localized("滚动浏览")
        case .fold: I18N.localized("折叠翻页")
        case .fade: I18N.localized("淡入淡出")
        }
    }
}

public struct MagazinePage: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let entries: [EntryListItem]

    public init(id: String, title: String, entries: [EntryListItem]) {
        self.id = id
        self.title = title
        self.entries = entries
    }

    /// 只允许当前首篇成为图像主稿，不提升后面的有图文章。
    public func featuredID(showsImages: Bool) -> String? {
        guard showsImages, let first = entries.first, first.previewImageURL != nil else { return nil }
        return first.id
    }
}

public enum MagazineEdition {
    /// 分组不承担分页；布局器可以跨越任意文章数量继续填充。
    public static func groups(entries: [EntryListItem], arrangement: MagazineArrangement,
                              folders: [UUID: String] = [:]) -> [MagazinePage] {
        var seen = Set<String>()
        let entries = entries.filter { seen.insert($0.id).inserted }
        var groups: [(String, String, [EntryListItem])] = []
        var indices: [String: Int] = [:]
        for entry in entries {
            let key: String
            let label: String
            switch arrangement {
            case .source:
                key = entry.accountID + ":" + entry.feedID.uuidString
                label = entry.sourceTitle
            case .folder:
                let folder = folders[entry.feedID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                key = entry.accountID + ":" + folder
                label = folder.isEmpty ? I18N.localized("未分类") : folder
            case .balanced, .chronological:
                key = "edition"
                label = I18N.localized("本期选读")
            }
            if let index = indices[key] { groups[index].2.append(entry) }
            else { indices[key] = groups.count; groups.append((key, label, [entry])) }
        }
        return groups.map { key, label, articles in
            MagazinePage(id: key + ":" + articles[0].id, title: label, entries: articles)
        }
    }

    /// 兼容无视口的调用方，智能编排与时间模式均保持输入顺序。
    public static func pages(entries: [EntryListItem], arrangement: MagazineArrangement,
                             folders: [UUID: String] = [:], capacity: Int = 6) -> [MagazinePage] {
        let capacity = min(12, max(1, capacity))
        return groups(entries: entries, arrangement: arrangement, folders: folders).flatMap { group in
            stride(from: 0, to: group.entries.count, by: capacity).map { offset in
                let chunk = Array(group.entries[offset..<min(offset + capacity, group.entries.count)])
                return MagazinePage(id: group.id + ":" + chunk[0].id, title: group.title, entries: chunk)
            }
        }
    }

    public static func pageIndex(containing anchor: String?, in pages: [MagazinePage]) -> Int {
        guard let anchor else { return 0 }
        return pages.firstIndex { $0.entries.contains { $0.id == anchor } } ?? 0
    }
}
