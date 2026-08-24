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
        splitVC.onLayout = { [weak coordinator = context.coordinator, weak splitVC] in
            MainActor.assumeIsolated {
                guard let window = splitVC?.view.window else { return }
                coordinator?.layoutDidChange(for: window)
            }
        }

        // 侧边栏 — 使用 sidebarWithViewController 声明 sidebar 身份并挂载独立浮层滚动条
        let sidebarContainer = PaperColumnContainerController(rootView: sidebar)
        sidebarContainer.view.wantsLayer = true
        sidebarContainer.view.clipsToBounds = true
        sidebarContainer.view.layer?.masksToBounds = true
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarContainer)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true

        // 文章列表 — 使用 contentListWithViewController 声明 content list 身份并挂载独立浮层滚动条
        let contentContainer = PaperColumnContainerController(rootView: content)
        contentContainer.view.wantsLayer = true
        contentContainer.view.clipsToBounds = true
        contentContainer.view.layer?.masksToBounds = true
        let contentItem = NSSplitViewItem(contentListWithViewController: contentContainer)
        contentItem.minimumThickness = 280

        // 文章详情 (Reader 隔离：保持原有 NSHostingController，不受浮层滚动条影响)
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
                if let coord = coordinator, view.window != nil, !coord.didInitializeFocus {
                    coord.didInitializeFocus = true
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            coord.setActiveColumn(1, autoSelect: false)
                        }
                    }
                }
            }
        }

        context.coordinator.sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak coordinator = context.coordinator] _, _ in
            MainActor.assumeIsolated {
                coordinator?.syncHeaderState()
                coordinator?.reconcileActiveColumnAfterCollapse()
            }
        }

        return splitVC
    }

    func updateNSViewController(_ splitVC: NSSplitViewController, context: Context) {
        // 更新工具栏动作状态
        context.coordinator.actions = toolbarActions

        // 更新三栏的 SwiftUI 内容
        if let host = splitVC.splitViewItems[0].viewController as? PaperColumnContainerController<Sidebar> {
            host.rootView = sidebar
        }
        if let host = splitVC.splitViewItems[1].viewController as? PaperColumnContainerController<Content> {
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
        context.coordinator.reconcileActiveColumnAfterCollapse()

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
        nonisolated(unsafe) static weak var current: ThreeColumnSplitViewCoordinator?
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
        nonisolated(unsafe) private var fullScreenChromeTimer: DispatchSourceTimer?
        private(set) var activeColumnIndex: Int = 1
        var didInitializeFocus = false
        init(actions: ToolbarActions) {
            self.actions = actions
            super.init()
            setupLocalKeyMonitor()
            setupMouseDownMonitor()
            ThreeColumnSplitViewCoordinator.current = self
        }

        deinit {
            if ThreeColumnSplitViewCoordinator.current === self {
                ThreeColumnSplitViewCoordinator.current = nil
            }
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = mouseDownMonitor {
                NSEvent.removeMonitor(monitor)
            }
            fullScreenChromeTimer?.cancel()
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
                
                // 左/右方向键 (keyCode 123 左, 124 右)。
                // 注意：macOS 方向键事件自带 .numericPad（箭头属小键盘区），可能还带 .function，
                // 不能以 flags.isEmpty 判断"无修饰键"，否则左右键永远进不来。
                let navDisallowed: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
                if (event.keyCode == 123 || event.keyCode == 124)
                    && flags.intersection(navDisallowed).isEmpty {
                    let handled = MainActor.assumeIsolated { () -> Bool in
                        guard let splitVC = self.splitViewController,
                              splitVC.splitViewItems.count >= 3,
                              let window = splitVC.view.window,
                              (event.window ?? NSApp.keyWindow) === window,
                              window.attachedSheet == nil,
                              NSApp.modalWindow == nil else {
                        return false
                    }

                        if let firstResponder = window.firstResponder as? NSView,
                           firstResponder is NSTextView || firstResponder is NSTextField {
                            return false
                        }

                        let direction = event.keyCode == 124 ? 1 : -1
                        guard let next = self.nextVisibleColumnIndex(
                            from: self.activeColumnIndex,
                            direction: direction,
                            in: splitVC
                        ) else { return true } // 边缘或单可见栏：消费为 no-op

                        self.setActiveColumn(next)
                        return true
                    }
                    if handled { return nil }
                    return event
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
                        self.setActiveColumn(2, makeFirstResponder: false)
                        self.actions.onFocusAndScrollArticle()
                    }
                    return nil
                }

                if let detailVCView, firstResponder.isDescendant(of: detailVCView) {
                    MainActor.assumeIsolated {
                        self.setActiveColumn(2, makeFirstResponder: false)
                    }
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

        /// 设置活动栏：更新状态，必要时把 first responder 移到该栏的焦点目标，
        /// 进入文章列表且无选中时自动选中第一篇。
        @MainActor
        func setActiveColumn(_ index: Int, makeFirstResponder: Bool = true, autoSelect: Bool = true) {
            guard let splitVC = splitViewController,
                  splitVC.splitViewItems.indices.contains(index),
                  !splitVC.splitViewItems[index].isCollapsed else { return }
            activeColumnIndex = index

            if makeFirstResponder, let window = splitVC.view.window ?? NSApp.keyWindow {
                let targetContainer = splitVC.splitViewItems[index].viewController.view
                let targetView = findFocusTarget(in: targetContainer)
                if window.firstResponder !== targetView {
                    window.makeFirstResponder(targetView)
                }
            }

            if index == 1 && autoSelect {
                actions.onSelectFirstEntryIfNeeded()
            }
        }

        /// 从 current 沿 direction（±1）找到下一个未折叠的栏；返回 nil 表示边缘或无可移动栏。
        @MainActor
        private func nextVisibleColumnIndex(
            from current: Int,
            direction: Int,
            in splitVC: NSSplitViewController
        ) -> Int? {
            guard splitVC.splitViewItems.indices.contains(current) else { return nil }
            var i = current + direction
            while splitVC.splitViewItems.indices.contains(i) {
                if !splitVC.splitViewItems[i].isCollapsed {
                    return i
                }
                i += direction
            }
            return nil
        }

        /// 活动栏被折叠（如禅模式）时，吸附到最近的可见栏。
        @MainActor
        func reconcileActiveColumnAfterCollapse() {
            guard let splitVC = splitViewController,
                  splitVC.splitViewItems.indices.contains(activeColumnIndex),
                  splitVC.splitViewItems[activeColumnIndex].isCollapsed else { return }
            for i in (activeColumnIndex + 1)..<splitVC.splitViewItems.count
            where !splitVC.splitViewItems[i].isCollapsed {
                activeColumnIndex = i
                return
            }
            for i in stride(from: activeColumnIndex - 1, through: 0, by: -1)
            where !splitVC.splitViewItems[i].isCollapsed {
                activeColumnIndex = i
                return
            }
        }

        private enum ColumnClickOutcome {
            case activate(Int)   // 栏 0/1：激活并 makeFirstResponder
            case trackReader     // 栏 2：仅记录状态，WebKit 自管焦点
            case ignore          // 交互控件 / 不在任何可见栏内
        }

        /// 判断一次点击应如何影响活动栏。themeFrame = window.contentView?.superview，
        /// 与 removeTitlebarBlur 使用同一坐标系。
        @MainActor
        private func columnClickOutcome(at locationInWindow: CGPoint) -> ColumnClickOutcome {
            guard let splitVC = splitViewController,
                  let window = splitVC.view.window ?? NSApp.keyWindow,
                  let themeFrame = window.contentView?.superview else { return .ignore }

            let point = themeFrame.convert(locationInWindow, from: nil)
            guard let topView = themeFrame.hitTest(point) else { return .ignore }

            let columns: [(index: Int, view: NSView)] =
                splitVC.splitViewItems.enumerated().compactMap { i, item in
                    guard !item.isCollapsed else { return nil }
                    return (i, item.viewController.view)
                }

            var v: NSView? = topView
            while let view = v {
                if view is WKWebView { return .trackReader }
                if view is NSScroller || view is NSTextView { return .ignore }
                if view is NSTableView || view is NSOutlineView {
                    // 表格即焦点目标，继续上溯到栏容器
                } else if view is NSControl {
                    return .ignore
                }
                if let col = columns.first(where: { $0.view === view }) {
                    return col.index == 2 ? .trackReader : .activate(col.index)
                }
                v = view.superview
            }
            return .ignore
        }

        /// 判断鼠标点击位置是否处于顶部标题栏/工具栏的空白可拖拽区域。
        /// 确保在排除红绿灯、阅读胶囊、刷新按钮等交互控件后，允许用户在三栏顶部任意空白处按住拖动窗口。
        @MainActor
        private func isTitlebarDraggableArea(at locationInWindow: CGPoint, in window: NSWindow) -> Bool {
            guard !window.styleMask.contains(.fullScreen) else { return false }
            guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }

            guard let contentView = window.contentView else { return false }
            let windowHeight = contentView.bounds.height
            let titlebarHeight: CGFloat = contentView.safeAreaInsets.top > 0 ? contentView.safeAreaInsets.top : 52

            guard locationInWindow.y >= (windowHeight - titlebarHeight) && locationInWindow.y <= windowHeight else {
                return false
            }

            // 1. 排除系统红绿灯按钮
            let standardButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for buttonType in standardButtons {
                if let button = window.standardWindowButton(buttonType), !button.isHidden {
                    let rectInWindow = button.convert(button.bounds, to: nil)
                    if rectInWindow.contains(locationInWindow) {
                        return false
                    }
                }
            }

            // 2. 排除阅读工具胶囊 (ReaderCapsule)
            if let capsuleHost = readerCapsuleHost, !capsuleHost.isHidden, capsuleHost.window === window {
                let capsuleRect = capsuleHost.convert(capsuleHost.bounds, to: nil)
                if capsuleRect.contains(locationInWindow) {
                    return false
                }
            }

            // 3. 排除已知交互按钮
            if let refreshButton, !refreshButton.isHidden, refreshButton.window === window {
                let rect = refreshButton.convert(refreshButton.bounds, to: nil)
                if rect.contains(locationInWindow) {
                    return false
                }
            }
            if let markAllReadButton, !markAllReadButton.isHidden, markAllReadButton.window === window {
                let rect = markAllReadButton.convert(markAllReadButton.bounds, to: nil)
                if rect.contains(locationInWindow) {
                    return false
                }
            }

            // 4. 排除命中的所有 NSControl、NSTextView、NSScroller 交互控件
            if let themeFrame = contentView.superview {
                let point = themeFrame.convert(locationInWindow, from: nil)
                if let hitView = themeFrame.hitTest(point) {
                    var v: NSView? = hitView
                    while let view = v {
                        if view is NSControl || view is NSTextView || view is NSScroller {
                            return false
                        }
                        v = view.superview
                    }
                }
            }

            return true
        }

        /// 处理双击顶部标题栏的 macOS 系统偏好行为（缩放/最大化或最小化窗口）
        @MainActor
        private func handleTitlebarDoubleClick(on window: NSWindow) {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize":
                window.miniaturize(nil)
            case "None":
                break
            default:
                window.zoom(nil)
            }
        }

        /// 鼠标点击监控：
        /// 1. 激活栏：点击栏内任意位置 → 该栏 first responder，选中行立即变绿。
        /// 2. 顶部空白拖拽：点击在三栏顶部标题栏/工具栏空白区域时，调用 performWindowDrag 拖动窗口，并支持双击缩放。
        private func setupMouseDownMonitor() {
            guard mouseDownMonitor == nil else { return }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self else { return event }
                guard let window = MainActor.assumeIsolated({ self.splitViewController?.view.window ?? NSApp.keyWindow }),
                      (event.window ?? NSApp.keyWindow) === window,
                      window.attachedSheet == nil,
                      NSApp.modalWindow == nil else { return event }

                let outcome = MainActor.assumeIsolated({ self.columnClickOutcome(at: event.locationInWindow) })
                switch outcome {
                case .activate(let col):
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.setActiveColumn(col, autoSelect: false) }
                    }
                case .trackReader:
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.setActiveColumn(2, makeFirstResponder: false) }
                    }
                case .ignore:
                    break
                }

                let isDraggable = MainActor.assumeIsolated({
                    self.isTitlebarDraggableArea(at: event.locationInWindow, in: window)
                })

                if isDraggable {
                    if event.clickCount == 1 {
                        window.performDrag(with: event)
                        return nil
                    } else if event.clickCount == 2 {
                        MainActor.assumeIsolated {
                            self.handleTitlebarDoubleClick(on: window)
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
            
            reconcileWindowChrome(for: window)
            DispatchQueue.main.async { [weak self, weak window] in
                if let window {
                    MainActor.assumeIsolated {
                        self?.reconcileWindowChrome(for: window)
                    }
                }
            }

            let center = NotificationCenter.default
            // 事件驱动重同步：全屏进出 + 遮挡状态变化（覆盖切换 Space、睡眠唤醒、
            // 折叠侧边栏时系统重建全屏辅助窗口的场景）。
            // 注意：不要监听 didUpdateNotification 等高频通知并在其中遍历视图树——
            // 全屏期间这些通知每帧触发，会造成滚动卡顿。
            let chromeNotifications: [Notification.Name] = [
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willExitFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ]
            for name in chromeNotifications {
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] note in
                    guard let window = window else { return }
                    let name = note.name
                    MainActor.assumeIsolated {
                        switch name {
                        case NSWindow.willEnterFullScreenNotification:
                            self?.beginFullScreenChromeTracking(for: window)
                        case NSWindow.didExitFullScreenNotification, NSWindow.willExitFullScreenNotification:
                            self?.stopFullScreenChromeTracking()
                            self?.removePaperOverlays(around: window)
                            self?.syncMainWindowTitlebarBackground(for: window)
                        default:
                            self?.scheduleFullScreenChromeSync(for: window)
                        }
                    }
                }
            }

            toolbarConfigured = true
        }

        /// 进入全屏动画一开始就开启高频（8ms）有界监听，抢在辅助窗口首个白色
        /// 绘制帧之前插入背板。背板一旦就位立即停止；最多持续 ~1.2s 兜底。
        private func beginFullScreenChromeTracking(for window: NSWindow) {
            reconcileWindowChrome(for: window)
            fullScreenChromeTimer?.cancel()
            var remaining = 150
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8))
            timer.setEventHandler { [weak self, weak window] in
                guard let self, let window else {
                    timer.cancel()
                    return
                }
                if self.companionOverlayInstalled(around: window) {
                    timer.cancel()
                    self.fullScreenChromeTimer = nil
                    return
                }
                MainActor.assumeIsolated {
                    self.reconcileWindowChrome(for: window)
                }
                remaining -= 1
                if remaining <= 0 {
                    timer.cancel()
                    self.fullScreenChromeTimer = nil
                }
            }
            timer.resume()
            fullScreenChromeTimer = timer
        }

        private func stopFullScreenChromeTracking() {
            fullScreenChromeTimer?.cancel()
            fullScreenChromeTimer = nil
        }

        /// 任一辅助窗口的标题栏容器内已插入背板即视为就位。
        private func companionOverlayInstalled(around mainWindow: NSWindow) -> Bool {
            for companion in fullScreenCompanionWindows(of: mainWindow) {
                guard let contentView = companion.contentView else { continue }
                var themeFrame: NSView = contentView
                while let superview = themeFrame.superview { themeFrame = superview }
                guard let container = firstDescendant(of: themeFrame, className: "NSTitlebarContainerView") else { continue }
                if container.subviews.contains(where: { $0 is PaperChromeBackdropView }) { return true }
            }
            return false
        }

        /// 全屏工具栏辅助窗口由 AppKit 异步创建，且会被系统随时重建
        /// （见 Ghostty #9600 分析）。这里用「即时同步 + 进入全屏后有限次延迟补偿」
        /// 覆盖重建时机。退出全屏时清理背板防止残留。
        private func scheduleFullScreenChromeSync(for window: NSWindow) {
            reconcileWindowChrome(for: window)
            if window.styleMask.contains(.fullScreen) {
                // 密集的早期补偿，配合 viewDidLayout 钩子把背板在首个白条帧前就位
                for delay in [0.05, 0.15, 0.35, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                        guard let window else { return }
                        MainActor.assumeIsolated {
                            self?.reconcileWindowChrome(for: window)
                        }
                    }
                }
            } else {
                removePaperOverlays(around: window)
                syncMainWindowTitlebarBackground(for: window)
            }
        }

        /// 进入/处于全屏期间的分割视图布局会持续触发，正是辅助窗口被创建并布局的
        /// 第一时间。在这里做“只针对辅助窗口”的轻量同步（不碰主窗口），让背板在
        /// 白条首个绘制帧之前就位，消除闪现。窗口模式下此钩子直接返回，零开销。
        func layoutDidChange(for window: NSWindow) {
            guard window.styleMask.contains(.fullScreen) else { return }
            hideMainWindowTitlebarBackground(window)
            for companion in fullScreenCompanionWindows(of: window) {
                neutralizeFullScreenCompanion(companion)
            }
        }

        /// 主窗口标题栏 chrome（透明、纸张底色）+ 中和全屏辅助窗口的白条背景。
        /// 进入全屏时额外隐藏主窗口自身的 NSTitlebarBackgroundView，消除进入动画
        /// 初始瞬间（辅助窗口尚未覆盖时）露出的白色条带。
        fileprivate func reconcileWindowChrome(for window: NSWindow) {
            applyMainWindowChrome(window)
            syncMainWindowTitlebarBackground(for: window)
            for companion in fullScreenCompanionWindows(of: window) {
                neutralizeFullScreenCompanion(companion)
            }
        }

        /// 主窗口自身的标题栏容器定位：contentView 上溯到 themeFrame，再找标题栏容器。
        private func titlebarContainer(in window: NSWindow) -> NSView? {
            guard let contentView = window.contentView else { return nil }
            var themeFrame: NSView = contentView
            while let superview = themeFrame.superview { themeFrame = superview }
            return firstDescendant(of: themeFrame, className: "NSTitlebarContainerView")
        }

        /// 只切换主窗口标题栏背景这一棵叶子视图的显隐。
        /// NSTitlebarBackgroundView 纯背景、不含任何按钮；隐藏它让纸张色窗口底色透出，
        /// 消除进入全屏瞬间的白色闪现。绝不触碰工具栏按钮宿主或其它视图，
        /// 因此不会造成此前“工具栏消失”的回归。
        private func hideMainWindowTitlebarBackground(_ window: NSWindow) {
            guard let container = titlebarContainer(in: window) else { return }
            firstDescendant(of: container, className: "NSTitlebarBackgroundView")?.isHidden = true
        }

        private func restoreMainWindowTitlebarBackground(_ window: NSWindow) {
            guard let container = titlebarContainer(in: window) else { return }
            firstDescendant(of: container, className: "NSTitlebarBackgroundView")?.isHidden = false
        }

        /// 全屏始终隐藏系统白色背景；窗口态仅在 macOS 14–25 隐藏纯背景叶子，
        /// 让 Paper 窗口底色透出。macOS 26+ 恢复背景叶子，由逐控件玻璃路径处理。
        private func syncMainWindowTitlebarBackground(for window: NSWindow) {
            if window.styleMask.contains(.fullScreen) {
                hideMainWindowTitlebarBackground(window)
            } else if #available(macOS 26.0, *) {
                restoreMainWindowTitlebarBackground(window)
            } else {
                hideMainWindowTitlebarBackground(window)
            }
        }

        private func applyMainWindowChrome(_ window: NSWindow) {
            if #available(macOS 26.0, *) {
                applyLiquidGlassWindowChrome(window)
            } else {
                applyLegacyPaperNavbarChrome(window)
            }

            // 窗口背景不能保持透明:透明会让 NSSplitView 的分割线矩形
            // (约 1pt 宽,位于列表栏与阅读器栏之间)直接透出窗口背后的内容,
            // 在阅读器左缘形成一条可见缝隙。三个栏目的 PaperSurface 已覆盖
            // 全部内容区域,这里用纸张色填满分割线即可;动态颜色跟随明暗外观切换。
            window.backgroundColor = NSColor(name: nil) { appearance in
                let scheme: ColorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
                return NSColor(PaperTheme.surface(.page, scheme: scheme))
            }
            window.isOpaque = true
        }

        /// Tahoe 及后续系统由 AppKit 为工具栏控件提供 Liquid Glass。
        /// 保持纸张延伸到标题栏，并只移除旧式整栏模糊层，避免双重材质。
        private func applyLiquidGlassWindowChrome(_ window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none

            // 主窗口：仅隐去标题栏/工具栏容器中的 NSVisualEffectView，保留 contentView (应用内容)
            if let themeFrame = window.contentView?.superview {
                for subview in themeFrame.subviews where subview !== window.contentView {
                    hideVisualEffects(in: subview)
                }
            }
        }

        /// macOS 14–25 没有逐控件 Liquid Glass。顶部 navbar 不使用系统整栏
        /// 灰色材质，改为透出窗口的 Paper 页面色，保持三栏纸张背景连续。
        private func applyLegacyPaperNavbarChrome(_ window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }

        /// 找出主窗口的全屏工具栏辅助窗口。
        /// 判定链（参照 macterm PR #59 / Ghostty TerminalWindow.titlebarContainer 的成熟做法）：
        /// childWindows → titlebarAccessoryViewControllers 所在窗口 → 遍历 NSApp.windows，
        /// 类名精确匹配 NSToolbarFullScreenWindow，并以 parent/child/同屏/frame 相交校验归属，
        /// 保证多显示器、多全屏窗口时不误伤其他空间的辅助窗口。
        private func fullScreenCompanionWindows(of mainWindow: NSWindow) -> [NSWindow] {
            var candidates: [NSWindow] = []
            if let children = mainWindow.childWindows {
                candidates.append(contentsOf: children)
            }
            for accessory in mainWindow.titlebarAccessoryViewControllers {
                if let accessoryWindow = accessory.view.window {
                    candidates.append(accessoryWindow)
                }
            }
            candidates.append(contentsOf: NSApp.windows)

            var seen = Set<ObjectIdentifier>()
            return candidates.filter { candidate in
                guard candidate !== mainWindow else { return false }
                guard Self.isFullScreenToolbarWindow(candidate) else { return false }
                guard seen.insert(ObjectIdentifier(candidate)).inserted else { return false }
                return isFullScreenCompanion(candidate, of: mainWindow)
            }
        }

        /// 类名匹配：精确名为主，特征匹配（Toolbar + Full）兜底 macOS 版本差异；
        /// 误伤由 isFullScreenCompanion 的 parent/child/同屏/frame 归属校验兜底。
        nonisolated private static func isFullScreenToolbarWindow(_ window: NSWindow) -> Bool {
            let name = String(describing: type(of: window))
            if name == "NSToolbarFullScreenWindow" || name == "NSToolbarFullscreenWindow" {
                return true
            }
            return name.contains("Toolbar") && name.contains("Full")
        }

        private func isFullScreenCompanion(_ candidate: NSWindow, of mainWindow: NSWindow) -> Bool {
            if candidate.parent === mainWindow { return true }
            if mainWindow.childWindows?.contains(where: { $0 === candidate }) == true { return true }
            if let screen = mainWindow.screen, let candidateScreen = candidate.screen {
                return screen === candidateScreen
            }
            if let screen = mainWindow.screen {
                return candidate.frame.intersects(screen.frame)
            }
            if let candidateScreen = candidate.screen {
                return mainWindow.frame.intersects(candidateScreen.frame)
            }
            return candidate.frame.intersects(mainWindow.frame)
        }

        /// 全屏白条只改颜色、不做隐藏（实机验证过的安全策略）：
        /// 1. 辅助窗口底色设为纸张色并声明不透明——覆盖窗口级白底；
        /// 2. 在标题栏容器的白色背景视图之上、按钮宿主之下插入纸张色背板——
        ///    覆盖 NSTitlebarBackgroundView 的白色绘制，且不隐藏、不遮挡任何系统视图；
        /// 3. 仅缺失两个锚点之一时安全跳过：最坏情况白条保留，绝不影响按钮。
        private func neutralizeFullScreenCompanion(_ window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(name: nil) { appearance in
                let scheme: ColorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
                return NSColor(PaperTheme.surface(.page, scheme: scheme))
            }
            window.isOpaque = true

            guard let contentView = window.contentView else { return }
            var themeFrame: NSView = contentView
            while let superview = themeFrame.superview { themeFrame = superview }
            // 只隐藏辅助窗口内的模糊材质（玻璃效果），不触碰任何按钮宿主
            hideVisualEffects(in: themeFrame)

            guard let container = firstDescendant(of: themeFrame, className: "NSTitlebarContainerView") else { return }
            installPaperOverlay(in: container)
        }

        private func installPaperOverlay(in container: NSView) {
            let titlebarView = firstDescendant(of: container, className: "NSTitlebarView")
            let backgroundView = firstDescendant(of: container, className: "NSTitlebarBackgroundView")

            // 已存在：仅在下一次同步时强制维持正确层级（AppKit 动画期间可能重排）
            if let existing = container.subviews.first(where: { $0 is PaperChromeBackdropView }) {
                if let titlebarView {
                    container.addSubview(existing, positioned: .below, relativeTo: titlebarView)
                } else if let backgroundView {
                    container.addSubview(existing, positioned: .above, relativeTo: backgroundView)
                }
                return
            }

            let overlay = PaperChromeBackdropView(frame: container.bounds)
            overlay.autoresizingMask = [.width, .height]

            if let titlebarView {
                // 首选：置于按钮宿主之下（背景视图是更早的兄弟，自然被覆盖）
                container.addSubview(overlay, positioned: .below, relativeTo: titlebarView)
            } else if let backgroundView {
                // 兜底：背景视图之上
                container.addSubview(overlay, positioned: .above, relativeTo: backgroundView)
            } else {
                // 两个锚点都找不到：不插入任何视图，保持现状
                return
            }
        }

        /// 退出全屏后清理背板，防止容器迁移到主窗口时残留。
        private func removePaperOverlays(around mainWindow: NSWindow) {
            var roots: [NSView] = []
            if let contentView = mainWindow.contentView {
                var themeFrame: NSView = contentView
                while let superview = themeFrame.superview { themeFrame = superview }
                roots.append(themeFrame)
            }
            for candidate in NSApp.windows {
                guard let contentView = candidate.contentView else { continue }
                var themeFrame: NSView = contentView
                while let superview = themeFrame.superview { themeFrame = superview }
                roots.append(themeFrame)
            }
            for root in roots {
                removePaperOverlaysRecursively(in: root)
            }
        }

        private func removePaperOverlaysRecursively(in view: NSView) {
            for subview in Array(view.subviews) {
                if subview is PaperChromeBackdropView {
                    subview.removeFromSuperview()
                } else {
                    removePaperOverlaysRecursively(in: subview)
                }
            }
        }

        private func firstDescendant(of view: NSView, className: String) -> NSView? {
            if String(describing: type(of: view)) == className { return view }
            for subview in view.subviews {
                if let found = firstDescendant(of: subview, className: className) {
                    return found
                }
            }
            return nil
        }

        private func hideVisualEffects(in view: NSView) {
            if let effectView = view as? NSVisualEffectView {
                effectView.isHidden = true
                effectView.state = .inactive
                effectView.alphaValue = 0
            }
            for subview in view.subviews {
                hideVisualEffects(in: subview)
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

/// 全屏工具栏辅助窗口内的纸张色背板。
/// 只做两件事：以页面背景色填充、跟随明暗外观刷新；不参与命中测试，绝不遮挡按钮。
@MainActor
final class PaperChromeBackdropView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        updateBackdropColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackdropColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateBackdropColor() {
        let scheme: ColorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor(PaperTheme.surface(.page, scheme: scheme)).cgColor
        CATransaction.commit()
    }
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
