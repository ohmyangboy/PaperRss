import Foundation

/// 冻结的 Legacy JSON 数据模型 DTO（专用于 DA-04 数据迁移）。
///
/// 遵循 Architecture Contract (DA-04A / DA-04A.1)，完整固化旧版 `library.json` 的 Codable 结构与解码容错逻辑。

public struct LegacyAppDatabase: Codable, Sendable, Equatable {
    public var feeds: [LegacyFeed]
    public var entries: [LegacyEntry]
    public var articleCaches: [String: LegacyArticleCache]
    public var readingStates: [String: LegacyReadingState]
    public var artifacts: [LegacyAIArtifact]
    public var llmConfiguration: LegacyLLMConfiguration
    public var customFolders: [String]

    public static let empty = LegacyAppDatabase(
        feeds: [],
        entries: [],
        articleCaches: [:],
        readingStates: [:],
        artifacts: [],
        llmConfiguration: .default,
        customFolders: []
    )

    public init(
        feeds: [LegacyFeed],
        entries: [LegacyEntry],
        articleCaches: [String: LegacyArticleCache],
        readingStates: [String: LegacyReadingState],
        artifacts: [LegacyAIArtifact],
        llmConfiguration: LegacyLLMConfiguration,
        customFolders: [String] = []
    ) {
        self.feeds = feeds
        self.entries = entries
        self.articleCaches = articleCaches
        self.readingStates = readingStates
        self.artifacts = artifacts
        self.llmConfiguration = llmConfiguration
        self.customFolders = customFolders
    }

    private enum CodingKeys: String, CodingKey {
        case feeds, entries, articleCaches, readingStates, artifacts, llmConfiguration, customFolders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try container.decodeIfPresent([LegacyFeed].self, forKey: .feeds) ?? []
        entries = try container.decodeIfPresent([LegacyEntry].self, forKey: .entries) ?? []
        articleCaches = try container.decodeIfPresent([String: LegacyArticleCache].self, forKey: .articleCaches) ?? [:]
        readingStates = try container.decodeIfPresent([String: LegacyReadingState].self, forKey: .readingStates) ?? [:]
        artifacts = try container.decodeIfPresent([LegacyAIArtifact].self, forKey: .artifacts) ?? []
        llmConfiguration = try container.decodeIfPresent(LegacyLLMConfiguration.self, forKey: .llmConfiguration) ?? .default
        customFolders = try container.decodeIfPresent([String].self, forKey: .customFolders) ?? []
    }
}

public struct LegacyFeed: Identifiable, Codable, Hashable, Sendable {
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
    public var storedIconURL: URL?

    public init(
        id: UUID = UUID(),
        title: String,
        siteURL: URL? = nil,
        feedURL: URL,
        folder: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        lastRefreshedAt: Date? = nil,
        isDeleted: Bool = false,
        updatedAt: Date = .now,
        storedIconURL: URL? = nil
    ) {
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

public struct LegacyEntry: Identifiable, Codable, Hashable, Sendable {
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

    public init(
        id: String,
        feedID: UUID,
        title: String,
        author: String? = nil,
        url: URL? = nil,
        publishedAt: Date? = nil,
        summary: String = "",
        contentHTML: String? = nil,
        isRead: Bool = false,
        isStarred: Bool = false,
        updatedAt: Date = .now
    ) {
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

    private enum CodingKeys: String, CodingKey {
        case id, feedID, title, author, url, publishedAt, summary, contentHTML, isRead, isStarred, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        feedID = try container.decode(UUID.self, forKey: .feedID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        contentHTML = try container.decodeIfPresent(String.self, forKey: .contentHTML)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }
}

public struct LegacyReadingState: Codable, Hashable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case entryID, isRead, isStarred, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try container.decode(String.self, forKey: .entryID)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }
}

public struct LegacyArticleCache: Codable, Hashable, Sendable {
    public var entryID: String
    public var text: String
    public var html: String?
    public var imageURLs: [URL]
    public var fetchedAt: Date
    public var sourceURL: URL?
    public var isSanitized: Bool

    public init(
        entryID: String,
        text: String,
        html: String? = nil,
        imageURLs: [URL] = [],
        fetchedAt: Date = .now,
        sourceURL: URL? = nil,
        isSanitized: Bool = false
    ) {
        self.entryID = entryID
        self.text = text
        self.html = html
        self.imageURLs = imageURLs
        self.fetchedAt = fetchedAt
        self.sourceURL = sourceURL
        self.isSanitized = isSanitized
    }

    private enum CodingKeys: String, CodingKey {
        case entryID, text, html, imageURLs, fetchedAt, sourceURL, isSanitized
    }

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

public enum LegacyAIArtifactKind: String, Codable, CaseIterable, Sendable {
    case translation
    case bilingual
    case summary
    case articleContext
    case selectionExplanation
    case interpretation
}

public struct LegacyBilingualSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var original: String
    public var translation: String

    public init(id: String, original: String, translation: String) {
        self.id = id
        self.original = original
        self.translation = translation
    }
}

public struct LegacyAISelectionAnchor: Codable, Hashable, Sendable {
    public var paragraphID: String
    public var startOffset: Int
    public var endOffset: Int

    public init(paragraphID: String, startOffset: Int, endOffset: Int) {
        self.paragraphID = paragraphID
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

public struct LegacyAIArtifact: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var entryID: String
    public var kind: LegacyAIArtifactKind
    public var contentHash: String
    public var model: String
    public var targetLanguage: String
    public var promptVersion: Int
    public var content: String
    public var segments: [LegacyBilingualSegment]
    public var selectionText: String?
    public var selectionArticleHash: String?
    public var selectionAnchor: LegacyAISelectionAnchor?
    public var isComplete: Bool
    public var isDeleted: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        entryID: String,
        kind: LegacyAIArtifactKind,
        contentHash: String,
        model: String,
        targetLanguage: String,
        promptVersion: Int = 1,
        content: String = "",
        segments: [LegacyBilingualSegment] = [],
        selectionText: String? = nil,
        selectionArticleHash: String? = nil,
        selectionAnchor: LegacyAISelectionAnchor? = nil,
        isComplete: Bool = false,
        isDeleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
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
        kind = try container.decode(LegacyAIArtifactKind.self, forKey: .kind)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        model = try container.decode(String.self, forKey: .model)
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        promptVersion = try container.decodeIfPresent(Int.self, forKey: .promptVersion) ?? 1
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        segments = try container.decodeIfPresent([LegacyBilingualSegment].self, forKey: .segments) ?? []
        selectionText = try container.decodeIfPresent(String.self, forKey: .selectionText)
        selectionArticleHash = try container.decodeIfPresent(String.self, forKey: .selectionArticleHash)
        selectionAnchor = try container.decodeIfPresent(LegacyAISelectionAnchor.self, forKey: .selectionAnchor)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct LegacyLLMConfiguration: Codable, Hashable, Sendable {
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

    public static let `default` = LegacyLLMConfiguration(
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4o-mini",
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

    public init(
        providerName: String = "OpenAI 兼容接口",
        providerDescription: String = "用于翻译、总结和解读文章",
        baseURL: String,
        model: String,
        reasoningMode: String = "自动",
        temperature: Double,
        targetLanguage: String,
        allowInsecureLocalEndpoint: Bool,
        showsAISummary: Bool = true,
        automaticallyGenerateSummary: Bool = false,
        showsSelectionExplanation: Bool = true,
        showsSelectionAsk: Bool = true,
        showsSelectionTranslation: Bool = true,
        customPrompt: String = ""
    ) {
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

    private enum CodingKeys: String, CodingKey {
        case providerName, providerDescription, baseURL, model, reasoningMode, temperature
        case targetLanguage, allowInsecureLocalEndpoint, showsAISummary, automaticallyGenerateSummary
        case showsSelectionExplanation, showsSelectionAsk, showsSelectionTranslation, customPrompt
    }

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
