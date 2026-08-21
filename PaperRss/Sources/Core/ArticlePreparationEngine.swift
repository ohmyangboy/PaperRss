import Foundation

/// 负责将 Feed 原始内容、本地缓存以及可选的网页抓取候选进行统一评估与择优，
/// 输出严格同源绑定的 `PreparedArticle`，并计算是否需要无多余回写缓存。
public final class ArticlePreparationEngine: Sendable {

    private let pageLoader: any ArticlePageLoading

    public init(pageLoader: any ArticlePageLoading = DefaultArticlePageLoader()) {
        self.pageLoader = pageLoader
    }

    /// 评估并准备文章正文产物
    public func prepare(
        entry: Entry,
        cached: ArticleCache?,
        feed: Feed? = nil
    ) async -> (prepared: PreparedArticle, updatedCache: ArticleCache?) {
        // 1. 准备 Feed 候选
        let feedCandidate = prepareFeedCandidate(for: entry, feed: feed)

        // 2. 准备 Cache 候选
        let cacheCandidate = prepareCacheCandidate(cached, entry: entry)

        // 3. 判定强 Feed 候选（强 Feed 直接采用，0 网页请求）
        if let feedCandidate, feedCandidate.quality.isStrong {
            let prepared = feedCandidate.toPreparedArticle()
            let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
            return (prepared, cacheUpdate)
        }

        // 4. 判定高质量 Cache 候选（0 网页请求）
        if let cacheCandidate, cacheCandidate.quality.isUsableCache {
            let prepared = cacheCandidate.toPreparedArticle()
            let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
            return (prepared, cacheUpdate)
        }

        // 选取当前最佳本地候选
        let bestLocal = pickBestLocal(feedCandidate, cacheCandidate)

        // 5. 本地候选较弱，若存在目标 URL 则尝试最多抓取 1 次网页
        if let entryURL = entry.url {
            if Task.isCancelled {
                return cancelOrFallback(bestLocal: bestLocal, entry: entry)
            }

            do {
                if let webHTML = try await pageLoader.loadHTML(for: entryURL),
                   !webHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

                    if Task.isCancelled {
                        return cancelOrFallback(bestLocal: bestLocal, entry: entry)
                    }

                    if let webCandidate = prepareWebCandidate(webHTML, baseURL: entryURL) {
                        // 判定 Web 是否“明显改善”
                        if let bestLocal {
                            if isSignificantlyBetter(webCandidate.quality, than: bestLocal.quality) {
                                let prepared = webCandidate.toPreparedArticle()
                                let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
                                return (prepared, cacheUpdate)
                            }
                        } else if webCandidate.quality.charCount >= 100 {
                            let prepared = webCandidate.toPreparedArticle()
                            let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
                            return (prepared, cacheUpdate)
                        }
                    }
                }
            } catch {
                // 抓取失败，安全回退到本地候选
            }
        }

        if Task.isCancelled {
            return cancelOrFallback(bestLocal: bestLocal, entry: entry)
        }

        // 6. 回退到最佳本地候选或通用兜底
        if let bestLocal {
            let prepared = bestLocal.toPreparedArticle()
            let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
            return (prepared, cacheUpdate)
        }

        return (makeFallbackArticle(for: entry), nil)
    }

    // MARK: - Internal Candidate Model & Helpers

    struct ArticleCandidate: Sendable {
        let text: String
        let html: String
        let imageURLs: [URL]
        let baseURL: URL?
        let source: ArticleSource
        let quality: ArticleCandidateQuality

        func toPreparedArticle() -> PreparedArticle {
            let containsMath = ArticleMathDetector.containsMath(in: html) || ArticleMathDetector.containsMath(in: text)
            return PreparedArticle(
                text: text,
                html: html,
                imageURLs: imageURLs,
                baseURL: baseURL,
                source: source,
                features: ArticleFeatures(containsMath: containsMath)
            )
        }
    }

    struct ArticleCandidateQuality: Sendable, Equatable {
        let charCount: Int
        let blockCount: Int
        let imageCount: Int
        let hasTruncationSignal: Bool
        let isSpecialSelfContained: Bool

        var isStrong: Bool {
            if isSpecialSelfContained { return true }
            guard !hasTruncationSignal else { return false }
            // 1. 正文不少于 400 字且至少 2 个语义块，或单段不少于 500 字
            if charCount >= 400 && blockCount >= 2 { return true }
            if charCount >= 500 { return true }
            // 2. 正文不少于 200 字且至少 1 张有效图片
            if charCount >= 200 && imageCount >= 1 { return true }
            return false
        }

        var isUsableCache: Bool {
            if isSpecialSelfContained { return true }
            if isStrong { return true }
            return !hasTruncationSignal && (charCount >= 200 || (charCount >= 100 && (blockCount >= 2 || imageCount >= 1)))
        }
    }

    // MARK: - Candidate Preparation

    private func prepareFeedCandidate(for entry: Entry, feed: Feed?) -> ArticleCandidate? {
        guard let rawHTML = entry.contentHTML,
              !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let content = ArticleExtractor.content(from: rawHTML, baseURL: entry.url)
        let isSpecial = isTwitterOrSelfContainedFeed(entry: entry, feed: feed)
        let quality = evaluateQuality(text: content.text, html: content.html, imageCount: content.imageURLs.count, isSpecialSelfContained: isSpecial)

        return ArticleCandidate(
            text: content.text.isEmpty ? entry.sourceText : content.text,
            html: content.html,
            imageURLs: content.imageURLs,
            baseURL: entry.url,
            source: .feed,
            quality: quality
        )
    }

    private func prepareCacheCandidate(_ cache: ArticleCache?, entry: Entry) -> ArticleCandidate? {
        guard let cache, let cachedHTML = cache.html,
              !cachedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let sourceURL = cache.sourceURL ?? entry.url
        let content = ArticleExtractor.content(from: cachedHTML, baseURL: sourceURL)
        let quality = evaluateQuality(text: content.text, html: content.html, imageCount: content.imageURLs.count, isSpecialSelfContained: false)

        return ArticleCandidate(
            text: content.text.isEmpty ? cache.text : content.text,
            html: content.html,
            imageURLs: content.imageURLs.isEmpty ? cache.imageURLs : content.imageURLs,
            baseURL: sourceURL,
            source: .cache,
            quality: quality
        )
    }

    private func prepareWebCandidate(_ webHTML: String, baseURL: URL) -> ArticleCandidate? {
        let content = ArticleExtractor.content(from: webHTML, baseURL: baseURL)
        guard !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let quality = evaluateQuality(text: content.text, html: content.html, imageCount: content.imageURLs.count, isSpecialSelfContained: false)

        return ArticleCandidate(
            text: content.text,
            html: content.html,
            imageURLs: content.imageURLs,
            baseURL: baseURL,
            source: .web,
            quality: quality
        )
    }

    // MARK: - Quality Evaluation & Significance Decision

    private func evaluateQuality(
        text: String,
        html: String,
        imageCount: Int,
        isSpecialSelfContained: Bool
    ) -> ArticleCandidateQuality {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = trimmedText.count
        let blockCount = countSemanticBlocks(in: html)
        let hasTruncation = isSpecialSelfContained ? false : detectTruncationSignal(in: trimmedText, html: html)

        return ArticleCandidateQuality(
            charCount: charCount,
            blockCount: blockCount,
            imageCount: imageCount,
            hasTruncationSignal: hasTruncation,
            isSpecialSelfContained: isSpecialSelfContained
        )
    }

    private func countSemanticBlocks(in html: String) -> Int {
        let blockPattern = "(?is)<(p|h[1-6]|blockquote|li|pre|table)\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: blockPattern) else { return 1 }
        let range = NSRange(html.startIndex..., in: html)
        let count = regex.numberOfMatches(in: html, range: range)
        return max(1, count)
    }

    private func detectTruncationSignal(in text: String, html: String) -> Bool {
        // 1. 结尾省略号检测
        if text.count < 500 {
            if text.hasSuffix("...") || text.hasSuffix("…") || text.hasSuffix("……") {
                return true
            }
        }

        // 2. 通用跳转全文提示词检测
        let truncationKeywords = [
            "阅读全文", "继续阅读", "查看全文", "展开全文", "阅读原文", "查看原网页", "展开阅读", "全文",
            "Read more", "Continue reading", "Full article", "Read full article", "Click to read"
        ]
        let lower = text.lowercased()
        for kw in truncationKeywords {
            if lower.contains(kw.lowercased()) {
                return true
            }
        }

        // 3. 极高链接文本占比（正文主要是跳转链接）
        let linkPattern = "(?is)<a\\b[^>]*>(.*?)</a>"
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)
            var linkTextCount = 0
            for match in matches {
                if let r = Range(match.range(at: 1), in: html) {
                    linkTextCount += String(html[r]).plainText.count
                }
            }
            if text.count > 0 && Double(linkTextCount) / Double(text.count) > 0.5 {
                return true
            }
        }

        return false
    }

    private func isSignificantlyBetter(
        _ webQuality: ArticleCandidateQuality,
        than localQuality: ArticleCandidateQuality
    ) -> Bool {
        // Web 自身必须具有基本可读性
        guard webQuality.charCount >= 40 && webQuality.blockCount >= 1 else { return false }

        // 1. 本地存在截断信号而 Web 不存在
        if localQuality.hasTruncationSignal && !webQuality.hasTruncationSignal && webQuality.charCount >= localQuality.charCount {
            return true
        }

        // 2. Web 规范文本比本地多 25% 且至少多 100 字
        if webQuality.charCount >= Int(Double(localQuality.charCount) * 1.25) &&
           webQuality.charCount - localQuality.charCount >= 100 {
            return true
        }

        // 3. Web 多至少 2 个有效语义块且字数明显更多
        if webQuality.blockCount - localQuality.blockCount >= 2 && webQuality.charCount >= localQuality.charCount {
            return true
        }

        // 4. 本地无图而 Web 恢复了有效正文图片
        if localQuality.imageCount == 0 && webQuality.imageCount >= 1 && webQuality.charCount >= localQuality.charCount - 30 {
            return true
        }

        return false
    }

    private func pickBestLocal(
        _ feed: ArticleCandidate?,
        _ cache: ArticleCandidate?
    ) -> ArticleCandidate? {
        if let feed, let cache {
            return feed.quality.charCount >= cache.quality.charCount ? feed : cache
        }
        return feed ?? cache
    }

    func isTwitterOrSelfContainedFeed(entry: Entry, feed: Feed?) -> Bool {
        let entryHost = entry.url?.host?.lowercased() ?? ""
        let isTwitterStatus = entryHost == "x.com" || entryHost == "www.x.com" || entryHost == "twitter.com" || entryHost == "www.twitter.com"

        let feedURL = feed?.feedURL
        let feedHost = feedURL?.host?.lowercased() ?? ""
        let feedPath = feedURL?.path.lowercased() ?? ""
        let isTwitterRoute = feedPath.contains("/twitter/") || feedPath.hasPrefix("/twitter") || feedPath.contains("/x/")
        let isRSSHub = feedHost.contains("rsshub")

        return isTwitterRoute || isTwitterStatus || isRSSHub
    }

    private func computeCacheUpdate(
        existing: ArticleCache?,
        prepared: PreparedArticle,
        entryID: String
    ) -> ArticleCache? {
        if let existing,
           existing.isSanitized,
           existing.text == prepared.text,
           existing.html == prepared.html,
           existing.imageURLs == prepared.imageURLs,
           existing.sourceURL == prepared.baseURL {
            // 内容完全未变化，0 写入
            return nil
        }

        return ArticleCache(
            entryID: entryID,
            text: prepared.text,
            html: prepared.html,
            imageURLs: prepared.imageURLs,
            fetchedAt: existing?.fetchedAt ?? .now,
            sourceURL: prepared.baseURL,
            isSanitized: true
        )
    }

    private func cancelOrFallback(bestLocal: ArticleCandidate?, entry: Entry) -> (PreparedArticle, ArticleCache?) {
        if let bestLocal {
            return (bestLocal.toPreparedArticle(), nil)
        }
        return (makeFallbackArticle(for: entry), nil)
    }

    private func makeFallbackArticle(for entry: Entry) -> PreparedArticle {
        let fallbackText = entry.sourceText
        let fallbackHTML = "<p>\(fallbackText)</p>"
        let containsMath = ArticleMathDetector.containsMath(in: fallbackHTML) || ArticleMathDetector.containsMath(in: fallbackText)
        return PreparedArticle(
            text: fallbackText,
            html: fallbackHTML,
            imageURLs: [],
            baseURL: entry.url,
            source: .fallback,
            features: ArticleFeatures(containsMath: containsMath)
        )
    }
}
