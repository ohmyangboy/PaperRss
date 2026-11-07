import Foundation
#if SWIFT_PACKAGE
import PaperRssAgentProtocol
#endif

public struct AgentAccessPolicy: Sendable {
    public var enabled: Bool
    public var accountIDs: Set<String>
    public let allowStarred: Bool
    public let allowStateChanges: Bool
    public let outputCharacterBudget: Int
    public init(enabled: Bool = false, accountIDs: Set<String> = [], allowStarred: Bool = false,
                allowStateChanges: Bool = false, outputCharacterBudget: Int = 100_000) {
        self.enabled = enabled
        self.accountIDs = accountIDs
        self.allowStarred = allowStarred
        self.allowStateChanges = allowStateChanges
        self.outputCharacterBudget = min(max(outputCharacterBudget, 0), 100_000)
    }
}

public enum AgentStateField: String, Codable, Sendable { case read, starred }

/// App supplies the normal provider/sync write path. No executor means isolated local-only storage.
public protocol AgentWriteExecutor: Sendable {
    func executeFeed(_ mutation: AgentFeedMutation, expiresAt: Date) async throws -> AgentFeedWriteResult
    func execute(accountID: String, articleIDs: [String], field: AgentStateField, value: Bool, expiresAt: Date) async throws -> AgentWriteResult
}

public extension AgentWriteExecutor {
    func executeFeed(_ mutation: AgentFeedMutation, expiresAt: Date) async throws -> AgentFeedWriteResult {
        throw AgentFailure("UNSUPPORTED", "Feed management is unavailable for this executor.")
    }
}

public struct AgentFeedMutation: Sendable {
    public let kind: String
    public let accountID: String
    public let feedID: String?
    public let url: String?
    public let title: String?
    public let folder: String?
    public init(kind: String, accountID: String, feedID: String? = nil, url: String? = nil, title: String? = nil, folder: String? = nil) {
        self.kind = kind; self.accountID = accountID; self.feedID = feedID
        self.url = url; self.title = title; self.folder = folder
    }
}

public struct AgentFeedWriteResult: Sendable {
    public let feedID: String?
    public let title: String?
    public let sync: String
    public init(feedID: String?, title: String?, sync: String) {
        self.feedID = feedID; self.title = title; self.sync = sync
    }
}

public struct AgentWriteResult: Sendable {
    public let appliedCount: Int
    public let skippedCount: Int
    public let sync: String
    public init(appliedCount: Int, skippedCount: Int, sync: String) {
        self.appliedCount = appliedCount; self.skippedCount = skippedCount; self.sync = sync
    }
}

public struct AgentFeedPreview: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct AgentFeedChangePreview: Codable, Sendable, Equatable {
    public let summary: String
    public let summary_en: String
}

public struct AgentFeedOperationResult: Codable, Sendable, Equatable {
    public let index: Int
    public let action: String
    public let feed_id: String?
    public let feed_title: String?
    public let status: String
    public let error_code: String?
    public let sync: String?
}

public struct AgentStatePlan: Codable, Sendable {
    public let plan_id: String
    public let account_id: String
    public let article_ids: [String]
    public let field: AgentStateField
    public let value: Bool
    public let expires_at: Date
    public let retention_notice: String
    public let action_kind: String
    public let summary: String
    public let summary_en: String
    public let affected_count: Int
    public let sample_titles: [String]
    public let approval: String
    public let next_step: String
    public var feed_changes: [AgentFeedChangePreview] = []
    public var affected_feeds: [AgentFeedPreview] = []
    public var destructive_hint: Bool = false
    public var untrusted: Bool = true
}

extension AgentStatePlan {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plan_id = try values.decode(String.self, forKey: .plan_id)
        account_id = try values.decode(String.self, forKey: .account_id)
        article_ids = try values.decode([String].self, forKey: .article_ids)
        field = try values.decode(AgentStateField.self, forKey: .field)
        value = try values.decode(Bool.self, forKey: .value)
        expires_at = try values.decode(Date.self, forKey: .expires_at)
        retention_notice = try values.decode(String.self, forKey: .retention_notice)
        action_kind = try values.decode(String.self, forKey: .action_kind)
        summary = try values.decode(String.self, forKey: .summary)
        summary_en = try values.decode(String.self, forKey: .summary_en)
        affected_count = try values.decode(Int.self, forKey: .affected_count)
        sample_titles = try values.decode([String].self, forKey: .sample_titles)
        approval = try values.decode(String.self, forKey: .approval)
        next_step = try values.decode(String.self, forKey: .next_step)
        feed_changes = try values.decodeIfPresent([AgentFeedChangePreview].self, forKey: .feed_changes) ?? []
        affected_feeds = try values.decodeIfPresent([AgentFeedPreview].self, forKey: .affected_feeds) ?? []
        destructive_hint = try values.decode(Bool.self, forKey: .destructive_hint)
        untrusted = try values.decode(Bool.self, forKey: .untrusted)
    }
}

public struct AgentStateReceipt: Codable, Sendable, Equatable {
    public let operation_id: String
    public let applied_count: Int
    public let skipped_count: Int
    public var results: [AgentFeedOperationResult]? = nil
    public var failed_count: Int? = nil
    public var feed_id: String? = nil
    public var feed_title: String? = nil
    public var untrusted: Bool = true
    public let local_commit: String
    public let sync: String
}

public struct AgentArticleMetadata: Codable, Sendable {
    public let id: String
    public let account_id: String
    public let feed_id: String
    public let title: String
    public let authors: [String]
    public let source_url: String?
    public let source_url_unavailable_reason: String?
    public let feed_title: String
    public let published_at: Date?
    public let read: Bool
    public let starred: Bool
    public let state_token: String
    public let excerpt: String
    public let content_available: Bool
    public let content_source: String
    public let retrieved_at: Date
    public let truncated: Bool
    public let untrusted: Bool
}

/// Validated navigation intent; UI execution belongs to the App process.
public struct AgentOpenRequest: Sendable, Equatable {
    public let accountID: String
    public let feedID: UUID
    public let articleID: String?
    public init(accountID: String, feedID: UUID, articleID: String? = nil) {
        self.accountID = accountID
        self.feedID = feedID
        self.articleID = articleID
    }
}

public enum AgentAccountSnapshots {
    /// Explicit allowlist: endpoint, username and sync errors never enter the wire DTO.
    public static func read(database: LibraryDatabase, accounts: [AccountRecord]? = nil,
                                 syncStates: [String: AccountSyncStateRecord]? = nil,
                                 canOpen: Bool = false) throws -> [AgentJSON] {
        let repository = AccountRepository(database: database)
        let records = try accounts ?? database.read { try repository.fetchAllAccounts(in: $0) }
        return try records.map { account in
            let provider = LocalAccountProvider(accountID: account.id, database: database)
            let feeds = try provider.fetchFeeds()
            let counts = try provider.timelineQueryService.fetchSidebarCounts(accountID: account.id, startOfDayTimestamp: 0)
            let sync = try syncStates?[account.id] ?? database.read { try repository.fetchSyncState(accountID: account.id, in: $0) }
            let timestamp = sync?.lastSyncCompletedAt ?? (account.type == AccountType.local.rawValue
                ? feeds.compactMap(\.lastRefreshedAt).max()?.timeIntervalSince1970 : nil)
            var host: String?
            if [AccountType.freshRSS.rawValue, AccountType.miniflux.rawValue].contains(account.type),
               let raw = account.endpointURL, let url = URLComponents(string: raw),
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               let value = url.host, !value.isEmpty,
               !value.contains("@"), !value.contains("%"), !value.contains("/"),
               !value.contains("?"), !value.contains("#") {
                host = value + (url.port.map { ":\($0)" } ?? "")
            }
            return .object([
                "account_id": .string(account.id), "type": .string(account.type),
                "display_name": .string(account.displayName), "enabled": .bool(account.isEnabled),
                "server_host": host.map(AgentJSON.string) ?? .null,
                "feed_count": .number(Double(feeds.count)), "unread_count": .number(Double(counts.allUnread)),
                "last_sync_at": timestamp.map { .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0))) } ?? .null,
                "capabilities": .array((account.isEnabled ? ["metadata.read", "content.read.selection"] + (canOpen ? ["ui.open"] : []) : []).map(AgentJSON.string))
            ])
        }
    }
}
