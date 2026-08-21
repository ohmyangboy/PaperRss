import Foundation

/// 表示文章正文的实际最终来源
public enum ArticleSource: String, Sendable, Codable, Equatable {
    case feed
    case cache
    case web
    case fallback
}

/// 预留给 Reader 引擎的特性开关标记（如是否包含数学公式等）
public struct ArticleFeatures: Sendable, Equatable {
    public var containsMath: Bool

    public init(containsMath: Bool = false) {
        self.containsMath = containsMath
    }
}

/// 统一的规范化文章准备产物，所有正文字段严格同源
public struct PreparedArticle: Sendable, Equatable {
    public let text: String
    public let html: String
    public let imageURLs: [URL]
    public let baseURL: URL?
    public let source: ArticleSource
    public let features: ArticleFeatures

    public init(
        text: String,
        html: String,
        imageURLs: [URL],
        baseURL: URL?,
        source: ArticleSource,
        features: ArticleFeatures = ArticleFeatures()
    ) {
        self.text = text
        self.html = html
        self.imageURLs = imageURLs
        self.baseURL = baseURL
        self.source = source
        self.features = features
    }
}

/// 网页抓取 Seam 契约（用于生产网络抓取与单元测试注入）
public protocol ArticlePageLoading: Sendable {
    func loadHTML(for url: URL) async throws -> String?
}

/// 默认系统 URLSession 网页加载器（受限 4MB）
public struct DefaultArticlePageLoader: ArticlePageLoading {
    public init() {}

    public func loadHTML(for url: URL) async throws -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        // 单个响应最大限制 4 MB
        guard data.count <= 4 * 1024 * 1024 else { return nil }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)) as UInt?,
           let gbk = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return gbk
        }
        return String(data: data, encoding: .isoLatin1)
    }
}
