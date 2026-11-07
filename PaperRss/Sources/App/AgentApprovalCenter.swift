import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif
#if os(macOS)
import AppKit
#endif

/// App-owned consent queue. No IPC route can invoke its decision callbacks.
@MainActor
final class AgentApprovalCenter: ObservableObject {
    struct Key: Hashable { let sessionID: String; let planID: String }
    struct Request: Identifiable {
        let sessionID: String
        let planID: String
        let clientLabel: String?
        let actionKind: String
        let accountName: String
        let accountType: String
        let summary: String
        let affectedCount: Int
        let sampleTitles: [String]
        let destructiveHint: Bool
        let feedChanges: [(String, String)]
        let affectedFeeds: [AgentFeedPreview]
        let notice: String
        let expiresAt: Date
        let summaryEnglish: String?
        init(sessionID: String, planID: String, clientLabel: String?, actionKind: String,
             accountName: String, accountType: String, summary: String, affectedCount: Int,
             sampleTitles: [String], notice: String, expiresAt: Date, summaryEnglish: String? = nil,
             destructiveHint: Bool = false, feedChanges: [(String, String)] = [],
             affectedFeeds: [AgentFeedPreview] = []) {
            self.sessionID = sessionID
            self.planID = planID
            self.clientLabel = clientLabel
            self.actionKind = actionKind
            self.accountName = accountName
            self.accountType = accountType
            self.summary = summary
            self.affectedCount = affectedCount
            self.sampleTitles = sampleTitles
            self.notice = notice
            self.expiresAt = expiresAt
            self.summaryEnglish = summaryEnglish
            self.destructiveHint = destructiveHint
            self.feedChanges = feedChanges
            self.affectedFeeds = affectedFeeds
        }
        var id: Key { Key(sessionID: sessionID, planID: planID) }
        var isDestructive: Bool { destructiveHint || actionKind == "remove_feed" }
        var isFeedManagement: Bool { ["add_feed", "rename_feed", "remove_feed", "manage_feeds"].contains(actionKind) }
        @MainActor var warning: String {
            if isDestructive {
                return I18N.shared.localized("删除订阅源会移除其中的文章（包括收藏），并同步到该账号。此操作不可撤销。",
                    "Removing this feed deletes its articles, including starred articles, and updates this account. This cannot be undone.")
            }
            return ""
        }
    }
    typealias Decision = @MainActor () async throws -> Void
    private struct Actions { let approve: Decision; let deny: Decision }
    @Published private(set) var pending: [Request] = []
    @Published private(set) var busy: Set<Key> = []
    @Published private(set) var failed: Set<Key> = []
    private var actions: [Key: Actions] = [:]
    weak var store: AppStore?
    private let showPanel: Bool
    private let clock: () -> Date
    private var expiryTask: Task<Void, Never>?
    #if os(macOS)
    private var panel: NSPanel?
    #endif

    init(showPanel: Bool = true, clock: @escaping () -> Date = Date.init) {
        self.showPanel = showPanel
        self.clock = clock
    }

    func register(_ request: Request, approve: @escaping Decision, deny: @escaping Decision) {
        guard request.expiresAt > clock(), actions[request.id] == nil else { return }
        actions[request.id] = Actions(approve: approve, deny: deny)
        pending.append(request)
        scheduleExpiry()
        #if os(macOS)
        if showPanel { presentPanel() }
        #endif
    }

    func remove(sessionID: String) {
        for request in pending where request.sessionID == sessionID { actions.removeValue(forKey: request.id) }
        pending.removeAll { $0.sessionID == sessionID }
        didRemove()
    }

    func removeAll() {
        actions.removeAll()
        pending.removeAll()
        didRemove()
    }

    func expire() {
        let now = clock()
        for request in pending where request.expiresAt <= now { actions.removeValue(forKey: request.id) }
        pending.removeAll { $0.expiresAt <= now }
        didRemove()
    }

    /// Called by the two App buttons only; neither decision is a wire operation.
    func approve(_ request: Request) async { await decide(request, approval: true) }
    func deny(_ request: Request) async { await decide(request, approval: false) }

    private func decide(_ request: Request, approval: Bool) async {
        expire()
        guard let action = actions[request.id], !busy.contains(request.id) else { return }
        busy.insert(request.id)
        failed.remove(request.id)
        do {
            try await (approval ? action.approve : action.deny)()
            actions.removeValue(forKey: request.id)
            pending.removeAll { $0.id == request.id }
        } catch {
            // Do not display arbitrary provider errors or private account details.
            if actions[request.id] != nil { failed.insert(request.id) }
        }
        busy.remove(request.id)
        didRemove()
    }

    private func didRemove() {
        let keys = Set(pending.map(\.id))
        busy.formIntersection(keys)
        failed.formIntersection(keys)
        scheduleExpiry()
        #if os(macOS)
        if pending.isEmpty { panel?.orderOut(nil) }
        #endif
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let expiry = pending.map(\.expiresAt).min() else { expiryTask = nil; return }
        let delay = max(0.001, min(expiry.timeIntervalSince(clock()), 900))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.expire()
        }
    }

    #if os(macOS)
    private func presentPanel() {
        guard let store else { return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: AgentApprovalList(center: self)
                .environmentObject(store)
                .environmentObject(store.iconStore)
                .frame(minWidth: 400, minHeight: 200).accessibilityIdentifier("agent.approval.panel"))
            window.center()
            panel = window
        }
        updatePanelTitle()
        panel?.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }
    #endif

    fileprivate func fitPanel(to contentHeight: CGFloat) {
        #if os(macOS)
        guard let panel, !pending.isEmpty, contentHeight > 0 else { return }
        let availableHeight = (panel.screen?.visibleFrame.height ?? 800) - 100
        let height = min(max(200, contentHeight), min(560, availableHeight))
        let size = panel.frameRect(forContentRect: NSRect(x: 0, y: 0,
            width: panel.contentLayoutRect.width, height: height)).size
        guard abs(panel.frame.height - size.height) > 1 else { return }
        // Keep the top edge stable as requests arrive, expire, or change language.
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height,
            width: size.width, height: size.height), display: true)
        #endif
    }

    fileprivate func updatePanelTitle() {
        #if os(macOS)
        panel?.title = "PaperRss MCP"
        #endif
    }
}

struct AgentApprovalList: View {
    @ObservedObject var center: AgentApprovalCenter
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var i18n = I18N.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(center.pending) { request in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: source(request.clientLabel)).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(verbatim: actionTitle(request.actionKind))
                            .font(.system(size: 18, weight: .semibold))
                        Text(verbatim: clipped(request.accountName, limit: 120) + " · " + clipped(request.accountType, limit: 40))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        feedPreview(request)
                        Text(verbatim: shortSummary(request))
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(request.feedChanges.indices, id: \.self) { index in
                            Text(verbatim: "\(index + 1). " + i18n.localized(request.feedChanges[index].0, request.feedChanges[index].1))
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if request.isDestructive {
                            Text(verbatim: request.warning)
                                .font(.system(size: 13)).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("agent.approval.warning.\(request.planID)")
                        }
                        if center.failed.contains(request.id) {
                            Text(i18n.localized("操作未完成，请重试。", "Could not complete the decision. Please retry."))
                                .font(.system(size: 13)).foregroundStyle(.red)
                        }
                        HStack(spacing: 8) {
                            Spacer()
                            Button(i18n.localized("拒绝", "Deny")) { Task { await center.deny(request) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("agent.approval.deny.\(request.planID)")
                            Button(i18n.localized("批准", "Approve")) { Task { await center.approve(request) } }
                                .buttonStyle(.borderedProminent)
                                .tint(request.isDestructive ? Color.red : Color.accentColor)
                                .accessibilityIdentifier("agent.approval.approve.\(request.planID)")
                            // Deliberately no defaultAction / Return keyboard shortcut.
                        }
                        .disabled(center.busy.contains(request.id))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(16)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AgentApprovalContentHeight.self, value: geometry.size.height)
            })
        }
        .onPreferenceChange(AgentApprovalContentHeight.self) { center.fitPanel(to: $0) }
        .onChange(of: i18n.isEnglish) { center.updatePanelTitle() }
    }

    @ViewBuilder
    private func feedPreview(_ request: AgentApprovalCenter.Request) -> some View {
        if !request.affectedFeeds.isEmpty {
            HStack(spacing: 10) {
                ForEach(request.affectedFeeds.prefix(7), id: \.id) { preview in
                    let title = clipped(preview.title, limit: 200)
                    if let id = UUID(uuidString: preview.id) {
                        FeedFaviconView(feedID: id, iconURL: store.feed(forFeedID: id)?.iconURL,
                            title: title, size: 18)
                            .help(title)
                            .accessibilityLabel(title)
                    }
                    if request.affectedFeeds.count == 1 {
                        Text(verbatim: title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                    }
                }
                if request.affectedFeeds.count > 7 {
                    Text(verbatim: "+\(request.affectedFeeds.count - 7)")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .help(request.affectedFeeds.dropFirst(7).map(\.title).joined(separator: "\n"))
                }
                Spacer(minLength: 8)
                impactCapsule(request)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } else {
            impactCapsule(request)
        }
    }

    @ViewBuilder
    private func impactCapsule(_ request: AgentApprovalCenter.Request) -> some View {
        if request.affectedCount > 0 {
            Text(verbatim: i18n.localized("影响 \(request.affectedCount) 篇", "Affects \(request.affectedCount) articles"))
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    private func shortSummary(_ request: AgentApprovalCenter.Request) -> String {
        return clipped(i18n.localized(request.summary, request.summaryEnglish ?? request.summary), limit: 600)
    }

    private func actionTitle(_ kind: String) -> String {
        switch kind {
        case "manage_feeds": return i18n.localized("批量管理订阅源", "Manage Feeds")
        case "add_feed": return i18n.localized("添加订阅源", "Add Feed")
        case "rename_feed": return i18n.localized("重命名订阅源", "Rename Feed")
        case "remove_feed": return i18n.localized("删除订阅源", "Remove Feed")
        case "mark_read": return i18n.localized("批量标为已读", "Mark Articles Read")
        case "state_change": return i18n.localized("更改已读或收藏状态", "Change Read or Starred State")
        default: return i18n.localized("更改文章状态", "Change Article State")
        }
    }

    private func source(_ label: String?) -> String {
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return i18n.localized("未知助手", "Unknown assistant")
        }
        return i18n.localized("来自 \(clipped(label, limit: 80))（自报）", "From \(clipped(label, limit: 80)) (self-reported)")
    }
    private func clipped(_ value: String, limit: Int) -> String {
        let plain = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(plain.prefix(limit)))
        return plain.count > limit ? text + "…" : text
    }
}

private struct AgentApprovalContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
