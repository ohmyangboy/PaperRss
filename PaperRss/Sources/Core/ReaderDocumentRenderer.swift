import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 负责将准备好的文章内容、头部元数据、排版参数和安全策略组装为完整 Reader HTML 文档的单一权威渲染器。
public enum ReaderDocumentRenderer: Sendable {

    /// 严格的 CSP 安全策略，默认禁止外链脚本、嵌入对象和跨域连接，保证 WebKit 渲染环境安全沙箱化。
    public static let standardCSP = "default-src 'none'; img-src http: https: data: blob:; style-src 'unsafe-inline'; font-src 'none'; media-src http: https: data: blob:; object-src 'none'; frame-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'"

    /// 组装完整 Reader HTML 文档
    public static func renderHTMLDocument(
        bodyHTML: String,
        headerHTML: String = "",
        topInset: Double = 0,
        fontSize: Int = 16,
        features: ArticleFeatures = ArticleFeatures(),
        extraStyleCSS: String? = nil
    ) -> String {
        let safeInset = max(0.0, topInset)
        let clampedFontSize = min(36, max(12, fontSize))
        let customCSS = extraStyleCSS ?? ""

        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(standardCSP)">
        <style>:root { --paper-reader-top-inset: \(safeInset)px; --paper-font-size: \(clampedFontSize)px; }\(customCSS)</style>
        </head><body>\(headerHTML)\(bodyHTML)</body></html>
        """
    }
}
