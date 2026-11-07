import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct ICloudAccountSetupView: View {
    @ObservedObject var store: AppStore
    @Binding var isAdding: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        AccountProviderIcon(type: .iCloud)
                        Text("iCloud")
                    }
                        .font(.title2.weight(.semibold))
                    #if os(macOS)
                    BetaBadge()
                    #endif
                }
                Text(I18N.localized("使用系统设置中的 iCloud 账号，在多台 Mac 之间同步阅读。", englishFallback: "Use the iCloud account in System Settings to sync your reading across Macs."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    Label(I18N.localized("同步订阅、目录、已读和收藏", englishFallback: "Sync feeds, folders, read and starred states"), systemImage: "arrow.triangle.2.circlepath")
                    Label(I18N.localized("保留收藏的 RSS 原正文", englishFallback: "Keep the original RSS content of starred articles"), systemImage: "star")
                    Label(I18N.localized("现有本地和服务器账号保持独立", englishFallback: "Keep existing local and server accounts separate"), systemImage: "tray.2")
                }
                .font(.callout)
                Text(I18N.localized("未读正文默认不上传，可在添加账号后开启。AI 结果、模型设置及钥匙串中的服务凭据保持本地。", englishFallback: "Unread content is off by default and can be enabled after adding the account. AI results, model settings and service credentials in Keychain stay local."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(I18N.localized("订阅地址与 RSS 原文会进入你的 iCloud；私有链接中的访问参数也会同步。", englishFallback: "Feed addresses and original RSS content go to your iCloud, including access parameters in private feed links."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let availabilityMessage {
                    Text(availabilityMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button {
                        Task { await addAccount() }
                    } label: {
                        if isAdding { ProgressView().controlSize(.small) }
                        else { Text(I18N.localized("添加 iCloud 账号", englishFallback: "Add iCloud Account")) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAdding || !store.canAddICloudAccount)
                    .accessibilityIdentifier("icloud.addAccount")
                }
            }
            .padding(20)
        }
    }

    private var availabilityMessage: String? {
        switch store.iCloudAccountCreationAvailability {
        case .ready: nil
        case .alreadyExists: I18N.localized("已有 iCloud 账号，请在账号列表查看。", englishFallback: "An iCloud account already exists. Find it in the account list.")
        case .unsupportedBuild: I18N.localized("此版本暂不支持连接 iCloud，请使用支持 iCloud 的版本。", englishFallback: "This version cannot connect to iCloud. Use a version with iCloud support.")
        }
    }

    private func addAccount() async {
        guard !isAdding, store.canAddICloudAccount else { return }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do {
            _ = try await store.addICloudAccount()
            dismiss()
        } catch is CancellationError { }
        catch { errorMessage = store.iCloudErrorMessage(error) }
    }
}

struct ICloudAccountSettingsRow: View {
    @ObservedObject var store: AppStore
    let account: AccountRecord
    let isActive: Bool
    @State private var snapshot: ICloudAccountSyncSnapshot?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isAdvancedExpanded = false
    @State private var presentedSheet: SettingsSheet?

    private enum SettingsSheet: String, Identifiable {
        case inventory, recovery, residue, originalAccountResume, archiveRecovery, retention, newLibrary
        var id: String { rawValue }
    }

    private struct RefreshIdentity: Equatable {
        let syncState: AccountSyncStateRecord?
        let isSyncing: Bool
        let isEnabled: Bool
        let isActive: Bool
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot {
                    if snapshot.isPaused {
                        Label(I18N.localized("同步已暂停，本机资料已保留。", englishFallback: "Sync is paused. Your data on this Mac is retained."), systemImage: "pause.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    Toggle(isOn: Binding(
                        get: { snapshot.syncUnreadContent },
                        set: { value in Task { await saveUnreadOption(value) } }
                    )) {
                        Text(I18N.localized("同步未读文章正文", englishFallback: "Sync unread article content"))
                    }
                    .toggleStyle(.switch)
                    .disabled(isSaving)
                    .accessibilityIdentifier("icloud.syncUnreadContent")
                    .help(I18N.localized("收藏文章始终同步；开启后在多台设备间同步未读文章全文。", englishFallback: "Starred articles always sync; enable to sync full unread content across your devices."))
                    if snapshot.pendingChanges > 0 {
                        Label(I18N.shared.localizedFormat("待发送更改：%lld", snapshot.pendingChanges), systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("icloud.pendingChanges")
                    }
                    if snapshot.missingArticleIdentities > 0 {
                        Text(I18N.shared.localizedFormat("历史文章缺少原始身份：%lld，暂留本地。", snapshot.missingArticleIdentities))
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("icloud.missingIdentities")
                    }
                    if snapshot.deferredBodies > 0 {
                        Text(I18N.shared.localizedFormat("正文超过同步大小限制：%lld，仍可在本机阅读。", snapshot.deferredBodies))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("icloud.deferredBodies")
                    }
                    if snapshot.waitingArticleStates + snapshot.waitingRelationships + snapshot.waitingBodies > 0 {
                        Text(I18N.shared.localizedFormat("待恢复：文章状态 %lld，目录关系 %lld，正文 %lld。", snapshot.waitingArticleStates, snapshot.waitingRelationships, snapshot.waitingBodies))
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("icloud.inbox")
                    }
                } else if errorMessage == nil {
                    ProgressView().controlSize(.small)
                }
                if store.supportsICloudSync, let pushError = store.iCloudPushError,
                   pushError != store.accountSyncStates[account.id]?.lastError {
                    Text(pushError).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.supportsICloudSync, let errorMessage,
                   errorMessage != store.accountSyncStates[account.id]?.lastError {
                    Text(errorMessage).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Menu {
                        Button(I18N.localized("查看云端记录", englishFallback: "View Cloud Records")) {
                            presentedSheet = .inventory
                        }
                        .disabled(!account.isEnabled || !store.supportsICloudSync || snapshot?.isPaused == true)
                        .accessibilityIdentifier("icloud.cloudInventory")
                        Button(I18N.localized("审阅云端历史清理…", englishFallback: "Review Cloud History Cleanup…")) {
                            presentedSheet = .retention
                        }
                        .disabled(!account.isEnabled || !store.supportsICloudSync || snapshot?.isPaused == true)
                        .accessibilityIdentifier("icloud.retentionReview")
                        Button(I18N.localized("复核旧云资料", englishFallback: "Review Older Cloud Data")) {
                            presentedSheet = .residue
                        }
                        .disabled(!account.isEnabled || !store.supportsICloudSync)
                        .accessibilityIdentifier("icloud.cloudResidueReview")
                    } label: {
                        Label(I18N.shared.localized("云端资料", "Cloud Data"), systemImage: "icloud")
                    }
                    .accessibilityIdentifier("icloud.cloudDataMenu")

                    Menu {
                        Button(I18N.localized("查看恢复资料", englishFallback: "Review Recovery Data")) {
                            presentedSheet = .recovery
                        }
                        .accessibilityIdentifier("icloud.recoveryReview")
                        Button(I18N.localized("恢复原账号同步…", englishFallback: "Resume the Original Account’s Sync…")) {
                            presentedSheet = .originalAccountResume
                        }
                        .disabled(!account.isEnabled)
                        .accessibilityIdentifier("icloud.originalAccountResume")
                        Divider()
                        Button(I18N.localized("保留归档并恢复当前云库…", englishFallback: "Keep an Archive and Restore the Current Cloud Library…")) {
                            presentedSheet = .archiveRecovery
                        }
                        .disabled(!account.isEnabled)
                        .accessibilityIdentifier("icloud.archiveRecovery")
                        Button(I18N.localized("保留旧云资料并准备新云库…", englishFallback: "Keep Old Cloud Data and Prepare a New Library…")) {
                            presentedSheet = .newLibrary
                        }
                        .disabled(!account.isEnabled || !store.supportsICloudSync)
                        .accessibilityIdentifier("icloud.newLibraryReview")
                    } label: {
                        Label(I18N.shared.localized("恢复与重置", "Recovery & Reset"), systemImage: "arrow.counterclockwise")
                    }
                    .accessibilityIdentifier("icloud.recoveryMenu")
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 4)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(I18N.shared.localized("同步选项", "Sync Options"))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("icloud.advancedOptions")
        .font(.callout)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .inventory: ICloudCloudInventoryView(store: store, accountID: account.id)
            case .recovery: ICloudRecoveryReviewView(store: store, accountID: account.id)
            case .residue: ICloudCloudResidueReviewView(store: store, accountID: account.id)
            case .originalAccountResume: ICloudSameAccountResumeView(store: store, accountID: account.id)
            case .archiveRecovery: ICloudArchiveRecoveryView(store: store, accountID: account.id)
            case .retention: ICloudRetentionView(store: store, accountID: account.id)
            case .newLibrary: ICloudNewLibraryView(store: store, accountID: account.id)
            }
        }
        .task(id: RefreshIdentity(syncState: store.accountSyncStates[account.id],
                                 isSyncing: store.accountRefreshProgress[account.id] != nil,
                                 isEnabled: account.isEnabled, isActive: isActive)) {
            if isActive, store.accountRefreshProgress[account.id] == nil { await loadSnapshot() }
        }
    }

    private func loadSnapshot() async {
        do {
            let value = try await store.iCloudAccountSnapshot(accountID: account.id)
            guard !Task.isCancelled else { return }
            snapshot = value
            errorMessage = nil
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) }
        }
    }

    private func saveUnreadOption(_ value: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.setICloudSyncUnreadContent(accountID: account.id, enabled: value)
            await loadSnapshot()
        } catch { errorMessage = store.iCloudErrorMessage(error) }
    }
}

struct ICloudLocalArchiveSettingsRow: View {
    @ObservedObject var store: AppStore
    let account: AccountRecord
    @State private var presentedSheet: ArchiveSheet?
    private enum ArchiveSheet: String, Identifiable {
        case review, reader, copy
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox").font(.system(size: 20))
                    .foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.displayName).font(.system(size: 14, weight: .semibold))
                        #if os(macOS)
                        BetaBadge()
                        #endif
                    }
                    Text(I18N.localized("只读本机归档", englishFallback: "Read-only Local Archive"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(I18N.localized("旧文章、收藏和本机 AI 产物已保留。归档停止刷新与同步，阅读状态保持原样。", englishFallback: "Old articles, stars and local AI results are retained. Refresh and sync are stopped, and reading states are unchanged."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 40)
            HStack(spacing: 8) {
                Button(I18N.localized("阅读归档", englishFallback: "Read Archive")) { presentedSheet = .reader }
                    .controlSize(.small)
                    .accessibilityIdentifier("icloud.readArchive")
                Button(I18N.localized("选择归档资料复制到当前 iCloud…", englishFallback: "Select Archived Data to Copy to the Current iCloud Account…")) { presentedSheet = .copy }
                    .controlSize(.small)
                    .accessibilityIdentifier("icloud.copyArchive")
                Button(I18N.localized("查看恢复资料", englishFallback: "Review Recovery Data")) { presentedSheet = .review }
                    .controlSize(.small)
                    .accessibilityIdentifier("icloud.archiveRecoveryReview")
            }
            .padding(.leading, 40)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .review: ICloudRecoveryReviewView(store: store, accountID: account.id)
            case .reader: ICloudArchiveReaderView(store: store, accountID: account.id)
            case .copy: ICloudLocalCopyView(store: store, sourceAccountID: account.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icloud.localArchiveAccount")
    }
}

private struct ICloudCloudResidueReviewView: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var review: ICloudCloudResidueReview?
    @State private var errorMessage: String?
    @State private var isScanning = false
    @State private var scanRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("旧云资料复核", englishFallback: "Older Cloud Data Review"))
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(I18N.localized("只读取 iCloud 资料区和控制信息，检查旧版快照是否存在；不下载旧正文，不恢复同步或删除资料。", englishFallback: "Reads iCloud zone and control metadata and checks whether a legacy snapshot exists. It does not download old bodies, resume sync or delete data."))
                        .foregroundStyle(.secondary)
                    if let review {
                        Text(rootMessage(review.rootStatus))
                            .foregroundStyle(review.rootStatus == .ready ? Color.secondary : Color.orange)
                        Text(I18N.shared.localizedFormat("本机确认代次的资料区 %lld，其它代次资料区 %lld，旧版资料区 %lld。",
                            review.currentGenerationZones, review.otherGenerationZones, review.legacyZones))
                        if review.isComplete, review.rootStatus == .ready, review.currentGenerationZones < 2 {
                            Text(I18N.localized("当前确认代次的资料区不完整，恢复方式需要确认。", englishFallback: "Zones for the confirmed generation are incomplete. Recovery needs review."))
                                .foregroundStyle(.orange)
                        }
                        if review.unrecognizedOwnedZones > 0 {
                            Text(I18N.shared.localizedFormat("格式无法核实的 PaperRss 资料区：%lld。", review.unrecognizedOwnedZones))
                                .foregroundStyle(.orange)
                        }
                        switch review.legacySnapshot {
                        case .observed:
                            Text(I18N.localized("本次观察到旧版全库快照，尚未处理其内容。", englishFallback: "A legacy whole-library snapshot was observed. Its contents have not been processed."))
                                .foregroundStyle(.orange)
                        case .notObserved:
                            Text(I18N.localized("本次未观察到已知的旧版全库快照。", englishFallback: "No known legacy whole-library snapshot was observed."))
                                .foregroundStyle(.secondary)
                        }
                        if review.didChangeDuringReview {
                            Text(I18N.localized("复核期间云端信息发生变化，结果不完整。数量包含任一次观察到的资料区，请稍后重新复核。", englishFallback: "Cloud metadata changed during review. Results are incomplete. Counts include zones seen in either observation; review again later."))
                                .foregroundStyle(.orange)
                        } else if review.reachedSafetyLimit {
                            Text(I18N.localized("复核达到时间或数量上限，结果不完整。", englishFallback: "The review reached its time or count limit. Results are incomplete."))
                                .foregroundStyle(.orange)
                        } else if !review.isComplete {
                            Text(I18N.localized("复核结果不完整，不能据此确认旧资料已清除。", englishFallback: "The review is incomplete and cannot confirm that older data was cleared."))
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Text(I18N.localized("复核时间", englishFallback: "Reviewed at"))
                            Text(review.scannedAt, format: .dateTime.year().month().day().hour().minute())
                        }
                        .foregroundStyle(.secondary)
                    }
                    Text(I18N.localized("资料区数量不是文章或正文数量。即使两次观察一致，其它设备或迟到请求仍可能留下旧副本；本页不能证明全部云端资料已擦除。", englishFallback: "Zone counts are not article or body counts. Even matching observations cannot rule out older copies from other devices or delayed requests. This page cannot prove complete cloud erasure."))
                        .foregroundStyle(.secondary)
                    if isScanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(I18N.localized("正在复核云端元信息…", englishFallback: "Reviewing cloud metadata…"))
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(I18N.localized("重新复核", englishFallback: "Review Again")) { scanRevision += 1 }
                    .disabled(isScanning)
                Spacer()
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 360, maxHeight: 620)
        .task(id: scanRevision) { await scan() }
        .accessibilityIdentifier("icloud.cloudResidueReviewSheet")
    }

    private func rootMessage(_ status: ICloudCloudResidueReview.RootStatus) -> String {
        switch status {
        case .unbound:
            return I18N.localized("本机尚未确认云库代次，需要先确认兼容或恢复方式。", englishFallback: "This Mac has not confirmed a cloud library generation. Compatibility or recovery needs review.")
        case .ready:
            return I18N.localized("云端控制信息与本机确认的代次一致。", englishFallback: "Cloud control metadata matches the generation confirmed on this Mac.")
        case .resetting:
            return I18N.localized("云端控制信息显示正在重置，恢复方式需要确认。", englishFallback: "Cloud control metadata indicates a reset in progress. Recovery needs review.")
        case .missing:
            return I18N.localized("未观察到云端控制信息，本机资料仍保留。", englishFallback: "Cloud control metadata was not observed. Local data is retained.")
        case .incompatible:
            return I18N.localized("云端控制信息无法核实，需要先确认兼容方式。", englishFallback: "Cloud control metadata could not be verified. Compatibility needs review.")
        case .differentGeneration:
            return I18N.localized("云端控制信息与本机确认的代次不同，需要先确认恢复方式。", englishFallback: "Cloud control metadata differs from the generation confirmed on this Mac. Recovery needs review.")
        case .changedDuringReview:
            return I18N.localized("两次读取的云端控制信息不同，暂不作完成判断。", englishFallback: "The two cloud control observations differ. Completion cannot be determined.")
        }
    }

    private func scan() async {
        isScanning = true
        review = nil
        errorMessage = nil
        defer { isScanning = false }
        do {
            let result = try await store.iCloudCloudResidueReview(accountID: accountID)
            guard !Task.isCancelled else { return }
            review = result
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) }
        }
    }
}

private struct ICloudRecoveryReviewView: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var review: ICloudRecoveryReview?
    @State private var errorMessage: String?
    @State private var loadRevision = 0
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("恢复资料预览", englishFallback: "Recovery Data Review"))
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(I18N.localized("本页只统计本机资料；不连接 iCloud，不复制、上传或删除资料。", englishFallback: "This page only reviews data on this Mac. It does not connect to iCloud or copy, upload or delete data."))
                        .foregroundStyle(.secondary)
                    if let review {
                        localData(review)
                        Divider()
                        linkReview(review)
                        Divider()
                        resetReview(review)
                    }
                    if isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(I18N.localized("正在读取本机资料…", englishFallback: "Reading local data…"))
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(I18N.localized("重新统计", englishFallback: "Rescan")) { loadRevision += 1 }
                    .disabled(isLoading)
                Spacer()
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 420, maxHeight: 660)
        .task(id: loadRevision) { await load() }
        .accessibilityIdentifier("icloud.recoveryReviewSheet")
    }

    private func localData(_ review: ICloudRecoveryReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("本机保留的资料", englishFallback: "Data Retained on This Mac")).font(.headline)
            if !review.isEnabled {
                Text(I18N.localized("此账号已停用，仍可查看本机资料。", englishFallback: "This account is disabled. Its local data is still available for review."))
                    .foregroundStyle(.secondary)
            }
            if !review.hasSyncScope || !review.captureEnabled {
                Text(I18N.localized("此账号尚未启用同步记录，预览不会自动开启同步。", englishFallback: "Sync recording is inactive for this account. Reviewing data does not activate sync."))
                    .foregroundStyle(.secondary)
            }
            if let message = review.pause.message {
                Text(message).foregroundStyle(.orange)
            }
            Text(I18N.shared.localizedFormat("订阅 %lld，目录 %lld，本机文章 %lld。", review.feeds, review.folders, review.articles))
            Text(I18N.shared.localizedFormat("已读文章 %lld，收藏文章 %lld。", review.readArticles, review.starredArticles))
            Text(I18N.shared.localizedFormat("带有 RSS 正文的文章：%lld。", review.articlesWithRSSBody))
            Text(I18N.shared.localizedFormat("缺少原始身份的文章：%lld，其中收藏 %lld。", review.missingIdentities, review.starredMissingIdentities))
                .foregroundStyle(review.missingIdentities > 0 ? .orange : .secondary)
            Text(I18N.localized("统计只包括该账号未删除订阅下的资料。正文数量不代表每篇文章都能同步；缺少原始身份的历史文章仍留在本机，恢复方式待确认。", englishFallback: "Counts include data under this account’s active subscriptions. Body counts do not guarantee sync eligibility. Historical articles without original identities stay on this Mac pending recovery review."))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("icloud.recoveryLocalData")
    }

    private func linkReview(_ review: ICloudRecoveryReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("订阅链接检查", englishFallback: "Subscription Link Review")).font(.headline)
            Text(I18N.shared.localizedFormat("需要检查的订阅链接：%lld。", review.flaggedFeedLinks))
            Text(I18N.shared.localizedFormat("包含账号信息 %lld，查询参数 %lld，片段 %lld，无法核实 %lld。",
                                             review.feedLinksWithCredentials, review.feedLinksWithQuery,
                                             review.feedLinksWithFragment, review.unverifiableFeedLinks))
            Text(I18N.localized("同一链接可能计入多类。查询参数不一定是凭据，路径中也可能包含私人令牌；此检查不能识别所有敏感内容。", englishFallback: "A link can appear in several categories. Query parameters may be harmless, while paths may contain private tokens. This check cannot identify all sensitive content."))
                .foregroundStyle(.secondary)
            Text(I18N.localized("订阅地址和允许同步的 RSS 内容可能携带私人信息，启用前请确认。预览不显示完整链接，也不移除参数或改写地址。", englishFallback: "Subscription URLs and eligible RSS content may contain private information. Review them before enabling sync. This preview does not display full links, remove parameters or rewrite URLs."))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("icloud.recoveryLinkReview")
    }

    private func resetReview(_ review: ICloudRecoveryReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18N.localized("本机记录的重置进度", englishFallback: "Reset Progress Recorded on This Mac")).font(.headline)
            Text(resetMessage(review.resetProgress))
            Text(I18N.localized("此处显示本机最后记录的阶段，云端实际进度仍需核对。新云库准备好不表示全部旧云资料已擦除，也不会自动上传旧本机资料。", englishFallback: "This is the last locally recorded stage; actual cloud progress needs verification. A ready replacement library does not mean all older cloud data was erased or that old local data will upload automatically."))
                .foregroundStyle(.secondary)
            Text(I18N.localized("历史资料复制、旧缓存处理、云端删除和隐私说明仍待确认。", englishFallback: "Historical data copying, old cache handling, cloud deletion and privacy disclosures await review."))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("icloud.recoveryResetProgress")
    }

    private func resetMessage(_ progress: ICloudRecoveryReview.ResetProgress) -> String {
        switch progress {
        case .none:
            return I18N.localized("本机没有已确认的重置操作。", englishFallback: "No approved reset operation is recorded on this Mac.")
        case .prepared:
            return I18N.localized("已保存重置确认，等待核对云端进度。", englishFallback: "Reset approval is saved. Cloud progress awaits verification.")
        case .rootPublished:
            return I18N.localized("已发布重置信息，下一步建立新订阅资料区。", englishFallback: "Reset information was published. Next is creating the replacement subscription zone.")
        case .libraryCreated:
            return I18N.localized("已建立新订阅资料区，下一步建立新文章资料区。", englishFallback: "The replacement subscription zone was created. Next is creating the replacement article zone.")
        case .articlesCreated:
            return I18N.localized("已建立新资料区，下一步按已确认的方案处理旧范围。", englishFallback: "Replacement zones were created. Next is applying the approved plan for the previous scope.")
        case .libraryDeleted:
            return I18N.localized("已清除当前旧订阅资料区，下一步清除对应旧文章资料区。", englishFallback: "The previous subscription zone was cleared. Next is clearing its article zone.")
        case .articlesDeleted:
            return I18N.localized("已清除当前旧资料区，等待核对新云库是否准备好。", englishFallback: "The previous zones were cleared. The replacement library’s readiness awaits verification.")
        case .previousRetained:
            return I18N.localized("旧云端范围已保留，等待核对新云库是否准备好。", englishFallback: "The previous cloud scope was preserved. The replacement library’s readiness awaits verification.")
        case .cloudReady:
            return I18N.localized("新云库已准备好，旧本机资料的恢复方式仍待确认。", englishFallback: "The replacement cloud library is ready. Recovery of old local data awaits review.")
        case .needsReview:
            return I18N.localized("恢复记录无法核实，需要确认后再继续。", englishFallback: "The recovery record could not be verified. Review is required before continuing.")
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await store.iCloudRecoveryReview(accountID: accountID)
            guard !Task.isCancelled else { return }
            review = result
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) }
        }
    }
}

private struct ICloudCloudInventoryView: View {
    @ObservedObject var store: AppStore
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @State private var inventory: ICloudCloudInventory?
    @State private var errorMessage: String?
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.localized("云端记录统计", englishFallback: "Cloud Record Statistics"))
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let inventory {
                        Text(I18N.shared.localizedFormat("已扫描记录：%lld", inventory.recordCount))
                        if inventory.otherGenerationZones > 0 {
                            Text(I18N.shared.localizedFormat("另有 %lld 个旧资料区，尚未统计其内容。", inventory.otherGenerationZones))
                                .foregroundStyle(.secondary)
                        }
                        if inventory.otherGenerationRecords > 0 {
                            Text(I18N.shared.localizedFormat("当前云库以外的记录：%lld，未应用到本机资料。", inventory.otherGenerationRecords))
                                .foregroundStyle(.secondary)
                        }
                        Text(I18N.shared.localizedFormat("订阅 %lld，目录 %lld，目录关系 %lld。", inventory.feeds, inventory.folders, inventory.relationships))
                        Text(I18N.shared.localizedFormat("已读状态 %lld，收藏状态 %lld。", inventory.readStateRecords, inventory.starredStateRecords))
                        Text(I18N.shared.localizedFormat("正文：收藏 %lld，未读 %lld，已读 %lld。", inventory.starredBodies, inventory.unreadBodies, inventory.readBodies))
                        Text(I18N.shared.localizedFormat("缺少状态的正文 %lld，状态不完整的正文 %lld，正文删除标记 %lld。", inventory.orphanedBodies, inventory.bodiesWithIncompleteStatus, inventory.contentTombstones))
                        Text(I18N.localized("记录数包含已删除项目的同步标记。其他设备同步时，统计可能随之变化。", englishFallback: "Record counts include sync markers for deleted items. Counts may change as other devices sync."))
                            .foregroundStyle(.secondary)
                        if inventory.reachedSafetyLimit {
                            Text(I18N.localized("本次统计达到安全上限，结果不完整，暂不生成清理预览。", englishFallback: "This scan reached its safety limit. Results are incomplete and cleanup preview is unavailable."))
                                .foregroundStyle(.orange)
                        } else if !inventory.isComplete {
                            Text(I18N.localized("统计尚未完成，可继续扫描剩余记录。", englishFallback: "The scan is incomplete. Continue to scan the remaining records."))
                                .foregroundStyle(.secondary)
                        }
                        if let preview = inventory.cleanupPreview {
                            Divider()
                            Text(I18N.localized("清理预览", englishFallback: "Cleanup Preview")).font(.headline)
                            Text(I18N.shared.localizedFormat("可清理正文 %lld，超过保留期限的状态记录 %lld。", preview.removableBodies, preview.staleStateRecords))
                            Text(I18N.shared.localizedFormat("本轮预览最多 %lld 条记录；本机保留或待发送的文章 %lld。", preview.proposedRecordCount, preview.protectedArticles))
                            if preview.hasUnresolvedLocalChanges {
                                Text(I18N.localized("本机有未确认的选项或文章身份，已暂停清理候选计算。", englishFallback: "Unconfirmed local settings or article identities are holding cleanup candidate calculation."))
                                    .foregroundStyle(.orange)
                            }
                            Text(I18N.localized("预览按 183 天保留期限、每轮最多 400 条记录计算。保留规则仍待确认，预览不会删除云端或本机资料。", englishFallback: "The preview uses a 183-day retention period and a limit of 400 records per run. Retention rules await review. The preview does not delete cloud or local data."))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if isScanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(I18N.localized("正在读取云端记录…", englishFallback: "Reading cloud records…"))
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(I18N.localized("重新统计", englishFallback: "Rescan")) { startScan(reset: true) }
                    .disabled(isScanning)
                if let inventory, !inventory.isComplete, !inventory.reachedSafetyLimit {
                    Button(I18N.localized("继续扫描", englishFallback: "Continue Scan")) { startScan(reset: false) }
                        .disabled(isScanning)
                }
                Spacer()
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360, maxHeight: 620)
        .onAppear { startScan(reset: true) }
        .onDisappear { scanTask?.cancel() }
        .accessibilityIdentifier("icloud.cloudInventorySheet")
    }

    private func startScan(reset: Bool) {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        if reset { inventory = nil }
        scanTask = Task {
            defer { isScanning = false }
            do {
                let result = try await store.iCloudCloudInventory(accountID: accountID, reset: reset)
                guard !Task.isCancelled else { return }
                inventory = result
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { errorMessage = store.iCloudErrorMessage(error) }
            }
        }
    }
}
