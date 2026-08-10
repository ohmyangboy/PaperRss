#if os(macOS)
import AppKit
import Combine
import Foundation
import UserNotifications
#if SWIFT_PACKAGE
import PaperRssCore
#endif

private final class DockUnreadBadgeView: NSView {
    private let icon: NSImage
    var label: String {
        didSet { needsDisplay = true }
    }

    init(icon: NSImage, label: String, size: NSSize) {
        self.icon = icon
        self.label = label
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let badgeHeight = max(28, bounds.height * 0.30)
        let font = NSFont.systemFont(ofSize: badgeHeight * 0.58, weight: .bold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let badgeWidth = max(badgeHeight, textSize.width + badgeHeight * 0.42)
        let badgeRect = NSRect(
            x: bounds.maxX - badgeWidth - 2,
            y: bounds.maxY - badgeHeight - 2,
            width: badgeWidth,
            height: badgeHeight
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (label as NSString).draw(
            in: NSRect(
                x: badgeRect.minX,
                y: badgeRect.midY - textSize.height / 2,
                width: badgeRect.width,
                height: textSize.height
            ),
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
    }
}

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
    private var dockBadgeView: DockUnreadBadgeView?

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
        feedNotificationsEnabled = false
        preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
        super.init()

        notificationCenter.delegate = self
        observeStore()
        updateDockBadge()
    }

    func setDockBadgeEnabled(_ enabled: Bool) {
        dockBadgeEnabled = enabled
        preferences.set(enabled, forKey: PreferenceKey.dockBadgeEnabled)
        updateDockBadge()
    }

    func setFeedNotificationsEnabled(_ enabled: Bool) async {
        feedNotificationsEnabled = false
        preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
    }

    func refreshNotificationAuthorization() async {
        feedNotificationsEnabled = false
        preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
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
        let label = FeedAttentionPolicy.dockBadgeLabel(
            unreadCount: unreadCount,
            enabled: dockBadgeEnabled
        )
        let dockTile = NSApp.dockTile
        dockTile.badgeLabel = nil

        guard let label else {
            dockBadgeView = nil
            dockTile.contentView = nil
            dockTile.display()
            return
        }

        let badgeView = dockBadgeView ?? DockUnreadBadgeView(
            icon: NSApp.applicationIconImage,
            label: label,
            size: dockTile.size
        )
        badgeView.frame = NSRect(origin: .zero, size: dockTile.size)
        badgeView.label = label
        dockBadgeView = badgeView
        dockTile.contentView = badgeView
        dockTile.display()
    }

    private func deliverNotification(
        for outcome: FeedRefreshOutcome,
        appWasActive: Bool
    ) async {
        // 新文章系统通知功能已被停用
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
