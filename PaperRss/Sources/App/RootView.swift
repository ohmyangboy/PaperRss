import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import WebKit
#elseif os(iOS)
import UIKit
#endif
#if SWIFT_PACKAGE
import PaperRssCore
#endif

enum SidebarSelection: Hashable {
    case today
    case unread
    case starred
    case folder(accountID: String, folderName: String)
    case feed(UUID)
    case feeds(Set<UUID>)

    @MainActor
    var title: String {
        switch self {
        case .today: I18N.shared.localized("今天")
        case .unread: I18N.shared.localized("未读")
        case .starred: I18N.shared.localized("收藏")
        case let .folder(_, name): name
        case .feed: I18N.shared.localized("订阅")
        case let .feeds(ids): I18N.shared.localizedFormat("%lld 个订阅", ids.count)
        }
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var navigation: AppNavigationModel
    @State private var selection: SidebarSelection? = .today
    // Keep selection independent from the value-semantic Entry model. Reading an
    // item updates its `isRead` / `updatedAt` fields, which used to invalidate the
    // List's synthesized Hashable selection after the first click. A stable ID
    // makes selection, focus, and the visible detail all describe the same item.
    @State private var selectedEntryID: String?
    @State private var retainedEntryListIDs: Set<String> = []
    @State private var selectedFeedIDs: Set<UUID> = []
    @State private var showsAddFeed = false
    @State private var showsAddFolder = false
    @State private var renamingFolder: String? = nil
    @State private var showsSettings = false
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var isZenMode = false
    @State private var autoScrollTrigger = UUID()
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var navigationConfirmation = ReaderNavigationConfirmation()
    @State private var navigationConfirmationExpiryTask: Task<Void, Never>?
    @State private var readerShortcutInvocation: ReaderShortcutInvocation?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        mainContent
            .tint(PaperTheme.accent)
            .accentColor(PaperTheme.accent)
            .preferredColorScheme(store.appTheme.colorScheme)
            .environmentObject(store.iconStore)
            .task {
                #if os(iOS)
                BackgroundRefresh.schedule(interval: store.refreshInterval)
                #endif
                // 启动定时刷新循环。首刷与 interval 循环都在 AppStore 内
                // 处理，并尊重"启动时刷新"开关——此前 startAutomaticRefresh
                // 从未被调用，设置里的刷新间隔选项完全不生效。
                store.startAutomaticRefresh()
                // 冷启动图标预热：等懒行渲染时已是内存/磁盘命中，首帧即图。
                store.iconStore.warmUp(feeds: store.feeds)
            }
            .onChange(of: store.feeds) { _, feeds in
                // 订阅列表变化（同步、增删源）后重新预热，覆盖新增 feed。
                store.iconStore.warmUp(feeds: feeds)
            }
            .onReceive(navigation.$request.compactMap { $0 }) { request in
                guard request.destination == .unread else { return }
                cancelNavigationConfirmation(dismissToast: true)
                selection = .unread
                selectedEntryID = nil
                retainedEntryListIDs.removeAll()
                autoScrollTrigger = UUID()
            }
            .onChange(of: isZenMode) { _, newZenMode in
                if newZenMode {
                    showToast(I18N.shared.localized("ESC退出，按下 ⌘/ 查看快捷键"))
                }
            }
            .onChange(of: selectedEntryID) { oldID, newID in
                if oldID != newID {
                    cancelNavigationConfirmation(dismissToast: true)
                }
                if let newID {
                    scheduleNeighborPrefetch(from: newID)
                }
            }
            .sheet(isPresented: $showsAddFeed) { AddFeedSheet(store: store) }
            .sheet(isPresented: $showsAddFolder) { AddFolderSheet(store: store) }
            .sheet(item: Binding(
                get: { renamingFolder.map { FolderIdentifiable(name: $0) } },
                set: { renamingFolder = $0?.name }
            )) { folder in
                RenameFolderSheet(store: store, oldName: folder.name) { newName in
                    // 重命名当前选中的文件夹后，侧栏选择与中间栏内容应跟随，
                    // 否则高亮消失、文章列表显示"没有文章"。
                    if case let .folder(acc, current) = selection, acc == "local-default" && current == folder.name {
                        selection = .folder(accountID: "local-default", folderName: newName)
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showsSettings) { NavigationStack { SettingsView(store: store).navigationTitle(I18N.localized("设置")) } }
            #endif
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: OPMLDocument.readableContentTypes) { result in
                guard case let .success(url) = result else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                Task { await store.importOPML(data) }
            }
            .fileExporter(isPresented: $showsExporter, document: OPMLDocument(data: store.exportOPML()), contentType: .xml, defaultFilename: "PaperRss-Subscriptions") { _ in }
            .alert("PaperRss", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.dismissError() } })) {
                Button(I18N.localized("好"), role: .cancel) { store.dismissError() }
            } message: { Text(store.lastError ?? "") }
    }

    // MARK: - 平台分支主内容

    @ViewBuilder
    private var mainContent: some View {
        #if os(macOS)
        // macOS: 使用 AppKit NSSplitViewController + NSToolbar（NetNewsWire 方案）
        ThreeColumnSplitView(
            sidebar: SidebarView(
                store: store,
                selection: sidebarSelection,
                selectedFeedIDs: $selectedFeedIDs,
                showsAddFeed: $showsAddFeed,
                showsAddFolder: $showsAddFolder,
                renamingFolder: $renamingFolder,
                showsSettings: $showsSettings,
                showsImporter: $showsImporter,
                showsExporter: $showsExporter,
                onDeleteSelection: { selectedEntryID = nil }
            )
            .ignoresSafeArea(),
            // 注意:内容列不能 .ignoresSafeArea()——否则 safeAreaInset 的 header
            // 会顶到窗口最上方,落在 unified NSToolbar 的不可交互条带内,
            // 「全部已读」按钮点击会被工具栏吞掉。纸张背景已在 EntryListView
            // 内用 .ignoresSafeArea() 单独延伸到工具栏之下,观感保持一致。
            content: EntryListView(
                store: store,
                selection: selection ?? .today,
                selectedEntryID: $selectedEntryID,
                retainedUnreadIDs: $retainedEntryListIDs,
                autoScrollTrigger: autoScrollTrigger,
                onFeedback: { showToast($0) }
            )
                .ignoresSafeArea(),
            detail: detailContent
                .ignoresSafeArea(),
            toolbarActions: ToolbarActions(
                onRefresh: { [store] in Task { await store.refresh() } },
                onAddFeed: { showsAddFeed = true },
                onAddFolder: { showsAddFolder = true },
                onImport: { showsImporter = true },
                onExport: { showsExporter = true },
                isRefreshing: store.isRefreshing,
                selectionTitle: headerTitle,
                hasUnread: currentHasUnread,
                onMarkAllRead: { markCurrentAllRead() },
                onFocusAndScrollArticle: { focusAndScrollArticle() },
                isZenMode: isZenMode,
                onToggleZenMode: { withAnimation { isZenMode.toggle() } },
                showsReaderCapsule: selectedEntryID != nil,
                readerCapsule: AnyView(readerToolbarCapsule),
                onReaderShortcut: dispatchReaderShortcut,
                onIncreaseFontSize: { store.increaseArticleFontSize() },
                onDecreaseFontSize: { store.decreaseArticleFontSize() },
                onResetFontSize: { store.resetArticleFontSize() },
                onSelectFirstEntryIfNeeded: { selectFirstEntryIfNeeded() }
            )
        )
        .ignoresSafeArea()
        #else
        // iOS: 保留 NavigationSplitView
        NavigationSplitView {
            SidebarView(
                store: store,
                selection: sidebarSelection,
                selectedFeedIDs: $selectedFeedIDs,
                showsAddFeed: $showsAddFeed,
                showsAddFolder: $showsAddFolder,
                renamingFolder: $renamingFolder,
                showsSettings: $showsSettings,
                showsImporter: $showsImporter,
                showsExporter: $showsExporter,
                onDeleteSelection: { selectedEntryID = nil }
            )
        } content: {
            EntryListView(
                store: store,
                selection: selection ?? .today,
                selectedEntryID: $selectedEntryID,
                retainedUnreadIDs: $retainedEntryListIDs,
                autoScrollTrigger: autoScrollTrigger,
                onFeedback: { showToast($0) }
            )
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        #endif
    }

    private var currentSelection: SidebarSelection {
        selection ?? .today
    }

    private var headerTitle: String {
        if let selectedEntryID,
           let entry = store.entry(id: selectedEntryID),
           let feed = store.feed(for: entry) {
            return feed.title
        }
        return currentSelection.title
    }

    private var currentHasUnread: Bool {
        switch currentSelection {
        case .today:
            return store.sidebarCounts.todayUnread > 0
        case .unread:
            return store.sidebarCounts.allUnread > 0
        case .starred:
            return false
        case let .feed(id):
            return (store.sidebarCounts.unreadByFeed[id] ?? 0) > 0
        case let .feeds(ids):
            return ids.contains { (store.sidebarCounts.unreadByFeed[$0] ?? 0) > 0 }
        case let .folder(acc, folder):
            return store.unreadCount(folder: folder, accountID: acc) > 0
        }
    }

    private func markCurrentAllRead() {
        switch currentSelection {
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            store.markAllRead(scope: .today(startOfDayTimestamp: startOfDay))
        case .unread:
            store.markAllRead()
        case .starred:
            store.markAllRead(scope: .starred)
        case let .folder(acc, folder):
            store.markAllRead(accountID: acc, folder: folder)
        case let .feed(id):
            store.markAllRead(feedID: id)
        case let .feeds(ids):
            store.markAllRead(feedIDs: ids)
        }
    }

    private func showToast(
        _ message: String,
        duration: TimeInterval = ReaderNavigationConfirmation.defaultTimeout
    ) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toastMessage = message
        }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                toastMessage = nil
            }
        }
    }

    private func dismissToast() {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = nil
        }
    }

    private func cancelNavigationConfirmation(dismissToast shouldDismissToast: Bool) {
        navigationConfirmationExpiryTask?.cancel()
        navigationConfirmationExpiryTask = nil
        navigationConfirmation.cancel()
        if shouldDismissToast {
            dismissToast()
        }
    }

    private func confirmNavigation(
        _ key: ReaderNavigationConfirmation.Key,
        entryID: String,
        prompt: String
    ) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        switch navigationConfirmation.register(key, entryID: entryID, at: now) {
        case .confirmed:
            navigationConfirmationExpiryTask?.cancel()
            navigationConfirmationExpiryTask = nil
            dismissToast()
            return true
        case .armed:
            guard let expectedPending = navigationConfirmation.pending else { return false }
            let remainingDuration = max(0, expectedPending.expiresAt - now)
            showToast(prompt, duration: remainingDuration)
            navigationConfirmationExpiryTask?.cancel()
            navigationConfirmationExpiryTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(remainingDuration * 1_000_000_000))
                guard !Task.isCancelled,
                      navigationConfirmation.pending == expectedPending else { return }
                navigationConfirmation.cancel()
                navigationConfirmationExpiryTask = nil
            }
            return false
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(PaperTheme.accent)
                Text(toastMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(PaperTheme.surface(.page, scheme: colorScheme))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 12, x: 0, y: 6)
                    .overlay {
                        Capsule()
                            .stroke(PaperTheme.accent.opacity(0.3), lineWidth: 1)
                    }
            }
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(100)
        }
    }

    private func selectNextEntry() {
        guard let selectedEntryID else {
            // 没有选中项时，拉取当前时间线第一篇
            if let firstID = store.fetchTimelinePage(scope: currentTimelineScope, limit: 1, offset: 0).first?.id {
                self.selectedEntryID = firstID
                if currentTimelineScope == .unread {
                    self.retainedEntryListIDs.insert(firstID)
                } else {
                    self.retainedEntryListIDs.removeAll()
                }
                self.autoScrollTrigger = UUID()
            } else {
                cancelNavigationConfirmation(dismissToast: true)
                showToast(I18N.shared.localized("列表已经阅读完毕"))
            }
            return
        }

        if let nextItem = store.fetchAdjacentItem(
            scope: currentTimelineScope,
            currentItemID: selectedEntryID,
            direction: .next,
            retainingIDs: retainedEntryListIDs.union([selectedEntryID])
        ) {
            let unreadCount = max(1, store.unreadCount(scope: currentTimelineScope))
            let prompt: String = {
                if I18N.shared.isEnglish {
                    return "Press Space again for next article. \(unreadCount) unread"
                } else {
                    return "再次按下空格，切换下一篇。未读 \(unreadCount) 篇"
                }
            }()

            guard confirmNavigation(
                .spaceNextArticle,
                entryID: selectedEntryID,
                prompt: prompt
            ) else { return }

            let nextID = nextItem.id
            self.selectedEntryID = nextID
            if currentTimelineScope == .unread {
                self.retainedEntryListIDs.insert(nextID)
            } else {
                self.retainedEntryListIDs.removeAll()
            }
            self.autoScrollTrigger = UUID()
        } else {
            cancelNavigationConfirmation(dismissToast: true)
            showToast(I18N.shared.localized("列表已经阅读完毕"))
        }
    }

    private enum AdjacentArticleDirection {
        case previous
        case next
    }

    /// 选中稳定后预取相邻文章，使 Space/nn/bb 切换始终命中内存缓存。
    private func scheduleNeighborPrefetch(from entryID: String) {
        store.scheduleNeighborPrefetch(
            scope: currentTimelineScope,
            currentItemID: entryID,
            retainingIDs: retainedEntryListIDs.union([entryID])
        )
    }

    private func requestAdjacentArticle(_ direction: AdjacentArticleDirection) {
        guard let selectedEntryID else {
            cancelNavigationConfirmation(dismissToast: true)
            return
        }

        let confirmationKey: ReaderNavigationConfirmation.Key
        let prompt: String
        let boundaryMessage: String
        let adjacentDir: AdjacentTimelineDirection

        switch direction {
        case .previous:
            confirmationKey = .previousArticle
            prompt = I18N.shared.localized("再次按下 K 查看上一篇")
            boundaryMessage = I18N.shared.localized("已经是列表第一篇")
            adjacentDir = .previous
        case .next:
            confirmationKey = .nextArticle
            prompt = I18N.shared.localized("再次按下 J 查看下一篇")
            boundaryMessage = I18N.shared.localized("列表已经阅读完毕")
            adjacentDir = .next
        }

        guard let adjacentItem = store.fetchAdjacentItem(
            scope: currentTimelineScope,
            currentItemID: selectedEntryID,
            direction: adjacentDir,
            retainingIDs: retainedEntryListIDs.union([selectedEntryID])
        ) else {
            cancelNavigationConfirmation(dismissToast: true)
            showToast(boundaryMessage)
            return
        }

        guard confirmNavigation(confirmationKey, entryID: selectedEntryID, prompt: prompt) else { return }
        let nextID = adjacentItem.id
        self.selectedEntryID = nextID
        if currentTimelineScope == .unread {
            self.retainedEntryListIDs.insert(nextID)
        } else {
            self.retainedEntryListIDs.removeAll()
        }
        self.autoScrollTrigger = UUID()
    }

    private func dispatchReaderShortcut(_ action: ReaderShortcutAction) {
        guard let entryID = selectedEntryID else { return }
        switch action {
        case .previousArticle:
            requestAdjacentArticle(.previous)
        case .nextArticle:
            requestAdjacentArticle(.next)
        case .toggleBilingual:
            let prompt = I18N.shared.localized("再按一次 C 切换对照翻译")
            guard confirmNavigation(.toggleBilingual, entryID: entryID, prompt: prompt) else { return }
            readerShortcutInvocation = ReaderShortcutInvocation(action: action)
        case .showSummary:
            let prompt = I18N.shared.localized("再按一次 V 查看 AI 摘要")
            guard confirmNavigation(.showSummary, entryID: entryID, prompt: prompt) else { return }
            readerShortcutInvocation = ReaderShortcutInvocation(action: action)
        case .toggleStar:
            let prompt = I18N.shared.localized("再按一次 M 切换收藏")
            guard confirmNavigation(.toggleStar, entryID: entryID, prompt: prompt) else { return }
            readerShortcutInvocation = ReaderShortcutInvocation(action: action)
        case .toggleFullScreen:
            let prompt = I18N.shared.localized("再按一次 F 切换禅模式")
            guard confirmNavigation(.toggleFullScreen, entryID: entryID, prompt: prompt) else { return }
            withAnimation {
                isZenMode.toggle()
            }
        }
    }

    private var currentTimelineScope: TimelineScope {
        switch currentSelection {
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            return .today(startOfDayTimestamp: startOfDay)
        case .unread:
            return .unread
        case .starred:
            return .starred
        case let .folder(acc, folder):
            return .folder(accountID: acc, folderName: folder)
        case let .feed(id):
            return .feed(feedID: id.uuidString)
        case let .feeds(ids):
            return .feeds(feedIDs: Set(ids.map(\.uuidString)))
        }
    }

    private func focusAndScrollArticle() {
        if selectedEntryID == nil {
            selectedEntryID = store.fetchTimelinePage(scope: currentTimelineScope, limit: 1, offset: 0).first?.id
        }

        #if os(macOS)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ThreeColumnSplitViewCoordinator.current?.setActiveColumn(2, makeFirstResponder: false)
            }
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }

            @MainActor
            func findWKWebView(in view: NSView) -> WKWebView? {
                if let webView = view as? WKWebView {
                    return webView
                }
                for subview in view.subviews {
                    if let found = findWKWebView(in: subview) {
                        return found
                    }
                }
                return nil
            }

            if let contentView = window.contentView, let webView = findWKWebView(in: contentView) {
                window.makeFirstResponder(webView)
                let js = """
                (() => {
                  const scrollHeight = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight);
                  const clientHeight = window.innerHeight;
                  const scrollTop = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                  const isAtBottom = (scrollTop + clientHeight) >= (scrollHeight - 6);
                  if (isAtBottom) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(PaperReaderBridge.nextArticleMessageName)) {
                      window.webkit.messageHandlers.\(PaperReaderBridge.nextArticleMessageName).postMessage({});
                    }
                  } else {
                    const pageDistance = Math.max(120, clientHeight * 0.382);
                    window.scrollBy({ top: pageDistance, behavior: 'smooth' });
                  }
                })();
                """
                webView.evaluateJavaScript(js)
            } else {
                selectNextEntry()
            }
        }
        #endif
    }

    private func selectFirstEntryIfNeeded() {
        if selectedEntryID == nil, let first = store.fetchTimelinePage(scope: currentTimelineScope, limit: 1, offset: 0).first {
            selectedEntryID = first.id
        }
    }

    private func focusListView() {
        #if os(macOS)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let coordinator = ThreeColumnSplitViewCoordinator.current else { return }
                coordinator.setActiveColumn(1)
            }
        }
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack(alignment: .bottom) {
            if let selectedEntry {
                ArticleReaderView(
                    store: store,
                    entry: selectedEntry,
                    shortcutInvocation: readerShortcutInvocation,
                    onReaderShortcut: dispatchReaderShortcut,
                    onShortcutFeedback: { showToast($0) },
                    onSelectNextEntry: { selectNextEntry() },
                    onFocusListView: { focusListView() },
                    isZenMode: isZenMode,
                    onToggleZenMode: { withAnimation { isZenMode.toggle() } }
                )
                .ignoresSafeArea()
            } else {
                emptyDetailPlaceholder
            }

            toastOverlay
        }
    }

    private var selectedEntry: Entry? {
        guard let selectedEntryID else { return nil }
        return store.entry(id: selectedEntryID)
    }

    /// Clear the old reader in the same transaction as the sidebar change.
    /// Doing this later from `EntryListView.onChange` forced SwiftUI to update
    /// the split view twice and briefly kept the previous WKWebView alive while
    /// constructing the new feed list.
    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard newSelection != selection else { return }
                cancelNavigationConfirmation(dismissToast: true)
                selectedEntryID = nil
                retainedEntryListIDs.removeAll()
                selection = newSelection
            }
        )
    }

    @ViewBuilder
    private var readerToolbarCapsule: some View {
        if let selectedEntry {
            let current = store.entry(id: selectedEntry.id) ?? selectedEntry
            ReaderCapsuleToolbar(
                isBilingualActive: store.isBilingualActive(for: current.id),
                isRead: current.isRead,
                isStarred: current.isStarred,
                isZenMode: isZenMode,
                disabled: false,
                onToggleBilingual: {
                    store.toggleBilingualMode(for: current.id)
                },
                onToggleRead: {
                    store.markRead(current, read: !current.isRead)
                },
                onToggleStar: {
                    store.toggleStar(current)
                },
                onToggleZenMode: {
                    withAnimation {
                        isZenMode.toggle()
                    }
                }
            )
        } else {
            EmptyView()
        }
    }

    private var emptyDetailPlaceholder: some View {
        ZStack {
            PaperSurface(kind: .page)
                .ignoresSafeArea()
            ContentUnavailableView {
                Label {
                    Text(I18N.localized("慢读，深思"))
                        .font(.system(size: 17, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                } icon: {
                    PaperBrandIcon(size: 76)
                        .padding(.bottom, 4)
                }
            } description: {
                Text(I18N.localized("从列表中打开文章开始阅读。"))
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.tertiary)
            }
        }
        .ignoresSafeArea()
    }
}

private struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Binding var selection: SidebarSelection?
    @Binding var selectedFeedIDs: Set<UUID>
    @Binding var showsAddFeed: Bool
    @Binding var showsAddFolder: Bool
    @Binding var renamingFolder: String?
    @Binding var showsSettings: Bool
    @Binding var showsImporter: Bool
    @Binding var showsExporter: Bool
    /// Invoked after any destructive sidebar action (delete feed/folder).
    /// The parent clears the open reader so a deleted feed's article never
    /// leaves a stale selection behind — the toolbar would otherwise render
    /// an empty capsule placeholder.
    var onDeleteSelection: () -> Void
    @AppStorage("sidebar_collapsed_accounts_raw") private var collapsedAccountsRaw: String = ""
    @AppStorage("sidebar_collapsed_folders_raw") private var collapsedFoldersRaw: String = ""
    @State private var batchDeleteConfirmFeedIDs: Set<UUID>? = nil
    @Environment(\.colorScheme) private var colorScheme

    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private var collapsedAccounts: Set<String> {
        get {
            Set(collapsedAccountsRaw.split(separator: "|||").map(String.init))
        }
        nonmutating set {
            collapsedAccountsRaw = newValue.sorted().joined(separator: "|||")
        }
    }

    private var collapsedFolders: Set<String> {
        get {
            Set(collapsedFoldersRaw.split(separator: "|||").map(String.init))
        }
        nonmutating set {
            collapsedFoldersRaw = newValue.sorted().joined(separator: "|||")
        }
    }

    private func isAccountExpandedBinding(accountID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedAccounts.contains(accountID) },
            set: { isExpanded in
                var current = collapsedAccounts
                if isExpanded {
                    current.remove(accountID)
                } else {
                    current.insert(accountID)
                }
                collapsedAccounts = current
            }
        )
    }

    private func isFolderExpandedBinding(key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(key) },
            set: { isExpanded in
                var current = collapsedFolders
                if isExpanded {
                    current.remove(key)
                } else {
                    current.insert(key)
                }
                collapsedFolders = current
            }
        )
    }

    private var selectedSidebarSelections: Binding<Set<SidebarSelection>> {
        Binding(
            get: {
                if !selectedFeedIDs.isEmpty {
                    return Set(selectedFeedIDs.map { SidebarSelection.feed($0) })
                }
                if let sel = selection {
                    return [sel]
                }
                return []
            },
            set: { newSet in
                // 原生 List 在由单项向另一项切换过渡时会短暂发射 empty set。
                // 忽略过渡瞬态的空集合，防止 selection 变为 nil 并触发 RootView 回退到 .today 导致界面闪烁
                if newSet.isEmpty {
                    return
                }
                let feeds = newSet.compactMap { sel -> UUID? in
                    if case let .feed(id) = sel { return id }
                    return nil
                }
                if feeds.count > 1 {
                    selectedFeedIDs = Set(feeds)
                    selection = .feeds(Set(feeds))
                } else if feeds.count == 1, newSet.count == 1 {
                    let singleID = feeds[0]
                    selectedFeedIDs = [singleID]
                    selection = .feed(singleID)
                } else if let firstNonFeed = newSet.first(where: {
                    if case .feed = $0 { return false } else { return true }
                }) {
                    selectedFeedIDs = []
                    selection = firstNonFeed
                }
            }
        )
    }

    private var freshRSSAccounts: [AccountRecord] {
        store.accounts.filter { $0.type == AccountType.freshRSS.rawValue && $0.isEnabled }
    }

    var body: some View {
        List(selection: selectedSidebarSelections) {
            readingSection
            if store.isAccountEnabled("local-default") {
                localSubscriptionsSection
            }
            ForEach(freshRSSAccounts) { account in
                freshRSSAccountSection(account)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .scrollIndicators(.never, axes: .vertical)
        #endif
        .overlay {
            let hasAnyAccount = store.isAccountEnabled("local-default") || !freshRSSAccounts.isEmpty
            if !hasAnyAccount {
                ContentUnavailableView {
                    Label(I18N.localized("未启用任何账号"), systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text(I18N.localized("请前往“设置 -> 账号”启用本地或 FreshRSS 订阅账号。"))
                }
                .padding()
            } else if (store.isAccountEnabled("local-default") ? store.feeds.isEmpty : true) && freshRSSAccounts.allSatisfy({ store.rootFeeds(for: $0.id).isEmpty && store.folders(for: $0.id).isEmpty }) {
                ContentUnavailableView {
                    Label(I18N.localized("还没有订阅"), systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(I18N.localized("添加一个 RSS 地址，或导入 OPML 文件。"))
                } actions: {
                    Button(I18N.localized("添加订阅")) { showsAddFeed = true }
                }
                .padding()
            }
        }
        .onChange(of: store.accounts) {
            validateSelectionAgainstEnabledAccounts()
        }
        .safeAreaInset(edge: .bottom) {
            settingsFooter
        }
        #if os(macOS)
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 44)
        }
        #endif
        .background {
            // 与文章列表一致：纸张背景延伸到窗口顶部，避免 44pt 占位区透出白色背景
            PaperSurface(kind: .sidebar, textureOpacity: 0.52).ignoresSafeArea()
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                refreshButton
                addButton
            }
        }
        #endif
        .alert("确认删除订阅", isPresented: Binding(
            get: { batchDeleteConfirmFeedIDs != nil },
            set: { if !$0 { batchDeleteConfirmFeedIDs = nil } }
        )) {
            Button(I18N.localized("取消"), role: .cancel) { batchDeleteConfirmFeedIDs = nil }
            Button(I18N.localized("删除"), role: .destructive) {
                if let ids = batchDeleteConfirmFeedIDs {
                    store.deleteFeeds(ids)
                    selectedFeedIDs = []
                    selection = .today
                    onDeleteSelection()
                }
                batchDeleteConfirmFeedIDs = nil
            }
        } message: {
            if let ids = batchDeleteConfirmFeedIDs {
                Text(I18N.shared.localizedFormat("确定要删除选中的 %lld 个订阅源及其所有文章吗？此操作无法撤销。", ids.count))
            }
        }
    }
    private var availableUpdateRelease: AppReleaseInfo? {
        guard case let .hasUpdate(release, _) = store.updateStatus else { return nil }
        let releaseVersionClean = release.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        if let ignored = store.ignoredVersion, ignored == releaseVersionClean {
            return nil
        }
        return release
    }

    @ViewBuilder
    private var settingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.15)
            HStack(spacing: 8) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(I18N.localized("设置"))
                .help(I18N.localized("设置"))

                if let release = availableUpdateRelease {
                    HStack(spacing: 5) {
                        Button {
                            UpdateCheckService.openURL(release.htmlURL)
                        } label: {
                            HStack(spacing: 3) {
                                Text(I18N.localized("NEW"))
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.white)
                                Text("v\(release.version)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.95))
                            }
                        }
                        .buttonStyle(.borderless)
                        .help(I18N.shared.localizedFormat("点击前往下载新版本 v%@", release.version))

                        Button {
                            store.ignoreVersion(release.version)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(I18N.localized("忽略此版本更新"))
                        .help(I18N.localized("不再提示此版本更新"))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange, in: Capsule())
                }

                Spacer()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(PaperHeaderSurface(kind: .sidebar))
    }
    @ViewBuilder
    private var readingSection: some View {
        Section(I18N.localized("阅读")) {
            SidebarRow(I18N.shared.localized("今天"), systemImage: "sun.max", count: store.sidebarCounts.todayUnread)
                .tag(SidebarSelection.today)
            SidebarRow(I18N.shared.localized("未读"), systemImage: "circle", count: store.sidebarCounts.allUnread)
                .tag(SidebarSelection.unread)
            SidebarRow(I18N.shared.localized("收藏"), systemImage: "star", count: store.sidebarCounts.starred)
                .tag(SidebarSelection.starred)
        }
    }

    @ViewBuilder
    private var localSubscriptionsSection: some View {
        Section(isExpanded: isAccountExpandedBinding(accountID: "local-default")) {
            ForEach(store.rootFeeds(for: "local-default")) { feed in
                feedRow(feed)
            }
            .onMove { fromOffsets, toOffset in
                store.reorderRootFeeds(fromOffsets: fromOffsets, toOffset: toOffset)
            }

            ForEach(store.folders(for: "local-default"), id: \.self) { folder in
                let key = "local-default::\(folder)"
                DisclosureGroup(
                    isExpanded: isFolderExpandedBinding(key: key),
                    content: {
                        ForEach(store.feeds(in: folder, for: "local-default")) { feed in
                            feedRow(feed, inFolder: true)
                        }
                        .onMove { fromOffsets, toOffset in
                            store.reorderFeeds(in: folder, fromOffsets: fromOffsets, toOffset: toOffset)
                        }
                    },
                    label: {
                        folderRow(folder, accountID: "local-default")
                    }
                )
            }
            .onMove { fromOffsets, toOffset in
                store.reorderFolders(fromOffsets: fromOffsets, toOffset: toOffset)
            }
        } header: {
            HStack {
                Text(I18N.localized("我的 Mac"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAccountExpandedBinding(accountID: "local-default").wrappedValue.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private func freshRSSAccountSection(_ account: AccountRecord) -> some View {
        Section(isExpanded: isAccountExpandedBinding(accountID: account.id)) {
            ForEach(store.rootFeeds(for: account.id)) { feed in
                remoteFeedRow(feed, accountID: account.id)
            }

            ForEach(store.folders(for: account.id), id: \.self) { folder in
                let key = "\(account.id)::\(folder)"
                DisclosureGroup(
                    isExpanded: isFolderExpandedBinding(key: key),
                    content: {
                        ForEach(store.feeds(in: folder, for: account.id)) { feed in
                            remoteFeedRow(feed, accountID: account.id, inFolder: true)
                        }
                    },
                    label: {
                        remoteFolderRow(folder, accountID: account.id)
                    }
                )
            }
        } header: {
            HStack {
                Text(account.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAccountExpandedBinding(accountID: account.id).wrappedValue.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private func remoteFolderRow(_ folder: String, accountID: String) -> some View {
        let count = store.unreadCount(folder: folder, accountID: accountID)
        let key = "\(accountID)::\(folder)"
        SidebarRow(folder, systemImage: "folder", count: count)
            .contentShape(Rectangle())
            .tag(SidebarSelection.folder(accountID: accountID, folderName: folder))
            .onTapGesture {
                if selection == .folder(accountID: accountID, folderName: folder) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFolderExpandedBinding(key: key).wrappedValue.toggle()
                    }
                } else {
                    selection = .folder(accountID: accountID, folderName: folder)
                }
            }
            .contextMenu {
                Button {
                    store.markAllRead(accountID: accountID, folder: folder)
                } label: {
                    Label(I18N.localized("全部已读"), systemImage: "checkmark.circle")
                }
            }
    }

    @ViewBuilder
    private func remoteFeedRow(_ feed: Feed, accountID: String, inFolder: Bool = false) -> some View {
        SidebarRow(feed.title, systemImage: "dot.radiowaves.left.and.right", iconURL: feed.iconURL, count: store.unreadCount(feedID: feed.id), feedID: feed.id)
            .padding(.leading, inFolder ? -12 : 0)
            .tag(SidebarSelection.feed(feed.id))
            .contextMenu {
                Button {
                    store.markAllRead(feedID: feed.id)
                } label: {
                    Label(I18N.localized("全部已读"), systemImage: "checkmark.circle")
                }

                Button {
                    copyToClipboard(feed.feedURL.absoluteString)
                } label: {
                    Label(I18N.localized("复制订阅"), systemImage: "doc.on.doc")
                }
            }
    }

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            Task {
                await store.refresh()
            }
        } label: {
            refreshIcon
        }
        .disabled(store.isRefreshing)
        .accessibilityLabel(I18N.localized("手动刷新"))
        .help(I18N.localized("刷新所有订阅"))
    }

    @ViewBuilder
    private var refreshIcon: some View {
        if store.isRefreshing {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private var addButton: some View {
        Menu {
            Button { showsAddFeed = true } label: { Label(I18N.localized("添加订阅"), systemImage: "plus") }
            Button { showsAddFolder = true } label: { Label(I18N.localized("新建文件夹"), systemImage: "folder.badge.plus") }
            Divider()
            Button { showsImporter = true } label: { Label(I18N.localized("导入 OPML"), systemImage: "square.and.arrow.down") }
            Button { showsExporter = true } label: { Label(I18N.localized("导出 OPML"), systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel(I18N.localized("新建与更多"))
        .help(I18N.localized("添加订阅或新建文件夹"))
    }

    @ViewBuilder
    private func folderRow(_ folder: String, accountID: String = "local-default") -> some View {
        let key = "\(accountID)::\(folder)"
        FolderRowView(folder: folder, unreadCount: store.unreadCount(folder: folder, accountID: accountID)) { feedIDs in
            store.setFeedFolder(feedIDs: feedIDs, folder: folder)
            var current = collapsedFolders
            current.remove(key)
            current.remove(folder)
            collapsedFolders = current
        }
        .contentShape(Rectangle())
        .tag(SidebarSelection.folder(accountID: accountID, folderName: folder))
        .onTapGesture {
            if selection == .folder(accountID: accountID, folderName: folder) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFolderExpandedBinding(key: key).wrappedValue.toggle()
                }
            } else {
                selection = .folder(accountID: accountID, folderName: folder)
            }
        }
            .contextMenu {
                Button {
                    let unreadIDs = store.entryListItems(folder: folder, accountID: accountID).filter { !$0.isRead }.map { $0.id }
                    store.markRead(entryIDs: unreadIDs)
                } label: {
                    Label(I18N.localized("全部已读"), systemImage: "checkmark.circle")
                }

                Button {
                    renamingFolder = folder
                } label: {
                    Label(I18N.localized("重命名文件夹"), systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    store.deleteFolder(folder)
                    if case let .folder(acc, f) = selection, acc == accountID && f == folder {
                        selection = .today
                    }
                    onDeleteSelection()
                } label: {
                    Label(I18N.localized("删除文件夹"), systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed, inFolder: Bool = false) -> some View {
        SidebarRow(feed.title, systemImage: "dot.radiowaves.left.and.right", iconURL: feed.iconURL, count: store.unreadCount(feedID: feed.id), feedID: feed.id)
            .padding(.leading, inFolder ? -12 : 0)
            .tag(SidebarSelection.feed(feed.id))
            .draggable(selectedFeedIDs.contains(feed.id) && selectedFeedIDs.count > 1 ? selectedFeedIDs.map(\.uuidString).joined(separator: ",") : feed.id.uuidString) {
                HStack(spacing: 6) {
                    if let iconURL = feed.iconURL {
                        FeedFaviconView(feedID: feed.id, iconURL: iconURL, title: feed.title, size: 14)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(PaperTheme.accent)
                    }
                    Text(feed.title)
                        .font(.system(size: 13, weight: .medium))
                    if selectedFeedIDs.contains(feed.id) && selectedFeedIDs.count > 1 {
                        Text("\(selectedFeedIDs.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(PaperTheme.accent, in: Capsule())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PaperTheme.surface(.sidebar, scheme: colorScheme), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }
            .contextMenu {
                if selectedFeedIDs.contains(feed.id) && selectedFeedIDs.count > 1 {
                    Button {
                        let unreadIDs = store.entryListItems(feedIDs: selectedFeedIDs).filter { !$0.isRead }.map { $0.id }
                        store.markRead(entryIDs: unreadIDs)
                    } label: {
                        Label(I18N.shared.localizedFormat("标记选中源全部已读 (%lld)", selectedFeedIDs.count), systemImage: "checkmark.circle")
                    }

                    Button {
                        let urls = store.feeds.filter { selectedFeedIDs.contains($0.id) }.map { $0.feedURL.absoluteString }.joined(separator: "\n")
                        copyToClipboard(urls)
                    } label: {
                        Label(I18N.shared.localizedFormat("复制选中订阅链接 (%lld)", selectedFeedIDs.count), systemImage: "doc.on.doc")
                    }

                    Menu {
                        Button {
                            store.setFeedFolder(feedIDs: selectedFeedIDs, folder: nil)
                        } label: {
                            Text(I18N.localized("无分类"))
                        }

                        if !store.folders.isEmpty {
                            Divider()
                            ForEach(store.folders, id: \.self) { targetFolder in
                                Button {
                                    store.setFeedFolder(feedIDs: selectedFeedIDs, folder: targetFolder)
                                    var current = collapsedFolders
                                    current.remove("local-default::\(targetFolder)")
                                    current.remove(targetFolder)
                                    collapsedFolders = current
                                } label: {
                                    Text(targetFolder)
                                }
                            }
                        }

                        Divider()

                        Button {
                            showsAddFolder = true
                        } label: {
                            Label(I18N.localized("新建文件夹..."), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label(I18N.localized("移动选中项到文件夹"), systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        batchDeleteConfirmFeedIDs = selectedFeedIDs
                    } label: {
                        Label(I18N.shared.localizedFormat("删除选中的订阅 (%lld)", selectedFeedIDs.count), systemImage: "trash")
                    }
                } else {
                    Button {
                        let unreadIDs = store.entryListItems(feedID: feed.id).filter { !$0.isRead }.map { $0.id }
                        store.markRead(entryIDs: unreadIDs)
                    } label: {
                        Label(I18N.localized("全部已读"), systemImage: "checkmark.circle")
                    }

                    Button {
                        copyToClipboard(feed.feedURL.absoluteString)
                    } label: {
                        Label(I18N.localized("复制订阅"), systemImage: "doc.on.doc")
                    }

                    Menu {
                        Button {
                            store.setFeedFolder(feed, folder: nil)
                        } label: {
                            if feed.folder == nil {
                                Label(I18N.localized("无分类"), systemImage: "checkmark")
                            } else {
                                Text(I18N.localized("无分类"))
                            }
                        }

                        if !store.folders.isEmpty {
                            Divider()
                            ForEach(store.folders, id: \.self) { targetFolder in
                                Button {
                                    store.setFeedFolder(feed, folder: targetFolder)
                                    var current = collapsedFolders
                                    current.remove("local-default::\(targetFolder)")
                                    current.remove(targetFolder)
                                    collapsedFolders = current
                                } label: {
                                    if feed.folder == targetFolder {
                                        Label(targetFolder, systemImage: "checkmark")
                                    } else {
                                        Text(targetFolder)
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            showsAddFolder = true
                        } label: {
                            Label(I18N.localized("新建文件夹..."), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label(I18N.localized("移动到文件夹"), systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        store.deleteFeed(feed)
                        if selection == .feed(feed.id) {
                            selection = .today
                        }
                        onDeleteSelection()
                    } label: {
                        Label(I18N.localized("删除订阅"), systemImage: "trash")
                    }
                }
            }
    }

    private func showSettings() {
        #if os(macOS)
        openSettings()
        #else
        showsSettings = true
        #endif
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    private func validateSelectionAgainstEnabledAccounts() {
        guard let sel = selection else { return }
        switch sel {
        case .folder(let accountID, _):
            if !store.isAccountEnabled(accountID) {
                selection = .today
            }
        case .feed(let feedID):
            let feedAccountID = store.accountID(forFeedID: feedID)
            if !store.isAccountEnabled(feedAccountID) {
                selection = .today
                selectedFeedIDs = []
            }
        default:
            break
        }
    }
}

/// Feed 图标视图。与旧 AsyncImage 实现的关键差异：
/// 图标经 `FeedIconStore` 同步查询，首帧即命中内存/磁盘缓存，不存在加载期占位态；
/// 字母徽章只出现在"该 feed 确定无图标"或"首次预热尚未完成"的帧，
/// 且失败记忆保证坏 URL 不会反复进入"徽章→图→徽章"的闪烁循环。
private struct FeedFaviconView: View {
    let feedID: UUID
    let iconURL: URL?
    let title: String
    var size: CGFloat = 16

    @EnvironmentObject private var icons: FeedIconStore

    var body: some View {
        if let image = icons.cachedImage(feedID: feedID) {
            Image(decorative: image, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size > 15 ? 4 : 3, style: .continuous))
        } else {
            // 兜底期间顺带补发预热（store 内有 in-flight 与失败窗去重，代价为零）。
            fallbackBadge
                .onAppear { icons.warmUp(feedID: feedID, iconURL: iconURL) }
        }
    }

    private var fallbackBadge: some View {
        Text(title.prefix(1).uppercased())
            .font(.system(size: max(8, size * 0.58), weight: .bold, design: .rounded))
            .foregroundStyle(PaperTheme.accent)
            .frame(width: size, height: size)
            .background(PaperTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size > 15 ? 4 : 3, style: .continuous))
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let iconURL: URL?
    let count: Int
    var feedID: UUID?

    init(_ title: String, systemImage: String, iconURL: URL? = nil, count: Int = 0, feedID: UUID? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.iconURL = iconURL
        self.count = count
        self.feedID = feedID
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let iconURL, let feedID {
                    FeedFaviconView(feedID: feedID, iconURL: iconURL, title: title, size: 16)
                } else {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 18, alignment: .center)
            Text(title)
            Spacer(minLength: 8)
            if count > 0 {
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct SubscriptionsHeaderView: View {
    let onDropBatch: (Set<UUID>) -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Text(I18N.localized("订阅源"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isTargeted ? PaperTheme.accent : .secondary)
            if isTargeted {
                Text(I18N.localized("(移出文件夹)"))
                    .font(.caption2)
                    .foregroundStyle(PaperTheme.accent)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isTargeted ? PaperTheme.accent.opacity(0.15) : Color.clear)
        )
        .dropDestination(for: String.self) { items, _ -> Bool in
            isTargeted = false
            let feedIDs = Set(items.flatMap { $0.components(separatedBy: ",").compactMap { UUID(uuidString: $0) } })
            guard !feedIDs.isEmpty else { return false }
            onDropBatch(feedIDs)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

private struct FolderRowView: View {
    let folder: String
    let unreadCount: Int
    let onDropBatch: (Set<UUID>) -> Void

    @State private var isTargeted = false

    var body: some View {
        SidebarRow(folder, systemImage: isTargeted ? "folder.fill" : "folder", count: unreadCount)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isTargeted ? PaperTheme.accent.opacity(0.22) : Color.clear)
            )
            .dropDestination(for: String.self) { items, _ -> Bool in
                isTargeted = false
                let feedIDs = Set(items.flatMap { $0.components(separatedBy: ",").compactMap { UUID(uuidString: $0) } })
                guard !feedIDs.isEmpty else { return false }
                onDropBatch(feedIDs)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
    }
}

private struct EntryListView: View {
    @ObservedObject var store: AppStore
    let selection: SidebarSelection
    @Binding var selectedEntryID: String?
    @Binding var retainedUnreadIDs: Set<String>
    var autoScrollTrigger: UUID
    var onFeedback: (String) -> Void = { _ in }

    @State private var isScrolled = false
    @State private var loadedEntries: [EntryListItem] = []
    @State private var hasMore: Bool = true
    @State private var isLoadingPage: Bool = false
    private let pageSize = 100

    private var timelineScope: TimelineScope {
        switch selection {
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            return .today(startOfDayTimestamp: startOfDay)
        case .unread:
            return .unread
        case .starred:
            return .starred
        case let .folder(acc, folder):
            return .folder(accountID: acc, folderName: folder)
        case let .feed(id):
            return .feed(feedID: id.uuidString)
        case let .feeds(ids):
            return .feeds(feedIDs: Set(ids.map(\.uuidString)))
        }
    }

    private var hasUnread: Bool {
        loadedEntries.contains { !$0.isRead }
    }

    private func loadInitialPage() {
        guard !isLoadingPage else { return }
        isLoadingPage = true
        let firstPage = store.fetchTimelinePage(
            scope: timelineScope,
            retainingIDs: retainedUnreadIDs,
            limit: pageSize,
            offset: 0
        )
        loadedEntries = firstPage
        hasMore = (firstPage.count == pageSize)
        isLoadingPage = false
        // 切换订阅源后首屏预热：行渲染前图标已就绪，避免整列闪兜底徽章。
        store.iconStore.warmUp(items: firstPage)
    }

    private func loadNextPage() {
        guard !isLoadingPage, hasMore else { return }
        isLoadingPage = true
        let page = store.fetchTimelinePage(
            scope: timelineScope,
            retainingIDs: retainedUnreadIDs,
            limit: pageSize,
            offset: loadedEntries.count
        )
        let existingIDs = Set(loadedEntries.map(\.id))
        let freshItems = page.filter { !existingIDs.contains($0.id) }
        if freshItems.isEmpty {
            hasMore = false
        } else {
            loadedEntries.append(contentsOf: freshItems)
            hasMore = (page.count == pageSize)
            // 滚动加载下一页时预热新页涉及的 feed。
            store.iconStore.warmUp(items: freshItems)
        }
        isLoadingPage = false
    }

    private func reloadCurrentPages() {
        let totalCount = max(pageSize, loadedEntries.count)
        let refreshed = store.fetchTimelinePage(
            scope: timelineScope,
            retainingIDs: retainedUnreadIDs,
            limit: totalCount,
            offset: 0
        )
        loadedEntries = refreshed
        hasMore = (refreshed.count >= totalCount)
        // 刷新后的列表可能引入新 feed，幂等预热（store 内自动去重）。
        store.iconStore.warmUp(items: refreshed)
    }

    /// 将当前选择范围在数据库中的全部未读文章标记为已读。
    private func markAllRead() {
        switch selection {
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            store.markAllRead(scope: .today(startOfDayTimestamp: startOfDay))
        case .unread:
            store.markAllRead()
        case .starred:
            store.markAllRead(scope: .starred)
        case let .folder(acc, folder):
            store.markAllRead(accountID: acc, folder: folder)
        case let .feed(id):
            store.markAllRead(feedID: id)
        case let .feeds(ids):
            store.markAllRead(feedIDs: ids)
        }
        retainedUnreadIDs = selectedEntryID.map { [$0] } ?? []
        reloadCurrentPages()
    }

    private func patchEntryState(entryID: String, isRead: Bool? = nil, isStarred: Bool? = nil) {
        guard let index = loadedEntries.firstIndex(where: { $0.id == entryID }) else { return }
        if let isRead { loadedEntries[index].isRead = isRead }
        if let isStarred { loadedEntries[index].isStarred = isStarred }
    }

    private var entryListSelection: Binding<String?> {
        Binding(
            get: { selectedEntryID },
            set: { newID in
                // 原生 List 在自身结构调和、局部刷新或状态变化时可能会发出瞬态 nil。
                // 严禁让原生 List 决定应用层选择状态，忽略此类瞬态 nil 以免清空 selectedEntryID 或 retainedUnreadIDs。
                guard let newID else { return }

                // 在未读浏览会话中，累积保留所有在当前会话中被阅读过的条目
                if timelineScope == .unread {
                    retainedUnreadIDs.insert(newID)
                } else {
                    retainedUnreadIDs.removeAll()
                }
                selectedEntryID = newID
            }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: entryListSelection) {
                ForEach(loadedEntries) { entry in
                    EntryRow(entry: entry)
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button(I18N.shared.localized(entry.isRead ? "标为未读" : "标为已读")) {
                                let nextRead = !entry.isRead
                                store.markRead(entryID: entry.id, read: nextRead)
                                patchEntryState(entryID: entry.id, isRead: nextRead)
                            }
                            Button(I18N.shared.localized(entry.isStarred ? "取消收藏" : "收藏")) {
                                let nextStarred = !entry.isStarred
                                store.toggleStar(entryID: entry.id)
                                patchEntryState(entryID: entry.id, isStarred: nextStarred)
                            }
                            Divider()
                            Button {
                                Task {
                                    let ok = await store.refetchArticle(entryID: entry.id)
                                    onFeedback(I18N.shared.localized(ok ? "正文已更新" : "拉取失败，已保留原内容"))
                                }
                            } label: {
                                Label(I18N.shared.localized("重新拉取正文"), systemImage: "arrow.clockwise")
                            }
                            .disabled(store.activeRefetchEntryIDs.contains(entry.id))
                        }
                        .onAppear {
                            if entry.id == loadedEntries.last?.id {
                                loadNextPage()
                            }
                        }
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollIndicators(.never, axes: .vertical)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
            .background {
                // 让纸张背景延伸到窗口顶部（unified NSToolbar 之下、safeAreaInset 占位区），
                // 否则占位区会透出窗口默认白色背景，形成顶部空白条
                PaperSurface(kind: .articleList, textureOpacity: 0.62).ignoresSafeArea()
            }
            #if os(iOS)
            .navigationTitle(selection.title)
            #endif
            .onAppear {
                if loadedEntries.isEmpty {
                    loadInitialPage()
                }
            }
            .onChange(of: selection) { _, _ in
                retainedUnreadIDs.removeAll()
                loadInitialPage()
            }
            .onChange(of: selectedEntryID) { _, newID in
                if let newID {
                    if timelineScope == .unread {
                        retainedUnreadIDs.insert(newID)
                    }
                    patchEntryState(entryID: newID, isRead: true)
                }
            }
            .onChange(of: store.timelineRevision) { _, _ in
                reloadCurrentPages()
            }
            .onChange(of: autoScrollTrigger) { _, _ in
                if let newID = selectedEntryID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        markAllRead()
                    } label: {
                        Label(I18N.localized("全部标为已读"), systemImage: "envelope.open")
                    }
                    .help(I18N.localized("将当前列表全部标为已读"))
                    .disabled(!hasUnread)
                }
            }
            #endif
            #if os(macOS)
            .background {
                ScrollOffsetObserver { offset in
                    let shouldBlur = offset > 5
                    if isScrolled != shouldBlur {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isScrolled = shouldBlur
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 52)
                    .background {
                        ZStack(alignment: .bottom) {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                            Divider()
                                .opacity(0.15)
                        }
                        .opacity(isScrolled ? 1 : 0)
                    }
            }
            #endif
            .overlay {
                if loadedEntries.isEmpty && !isLoadingPage {
                    ContentUnavailableView(
                        "没有文章",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: Text(I18N.shared.localized(
                            store.feeds.isEmpty
                                ? "添加订阅后，这里会显示文章。"
                                : "切换到其他分类，或等待下一次订阅更新。"
                        ))
                    )
                }
            }
        }
    }
}

#if os(macOS)
private struct ScrollOffsetObserver: NSViewRepresentable {
    let onOffsetChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 延迟搜索：视图挂载后才能遍历视图树
        DispatchQueue.main.async {
            guard let scrollView = Self.findScrollView(from: view) else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            context.coordinator.clipView = clipView
            context.coordinator.onOffsetChange = onOffsetChange
            context.coordinator.checkOffset(clipView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onOffsetChange = onOffsetChange
        // 如果已绑定 clipView，同步检查一次
        if let clipView = context.coordinator.clipView {
            context.coordinator.checkOffset(clipView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffsetChange: onOffsetChange)
    }

    /// 从给定视图出发，向上遍历父视图链，在每一层检查其所有子视图中是否包含 NSScrollView。
    /// .background 插入的视图与 List 的 NSScrollView 是同一个父容器的兄弟节点。
    private static func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let parent = current?.superview {
            // 在兄弟节点中搜索
            for sibling in parent.subviews where sibling !== current {
                if let sv = findScrollViewInSubtree(sibling) {
                    return sv
                }
            }
            // 父节点本身是 NSScrollView
            if let sv = parent as? NSScrollView {
                return sv
            }
            current = parent
        }
        return nil
    }

    private static func findScrollViewInSubtree(_ view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for child in view.subviews {
            if let found = findScrollViewInSubtree(child) { return found }
        }
        return nil
    }

    @MainActor
    class Coordinator: NSObject {
        var onOffsetChange: (CGFloat) -> Void
        weak var clipView: NSClipView?

        init(onOffsetChange: @escaping (CGFloat) -> Void) {
            self.onOffsetChange = onOffsetChange
        }

        @objc func boundsChanged(_ notification: Notification) {
            if let clipView = notification.object as? NSClipView {
                checkOffset(clipView)
            }
        }

        func checkOffset(_ clipView: NSClipView) {
            let y = clipView.bounds.origin.y
            onOffsetChange(y)
        }
    }
}

/// 与顶部 NSToolbar 一致的 AppKit 胶囊按钮（texturedRounded bezel）。
/// 工具栏的刷新/添加按钮用 NSButton + texturedRounded 实现，这里用同一风格
/// 保证列表头与窗口工具栏视觉统一。
private struct PaperCapsuleButton: NSViewRepresentable {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        // 与顶部工具栏按钮一致:仅图标、常规尺寸,标题只作 tooltip
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        // 双保险:禁止横向拉伸(NSButton 默认水平拥抱优先级低,会被 HStack 拉宽)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        apply(to: button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        apply(to: button)
    }

    private func apply(to button: NSButton) {
        button.isEnabled = isEnabled
        button.title = ""
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.toolTip = title
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func performAction() { action() }
    }
}
#endif

private struct EntryRow: View {
    let entry: EntryListItem

    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            // 当天的：只标记时间
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            // 超过当天的：标记具体的日月
            return date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            // 超过今年的：标记具体的年月
            return date.formatted(.dateTime.year().month(.abbreviated))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(entry.isRead ? .clear : PaperTheme.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityLabel(I18N.shared.localized(entry.isRead ? "已读" : "未读"))
            VStack(alignment: .leading, spacing: 5) {
                // Title 独占整行（当隐藏 Desc 时扩展显示至 4 行，确保与普通文章高度一致）
                Text(entry.title)
                    .font(.system(.headline, design: .serif).weight(entry.isRead ? .regular : .semibold))
                    .tracking(0.1)
                    .lineLimit(entry.isSummaryVisible ? 2 : 4)

                // Desc 独占整行（仅在非冗余时渲染）
                if entry.isSummaryVisible {
                    Text(entry.summaryPreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // 最下行：左侧为 [icon、name] 与 [source]，右侧为 [日期]
                HStack(alignment: .center, spacing: 6) {
                    FeedFaviconView(feedID: entry.feedID, iconURL: entry.feedIconURL, title: entry.sourceTitle, size: 14)
                    Text(entry.sourceTitle)
                        .lineLimit(1)

                    if !entry.accountSourceBadge.isEmpty {
                        Text(entry.accountSourceBadge)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .lineLimit(1)
                    }

                    if entry.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(PaperTheme.warmAccent)
                    }

                    Spacer(minLength: 8)

                    if let date = entry.publishedAt {
                        Text(formattedDate(date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(I18N.localized("单击以在右侧打开文章"))
    }
}

private struct AddFeedSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var folder = ""
    @State private var isSubmitting = false

    private var usesInsecureHTTP: Bool {
        let candidate = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.lowercased().hasPrefix("http://")
    }

    private var canSubmit: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    feedURLField
                    folderField

                    Text(I18N.localized("保存后会立即抓取一次 Feed。PaperRss 只保存订阅地址、文章和阅读状态。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(I18N.localized("添加订阅"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(I18N.localized("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(I18N.localized("添加"))
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 320)
        #else
        .presentationDetents([.medium])
        #endif
    }

    private var feedURLField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(I18N.localized("订阅地址"), systemImage: "link")
                .font(.headline)

            TextField(I18N.localized("https://example.com/feed.xml"), text: $url)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                #if os(iOS)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .onSubmit(submit)

            if usesInsecureHTTP {
                Label(I18N.localized("这是未加密的 HTTP 地址，内容可能被网络中间人篡改。仅在你信任该来源时使用。"), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var folderField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(I18N.localized("可选分类"), systemImage: "folder")
                .font(.headline)

            TextField(I18N.localized("例如：技术"), text: $folder)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            await store.addFeed(urlText: url, folder: folder)
            await MainActor.run {
                isSubmitting = false
                dismiss()
            }
        }
    }
}

extension UTType {
    static var opml: UTType {
        UTType(importedAs: "public.opml", conformingTo: .xml)
    }
}

private struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        var types: [UTType] = [.xml, .opml]
        if let extType = UTType(filenameExtension: "opml") { types.append(extType) }
        if let extTypeUpper = UTType(filenameExtension: "OPML") { types.append(extTypeUpper) }
        return types
    }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct FolderIdentifiable: Identifiable {
    var id: String { name }
    let name: String
}

private struct AddFolderSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""

    private var canSubmit: Bool {
        !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(I18N.localized("文件夹名称"), systemImage: "folder")
                    .font(.headline)

                TextField(I18N.localized("例如：科技、新闻、设计"), text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)

                Text(I18N.localized("创建后可以将订阅源拖拽归类到此文件夹中。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(24)
            .navigationTitle(I18N.localized("新建文件夹"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(I18N.localized("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(I18N.localized("创建"), action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 450, minHeight: 220)
        #else
        .presentationDetents([.height(260)])
        #endif
    }

    private func submit() {
        guard canSubmit else { return }
        store.addFolder(folderName)
        dismiss()
    }
}

private struct RenameFolderSheet: View {
    @ObservedObject var store: AppStore
    let oldName: String
    /// Called with the final folder name after a successful rename so the
    /// parent can keep the sidebar selection in sync.
    var onRename: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var newName: String = ""

    init(store: AppStore, oldName: String, onRename: ((String) -> Void)? = nil) {
        self.store = store
        self.oldName = oldName
        self.onRename = onRename
        _newName = State(initialValue: oldName)
    }

    private var canSubmit: Bool {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean != oldName else { return false }
        // 禁止重名：renameFolder 会把两个文件夹静默合并。
        return !store.folders.contains { $0 == clean }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(I18N.localized("新文件夹名称"), systemImage: "pencil")
                    .font(.headline)

                TextField(I18N.localized("文件夹名称"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)

                Spacer()
            }
            .padding(24)
            .navigationTitle(I18N.localized("重命名文件夹"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(I18N.localized("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(I18N.localized("保存"), action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 450, minHeight: 200)
        #else
        .presentationDetents([.height(220)])
        #endif
    }

    private func submit() {
        guard canSubmit else { return }
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameFolder(from: oldName, to: clean)
        onRename?(clean)
        dismiss()
    }
}
