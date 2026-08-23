import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ReaderDocument: Sendable, Equatable {
    public let html: String
    public let baseURL: URL?
    public let features: ArticleFeatures
    public let renderSignature: String

    public init(html: String, baseURL: URL?, features: ArticleFeatures, renderSignature: String) {
        self.html = html
        self.baseURL = baseURL
        self.features = features
        self.renderSignature = renderSignature
    }
}

/// 负责将准备好的文章内容、头部元数据、排版参数和安全策略组装为完整 Reader HTML 文档的单一权威渲染器。
public enum ReaderDocumentRenderer: Sendable {

    /// 严格的 CSP 安全策略，默认禁止外链脚本、嵌入对象和跨域连接，保证 WebKit 渲染环境安全沙箱化。
    public static let standardCSP = "default-src 'none'; img-src http: https: data: blob:; style-src 'unsafe-inline'; font-src 'none'; media-src http: https: data: blob:; object-src 'none'; frame-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'"

    public static func renderSignature(for article: PreparedArticle, documentIdentity: String) -> String {
        let safeBaseURL = article.baseURL.flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return nil }
            return url
        }
        return [
            documentIdentity,
            article.html.stableDigest,
            safeBaseURL?.absoluteString ?? "",
            article.features.containsMath ? "math" : "plain"
        ].joined(separator: "|").stableDigest
    }

    /// 组装完整 Reader HTML 文档
    public static func renderDocument(
        article: PreparedArticle,
        documentIdentity: String,
        bodyHTML: String? = nil,
        headerHTML: String = "",
        topInset: Double = 0,
        fontSize: Int = 16,
        extraStyleCSS: String? = nil
    ) -> ReaderDocument {
        let safeInset = max(0.0, topInset)
        let clampedFontSize = min(36, max(12, fontSize))
        let customCSS = extraStyleCSS ?? ""
        let safeBaseURL = article.baseURL.flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return nil }
            return url
        }
        let renderSignature = renderSignature(for: article, documentIdentity: documentIdentity)
        let renderedBodyHTML = bodyHTML ?? article.html

        let html = """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(standardCSP)">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>:root { --paper-reader-top-inset: \(safeInset)px; --paper-font-size: \(clampedFontSize)px; }\(customCSS)</style>
        </head><body>\(headerHTML)\(renderedBodyHTML)</body></html>
        """
        return ReaderDocument(
            html: html,
            baseURL: safeBaseURL,
            features: article.features,
            renderSignature: renderSignature
        )
    }
}
