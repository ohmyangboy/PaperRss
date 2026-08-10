import Foundation

public struct FeedNotificationSummary: Equatable, Sendable {
    public let newUnreadCount: Int
    public let visibleSourceNames: [String]
    public let remainingSourceCount: Int

    public init(newUnreadCount: Int, visibleSourceNames: [String], remainingSourceCount: Int) {
        self.newUnreadCount = newUnreadCount
        self.visibleSourceNames = visibleSourceNames
        self.remainingSourceCount = remainingSourceCount
    }
}

public enum FeedAttentionPolicy {
    public static func dockBadgeLabel(unreadCount: Int, enabled: Bool) -> String? {
        guard enabled, unreadCount > 0 else { return nil }
        return unreadCount > 99 ? "99+" : String(unreadCount)
    }

    public static func notificationSummary(
        outcome: FeedRefreshOutcome,
        feedTitles: [UUID: String],
        enabled: Bool,
        appIsActive: Bool
    ) -> FeedNotificationSummary? {
        guard enabled,
              !appIsActive,
              outcome.origin == .scheduled,
              !outcome.newUnreadEntries.isEmpty else { return nil }

        let counts = Dictionary(grouping: outcome.newUnreadEntries, by: \.feedID)
            .mapValues(\.count)
        let orderedSources = counts.compactMap { feedID, count -> (name: String, count: Int)? in
            guard let name = feedTitles[feedID] else { return nil }
            return (name, count)
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let visibleNames = orderedSources.prefix(3).map(\.name)

        return FeedNotificationSummary(
            newUnreadCount: outcome.newUnreadEntries.count,
            visibleSourceNames: visibleNames,
            remainingSourceCount: max(0, orderedSources.count - visibleNames.count)
        )
    }
}
