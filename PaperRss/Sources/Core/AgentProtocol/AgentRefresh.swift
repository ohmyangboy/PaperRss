import Foundation

/// One MCP refresh request after the session has checked the account and feeds.
public struct AgentRefreshRequest: Sendable, Equatable {
    public var scope: String
    public var accountID: String?
    public var feedIDs: [String]
    public var feedCount: Int
    public var idempotencyKey: String?

    public init(scope: String, accountID: String? = nil, feedIDs: [String] = [], feedCount: Int, idempotencyKey: String? = nil) {
        self.scope = scope
        self.accountID = accountID
        self.feedIDs = feedIDs
        self.feedCount = feedCount
        self.idempotencyKey = idempotencyKey
    }

    public var target: AgentRefreshTarget {
        AgentRefreshTarget(scope: scope, accountID: accountID, feedIDs: feedIDs.sorted())
    }
}

public struct AgentRefreshTarget: Sendable, Equatable {
    public var scope: String
    public var accountID: String?
    public var feedIDs: [String]

    public init(scope: String, accountID: String?, feedIDs: [String]) {
        self.scope = scope
        self.accountID = accountID
        self.feedIDs = feedIDs
    }
}

/// Feed-level failure safe to return to an MCP client. No publisher title or response body.
public struct AgentRefreshFailure: Sendable, Equatable {
    public var accountID: String?
    public var feedID: String?
    public var code: String

    public init(accountID: String? = nil, feedID: String? = nil, code: String) {
        self.accountID = accountID
        self.feedID = feedID
        self.code = code
    }
}

/// Counts collected from the existing refresh path.
public struct AgentRefreshDetail: Sendable, Equatable {
    public var state: String
    public var updatedFeedCount: Int
    public var notModifiedCount: Int
    public var failedFeedCount: Int
    public var skippedCount: Int
    public var newArticleIDs: [String]
    public var failures: [AgentRefreshFailure]
    public var subscriptionsSynced: Bool

    public init(state: String = "completed", updatedFeedCount: Int = 0, notModifiedCount: Int = 0,
                failedFeedCount: Int = 0, skippedCount: Int = 0, newArticleIDs: [String] = [],
                failures: [AgentRefreshFailure] = [], subscriptionsSynced: Bool = false) {
        self.state = state
        self.updatedFeedCount = updatedFeedCount
        self.notModifiedCount = notModifiedCount
        self.failedFeedCount = failedFeedCount
        self.skippedCount = skippedCount
        self.newArticleIDs = newArticleIDs
        self.failures = failures
        self.subscriptionsSynced = subscriptionsSynced
    }

    public func resolved() -> AgentRefreshDetail {
        var copy = self
        if failedFeedCount == 0 {
            copy.state = "completed"
        } else if updatedFeedCount + notModifiedCount + skippedCount + newArticleIDs.count > 0 || subscriptionsSynced {
            copy.state = "partial"
        } else {
            copy.state = "failed"
        }
        return copy
    }
}

public struct AgentRefreshSnapshot: Sendable, Equatable {
    public var operationID: String
    public var state: String
    public var scope: String
    public var accountID: String?
    public var feedCount: Int
    public var joined: Bool
    public var updatedFeedCount: Int
    public var notModifiedCount: Int
    public var failedFeedCount: Int
    public var skippedCount: Int
    public var newUnreadCount: Int
    public var newArticleIDs: [String]
    public var truncated: Bool
    public var subscriptionsSynced: Bool
    public var failures: [AgentRefreshFailure]
    public var idempotencyKey: String?

    public init(operationID: String, state: String, scope: String, accountID: String?, feedCount: Int, joined: Bool,
                updatedFeedCount: Int = 0, notModifiedCount: Int = 0, failedFeedCount: Int = 0, skippedCount: Int = 0,
                newUnreadCount: Int = 0, newArticleIDs: [String] = [], truncated: Bool = false,
                subscriptionsSynced: Bool = false, failures: [AgentRefreshFailure] = [], idempotencyKey: String? = nil) {
        self.operationID = operationID
        self.state = state
        self.scope = scope
        self.accountID = accountID
        self.feedCount = feedCount
        self.joined = joined
        self.updatedFeedCount = updatedFeedCount
        self.notModifiedCount = notModifiedCount
        self.failedFeedCount = failedFeedCount
        self.skippedCount = skippedCount
        self.newUnreadCount = newUnreadCount
        self.newArticleIDs = newArticleIDs
        self.truncated = truncated
        self.subscriptionsSynced = subscriptionsSynced
        self.failures = failures
        self.idempotencyKey = idempotencyKey
    }

    /// Running responses stay small. Finished responses add counts and article IDs only.
    public func fields() -> [String: AgentJSON] {
        var object: [String: AgentJSON] = [
            "operation_id": .string(operationID),
            "state": .string(state),
            "scope": .string(scope),
            "feed_count": .number(Double(feedCount)),
            "joined": .bool(joined)
        ]
        if let accountID { object["account_id"] = .string(accountID) }
        guard state != "running" else { return object }
        object["updated_feed_count"] = .number(Double(updatedFeedCount))
        object["not_modified_count"] = .number(Double(notModifiedCount))
        object["failed_feed_count"] = .number(Double(failedFeedCount))
        object["skipped_count"] = .number(Double(skippedCount))
        object["new_unread_count"] = .number(Double(newUnreadCount))
        object["new_article_ids"] = .array(newArticleIDs.map(AgentJSON.string))
        object["truncated"] = .bool(truncated)
        object["subscriptions_synced"] = .bool(subscriptionsSynced)
        object["failures"] = .array(failures.map { failure in
            var item: [String: AgentJSON] = ["code": .string(failure.code)]
            if let accountID = failure.accountID, !accountID.isEmpty { item["account_id"] = .string(accountID) }
            if let feedID = failure.feedID { item["feed_id"] = .string(feedID) }
            return .object(item)
        })
        return object
    }
}

public enum AgentRefreshAdmission: Equatable, Sendable {
    case start(AgentRefreshSnapshot)
    case joined(AgentRefreshSnapshot)
    case replay(AgentRefreshSnapshot)
    case busy(AgentRefreshSnapshot)
    case conflict
}

/// Process-wide refresh admissions. One refresh runs at a time. Identical targets join or replay for 30 seconds.
public struct AgentRefreshBoard: Equatable, Sendable {
    public static let replayInterval: TimeInterval = 30
    public static let retention: TimeInterval = 900
    public static let finishedLimit = 20
    public static let articleIDLimit = 50

    private struct Record: Equatable {
        var snapshot: AgentRefreshSnapshot
        var target: AgentRefreshTarget
        var finishedAt: Date?
    }

    private var records: [String: Record] = [:]
    private var order: [String] = []

    public init() {}

    public var isRunning: Bool { records.values.contains { $0.snapshot.state == "running" } }

    public mutating func admit(request: AgentRefreshRequest, now: Date, makeID: () -> String = { "refresh-\(UUID().uuidString)" }) -> AgentRefreshAdmission {
        prune(now: now)
        let target = request.target
        if let key = request.idempotencyKey {
            let matches = records.values.filter { $0.snapshot.idempotencyKey == key }
            if let record = matches.first(where: { record in
                record.snapshot.state == "running"
                    || record.finishedAt.map { now.timeIntervalSince($0) < Self.replayInterval } == true
            }) {
                guard record.target == target else { return .conflict }
                return record.snapshot.state == "running" ? .joined(joining(record.snapshot)) : .replay(record.snapshot)
            }
        }
        if let running = records.values.first(where: { $0.snapshot.state == "running" }) {
            return running.target == target ? .joined(joining(running.snapshot)) : .busy(running.snapshot)
        }
        if let recent = order.reversed().compactMap({ records[$0] }).first(where: {
            $0.target == target && $0.finishedAt.map { now.timeIntervalSince($0) < Self.replayInterval } == true
        }) {
            return .replay(recent.snapshot)
        }
        let snapshot = AgentRefreshSnapshot(operationID: makeID(), state: "running", scope: request.scope,
            accountID: request.accountID, feedCount: request.feedCount, joined: false, idempotencyKey: request.idempotencyKey)
        records[snapshot.operationID] = Record(snapshot: snapshot, target: target, finishedAt: nil)
        order.append(snapshot.operationID)
        return .start(snapshot)
    }

    public mutating func finish(operationID: String, detail: AgentRefreshDetail, now: Date) {
        guard var record = records[operationID], record.snapshot.state == "running" else { return }
        let resolved = detail.resolved()
        record.snapshot.state = resolved.state
        record.snapshot.updatedFeedCount = resolved.updatedFeedCount
        record.snapshot.notModifiedCount = resolved.notModifiedCount
        record.snapshot.failedFeedCount = resolved.failedFeedCount
        record.snapshot.skippedCount = resolved.skippedCount
        record.snapshot.newUnreadCount = resolved.newArticleIDs.count
        record.snapshot.truncated = resolved.newArticleIDs.count > Self.articleIDLimit
        record.snapshot.newArticleIDs = Array(resolved.newArticleIDs.prefix(Self.articleIDLimit))
        record.snapshot.subscriptionsSynced = resolved.subscriptionsSynced
        record.snapshot.failures = resolved.failures
        record.finishedAt = now
        records[operationID] = record
        prune(now: now)
    }

    public mutating func snapshot(operationID: String, now: Date) -> AgentRefreshSnapshot? {
        prune(now: now)
        return records[operationID]?.snapshot
    }

    private func joining(_ snapshot: AgentRefreshSnapshot) -> AgentRefreshSnapshot {
        var copy = snapshot
        copy.joined = true
        return copy
    }

    private mutating func prune(now: Date) {
        let expired = records.compactMap { id, record -> String? in
            guard let finishedAt = record.finishedAt, now.timeIntervalSince(finishedAt) >= Self.retention else { return nil }
            return id
        }
        for id in expired {
            records.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
        let finished = order.filter { records[$0]?.finishedAt != nil }
        if finished.count > Self.finishedLimit {
            for id in finished.prefix(finished.count - Self.finishedLimit) {
                records.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
        }
    }
}
