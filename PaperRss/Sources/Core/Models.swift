import Foundation

public enum FeedRefreshInterval: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case manual
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case eightHours

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: I18N.localized("仅手动")
        case .thirtyMinutes: I18N.localized("每 30 分钟")
        case .oneHour: I18N.localized("每小时")
        case .twoHours: I18N.localized("每 2 小时")
        case .fourHours: I18N.localized("每 4 小时")
        case .eightHours: I18N.localized("每 8 小时")
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .manual: nil
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .fourHours: 4 * 60 * 60
        case .eightHours: 8 * 60 * 60
        }
    }

    public var detail: String {
        switch self {
        case .manual: I18N.localized("应用保持打开时不自动刷新；打开应用时仍会按上方开关刷新。")
        default: I18N.localized("应用保持打开时按此频率检查订阅；系统后台刷新时间可能会有所延迟。")
        }
    }
}

public enum FeedRefreshStatus: Equatable, Sendable {
    case idle
    case refreshing
    case completed(updatedFeeds: Int, finishedAt: Date)
    case failed(message: String, finishedAt: Date)
}

public enum FeedRefreshOrigin: String, CaseIterable, Hashable, Sendable {
    case launch
    case scheduled
    case manual
    case subscriptionManagement
    case systemBackground
}

public struct FeedRefreshOutcome: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let origin: FeedRefreshOrigin
    public let newUnreadEntries: [Entry]
    public let updatedFeedCount: Int
    public let failedFeedCount: Int
    public let finishedAt: Date

    public init(
        id: UUID = UUID(),
        origin: FeedRefreshOrigin,
        newUnreadEntries: [Entry],
        updatedFeedCount: Int,
        failedFeedCount: Int,
        finishedAt: Date
    ) {
        self.id = id
        self.origin = origin
        self.newUnreadEntries = newUnreadEntries
        self.updatedFeedCount = updatedFeedCount
        self.failedFeedCount = failedFeedCount
        self.finishedAt = finishedAt
    }
}

public struct Feed: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var siteURL: URL?
    public var feedURL: URL
    public var folder: String?
    public var etag: String?
    public var lastModified: String?
    public var lastRefreshedAt: Date?
    public var isDeleted: Bool
    public var updatedAt: Date
    /// The icon advertised by the feed itself. For RSSHub Twitter/X routes
    /// this is the account owner's profile image, which the reader prefers
    /// over the generic twitter.com favicon.
    public var storedIconURL: URL?

    public init(id: UUID = UUID(), title: String, siteURL: URL? = nil, feedURL: URL, folder: String? = nil, etag: String? = nil, lastModified: String? = nil, lastRefreshedAt: Date? = nil, isDeleted: Bool = false, updatedAt: Date = .now, storedIconURL: URL? = nil) {
        self.id = id
        self.title = title
        self.siteURL = siteURL
        self.feedURL = feedURL
        self.folder = folder
        self.etag = etag
        self.lastModified = lastModified
        self.lastRefreshedAt = lastRefreshedAt
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
        self.storedIconURL = storedIconURL
    }

    public var iconURL: URL? {
        // Keep the icon advertised by the feed for every source, not only
        // Twitter/X. Some feeds provide a real logo while the generic
        // favicon service returns a globe or another placeholder.
        if let storedIconURL {
            return storedIconURL
        }

        let candidateHost = siteURL?.host ?? feedURL.host
        guard let host = candidateHost?.lowercased() else { return nil }
        // Special case for Twitter / X via RSSHub
        let path = feedURL.path.lowercased()
        if host.contains("twitter.com") || host.contains("x.com") || path.contains("/twitter/") || path.hasPrefix("/twitter") || path.contains("/x/") {
            // RSSHub publishes the account owner's avatar as the feed image.
            // The bird favicon remains the fallback until refresh.
            return URL(string: "https://abs.twimg.com/favicons/twitter.3.ico")
        }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, siteURL, feedURL, folder, etag, lastModified
        case lastRefreshedAt, isDeleted, updatedAt, storedIconURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未命名订阅"
        siteURL = try container.decodeIfPresent(URL.self, forKey: .siteURL)
        feedURL = try container.decode(URL.self, forKey: .feedURL)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        lastRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        storedIconURL = try container.decodeIfPresent(URL.self, forKey: .storedIconURL)
    }
}

public struct Entry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var feedID: UUID
    public var title: String
    public var author: String?
    public var url: URL?
    public var publishedAt: Date?
    public var summary: String
    public var contentHTML: String?
    public var isRead: Bool
    public var isStarred: Bool
    public var updatedAt: Date

    public init(id: String, feedID: UUID, title: String, author: String? = nil, url: URL? = nil, publishedAt: Date? = nil, summary: String = "", contentHTML: String? = nil, isRead: Bool = false, isStarred: Bool = false, updatedAt: Date = .now) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.author = author
        self.url = url
        self.publishedAt = publishedAt
        self.summary = summary
        self.contentHTML = contentHTML
        self.isRead = isRead
        self.isStarred = isStarred
        self.updatedAt = updatedAt
    }

    public var sourceText: String {
        let candidate = contentHTML?.plainText ?? summary.plainText
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The small, immutable value used by the middle article list.
public struct EntryListItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let feedID: UUID
    public let title: String
    public let url: URL?
    public let summaryPreview: String
    public let sourceTitle: String
    public let feedIconURL: URL?
    public let publishedAt: Date?
    public let isRead: Bool
    public let isStarred: Bool

    public init(
        id: String,
        feedID: UUID,
        title: String,
        url: URL? = nil,
        summaryPreview: String = "",
        sourceTitle: String,
        feedIconURL: URL? = nil,
        publishedAt: Date? = nil,
        isRead: Bool = false,
        isStarred: Bool = false
    ) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.url = url
        self.summaryPreview = summaryPreview
        self.sourceTitle = sourceTitle
        self.feedIconURL = feedIconURL
        self.publishedAt = publishedAt
        self.isRead = isRead
        self.isStarred = isStarred
    }

    public init(entry: Entry, sourceTitle: String, feedIconURL: URL? = nil, previewCharacterLimit: Int = 240) {
        id = entry.id
        feedID = entry.feedID
        title = entry.title
        url = entry.url
        summaryPreview = String(entry.summary.prefix(previewCharacterLimit))
        self.sourceTitle = sourceTitle
        self.feedIconURL = feedIconURL
        publishedAt = entry.publishedAt
        isRead = entry.isRead
        isStarred = entry.isStarred
    }
}

public struct ArticleCache: Codable, Hashable, Sendable {
    public var entryID: String
    public var text: String
    public var html: String?
    public var imageURLs: [URL]
    public var fetchedAt: Date
    public var sourceURL: URL?
    public var isSanitized: Bool

    public init(entryID: String, text: String, html: String? = nil, imageURLs: [URL] = [], fetchedAt: Date = .now, sourceURL: URL? = nil, isSanitized: Bool = false) {
        self.entryID = entryID
        self.text = text
        self.html = html
        self.imageURLs = imageURLs
        self.fetchedAt = fetchedAt
        self.sourceURL = sourceURL
        self.isSanitized = isSanitized
    }

    private enum CodingKeys: String, CodingKey { case entryID, text, html, imageURLs, fetchedAt, sourceURL, isSanitized }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try container.decode(String.self, forKey: .entryID)
        text = try container.decode(String.self, forKey: .text)
        html = try container.decodeIfPresent(String.self, forKey: .html)
        imageURLs = try container.decodeIfPresent([URL].self, forKey: .imageURLs) ?? []
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        isSanitized = try container.decodeIfPresent(Bool.self, forKey: .isSanitized) ?? false
    }
}

public struct ReadingState: Codable, Hashable, Sendable {
    public var entryID: String
    public var isRead: Bool
    public var isStarred: Bool
    public var updatedAt: Date

    public init(entryID: String, isRead: Bool, isStarred: Bool, updatedAt: Date = .now) {
        self.entryID = entryID
        self.isRead = isRead
        self.isStarred = isStarred
        self.updatedAt = updatedAt
    }
}

public enum AIArtifactKind: String, Codable, CaseIterable, Sendable {
    case translation
    case bilingual
    case summary
    /// A compact, reusable memo of the article. It is generated once per
    /// article/model/language/prompt version and reused by selection questions.
    case articleContext
    case selectionExplanation
    /// Kept only so databases created by older builds continue to decode.
    /// The whole-article interpretation feature is no longer exposed or run.
    case interpretation

    public var title: String {
        switch self {
        case .translation: I18N.localized("全文翻译")
        case .bilingual: I18N.localized("上下对照")
        case .summary: I18N.localized("AI 总结")
        case .articleContext: I18N.localized("文章上下文缓存")
        case .selectionExplanation: I18N.localized("选中文字解释")
        case .interpretation: I18N.localized("旧版 AI 解读")
        }
    }
}

public struct BilingualSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var original: String
    public var translation: String

    public init(id: String, original: String, translation: String) {
        self.id = id
        self.original = original
        self.translation = translation
    }
}

/// A stable, reader-visible source block. IDs are derived from document order
/// so WebKit can report exactly which paragraphs are on screen without sending
/// the entire article to the translation service.
public struct ReaderParagraph: Hashable, Identifiable, Sendable {
    public let id: String
    public let original: String

    public init(id: String, original: String) {
        self.id = id
        self.original = original
    }
}

/// A compact DOM anchor for a sentence explained by the reader. Keeping the
/// paragraph ID and UTF-16 offsets lets a newly loaded WebView restore the
/// annotation icon without storing or re-rendering article HTML.
public struct AISelectionAnchor: Codable, Hashable, Sendable {
    public var paragraphID: String
    public var startOffset: Int
    public var endOffset: Int

    public init(paragraphID: String, startOffset: Int, endOffset: Int) {
        self.paragraphID = paragraphID
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

public struct AIArtifact: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var entryID: String
    public var kind: AIArtifactKind
    public var contentHash: String
    public var model: String
    public var targetLanguage: String
    public var promptVersion: Int
    public var content: String
    public var segments: [BilingualSegment]
    public var selectionText: String?
    public var selectionArticleHash: String?
    public var selectionAnchor: AISelectionAnchor?
    public var isComplete: Bool
    public var isDeleted: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), entryID: String, kind: AIArtifactKind, contentHash: String, model: String, targetLanguage: String, promptVersion: Int = 1, content: String = "", segments: [BilingualSegment] = [], selectionText: String? = nil, selectionArticleHash: String? = nil, selectionAnchor: AISelectionAnchor? = nil, isComplete: Bool = false, isDeleted: Bool = false, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.entryID = entryID
        self.kind = kind
        self.contentHash = contentHash
        self.model = model
        self.targetLanguage = targetLanguage
        self.promptVersion = promptVersion
        self.content = content
        self.segments = segments
        self.selectionText = selectionText
        self.selectionArticleHash = selectionArticleHash
        self.selectionAnchor = selectionAnchor
        self.isComplete = isComplete
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, entryID, kind, contentHash, model, targetLanguage, promptVersion
        case content, segments, selectionText, selectionArticleHash, selectionAnchor
        case isComplete, isDeleted, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        entryID = try container.decode(String.self, forKey: .entryID)
        kind = try container.decode(AIArtifactKind.self, forKey: .kind)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        model = try container.decode(String.self, forKey: .model)
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        promptVersion = try container.decodeIfPresent(Int.self, forKey: .promptVersion) ?? 1
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        segments = try container.decodeIfPresent([BilingualSegment].self, forKey: .segments) ?? []
        selectionText = try container.decodeIfPresent(String.self, forKey: .selectionText)
        selectionArticleHash = try container.decodeIfPresent(String.self, forKey: .selectionArticleHash)
        selectionAnchor = try container.decodeIfPresent(AISelectionAnchor.self, forKey: .selectionAnchor)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct LLMConfiguration: Codable, Hashable, Sendable {
    public var providerName: String
    public var providerDescription: String
    public var baseURL: String
    public var model: String
    public var reasoningMode: String
    public var temperature: Double
    public var targetLanguage: String
    public var allowInsecureLocalEndpoint: Bool
    public var showsAISummary: Bool
    public var automaticallyGenerateSummary: Bool
    public var showsSelectionExplanation: Bool
    public var showsSelectionAsk: Bool
    public var showsSelectionTranslation: Bool

    public var customPrompt: String

    public static let `default` = LLMConfiguration(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", temperature: 0.2, targetLanguage: "简体中文", allowInsecureLocalEndpoint: false, showsAISummary: true, automaticallyGenerateSummary: false, showsSelectionExplanation: true, showsSelectionAsk: true, showsSelectionTranslation: true, customPrompt: "")

    /// DeepSeek's OpenAI-compatible endpoint expects the API root here.  The
    /// service appends `/chat/completions` itself, so users never need to guess
    /// whether to include `/v1` or the operation path.
    public static let deepSeek = LLMConfiguration(
        providerName: "DeepSeek",
        providerDescription: "DeepSeek OpenAI 兼容接口",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-flash",
        reasoningMode: "自动",
        temperature: 0.2,
        targetLanguage: "简体中文",
        allowInsecureLocalEndpoint: false,
        showsAISummary: true,
        automaticallyGenerateSummary: false,
        showsSelectionExplanation: true,
        showsSelectionAsk: true,
        showsSelectionTranslation: true,
        customPrompt: ""
    )

    public var usesDeepSeekAPI: Bool {
        guard let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "api.deepseek.com"
    }

    public init(providerName: String = "OpenAI 兼容接口", providerDescription: String = "用于翻译、总结和解读文章", baseURL: String, model: String, reasoningMode: String = "自动", temperature: Double, targetLanguage: String, allowInsecureLocalEndpoint: Bool, showsAISummary: Bool = true, automaticallyGenerateSummary: Bool = false, showsSelectionExplanation: Bool = true, showsSelectionAsk: Bool = true, showsSelectionTranslation: Bool = true, customPrompt: String = "") {
        self.providerName = providerName
        self.providerDescription = providerDescription
        self.baseURL = baseURL
        self.model = model
        self.reasoningMode = reasoningMode
        self.temperature = temperature
        self.targetLanguage = targetLanguage
        self.allowInsecureLocalEndpoint = allowInsecureLocalEndpoint
        self.showsAISummary = showsAISummary
        self.automaticallyGenerateSummary = automaticallyGenerateSummary
        self.showsSelectionExplanation = showsSelectionExplanation
        self.showsSelectionAsk = showsSelectionAsk
        self.showsSelectionTranslation = showsSelectionTranslation
        self.customPrompt = customPrompt
    }

    private enum CodingKeys: String, CodingKey { case providerName, providerDescription, baseURL, model, reasoningMode, temperature, targetLanguage, allowInsecureLocalEndpoint, showsAISummary, automaticallyGenerateSummary, showsSelectionExplanation, showsSelectionAsk, showsSelectionTranslation, customPrompt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName) ?? "OpenAI 兼容接口"
        providerDescription = try container.decodeIfPresent(String.self, forKey: .providerDescription) ?? "用于翻译、总结和解读文章"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4o-mini"
        reasoningMode = try container.decodeIfPresent(String.self, forKey: .reasoningMode) ?? "自动"
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "简体中文"
        allowInsecureLocalEndpoint = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureLocalEndpoint) ?? false
        showsAISummary = try container.decodeIfPresent(Bool.self, forKey: .showsAISummary) ?? true
        automaticallyGenerateSummary = try container.decodeIfPresent(Bool.self, forKey: .automaticallyGenerateSummary) ?? false
        showsSelectionExplanation = try container.decodeIfPresent(Bool.self, forKey: .showsSelectionExplanation) ?? true
        showsSelectionAsk = try container.decodeIfPresent(Bool.self, forKey: .showsSelectionAsk) ?? true
        showsSelectionTranslation = try container.decodeIfPresent(Bool.self, forKey: .showsSelectionTranslation) ?? true
        customPrompt = try container.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
    }
}

public struct AppDatabase: Codable, Sendable {
    public var feeds: [Feed]
    public var entries: [Entry]
    public var articleCaches: [String: ArticleCache]
    public var readingStates: [String: ReadingState]
    public var artifacts: [AIArtifact]
    public var llmConfiguration: LLMConfiguration
    public var customFolders: [String]

    public static let empty = AppDatabase(feeds: [], entries: [], articleCaches: [:], readingStates: [:], artifacts: [], llmConfiguration: .default, customFolders: [])

    public init(feeds: [Feed], entries: [Entry], articleCaches: [String: ArticleCache], readingStates: [String: ReadingState], artifacts: [AIArtifact], llmConfiguration: LLMConfiguration, customFolders: [String] = []) {
        self.feeds = feeds
        self.entries = entries
        self.articleCaches = articleCaches
        self.readingStates = readingStates
        self.artifacts = artifacts
        self.llmConfiguration = llmConfiguration
        self.customFolders = customFolders
    }

    private enum CodingKeys: String, CodingKey { case feeds, entries, articleCaches, readingStates, artifacts, llmConfiguration, customFolders }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try container.decodeIfPresent([Feed].self, forKey: .feeds) ?? []
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        articleCaches = try container.decodeIfPresent([String: ArticleCache].self, forKey: .articleCaches) ?? [:]
        readingStates = try container.decodeIfPresent([String: ReadingState].self, forKey: .readingStates) ?? [:]
        artifacts = try container.decodeIfPresent([AIArtifact].self, forKey: .artifacts) ?? []
        llmConfiguration = try container.decodeIfPresent(LLMConfiguration.self, forKey: .llmConfiguration) ?? .default
        customFolders = try container.decodeIfPresent([String].self, forKey: .customFolders) ?? []
    }
}

public extension String {
    var plainText: String {
        var value = self
        let newline = String(UnicodeScalar(10)!)
        value = value.replacingOccurrences(of: "(?is)<(script|style|iframe|form|object|embed)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<br\\s*/?>", with: newline, options: .regularExpression)
        // Preserve an actual paragraph boundary for the translation pipeline.
        // A single newline made an entire article look like one translation unit
        // whenever publishers minified their HTML.
        value = value.replacingOccurrences(of: "(?is)</(p|div|h[1-6]|li|blockquote|pre|figcaption|dt|dd)>", with: newline + newline, options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "&nbsp;", with: " ")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "&quot;", with: "\\\"")
        value = value.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: newline, options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: newline + newline, options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var stableDigest: String {
        let data = Data(utf8)
        return data.reduce(into: UInt64(0xcbf29ce484222325)) { hash, byte in
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }.description
    }
}
