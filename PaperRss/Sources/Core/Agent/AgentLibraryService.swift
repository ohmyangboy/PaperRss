import Foundation
import GRDB
#if SWIFT_PACKAGE
import PaperRssAgentProtocol
#endif

/// One app-owned authorization session. No database creation, refresh or network commands.
/// The App creates one service per authenticated IPC connection and revokes it on disconnect.
public actor AgentLibraryService: AgentBridge {
    private let database: LibraryDatabase
    private let provider: LocalAccountProvider
    private let engine: ArticlePreparationEngine
    private let clock: @Sendable () -> Date
    private let opener: (@MainActor @Sendable (AgentOpenRequest) throws -> Void)?
    private let writeExecutor: (any AgentWriteExecutor)?
    private var applying = false
    private var policy: AgentAccessPolicy
    private var remainingCharacters: Int
    private var requestTimes: [Date] = []
    private struct Selection {
        let account: String
        let ids: Set<String>
        let expires: Date
    }
    private struct PendingPlan {
        let dto: AgentStatePlan
        let before: [String: ArticleStateRecord]
        var mutation: AgentFeedMutation? = nil
        var mutations: [AgentFeedMutation]? = nil
        var denied = false
        var approval: String?
        var receipt: AgentStateReceipt?
    }
    private struct Replay {
        let plan: String
        let approval: String
        let receipt: AgentStateReceipt
    }
    private struct Cursor {
        let arguments: [String: AgentJSON]
        let offset: Int
        let expires: Date
    }
    private var selections: [String: Selection] = [:]
    private var plans: [String: PendingPlan] = [:]
    private var receipts: [String: Replay] = [:]
    private var cursors: [String: Cursor] = [:]

    public init(database: LibraryDatabase, accountID: String = "local-default",
                policy: AgentAccessPolicy = AgentAccessPolicy(),
                engine: ArticlePreparationEngine = ArticlePreparationEngine(),
                clock: @escaping @Sendable () -> Date = { Date() },
                writeExecutor: (any AgentWriteExecutor)? = nil,
                opener: (@MainActor @Sendable (AgentOpenRequest) throws -> Void)? = nil) {
        self.database = database
        self.provider = LocalAccountProvider(accountID: accountID, database: database)
        self.policy = policy
        self.engine = engine
        self.clock = clock
        self.opener = opener
        self.writeExecutor = writeExecutor
        self.remainingCharacters = policy.outputCharacterBudget
    }

    /// App-owned account changes update scope without resetting budgets or approvals.
    public func updateAccountIDs(_ accountIDs: Set<String>) {
        policy.accountIDs = accountIDs
        selections = selections.filter { accountIDs.contains($0.value.account) }
        plans = plans.filter { accountIDs.contains($0.value.dto.account_id) }
    }

    /// App-only revocation: invalidates all grants immediately. Never exposed as an MCP tool.
    public func revoke() {
        policy.enabled = false
        selections.removeAll()
        plans.removeAll()
        cursors.removeAll()
    }

    /// Called only by the trusted App confirmation bridge, never by RPC arguments.
    public func authorizeContent(accountID: String, articleIDs: [String]) throws -> String {
        try authorize(accountID)
        guard !articleIDs.isEmpty, articleIDs.count <= 20, Set(articleIDs).count == articleIDs.count else {
            throw AgentFailure("INVALID_ARGUMENT", "Select 1–20 distinct articles.")
        }
        try database.read { db in
            for id in articleIDs { _ = try ownedEntry(id, account: accountID, in: db) }
        }
        guard selections.count < 20 else { throw AgentFailure("RATE_LIMITED", "Too many active selections.") }
        let id = UUID().uuidString
        selections[id] = Selection(account: accountID, ids: Set(articleIDs), expires: clock().addingTimeInterval(900))
        return id
    }

    /// App-only approval, bound to the immutable plan. Confirmation UI must show retention_notice.
    public func approve(planID: String) throws -> String {
        try requireEnabled()
        guard var plan = plans[planID], plan.dto.expires_at > clock(), plan.receipt == nil else {
            throw AgentFailure("CONFLICT", "Plan is missing, expired or already committed.")
        }
        guard !plan.denied else { throw AgentFailure("DENIED", "Plan was denied.") }
        try authorize(plan.dto.account_id, write: true)
        let approval = plan.approval ?? UUID().uuidString
        plan.approval = approval
        plans[planID] = plan
        return approval
    }

    /// Trusted App policy/UI entry point; uses the same executor and receipt path as MCP retries.
    @discardableResult
    public func approveAndApply(planID: String) async throws -> String {
        try requireEnabled()
        let approval: String
        if let plan = plans[planID], plan.receipt != nil, let existing = plan.approval {
            approval = existing
        } else {
            approval = try approve(planID: planID)
        }
        _ = try await apply(["plan_id": .string(planID), "approval_id": .string(approval),
                             "idempotency_key": .string("app-approve-\(planID)")])
        return approval
    }

    /// Trusted App UI only. There is deliberately no IPC tool for approval or denial.
    public func deny(planID: String) throws {
        try requireEnabled()
        guard var plan = plans[planID], plan.dto.expires_at > clock(), plan.receipt == nil, !applying else {
            throw AgentFailure("CONFLICT", "Plan is unavailable or executing.")
        }
        plan.denied = true
        plan.approval = nil
        plans[planID] = plan
    }

    public func call(tool: String, arguments a: [String: AgentJSON]) async throws -> AgentJSON {
        try Task.checkCancellation()
        if tool == "paperrss_status" { return try status(a) }
        try requireEnabled()
        let now = clock()
        requestTimes.removeAll { now.timeIntervalSince($0) >= 60 }
        guard requestTimes.count < 60 else { throw AgentFailure("RATE_LIMITED", "Retry after one minute.") }
        requestTimes.append(now)
        cursors = cursors.filter { $0.value.expires > now }
        selections = selections.filter { $0.value.expires > now }
        // Keep bounded expired plans so status can still explain their terminal state.
        switch tool {
        case "paperrss_open": return try await open(a)
        case "paperrss_list_feeds": return try listFeeds(a)
        case "paperrss_list_articles": return try listArticles(a)
        case "paperrss_get_article":
            let account = try string(a, "account_id")
            try authorize(account)
            let metadata = try metadataForID(try string(a, "article_id"), account: account, requireScope: true)
            try charge(metadata)
            return try .encoding(metadata)
        case "paperrss_get_content": return try await content(a)
        case "paperrss_plan_manage_feeds": return try planFeeds(a)
        case "paperrss_plan_state_change": return try plan(a)
        case "paperrss_plan_mark_read": return try planMarkRead(a)
        case "paperrss_apply_plan", "paperrss_apply_state_change": return try await apply(a)
        case "paperrss_add_feed", "paperrss_rename_feed", "paperrss_remove_feed",
             "paperrss_plan_add_feed", "paperrss_plan_rename_feed", "paperrss_plan_remove_feed":
            return try planFeed(tool.replacingOccurrences(of: "paperrss_", with: "").replacingOccurrences(of: "plan_", with: ""), a)
        default: throw AgentFailure("INVALID_ARGUMENT", "Unknown tool.")
        }
    }

    private func status(_ a: [String: AgentJSON]) throws -> AgentJSON {
        guard policy.enabled else {
            return .object(["approval_mode": .string("ask"), "version": .string("agent-spike-1"), "enabled": .bool(false),
                            "paired": .bool(false), "pair_state": .string("disabled"),
                            "transport": .string("none"), "accounts": .array([]), "pending_approvals": .number(0)])
        }
        var data: [String: AgentJSON] = [
            "approval_mode": .string("ask"), "version": .string("agent-spike-1"), "enabled": .bool(true), "paired": .bool(false),
            "pair_state": .string("app_internal"),
            "transport": .string("in_process_spike"),
            "accounts": .array(policy.accountIDs.sorted().map { .object([
                "account_id": .string($0), "capabilities": .array(
                    (["metadata.read", "content.read.selection"] + (policy.allowStateChanges ? ["state.write.approval", "feeds.manage.approval"] : [])).map { .string($0) })]) }),
            "selection_ids": .array(selections.filter { $0.value.expires > clock() }.keys.sorted().map { .string($0) }),
            "pending_approvals": .number(Double(plans.values.filter { !$0.denied && $0.approval == nil && $0.receipt == nil && $0.dto.expires_at > clock() }.count)),
            "remaining_characters": .number(Double(remainingCharacters))
        ]
        if let id = a["plan_id"]?.stringValue {
            guard let plan = plans[id] else { throw AgentFailure("NOT_FOUND", "Plan not found in this session.") }
            data["plan"] = try .encoding(plan.dto)
            data["plan_state"] = .string(plan.receipt != nil ? "committed" : plan.dto.expires_at <= clock() ? "expired" : plan.denied ? "denied" : plan.approval == nil ? "pending" : "approved")
            if plan.receipt == nil, !plan.denied, plan.dto.expires_at > clock(), let approval = plan.approval { data["approval_id"] = .string(approval) }
            if let receipt = plan.receipt { data["receipt"] = try .encoding(receipt) }
        }
        if let id = a["operation_id"]?.stringValue {
            guard let receipt = receipts.values.first(where: { $0.receipt.operation_id == id })?.receipt else {
                throw AgentFailure("NOT_FOUND", "Operation not found in this session.")
            }
            data["receipt"] = try .encoding(receipt)
        }
        return .object(data)
    }

    private func requireEnabled() throws {
        guard policy.enabled else { throw AgentFailure("NOT_ENABLED", "Local agent access is off.") }
    }
    private func authorize(_ account: String, write: Bool = false) throws {
        try requireEnabled()
        guard policy.accountIDs.contains(account) else {
            throw AgentFailure("UNAUTHORIZED", "Account is outside this session.")
        }
        try database.read { db in try checkAccount(account, write: write, in: db) }
        if write && !policy.allowStateChanges { throw AgentFailure("UNAUTHORIZED", "State changes are not enabled.") }
    }
    private func checkAccount(_ account: String, write: Bool = false, in db: Database) throws {
        guard let record = try AccountRecord.fetchOne(db, key: account), record.isEnabled, !record.isArchived,
              AccountType(rawValue: record.type) != nil else {
            throw AgentFailure("NOT_FOUND", "Enabled account not found.")
        }
        if write && writeExecutor == nil && record.type != AccountType.local.rawValue {
            throw AgentFailure("UNSUPPORTED", "Remote state changes require the App write executor.")
        }
    }
    private func string(_ a: [String: AgentJSON], _ key: String) throws -> String {
        guard let value = a[key]?.stringValue, !value.isEmpty, value.count <= 512 else {
            throw AgentFailure("INVALID_ARGUMENT", "Missing or invalid \(key).")
        }
        return value
    }
    private func integer(_ a: [String: AgentJSON], _ key: String, default fallback: Int, max: Int) throws -> Int {
        guard let raw = a[key] else { return fallback }
        guard let n = raw.intValue, (1...max).contains(n) else { throw AgentFailure("INVALID_ARGUMENT", "Invalid \(key).") }
        return n
    }
    private func ownedEntry(_ id: String, account: String, in db: Database) throws -> (Entry, Feed) {
        guard let item = try provider.articleRepository.fetchItem(id: id, in: db), item.accountID == account,
              let feedRecord = try provider.feedRepository.fetchFeed(id: item.feedID, in: db),
              feedRecord.accountID == account, !feedRecord.isDeleted,
              let feed = try provider.feedRepository.fetchFeedModel(id: item.feedID, in: db),
              let entry = try provider.articleRepository.fetchEntry(id: id, in: db) else {
            throw AgentFailure("NOT_FOUND", "Article not found in the allowed account.")
        }
        return (entry, feed)
    }
    private func inMetadataScope(_ entry: Entry, account: String) -> Bool {
        !entry.isRead || (policy.allowStarred && entry.isStarred) || selections.values.contains {
            $0.account == account && $0.expires > clock() && $0.ids.contains(entry.id)
        }
    }
    private func metadataForID(_ id: String, account: String, requireScope: Bool) throws -> AgentArticleMetadata {
        try database.read { db in
            let (entry, feed) = try ownedEntry(id, account: account, in: db)
            if requireScope && !inMetadataScope(entry, account: account) {
                throw AgentFailure("UNAUTHORIZED", "Article is outside the granted metadata scope.")
            }
            let cached = try provider.cacheRepository.fetchCacheModel(itemID: id, in: db)
            // Never return raw URLs with userinfo, query tokens or fragments. Path-secret detection remains a production gap.
            let safeURL = Self.safeSourceURL(entry.url)
            let excerpt = String(entry.summary.plainText.unicodeScalars.prefix(500))
            return AgentArticleMetadata(id: id, account_id: account, feed_id: feed.id.uuidString,
                title: String(entry.title.plainText.unicodeScalars.prefix(500)),
                authors: entry.author.map { [String($0.plainText.unicodeScalars.prefix(200))] } ?? [],
                source_url: safeURL, source_url_unavailable_reason: safeURL == nil ? "missing_or_sensitive_url" : nil,
                feed_title: String(feed.title.plainText.unicodeScalars.prefix(500)), published_at: entry.publishedAt,
                read: entry.isRead, starred: entry.isStarred,
                state_token: "\(entry.updatedAt.timeIntervalSince1970.bitPattern)-\(entry.isRead)-\(entry.isStarred)",
                excerpt: excerpt, content_available: cached != nil || !entry.sourceText.isEmpty,
                content_source: "feed_summary", retrieved_at: clock(),
                truncated: entry.summary.plainText.unicodeScalars.count > 500, untrusted: true)
        }
    }
    private static func safeSourceURL(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.absoluteString.count <= 2048 else { return nil }
        return url.absoluteString
    }
    private func outputCost(_ metadata: AgentArticleMetadata) -> Int {
        metadata.excerpt.unicodeScalars.count + metadata.title.unicodeScalars.count
            + metadata.feed_title.unicodeScalars.count + metadata.authors.joined().unicodeScalars.count
    }
    private func charge(_ metadata: AgentArticleMetadata) throws { try charge(outputCost(metadata)) }
    private func charge(_ characters: Int) throws {
        guard characters <= remainingCharacters else { throw AgentFailure("CONTENT_BUDGET_EXCEEDED", "Session output budget exhausted; App authorization is required.") }
        remainingCharacters -= characters
    }

    private func offset(_ a: [String: AgentJSON]) throws -> Int {
        guard let value = a["cursor"] else { return 0 }
        guard let key = value.stringValue, let cursor = cursors[key], cursor.expires > clock() else {
            throw AgentFailure("CONFLICT", "Cursor expired or is unknown.")
        }
        var query = a; query.removeValue(forKey: "cursor")
        guard cursor.arguments == query else { throw AgentFailure("UNAUTHORIZED", "Cursor belongs to a different query.") }
        return cursor.offset
    }
    private func nextCursor(_ a: [String: AgentJSON], offset: Int) throws -> AgentJSON {
        guard cursors.count < 60 else { throw AgentFailure("RATE_LIMITED", "Too many pagination cursors.") }
        var query = a; query.removeValue(forKey: "cursor")
        let id = UUID().uuidString
        cursors[id] = Cursor(arguments: query, offset: offset, expires: clock().addingTimeInterval(900))
        return .string(id)
    }
    private func listFeeds(_ a: [String: AgentJSON]) throws -> AgentJSON {
        let account = try string(a, "account_id")
        try authorize(account)
        let limit = try integer(a, "limit", default: 20, max: 50)
        let start = try offset(a)
        let feeds = try database.read { db in
            try provider.feedRepository.fetchAllFeedModels(accountID: account, in: db)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let counts = try provider.timelineQueryService.fetchSidebarCounts(accountID: account, startOfDayTimestamp: 0)
        let page = Array(feeds.dropFirst(start).prefix(limit))
        let titles = page.map { String($0.title.plainText.unicodeScalars.prefix(500)) }
        try charge(titles.reduce(0) { $0 + $1.unicodeScalars.count })
        return .object(["feeds": .array(zip(page, titles).map { feed, title in .object([
            "id": .string(feed.id.uuidString), "account_id": .string(account), "title": .string(title),
            "unread_count": .number(Double(counts.unreadByFeed[feed.id] ?? 0)), "untrusted": .bool(true)
        ]) }), "next_cursor": start + page.count < feeds.count ? try nextCursor(a, offset: start + page.count) : .null])
    }
    private func open(_ a: [String: AgentJSON]) async throws -> AgentJSON {
        guard Set(a.keys).isSubset(of: ["account_id", "article_id", "feed_id"]),
              (a["article_id"] != nil) != (a["feed_id"] != nil) else {
            throw AgentFailure("INVALID_ARGUMENT", "Choose exactly one article_id or feed_id.")
        }
        let account = try string(a, "account_id")
        let articleID = a["article_id"] == nil ? nil : try string(a, "article_id")
        let feedID = a["feed_id"] == nil ? nil : try string(a, "feed_id")
        guard policy.accountIDs.contains(account) else {
            throw AgentFailure("NOT_FOUND", "Enabled account not found.")
        }
        let (request, title, feedTitle): (AgentOpenRequest, String, String) = try database.read { db in
            try checkAccount(account, in: db)
            if let articleID {
                let (entry, feed) = try ownedEntry(articleID, account: account, in: db)
                return (AgentOpenRequest(accountID: account, feedID: feed.id, articleID: articleID),
                        String(entry.title.plainText.unicodeScalars.prefix(500)),
                        String(feed.title.plainText.unicodeScalars.prefix(500)))
            }
            guard let feedID, let record = try provider.feedRepository.fetchFeed(id: feedID, in: db),
                  record.accountID == account, !record.isDeleted,
                  let feed = try provider.feedRepository.fetchFeedModel(id: feedID, in: db) else {
                throw AgentFailure("NOT_FOUND", "Feed not found in the allowed account.")
            }
            let title = String(feed.title.plainText.unicodeScalars.prefix(500))
            return (AgentOpenRequest(accountID: account, feedID: feed.id), title, title)
        }
        guard let opener else { throw AgentFailure("UNSUPPORTED", "App navigation is unavailable.") }
        let cost = title.unicodeScalars.count + feedTitle.unicodeScalars.count
        try Task.checkCancellation()
        try charge(cost)
        do {
            try await MainActor.run {
                try Task.checkCancellation()
                try opener(request)
            }
        } catch { remainingCharacters += cost; throw error }
        return .object(["opened": .string(articleID == nil ? "feed" : "article"),
                        "id": .string(articleID ?? request.feedID.uuidString),
                        "title": .string(title), "feed_title": .string(feedTitle)])
    }

    private func listArticles(_ a: [String: AgentJSON]) throws -> AgentJSON {
        let account = try string(a, "account_id")
        try authorize(account)
        let scope = try string(a, "scope")
        guard ["unread", "starred", "selection"].contains(scope),
              (scope == "selection") == (a["selection_id"] != nil) else {
            throw AgentFailure("INVALID_ARGUMENT", "Use unread, starred or an explicit selection.")
        }
        if scope == "starred" && !policy.allowStarred { throw AgentFailure("UNAUTHORIZED", "Starred scope is not granted.") }
        let ids = scope == "selection" ? try selection(a, account: account).ids : nil
        let limit = try integer(a, "limit", default: 20, max: 50)
        let query = a["query"]?.stringValue ?? ""
        guard query.count <= 200 else { throw AgentFailure("INVALID_ARGUMENT", "Query is too long.") }
        let since: Date?
        if let raw = a["since"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractionalDate = raw.stringValue.flatMap { formatter.date(from: $0) }
            formatter.formatOptions = [.withInternetDateTime]
            guard let text = raw.stringValue, let date = fractionalDate ?? formatter.date(from: text) else {
                throw AgentFailure("INVALID_ARGUMENT", "since must be an ISO8601 timestamp.")
            }
            since = date
        } else { since = nil }
        var position = try offset(a)
        // Reuse the existing bounded timeline projection. Cap work per call and continue scanning via cursor.
        let rows = try provider.timelineQueryService.fetchListItems(accountID: account,
            scope: scope == "unread" ? .unread : scope == "starred" ? .starred : .all, limit: 500, offset: position)
        var result: [AgentArticleMetadata] = []
        for row in rows {
            position += 1
            guard ids == nil || ids!.contains(row.id),
                  a["feed_id"] == nil || a["feed_id"]?.stringValue == row.feedID.uuidString,
                  since == nil || (row.publishedAt.map { $0 >= since! } ?? false) else { continue }
            // Search only the same bounded metadata exposed to the caller, never content_html/cache.
            let metadata = try metadataForID(row.id, account: account, requireScope: true)
            guard query.isEmpty || metadata.title.localizedCaseInsensitiveContains(query) || metadata.excerpt.localizedCaseInsensitiveContains(query) else { continue }
            result.append(metadata)
            if result.count == limit { break }
        }
        let hasMore = position < (try offset(a)) + rows.count || rows.count == 500
        let response: AgentJSON = .object(["articles": try .encoding(result), "next_cursor": hasMore ? try nextCursor(a, offset: position) : .null,
                        "pagination": .string("live_offset"), "snapshot_at": try .encoding(clock())])
        try charge(result.reduce(0) { $0 + outputCost($1) })
        return response
    }
    private func selection(_ a: [String: AgentJSON], account: String) throws -> Selection {
        let id = try string(a, "selection_id")
        guard let selection = selections[id], selection.account == account, selection.expires > clock() else {
            throw AgentFailure("UNAUTHORIZED", "Selection is missing or expired.")
        }
        return selection
    }
    private func content(_ a: [String: AgentJSON]) async throws -> AgentJSON {
        let account = try string(a, "account_id")
        let id = try string(a, "article_id")
        try authorize(account)
        guard try selection(a, account: account).ids.contains(id) else { throw AgentFailure("UNAUTHORIZED", "Article is not in the approved selection.") }
        let limit = try integer(a, "max_chars", default: 8000, max: 20_000)
        let (entry, feed, cache) = try database.read { db in
            let (entry, feed) = try ownedEntry(id, account: account, in: db)
            return (entry, feed, try provider.cacheRepository.fetchCacheModel(itemID: id, in: db))
        }
        let result = await engine.prepare(entry: entry, cached: cache, feed: feed, policy: .storedContent)
        try Task.checkCancellation()
        try authorize(account) // Revalidate after suspension: revoke/expiry must win over in-flight reads.
        guard try selection(a, account: account).ids.contains(id) else { throw AgentFailure("UNAUTHORIZED", "Selection was revoked.") }
        let metadata = try metadataForID(id, account: account, requireScope: true)
        let text = String(result.prepared.text.unicodeScalars.prefix(limit))
        try charge(outputCost(metadata) + text.unicodeScalars.count)
        return .object(["article": try .encoding(metadata), "text": .string(text), "untrusted": .bool(true),
            "content_source": .string(result.prepared.source == .cache ? "web_cache" : result.prepared.source == .fallback ? "unavailable" : "feed"),
            "truncated": .bool(result.prepared.text.unicodeScalars.count > limit), "remaining_characters": .number(Double(remainingCharacters))])
    }
    private func plan(_ a: [String: AgentJSON]) throws -> AgentJSON {
        let account = try string(a, "account_id")
        try authorize(account, write: true)
        guard let raw = a["article_ids"]?.arrayValue, (1...50).contains(raw.count),
              raw.allSatisfy({ $0.stringValue != nil }),
              let field = AgentStateField(rawValue: try string(a, "field")), let value = a["value"]?.boolValue else {
            throw AgentFailure("INVALID_ARGUMENT", "Use 1–50 article IDs and an explicit read/starred value.")
        }
        let ids = raw.compactMap(\.stringValue)
        guard Set(ids).count == ids.count, plans.count < 100 else { throw AgentFailure("INVALID_ARGUMENT", "Duplicate IDs or too many pending plans.") }
        let before = try database.read { db in
            try checkAccount(account, write: true, in: db)
            return try Dictionary(uniqueKeysWithValues: ids.map { id in
                let (entry, _) = try ownedEntry(id, account: account, in: db)
                guard inMetadataScope(entry, account: account) else { throw AgentFailure("UNAUTHORIZED", "Article is outside the granted scope.") }
                guard let state = try provider.stateRepository.fetchState(itemID: id, in: db) else { throw AgentFailure("CONFLICT", "Article state is missing.") }
                return (id, state)
            })
        }
        let action = field == .read ? (value ? "标为已读" : "标为未读") : (value ? "加入收藏" : "取消收藏")
        let englishAction = field == .read ? (value ? "Mark as read" : "Mark as unread") : (value ? "Star" : "Unstar")
        return try storePlan(account: account, ids: ids, field: field, value: value, before: before,
                             kind: "state_change", summary: "将 \(ids.count) 篇文章\(action)",
                             summaryEnglish: "\(englishAction): \(ids.count) articles")
    }

    private func storePlan(account: String, ids: [String], field: AgentStateField, value: Bool,
                           before: [String: ArticleStateRecord], kind: String, summary: String, summaryEnglish: String, feedID: String? = nil) throws -> AgentJSON {
        guard plans.count < 100 else { throw AgentFailure("RATE_LIMITED", "Session plan capacity reached.") }
        let titles = try database.read { db in
            try ids.prefix(5).map { String(try ownedEntry($0, account: account, in: db).0.title.plainText.prefix(200)) }
        }
        let feeds: [AgentFeedPreview] = try database.read { db in
            if let feedID, let feed = try provider.feedRepository.fetchFeed(id: feedID, in: db),
               feed.accountID == account, !feed.isDeleted {
                return [AgentFeedPreview(id: feed.id, title: String(feed.title.plainText.prefix(200)))]
            }
            guard !ids.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT f.id, f.title FROM feeds f JOIN items i ON i.feed_id = f.id
                WHERE f.account_id = ? AND i.account_id = ? AND f.is_deleted = 0
                AND i.id IN (\(placeholders)) ORDER BY f.id LIMIT 12
                """, arguments: StatementArguments([account, account] + ids))
            return rows.map { AgentFeedPreview(id: $0["id"], title: String(($0["title"] as String).plainText.prefix(200))) }
        }
        let titleCharacters: Int = titles.reduce(0) { $0 + $1.count }
        let feedCharacters: Int = feeds.reduce(0) { $0 + $1.id.count + $1.title.count }
        try charge(summary.count + summaryEnglish.count + titleCharacters + feedCharacters)
        var dto = AgentStatePlan(plan_id: UUID().uuidString, account_id: account, article_ids: ids,
            field: field, value: value, expires_at: clock().addingTimeInterval(900),
            retention_notice: "Marking read or removing a star may make articles eligible for retention cleanup. Changes to synced accounts are queued for sync. No undo is provided.",
            action_kind: kind, summary: summary, summary_en: summaryEnglish, affected_count: ids.count, sample_titles: titles,
            approval: "pending", next_step: "PaperRss applies according to approval_mode. If pending, ask the user to approve in PaperRss; App applies immediately. Poll paperrss_status with plan_id for committed and receipt, or denied/expired. Only retry paperrss_apply_plan if status stays approved without receipt; never invent approval_id.")
        dto.affected_feeds = feeds
        plans[dto.plan_id] = PendingPlan(dto: dto, before: before)
        return try .encoding(dto)
    }

    private func validateFeedMutation(_ mutation: AgentFeedMutation) throws {
        try authorize(mutation.accountID, write: true)
        try database.read { db in
            if let raw = mutation.url {
                guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                      raw.count <= 2048 else {
                    throw AgentFailure("INVALID_ARGUMENT", "Feed URL must be HTTP(S) without credentials.")
                }
                let feeds = try provider.feedRepository.fetchAllFeedModels(accountID: mutation.accountID, in: db)
                guard !feeds.contains(where: { $0.feedURL == url }) else {
                    throw AgentFailure("CONFLICT", "Already subscribed to this feed in the account.")
                }
            }
            if let id = mutation.feedID {
                guard UUID(uuidString: id) != nil, let feed = try provider.feedRepository.fetchFeed(id: id, in: db),
                      feed.accountID == mutation.accountID, !feed.isDeleted else {
                    throw AgentFailure("NOT_FOUND", "Feed not found in the allowed account.")
                }
            }
        }
    }

    private func planFeed(_ kind: String, _ a: [String: AgentJSON]) throws -> AgentJSON {
        let pending = try makeFeedPlan(kind, a)
        plans[pending.dto.plan_id] = pending
        return try .encoding(pending.dto)
    }

    private func planFeeds(_ a: [String: AgentJSON]) throws -> AgentJSON {
        guard Set(a.keys) == ["account_id", "operations"],
              let operations = a["operations"]?.arrayValue, (1...50).contains(operations.count) else {
            throw AgentFailure("INVALID_ARGUMENT", "Supply 1–50 operations in one account.")
        }
        let account = try string(a, "account_id")
        try authorize(account, write: true)
        var seen = Set<String>()
        let parts = try operations.map { operation -> PendingPlan in
            guard var arguments = operation.objectValue,
                  let action = arguments.removeValue(forKey: "action")?.stringValue,
                  ["add_feed", "rename_feed", "remove_feed"].contains(action) else {
                throw AgentFailure("INVALID_ARGUMENT", "Invalid feed operation.")
            }
            guard arguments["account_id"] == nil else { throw AgentFailure("INVALID_ARGUMENT", "Use the batch account_id.") }
            arguments["account_id"] = .string(account)
            let part = try makeFeedPlan(action, arguments)
            let mutation = part.mutation!
            let identity = mutation.feedID.map { "id:" + $0.lowercased() } ?? "url:" + mutation.url!
            guard seen.insert(identity).inserted else {
                throw AgentFailure("INVALID_ARGUMENT", "Each feed or URL may appear only once in a batch.")
            }
            return part
        }
        let removes = parts.contains { $0.dto.destructive_hint }
        var dto = AgentStatePlan(plan_id: UUID().uuidString, account_id: account, article_ids: [], field: .read, value: false,
            expires_at: clock().addingTimeInterval(900), retention_notice: removes
                ? "Permanently deletes selected feed history including starred articles. No undo. Batch execution is not atomic."
                : "Changes subscriptions in this account. Batch execution is not atomic; check per-item results.",
            action_kind: "manage_feeds", summary: "管理 \(parts.count) 个订阅", summary_en: "Manage \(parts.count) feeds",
            affected_count: parts.reduce(0) { $0 + $1.dto.affected_count }, sample_titles: [], approval: "pending",
            next_step: parts[0].dto.next_step)
        dto.affected_feeds = parts.flatMap { $0.dto.affected_feeds }
        dto.destructive_hint = removes
        dto.feed_changes = parts.map { part in
            let title = part.dto.affected_feeds.first?.title
            let label = part.mutation!.kind == "remove_feed" ? "删除" : "重命名"
            let english = part.mutation!.kind == "remove_feed" ? "Remove" : "Rename"
            return AgentFeedChangePreview(summary: (title.map { "\(label) “\($0)” · " } ?? "") + part.dto.summary,
                summary_en: (title.map { "\(english) \"\($0)\" · " } ?? "") + part.dto.summary_en)
        }
        plans[dto.plan_id] = PendingPlan(dto: dto, before: [:], mutations: parts.compactMap(\.mutation))
        return try .encoding(dto)
    }

    private func makeFeedPlan(_ kind: String, _ a: [String: AgentJSON]) throws -> PendingPlan {
        let allowed: Set<String> = kind == "add_feed" ? ["account_id", "url", "title", "folder"]
            : kind == "rename_feed" ? ["account_id", "feed_id", "title"] : ["account_id", "feed_id"]
        guard Set(a.keys).isSubset(of: allowed) else { throw AgentFailure("INVALID_ARGUMENT", "Unexpected feed plan arguments.") }
        let account = try string(a, "account_id")
        func optionalText(_ key: String) throws -> String? {
            guard let value = a[key] else { return nil }
            guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.unicodeScalars.count <= 200 else { throw AgentFailure("INVALID_ARGUMENT", "Invalid \(key); use 1–200 characters.") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = try optionalText("title"), folder = try optionalText("folder")
        if kind == "rename_feed", title == nil { throw AgentFailure("INVALID_ARGUMENT", "title is required.") }
        let rawURL: String?
        if kind == "add_feed" {
            guard let text = a["url"]?.stringValue, !text.isEmpty else { throw AgentFailure("INVALID_ARGUMENT", "url is required.") }
            rawURL = text
        } else { rawURL = nil }
        let mutation = AgentFeedMutation(kind: kind, accountID: account,
            feedID: kind == "add_feed" ? nil : try string(a, "feed_id"), url: rawURL, title: title, folder: folder)
        try validateFeedMutation(mutation)
        let (summary, english, count): (String, String, Int) = try database.read { db in
            let record = try AccountRecord.fetchOne(db, key: account)!
            var label = record.type == "freshRSS" ? "FreshRSS" : record.type == "miniflux" ? "Miniflux" : record.type == "iCloud" ? "iCloud" : "Local"
            if ["freshRSS", "miniflux"].contains(record.type), let endpoint = record.endpointURL,
               let components = URLComponents(string: endpoint), let host = components.host,
               !host.contains("@"), !host.contains("%") {
                label += "（" + host + "）"
            }
            if kind == "add_feed" {
                let safe = Self.safeSourceURL(URL(string: rawURL!)) ?? "HTTP(S) feed (URL redacted)"
                let details = (title.map { " · " + $0 } ?? "") + (folder.map { " · folder: " + $0 } ?? "")
                return ("在 \(label) 中添加订阅 \(safe)\(details)", "Add subscription \(safe) in \(label)\(details)", 0)
            }
            let feed = try provider.feedRepository.fetchFeed(id: mutation.feedID!, in: db)!
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE account_id = ? AND feed_id = ?", arguments: [account, feed.id]) ?? 0
            let starred = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items i JOIN article_states s ON s.item_id = i.id WHERE i.account_id = ? AND i.feed_id = ? AND s.is_starred = 1", arguments: [account, feed.id]) ?? 0
            if kind == "remove_feed" {
                return ("同时移除订阅历史，含 \(starred) 篇收藏。",
                        "Also removes subscription history, including \(starred) starred articles.", total)
            }
            return ("重命名为 “\(title!)”", "Rename to \"\(title!)\"", 0)
        }
        guard plans.count < 100 else { throw AgentFailure("RATE_LIMITED", "Session plan capacity reached.") }
        let feeds: [AgentFeedPreview] = try database.read { db in
            guard let id = mutation.feedID,
                  let feed = try provider.feedRepository.fetchFeed(id: id, in: db) else { return [] }
            return [AgentFeedPreview(id: feed.id, title: String(feed.title.plainText.prefix(200)))]
        }
        try charge(summary.count + english.count + feeds.reduce(0) { $0 + $1.id.count + $1.title.count })
        var dto = AgentStatePlan(plan_id: UUID().uuidString, account_id: account, article_ids: [], field: .read, value: false,
            expires_at: clock().addingTimeInterval(900), retention_notice: kind == "remove_feed" ? "Permanently deletes feed history including starred articles. No undo." : "Changes the subscription in the selected account.",
            action_kind: kind, summary: summary, summary_en: english, affected_count: count, sample_titles: [], approval: "pending",
            next_step: "PaperRss applies according to approval_mode. If pending, ask the user to approve in PaperRss; App applies immediately. Poll paperrss_status with plan_id for committed and receipt, or denied/expired. Only retry paperrss_apply_plan if status stays approved without receipt; never invent approval_id.")
        dto.affected_feeds = feeds
        dto.destructive_hint = kind == "remove_feed"
        return PendingPlan(dto: dto, before: [:], mutation: mutation)
    }

    private func planMarkRead(_ a: [String: AgentJSON]) throws -> AgentJSON {
        let account = try string(a, "account_id"), scope = try string(a, "scope")
        try authorize(account, write: true)
        guard ["feed", "folder", "account"].contains(scope),
              (scope == "feed") == (a["feed_id"] != nil),
              (scope == "folder") == (a["folder"] != nil) else {
            throw AgentFailure("INVALID_ARGUMENT", "Choose feed, folder or account with only its matching identifier.")
        }
        var beforeDate: Date?
        if let raw = a["before"] {
            let formatter = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
            guard let text = raw.stringValue, let date = formatter.date(from: text) ?? fractional.date(from: text) else {
                throw AgentFailure("INVALID_ARGUMENT", "before must be an ISO8601 instant.")
            }
            beforeDate = date
        }
        let (ids, states, label, englishLabel): ([String], [String: ArticleStateRecord], String, String) = try database.read { db in
            var predicate = "", arguments: [DatabaseValueConvertible] = [account]
            var label = "账号", englishLabel = "account"
            if scope == "feed" {
                let id = try string(a, "feed_id")
                guard let feed = try provider.feedRepository.fetchFeed(id: id, in: db), feed.accountID == account, !feed.isDeleted else {
                    throw AgentFailure("NOT_FOUND", "Feed not found in account.")
                }
                predicate = " AND i.feed_id = ?"; arguments.append(id)
                label = "此订阅源"
                englishLabel = "this feed"
            } else if scope == "folder" {
                let value = try string(a, "folder")
                let folders = try FolderRecord.fetchAll(db, sql: "SELECT * FROM folders WHERE account_id = ? AND is_deleted = 0 AND (id = ? OR name = ?)", arguments: [account, value, value])
                guard folders.count == 1, let folder = folders.first else {
                    throw AgentFailure("INVALID_ARGUMENT", "Folder is missing or ambiguous; use its ID.")
                }
                predicate = " AND EXISTS (SELECT 1 FROM feed_folders ff WHERE ff.feed_id = i.feed_id AND ff.folder_id = ?)"; arguments.append(folder.id)
                label = "“\(String(folder.name.plainText.prefix(200)))” 文件夹"
                englishLabel = "folder \"\(String(folder.name.plainText.prefix(200)))\""
            }
            if let beforeDate { predicate += " AND COALESCE(a.published_at, s.date_arrived) < ?"; arguments.append(beforeDate.timeIntervalSince1970) }
            let ids = try String.fetchAll(db, sql: """
                SELECT i.id FROM items i JOIN articles a ON a.item_id = i.id
                JOIN article_states s ON s.item_id = i.id JOIN feeds f ON f.id = i.feed_id
                WHERE i.account_id = ? AND f.account_id = i.account_id AND f.is_deleted = 0 AND s.is_read = 0
                \(predicate) ORDER BY i.id LIMIT 5001
                """, arguments: StatementArguments(arguments))
            guard ids.count <= 5000 else { throw AgentFailure("INVALID_ARGUMENT", "More than 5000 unread articles; narrow the scope with before.") }
            let states = try Dictionary(uniqueKeysWithValues: ids.map { id in
                guard let state = try provider.stateRepository.fetchState(itemID: id, in: db) else { throw AgentFailure("CONFLICT", "Article state missing.") }
                return (id, state)
            })
            return (ids, states, label, englishLabel)
        }
        return try storePlan(account: account, ids: ids, field: .read, value: true, before: states,
                             kind: "mark_read", summary: "将 \(label)的 \(ids.count) 篇未读标为已读",
                             summaryEnglish: "Mark \(ids.count) unread articles in \(englishLabel) as read",
                             feedID: scope == "feed" ? a["feed_id"]?.stringValue : nil)
    }
    private func apply(_ a: [String: AgentJSON]) async throws -> AgentJSON {
        guard !applying else { throw AgentFailure("CONFLICT", "Another write is executing; retry shortly.") }
        let id = try string(a, "plan_id"), approval = try string(a, "approval_id"), key = try string(a, "idempotency_key")
        guard key.count <= 128 else { throw AgentFailure("INVALID_ARGUMENT", "Idempotency key is too long.") }
        if let replay = receipts[key] {
            guard replay.plan == id, replay.approval == approval else { throw AgentFailure("CONFLICT", "Idempotency key was used for another command.") }
            guard let plan = plans[id] else { throw AgentFailure("CONFLICT", "Session plan is unavailable.") }
            try authorize(plan.dto.account_id, write: true)
            return try .encoding(replay.receipt)
        }
        guard var pending = plans[id] else { throw AgentFailure("CONFLICT", "Plan is unknown.") }
        try authorize(pending.dto.account_id, write: true)
        guard !pending.denied else { throw AgentFailure("DENIED", "Plan was denied.") }
        guard pending.approval == approval else { throw AgentFailure("CONFIRMATION_REQUIRED", "Approve this exact plan in PaperRss first.") }
        if let receipt = pending.receipt {
            guard receipts.count < 256 else { throw AgentFailure("RATE_LIMITED", "Session receipt capacity reached.") }
            receipts[key] = Replay(plan: id, approval: approval, receipt: receipt)
            return try .encoding(receipt)
        }
        guard pending.dto.expires_at > clock() else { throw AgentFailure("CONFLICT", "Plan expired.") }
        guard receipts.count < 256 else { throw AgentFailure("RATE_LIMITED", "Session receipt capacity reached.") }
        try Task.checkCancellation()
        let dto = pending.dto
        applying = true
        defer { applying = false }
        func validate(_ db: Database) throws -> [String] {
            try Task.checkCancellation()
            guard dto.expires_at > clock() else { throw AgentFailure("CONFLICT", "Plan expired before execution.") }
            try checkAccount(dto.account_id, write: true, in: db)
            return try dto.article_ids.filter { articleID in
                _ = try ownedEntry(articleID, account: dto.account_id, in: db)
                guard let current = try provider.stateRepository.fetchState(itemID: articleID, in: db) else {
                    throw AgentFailure("CONFLICT", "Article state missing.")
                }
                return (dto.field == .read ? current.isRead : current.isStarred) != dto.value
            }
        }
        if let mutations = pending.mutations {
            var results: [AgentFeedOperationResult] = []
            for (index, mutation) in mutations.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard dto.expires_at > clock() else { throw AgentFailure("CONFLICT", "Plan expired.") }
                    try validateFeedMutation(mutation)
                    let result = try await executeFeed(mutation, expiresAt: dto.expires_at)
                    results.append(AgentFeedOperationResult(index: index, action: mutation.kind,
                        feed_id: result.feedID, feed_title: result.title.map { String($0.plainText.prefix(200)) },
                        status: "applied", error_code: nil, sync: result.sync))
                } catch {
                    // Do not serialize arbitrary provider errors, URLs or credentials.
                    let known = ["INVALID_ARGUMENT", "CONFLICT", "NOT_FOUND", "UNAUTHORIZED", "NOT_ENABLED", "UNSUPPORTED"]
                    let code = (error as? AgentFailure)?.code ?? "INTERNAL_ERROR"
                    results.append(AgentFeedOperationResult(index: index, action: mutation.kind,
                        feed_id: mutation.feedID, feed_title: nil, status: "failed",
                        error_code: error is CancellationError ? "CANCELLED" : known.contains(code) ? code : "INTERNAL_ERROR", sync: nil))
                }
            }
            let failed = results.filter { $0.status == "failed" }.count
            let syncs = Set(results.compactMap(\.sync))
            var receipt = AgentStateReceipt(operation_id: UUID().uuidString,
                applied_count: results.count - failed, skipped_count: 0,
                local_commit: failed == 0 ? "committed" : failed == results.count ? "failed" : "partial",
                sync: syncs.count == 1 ? syncs.first! : syncs.isEmpty ? "none" : "mixed")
            receipt.results = results
            receipt.failed_count = failed
            guard policy.enabled, plans[id] != nil else { throw AgentFailure("NOT_ENABLED", "Session was revoked during execution.") }
            pending.receipt = receipt; plans[id] = pending
            receipts[key] = Replay(plan: id, approval: approval, receipt: receipt)
            return try .encoding(receipt)
        }
        if let mutation = pending.mutation {
            try validateFeedMutation(mutation)
            let result = try await executeFeed(mutation, expiresAt: dto.expires_at)
            var receipt = AgentStateReceipt(operation_id: UUID().uuidString, applied_count: 1, skipped_count: 0, local_commit: "committed", sync: result.sync)
            receipt.feed_id = result.feedID
            receipt.feed_title = result.title.map { String($0.plainText.prefix(200)) }
            guard policy.enabled, plans[id] != nil else { throw AgentFailure("NOT_ENABLED", "Session was revoked during execution.") }
            pending.receipt = receipt; plans[id] = pending
            receipts[key] = Replay(plan: id, approval: approval, receipt: receipt)
            return try .encoding(receipt)
        }
        let result: AgentWriteResult
        if let writeExecutor {
            _ = try database.read { try validate($0) }
            result = try await writeExecutor.execute(accountID: dto.account_id, articleIDs: dto.article_ids, field: dto.field, value: dto.value, expiresAt: dto.expires_at)
        } else {
            let appliedIDs = try database.write { db in
                let ids = try validate(db)
                for articleID in ids {
                    switch dto.field {
                    case .read: try provider.stateRepository.markRead(itemID: articleID, isRead: dto.value, in: db)
                    case .starred: try provider.stateRepository.markStarred(itemID: articleID, isStarred: dto.value, in: db)
                    }
                }
                return ids
            }
            result = AgentWriteResult(appliedCount: appliedIDs.count, skippedCount: dto.article_ids.count - appliedIDs.count, sync: "local_only")
        }
        let receipt = AgentStateReceipt(operation_id: UUID().uuidString, applied_count: result.appliedCount, skipped_count: result.skippedCount,
                                        local_commit: "committed", sync: result.sync)
        // A disconnect/toggle-off may revoke the actor while the App executor is awaited.
        guard policy.enabled, plans[id] != nil else { throw AgentFailure("NOT_ENABLED", "Session was revoked during execution.") }
        pending.receipt = receipt
        plans[id] = pending
        receipts[key] = Replay(plan: id, approval: approval, receipt: receipt)
        return try .encoding(receipt)
    }
    private func executeFeed(_ mutation: AgentFeedMutation, expiresAt: Date) async throws -> AgentFeedWriteResult {
        if let writeExecutor {
            return try await writeExecutor.executeFeed(mutation, expiresAt: expiresAt)
        } else {
            // Only isolated local storage is allowed without the App executor.
            let local = LocalAccountProvider(accountID: mutation.accountID, database: database)
            switch mutation.kind {
            case "add_feed":
                let feed = try local.addFeed(title: mutation.title ?? URL(string: mutation.url!)!.host!, feedURL: URL(string: mutation.url!)!, folder: mutation.folder)
                return AgentFeedWriteResult(feedID: feed.id.uuidString, title: feed.title, sync: "local_only")
            case "rename_feed":
                try await local.renameFeed(feedID: UUID(uuidString: mutation.feedID!)!, newTitle: mutation.title!)
                return AgentFeedWriteResult(feedID: mutation.feedID, title: mutation.title, sync: "local_only")
            default:
                try await local.deleteFeed(feedID: UUID(uuidString: mutation.feedID!)!)
                return AgentFeedWriteResult(feedID: mutation.feedID, title: nil, sync: "local_only")
            }
        }
    }
}
