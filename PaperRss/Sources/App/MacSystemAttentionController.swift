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
    /// 用户选择（下次启动生效）：隐藏 Dock 图标（含 Cmd+Tab），应用转为辅助（accessory）激活策略。
    @Published private(set) var hideDockIcon: Bool
    /// 用户选择（下次启动生效）：在菜单栏显示图标与未读数量。
    @Published private(set) var showMenuBarIcon: Bool
    /// 当前进程实际生效的图标可见性，启动时一次性应用。
    @Published private(set) var appliedHideDockIcon: Bool
    @Published private(set) var appliedShowMenuBarIcon: Bool
    @Published private(set) var feedNotificationsEnabled: Bool
    @Published private(set) var isNotificationPermissionDenied = false
    @Published private(set) var isRequestingNotificationAuthorization = false

    private enum PreferenceKey {
        static let dockBadgeEnabled = "PaperRss.macDockBadgeEnabled"
        static let feedNotificationsEnabled = "PaperRss.macFeedNotificationsEnabled"
        static let hideDockIcon = "PaperRss.macHideDockIcon"
        static let showMenuBarIcon = "PaperRss.macShowMenuBarIcon"
    }

    private let store: AppStore
    private let navigation: AppNavigationModel
    private let preferences: UserDefaults
    private let notificationCenter: UNUserNotificationCenter
    private var cancellables: Set<AnyCancellable> = []
    private weak var application: NSApplication?
    private var hasStarted = false
    private var dockBadgeView: DockUnreadBadgeView?
    private var statusItem: NSStatusItem?
    private var mainWindowOpener: (() -> Void)?

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
        dockBadgeEnabled = preferences.bool(forKey: PreferenceKey.dockBadgeEnabled)
        let storedShowMenuBarIcon = preferences.bool(forKey: PreferenceKey.showMenuBarIcon)
        showMenuBarIcon = storedShowMenuBarIcon
        // 修正历史或异常组合：没有菜单栏入口时不允许隐藏 Dock 图标。
        let resolvedHideDockIcon = MacIconVisibilityPolicy.resolvesHideDockIcon(
            preferences.bool(forKey: PreferenceKey.hideDockIcon),
            showMenuBarIcon: storedShowMenuBarIcon
        )
        hideDockIcon = resolvedHideDockIcon
        appliedHideDockIcon = resolvedHideDockIcon
        appliedShowMenuBarIcon = storedShowMenuBarIcon
        feedNotificationsEnabled = false
        preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
        super.init()
    }

    /// 在 App 初始化阶段就按已存开关设置激活策略，避免启动瞬间闪现 Dock 图标。
    static func applyStoredIconVisibilityToLaunchingApplication() {
        let hidesDockIcon = MacIconVisibilityPolicy.resolvesHideDockIcon(
            UserDefaults.standard.bool(forKey: PreferenceKey.hideDockIcon),
            showMenuBarIcon: UserDefaults.standard.bool(forKey: PreferenceKey.showMenuBarIcon)
        )
        guard hidesDockIcon else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func start(application: NSApplication) {
        guard !hasStarted else { return }
        self.application = application
        hasStarted = true
        notificationCenter.delegate = self
        observeStore()
        updateDockBadge()
        applyIconVisibility()
    }

    /// 主窗口由 SwiftUI 场景管理，窗口被关闭后需要经 openWindow 重新创建。
    func registerMainWindowOpener(_ opener: @escaping () -> Void) {
        mainWindowOpener = opener
    }

    func setDockBadgeEnabled(_ enabled: Bool) {
        dockBadgeEnabled = enabled
        preferences.set(enabled, forKey: PreferenceKey.dockBadgeEnabled)
        updateDockBadge()
    }

    /// 图标可见性开关改动后需要重启才生效：运行中切换激活策略会让窗口短暂失去前台，
    /// 因此开关只写入偏好，统一由下次启动时应用。
    func setHideDockIcon(_ hidden: Bool) {
        let resolved = MacIconVisibilityPolicy.resolvesHideDockIcon(
            hidden,
            showMenuBarIcon: showMenuBarIcon
        )
        guard hideDockIcon != resolved else { return }
        hideDockIcon = resolved
        preferences.set(resolved, forKey: PreferenceKey.hideDockIcon)
    }

    func setShowMenuBarIcon(_ visible: Bool) {
        guard showMenuBarIcon != visible else { return }
        showMenuBarIcon = visible
        preferences.set(visible, forKey: PreferenceKey.showMenuBarIcon)
        // 关闭菜单栏入口时同步取消隐藏 Dock，避免应用没有任何入口。
        let resolvedHideDockIcon = MacIconVisibilityPolicy.resolvesHideDockIcon(
            hideDockIcon,
            showMenuBarIcon: visible
        )
        if hideDockIcon != resolvedHideDockIcon {
            hideDockIcon = resolvedHideDockIcon
            preferences.set(resolvedHideDockIcon, forKey: PreferenceKey.hideDockIcon)
        }
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
        store.$sidebarCounts
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateDockBadge()
                self.updateStatusItem()
            }
            .store(in: &cancellables)

        store.$latestRefreshOutcome
            .compactMap { $0 }
            .sink { [weak self] outcome in
                guard let self, let application = self.application else { return }
                let appWasActive = application.isActive
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
        guard let application else { return }
        let unreadCount = store.sidebarCounts.allUnread
        let label = FeedAttentionPolicy.dockBadgeLabel(
            unreadCount: unreadCount,
            enabled: dockBadgeEnabled
        )
        let dockTile = application.dockTile
        dockTile.badgeLabel = nil

        guard let label else {
            dockBadgeView = nil
            dockTile.contentView = nil
            dockTile.display()
            return
        }

        let badgeView = dockBadgeView ?? DockUnreadBadgeView(
            icon: application.applicationIconImage,
            label: label,
            size: dockTile.size
        )
        badgeView.frame = NSRect(origin: .zero, size: dockTile.size)
        badgeView.label = label
        dockBadgeView = badgeView
        dockTile.contentView = badgeView
        dockTile.display()
    }

    // MARK: - 图标可见性（Dock / 菜单栏）

    /// 启动时一次性应用已存偏好；运行期间不再切换激活策略，避免窗口闪动。
    private func applyIconVisibility() {
        guard let application else { return }
        appliedHideDockIcon = hideDockIcon
        appliedShowMenuBarIcon = showMenuBarIcon
        application.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        if showMenuBarIcon {
            installStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }
        updateStatusItem()
        updateDockBadge()
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusItemImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("PaperRss")
        }
        statusItem = item
        updateStatusItem()
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let title = FeedAttentionPolicy.menuBarUnreadTitle(unreadCount: store.sidebarCounts.allUnread)
        button.title = title ?? ""
        button.toolTip = title.map { I18N.shared.localizedFormat("未读 %@ 篇", $0) } ?? "PaperRss"
    }

    private static func statusItemImage() -> NSImage? {
        #if SWIFT_PACKAGE
        let source = Bundle.module.image(forResource: "PaperEmptyBrandIcon")
        #else
        let source = NSImage(named: "PaperEmptyBrandIcon")
        #endif
        guard let image = source?.copy() as? NSImage else { return source }
        // 源图上下留有透明边距，按比例放大画布让字形接近菜单栏图标常用高度。
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 18)
        return image
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let statusItem else { return }
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            showStatusItemMenu(for: statusItem)
        } else {
            bringAppForward()
        }
    }

    private func showStatusItemMenu(for statusItem: NSStatusItem) {
        let menu = NSMenu()
        menu.addItem(statusMenuItem(I18N.shared.localized("打开 PaperRss"), #selector(openMainWindowFromStatusItem(_:))))
        menu.addItem(statusMenuItem(I18N.shared.localized("未读文章"), #selector(openUnreadFromStatusItem(_:))))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(I18N.shared.localized("刷新全部订阅"), #selector(refreshAllFromStatusItem(_:))))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(I18N.shared.localized("退出 PaperRss"), #selector(quitFromStatusItem(_:))))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func statusMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindowFromStatusItem(_ sender: NSMenuItem) {
        bringAppForward()
    }

    @objc private func openUnreadFromStatusItem(_ sender: NSMenuItem) {
        navigation.openUnread()
        bringAppForward()
    }

    @objc private func refreshAllFromStatusItem(_ sender: NSMenuItem) {
        Task { await store.refresh() }
    }

    @objc private func quitFromStatusItem(_ sender: NSMenuItem) {
        application?.terminate(nil)
    }

    private func deliverNotification(
        for outcome: FeedRefreshOutcome,
        appWasActive: Bool
    ) async {
        // 新文章系统通知功能已被停用
    }

    private func openUnreadFromNotification() {
        navigation.openUnread()
        bringAppForward()
    }

    private func bringAppForward() {
        guard let application else { return }
        application.activate(ignoringOtherApps: true)
        if let window = mainWindow(in: application) {
            window.makeKeyAndOrderFront(nil)
        } else {
            mainWindowOpener?()
        }
    }

    private func mainWindow(in application: NSApplication) -> NSWindow? {
        let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        return application.windows.first {
            $0.canBecomeMain
                && !($0 is NSPanel)
                && $0.identifier != settingsWindowIdentifier
        }
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
