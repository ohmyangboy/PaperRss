import Foundation

public enum OPMLService {
    public static func importURLs(data: Data) -> [URL] {
        let parser = OPMLParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        _ = xml.parse()
        return Array(Set(parser.urls)).sorted { $0.absoluteString < $1.absoluteString }
    }

    public static func export(feeds: [Feed]) -> Data {
        let outlines: [String] = feeds.filter { !$0.isDeleted }.map { (feed: Feed) -> String in
            let title = escape(feed.title)
            let url = escape(feed.feedURL.absoluteString)
            let site = feed.siteURL.map { " htmlUrl=\"\(escape($0.absoluteString))\"" } ?? ""
            return "    <outline text=\"\(title)\" title=\"\(title)\" type=\"rss\" xmlUrl=\"\(url)\"\(site) />"
        }
        let joinedOutlines = outlines.joined(separator: "\n")
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>PaperRss subscriptions</title></head>
          <body>
        \(joinedOutlines)
          </body>
        </opml>
        """.utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

private final class OPMLParser: NSObject, XMLParserDelegate {
    var urls: [URL] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName.lowercased() == "outline", let value = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"], let url = URL(string: value) else { return }
        urls.append(url)
    }
}
