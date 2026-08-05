import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
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
    case folder(String)
    case feed(UUID)

    var title: String {
        switch self {
        case .today: "今天"
        case .unread: "未读"
        case .starred: "收藏"
        case let .folder(name): name
        case .feed: "订阅"
        }
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SidebarSelection? = .today
    // Keep selection independent from the value-semantic Entry model. Reading an
    // item updates its `isRead` / `updatedAt` fields, which used to invalidate the
    // List's synthesized Hashable selection after the first click. A stable ID
    // makes selection, focus, and the visible detail all describe the same item.
    @State private var selectedEntryID: String?
    @State private var showsAddFeed = false
    @State private var showsAddFolder = false
    @State private var renamingFolder: String? = nil
    @State private var showsSettings = false
    @State private var showsImporter = false
    @State private var showsExporter = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        mainContent
            .tint(PaperTheme.accent)
            .accentColor(PaperTheme.accent)
            .preferredColorScheme(store.appTheme.colorScheme)
            .task {
                #if os(iOS)
                BackgroundRefresh.schedule(interval: store.refreshInterval)
                #endif
                // 启动定时刷新循环。首刷与 interval 循环都在 AppStore 内
                // 处理，并尊重"启动时刷新"开关——此前 startAutomaticRefresh
                // 从未被调用，设置里的刷新间隔选项完全不生效。
                store.startAutomaticRefresh()
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
                    if case let .folder(current) = selection, current == folder.name {
                        selection = .folder(newName)
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showsSettings) { NavigationStack { SettingsView(store: store).navigationTitle("设置") } }
            #endif
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.xml]) { result in
                guard case let .success(url) = result else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                Task { await store.importOPML(data) }
            }
            .fileExporter(isPresented: $showsExporter, document: OPMLDocument(data: store.exportOPML()), contentType: .xml, defaultFilename: "PaperRss-Subscriptions") { _ in }
            .alert("PaperRss", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.dismissError() } })) {
                Button("好", role: .cancel) { store.dismissError() }
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
            content: EntryListView(store: store, selection: selection ?? .today, selectedEntryID: $selectedEntryID)
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
                showsReaderCapsule: selectedEntryID != nil,
                readerCapsule: AnyView(readerToolbarCapsule)
            )
        )
        .ignoresSafeArea()
        #else
        // iOS: 保留 NavigationSplitView
        NavigationSplitView {
            SidebarView(
                store: store,
                selection: sidebarSelection,
                showsAddFeed: $showsAddFeed,
                showsAddFolder: $showsAddFolder,
                renamingFolder: $renamingFolder,
                showsSettings: $showsSettings,
                showsImporter: $showsImporter,
                showsExporter: $showsExporter,
                onDeleteSelection: { selectedEntryID = nil }
            )
        } content: {
            EntryListView(store: store, selection: selection ?? .today, selectedEntryID: $selectedEntryID)
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

    private var currentDisplayEntries: [EntryListItem] {
        switch currentSelection {
        case .today: return store.todayEntryListItems
        case .unread: return store.unreadEntryListItems
        case .starred: return store.starredEntryListItems
        case let .folder(folder): return store.entryListItems(folder: folder)
        case let .feed(id): return store.entryListItems(feedID: id)
        }
    }

    private var currentHasUnread: Bool {
        currentDisplayEntries.contains { !$0.isRead }
    }

    private func markCurrentAllRead() {
        let unreadIDs = Array(currentDisplayEntries.lazy.filter { !$0.isRead }.map(\.id))
        store.markRead(entryIDs: unreadIDs, read: true)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedEntry {
            ArticleReaderView(store: store, entry: selectedEntry)
                .ignoresSafeArea()
        } else {
            emptyDetailPlaceholder
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
                selectedEntryID = nil
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
                disabled: store.activeAIRequest != nil,
                onToggleBilingual: {
                    store.toggleBilingualMode(for: current.id)
                },
                onToggleRead: {
                    store.markRead(current, read: !current.isRead)
                },
                onToggleStar: {
                    store.toggleStar(current)
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
            ContentUnavailableView("选择一篇文章", systemImage: "newspaper", description: Text("从列表中打开文章开始阅读。"))
        }
        .ignoresSafeArea()
    }
}

private struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Binding var selection: SidebarSelection?
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
    @State private var expandedFolders: Set<String> = []
    @Environment(\.colorScheme) private var colorScheme

    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        List(selection: $selection) {
            readingSection
            subscriptionsSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onAppear {
            expandedFolders = Set(store.folders)
        }
        .onChange(of: store.folders) { _, newFolders in
            expandedFolders.formUnion(newFolders)
        }
        .overlay {
            if store.feeds.isEmpty {
                ContentUnavailableView {
                    Label("还没有订阅", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("添加一个 RSS 地址，或导入 OPML 文件。")
                } actions: {
                    Button("添加订阅") { showsAddFeed = true }
                }
                .padding()
            }
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
    }
    @ViewBuilder
    private var settingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.15)
            HStack {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("设置")
                .help("设置")

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
        Section("阅读") {
            SidebarRow("今天", systemImage: "sun.max", count: store.todayUnreadCount)
                .tag(SidebarSelection.today)
            SidebarRow("未读", systemImage: "circle", count: store.unreadEntries.count)
                .tag(SidebarSelection.unread)
            SidebarRow("收藏", systemImage: "star", count: store.starredEntries.count)
                .tag(SidebarSelection.starred)
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        Section {
            ForEach(store.rootFeeds) { feed in
                feedRow(feed)
            }
            .onMove { fromOffsets, toOffset in
                store.reorderRootFeeds(fromOffsets: fromOffsets, toOffset: toOffset)
            }

            ForEach(store.folders, id: \.self) { folder in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedFolders.contains(folder) },
                        set: { isExpanded in
                            if isExpanded { expandedFolders.insert(folder) } else { expandedFolders.remove(folder) }
                        }
                    ),
                    content: {
                        ForEach(store.feeds(in: folder)) { feed in
                            feedRow(feed, inFolder: true)
                        }
                        .onMove { fromOffsets, toOffset in
                            store.reorderFeeds(in: folder, fromOffsets: fromOffsets, toOffset: toOffset)
                        }
                    },
                    label: {
                        folderRow(folder)
                    }
                )
            }
            .onMove { fromOffsets, toOffset in
                store.reorderFolders(fromOffsets: fromOffsets, toOffset: toOffset)
            }
        } header: {
            SubscriptionsHeaderView { feedID in
                store.setFeedFolder(feedID: feedID, folder: nil)
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
        .accessibilityLabel("手动刷新")
        .help("刷新所有订阅")
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
            Button { showsAddFeed = true } label: { Label("添加订阅", systemImage: "plus") }
            Button { showsAddFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
            Divider()
            Button { showsImporter = true } label: { Label("导入 OPML", systemImage: "square.and.arrow.down") }
            Button { showsExporter = true } label: { Label("导出 OPML", systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("新建与更多")
        .help("添加订阅或新建文件夹")
    }

    @ViewBuilder
    private func folderRow(_ folder: String) -> some View {
        FolderRowView(folder: folder, unreadCount: store.unreadCount(folder: folder)) { feedID in
            store.setFeedFolder(feedID: feedID, folder: folder)
            expandedFolders.insert(folder)
        }
        .contentShape(Rectangle())
        .tag(SidebarSelection.folder(folder))
        .onTapGesture {
            if selection == .folder(folder) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedFolders.contains(folder) {
                        expandedFolders.remove(folder)
                    } else {
                        expandedFolders.insert(folder)
                    }
                }
            } else {
                selection = .folder(folder)
                _ = withAnimation(.easeInOut(duration: 0.2)) {
                    expandedFolders.insert(folder)
                }
            }
        }
            .contextMenu {
                Button {
                    let unreadIDs = store.entryListItems(folder: folder).filter { !$0.isRead }.map { $0.id }
                    store.markRead(entryIDs: unreadIDs)
                } label: {
                    Label("全部已读", systemImage: "checkmark.circle")
                }

                Button {
                    renamingFolder = folder
                } label: {
                    Label("重命名文件夹", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    store.deleteFolder(folder)
                    if case let .folder(f) = selection, f == folder {
                        selection = .today
                    }
                    onDeleteSelection()
                } label: {
                    Label("删除文件夹", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed, inFolder: Bool = false) -> some View {
        SidebarRow(feed.title, systemImage: "dot.radiowaves.left.and.right", iconURL: feed.iconURL, count: store.unreadCount(feedID: feed.id))
            .padding(.leading, inFolder ? -12 : 0)
            .tag(SidebarSelection.feed(feed.id))
            .draggable(feed.id.uuidString) {
                HStack(spacing: 6) {
                    if let iconURL = feed.iconURL {
                        FeedFaviconView(iconURL: iconURL, title: feed.title, size: 14)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(PaperTheme.accent)
                    }
                    Text(feed.title)
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PaperTheme.surface(.sidebar, scheme: colorScheme), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }
            .contextMenu {
                Button {
                    let unreadIDs = store.entryListItems(feedID: feed.id).filter { !$0.isRead }.map { $0.id }
                    store.markRead(entryIDs: unreadIDs)
                } label: {
                    Label("全部已读", systemImage: "checkmark.circle")
                }

                Button {
                    copyToClipboard(feed.feedURL.absoluteString)
                } label: {
                    Label("复制订阅", systemImage: "doc.on.doc")
                }

                Menu {
                    Button {
                        store.setFeedFolder(feed, folder: nil)
                    } label: {
                        if feed.folder == nil {
                            Label("无分类", systemImage: "checkmark")
                        } else {
                            Text("无分类")
                        }
                    }

                    if !store.folders.isEmpty {
                        Divider()
                        ForEach(store.folders, id: \.self) { targetFolder in
                            Button {
                                store.setFeedFolder(feed, folder: targetFolder)
                                expandedFolders.insert(targetFolder)
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
                        Label("新建文件夹...", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("移动到文件夹", systemImage: "folder")
                }

                Divider()

                Button(role: .destructive) {
                    store.deleteFeed(feed)
                    if selection == .feed(feed.id) {
                        selection = .today
                    }
                    onDeleteSelection()
                } label: {
                    Label("删除订阅", systemImage: "trash")
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
}

private struct FeedFaviconView: View {
    let iconURL: URL?
    let title: String
    var size: CGFloat = 16

    var body: some View {
        if let iconURL {
            AsyncImage(url: iconURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size > 15 ? 4 : 3, style: .continuous))
                default:
                    fallbackBadge
                }
            }
        } else {
            fallbackBadge
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

    init(_ title: String, systemImage: String, iconURL: URL? = nil, count: Int = 0) {
        self.title = title
        self.systemImage = systemImage
        self.iconURL = iconURL
        self.count = count
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let iconURL {
                    FeedFaviconView(iconURL: iconURL, title: title, size: 16)
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
    let onDrop: (UUID) -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Text("订阅源")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isTargeted ? PaperTheme.accent : .secondary)
            if isTargeted {
                Text("(移出文件夹)")
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
            guard let idString = items.first, let feedID = UUID(uuidString: idString) else { return false }
            onDrop(feedID)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

private struct FolderRowView: View {
    let folder: String
    let unreadCount: Int
    let onDrop: (UUID) -> Void

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
                guard let idString = items.first, let feedID = UUID(uuidString: idString) else { return false }
                onDrop(feedID)
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
    @State private var retainedUnreadIDs: Set<String> = []

    private var displayEntries: [EntryListItem] {
        switch selection {
        case .today: return store.todayEntryListItems
        case .unread: return store.unreadEntryListItems(retainingIDs: retainedUnreadIDs)
        case .starred: return store.starredEntryListItems
        case let .folder(folder): return store.entryListItems(folder: folder).filter { !$0.isRead || retainedUnreadIDs.contains($0.id) }
        case let .feed(id): return store.entryListItems(feedID: id)
        }
    }

    private var hasUnread: Bool {
        displayEntries.contains { !$0.isRead }
    }

    /// 将当前列表全部标为已读。
    /// 未读/文件夹列表会同步清空 `retainedUnreadIDs`（保留正在阅读的文章），
    /// 否则已打开的文章会以已读状态继续留在列表里，看起来像“全部已读”没生效。
    private func markAllRead() {
        let unreadIDs = Array(displayEntries.lazy.filter { !$0.isRead }.map(\.id))
        store.markRead(entryIDs: unreadIDs, read: true)
        retainedUnreadIDs = selectedEntryID.map { [$0] } ?? []
    }

    var body: some View {
        List(selection: $selectedEntryID) {
            ForEach(displayEntries) { entry in
                EntryRow(entry: entry)
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button(entry.isRead ? "标为未读" : "标为已读") {
                            store.markRead(entryID: entry.id, read: !entry.isRead)
                        }
                        Button(entry.isStarred ? "取消收藏" : "收藏") {
                            store.toggleStar(entryID: entry.id)
                        }
                    }
                }
        }
        #if os(macOS)
        .listStyle(.inset(alternatesRowBackgrounds: false))
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
        .onChange(of: selectedEntryID) { _, newID in
            if let newID {
                retainedUnreadIDs.insert(newID)
            }
        }
        .onChange(of: selection) { _, _ in
            retainedUnreadIDs.removeAll()
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    markAllRead()
                } label: {
                    Label("全部标为已读", systemImage: "envelope.open")
                }
                .help("将当前列表全部标为已读")
                .disabled(!hasUnread)
            }
        }
        #endif
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 52)
        }
        #endif
        .overlay {
            if displayEntries.isEmpty {
                ContentUnavailableView("没有文章", systemImage: "text.line.first.and.arrowtriangle.forward", description: Text(store.feeds.isEmpty ? "添加订阅后，这里会显示文章。" : "切换到其他分类，或等待下一次订阅更新。"))
            }
        }
    }
}

#if os(macOS)
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

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(entry.isRead ? .clear : PaperTheme.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityLabel(entry.isRead ? "已读" : "未读")
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.system(.headline, design: .serif).weight(entry.isRead ? .regular : .semibold))
                    .tracking(0.1)
                    .lineLimit(2)
                Text(entry.summaryPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    FeedFaviconView(iconURL: entry.feedIconURL, title: entry.sourceTitle, size: 14)
                    Text(entry.sourceTitle)
                    if entry.isStarred { Image(systemName: "star.fill").foregroundStyle(PaperTheme.warmAccent) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let date = entry.publishedAt {
                Text(date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("单击以在右侧打开文章")
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

                    Text("保存后会立即抓取一次 Feed。PaperRss 只保存订阅地址、文章和阅读状态。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("添加订阅")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("添加")
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
            Label("订阅地址", systemImage: "link")
                .font(.headline)

            TextField("https://example.com/feed.xml", text: $url)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                #if os(iOS)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .onSubmit(submit)

            if usesInsecureHTTP {
                Label("这是未加密的 HTTP 地址，内容可能被网络中间人篡改。仅在你信任该来源时使用。", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var folderField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("可选分类", systemImage: "folder")
                .font(.headline)

            TextField("例如：技术", text: $folder)
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

private struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
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
                Label("文件夹名称", systemImage: "folder")
                    .font(.headline)

                TextField("例如：科技、新闻、设计", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)

                Text("创建后可以将订阅源拖拽归类到此文件夹中。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(24)
            .navigationTitle("新建文件夹")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建", action: submit)
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
                Label("新文件夹名称", systemImage: "pencil")
                    .font(.headline)

                TextField("文件夹名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)

                Spacer()
            }
            .padding(24)
            .navigationTitle("重命名文件夹")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: submit)
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
