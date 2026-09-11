import Foundation

/// A completed, network-free extraction. A nil URL with revision 1 means “no
/// usable image”, not “unprocessed”. Network failures belong to the byte cache.
public struct EntryPreviewImage: Sendable, Equatable {
    public static let currentRevision = 1
    public let url: URL?
    public let source: String?
    public let inputHash: String
    public let revision: Int
}

public enum EntryPreviewImageExtractor {
    public struct Candidate: Sendable, Equatable {
        public let url: String
        public let source: String
        public init(_ url: String, source: String) {
            self.url = url
            self.source = source
        }
    }

    /// No reader preparation, DOM execution, disk access or network access.
    public static func extract(
        explicit: [Candidate] = [],
        descriptionHTML: String? = nil,
        contentHTML: String? = nil,
        baseURL: URL?
    ) -> EntryPreviewImage {
        // Length prefixes avoid ambiguities when HTML contains separators.
        let inputs = explicit.flatMap { [$0.source, $0.url] }
            + [descriptionHTML ?? "", contentHTML ?? "", baseURL?.absoluteString ?? ""]
        let hash = inputs.map { "\($0.utf8.count):\($0)" }.joined().stableDigest
        var selected: URL?
        var source: String?
        for candidate in explicit {
            if let url = safeURL(candidate.url, baseURL: baseURL), isContentImage(url) {
                selected = url
                source = candidate.source
                break
            }
        }
        if selected == nil, let html = descriptionHTML, let url = firstImage(in: html, baseURL: baseURL) {
            selected = url
            source = "description"
        }
        if selected == nil, let html = contentHTML, let url = firstImage(in: html, baseURL: baseURL) {
            selected = url
            source = "content"
        }
        return EntryPreviewImage(url: selected, source: source, inputHash: hash,
                                 revision: EntryPreviewImage.currentRevision)
    }

    public static func safeURL(_ raw: String, baseURL: URL? = nil) -> URL? {
        guard let url = ArticleExtractor.safeRemoteURL(raw, baseURL: baseURL),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static let imageExpression = try! NSRegularExpression(
        pattern: "(?is)<img\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>"
    )

    public static func firstImage(in html: String, baseURL: URL?) -> URL? {
        // Only examine a bounded prefix of an unusually large feed payload.
        // The full content remains untouched for the reader.
        let html = String(html.prefix(512_000))
            .replacingOccurrences(of: "(?is)<!--.*?-->|<(script|style)\\b[^>]*>.*?</\\1>",
                                  with: "", options: .regularExpression)
        var result: URL?
        imageExpression.enumerateMatches(in: html, range: NSRange(html.startIndex..., in: html)) { match, _, stop in
            guard let match, let range = Range(match.range(at: 1), in: html) else { return }
            let attributes = String(html[range])
            guard isUsableImageAttributes(attributes),
                  let rawURL = ArticleExtractor.extractBestImageURL(from: attributes, baseURL: baseURL),
                  let url = safeURL(rawURL.absoluteString), isContentImage(url) else { return }
            result = url
            stop.pointee = true
        }
        return result
    }

    static func isUsableImageAttributes(_ attributes: String) -> Bool {
        let map = ArticleExtractor.parseAttributesMap(from: attributes)
        let tokens = ((map["class"] ?? "") + " " + (map["role"] ?? "")).lowercased()
        if tokens.contains("emoji") || tokens.contains("emoticon") || tokens.contains("avatar") { return false }
        if map["hidden"] != nil || map["aria-hidden"] == "true" { return false }
        let style = (map["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if style.contains("display:none") || style.contains("visibility:hidden") { return false }
        let width = map["width"].flatMap(Double.init)
        let height = map["height"].flatMap(Double.init)
        if let width, width <= 2 { return false }
        if let height, height <= 2 { return false }
        if let width, let height, width <= 48, height <= 48 { return false }
        return true
    }

    private static func isContentImage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return !ArticleExtractor.isPlaceholderImageURL(url.absoluteString)
            && !["/profile_images/", "/twemoji/", "/emoji/", "/emojione/", "/avatars/", "/avatar/"].contains(where: path.contains)
    }
}

/// Preferences are separate from reader typography and never mutate article
/// selection, unread filtering or the chronological order of the timeline.
public enum TimelineViewStyle: String, CaseIterable, Sendable {
    case list, magazine, cards
    public var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .magazine: "rectangle.topthird.inset.filled"
        case .cards: "square.grid.2x2"
        }
    }
    public var title: String {
        switch self {
        case .list: I18N.localized("列表")
        case .magazine: I18N.localized("杂志")
        case .cards: I18N.localized("卡片")
        }
    }
}

public enum TimelineImagePreference: String, Sendable {
    case automatic, enabled, disabled
    public func showsImages(in style: TimelineViewStyle) -> Bool {
        switch self {
        case .automatic: style != .list
        case .enabled: true
        case .disabled: false
        }
    }
}
