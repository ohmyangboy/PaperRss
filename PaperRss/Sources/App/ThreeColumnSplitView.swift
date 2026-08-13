#if os(macOS)
import SwiftUI
import AppKit
import WebKit
#if SWIFT_PACKAGE
import PaperRssCore
#endif

// MARK: - 工具栏动作回调

/// 由 SwiftUI 视图层传入的工具栏动作和状态
struct ToolbarActions {
    let onRefresh: () -> Void
    let onAddFeed: () -> Void
    let onAddFolder: () -> Void
    let onImport: () -> Void
    let onExport: () -> Void
    let isRefreshing: Bool
    let selectionTitle: String
    let hasUnread: Bool
    let onMarkAllRead: () -> Void
    let onFocusAndScrollArticle: () -> Void
    let isZenMode: Bool
    let onToggleZenMode: () -> Void
    let showsReaderCapsule: Bool
    let readerCapsule: AnyView
    let onReaderShortcut: (ReaderShortcutAction) -> Void

    let onIncreaseFontSize: () -> Void
    let onDecreaseFontSize: () -> Void
    let onResetFontSize: () -> Void
    let onSelectFirstEntryIfNeeded: () -> Void

    init(
        onRefresh: @escaping () -> Void,
        onAddFeed: @escaping () -> Void,
        onAddFolder: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onExport: @escaping () -> Void,
        isRefreshing: Bool,
        selectionTitle: String,
        hasUnread: Bool,
        onMarkAllRead: @escaping () -> Void,
        onFocusAndScrollArticle: @escaping () -> Void = {},
        isZenMode: Bool = false,
        onToggleZenMode: @escaping () -> Void = {},
        showsReaderCapsule: Bool = false,
        readerCapsule: AnyView = AnyView(EmptyView()),
        onReaderShortcut: @escaping (ReaderShortcutAction) -> Void = { _ in },
        onIncreaseFontSize: @escaping () -> Void = {},
        onDecreaseFontSize: @escaping () -> Void = {},
        onResetFontSize: @escaping () -> Void = {},
        onSelectFirstEntryIfNeeded: @escaping () -> Void = {}
    ) {
        self.onRefresh = onRefresh
        self.onAddFeed = onAddFeed
        self.onAddFolder = onAddFolder
        self.onImport = onImport
        self.onExport = onExport
        self.isRefreshing = isRefreshing
        self.selectionTitle = selectionTitle
        self.hasUnread = hasUnread
        self.onMarkAllRead = onMarkAllRead
        self.onFocusAndScrollArticle = onFocusAndScrollArticle
        self.isZenMode = isZenMode
        self.onToggleZenMode = onToggleZenMode
        self.showsReaderCapsule = showsReaderCapsule
        self.readerCapsule = readerCapsule
        self.onReaderShortcut = onReaderShortcut
        self.onIncreaseFontSize = onIncreaseFontSize
        self.onDecreaseFontSize = onDecreaseFontSize
        self.onResetFontSize = onResetFontSize
        self.onSelectFirstEntryIfNeeded = onSelectFirstEntryIfNeeded
    }
}

// MARK: - 三栏分割视图桥接

/// 使用 AppKit NSSplitViewController 实现的三栏布局，
/// 配合 NSToolbar 和 NSTrackingSeparatorToolbarItem 实现
/// NetNewsWire 风格的工具栏按钮紧贴红绿灯效果。
///
/// 关键原理（参考 NetNewsWire 源码）：
/// 1. fullSizeContentView — 视图延伸到标题栏下方
/// 2. NSSplitViewItem(sidebarWithViewController:) — 声明侧边栏身份
/// 3. NSToolbarItem.Identifier.toggleSidebar 作为首项 — 系统自动贴合红绿灯
/// 4. NSTrackingSeparatorToolbarItem — 工具栏项跟踪分割线位置
struct ThreeColumnSplitView<Sidebar: View, Content: View, Detail: View>: NSViewControllerRepresentable {
    let sidebar: Sidebar
    let content: Content
    let detail: Detail
    let toolbarActions: ToolbarActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: toolbarActions)
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitVC = PaperSplitViewController()
        splitVC.onLayout = { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated {
                if let window = splitVC.view.window {
                    coordinator?.removeTitlebarBlur(from: window)
                }
            }
        }

        // 侧边栏 — 使用 sidebarWithViewController 声明 sidebar 身份
        let sidebarHost = NSHostingController(rootView: sidebar)
        sidebarHost.view.wantsLayer = true
        sidebarHost.view.clipsToBounds = true
        sidebarHost.view.layer?.masksToBounds = true
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true

        // 文章列表 — 使用 contentListWithViewController 声明 content list 身份
        let contentHost = NSHostingController(rootView: content)
        contentHost.view.wantsLayer = true
        contentHost.view.clipsToBounds = true
        contentHost.view.layer?.masksToBounds = true
        let contentItem = NSSplitViewItem(contentListWithViewController: contentHost)
        contentItem.minimumThickness = 280

        // 文章详情
        let detailHost = NSHostingController(rootView: detail)
        detailHost.view.wantsLayer = true
        detailHost.view.clipsToBounds = true
        detailHost.view.layer?.masksToBounds = true
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.allowsFullHeightLayout = true
        detailItem.minimumThickness = 400

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        splitVC.addSplitViewItem(detailItem)

        context.coordinator.splitViewController = splitVC
        
        // 核心修复：使用 KVO 监听 NSSplitView 被挂载到 window 的那一瞬间。
        // 这会在窗口准备显示的第 0 帧同步触发，早于任何 SwiftUI 的 update 周期，
        // 从而能在原生窗口呈现的第一秒前就将 Toolbar 与全屏标志位设定好，实现零闪烁 (Zero-flicker) 启动。
        context.coordinator.windowObservation = splitVC.view.observe(\.window, options: [.new]) { [weak coordinator = context.coordinator] view, _ in
            MainActor.assumeIsolated {
                if let window = view.window, let coord = coordinator, !coord.toolbarConfigured {
                    coord.configureToolbar(on: window, splitView: splitVC.splitView)
                }
            }
        }

        context.coordinator.sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak coordinator = context.coordinator] _, _ in
            MainActor.assumeIsolated {
                coordinator?.syncHeaderState()
            }
        }

        return splitVC
    }

    func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
        // 更新工具栏动作状态
        context.coordinator.actions = toolbarActions

        // 更新三栏的 SwiftUI 内容
        if let host = splitVC.splitViewItems[0].viewController as? NSHostingController<Sidebar> {
            host.rootView = sidebar
        }
        if let host = splitVC.splitViewItems[1].viewController as? NSHostingController<Content> {
            host.rootView = content
        }
        if let host = splitVC.splitViewItems[2].viewController as? NSHostingController<Detail> {
            host.rootView = detail
        }

        // 同步刷新按钮及 Header 状态
        context.coordinator.syncLocalizedToolbarText()
        context.coordinator.syncRefreshState()
        context.coordinator.syncHeaderState()

        // 禅模式：平滑动画收起 Sidebar (Column 0) 和 EntryListView (Column 1)
        if splitVC.splitViewItems.count >= 2 {
            let sidebarItem = splitVC.splitViewItems[0]
            let contentListItem = splitVC.splitViewItems[1]
            let targetState = toolbarActions.isZenMode
            if sidebarItem.isCollapsed != targetState {
                sidebarItem.animator().isCollapsed = targetState
            }
            if contentListItem.isCollapsed != targetState {
                contentListItem.animator().isCollapsed = targetState
            }
        }

        // 禅模式下隐藏除 Article View 阅读胶囊外的所有工具栏按钮
        context.coordinator.syncZenModeState()

        // 更新工具栏中的阅读工具胶囊(SwiftUI 状态变化后刷新图标/可用态与显示隐藏)
        if let host = context.coordinator.readerCapsuleHost {
            if toolbarActions.showsReaderCapsule {
                host.isHidden = false
                if #available(macOS 15.0, *) {
                    context.coordinator.readerCapsuleItem?.isHidden = false
                }
                host.rootView = toolbarActions.readerCapsule
                let size = host.fittingSize
                let width = size.width > 0 ? size.width : 140
                let height = size.height > 0 ? size.height : 28
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                context.coordinator.readerCapsuleWidthConstraint?.constant = width
                context.coordinator.readerCapsuleHeightConstraint?.constant = height
            } else {
                host.isHidden = true
                if #available(macOS 15.0, *) {
                    context.coordinator.readerCapsuleItem?.isHidden = true
                }
                host.frame = .zero
                context.coordinator.readerCapsuleWidthConstraint?.constant = 0
                context.coordinator.readerCapsuleHeightConstraint?.constant = 0
            }
        }
    }

    // MARK: - Coordinator

    typealias Coordinator = ThreeColumnSplitViewCoordinator
}

@MainActor
final class ThreeColumnSplitViewCoordinator: NSObject, NSToolbarDelegate {
        var actions: ToolbarActions
        weak var splitViewController: NSSplitViewController?
        var toolbarConfigured = false
        var windowObservation: NSKeyValueObservation?
        var sidebarObservation: NSKeyValueObservation?
        private weak var refreshItem: NSToolbarItem?
        private weak var refreshButton: NSButton?
        private weak var refreshSpinner: NSProgressIndicator?
        fileprivate weak var readerCapsuleItem: NSToolbarItem?
        fileprivate weak var readerCapsuleHost: NSHostingView<AnyView>?
        fileprivate weak var readerCapsuleWidthConstraint: NSLayoutConstraint?
        fileprivate weak var readerCapsuleHeightConstraint: NSLayoutConstraint?
        fileprivate weak var entryListTitleItem: NSToolbarItem?
        private weak var titleLabel: NSTextField?
        private weak var markAllReadButton: NSButton?
        nonisolated(unsafe) private var eventMonitor: Any?
        nonisolated(unsafe) private var mouseDownMonitor: Any?
        private var blurCleanupTimer: DispatchSourceTimer?

        init(actions: ToolbarActions) {
            self.actions = actions
            super.init()
            setupLocalKeyMonitor()
            setupMouseDownMonitor()
        }

        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = mouseDownMonitor {
                NSEvent.removeMonitor(monitor)
            }
            blurCleanupTimer?.cancel()
        }

        @MainActor
        func findFocusTarget(in view: NSView) -> NSView {
            @MainActor
            func findPrimary(in v: NSView) -> NSView? {
                if v is NSTableView || v is NSOutlineView || v is WKWebView {
                    return v
                }
                for subview in v.subviews {
                    if let found = findPrimary(in: subview) { return found }
                }
                return nil
            }
            if let primary = findPrimary(in: view) { return primary }

            @MainActor
            func findAnyAccepting(in v: NSView) -> NSView? {
                if v.acceptsFirstResponder { return v }
                for subview in v.subviews {
                    if let found = findAnyAccepting(in: subview) { return found }
                }
                return nil
            }
            return findAnyAccepting(in: view) ?? view
        }

        @MainActor
        func focusColumn(_ index: Int) {
            guard let splitVC = splitViewController,
                  let window = splitVC.view.window ?? NSApp.keyWindow,
                  index < splitVC.splitViewItems.count else { return }

            let targetContainer = splitVC.splitViewItems[index].viewController.view
            let targetView = findFocusTarget(in: targetContainer)

            if window.firstResponder !== targetView {
                window.makeFirstResponder(targetView)
            }

            if index == 1 {
                actions.onSelectFirstEntryIfNeeded()
            }
        }

        private func setupMouseDownMonitor() {
            guard mouseDownMonitor == nil else { return }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self else { return event }

                guard let splitVC = MainActor.assumeIsolated({ self.splitViewController }),
                      let window = splitVC.view.window,
                      (event.window ?? NSApp.keyWindow) === window else { return event }

                let loc = event.locationInWindow
                let pointInSplitView = splitVC.view.convert(loc, from: nil)

                let sidebarView = splitVC.splitViewItems[0].viewController.view
                let listView = splitVC.splitViewItems[1].viewController.view
                let detailView = splitVC.splitViewItems.count >= 3 ? splitVC.splitViewItems[2].viewController.view : nil

                var clickedCol: Int? = nil
                if sidebarView.frame.contains(pointInSplitView) && !splitVC.splitViewItems[0].isCollapsed {
                    clickedCol = 0
                } else if listView.frame.contains(pointInSplitView) && !splitVC.splitViewItems[1].isCollapsed {
                    clickedCol = 1
                } else if let detailView = detailView, detailView.frame.contains(pointInSplitView) {
                    clickedCol = 2
                }

                if let col = clickedCol {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.focusColumn(col)
                        }
                    }
                }

                return event
            }
        }

        private func setupLocalKeyMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                // ESC 键 (keyCode 53)：处于禅模式时按下 ESC 键退出禅模式
                if event.keyCode == 53 && flags.isEmpty {
                    if MainActor.assumeIsolated({ self.actions.isZenMode }) {
                        MainActor.assumeIsolated {
                            self.actions.onToggleZenMode()
                        }
                        return nil
                    }
                }
                if flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
                    let chars = event.charactersIgnoringModifiers ?? ""
                    if chars == "=" || chars == "+" || event.keyCode == 24 || event.keyCode == 69 {
                        MainActor.assumeIsolated {
                            self.actions.onIncreaseFontSize()
                        }
                        return nil
                    }
                    if chars == "-" || chars == "_" || event.keyCode == 27 || event.keyCode == 78 {
                        MainActor.assumeIsolated {
                            self.actions.onDecreaseFontSize()
                        }
                        return nil
                    }
                    if chars == "0" || event.keyCode == 29 || event.keyCode == 82 {
                        MainActor.assumeIsolated {
                            self.actions.onResetFontSize()
                        }
                        return nil
                    }
                }

                if MainActor.assumeIsolated({ self.consumeReaderShortcut(event, flags: flags) }) {
                    return nil
                }

                // 左/右方向键 (keyCode 123 左, 124 右)
                if flags.isEmpty && (event.keyCode == 123 || event.keyCode == 124) {
                    guard let window = event.window ?? NSApp.keyWindow,
                          let splitVC = self.splitViewController,
                          splitVC.splitViewItems.count >= 3 else { return event }

                    let firstResponder = window.firstResponder as? NSView
                    if firstResponder is NSTextView || firstResponder is NSTextField {
                        return event
                    }

                    let sidebarView = splitVC.splitViewItems[0].viewController.view
                    let listView = splitVC.splitViewItems[1].viewController.view
                    let detailView = splitVC.splitViewItems[2].viewController.view

                    @MainActor
                    func currentColumnIndex() -> Int? {
                        guard let firstResponder = firstResponder else { return nil }
                        var current: NSView? = firstResponder
                        while let p = current {
                            if p === sidebarView { return 0 }
                            if p === listView { return 1 }
                            if p === detailView { return 2 }
                            current = p.superview
                        }
                        return nil
                    }

                    guard let colIndex = MainActor.assumeIsolated({ currentColumnIndex() }) else { return event }

                    if event.keyCode == 123 { // Left
                        if colIndex == 2 { // 从文章详情 -> 切到文章列表
                            MainActor.assumeIsolated {
                                self.focusColumn(1)
                            }
                            return nil
                        } else if colIndex == 1 { // 从文章列表 -> 切到侧边栏
                            MainActor.assumeIsolated {
                                self.focusColumn(0)
                            }
                            return nil
                        } else if colIndex == 0 { // 侧边栏（最左边缘停留）
                            return nil
                        }
                    } else if event.keyCode == 124 { // Right
                        if colIndex == 0 { // 从侧边栏 -> 切到文章列表
                            MainActor.assumeIsolated {
                                self.focusColumn(1)
                            }
                            return nil
                        } else if colIndex == 1 { // 从文章列表 -> 切到文章详情
                            MainActor.assumeIsolated {
                                self.focusColumn(2)
                            }
                            return nil
                        } else if colIndex == 2 { // 文章详情（最右边缘停留）
                            return nil
                        }
                    }
                }

                // Space 键 (keyCode 49), 且没有任何 modifier 键 (Cmd / Option / Ctrl / Shift)
                guard event.keyCode == 49, flags.isEmpty, !event.isARepeat else {
                    return event
                }
                guard let window = event.window ?? NSApp.keyWindow,
                      let firstResponder = window.firstResponder as? NSView else {
                    return event
                }
                guard let splitVC = self.splitViewController, splitVC.splitViewItems.count >= 2 else {
                    return event
                }
                if firstResponder is NSTextView || firstResponder is NSTextField {
                    return event
                }
                let contentVCView = splitVC.splitViewItems[1].viewController.view
                let detailVCView = splitVC.splitViewItems.count >= 3 ? splitVC.splitViewItems[2].viewController.view : nil

                if firstResponder.isDescendant(of: contentVCView) {
                    MainActor.assumeIsolated {
                        self.actions.onFocusAndScrollArticle()
                    }
                    return nil
                }

                if let detailVCView, firstResponder.isDescendant(of: detailVCView) {
                    @MainActor
                    func findWKWebView(in view: NSView) -> WKWebView? {
                        if let webView = view as? WKWebView { return webView }
                        for subview in view.subviews {
                            if let found = findWKWebView(in: subview) { return found }
                        }
                        return nil
                    }
                    if findWKWebView(in: detailVCView) == nil {
                        MainActor.assumeIsolated {
                            self.actions.onFocusAndScrollArticle()
                        }
                        return nil
                    }
                }

                return event
            }
        }

        private func consumeReaderShortcut(
            _ event: NSEvent,
            flags: NSEvent.ModifierFlags
        ) -> Bool {
            guard actions.showsReaderCapsule,
                  let splitVC = splitViewController,
                  let mainWindow = splitVC.view.window,
                  (event.window ?? NSApp.keyWindow) === mainWindow,
                  mainWindow.attachedSheet == nil,
                  NSApp.modalWindow == nil,
                  let firstResponder = mainWindow.firstResponder as? NSView else {
                return false
            }

            let disallowedModifiers: NSEvent.ModifierFlags = [
                .command, .option, .control, .shift, .function
            ]
            let action = ReaderShortcutPolicy.action(
                for: event.charactersIgnoringModifiers,
                hasDisallowedModifiers: !flags.intersection(disallowedModifiers).isEmpty,
                isRepeat: event.isARepeat
            )
            guard let action else { return false }

            // WebKit owns its editable descendants, selections and transient
            // selection assistant UI. Its injected key handler performs the
            // synchronous DOM checks and posts the same action only when safe.
            var ancestor: NSView? = firstResponder
            while let view = ancestor {
                if view is WKWebView { return false }
                ancestor = view.superview
            }

            if firstResponder is NSTextView || firstResponder is NSTextField {
                return false
            }

            actions.onReaderShortcut(action)
            return true
        }

        /// 在窗口上配置 NSToolbar，复刻 NetNewsWire 的布局方式
        func configureToolbar(on window: NSWindow, splitView: NSSplitView) {
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified

            let toolbar = NSToolbar(identifier: "PaperRssMainToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.titleVisibility = .hidden
            
            removeTitlebarBlur(from: window)
            DispatchQueue.main.async { [weak self, weak window] in
                if let window {
                    MainActor.assumeIsolated {
                        self?.removeTitlebarBlur(from: window)
                    }
                }
            }

            let center = NotificationCenter.default
            let fullScreenNotifications: [Notification.Name] = [
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification
            ]
            for name in fullScreenNotifications {
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    guard let window = window else { return }
                    MainActor.assumeIsolated {
                        self?.removeTitlebarBlur(from: window)
                        self?.startBlurCleanupTimer(for: window)
                    }
                }
            }

            // 全局监听所有窗口出现/更新，捕捉全屏时系统动态创建的浮动工具栏窗口
            for noteName in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
                center.addObserver(
                    forName: noteName,
                    object: nil,
                    queue: .main
                ) { [weak self, weak window] note in
                    guard let mainWindow = window else { return }
                    guard let appearedWindow = note.object as? NSWindow, appearedWindow !== mainWindow else { return }
                    let className = String(describing: type(of: appearedWindow))
                    if className.contains("Toolbar") || className.contains("Titlebar") || className.contains("FullScreen") {
                        MainActor.assumeIsolated {
                            self?.removeTitlebarBlur(from: mainWindow)
                        }
                    }
                }
            }

            toolbarConfigured = true
        }

        /// 启动一个高频定时器，每 100ms 调用一次 removeTitlebarBlur，持续 3 秒后自动停止。
        /// 解决退出全屏时系统异步多次重建 Titlebar 导致 NSVisualEffectView 反复出现的问题。
        private func startBlurCleanupTimer(for window: NSWindow) {
            blurCleanupTimer?.cancel()
            var remaining = 30 // 30 次 × 100ms = 3 秒
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self, weak window] in
                guard let self = self, let window = window else {
                    timer.cancel()
                    return
                }
                self.removeTitlebarBlur(from: window)
                remaining -= 1
                if remaining <= 0 {
                    timer.cancel()
                    self.blurCleanupTimer = nil
                }
            }
            timer.resume()
            blurCleanupTimer = timer
        }

        fileprivate func removeTitlebarBlur(from window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // 窗口背景不能保持透明:透明会让我 NSSplitView 的分割线矩形
            // (约 1pt 宽,位于列表栏与阅读器栏之间)直接透出窗口背后的内容,
            // 在阅读器左缘形成一条可见缝隙。三个栏目的 PaperSurface 已覆盖
            // 全部内容区域,这里用纸张色填满分割线即可,并跟随外观切换明暗。
            window.backgroundColor = NSColor(name: nil) { appearance in
                let scheme: ColorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
                return NSColor(PaperTheme.surface(.page, scheme: scheme))
            }
            window.isOpaque = true

            guard let themeFrame = window.contentView?.superview else { return }

            func hideVisualEffects(in view: NSView) {
                if let effectView = view as? NSVisualEffectView {
                    effectView.isHidden = true
                    effectView.state = .inactive
                    effectView.alphaValue = 0
                }
                for subview in view.subviews {
                    hideVisualEffects(in: subview)
                }
            }

            // 主窗口：仅隐去标题栏/工具栏容器中的 NSVisualEffectView，保留 contentView (应用内容)
            for subview in themeFrame.subviews {
                if subview !== window.contentView {
                    hideVisualEffects(in: subview)
                }
            }
            
            // 全屏窗口：处理 macOS 进入全屏时创建的浮动工具栏与标题栏辅助窗口
            for appWindow in NSApp.windows where appWindow !== window {
                let className = String(describing: type(of: appWindow))
                if className.contains("Toolbar") || className.contains("Titlebar") || className.contains("FullScreen") {
                    appWindow.titlebarAppearsTransparent = true
                    appWindow.titlebarSeparatorStyle = .none
                    appWindow.backgroundColor = .clear
                    appWindow.isOpaque = false
                    if let toolbarThemeFrame = appWindow.contentView?.superview {
                        hideVisualEffects(in: toolbarThemeFrame)
                    } else if let contentView = appWindow.contentView {
                        hideVisualEffects(in: contentView)
                    }
                }
            }
        }

        /// 同步刷新按钮的可用状态和图标
        func syncRefreshState() {
            guard let item = refreshItem, let button = refreshButton, let spinner = refreshSpinner else { return }
            
            // 永远保持 enabled 避免 AppKit 对整个 NSToolbarItem 强制应用半透明灰色滤镜
            item.isEnabled = true
            item.autovalidates = false
            
            if actions.isRefreshing {
                // 刷新时：隐藏按钮图标（使用透明空图片保持排版不抖动），显示菊花
                let size = button.image?.size ?? NSSize(width: 16, height: 16)
                button.image = NSImage(size: size)
                spinner.isHidden = false
                spinner.startAnimation(nil)
            } else {
                // 停止时：恢复系统原生刷新图标，隐藏菊花
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: I18N.localized("刷新"))
            }
        }

        /// SwiftUI 更新时重新写入原生工具栏文案，确保应用内切换语言无需重启。
        func syncLocalizedToolbarText() {
            guard let toolbar = splitViewController?.view.window?.toolbar else { return }

            for item in toolbar.items {
                switch item.itemIdentifier {
                case .paperRefresh:
                    item.label = I18N.localized("刷新")
                    item.paletteLabel = I18N.localized("刷新所有订阅")
                    item.toolTip = I18N.localized("刷新所有订阅")
                    if !actions.isRefreshing {
                        refreshButton?.image = NSImage(
                            systemSymbolName: "arrow.clockwise",
                            accessibilityDescription: I18N.localized("刷新")
                        )
                    }
                case .paperAddMenu:
                    item.label = I18N.localized("添加")
                    item.toolTip = I18N.localized("添加订阅或新建文件夹")
                    if let menuItem = item as? NSMenuToolbarItem {
                        menuItem.image = NSImage(
                            systemSymbolName: "plus",
                            accessibilityDescription: I18N.localized("添加")
                        )
                        menuItem.menu.items.first(where: { $0.action == #selector(doAddFeed) })?.title = I18N.localized("添加订阅")
                        menuItem.menu.items.first(where: { $0.action == #selector(doAddFolder) })?.title = I18N.localized("新建文件夹")
                        menuItem.menu.items.first(where: { $0.action == #selector(doImport) })?.title = I18N.localized("导入 OPML")
                        menuItem.menu.items.first(where: { $0.action == #selector(doExport) })?.title = I18N.localized("导出 OPML")
                    }
                case .paperMarkAllRead:
                    item.label = I18N.localized("全部已读")
                    item.paletteLabel = I18N.localized("全部标为已读")
                    item.toolTip = I18N.localized("将当前列表全部标为已读")
                    markAllReadButton?.image = NSImage(
                        systemSymbolName: "envelope.open",
                        accessibilityDescription: I18N.localized("全部已读")
                    )
                case .paperReaderCapsule:
                    item.label = I18N.localized("阅读工具")
                    item.paletteLabel = I18N.localized("阅读工具")
                    item.toolTip = I18N.localized("C 翻译 · V 摘要 · B 上一篇 · N 下一篇 · M 收藏")
                default:
                    break
                }
            }
        }

        /// 同步中间栏标题及全部已读按钮状态
        func syncHeaderState() {
            let isSidebarCollapsed = splitViewController?.splitViewItems.first?.isCollapsed ?? false
            
            if let label = titleLabel {
                label.isHidden = isSidebarCollapsed
                if isSidebarCollapsed {
                    label.stringValue = ""
                    label.frame = .zero
                } else {
                    if label.stringValue != actions.selectionTitle {
                        label.stringValue = actions.selectionTitle
                        label.sizeToFit()
                    }
                }
            }
            if #available(macOS 15.0, *) {
                entryListTitleItem?.isHidden = isSidebarCollapsed
            }
            if let button = markAllReadButton {
                button.isEnabled = actions.hasUnread
            }
        }

        /// 同步禅模式下工具栏其他按钮的显隐与原生居中对齐（借助 centeredItemIdentifier 强制让阅读胶囊位于窗口及内容正上方）
        func syncZenModeState() {
            guard let toolbar = splitViewController?.view.window?.toolbar else { return }
            let isZenMode = actions.isZenMode

            if #available(macOS 11.0, *) {
                toolbar.centeredItemIdentifier = isZenMode ? .paperReaderCapsule : nil
            }

            for item in toolbar.items {
                if item.itemIdentifier == .paperReaderCapsule {
                    if #available(macOS 15.0, *) {
                        item.isHidden = !actions.showsReaderCapsule
                    }
                    readerCapsuleHost?.isHidden = !actions.showsReaderCapsule
                } else {
                    if #available(macOS 15.0, *) {
                        item.isHidden = isZenMode
                    }
                    item.view?.isHidden = isZenMode
                }
            }

            if !isZenMode {
                syncHeaderState()
            }
        }

        // MARK: NSToolbarDelegate

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier id: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            switch id {
            // toggleSidebar 由系统自动创建，无需手动处理

            case .paperRefresh:
                let item = NSToolbarItem(itemIdentifier: .paperRefresh)
                item.label = I18N.localized("刷新")
                item.paletteLabel = I18N.localized("刷新所有订阅")
                item.toolTip = I18N.localized("刷新所有订阅")
                item.autovalidates = false // 关闭原生验证以防意外置灰
                
                // 固定按钮样式，永不改变以防止布局抖动
                let button = NSButton()
                button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: I18N.localized("刷新"))
                button.bezelStyle = .texturedRounded
                button.isBordered = true
                button.target = self
                button.action = #selector(doRefresh)
                
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isDisplayedWhenStopped = false
                spinner.translatesAutoresizingMaskIntoConstraints = false
                
                button.addSubview(spinner)
                NSLayoutConstraint.activate([
                    spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                    spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    spinner.widthAnchor.constraint(equalToConstant: 16),
                    spinner.heightAnchor.constraint(equalToConstant: 16)
                ])
                
                item.view = button
                self.refreshButton = button
                self.refreshSpinner = spinner
                self.refreshItem = item
                return item

            case .paperAddMenu:
                let item = NSMenuToolbarItem(itemIdentifier: .paperAddMenu)
                item.label = I18N.localized("添加")
                item.toolTip = I18N.localized("添加订阅或新建文件夹")
                item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: I18N.localized("添加"))
                item.isBordered = true
                let menu = NSMenu()
                let addFeed = NSMenuItem(title: I18N.localized("添加订阅"), action: #selector(doAddFeed), keyEquivalent: "")
                addFeed.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                addFeed.target = self
                let addFolder = NSMenuItem(title: I18N.localized("新建文件夹"), action: #selector(doAddFolder), keyEquivalent: "")
                addFolder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
                addFolder.target = self
                let importItem = NSMenuItem(title: I18N.localized("导入 OPML"), action: #selector(doImport), keyEquivalent: "")
                importItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
                importItem.target = self
                let exportItem = NSMenuItem(title: I18N.localized("导出 OPML"), action: #selector(doExport), keyEquivalent: "")
                exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
                exportItem.target = self
                menu.addItem(addFeed)
                menu.addItem(addFolder)
                menu.addItem(NSMenuItem.separator())
                menu.addItem(importItem)
                menu.addItem(exportItem)
                item.menu = menu
                return item

            case .paperSidebarTracker:
                guard let sv = splitViewController?.splitView else { return nil }
                return NSTrackingSeparatorToolbarItem(
                    identifier: .paperSidebarTracker,
                    splitView: sv,
                    dividerIndex: 0
                )

            case .paperEntryListTitle:
                let item = NSToolbarItem(itemIdentifier: .paperEntryListTitle)
                let isCollapsed = splitViewController?.splitViewItems.first?.isCollapsed ?? false
                if #available(macOS 15.0, *) {
                    item.isHidden = isCollapsed
                }
                let label = NSTextField(labelWithString: isCollapsed ? "" : actions.selectionTitle)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .labelColor
                label.isEditable = false
                label.isSelectable = false
                label.drawsBackground = false
                label.isBezeled = false
                label.isHidden = isCollapsed
                if isCollapsed {
                    label.frame = .zero
                }
                item.view = label
                self.titleLabel = label
                self.entryListTitleItem = item
                return item

            case .paperMarkAllRead:
                let item = NSToolbarItem(itemIdentifier: .paperMarkAllRead)
                item.label = I18N.localized("全部已读")
                item.paletteLabel = I18N.localized("全部标为已读")
                item.toolTip = I18N.localized("将当前列表全部标为已读")
                item.autovalidates = false
                
                let button = NSButton()
                button.image = NSImage(systemSymbolName: "envelope.open", accessibilityDescription: I18N.localized("全部已读"))
                button.bezelStyle = .texturedRounded
                button.isBordered = true
                button.target = self
                button.action = #selector(doMarkAllRead)
                button.isEnabled = actions.hasUnread
                
                item.view = button
                self.markAllReadButton = button
                return item

            case .paperTimelineTracker:
                guard let sv = splitViewController?.splitView else { return nil }
                return NSTrackingSeparatorToolbarItem(
                    identifier: .paperTimelineTracker,
                    splitView: sv,
                    dividerIndex: 1
                )

            case .paperReaderCapsule:
                let item = NSToolbarItem(itemIdentifier: .paperReaderCapsule)
                item.label = I18N.localized("阅读工具")
                item.paletteLabel = I18N.localized("阅读工具")
                item.toolTip = I18N.localized("C 翻译 · V 摘要 · B 上一篇 · N 下一篇 · M 收藏")
                item.autovalidates = false
                item.isEnabled = true
                if #available(macOS 15.0, *) {
                    item.isHidden = !actions.showsReaderCapsule
                }

                let host = NSHostingView(rootView: actions.readerCapsule)
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor.clear.cgColor
                host.translatesAutoresizingMaskIntoConstraints = false
                host.isHidden = !actions.showsReaderCapsule

                let size = host.fittingSize
                let width: CGFloat = actions.showsReaderCapsule ? (size.width > 0 ? size.width : 108) : 0
                let height: CGFloat = actions.showsReaderCapsule ? (size.height > 0 ? size.height : 28) : 0
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                
                let widthConstraint = host.widthAnchor.constraint(equalToConstant: width)
                let heightConstraint = host.heightAnchor.constraint(equalToConstant: height)
                NSLayoutConstraint.activate([widthConstraint, heightConstraint])

                item.view = host
                self.readerCapsuleItem = item
                self.readerCapsuleHost = host
                self.readerCapsuleWidthConstraint = widthConstraint
                self.readerCapsuleHeightConstraint = heightConstraint
                return item

            default:
                return nil
            }
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [
                // 侧边栏区域：红绿灯 → toggleSidebar → 刷新 → 添加
                .toggleSidebar,
                .paperRefresh,
                .paperAddMenu,
                // 分隔符跟踪第一个分割线（侧边栏 ↔ 文章列表）
                .paperSidebarTracker,
                // 中间栏区域：标题 + 弹簧 + 全部已读按钮
                .paperEntryListTitle,
                .flexibleSpace,
                .paperMarkAllRead,
                // 分隔符跟踪第二个分割线（文章列表 ↔ 详情）
                .paperTimelineTracker,
                // 详情栏区域：弹簧 + 阅读工具胶囊 + 弹簧（居中放置在最上方标题栏）
                .flexibleSpace,
                .paperReaderCapsule,
                .flexibleSpace,
            ]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        // MARK: 动作方法

        @objc private func doRefresh() { 
            // 阻断重复点击
            if actions.isRefreshing { return }
            actions.onRefresh() 
        }
        @objc private func doAddFeed() { actions.onAddFeed() }
        @objc private func doAddFolder() { actions.onAddFolder() }
        @objc private func doImport() { actions.onImport() }
        @objc private func doExport() { actions.onExport() }
        @objc private func doMarkAllRead() { actions.onMarkAllRead() }
    }

// MARK: - 自定义工具栏项标识

extension NSToolbarItem.Identifier {
    static let paperRefresh = NSToolbarItem.Identifier("com.paperrss.toolbar.refresh")
    static let paperAddMenu = NSToolbarItem.Identifier("com.paperrss.toolbar.addMenu")
    static let paperSidebarTracker = NSToolbarItem.Identifier("com.paperrss.toolbar.sidebarTracker")
    static let paperTimelineTracker = NSToolbarItem.Identifier("com.paperrss.toolbar.timelineTracker")
    static let paperEntryListTitle = NSToolbarItem.Identifier("com.paperrss.toolbar.entryListTitle")
    static let paperMarkAllRead = NSToolbarItem.Identifier("com.paperrss.toolbar.markAllRead")
    static let paperReaderCapsule = NSToolbarItem.Identifier("com.paperrss.toolbar.readerCapsule")
}

@MainActor
final class PaperSplitViewController: NSSplitViewController {
    var onLayout: (() -> Void)?
    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?()
    }
}
#endif
