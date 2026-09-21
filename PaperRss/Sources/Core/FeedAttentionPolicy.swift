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

/// macOS 图标可见性规则。
public enum MacIconVisibilityPolicy {
    /// 只有菜单栏图标开启时才允许隐藏 Dock 图标，否则应用会失去所有可见入口。
    public static func resolvesHideDockIcon(_ hideDockIcon: Bool, showMenuBarIcon: Bool) -> Bool {
        hideDockIcon && showMenuBarIcon
    }

    /// Dock 图标只在窗口全部关闭后才隐藏：有窗口时应用仍需出现在程序坞与 Cmd+Tab，
    /// 否则用户既切不回来，也没有 Dock 图标可以点。
    public static func hidesDockIcon(_ hideDockIcon: Bool, hasPresentedWindow: Bool) -> Bool {
        hideDockIcon && !hasPresentedWindow
    }
}

public enum FeedAttentionPolicy {
    public static func dockBadgeLabel(unreadCount: Int, enabled: Bool) -> String? {
        guard enabled else { return nil }
        return unreadBadgeText(unreadCount: unreadCount)
    }

    /// 菜单栏未读文案：未读为 0 时返回 nil（只保留图标），超过两位折叠为 99+。
    public static func menuBarUnreadTitle(unreadCount: Int) -> String? {
        unreadBadgeText(unreadCount: unreadCount)
    }

    private static func unreadBadgeText(unreadCount: Int) -> String? {
        guard unreadCount > 0 else { return nil }
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
