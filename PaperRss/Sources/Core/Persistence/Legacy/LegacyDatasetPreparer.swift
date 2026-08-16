import Foundation

/// 经过数据清洗与启动修复后的准备数据集（专用于单事务全量入库）。
///
/// 遵循 Architecture Contract (DA-04A.1 Section 6)。
public struct PreparedLegacyDataset: Sendable, Equatable {
    public var feeds: [LegacyFeed]
    public var entries: [LegacyEntry]
    public var articleCaches: [String: LegacyArticleCache]
    public var readingStates: [String: LegacyReadingState]
    public var artifacts: [LegacyAIArtifact]
    public var llmConfiguration: LegacyLLMConfiguration
    public var customFolders: [String]

    /// 孤儿 ReadingState（未匹配到有效 Entry）
    public var orphanReadingStates: [String: LegacyReadingState]
    /// 孤儿 ArticleCache（未匹配到有效 Entry）
    public var orphanArticleCaches: [String: LegacyArticleCache]
}

/// 纯函数式 Legacy 数据集准备器。
///
/// 仅复现当前 AppStore 启动阶段已有的 4 项纯净修复规则，不增加新规则，不依赖外部 AppStore 实例。
public enum LegacyDatasetPreparer {
    public static func prepare(raw: LegacyAppDatabase) -> PreparedLegacyDataset {
        var dataset = raw

        // 1. siteURL 修复：对缺少 siteURL 的 Feed，从名下首篇文章的 URL 提取 origin 补齐
        for feedIndex in dataset.feeds.indices where dataset.feeds[feedIndex].siteURL == nil {
            guard let articleURL = dataset.entries.first(where: { $0.feedID == dataset.feeds[feedIndex].id })?.url,
                  let origin = originURL(from: articleURL) else { continue }
            dataset.feeds[feedIndex].siteURL = origin
        }

        // 2. summary 规范化：清洗残留的 HTML 标签与实体
        for index in dataset.entries.indices where needsPlainTextNormalization(dataset.entries[index].summary) {
            dataset.entries[index].summary = dataset.entries[index].summary.plainText
        }

        // 3. purgeEntriesFromInactiveFeeds：清理已删除/失联 Feed 的条目及关联
        let activeFeedIDs = Set(dataset.feeds.lazy.filter { !$0.isDeleted }.map(\.id))
        let orphanedEntryIDs = Set(
            dataset.entries.lazy
                .filter { !activeFeedIDs.contains($0.feedID) }
                .map(\.id)
        )

        if !orphanedEntryIDs.isEmpty {
            let deletedAt = Date.now
            dataset.entries.removeAll { orphanedEntryIDs.contains($0.id) }
            dataset.articleCaches = dataset.articleCaches.filter { !orphanedEntryIDs.contains($0.key) }
            dataset.readingStates = dataset.readingStates.filter { !orphanedEntryIDs.contains($0.key) }
            for index in dataset.artifacts.indices where orphanedEntryIDs.contains(dataset.artifacts[index].entryID) {
                dataset.artifacts[index].content = ""
                dataset.artifacts[index].segments = []
                dataset.artifacts[index].selectionText = nil
                dataset.artifacts[index].selectionArticleHash = nil
                dataset.artifacts[index].selectionAnchor = nil
                dataset.artifacts[index].isComplete = false
                dataset.artifacts[index].isDeleted = true
                dataset.artifacts[index].updatedAt = deletedAt
            }
        }

        // 4. ReadingState 状态合并：优先使用 readingStates 覆盖 Entry 内部状态
        for index in dataset.entries.indices {
            if let state = dataset.readingStates[dataset.entries[index].id] {
                dataset.entries[index].isRead = state.isRead
                dataset.entries[index].isStarred = state.isStarred
                dataset.entries[index].updatedAt = state.updatedAt
            }
        }

        // 5. 提取孤儿 ReadingState 与 ArticleCache（在有效 Entry 列表之外的记录）
        let validEntryIDs = Set(dataset.entries.map(\.id))
        var validCaches: [String: LegacyArticleCache] = [:]
        var orphanCaches: [String: LegacyArticleCache] = [:]
        for (key, cache) in dataset.articleCaches {
            if validEntryIDs.contains(key) {
                validCaches[key] = cache
            } else {
                orphanCaches[key] = cache
            }
        }

        var validStates: [String: LegacyReadingState] = [:]
        var orphanStates: [String: LegacyReadingState] = [:]
        for (key, state) in dataset.readingStates {
            if validEntryIDs.contains(key) {
                validStates[key] = state
            } else {
                orphanStates[key] = state
            }
        }

        return PreparedLegacyDataset(
            feeds: dataset.feeds,
            entries: dataset.entries,
            articleCaches: validCaches,
            readingStates: validStates,
            artifacts: dataset.artifacts,
            llmConfiguration: dataset.llmConfiguration,
            customFolders: dataset.customFolders,
            orphanReadingStates: orphanStates,
            orphanArticleCaches: orphanCaches
        )
    }

    private static func originURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func needsPlainTextNormalization(_ string: String) -> Bool {
        string.range(of: #"(?is)<\s*/?\s*[a-z][^>]*>"#, options: .regularExpression) != nil
            || string.contains("&nbsp;")
            || string.contains("&amp;")
            || string.contains("&lt;")
            || string.contains("&gt;")
            || string.contains("&quot;")
    }
}
