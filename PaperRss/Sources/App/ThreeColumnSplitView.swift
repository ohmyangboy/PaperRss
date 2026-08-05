#if os(macOS)
import SwiftUI
import AppKit

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
    let showsReaderCapsule: Bool
    let readerCapsule: AnyView

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
        showsReaderCapsule: Bool = false,
        readerCapsule: AnyView = AnyView(EmptyView())
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
        self.showsReaderCapsule = showsReaderCapsule
        self.readerCapsule = readerCapsule
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
        let splitVC = NSSplitViewController()

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
            if let window = view.window, let coord = coordinator, !coord.toolbarConfigured {
                coord.configureToolbar(on: window, splitView: splitVC.splitView)
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
        context.coordinator.syncRefreshState()
        context.coordinator.syncHeaderState()

        // 更新工具栏中的阅读工具胶囊(SwiftUI 状态变化后刷新图标/可用态与显示隐藏)
        if let host = context.coordinator.readerCapsuleHost {
            if toolbarActions.showsReaderCapsule {
                host.isHidden = false
                if #available(macOS 15.0, *) {
                    context.coordinator.readerCapsuleItem?.isHidden = false
                }
                host.rootView = toolbarActions.readerCapsule
                let size = host.fittingSize
                let width = size.width > 0 ? size.width : 108
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

    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate {
        var actions: ToolbarActions
        weak var splitViewController: NSSplitViewController?
        var toolbarConfigured = false
        var windowObservation: NSKeyValueObservation?
        private weak var refreshItem: NSToolbarItem?
        private weak var refreshButton: NSButton?
        private weak var refreshSpinner: NSProgressIndicator?
        fileprivate weak var readerCapsuleItem: NSToolbarItem?
        fileprivate weak var readerCapsuleHost: NSHostingView<AnyView>?
        fileprivate weak var readerCapsuleWidthConstraint: NSLayoutConstraint?
        fileprivate weak var readerCapsuleHeightConstraint: NSLayoutConstraint?
        private weak var titleLabel: NSTextField?
        private weak var markAllReadButton: NSButton?

        init(actions: ToolbarActions) {
            self.actions = actions
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
                    self?.removeTitlebarBlur(from: window)
                }
            }
            toolbarConfigured = true
        }

        private func removeTitlebarBlur(from window: NSWindow) {
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
                for subview in view.subviews {
                    if let effectView = subview as? NSVisualEffectView {
                        effectView.isHidden = true
                        effectView.state = .inactive
                        effectView.alphaValue = 0
                    }
                    hideVisualEffects(in: subview)
                }
            }

            for subview in themeFrame.subviews {
                if subview !== window.contentView {
                    hideVisualEffects(in: subview)
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
                button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
            }
        }

        /// 同步中间栏标题及全部已读按钮状态
        func syncHeaderState() {
            if let label = titleLabel, label.stringValue != actions.selectionTitle {
                label.stringValue = actions.selectionTitle
                label.sizeToFit()
            }
            if let button = markAllReadButton {
                button.isEnabled = actions.hasUnread
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
                item.label = "刷新"
                item.paletteLabel = "刷新所有订阅"
                item.toolTip = "刷新所有订阅"
                item.autovalidates = false // 关闭原生验证以防意外置灰
                
                // 固定按钮样式，永不改变以防止布局抖动
                let button = NSButton()
                button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
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
                item.label = "添加"
                item.toolTip = "添加订阅或新建文件夹"
                item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")
                item.isBordered = true
                let menu = NSMenu()
                let addFeed = NSMenuItem(title: "添加订阅", action: #selector(doAddFeed), keyEquivalent: "")
                addFeed.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                addFeed.target = self
                let addFolder = NSMenuItem(title: "新建文件夹", action: #selector(doAddFolder), keyEquivalent: "")
                addFolder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
                addFolder.target = self
                let importItem = NSMenuItem(title: "导入 OPML", action: #selector(doImport), keyEquivalent: "")
                importItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
                importItem.target = self
                let exportItem = NSMenuItem(title: "导出 OPML", action: #selector(doExport), keyEquivalent: "")
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
                let label = NSTextField(labelWithString: actions.selectionTitle)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .labelColor
                label.isEditable = false
                label.isSelectable = false
                label.drawsBackground = false
                label.isBezeled = false
                item.view = label
                self.titleLabel = label
                return item

            case .paperMarkAllRead:
                let item = NSToolbarItem(itemIdentifier: .paperMarkAllRead)
                item.label = "全部已读"
                item.paletteLabel = "全部标为已读"
                item.toolTip = "将当前列表全部标为已读"
                item.autovalidates = false
                
                let button = NSButton()
                button.image = NSImage(systemSymbolName: "envelope.open", accessibilityDescription: "全部已读")
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
                item.label = "阅读工具"
                item.paletteLabel = "阅读工具"
                item.toolTip = "翻译、已读与收藏"
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
#endif

