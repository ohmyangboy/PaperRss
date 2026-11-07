import Foundation

/// Wire-only values. This module deliberately has no database or app dependency.
public enum AgentJSON: Codable, Sendable, Equatable {
    case object([String: AgentJSON]), array([AgentJSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        func decodeType<T: Decodable>(_ type: T.Type) throws -> T? {
            do { return try value.decode(type) }
            catch DecodingError.typeMismatch { return nil } // JSON union discrimination only.
            catch { throw error }
        }
        if value.decodeNil() { self = .null }
        else if let bool = try decodeType(Bool.self) { self = .bool(bool) }
        else if let number = try decodeType(Double.self) { self = .number(number) }
        else if let string = try decodeType(String.self) { self = .string(string) }
        else if let array = try decodeType([AgentJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: AgentJSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public subscript(_ key: String) -> AgentJSON? { objectValue?[key] }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var intValue: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v,
              v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var objectValue: [String: AgentJSON]? { if case .object(let v) = self { v } else { nil } }
    public var arrayValue: [AgentJSON]? { if case .array(let v) = self { v } else { nil } }
    public static func encoding<T: Encodable>(_ value: T) throws -> AgentJSON {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(AgentJSON.self, from: encoder.encode(value))
    }
}

public struct AgentFailure: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Only the app-side implementation may own library services. Helpers receive DTOs.
public protocol AgentBridge: Sendable {
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON
    /// Permanently end this helper session. This is separate from cancelling one request.
    func shutdown() async
}

public extension AgentBridge {
    func shutdown() async {}
}

/// Shared discovery names keep the App status and helper tools/list aligned.
public enum AgentToolCatalog {
    public static let names = ["status", "list_feeds", "list_articles", "get_article", "get_content", "open",
                               "plan_manage_feeds", "plan_state_change", "plan_mark_read", "apply_plan", "apply_state_change", "plan_add_feed", "plan_rename_feed", "plan_remove_feed", "add_feed", "rename_feed", "remove_feed"]
        .map { "paperrss_" + $0 }
}


/// User-facing MCP catalog shared by Settings and the tool-definition contract tests.
/// Aliases stay on their primary row without duplicate rows.
/// get_content remains available at runtime for QA but is hidden until content authorization UI ships.
public enum AgentMCPToolCatalog {
    public enum Group: String, CaseIterable, Sendable {
        case readOnly, approvalGated

        public var zhTitle: String {
            switch self {
            case .readOnly: "只读"
            case .approvalGated: "需审批写入"
            }
        }

        public var enTitle: String {
            switch self {
            case .readOnly: "Read-only"
            case .approvalGated: "Approval-gated writes"
            }
        }
    }

    public struct Entry: Identifiable, Sendable {
        public let name: String
        public let group: Group
        public let zhSummary: String
        public let enSummary: String
        public let exampleArgs: String
        public var example: String { name + "\n" + exampleArgs }
        public let aliases: [String]
        public var id: String { name }

        init(_ name: String, _ group: Group, _ zh: String, _ en: String,
             _ exampleArgs: String, aliases: [String] = []) {
            self.name = "paperrss_" + name
            self.group = group
            zhSummary = zh
            enSummary = en
            self.exampleArgs = exampleArgs
            self.aliases = aliases.map { "paperrss_" + $0 }
        }
    }

    public static let entries: [Entry] = [
        Entry("status", .readOnly, "查看账号、审批模式与待批准项；可查询计划状态。",
              "View accounts, approval mode and pending approvals; check a plan's status.",
              """
              {
                "plan_id": "plan-id"
              }
              """),
        Entry("open", .readOnly, "在 App 中定位文章或订阅，不自动标为已读。",
              "Locate an article or feed in the App without marking it read.",
              """
              {
                "account_id": "account-id",
                "article_id": "article-id"
              }
              """),
        Entry("list_feeds", .readOnly, "分页查看账号内的订阅源与计数。",
              "List a page of feeds and counts in an account.",
              """
              {
                "account_id": "account-id",
                "limit": 20
              }
              """),
        Entry("list_articles", .readOnly, "查看未读、收藏或已授权选择的文章元数据，不抓取正文。",
              "List unread, starred or selected article metadata without fetching content.",
              """
              {
                "account_id": "account-id",
                "scope": "unread"
              }
              """),
        Entry("get_article", .readOnly, "查看文章元数据与本地正文可用性，不返回正文。",
              "Get article metadata and stored-content availability, without the body.",
              """
              {
                "account_id": "account-id",
                "article_id": "article-id"
              }
              """),
        Entry("plan_state_change", .approvalGated, "计划更改指定文章的已读或收藏状态；批准后 App 立即执行。",
              "Plan read or starred changes for exact articles; the App applies on approval.",
              """
              {
                "account_id": "account-id",
                "article_ids": [
                  "article-id"
                ],
                "field": "starred",
                "value": true
              }
              """),
        Entry("plan_mark_read", .approvalGated, "计划将订阅、文件夹或账号的未读文章标为已读；批准后立即执行。",
              "Plan marking unread articles in a feed, folder or account as read; applies on approval.",
              """
              {
                "account_id": "account-id",
                "scope": "feed",
                "feed_id": "feed-id"
              }
              """),
        Entry("apply_plan", .approvalGated, "仅用于已批准计划的补偿重试或回执重放；不能代替用户批准。",
              "Recovery retry or receipt replay for approved plans only; cannot grant approval.",
              """
              {
                "plan_id": "plan-id",
                "approval_id": "app-issued-id",
                "idempotency_key": "retry-key"
              }
              """,
              aliases: ["apply_state_change"]),
        Entry("plan_manage_feeds", .approvalGated, "批量添加、重命名或删除指定账号的 1–50 个订阅；逐项返回结果。",
              "Plan 1–50 feed additions, renames or removals in one account; returns per-item results.",
              """
              {
                "account_id": "account-id",
                "operations": [{"action": "add_feed", "url": "https://example.org/feed.xml"}]
              }
              """),
        Entry("plan_add_feed", .approvalGated, "计划添加订阅源；按审批模式执行。",
              "Plan adding a feed under the current approval mode.",
              """
              {
                "account_id": "account-id",
                "url": "https://example.org/feed.xml"
              }
              """,
              aliases: ["add_feed"]),
        Entry("plan_rename_feed", .approvalGated, "计划重命名订阅源；按审批模式执行。",
              "Plan renaming a feed under the current approval mode.",
              """
              {
                "account_id": "account-id",
                "feed_id": "feed-id",
                "title": "News"
              }
              """,
              aliases: ["rename_feed"]),
        Entry("plan_remove_feed", .approvalGated, "计划删除订阅及历史文章（含收藏），不可撤销。",
              "Plan deleting a feed and its history, including starred articles; no undo.",
              """
              {
                "account_id": "account-id",
                "feed_id": "feed-id"
              }
              """,
              aliases: ["remove_feed"])
    ]
}
