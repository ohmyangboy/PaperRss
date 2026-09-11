import Foundation

public struct ParsedFeed: Sendable {
    public var title: String
    public var siteURL: URL?
    public var iconURL: URL?
    public var entries: [ParsedFeedEntry]
    public var languageHints: [ArticleLanguageHint] = []
}

public struct ParsedFeedEntry: Sendable {
    public var id: String
    public var title: String
    public var author: String?
    public var url: URL?
    public var publishedAt: Date?
    public var summary: String
    public var contentHTML: String?
    public var languageHints: [ArticleLanguageHint] = []
    public var previewImage: EntryPreviewImage? = nil
}

public enum FeedParserError: LocalizedError {
    case unsupported
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unsupported: I18N.localized("此地址不是可识别的 RSS、Atom 或 JSON Feed。")
        case .malformed: I18N.localized("Feed 内容格式不完整。")
        }
    }
}

public enum FeedParser {
    public static func parse(data: Data, baseURL: URL) throws -> ParsedFeed {
        let trimmed = data.drop(while: { $0 == 9 || $0 == 10 || $0 == 13 || $0 == 32 })
        if trimmed.first == UInt8(ascii: "{") {
            return try parseJSON(data: data, baseURL: baseURL)
        }
        let parser = XMLFeedParser(baseURL: baseURL)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw FeedParserError.malformed }
        return try parser.result()
    }

    private static func parseJSON(data: Data, baseURL: URL) throws -> ParsedFeed {
        struct JSONFeed: Decodable {
            struct Item: Decodable {
                var language: String?
                var id: String?
                var url: String?
                var external_url: String?
                var title: String?
                var image: String?
                var banner_image: String?
                var attachments: [Attachment]?
                struct Attachment: Decodable {
                    var url: String
                    var mime_type: String?
                }
                var content_html: String?
                var content_text: String?
                var summary: String?
                var date_published: String?
                var authors: [Author]?
                struct Author: Decodable { var name: String? }
            }
            var language: String?
            var version: String?
            var title: String?
            var home_page_url: String?
            var icon: String?
            var favicon: String?
            var items: [Item]?
        }
        let decoded = try JSONDecoder().decode(JSONFeed.self, from: data)
        guard decoded.version != nil else { throw FeedParserError.unsupported }
        let items = (decoded.items ?? []).map { item in
            let link = URL(string: item.url ?? item.external_url ?? "", relativeTo: baseURL)?.absoluteURL
            let body = item.content_html ?? item.content_text
            return ParsedFeedEntry(
                id: item.id ?? link?.absoluteString ?? UUID().uuidString,
                title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "未命名文章",
                author: item.authors?.first?.name,
                url: link,
                publishedAt: parseDate(item.date_published),
                summary: item.summary ?? body?.plainText ?? "",
                contentHTML: item.content_html ?? item.content_text,
                languageHints: item.language.map { [ArticleLanguageHint(language: $0, scope: "json:item")] } ?? [],
                previewImage: EntryPreviewImageExtractor.extract(
                    explicit: [item.image, item.banner_image].compactMap { $0 }.map {
                        .init($0, source: "json-image")
                    } + (item.attachments ?? []).filter {
                        $0.mime_type?.lowercased().hasPrefix("image/") == true
                    }.map { .init($0.url, source: "enclosure") },
                    contentHTML: item.content_html,
                    baseURL: link ?? baseURL
                )
            )
        }
        let iconURLString = decoded.icon ?? decoded.favicon
        let iconURL = iconURLString.flatMap { URL(string: $0) }
        return ParsedFeed(title: decoded.title?.nonEmpty ?? "未命名订阅", siteURL: URL(string: decoded.home_page_url ?? ""), iconURL: iconURL, entries: items, languageHints: decoded.language.map { [ArticleLanguageHint(language: $0, scope: "json:feed")] } ?? [])
    }

    fileprivate static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        let formatters = ["EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss"]
        for format in formatters {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private final class XMLFeedParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var root = ""
    private var languageStack: [String] = []
    private var feedLanguageHints: [ArticleLanguageHint] = []
    private var itemLanguageHints: [ArticleLanguageHint] = []
    private var currentElement = ""
    private var currentText = ""
    private var feedTitle = ""
    private var feedLink: URL?
    private var feedIconURL: URL?
    private var inImageTag = false
    private var currentItem: [String: String]?
    private var currentItemLink: URL?
    private var entries: [ParsedFeedEntry] = []
    private var namespaceStack: [[String: String]] = []
    private var baseURLStack: [URL] = []
    private var elementStack: [String] = []
    private var itemImages: [EntryPreviewImageExtractor.Candidate] = []
    private var inlineDescriptionImages = ""
    private var inlineContentImages = ""

    private func isMediaElement(_ name: String) -> Bool {
        let pieces = name.split(separator: ":", maxSplits: 1)
        let prefix = pieces.count == 2 ? String(pieces[0]) : ""
        let uri = namespaceStack.last?[prefix]?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return uri == "http://search.yahoo.com/mrss" || uri == "https://search.yahoo.com/mrss"
    }

    init(baseURL: URL) { self.baseURL = baseURL }

    /// XMLParser hands the qualified name to `elementName` when
    /// `shouldProcessNamespaces` is off (the default). Feed module elements
    /// arrive as "content:encoded" / "dc:creator"; only the unqualified
    /// local part is matched against the extraction cases.
    private static func localName(of elementName: String) -> String {
        elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        // XMLParser reports qualified names ("content:encoded", "dc:creator")
        // when namespaces are not processed, so strip the prefix before
        // matching against the unqualified cases below.
        let local = Self.localName(of: elementName)
        var namespaces = namespaceStack.last ?? [:]
        for (key, value) in attributeDict {
            if key == "xmlns" { namespaces[""] = value }
            else if key.hasPrefix("xmlns:") { namespaces[String(key.dropFirst(6))] = value }
        }
        namespaceStack.append(namespaces)
        let inheritedBase = baseURLStack.last ?? baseURL
        let elementBase = attributeDict["xml:base"].flatMap { URL(string: $0, relativeTo: inheritedBase)?.absoluteURL } ?? inheritedBase
        baseURLStack.append(elementBase)
        elementStack.append(local)
        let inherited = attributeDict["xml:lang"] ?? languageStack.last ?? ""
        languageStack.append(inherited)
        if local == "feed", !inherited.isEmpty {
            feedLanguageHints.append(.init(language: inherited, scope: "atom:feed"))
        }
        currentElement = local
        currentText = ""
        if root.isEmpty { root = local }
        if local == "image", currentItem == nil { inImageTag = true }
        if local == "item" || local == "entry" {
            currentItem = [:]
            itemImages = []
            inlineDescriptionImages = ""
            inlineContentImages = ""
            itemLanguageHints = inherited.isEmpty ? [] : [.init(language: inherited, scope: "atom:entry")]

            currentItemLink = nil
        }
        if currentItem != nil, ["content", "summary", "description"].contains(local), !inherited.isEmpty {
            itemLanguageHints.append(.init(language: inherited, scope: "atom:\(local)"))
        }
        if currentItem != nil {
            let media = isMediaElement(elementName)
            let mime = attributeDict["type"]?.lowercased() ?? ""
            let isImage = mime.hasPrefix("image/") || attributeDict["medium"]?.lowercased() == "image"
            let enclosure = local == "enclosure" || (local == "link" && attributeDict["rel"]?.lowercased() == "enclosure")
            let attrs = attributeDict.sorted { $0.key < $1.key }.map {
                "\($0.key)=\"\($0.value.replacingOccurrences(of: "\"", with: "&quot;"))\""
            }.joined(separator: " ")
            if (media && (local == "thumbnail" || (local == "content" && isImage))) || (enclosure && isImage) {
                if EntryPreviewImageExtractor.isUsableImageAttributes(attrs),
                   let raw = attributeDict["url"] ?? attributeDict["href"],
                   let url = EntryPreviewImageExtractor.safeURL(raw, baseURL: elementBase) {
                    itemImages.append(.init(url.absoluteString, source: media ? "media" : "enclosure"))
                }
            }
            // Atom XHTML content may contain actual XML img elements rather
            // than CDATA. Capture their attributes independently of body text.
            if local == "img", EntryPreviewImageExtractor.isUsableImageAttributes(attrs),
               let url = ArticleExtractor.extractBestImageURL(from: attrs, baseURL: elementBase) {
                let image = "<img src=\"\(url.absoluteString.replacingOccurrences(of: "\"", with: "&quot;"))\">"
                if elementStack.contains("description") || elementStack.contains("summary") {
                    inlineDescriptionImages += image
                } else if elementStack.contains("content") || elementStack.contains("encoded") {
                    inlineContentImages += image
                }
            }
        }
        if local == "link" {
            let href = attributeDict["href"] ?? attributeDict["url"]
            if let href, let url = URL(string: href, relativeTo: elementBase)?.absoluteURL {
                if currentItem != nil {
                    let relation = attributeDict["rel"]?.lowercased() ?? "alternate"
                    if relation == "alternate", currentItemLink == nil { currentItemLink = url }
                } else if attributeDict["rel"]?.lowercased() != "self" {
                    // Atom's rel="self" points back to the feed endpoint,
                    // not to the site that owns the feed.
                    feedLink = url
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { currentText += String(data: CDATABlock, encoding: .utf8) ?? "" }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = Self.localName(of: elementName)
        defer {
            if !languageStack.isEmpty { languageStack.removeLast() }
            if !namespaceStack.isEmpty { namespaceStack.removeLast() }
            if !baseURLStack.isEmpty { baseURLStack.removeLast() }
            if !elementStack.isEmpty { elementStack.removeLast() }
        }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if var item = currentItem {
            switch local {
            case "title", "id", "guid", "author", "name", "creator", "summary", "description", "content", "encoded", "pubdate", "published", "updated", "link":
                if !text.isEmpty && !isMediaElement(elementName) {
                    let key: String
                    if local == "encoded" { key = "content" }
                    else if local == "creator" { key = "author" } // RSS 2.0 <dc:creator>
                    else if local == "name" && item["author"] == nil { key = "author" }
                    else { key = local }
                    // First writer wins. Without the prefix strip a module
                    // element like <media:content> could otherwise overwrite
                    // the real body extracted from <content:encoded>.
                    if item[key] == nil { item[key] = text }
                }
            default: break
            }
            currentItem = item
        } else {
            if local == "language", !text.isEmpty {
                feedLanguageHints.append(.init(language: text, scope: "rss:channel"))
            }
            if local == "title" && !text.isEmpty {
                feedTitle = text
            } else if (local == "icon" || local == "logo" || (local == "url" && inImageTag)) && !text.isEmpty && feedIconURL == nil {
                feedIconURL = URL(string: text, relativeTo: baseURL)?.absoluteURL
            }
            if local == "image" { inImageTag = false }
        }

        if local == "item" || local == "entry", let item = currentItem {
            let linkString = currentItemLink?.absoluteString ?? item["link"]
            let link = linkString.flatMap { URL(string: $0, relativeTo: baseURLStack.last ?? baseURL)?.absoluteURL }
            let body = item["content"] ?? item["summary"] ?? item["description"]
            let stable = item["guid"] ?? item["id"] ?? link?.absoluteString ?? "\(item["title"] ?? "")|\(item["published"] ?? item["pubdate"] ?? UUID().uuidString)"
            entries.append(ParsedFeedEntry(
                id: stable,
                title: item["title"]?.nonEmpty ?? "未命名文章",
                author: item["author"],
                url: link,
                publishedAt: FeedParser.parseDate(item["published"] ?? item["updated"] ?? item["pubdate"]),
                summary: item["summary"]?.plainText ?? item["description"]?.plainText ?? body?.plainText ?? "",
                contentHTML: body,
                languageHints: itemLanguageHints,
                previewImage: EntryPreviewImageExtractor.extract(
                    explicit: itemImages,
                    descriptionHTML: [item["description"], item["summary"], inlineDescriptionImages].compactMap { $0 }.joined(separator: "\n"),
                    contentHTML: (item["content"] ?? "") + inlineContentImages,
                    baseURL: link ?? baseURLStack.last ?? baseURL
                )
            ))
            currentItem = nil
            currentItemLink = nil
        }
        currentElement = ""
        currentText = ""
    }

    func result() throws -> ParsedFeed {
        guard root == "rss" || root == "feed" || root == "rdf" || !entries.isEmpty else { throw FeedParserError.unsupported }
        // A number of RSS proxies omit the channel homepage. The first item
        // still normally carries the publisher URL, which is a useful and
        // stable source for favicon fallback.
        let siteURL = feedLink ?? entries.compactMap(\.url).first.flatMap(Self.originURL)
        return ParsedFeed(title: feedTitle.nonEmpty ?? "未命名订阅", siteURL: siteURL, iconURL: feedIconURL, entries: entries, languageHints: feedLanguageHints)
    }

    private static func originURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
