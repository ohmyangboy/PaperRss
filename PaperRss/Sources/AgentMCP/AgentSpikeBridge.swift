import Foundation
#if !PAPERRSS_AGENT_NATIVE
import PaperRssAgentProtocol
#endif

/// Fail-closed stub used when no App transport is attached (unit tests / disabled path).
/// Production non-fixture helpers use `AgentIPCClientBridge` over Unix domain socket IPC.
public struct AgentUnavailableBridge: AgentBridge {
    public let enabled: Bool
    public init(enabled: Bool = false) { self.enabled = enabled }

    public func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        guard enabled else { throw AgentFailure("NOT_ENABLED", "Local Agent access is disabled.") }
        throw AgentFailure(
            "APP_NOT_RUNNING",
            "PaperRss App is not running or Agent IPC is not listening. Start PaperRss with agentMCPEnabled ON; non-fixture helpers connect over Unix domain socket."
        )
    }
}

/// Explicit smoke fixture, compiled separately from PaperRssCore. All data here
/// is synthetic; no file, SQLite, credential, or network API is used.
public struct AgentFixtureBridge: AgentBridge {
    private let enabled: Bool
    public init(enabled: Bool = false) { self.enabled = enabled }

    public func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        guard enabled else { throw AgentFailure("NOT_ENABLED", "Set PAPERRSS_AGENT_ENABLED=1 for the explicit fixture session.") }
        try AgentMCPTools.validate(name: tool, arguments: arguments)
        if tool == "paperrss_status" {
            // Keep fixture status keys aligned with App/Core overlays so clients
            // can share one parser (Bro steer: pair_state / paired / transport).
            return .object(["version": .string("0.1.0-spike"), "enabled": .bool(true),
                            "paired": .bool(false), "pair_state": .string("fixture_only"),
                            "transport": .string("fixture"), "fixture": .bool(true),
                            "tools": .array(AgentToolCatalog.names.map(AgentJSON.string)),
                            "capabilities": .array([.string("metadata.read"), .string("feeds.refresh")]),
                            "allowed_accounts": .array([.object(["account_id": .string("fixture-local"),
                                "capabilities": .array([.string("metadata.read"), .string("feeds.refresh")])])]),
                            "accounts": .array([.object(["account_id": .string("fixture-local"),
                                "capabilities": .array([.string("metadata.read"), .string("feeds.refresh")])])]),
                            "selections": .array([]), "selection_ids": .array([])])
        }
        if let account = arguments["account_id"]?.stringValue, account != "fixture-local" {
            throw AgentFailure("UNAUTHORIZED", "The fixture grants access only to fixture-local.")
        }
        if arguments["cursor"] != nil {
            throw AgentFailure("INVALID_ARGUMENT", "Fixture has one page and does not accept cursors.")
        }
        switch tool {
        case "paperrss_open":
            throw AgentFailure("UNSUPPORTED", "Fixture has no App window to open.")
        case "paperrss_list_feeds":
            return .object(["feeds": .array([.object(["id": .string("fixture-feed"), "title": .string("PaperRss smoke fixture"),
                "account_id": .string("fixture-local"), "untrusted": .bool(true), "unread_count": .number(1), "article_count": .number(1)])]), "next_cursor": .null])
        case "paperrss_list_articles":
            if arguments["scope"]?.stringValue == "selection" {
                throw AgentFailure("UNAUTHORIZED", "No content selections have been granted in fixture mode.")
            }
            var withinTimeRange = true
            if let since = arguments["since"]?.stringValue {
                let formatter = ISO8601DateFormatter()
                let publicationDate = formatter.date(from: "2026-10-27T00:00:00Z")!
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var date = formatter.date(from: since)
                if date == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    date = formatter.date(from: since)
                }
                guard let date else { throw AgentFailure("INVALID_ARGUMENT", "Invalid since timestamp.") }
                withinTimeRange = publicationDate >= date
            }
            let matches = withinTimeRange && arguments["scope"]?.stringValue != "starred"
                && (arguments["feed_id"] == nil || arguments["feed_id"]?.stringValue == "fixture-feed")
                && (arguments["query"]?.stringValue.map { "Synthetic Swift article".localizedCaseInsensitiveContains($0) } ?? true)
            return .object(["articles": .array(matches ? [Self.article] : []), "next_cursor": .null,
                            "snapshot_at": .string("2026-10-27T00:00:00Z")])
        case "paperrss_get_article":
            guard arguments["article_id"]?.stringValue == "fixture-article" else { throw AgentFailure("NOT_FOUND", "Fixture article not found.") }
            return Self.article
        case "paperrss_get_content":
            throw AgentFailure("UNAUTHORIZED", "Fixture has no approved content selection. A client cannot issue its own approval.")
        case "paperrss_refresh_feeds":
            let scope = arguments["scope"]?.stringValue ?? ""
            if scope == "feeds" {
                let ids = arguments["feed_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard ids.allSatisfy({ $0 == "fixture-feed" }) else {
                    throw AgentFailure("NOT_FOUND", "Fixture feed not found.")
                }
            }
            let snapshot = AgentRefreshSnapshot(operationID: "refresh-fixture", state: "completed", scope: scope,
                accountID: arguments["account_id"]?.stringValue,
                feedCount: scope == "feeds" ? (arguments["feed_ids"]?.arrayValue?.count ?? 0) : 0, joined: false)
            return .object(snapshot.fields())
        case "paperrss_plan_state_change", "paperrss_plan_mark_read", "paperrss_apply_plan", "paperrss_apply_state_change",
             "paperrss_plan_add_feed", "paperrss_plan_rename_feed", "paperrss_plan_remove_feed",
             "paperrss_add_feed", "paperrss_rename_feed", "paperrss_remove_feed":
            throw AgentFailure("CONFIRMATION_REQUIRED", "Fixture is read-only and cannot issue approvals. Use the running PaperRss App for human-approved writes.")
        default:
            throw AgentFailure("INVALID_ARGUMENT", "Unknown tool.")
        }
    }

    private static let article: AgentJSON = .object([
        "id": .string("fixture-article"), "account_id": .string("fixture-local"), "feed_id": .string("fixture-feed"),
        "title": .string("Synthetic Swift article"), "authors": .array([]),
        "source_url": .string("https://example.org/fixture"), "feed_title": .string("PaperRss smoke fixture"),
        "published_at": .string("2026-10-27T00:00:00Z"), "read": .bool(false), "starred": .bool(false),
        "state_token": .string("fixture-state-1"), "excerpt": .string("Synthetic metadata for local MCP smoke testing."),
        "content_available": .bool(false), "content_source": .string("feed_summary"),
        "retrieved_at": .string("2026-10-27T00:00:00Z"), "truncated": .bool(false), "untrusted": .bool(true)
    ])
}
