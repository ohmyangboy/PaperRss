import Foundation

public struct OPMLSubscription: Sendable, Equatable {
    public let feedURL: URL
    public let title: String?
    public let siteURL: URL?
    public let folder: String?
}

public struct OPMLDocument: Sendable, Equatable {
    public let subscriptions: [OPMLSubscription]
    public let folders: [String]
}

public enum OPMLImportError: LocalizedError, Sendable {
    case invalidDocument
    public var errorDescription: String? {
        I18N.localized("无法读取 OPML 文件，请检查文件格式。", englishFallback: "Unable to read the OPML file. Check its format.")
    }
}

public struct SubscriptionImportResult: Sendable, Equatable {
    public var movedCount = 0
    public var addedCount = 0
    public var skippedCount = 0
    public var failedTitles: [String] = []

    @MainActor public var summary: String {
        if movedCount > 0 {
            return I18N.shared.localized("已移动 \(movedCount) 个；已添加 \(addedCount) 个，已存在 \(skippedCount) 个，失败 \(failedTitles.count) 个。",
                "Moved \(movedCount); added \(addedCount), already subscribed \(skippedCount), failed \(failedTitles.count).")
        }
        return I18N.shared.localized("已添加 \(addedCount) 个，已存在 \(skippedCount) 个，失败 \(failedTitles.count) 个。",
                              "Added \(addedCount), already subscribed \(skippedCount), failed \(failedTitles.count).")
    }
}

public enum OPMLService {
    /// Parse the whole document before making any database changes. DTDs and
    /// external entities are unnecessary for OPML and must never read files.
    public static func parse(data: Data) throws -> OPMLDocument {
        guard String(data: data, encoding: .utf8)?.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil
        else { throw OPMLImportError.invalidDocument }
        let delegate = OPMLParser()
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = delegate
        guard xml.parse(), delegate.hasRoot, delegate.hasBody, !delegate.invalid else {
            throw OPMLImportError.invalidDocument
        }
        return OPMLDocument(subscriptions: delegate.subscriptions, folders: delegate.folders)
    }

    public static func importURLs(data: Data) -> [URL] {
        guard let document = try? parse(data: data) else { return [] }
        return Array(Set(document.subscriptions.map(\.feedURL))).sorted { $0.absoluteString < $1.absoluteString }
    }

    public static func export(
        feeds: [Feed], folders: [String] = [], memberships: [UUID: [String]] = [:]
    ) -> Data {
        var seen = Set<UUID>()
        let unique = feeds.filter { !$0.isDeleted && seen.insert($0.id).inserted }
        func groups(_ feed: Feed) -> [String] {
            memberships[feed.id] ?? feed.folder.map { [$0] } ?? []
        }
        var folderSet = Set(folders)
        for feed in unique { folderSet.formUnion(groups(feed)) }
        func outline(_ feed: Feed, indent: String) -> String {
            let title = escape(feed.title)
            let site = feed.siteURL.map { " htmlUrl=\"\(escape($0.absoluteString))\"" } ?? ""
            return "\(indent)<outline text=\"\(title)\" title=\"\(title)\" type=\"rss\" xmlUrl=\"\(escape(feed.feedURL.absoluteString))\"\(site) />"
        }
        var outlines = unique.filter { groups($0).isEmpty }.map { outline($0, indent: "    ") }
        for folder in folderSet.sorted() {
            outlines.append("    <outline text=\"\(escape(folder))\" title=\"\(escape(folder))\">")
            outlines += unique.filter { groups($0).contains(folder) }.map { outline($0, indent: "      ") }
            outlines.append("    </outline>")
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>PaperRss subscriptions</title></head>
          <body>
        \(outlines.joined(separator: "\n"))
          </body>
        </opml>
        """.utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class OPMLParser: NSObject, XMLParserDelegate {
    var subscriptions: [OPMLSubscription] = []
    var folders: [String] = []
    var hasRoot = false
    var hasBody = false
    var invalid = false
    private var stack: [String?] = []
    private var folderSet = Set<String>()
    private var depth = 0
    private var bodyDepth: Int?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        depth += 1
        let name = elementName.lowercased()
        if depth == 1 { hasRoot = name == "opml" }
        if name == "body", depth == 2 { hasBody = true; bodyDepth = depth }
        guard name == "outline", bodyDepth != nil else { return }
        let values = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let title = ["title", "text"].compactMap { values[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if let value = values["xmlurl"] {
            guard let url = webURL(value) else { invalid = true; parser.abortParsing(); return }
            let path = stack.compactMap { $0 }
            subscriptions.append(.init(feedURL: url, title: title?.isEmpty == false ? title : nil,
                siteURL: values["htmlurl"].flatMap(webURL), folder: path.isEmpty ? nil : path.joined(separator: " / ")))
            stack.append(nil)
        } else {
            let group = title?.isEmpty == false ? title : nil
            stack.append(group)
            let path = stack.compactMap { $0 }
            if !path.isEmpty {
                // PaperRss has one folder level. Preserve nested source names
                // as a visible path rather than silently dropping ancestors.
                let folder = path.joined(separator: " / ")
                if folderSet.insert(folder).inserted { folders.append(folder) }
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "outline", bodyDepth != nil, !stack.isEmpty { stack.removeLast() }
        if depth == bodyDepth { bodyDepth = nil }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        invalid = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        invalid = true
        parser.abortParsing()
    }

    private func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
        return url
    }
}
