import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import PaperRssCore
#endif

enum SidebarSelection: Hashable {
    case today
    case all
    case unread
    case starred
    case folder(String)
    case feed(UUID)

    var title: String {
        switch self {
        case .today: "今天"
        case .all: "全部文章"
        case .unread: "未读"
        case .starred: "收藏"
        case let .folder(name): name
        case .feed: "订阅"
        }
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SidebarSelection? = .all
    // Keep selection independent from the value-semantic Entry model. Reading an
    // item updates its `isRead` / `updatedAt` fields, which used to invalidate the
    // List's synthesized Hashable selection after the first click. A stable ID
    // makes selection, focus, and the visible detail all describe the same item.
    @State private var selectedEntryID: String?
    @State private var showsAddFeed = false
    @State private var showsSettings = false
    @State private var showsImporter = false
    @State private var showsExporter = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let columnWidths = ReaderColumnWidths(totalWidth: geometry.size.width)

            NavigationSplitView {
                SidebarView(
                    store: store,
                    selection: sidebarSelection,
                    showsAddFeed: $showsAddFeed,
                    showsSettings: $showsSettings,
                    showsImporter: $showsImporter,
                    showsExporter: $showsExporter
                )
                    .navigationTitle("Paper RSS")
                    .navigationSplitViewColumnWidth(columnWidths.sidebar)
            } content: {
                EntryListView(store: store, selection: selection ?? .all, selectedEntryID: $selectedEntryID)
                    .navigationSplitViewColumnWidth(columnWidths.entryList)
            } detail: {
                if let selectedEntry {
                    ArticleReaderView(store: store, entry: selectedEntry)
                } else {
                    ZStack {
                        PaperSurface(kind: .page)
                        ContentUnavailableView("选择一篇文章", systemImage: "newspaper", description: Text("从列表中打开文章开始阅读。"))
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .tint(PaperTheme.accent)
        .accentColor(PaperTheme.accent)
        #if os(macOS)
        .toolbarBackground(PaperTheme.chromeBackground(scheme: colorScheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        #endif
        .task {
            #if os(iOS)
            BackgroundRefresh.schedule()
            #endif
            await store.refresh()
        }
        .sheet(isPresented: $showsAddFeed) { AddFeedSheet(store: store) }
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
}

/// Keeps the reading canvas at the golden-ratio share of the window on normal
/// Mac widths. Very narrow or ultra-wide windows clamp the supporting columns
/// so the feed names and article previews remain usable.
private struct ReaderColumnWidths {
    private static let detailRatio: CGFloat = 0.618
    private static let sidebarShare: CGFloat = 0.157

    let sidebar: CGFloat
    let entryList: CGFloat

    init(totalWidth: CGFloat) {
        let supportingWidth = totalWidth * (1 - Self.detailRatio)
        sidebar = min(max(totalWidth * Self.sidebarShare, 190), 260)
        entryList = min(max(supportingWidth - sidebar, 290), 520)
    }
}

private struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Binding var selection: SidebarSelection?
    @Binding var showsAddFeed: Bool
    @Binding var showsSettings: Bool
    @Binding var showsImporter: Bool
    @Binding var showsExporter: Bool
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        List(selection: $selection) {
            Section("阅读") {
                SidebarRow("今天", systemImage: "sun.max", count: store.todayEntries.count)
                    .tag(SidebarSelection.today)
                SidebarRow("全部文章", systemImage: "tray.full", count: store.entries.count)
                    .tag(SidebarSelection.all)
                SidebarRow("未读", systemImage: "circle", count: store.unreadEntries.count)
                    .tag(SidebarSelection.unread)
                SidebarRow("收藏", systemImage: "star", count: store.starredEntries.count)
                    .tag(SidebarSelection.starred)
            }
            if !store.folders.isEmpty {
                Section("文件夹") {
                    ForEach(store.folders, id: \.self) { folder in
                        SidebarRow(folder, systemImage: "folder", count: store.unreadCount(folder: folder))
                            .tag(SidebarSelection.folder(folder))
                    }
                }
            }
            Section("订阅源") {
                ForEach(store.feeds) { feed in
                    SidebarRow(feed.title, systemImage: "dot.radiowaves.left.and.right", iconURL: feed.iconURL, count: store.unreadCount(feedID: feed.id))
                        .tag(SidebarSelection.feed(feed.id))
                        .contextMenu {
                            Button("删除订阅", role: .destructive) {
                                store.deleteFeed(feed)
                                if selection == .feed(feed.id) {
                                    selection = .all
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(PaperSurface(kind: .sidebar, textureOpacity: 0.52))
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
            HStack(spacing: 8) {
                ControlGroup {
                    Button(action: showSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                    .help("设置")

                    Button { showsAddFeed = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加订阅")
                    .help("添加订阅")

                    Menu {
                        Button("导入 OPML") { showsImporter = true }
                        Button("导出 OPML") { showsExporter = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多订阅操作")
                    .help("更多订阅操作")
                }
                .controlGroupStyle(.navigation)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PaperHeaderSurface())
        }
    }

    private func showSettings() {
        #if os(macOS)
        openSettings()
        #else
        showsSettings = true
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
            if let iconURL {
                FeedFaviconView(iconURL: iconURL, title: title, size: 16)
            } else {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .frame(width: 18)
            }
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

private struct EntryListView: View {
    @ObservedObject var store: AppStore
    let selection: SidebarSelection
    @Binding var selectedEntryID: String?

    private var displayEntries: [EntryListItem] {
        switch selection {
        case .today: return store.todayEntryListItems
        case .all: return store.entryListItems
        case .unread: return store.unreadEntryListItems
        case .starred: return store.starredEntryListItems
        case let .folder(folder): return store.entryListItems(folder: folder)
        case let .feed(id): return store.entryListItems(feedID: id)
        }
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
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(PaperSurface(kind: .articleList, textureOpacity: 0.62))
        .navigationTitle(selection.title)
        .toolbar {
            if selectedEntryID != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.markRead(
                            entryIDs: Array(displayEntries.lazy.filter { !$0.isRead }.map(\.id)),
                            read: true
                        )
                    } label: {
                        Label("全部标为已读", systemImage: "envelope.open")
                    }
                    .help("将当前列表全部标为已读")
                    .disabled(!displayEntries.contains { !$0.isRead })
                }
            }
        }
        .overlay {
            if displayEntries.isEmpty {
                ContentUnavailableView("没有文章", systemImage: "text.line.first.and.arrowtriangle.forward", description: Text(store.feeds.isEmpty ? "添加订阅后，这里会显示文章。" : "切换到其他分类，或等待下一次订阅更新。"))
            }
        }
    }
}

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
