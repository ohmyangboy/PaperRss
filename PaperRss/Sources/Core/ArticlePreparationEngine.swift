import Foundation

public enum ArticlePreparationPolicy: Sendable {
    case foregroundRefresh
    case localOnly
}

public enum ArticlePreparationCacheState: Sendable, Equatable {
    case current
    case staleFallback
}

public struct ArticlePreparationResult: Sendable {
    public let prepared: PreparedArticle
    public let updatedCache: ArticleCache?
    public let cacheState: ArticlePreparationCacheState
    public let didRefreshCache: Bool
    /// localOnly 预取产出的"降级预览"：有网页 URL 可升级，但本次仅取到弱 Feed
    /// 摘要（不含完整正文）。此类结果不得进入内存缓存，否则正式打开会命中它
    /// 并跳过网页抓取升级。
    public let isProvisionalLocal: Bool

    init(
        prepared: PreparedArticle,
        updatedCache: ArticleCache?,
        cacheState: ArticlePreparationCacheState,
        didRefreshCache: Bool = false,
        isProvisionalLocal: Bool = false
    ) {
        self.prepared = prepared
        self.updatedCache = updatedCache
        self.cacheState = cacheState
        self.didRefreshCache = didRefreshCache
        self.isProvisionalLocal = isProvisionalLocal
    }
}

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
        let result = await prepare(
            entry: entry,
            cached: cached,
            feed: feed,
            policy: .foregroundRefresh
        )
        return (result.prepared, result.updatedCache)
    }

    /// 带显式网络策略的正文准备入口。前台阅读允许惰性升级旧缓存；相邻预取
    /// 只能使用本地候选，且旧缓存结果不得被视为当前管线产物。
    public func prepare(
        entry: Entry,
        cached: ArticleCache?,
        feed: Feed? = nil,
        policy: ArticlePreparationPolicy
    ) async -> ArticlePreparationResult {
        // 1. 准备 Feed 候选
        let feedCandidate = prepareFeedCandidate(for: entry, feed: feed)

        // 2. 准备 Cache 候选
        let cacheCandidate = prepareCacheCandidate(cached, entry: entry)
        let cacheNeedsRefresh = cached.map(cacheRequiresRefresh) ?? false

        // 相邻文章预取严格保持本地：旧缓存可作为离线兜底展示，但不得升级、
        // 回写或触发网页请求，也不能被上层写入 PreparedArticleMemoryCache。
        if policy == .localOnly {
            if let cacheCandidate {
                return ArticlePreparationResult(
                    prepared: cacheCandidate.toPreparedArticle(),
                    updatedCache: nil,
                    cacheState: cacheNeedsRefresh ? .staleFallback : .current
                )
            }
            if let feedCandidate {
                return ArticlePreparationResult(
                    prepared: feedCandidate.toPreparedArticle(),
                    updatedCache: nil,
                    cacheState: .current,
                    isProvisionalLocal: entry.url != nil && !feedCandidate.quality.isStrong
                )
            }
            return ArticlePreparationResult(
                prepared: makeFallbackArticle(for: entry),
                updatedCache: nil,
                cacheState: .current
            )
        }

        // 旧 revision 或公式定界符内夹入 HTML 的缓存不能继续命中高质量快路。
        // 保留它作为离线兜底，同时用当前管线最多重抓一次网页正文。
        if cacheNeedsRefresh {
            let bestLocal = pickBestLocal(feedCandidate, cacheCandidate)
            if Task.isCancelled {
                return staleFallback(bestLocal: bestLocal, entry: entry)
            }

            // 特殊自包含 feed（Twitter/RSSHub）的 feed 内容即权威全文：
            // revision 升级/公式修复只做本地重清洗，严禁抓网页升级。
            // x.com 抽取产物会携带作者行、时间戳、Views、互动数等页面 chrome，
            // 且这些 chrome 不受质量门槛约束——用它顶替干净推文正文是
            // 「头像/渲染异常」类缺陷的根源（与 step 4「强 Feed 直接采用」同一不变量）。
            if let feedCandidate, feedCandidate.quality.isSpecialSelfContained {
                let prepared = feedCandidate.toPreparedArticle()
                return ArticlePreparationResult(
                    prepared: prepared,
                    updatedCache: computeCacheUpdate(
                        existing: cached,
                        prepared: prepared,
                        entryID: entry.id,
                        refreshed: true
                    ),
                    cacheState: .current,
                    didRefreshCache: true
                )
            }

            if let entryURL = entry.url {
                do {
                    if let page = try await pageLoader.loadPage(for: entryURL),
                       !page.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !Task.isCancelled,
                       let webCandidate = prepareWebCandidate(page.html, baseURL: page.finalURL),
                       webCandidate.quality.isUsableCache,
                       !ArticleMathDetector.containsUnsupportedMarkupInsideFormula(in: webCandidate.html) {
                        let prepared = webCandidate.toPreparedArticle()
                        return ArticlePreparationResult(
                            prepared: prepared,
                            updatedCache: computeCacheUpdate(
                                existing: cached,
                                prepared: prepared,
                                entryID: entry.id,
                                refreshed: true
                            ),
                            cacheState: .current,
                            didRefreshCache: true
                        )
                    }
                } catch {
                    // 网络失败时保留旧缓存，不提升 revision，下一次前台打开继续重试。
                }
            }

            // 无网页 URL 时，仅允许明显更强的 Feed 替代旧缓存；否则继续离线兜底。
            if entry.url == nil,
               let feedCandidate,
               feedCandidate.quality.isStrong,
               cacheCandidate.map({ isStrongFeedSignificantlyBetter(feedCandidate, than: $0) }) ?? true {
                let prepared = feedCandidate.toPreparedArticle()
                return ArticlePreparationResult(
                    prepared: prepared,
                    updatedCache: computeCacheUpdate(
                        existing: cached,
                        prepared: prepared,
                        entryID: entry.id,
                        refreshed: true
                    ),
                    cacheState: .current,
                    didRefreshCache: true
                )
            }

            return staleFallback(bestLocal: bestLocal, entry: entry)
        }

        // 3. 高质量缓存优先，避免用较短的新 Feed 覆盖已经抓取到的完整正文。
        if let cacheCandidate,
           cacheCandidate.quality.isUsableCache,
           !isStrongFeedSignificantlyBetter(feedCandidate, than: cacheCandidate) {
            let prepared = cacheCandidate.toPreparedArticle()
            let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
            return ArticlePreparationResult(prepared: prepared, updatedCache: cacheUpdate, cacheState: .current)
        }

        // 4. 强 Feed 候选直接采用，0 网页请求。
        if let feedCandidate, feedCandidate.quality.isStrong {
            let prepared = feedCandidate.toPreparedArticle()
            let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
            return ArticlePreparationResult(prepared: prepared, updatedCache: cacheUpdate, cacheState: .current)
        }

        // 选取当前最佳本地候选
        let bestLocal = pickBestLocal(feedCandidate, cacheCandidate)

        // 5. 本地候选较弱，若存在目标 URL 则尝试最多抓取 1 次网页
        if let entryURL = entry.url {
            if Task.isCancelled {
                let fallback = cancelOrFallback(bestLocal: bestLocal, entry: entry)
                return ArticlePreparationResult(prepared: fallback.0, updatedCache: fallback.1, cacheState: .current)
            }

            do {
                if let page = try await pageLoader.loadPage(for: entryURL),
                   !page.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

                    if Task.isCancelled {
                        let fallback = cancelOrFallback(bestLocal: bestLocal, entry: entry)
                        return ArticlePreparationResult(prepared: fallback.0, updatedCache: fallback.1, cacheState: .current)
                    }

                    if let webCandidate = prepareWebCandidate(page.html, baseURL: page.finalURL) {
                        // 判定 Web 是否“明显改善”
                        if let bestLocal {
                            if isSignificantlyBetter(webCandidate.quality, than: bestLocal.quality) {
                                let prepared = webCandidate.toPreparedArticle()
                                let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
                                return ArticlePreparationResult(prepared: prepared, updatedCache: cacheUpdate, cacheState: .current)
                            }
                        } else if webCandidate.quality.charCount >= 100 {
                            let prepared = webCandidate.toPreparedArticle()
                            let cacheUpdate = computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
                            return ArticlePreparationResult(prepared: prepared, updatedCache: cacheUpdate, cacheState: .current)
                        }
                    }
                }
            } catch {
                // 抓取失败，安全回退到本地候选
            }
        }

        if Task.isCancelled {
            let fallback = cancelOrFallback(bestLocal: bestLocal, entry: entry)
            return ArticlePreparationResult(prepared: fallback.0, updatedCache: fallback.1, cacheState: .current)
        }

        // 6. 回退到最佳本地候选或通用兜底
        if let bestLocal {
            let prepared = bestLocal.toPreparedArticle()
            // 网页抓取已尝试但未产出更强正文时，弱 Feed 摘要仅作本次展示，
            // 不得写入缓存：否则摘要会永久顶替完整正文（下次打开命中可用缓存
            // 即不再重试网页）。无 URL（Feed 即权威）、本地候选已足够强
            // （全文 Feed）或候选来自旧缓存（规范化/修订号升级等合法家务回写）
            // 时照常缓存。
            let cacheable = entry.url == nil
                || bestLocal.quality.isStrong
                || bestLocal.source == .cache
            let cacheUpdate = cacheable
                ? computeCacheUpdate(existing: cached, prepared: prepared, entryID: entry.id)
                : nil
            return ArticlePreparationResult(prepared: prepared, updatedCache: cacheUpdate, cacheState: .current)
        }

        return ArticlePreparationResult(
            prepared: makeFallbackArticle(for: entry),
            updatedCache: nil,
            cacheState: .current
        )
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
            // HTML retains code-block boundaries and safe MathML tags. Running
            // detection against plain text would turn code samples such as
            // `$$x$$` back into false-positive formulas.
            let containsMath = ArticleMathDetector.containsMath(in: html)
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
            // 1. 正文不少于 600 字且至少 3 个语义块
            if charCount >= 600 && blockCount >= 3 { return true }
            // 2. 正文不少于 200 字、至少 2 个语义块且至少 1 张有效图片
            if charCount >= 200 && blockCount >= 2 && imageCount >= 1 { return true }
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
        guard let cache else {
            return nil
        }
        let cachedHTML = cache.html?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceMarkup: String
        if let cachedHTML, !cachedHTML.isEmpty {
            sourceMarkup = cachedHTML
        } else {
            let escapedText = ArticleMarkupNormalizer.escapeHTML(cache.text)
                .replacingOccurrences(of: "\n", with: "<br>")
            sourceMarkup = "<p>\(escapedText)</p>"
        }
        guard !sourceMarkup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let sourceURL = cache.sourceURL ?? entry.url
        let content = ArticleExtractor.content(from: sourceMarkup, baseURL: sourceURL)
        let quality = evaluateQuality(text: content.text, html: content.html, imageCount: content.imageURLs.count, isSpecialSelfContained: false)

        return ArticleCandidate(
            text: content.text.isEmpty ? cache.text : content.text,
            html: content.html,
            imageURLs: content.imageURLs,
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
            "阅读全文", "继续阅读", "查看全文", "展开全文", "阅读原文", "查看原网页", "展开阅读",
            "read more", "continue reading", "full article", "read full article", "click to read"
        ]
        let lower = text.lowercased()
        for kw in truncationKeywords {
            if lower.contains(kw) {
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

    private func isStrongFeedSignificantlyBetter(
        _ feed: ArticleCandidate?,
        than cache: ArticleCandidate
    ) -> Bool {
        guard let feed, feed.quality.isStrong else { return false }
        return isSignificantlyBetter(feed.quality, than: cache.quality)
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
        entryID: String,
        refreshed: Bool = false
    ) -> ArticleCache? {
        if let existing,
           existing.isSanitized,
           existing.normalizationRevision == ArticleCache.currentNormalizationRevision,
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
            fetchedAt: refreshed ? .now : (existing?.fetchedAt ?? .now),
            sourceURL: prepared.baseURL,
            isSanitized: true,
            normalizationRevision: ArticleCache.currentNormalizationRevision
        )
    }

    private func cacheRequiresRefresh(_ cache: ArticleCache) -> Bool {
        if cache.normalizationRevision < ArticleCache.currentNormalizationRevision {
            return true
        }
        guard let html = cache.html else { return false }
        return ArticleMathDetector.containsUnsupportedMarkupInsideFormula(in: html)
    }

    private func staleFallback(
        bestLocal: ArticleCandidate?,
        entry: Entry
    ) -> ArticlePreparationResult {
        ArticlePreparationResult(
            prepared: bestLocal?.toPreparedArticle() ?? makeFallbackArticle(for: entry),
            updatedCache: nil,
            cacheState: .staleFallback
        )
    }

    private func cancelOrFallback(bestLocal: ArticleCandidate?, entry: Entry) -> (PreparedArticle, ArticleCache?) {
        if let bestLocal {
            return (bestLocal.toPreparedArticle(), nil)
        }
        return (makeFallbackArticle(for: entry), nil)
    }

    private func makeFallbackArticle(for entry: Entry) -> PreparedArticle {
        let rawText = entry.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawText.isEmpty {
            return PreparedArticle(
                text: "",
                html: "",
                imageURLs: [],
                baseURL: entry.url,
                source: .fallback,
                features: ArticleFeatures(containsMath: false)
            )
        }

        // 纯文本 HTML escaping 与分段结构化
        let escaped = ArticleMarkupNormalizer.escapeHTML(rawText)
        let paragraphs = escaped
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: "<br>") }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let rawHTML: String
        if paragraphs.isEmpty {
            rawHTML = "<p>\(escaped)</p>"
        } else {
            rawHTML = paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n")
        }

        let safeHTML = ArticleExtractor.sanitizedHTML(rawHTML, baseURL: entry.url)
        let containsMath = ArticleMathDetector.containsMath(in: safeHTML)

        return PreparedArticle(
            text: rawText,
            html: safeHTML,
            imageURLs: [],
            baseURL: entry.url,
            source: .fallback,
            features: ArticleFeatures(containsMath: containsMath)
        )
    }
}
