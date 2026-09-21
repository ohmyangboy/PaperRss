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
    /// 用户选择（即时生效）：隐藏 Dock 图标（含 Cmd+Tab）。窗口打开期间仍保留常规入口，
    /// 窗口全部关闭后才转为辅助（accessory）激活策略。
    @Published private(set) var hideDockIcon: Bool
    /// 用户选择（即时生效）：在菜单栏显示图标与未读数量。
    @Published private(set) var showMenuBarIcon: Bool
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
        hideDockIcon = MacIconVisibilityPolicy.resolvesHideDockIcon(
            preferences.bool(forKey: PreferenceKey.hideDockIcon),
            showMenuBarIcon: storedShowMenuBarIcon
        )
        feedNotificationsEnabled = false
        preferences.set(false, forKey: PreferenceKey.feedNotificationsEnabled)
        super.init()
    }

    func start(application: NSApplication) {
        guard !hasStarted else { return }
        self.application = application
        hasStarted = true
        notificationCenter.delegate = self
        observeStore()
        observeWindowVisibility()
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

    /// 隐藏 Dock 图标：窗口打开期间仍保留程序坞与 Cmd+Tab 入口，
    /// 窗口全部关闭后才真正隐藏，改动即时生效。
    func setHideDockIcon(_ hidden: Bool) {
        let resolved = MacIconVisibilityPolicy.resolvesHideDockIcon(
            hidden,
            showMenuBarIcon: showMenuBarIcon
        )
        guard hideDockIcon != resolved else { return }
        hideDockIcon = resolved
        preferences.set(resolved, forKey: PreferenceKey.hideDockIcon)
        applyIconVisibility()
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
        applyIconVisibility()
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

    /// 应用两个图标开关：状态栏项立即装配，Dock 图标按窗口状态判定。
    private func applyIconVisibility() {
        if showMenuBarIcon {
            installStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }
        updateStatusItem()
        scheduleIconVisibilitySync()
        updateDockBadge()
    }

    /// Dock 图标只在「用户没要求隐藏」或「应用还有窗口」时可见。
    /// 关掉最后一个窗口后应用退回辅助策略，重新唤出窗口时随窗口回到程序坞与 Cmd+Tab。
    private func syncDockIconVisibility() {
        guard let application else { return }
        let hidesDockIcon = MacIconVisibilityPolicy.hidesDockIcon(
            hideDockIcon,
            hasPresentedWindow: hasPresentedWindow(in: application)
        )
        let policy: NSApplication.ActivationPolicy = hidesDockIcon ? .accessory : .regular
        guard application.activationPolicy() != policy else { return }
        application.setActivationPolicy(policy)
        if hidesDockIcon, application.isActive {
            // 没有窗口就不该再占着前台：交回上一个应用，菜单栏不残留空菜单。
            application.deactivate()
        }
    }

    /// 窗口显隐是 Dock 图标可见性的唯一依据；面板（弹出菜单、浮层）不算入口。
    private func observeWindowVisibility() {
        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    self?.scheduleIconVisibilitySync()
                }
                .store(in: &cancellables)
        }
    }

    /// 窗口通知与视图回调都可能落在窗口上屏/关闭的中间态（`willClose` 时窗口仍算可见），
    /// 统一延后一拍再判定。
    private func scheduleIconVisibilitySync() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.syncDockIconVisibility() }
        }
    }

    /// 最小化窗口也算窗口：它不在常规主窗口判定里，但用户必须留着 Dock 图标才能把它取回来。
    private func hasPresentedWindow(in application: NSApplication) -> Bool {
        application.windows.contains { window in
            guard !(window is NSPanel) else { return false }
            return window.isMiniaturized || (window.canBecomeMain && window.isVisible)
        }
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
        // 辅助策略下激活不会带回 Dock 图标与 Cmd+Tab：先恢复常规策略再唤出窗口。
        prepareRegularPolicyForPresentation(application)
        application.activate(ignoringOtherApps: true)
        if let window = mainWindow(in: application) {
            window.makeKeyAndOrderFront(nil)
        } else if let miniaturized = miniaturizedWindow(in: application) {
            // 最小化窗口不在主窗口判定里：直接还原，避免再开一个窗口。
            miniaturized.deminiaturize(nil)
            miniaturized.makeKeyAndOrderFront(nil)
        } else {
            mainWindowOpener?()
        }
    }

    /// 唤出窗口前先回常规策略；窗口真正上屏后由窗口通知接管判定。
    private func prepareRegularPolicyForPresentation(_ application: NSApplication) {
        guard application.activationPolicy() != .regular else { return }
        application.setActivationPolicy(.regular)
    }

    private func miniaturizedWindow(in application: NSApplication) -> NSWindow? {
        application.windows.first { $0.isMiniaturized && !($0 is NSPanel) }
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
