import Foundation
import GRDB

/// 管理 AI 生成产物（摘要、翻译、全局翻译记忆等）的持久化仓库。
///
/// 遵循 Architecture Contract (Section 11)。
public final class AIArtifactRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Database-Scoped Primitives

    public func fetchArtifact(id: String, in db: Database) throws -> AIArtifactRecord? {
        try AIArtifactRecord.filter(Column("id") == id).fetchOne(db)
    }

    public func fetchArtifactByArticle(
        itemID: String,
        kind: String,
        contentHash: String,
        in db: Database
    ) throws -> AIArtifactRecord? {
        try AIArtifactRecord
            .filter(
                Column("item_id") == itemID &&
                Column("kind") == kind &&
                Column("content_hash") == contentHash &&
                Column("is_deleted") == false
            )
            .order(Column("updated_at").desc)
            .fetchOne(db)
    }

    public func fetchGlobalArtifact(
        subjectKey: String,
        kind: String,
        contentHash: String,
        in db: Database
    ) throws -> AIArtifactRecord? {
        try AIArtifactRecord
            .filter(
                Column("subject_key") == subjectKey &&
                Column("kind") == kind &&
                Column("content_hash") == contentHash &&
                Column("is_deleted") == false
            )
            .order(Column("updated_at").desc)
            .fetchOne(db)
    }

    public func saveArtifact(_ record: AIArtifactRecord, in db: Database) throws {
        try record.save(db)
    }

    public func deleteArtifact(id: String, in db: Database) throws {
        _ = try AIArtifactRecord.filter(Column("id") == id).deleteAll(db)
    }

    // MARK: - Domain AIArtifact Helpers

    public func fetchLatestArtifactModel(
        entryID: String,
        kind: AIArtifactKind,
        isCompleteOnly: Bool = false,
        in db: Database
    ) throws -> AIArtifact? {
        var query = AIArtifactRecord
            .filter(
                (Column("item_id") == entryID || Column("subject_key") == entryID) &&
                Column("kind") == kind.rawValue &&
                Column("is_deleted") == false
            )
        if isCompleteOnly {
            query = query.filter(Column("is_complete") == true)
        }
        guard let record = try query.order(Column("updated_at").desc).fetchOne(db) else { return nil }
        return domainArtifactFromRecord(record)
    }

    public func fetchBilingualArtifactModel(
        entryID: String,
        contentHash: String,
        model: String,
        in db: Database
    ) throws -> AIArtifact? {
        let record = try AIArtifactRecord
            .filter(
                (Column("item_id") == entryID || Column("subject_key") == entryID) &&
                Column("kind") == AIArtifactKind.bilingual.rawValue &&
                Column("content_hash") == contentHash &&
                Column("model") == model &&
                Column("is_deleted") == false
            )
            .order(Column("updated_at").desc)
            .fetchOne(db)
        return record.flatMap { domainArtifactFromRecord($0) }
    }

    public func fetchGlobalTranslationMemory(key: String, in db: Database) throws -> AIArtifact? {
        let record = try AIArtifactRecord
            .filter(
                Column("subject_key") == key &&
                Column("is_deleted") == false
            )
            .order(Column("updated_at").desc)
            .fetchOne(db)
        return record.flatMap { domainArtifactFromRecord($0) }
    }

    public func fetchSelectionArtifacts(
        entryID: String,
        articleHash: String,
        in db: Database
    ) throws -> [AIArtifact] {
        // kind 覆盖 selectionExplanation 与 interpretation：划词提问
        // (askSelection) 以 interpretation 落库，恢复划词标注时两者都必须可见。
        // selection_article_hash 兼容 NULL：executeSelectionAI 统一保存路径的
        // 历史版本曾丢失该字段；hash 为空的记录仍可尝试恢复，锚点失效由
        // JS 侧 rangeForAnchor 解析失败兜底，不会错画。
        let records = try AIArtifactRecord
            .filter(
                (Column("item_id") == entryID || Column("subject_key") == entryID) &&
                (Column("kind") == AIArtifactKind.selectionExplanation.rawValue ||
                 Column("kind") == AIArtifactKind.interpretation.rawValue) &&
                (Column("selection_article_hash") == articleHash ||
                 Column("selection_article_hash") == nil) &&
                Column("is_complete") == true &&
                Column("is_deleted") == false
            )
            .order(Column("created_at").asc)
            .fetchAll(db)
        return records.compactMap { domainArtifactFromRecord($0) }
    }

    public func saveArtifactModel(_ artifact: AIArtifact, accountID: String? = "local-default", in db: Database) throws {
        let segmentsJSON = (try? LegacyMigrationJSONEncoder.encodeString(artifact.segments)) ?? "[]"
        let anchorJSON: String? = try artifact.selectionAnchor.flatMap { try LegacyMigrationJSONEncoder.encodeString($0) }

        let isGlobalTM = artifact.entryID.hasPrefix("translation-memory-v2:")
        var effectiveAccountID: String? = nil
        var effectiveItemID: String? = nil

        if isGlobalTM {
            effectiveAccountID = nil
            effectiveItemID = nil
        } else if let item = try ItemRecord.filter(Column("id") == artifact.entryID).fetchOne(db) {
            effectiveAccountID = item.accountID
            effectiveItemID = item.id
        } else {
            effectiveAccountID = accountID
            effectiveItemID = nil
        }

        let record = AIArtifactRecord(
            id: artifact.id.uuidString,
            accountID: effectiveAccountID,
            itemID: effectiveItemID,
            subjectKey: artifact.entryID,
            kind: artifact.kind.rawValue,
            contentHash: artifact.contentHash,
            model: artifact.model,
            targetLanguage: artifact.targetLanguage,
            promptVersion: artifact.promptVersion,
            content: artifact.content,
            segmentsJSON: segmentsJSON,
            selectionText: artifact.selectionText,
            selectionArticleHash: artifact.selectionArticleHash,
            selectionAnchorJSON: anchorJSON,
            isComplete: artifact.isComplete,
            isDeleted: artifact.isDeleted,
            createdAt: artifact.createdAt.timeIntervalSince1970,
            updatedAt: artifact.updatedAt.timeIntervalSince1970
        )
        try saveArtifact(record, in: db)
    }

    private func domainArtifactFromRecord(_ record: AIArtifactRecord) -> AIArtifact? {
        guard let uuid = UUID(uuidString: record.id),
              let kind = AIArtifactKind(rawValue: record.kind) else { return nil }

        let segments: [BilingualSegment] = record.segmentsJSON.flatMap { json in
            try? JSONDecoder().decode([BilingualSegment].self, from: Data(json.utf8))
        } ?? []
        let anchor = record.selectionAnchorJSON.flatMap {
            try? JSONDecoder().decode(AISelectionAnchor.self, from: Data($0.utf8))
        }

        return AIArtifact(
            id: uuid,
            entryID: record.subjectKey,
            kind: kind,
            contentHash: record.contentHash,
            model: record.model,
            targetLanguage: record.targetLanguage,
            promptVersion: record.promptVersion,
            content: record.content,
            segments: segments,
            selectionText: record.selectionText,
            selectionArticleHash: record.selectionArticleHash,
            selectionAnchor: anchor,
            isComplete: record.isComplete,
            isDeleted: record.isDeleted,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            updatedAt: Date(timeIntervalSince1970: record.updatedAt)
        )
    }

    // MARK: - Async Public APIs

    public func fetchLatestArtifactModel(
        entryID: String,
        kind: AIArtifactKind,
        isCompleteOnly: Bool = false
    ) async throws -> AIArtifact? {
        try database.read { db in
            try fetchLatestArtifactModel(entryID: entryID, kind: kind, isCompleteOnly: isCompleteOnly, in: db)
        }
    }

    public func fetchBilingualArtifactModel(
        entryID: String,
        contentHash: String,
        model: String
    ) async throws -> AIArtifact? {
        try database.read { db in
            try fetchBilingualArtifactModel(entryID: entryID, contentHash: contentHash, model: model, in: db)
        }
    }

    public func fetchGlobalTranslationMemory(key: String) async throws -> AIArtifact? {
        try database.read { db in
            try fetchGlobalTranslationMemory(key: key, in: db)
        }
    }

    public func fetchSelectionArtifacts(
        entryID: String,
        articleHash: String
    ) async throws -> [AIArtifact] {
        try database.read { db in
            try fetchSelectionArtifacts(entryID: entryID, articleHash: articleHash, in: db)
        }
    }

    public func saveArtifactModel(_ artifact: AIArtifact, accountID: String? = "local-default") async throws {
        try database.write { db in
            try saveArtifactModel(artifact, accountID: accountID, in: db)
        }
    }

    public func fetchArtifact(id: String) async throws -> AIArtifactRecord? {
        try database.read { db in
            try fetchArtifact(id: id, in: db)
        }
    }

    public func fetchArtifactByArticle(itemID: String, kind: String, contentHash: String) async throws -> AIArtifactRecord? {
        try database.read { db in
            try fetchArtifactByArticle(itemID: itemID, kind: kind, contentHash: contentHash, in: db)
        }
    }

    public func fetchGlobalArtifact(subjectKey: String, kind: String, contentHash: String) async throws -> AIArtifactRecord? {
        try database.read { db in
            try fetchGlobalArtifact(subjectKey: subjectKey, kind: kind, contentHash: contentHash, in: db)
        }
    }

    public func saveArtifact(_ record: AIArtifactRecord) async throws {
        try database.write { db in
            try saveArtifact(record, in: db)
        }
    }

    public func deleteArtifact(id: String) async throws {
        try database.write { db in
            try deleteArtifact(id: id, in: db)
        }
    }
}
