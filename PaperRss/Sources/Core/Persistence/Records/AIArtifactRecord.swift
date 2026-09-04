import Foundation
import GRDB

/// `ai_artifacts` 表的持久化映射模型（文章级 AI 产物与全局翻译记忆）。
///
/// 遵循 Architecture Contract (Section 11)。
public struct AIArtifactRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "ai_artifacts"

    public var id: String
    public var accountID: String?
    public var itemID: String?
    public var subjectKey: String
    public var kind: String
    public var contentHash: String
    public var model: String
    public var targetLanguage: String
    public var promptVersion: Int
    public var providerID: String?
    public var configurationFingerprint: String?
    public var content: String
    public var segmentsJSON: String?
    public var selectionText: String?
    public var selectionArticleHash: String?
    public var selectionAnchorJSON: String?
    public var isComplete: Bool
    public var isDeleted: Bool
    public var createdAt: Double
    public var updatedAt: Double

    public init(
        id: String,
        accountID: String? = nil,
        itemID: String? = nil,
        subjectKey: String,
        kind: String,
        contentHash: String,
        model: String,
        targetLanguage: String,
        promptVersion: Int = 1,
        providerID: String? = nil,
        configurationFingerprint: String? = nil,
        content: String = "",
        segmentsJSON: String? = nil,
        selectionText: String? = nil,
        selectionArticleHash: String? = nil,
        selectionAnchorJSON: String? = nil,
        isComplete: Bool = false,
        isDeleted: Bool = false,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.accountID = accountID
        self.itemID = itemID
        self.subjectKey = subjectKey
        self.kind = kind
        self.contentHash = contentHash
        self.model = model
        self.targetLanguage = targetLanguage
        self.promptVersion = promptVersion
        self.providerID = providerID
        self.configurationFingerprint = configurationFingerprint
        self.content = content
        self.segmentsJSON = segmentsJSON
        self.selectionText = selectionText
        self.selectionArticleHash = selectionArticleHash
        self.selectionAnchorJSON = selectionAnchorJSON
        self.isComplete = isComplete
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case itemID = "item_id"
        case subjectKey = "subject_key"
        case kind
        case contentHash = "content_hash"
        case model
        case targetLanguage = "target_language"
        case promptVersion = "prompt_version"
        case providerID = "provider_id"
        case configurationFingerprint = "configuration_fingerprint"
        case content
        case segmentsJSON = "segments_json"
        case selectionText = "selection_text"
        case selectionArticleHash = "selection_article_hash"
        case selectionAnchorJSON = "selection_anchor_json"
        case isComplete = "is_complete"
        case isDeleted = "is_deleted"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
