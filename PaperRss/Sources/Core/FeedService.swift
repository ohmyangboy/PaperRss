import Foundation

public enum FeedFetchResult: Sendable {
    case notModified(etag: String?, lastModified: String?)
    case updated(ParsedFeed, etag: String?, lastModified: String?)
}

public enum FeedService {
    public static func fetch(_ feed: Feed) async throws -> FeedFetchResult {
        var request = URLRequest(url: feed.feedURL)
        request.timeoutInterval = 30
        request.setValue("PaperRss/0.1 (+personal RSS reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/xml, text/xml, application/json", forHTTPHeaderField: "Accept")
        if let etag = feed.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = feed.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let etag = http.value(forHTTPHeaderField: "Etag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        if http.statusCode == 304 { return .notModified(etag: etag ?? feed.etag, lastModified: lastModified ?? feed.lastModified) }
        guard (200...299).contains(http.statusCode) else { throw HTTPStatusError(statusCode: http.statusCode) }
        return .updated(try FeedParser.parse(data: data, baseURL: feed.feedURL), etag: etag, lastModified: lastModified)
    }
}

public struct HTTPStatusError: LocalizedError, Sendable {
    public let statusCode: Int
    public var errorDescription: String? {
        I18N.localizedFormat("服务器返回 HTTP %lld。", arguments: [statusCode])
    }
}
