#if os(macOS)
import AppKit
import Combine
import Foundation
import UserNotifications
#if SWIFT_PACKAGE
import PaperRssCore
#endif

@MainActor
final class MacSystemAttentionController: NSObject, ObservableObject {
    @Published private(set) var dockBadgeEnabled: Bool
    @Published private(set) var feedNotificationsEnabled: Bool
    @Published private(set) var isNotificationPermissionDenied = false
    @Published private(set) var isRequestingNotificationAuthorization = false

    private enum PreferenceKey {
        static let dockBadgeEnabled = "PaperRss.macDockBadgeEnabled"
        static let feedNotificationsEnabled = "PaperRss.macFeedNotificationsEnabled"
    }

    private let store: AppStore
    private let navigation: AppNavigationModel
    private let preferences: UserDefaults
    private let notificationCenter: UNUserNotificationCenter
    private var cancellables: Set<AnyCancellable> = []
    private var latestDatabase: AppDatabase

    init(
        store: AppStore,
        navigation: AppNavigationModel,
        preferences: UserDefaults = .standard,
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.store = store
        self.navigation = navigation
        self.preferences = preferences
        self.notificationCenter = notificationCenter
        latestDatabase = store.database
        dockBadgeEnabled = preferences.bool(forKey: PreferenceKey.dockBadgeEnabled)
        feedNotificationsEnabled = preferences.bool(forKey: PreferenceKey.feedNotificationsEnabled)
        super.init()

        notificationCenter.delegate = self
        observeStore()
        updateDockBadge()
        Task { [weak self] in
            await self?.refreshNotificationAuthorization()
        }
    }

    func setDockBadgeEnabled(_ enabled: Bool) {
        dockBadgeEnabled = enabled
        preferences.set(enabled, forKey: PreferenceKey.dockBadgeEnabled)
        updateDockBadge()
    }

    func setFeedNotificationsEnabled(_ enabled: Bool) async {
        guard enabled else {
            feedNotificationsEnabled = false
            preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
            await refreshNotificationAuthorization()
            return
        }

        isRequestingNotificationAuthorization = true
        defer { isRequestingNotificationAuthorization = false }
        do {
            let settings = await notificationCenter.notificationSettings()
            let authorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authorized = true
            case .notDetermined:
                authorized = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            case .denied:
                authorized = false
            @unknown default:
                authorized = false
            }
            feedNotificationsEnabled = authorized
            isNotificationPermissionDenied = !authorized
            preferences.set(authorized, forKey: PreferenceKey.feedNotificationsEnabled)
        } catch {
            feedNotificationsEnabled = false
            preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
            await refreshNotificationAuthorization()
        }
    }

    func refreshNotificationAuthorization() async {
        let settings = await notificationCenter.notificationSettings()
        isNotificationPermissionDenied = settings.authorizationStatus == .denied
        let canDeliverNotifications: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            canDeliverNotifications = true
        case .notDetermined, .denied:
            canDeliverNotifications = false
        @unknown default:
            canDeliverNotifications = false
        }
        if !canDeliverNotifications, feedNotificationsEnabled {
            feedNotificationsEnabled = false
            preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
        }
    }

    func openSystemNotificationSettings() {
        let directURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        if let directURL, NSWorkspace.shared.open(directURL) {
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            configuration: .init()
        )
    }

    private func observeStore() {
        store.$database
            .sink { [weak self] database in
                guard let self else { return }
                self.latestDatabase = database
                self.updateDockBadge()
            }
            .store(in: &cancellables)

        store.$latestRefreshOutcome
            .compactMap { $0 }
            .sink { [weak self] outcome in
                let appWasActive = NSApp.isActive
                Task { [weak self] in
                    await self?.deliverNotification(for: outcome, appWasActive: appWasActive)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.refreshNotificationAuthorization()
                }
            }
            .store(in: &cancellables)
    }

    private func updateDockBadge() {
        let activeFeedIDs = Set(latestDatabase.feeds.lazy.filter { !$0.isDeleted }.map(\.id))
        let unreadCount = latestDatabase.entries.lazy.filter {
            activeFeedIDs.contains($0.feedID) && !$0.isRead
        }.count
        NSApp.dockTile.badgeLabel = FeedAttentionPolicy.dockBadgeLabel(
            unreadCount: unreadCount,
            enabled: dockBadgeEnabled
        )
    }

    private func deliverNotification(
        for outcome: FeedRefreshOutcome,
        appWasActive: Bool
    ) async {
        let feedTitles = Dictionary(
            uniqueKeysWithValues: latestDatabase.feeds
                .filter { !$0.isDeleted }
                .map { ($0.id, $0.title) }
        )
        guard let summary = FeedAttentionPolicy.notificationSummary(
            outcome: outcome,
            feedTitles: feedTitles,
            enabled: feedNotificationsEnabled,
            appIsActive: appWasActive
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = I18N.shared.tr(
            "Paper RSS：\(summary.newUnreadCount) 篇新文章",
            "Paper RSS: \(summary.newUnreadCount) new articles"
        )
        let sourceList = summary.visibleSourceNames.joined(separator: I18N.shared.tr("、", ", "))
        if summary.remainingSourceCount > 0 {
            content.body = I18N.shared.tr(
                "来自 \(sourceList)，另有 \(summary.remainingSourceCount) 个订阅源",
                "From \(sourceList), plus \(summary.remainingSourceCount) more sources"
            )
        } else {
            content.body = I18N.shared.tr("来自 \(sourceList)", "From \(sourceList)")
        }
        content.sound = .default
        content.userInfo = ["destination": "unread"]

        let request = UNNotificationRequest(
            identifier: "feed-refresh-\(outcome.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }

    private func openUnreadFromNotification() {
        navigation.openUnread()
        NSApp.activate(ignoringOtherApps: true)
        let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        let mainWindow = NSApp.windows.first {
            $0.canBecomeMain
                && !($0 is NSPanel)
                && $0.identifier != settingsWindowIdentifier
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

extension MacSystemAttentionController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let shouldOpenUnread = response.notification.request.content.userInfo["destination"] as? String == "unread"
        completionHandler()
        guard shouldOpenUnread else { return }
        Task { @MainActor [weak self] in
            self?.openUnreadFromNotification()
        }
    }
}
#endif
