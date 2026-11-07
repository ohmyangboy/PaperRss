import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct OPMLImportSheet: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var i18n = I18N.shared
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: String
    @State private var showsFilePicker = false
    @State private var data: Data?
    @State private var fileName = ""
    @State private var isImporting = false
    @State private var result: SubscriptionImportResult?
    @State private var error: String?

    init(store: AppStore) {
        self.store = store
        _accountID = State(initialValue: store.subscriptionAccounts.first { $0.id == store.activeAccountID }?.id
            ?? store.subscriptionAccounts.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(i18n.localized("导入 OPML", "Import OPML")).font(.title2.bold())
            Picker(i18n.localized("目标账号", "Destination Account"), selection: $accountID) {
                ForEach(store.subscriptionAccounts) { account in
                    Text(account.displayName).tag(account.id)
                }
            }
            .accessibilityIdentifier("opml.import.account")
            .disabled(isImporting || result != nil)

            HStack {
                Button(i18n.localized("选择 OPML 文件…", "Choose OPML File…")) { showsFilePicker = true }
                    .disabled(isImporting)
                    .accessibilityIdentifier("opml.import.choose-file")
                Text(fileName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Text(i18n.localized("订阅将添加到所选账号。重复订阅不会重复创建。", "Subscriptions will be added to the selected account. Existing feeds will not be duplicated."))
                .font(.callout).foregroundStyle(.secondary)
            if let account = store.subscriptionAccounts.first(where: { $0.id == accountID }),
               AccountType(rawValue: account.type)?.syncsRemoteArticleStates == true {
                Text(i18n.localized("服务器账号按文件中首次出现的分类添加订阅；空文件夹不会导入。", "Server accounts use each feed’s first folder in the file; empty folders are not imported."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isImporting {
                ProgressView(i18n.localized("正在导入…", "Importing…"))
            }
            if let result {
                Text(result.summary).accessibilityIdentifier("opml.import.result")
                if !result.failedTitles.isEmpty {
                    ScrollView {
                        Text(result.failedTitles.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                    Text(i18n.localized("请检查账号连接后重试；已经添加的订阅会自动跳过。", "Check the account connection and retry; feeds already added will be skipped."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(i18n.localized(result == nil ? "取消" : "完成", result == nil ? "Cancel" : "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isImporting)
                Button(i18n.localized(result == nil ? "导入" : "重试失败项", result == nil ? "Import" : "Retry Failed Feeds")) { submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(data == nil || isImporting || !store.subscriptionAccounts.contains { $0.id == accountID }
                        || store.importingAccountIDs.contains(accountID) || result?.failedTitles.isEmpty == true)
                    .accessibilityIdentifier("opml.import.submit")
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(isImporting)
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: OPMLExportDocument.readableContentTypes) { selection in
            do {
                let url = try selection.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let contents = try Data(contentsOf: url)
                _ = try OPMLService.parse(data: contents)
                data = contents; fileName = url.lastPathComponent; error = nil; result = nil
            } catch {
                self.error = i18n.localized("无法读取 OPML 文件，请检查文件格式。", "Unable to read the OPML file. Check its format.")
                data = nil; fileName = ""; result = nil
            }
        }
    }

    private func submit() {
        guard let data, !isImporting else { return }
        let destination = accountID
        isImporting = true; error = nil
        Task {
            result = await store.importOPML(data, targetAccountID: destination)
            if result == nil { error = store.lastError }
            isImporting = false
        }
    }
}
