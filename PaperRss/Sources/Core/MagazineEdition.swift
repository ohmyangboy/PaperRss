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
    case scroll, fold
    public var title: String {
        self == .scroll ? I18N.localized("滚动浏览") : I18N.localized("折叠翻页")
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

    /// No fixed lead slot for text-only editions. A real illustration earns a
    /// wider column; the surrounding stories pack into the remaining space.
    public func featuredID(showsImages: Bool) -> String? {
        guard showsImages, entries.count >= 3 else { return nil }
        return entries.first(where: { $0.previewImageURL != nil })?.id
    }
}

public enum MagazineEdition {
    public static func pages(entries: [EntryListItem], arrangement: MagazineArrangement,
                             folders: [UUID: String] = [:], capacity: Int = 6) -> [MagazinePage] {
        let capacity = min(12, max(1, capacity))
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
        var result: [MagazinePage] = []
        for (key, label, articles) in groups {
            for offset in stride(from: 0, to: articles.count, by: capacity) {
                let chunk = Array(articles[offset..<min(offset + capacity, articles.count)])
                let ordered: [EntryListItem]
                if arrangement == .balanced {
                    // Cluster only within a bounded page so later SQL pages do
                    // not reshuffle an already browsed issue on every append.
                    var rank: [UUID: Int] = [:]
                    for article in chunk where rank[article.feedID] == nil { rank[article.feedID] = rank.count }
                    ordered = chunk.enumerated().sorted {
                        let lhs = rank[$0.element.feedID] ?? 0, rhs = rank[$1.element.feedID] ?? 0
                        return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                    }.map(\.element)
                } else { ordered = chunk }
                let title = Set(ordered.map(\.feedID)).count == 1 ? (ordered.first?.sourceTitle ?? label) : label
                result.append(MagazinePage(id: key + ":" + chunk[0].id, title: title, entries: ordered))
            }
        }
        return result
    }

    public static func pageIndex(containing anchor: String?, in pages: [MagazinePage]) -> Int {
        guard let anchor else { return 0 }
        return pages.firstIndex { $0.entries.contains { $0.id == anchor } } ?? 0
    }
}
