import Foundation
import GRDB

/// `feed_folders` 表的持久化映射模型。
///
/// 遵循 Architecture Contract (Section 8.4)。
public struct FeedFolderRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "feed_folders"

    public var feedID: String
    public var folderID: String

    public init(feedID: String, folderID: String) {
        self.feedID = feedID
        self.folderID = folderID
    }

    enum CodingKeys: String, CodingKey {
        case feedID = "feed_id"
        case folderID = "folder_id"
    }
}
