import Foundation
import GRDB

/// Repairs only requested timeline pages; never scans the full library at
/// startup, and never fetches a webpage to recover discarded descriptions.
public actor ArticlePreviewBackfill {
    private let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }

    private struct Snapshot: Sendable {
        let id: String
        let html: String?
        let url: String?
        let baseURL: URL?
        let updatedAt: Double
        let revision: Int
    }

    @discardableResult
    public func prepare(entryIDs: [String]) async throws -> Int {
        let ids = Array(Set(entryIDs.prefix(100)))
        guard !ids.isEmpty else { return 0 }
        try Task.checkCancellation()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let snapshots: [Snapshot] = try await database.readAsync { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.item_id, a.content_html, a.url, a.content_updated_at,
                       a.preview_extraction_revision,
                       COALESCE(NULLIF(a.url, ''), f.site_url, f.feed_url) AS base_url
                FROM articles a JOIN items i ON i.id = a.item_id
                JOIN feeds f ON f.id = i.feed_id
                WHERE a.item_id IN (\(placeholders)) AND a.preview_extraction_revision < ?
                LIMIT 100;
                """, arguments: StatementArguments(ids + [String(EntryPreviewImage.currentRevision)]))
            return rows.map { row in
                Snapshot(id: row["item_id"], html: row["content_html"], url: row["url"],
                         baseURL: (row["base_url"] as String?).flatMap { URL(string: $0) },
                         updatedAt: row["content_updated_at"], revision: row["preview_extraction_revision"])
            }
        }
        let results = snapshots.map { snapshot in
            (snapshot, EntryPreviewImageExtractor.extract(contentHTML: snapshot.html, baseURL: snapshot.baseURL))
        }
        try Task.checkCancellation()
        return try await database.writeAsync { db in
            var changed = 0
            for (snapshot, preview) in results {
                // A refresh may have arrived while we were extracting. Never
                // overwrite newer metadata, content, or article state.
                try db.execute(sql: """
                    UPDATE articles SET preview_image_url = ?, preview_image_source = ?,
                        preview_input_hash = ?, preview_extraction_revision = ?
                    WHERE item_id = ? AND preview_extraction_revision = ?
                        AND content_updated_at = ? AND content_html IS ? AND url IS ?;
                    """, arguments: [preview.url?.absoluteString, preview.source, preview.inputHash,
                                      preview.revision, snapshot.id, snapshot.revision,
                                      snapshot.updatedAt, snapshot.html, snapshot.url])
                changed += db.changesCount
            }
            return changed
        }
    }
}
