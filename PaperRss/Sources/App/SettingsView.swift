import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if SWIFT_PACKAGE
import PaperRssCore
#endif
#if os(macOS)
#if SWIFT_PACKAGE
import PaperRssUpdateSupport
#endif
#endif

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case accounts
    case aiService
    case about

    var id: Self { self }

    @MainActor
    var title: String {
        switch self {
        case .general: I18N.shared.localized("常规", "General")
        case .appearance: I18N.shared.localized("外观", "Appearance")
        case .accounts: I18N.shared.localized("账号", "Accounts")
        case .aiService: I18N.shared.localized("AI", "AI")
        case .about: I18N.shared.localized("关于", "About")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .accounts: "person.crop.circle"
        case .aiService: "sparkles"
        case .about: "info.circle"
        }
    }

}

private enum SettingsMetrics {
    static let sidebarWidth: CGFloat = 240
    static let contentMaxWidth: CGFloat = 980
    static let contentHorizontalPadding: CGFloat = 34
    static let contentTopPadding: CGFloat = 26
    static let groupSpacing: CGFloat = 22
    static let cardCornerRadius: CGFloat = 14
    static let rowMinimumHeight: CGFloat = 52
    static let rowHorizontalPadding: CGFloat = 18
    static let rowVerticalPadding: CGFloat = 11
}

private enum AISettingsPane: String, CaseIterable, Identifiable {
    case features
    case providers
    var id: Self { self }

    @MainActor var title: String {
        switch self {
        case .features: I18N.shared.localized("功能配置", "Feature Routing")
        case .providers: I18N.shared.localized("供应商与模型", "Providers & Models")
        }
    }
}

private func providerSymbolName(_ kind: AIProviderKind) -> String {
    switch kind {
    case .deepSeek: "AIProviderDeepSeek"
    case .gemini: "AIProviderGemini"
    case .openAICompatible: "AIProviderOpenAI"
    case .customOpenAICompatible: "server.rack"
    }
}

private struct AIProviderIcon: View {
    let kind: AIProviderKind
    var size: CGFloat = 24
    var providerID: String = ""
    @Environment(\.colorScheme) private var colorScheme

    private var customColor: Color {
        // 按稳定标识分配色相，重启或重命名不会改变供应商图标颜色。
        let hash = providerID.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return Color(
            hue: Double(hash % 3600) / 3600,
            saturation: colorScheme == .dark ? 0.48 : 0.64,
            brightness: colorScheme == .dark ? 0.84 : 0.66
        )
    }

    private var color: Color {
        switch kind {
        case .deepSeek: Color(red: 0.30, green: 0.42, blue: 0.99)
        case .gemini: .primary
        case .openAICompatible: .primary
        case .customOpenAICompatible: customColor
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.055))
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
            if kind == .customOpenAICompatible {
                Image(systemName: providerSymbolName(kind))
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(color)
            } else {
                Image(providerSymbolName(kind))
                    .resizable()
                    .renderingMode(kind == .gemini ? .original : .template)
                    .scaledToFit()
                    .foregroundStyle(color)
                    .padding(size * 0.24)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SettingsInfoButton: View {
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(I18N.shared.localized("显示说明", "Show information"))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(LocalizedStringKey(message))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 270, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    #if os(macOS)
    @ObservedObject var attention: MacSystemAttentionController
    @ObservedObject var updateCoordinator: UpdateCoordinator
    #endif
    @State private var selectedSection: SettingsSection = SettingsSection.allCases.first ?? .general
    @ObservedObject var editor = AISettingsEditingSession()
    var isActive = true
    var onReturn: (() -> Void)?
    @FocusState private var isProviderNameFocused: Bool
    @State private var showsCompactProviderDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    private var configuration: LLMConfiguration {
        get { selectedAIProvider?.runtimeConfiguration(features: store.aiSettings.features) ?? .default }
        nonmutating set {
            editor.edit(selectedProviderID) { draft in
                draft.provider = draft.provider.replacing(
                    name: draft.provider.isBuiltIn ? draft.provider.name : newValue.providerName,
                    description: draft.provider.isBuiltIn ? draft.provider.description : newValue.providerDescription,
                    baseURL: draft.provider.isBuiltIn ? draft.provider.baseURL : newValue.baseURL,
                    selectedModelID: newValue.model,
                    reasoningMode: newValue.reasoningMode,
                    temperature: newValue.temperature,
                    allowInsecureLocalEndpoint: !draft.provider.isBuiltIn && newValue.allowInsecureLocalEndpoint
                )
            }
        }
    }
    private var configurationBinding: Binding<LLMConfiguration> {
        Binding(get: { configuration }, set: { configuration = $0 })
    }
    private var apiKey: String {
        get { editor.drafts[selectedProviderID]?.apiKey ?? "" }
        nonmutating set { editor.edit(selectedProviderID) { $0.apiKey = newValue } }
    }
    private var apiKeyBinding: Binding<String> {
        Binding(get: { apiKey }, set: { apiKey = $0 })
    }
    private var draftProviderEnabled: Bool {
        get { selectedAIProvider?.isEnabled ?? true }
        nonmutating set { editor.edit(selectedProviderID) { $0.provider.isEnabled = newValue } }
    }
    private var draftModels: [AIModelOption] {
        get { selectedAIProvider?.models ?? [] }
        nonmutating set { editor.edit(selectedProviderID) { $0.provider.models = newValue } }
    }
    private var draftRevision: Int { editor.drafts[selectedProviderID]?.revision ?? 0 }
    @State private var adaptationSuggestion: (providerID: String, modelID: String, revision: Int, adaptation: AIModelAdaptation)?
    @State private var showsAPIKey = false
    @State private var selectedProviderID = AIProviderID.deepSeek
    @State private var selectedAISettingsPane: AISettingsPane = .features
    @State private var providerSearchText = ""
    @State private var manualModelID = ""
    @State private var isShowingAddModelsSheet = false
    @State private var fetchedModelCandidates: [AIModelOption] = []
    @State private var selectedCandidateModelIDs = Set<String>()
    @State private var modelCandidateSearchText = ""
    @State private var providerPendingDeletion: AIProviderProfile?
    @State private var providerModelPendingDeletion: AIModelOption?
    @State private var isShowingDeleteProviderAlert = false
    @State private var showsAIModelList = false
    @State private var isFetchingModels = false
    @State private var modelFetchRequestID: UUID?
    @State private var status = ""
    @State private var isTesting = false
    @State private var testRequestID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    // 账号管理与添加弹窗状态
    @State private var isShowingAddAccountSheet = false
    @State private var accountPendingDeletion: AccountRecord? = nil
    @State private var isShowingDeleteAccountAlert = false
    @State private var deleteAccountError: String? = nil
    @State private var freshRSSUsername = ""
    @State private var freshRSSPassword = ""
    @State private var freshRSSDisplayName = ""
    @State private var isAddingFreshRSS = false
    @State private var addFreshRSSError: String?
    @State private var addFreshRSSSuccess: String?
    @State private var cacheClearMessage: String?
    @State private var cacheClearDismissTask: Task<Void, Never>?
    @State private var isClearingCache = false
    @State private var cacheStats: ArticleCacheStats?
    @State private var hoveredSection: SettingsSection?
    @State private var isFontPickerPresented = false
    @State private var fontSearchText = ""
    @FocusState private var isFontSearchFocused: Bool

    var body: some View {
        Group {
            #if os(macOS)
            macOSBody
            #else
            iOSBody
            #endif
        }
        .preferredColorScheme(store.appTheme.colorScheme)
        .tint(settingsAccentColor)
        .accentColor(settingsAccentColor)
        .toggleStyle(.switch)
        .environment(\.paperAppearancePalette, settingsAppearancePalette)
        #if os(macOS)
        .environment(\.colorScheme, settingsAppearancePalette.colorScheme == .dark ? .dark : .light)
        #endif
        .onChange(of: draftRevision) { _, _ in
            adaptationSuggestion = nil
            modelFetchRequestID = nil
            testRequestID = nil
            isFetchingModels = false
            isTesting = false
            status = ""
        }
        .onChange(of: isActive) { _, active in
            if !active { cancelProviderOperations() }
        }
        .onChange(of: selectedSection) { _, _ in cancelProviderOperations() }
        .onChange(of: selectedAISettingsPane) { _, _ in cancelProviderOperations() }
        .alert(
            I18N.shared.localized("删除 AI 供应商？", "Delete AI provider?"),
            isPresented: $isShowingDeleteProviderAlert,
            presenting: providerPendingDeletion
        ) { provider in
            Button(I18N.shared.localized("删除", "Delete"), role: .destructive) {
                if store.deleteAIProvider(id: provider.id) {
                    editor.discard(provider.id)
                    loadProvider(store.aiSettings.providers.first?.id ?? AIProviderID.deepSeek)
                    status = I18N.shared.localized("已删除供应商", "Provider deleted")
                }
                providerPendingDeletion = nil
            }
            Button(I18N.shared.localized("取消", "Cancel"), role: .cancel) {
                providerPendingDeletion = nil
            }
        } message: { provider in
            Text(providerDeletionMessage(provider))
        }
        .confirmationDialog(
            I18N.shared.localized("从供应商中删除模型？", "Remove model from provider?"),
            isPresented: Binding(
                get: { providerModelPendingDeletion != nil },
                set: { if !$0 { providerModelPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: providerModelPendingDeletion
        ) { model in
            Button(I18N.shared.localized("删除模型", "Remove Model"), role: .destructive) {
                draftModels.removeAll { $0.id == model.id }
                if configuration.model == model.id { configuration.model = draftModels.first?.id ?? "" }
                providerModelPendingDeletion = nil
            }
            Button(I18N.shared.localized("取消", "Cancel"), role: .cancel) {}
        } message: { model in
            Text(modelDeletionMessage(model))
        }
        .sheet(isPresented: $isShowingAddModelsSheet) {
            addModelsSheet
        }
    }

    #if os(macOS)
    private var macOSBody: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: SettingsMetrics.sidebarWidth)

            VStack(spacing: 0) {
                if selectedSection == .aiService && selectedAISettingsPane == .providers {
                    VStack(alignment: .leading, spacing: 16) {
                        aiSettingsHeader
                        providerPickerAndEditor
                    }
                    .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
                    .padding(.top, SettingsMetrics.contentTopPadding)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                SettingsScrollView {
                    settingsPage
                        .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
                        .padding(.top, SettingsMetrics.contentTopPadding)
                        .padding(.bottom, 34)
                }
                .scrollContentBackground(.hidden)
                }

                if showsActionBar {
                    actionBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(settingsWindowBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.system(size: 15))
        .controlSize(.regular)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .onAppear(perform: loadConfiguration)
    }
    #else
    private var iOSBody: some View {
        GeometryReader { geometry in
            if geometry.size.width > 520 {
                HStack(spacing: 0) {
                    sidebarView
                        .frame(width: 200)

                    VStack(spacing: 0) {
                        ScrollView {
                            settingsPage
                                .padding(.horizontal, 24)
                                .padding(.vertical, 20)
                        }
                        .paperListScrollStyle()

                        actionBar
                    }
                }
            } else {
                VStack(spacing: 0) {
                    Picker(I18N.localized("设置类别"), selection: $selectedSection) {
                        ForEach(SettingsSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    ScrollView {
                        settingsPage
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                    }
                    .paperListScrollStyle()

                    actionBar
                }
            }
        }
        .background(settingsWindowBackground)
        .onAppear(perform: loadConfiguration)
    }
    #endif

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onReturn {
                Button(action: onReturn) {
                    Label(I18N.shared.localized("返回 PaperRss", "Back to PaperRss"), systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.return")
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(SettingsSection.allCases) { section in
                        sidebarItem(for: section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            Spacer(minLength: 12)

            sidebarFooter
        }
        .background(settingsSidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.055))
                .frame(width: 1)
                .accessibilityHidden(true)
        }
    }

    private func sidebarItem(for section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                selectedSection = section
                status = ""
            }
        } label: {
            HStack(spacing: 10) {
                Capsule()
                    .fill(isSelected ? settingsAccentColor : Color.clear)
                    .frame(width: 3, height: 18)

                Image(systemName: section.icon)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                Text(section.title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? settingsAccentColor.opacity(0.13)
                            : hoveredSection == section ? Color.primary.opacity(0.055) : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredSection = isHovered ? section : nil
        }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(I18N.localized("PaperRss"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            switch selectedSection {
            case .accounts:
                Text(I18N.shared.localized("账号", "Accounts")).font(.system(size: 26, weight: .bold))
                accountsSettings
            case .appearance:
                Text(I18N.shared.localized("外观", "Appearance")).font(.system(size: 26, weight: .bold))
                appearanceSettings
            case .aiService:
                aiServiceSettings
            case .general:
                generalSettings
            case .about:
                aboutSettings
            }
        }
    }

    private var accountsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                I18N.shared.localized("当前账号", "Current Accounts"),
                info: I18N.shared.localized(
                    "本地订阅与 FreshRSS 远端订阅相互隔离；禁用账号不会删除本地数据或凭据。",
                    "Local and FreshRSS subscriptions stay separate. Disabling an account does not delete its data or credentials."
                )
            ) {
                // 本地账号
                HStack(spacing: 12) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 20))
                        .foregroundStyle(settingsAccentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(I18N.shared.localized("我的 Mac (本地账号)"))
                            .font(.system(size: 14, weight: .semibold))
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.isAccountEnabled("local-default") },
                            set: { newValue in
                                Task {
                                    try? await store.setAccountEnabled(accountID: "local-default", isEnabled: newValue)
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // FreshRSS 账号列表
                let freshRSSAccounts = store.accounts.filter { $0.type == AccountType.freshRSS.rawValue }
                ForEach(freshRSSAccounts, id: \.id) { account in
                    Divider().padding(.horizontal, 18).opacity(0.18)

                    VStack(alignment: .leading, spacing: 10) {
                        // 主行：图标 + 标题与端点 + Toggle
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 20))
                                .foregroundStyle(settingsAccentColor)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                if let user = account.username, let url = account.endpointURL {
                                    Text("\(user) @ \(url)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { account.isEnabled },
                                    set: { newValue in
                                        Task {
                                            try? await store.setAccountEnabled(accountID: account.id, isEnabled: newValue)
                                        }
                                    }
                                )
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }

                        // 次行：左侧同步状态，右侧操作（立即同步 + 删除）
                        HStack(spacing: 8) {
                            if let syncState = store.accountSyncStates[account.id] {
                                HStack(spacing: 6) {
                                    if let lastSync = syncState.lastSyncCompletedAt {
                                        let date = Date(timeIntervalSince1970: lastSync)
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.green)
                                        Text(I18N.shared.localizedFormat("上次同步：%@", DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let error = syncState.lastError, !error.isEmpty {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.orange)
                                        Text(error)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                    }
                                }
                            }

                            Spacer()

                            Button(I18N.shared.localized("立即同步")) {
                                Task {
                                    await store.syncAccount(accountID: account.id)
                                }
                            }
                            .controlSize(.small)
                            .disabled(!account.isEnabled)

                            Button(role: .destructive) {
                                accountPendingDeletion = account
                                isShowingDeleteAccountAlert = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                        .padding(.leading, 40)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            if let deleteError = deleteAccountError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(deleteError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            HStack {
                Button {
                    isShowingAddAccountSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text(I18N.shared.localized("添加账号…", "Add Account…"))
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $isShowingAddAccountSheet) {
            AddAccountSheet(store: store, isPresented: $isShowingAddAccountSheet)
        }
        .alert(
            I18N.shared.localized("确认移除账号？"),
            isPresented: $isShowingDeleteAccountAlert,
            presenting: accountPendingDeletion
        ) { account in
            Button(I18N.shared.localized("移除账号"), role: .destructive) {
                Task {
                    do {
                        deleteAccountError = nil
                        try await store.removeAccount(accountID: account.id)
                    } catch {
                        deleteAccountError = error.localizedDescription
                    }
                }
            }
            Button(I18N.shared.localized("取消"), role: .cancel) {}
        } message: { account in
            Text(I18N.shared.localizedFormat(
                "移除此账号将清除其在 PaperRss 本地同步的数据与凭据，但不会从 FreshRSS 服务器删除或退订您的 Feed。",
                account.displayName
            ))
        }
    }

    private var feedbackSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                I18N.shared.localized("赞赏与反馈", "Support & Feedback")
            ) {
                if store.appLanguage.resolvedLocalization() == .en {
                    HStack(spacing: 20) {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(settingsAccentColor)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(I18N.shared.localized("通过 PayPal 支持 PaperRss"))
                                .font(.system(size: 16, weight: .bold))
                            Text(I18N.shared.localized("感谢你支持独立软件与专注阅读。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Button(I18N.shared.localized("前往 PayPal")) {
                            if let url = URL(string: "https://paypal.me/ohmyangboy") {
                                AppInfo.openURL(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                } else {
                    VStack(spacing: 16) {
                    HStack(alignment: .center, spacing: 20) {
                        Image("SponsorQR", bundle: nil)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // 原图自带黑色方框，略微放大后裁去外沿，避免圆角处残留断开的黑边。
                            .frame(width: 114, height: 114)
                            .frame(width: 112, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(Color.red)
                                Text(I18N.shared.localized("微信赞赏码"))
                                    .font(.system(size: 16, weight: .bold))
                            }

                            Text(I18N.shared.localized("感谢每一位热爱独立软件与专注阅读的读者。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(I18N.shared.localized("您的支持是 PaperRss 持续进化与维护的动力。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    }
                }
                Divider().padding(.horizontal, 18).opacity(0.18)

                settingsRow(
                    I18N.shared.localized("提交 GitHub Issue", "Submit GitHub Issue")
                ) {
                    Button {
                        if let url = URL(string: "https://github.com/ohmyangboy/PaperRss/issues") {
                            AppInfo.openURL(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text(I18N.shared.localized("新建 Issue", "New Issue"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider().padding(.horizontal, 18).opacity(0.18)

                settingsRow(
                    I18N.shared.localized("开发者社区", "Developer Community")
                ) {
                    Button {
                        if let url = URL(string: "https://github.com/ohmyangboy") {
                            AppInfo.openURL(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(I18N.localized("GitHub Profile"))
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                GeometryReader { geometry in
                    let availableWidth = geometry.size.width - 16
                    HStack(alignment: .top, spacing: 16) {
                        appearancePreview.frame(width: availableWidth * 0.75)
                        typographyPanel.frame(width: availableWidth * 0.25)
                    }
                }
                .frame(minWidth: 736)
                .frame(height: 300)
                VStack(alignment: .leading, spacing: 16) {
                    appearancePreview
                    typographyPanel
                }
            }

            settingsGroup(
                I18N.shared.localized("主题", "Theme")
            ) {
                VStack(spacing: 0) {
                    settingsSubsectionTitle(I18N.shared.localized("外观模式", "Theme Mode"))
                    settingsRow(I18N.shared.localized("外观模式", "Theme Mode")) {
                        appThemePicker
                    }

                    Divider().padding(.horizontal, 18).opacity(0.18)

                    settingsSubsectionTitle(I18N.shared.localized("内容主题", "Content Theme"))
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                        spacing: 10
                    ) {
                        ForEach(ReaderThemePreset.allCases) { preset in
                            readerThemeTile(preset)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                    Divider().padding(.horizontal, 18).opacity(0.18)

                    settingsSubsectionTitle(I18N.shared.localized("颜色", "Colors"))
                    settingsRow(I18N.shared.localized("浅色背景", "Light Background")) {
                        ColorPicker(
                            I18N.shared.localized("浅色背景", "Light Background"),
                            selection: readerBackgroundBinding(for: .light),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }

                    Divider().padding(.horizontal, 18).opacity(0.18)

                    settingsRow(I18N.shared.localized("深色背景", "Dark Background")) {
                        ColorPicker(
                            I18N.shared.localized("深色背景", "Dark Background"),
                            selection: readerBackgroundBinding(for: .dark),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }

                    Divider().padding(.horizontal, 18).opacity(0.18)

                    settingsRow(
                        store.readerAppearance.isCustom
                            ? I18N.shared.localized("Custom · 自定义", "Custom")
                            : I18N.shared.localized("当前使用内置预设", "Using built-in preset")
                    ) {
                        Button(I18N.shared.localized("重置为预设", "Reset to Preset")) {
                            store.resetReaderAppearanceToPreset()
                        }
                        .disabled(!store.readerAppearance.isCustom)
                    }
                }
            }

            HStack {
                Spacer()
                Button(I18N.shared.localized("重置", "Reset")) {
                    store.resetReaderAppearanceToDefault()
                }
                .disabled(store.readerAppearance == .default)
                .help(I18N.shared.localized("恢复 Paper、系统字体、17pt 与默认行间距", "Restore Paper, system font, 17pt, and default line spacing"))
                Spacer()
            }

        }
    }

    private var appearancePreview: some View {
        AppearanceThreeColumnPreview(
            appearance: store.readerAppearance,
            mode: readerAppearanceMode,
            bodyFont: readerPreviewFont
        )
    }

    private var typographyPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18N.shared.localized("排版", "Typography"))
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text(I18N.shared.localized("正文字体", "Body Font"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                readerFontPicker
            }
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(I18N.shared.localized("正文字号", "Body Size"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.articleFontSize) pt")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                Slider(
                    value: Binding(
                        get: { Double(store.articleFontSize) },
                        set: { store.setArticleFontSize(Int($0)) }
                    ),
                    in: 13...25,
                    step: 1
                )
                .accessibilityLabel(I18N.shared.localized("正文字号", "Body Size"))
            }
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(I18N.shared.localized("行间距", "Line Spacing"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text(store.readerAppearance.lineHeight, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { store.readerAppearance.lineHeight },
                        set: { store.setReaderLineHeight($0) }
                    ),
                    in: 1.2...2.4,
                    step: 0.05
                )
                .accessibilityLabel(I18N.shared.localized("行间距", "Line Spacing"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius)
                .stroke(Color.primary.opacity(accessibilityContrast == .increased ? 0.45 : 0.075), lineWidth: 0.8)
        }
    }

    private var appThemePicker: some View {
        HStack(spacing: 3) {
            ForEach(AppTheme.allCases) { theme in
                let isSelected = store.appTheme == theme
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.setAppTheme(theme)
                    }
                } label: {
                    Text(theme.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Capsule())
                        .background(isSelected ? settingsAccentColor : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: 270)
        .background(Color.primary.opacity(0.075), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
        .contentShape(Capsule())
        .animation(.easeInOut(duration: 0.2), value: store.appTheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(I18N.shared.localized("外观模式", "Theme Mode"))
    }

    private var readerFontPicker: some View {
        Button {
            fontSearchText = ""
            isFontPickerPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(selectedReaderFontName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isFontPickerPresented, arrowEdge: .trailing) {
            readerFontPickerPopover
        }
        .accessibilityLabel(I18N.shared.localized("正文字体", "Body Font"))
        .accessibilityValue(selectedReaderFontName)
    }

    private var readerFontPickerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                I18N.shared.localized("搜索字体", "Search fonts"),
                text: $fontSearchText
            )
            .textFieldStyle(SettingsInputStyle())
            .focused($isFontSearchFocused)

            if filteredReaderFontFamilies.isEmpty {
                Text(I18N.shared.localized("没有匹配的字体", "No matching fonts"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        readerFontOption(
                            I18N.shared.localized("系统默认", "System Default"),
                            family: nil
                        )

                        Divider()

                        ForEach(filteredReaderFontFamilies, id: \.self) { family in
                            readerFontOption(family, family: family)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(width: 280, height: 300)
            }
        }
        .padding(12)
        .frame(width: 304)
        .onAppear { isFontSearchFocused = true }
        .onDisappear { isFontSearchFocused = false }
    }

    private var selectedReaderFontName: String {
        store.readerAppearance.fontFamilyName
            ?? I18N.shared.localized("系统默认", "System Default")
    }

    private var filteredReaderFontFamilies: [String] {
        let query = fontSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableReaderFontFamilies }
        return availableReaderFontFamilies.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private func readerFontOption(_ title: String, family: String?) -> some View {
        let isSelected = store.readerAppearance.fontFamilyName == family

        return Button {
            store.setReaderFontFamily(family)
            isFontPickerPresented = false
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(family.map { Font.custom($0, size: 13) } ?? .body)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(settingsAccentColor)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var availableReaderFontFamilies: [String] {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #else
        UIFont.familyNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #endif
    }

    private var readerAppearanceMode: ReaderAppearanceMode {
        switch store.appTheme {
        case .system: ReaderAppearanceMode(colorScheme)
        case .light: .light
        case .dark: .dark
        }
    }

    private var settingsAppearancePalette: ReaderAppearancePalette {
        store.readerAppearance.palette(for: readerAppearanceMode)
    }

    private var settingsAccentColor: Color {
        Color(paperHex: settingsAppearancePalette.accentHex)
    }

    private var readerPreviewFont: Font {
        if let family = store.readerAppearance.fontFamilyName {
            return .custom(family, size: CGFloat(store.articleFontSize))
        }
        return .system(size: CGFloat(store.articleFontSize))
    }

    private func readerBackgroundBinding(for mode: ReaderAppearanceMode) -> Binding<Color> {
        Binding(
            get: { Color(paperHex: store.readerAppearance.backgroundHex(for: mode)) },
            set: { store.setReaderBackgroundHex($0.readerHexString, for: mode) }
        )
    }

    private func readerThemeTitle(_ preset: ReaderThemePreset) -> String {
        switch preset {
        case .paper: I18N.shared.localized("Paper", "Paper")
        case .white: I18N.shared.localized("White", "White")
        case .geek: I18N.shared.localized("Geek", "Geek")
        }
    }

    private func readerThemeDescription(_ preset: ReaderThemePreset) -> String {
        switch preset {
        case .paper:
            I18N.shared.localized("温暖纸感，随外观模式自然变化。", "Warm paper texture that adapts to the appearance mode.")
        case .white:
            I18N.shared.localized("高对比、纯净而克制的现代阅读体验。", "A clean, high-contrast reading experience.")
        case .geek:
            I18N.shared.localized("深色蓝紫配色，适合夜间与技术内容。", "A deep blue-violet palette for night reading and technical content.")
        }
    }

    private func readerThemeTile(_ preset: ReaderThemePreset) -> some View {
        let isSelected = store.readerAppearance.preset == preset
        return Button {
            store.setReaderThemePreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Spacer(minLength: 0)
                    ReaderThemeSwatch(preset: preset)
                    Spacer(minLength: 0)
                }

                Text(readerThemeTitle(preset))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(readerThemeDescription(preset))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(
                isSelected ? settingsAccentColor.opacity(0.07) : Color.primary.opacity(0.022),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? settingsAccentColor.opacity(0.52) : Color.primary.opacity(0.075),
                        lineWidth: isSelected ? 1.3 : 0.8
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(settingsAccentColor)
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                I18N.shared.localized("界面语言", "Display Language")
            ) {
                settingsRow(I18N.shared.localized("语言选择", "Select Language")) {
                    Picker(I18N.shared.localized("语言选择", "Select Language"), selection: $store.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180, alignment: .trailing)
                }
            }
        }
    }

    private var aiSettingsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI")
                .font(.system(size: 26, weight: .bold))
            HStack {
                Picker(I18N.shared.localized("AI 设置页面", "AI settings page"), selection: $selectedAISettingsPane) {
                    ForEach(AISettingsPane.allCases) { pane in Text(pane.title).tag(pane) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }


        }
    }

    private var aiServiceSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            aiSettingsHeader
            if selectedAISettingsPane == .features {
                aiFeatureSection(I18N.shared.localized("文章能力", "Article Features")) {
                    LazyVGrid(columns: aiFeatureColumns, alignment: .leading, spacing: 16) {
                        featureConfigurationRow(.summary)
                        featureConfigurationRow(.bilingualTranslation)
                    }
                }

                aiFeatureSection(I18N.shared.localized("划词能力", "Selection Features")) {
                    LazyVGrid(columns: aiFeatureColumns, alignment: .leading, spacing: 16) {
                        featureConfigurationRow(.selectionTranslation)
                        featureConfigurationRow(.selectionExplanation)
                        featureConfigurationRow(.selectionAsk)
                    }
                }

                settingsGroup(I18N.shared.localized("摘要偏好", "Summary Preferences")) {
                    settingsRow(I18N.shared.localized("打开文章时自动生成", "Generate when opening an article")) {
                        Toggle("", isOn: featurePreferenceBinding(\.automaticallyGenerateSummary))
                            .labelsHidden()
                    }
                }

                translationPreferencesSection

                settingsGroup(I18N.shared.localized("表达偏好", "Writing Preferences")) {
                    TextEditor(text: featurePreferenceBinding(\.customPrompt))
                        .font(.system(size: 15))
                        .frame(height: 100)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .overlay(alignment: .topLeading) {
                            if store.aiSettings.features.customPrompt.isEmpty {
                                Text(I18N.shared.localized(
                                    "填写你偏好的语气、篇幅或输出格式。\n例如：语气自然简洁，总结控制在 200 字以内，按要点分段。",
                                    "Describe your preferred tone, length, or format.\nFor example: use a natural, concise tone; keep summaries under 200 words and organize them into key points."
                                ))
                                .font(.system(size: 14))
                                .foregroundStyle(Color(paperHex: settingsAppearancePalette.mutedHex))
                                .padding(.horizontal, 5)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                        .padding(10)
                        .modifier(SettingsInputSurface())
                        .accessibilityLabel(I18N.shared.localized("表达偏好", "Writing Preferences"))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(I18N.shared.localized("供应商与模型", "Providers & Models"))
                        .font(.system(size: 27, weight: .bold))
                    Text(I18N.shared.localized(
                        "管理模型连接。只有已启用供应商的模型会出现在功能配置中。",
                        "Manage model connections. Only enabled providers appear in feature routing."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 2)

                Divider().opacity(0.35)

                providerPickerAndEditor
            }
        }
    }

    private var providerPickerAndEditor: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 740
            HStack(alignment: .top, spacing: 16) {
                if !compact || !showsCompactProviderDetail {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(I18N.shared.localized("AI 供应商", "AI Providers"))
                                .font(.system(size: 17, weight: .semibold))
                            Spacer()
                            addProviderButton
                        }
                        SettingsScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredAIProviders) { provider in providerSidebarRow(provider) }
                            }
                        }
                    }
                    .frame(width: compact ? nil : min(292, max(240, geometry.size.width * 0.30)))
                    .frame(maxWidth: compact ? .infinity : nil)
                }
                if !compact || showsCompactProviderDetail {
                    VStack(alignment: .leading, spacing: 8) {
                        if compact {
                            Button {
                                showsCompactProviderDetail = false
                                cancelProviderOperations()
                            } label: {
                                Label(I18N.shared.localized("返回供应商列表", "Back to providers"), systemImage: "chevron.left")
                            }
                            .buttonStyle(.borderless)
                        }
                        providerDetailPanel
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var aiFeatureColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 330, maximum: 480), spacing: 16, alignment: .top)]
    }

    private func aiFeatureSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(settingsAccentColor)
                    .frame(width: 4, height: 23)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
            }
            content()
        }
    }

    private func featureConfigurationRow(_ kind: AIFeatureKind) -> some View {
        aiFeatureCard(kind)
    }

    private func aiFeatureCard(_ kind: AIFeatureKind) -> some View {
        let configuration = store.aiSettings.configuration(for: kind)
            ?? AIFeatureConfiguration(isEnabled: false, model: nil)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(settingsAccentColor.opacity(0.11))
                    Image(systemName: featureIconName(kind))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(settingsAccentColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(featureTitle(kind))
                        .font(.system(size: 15, weight: .semibold))
                    Text(featureDescription(kind))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { store.aiSettings.configuration(for: kind)?.isEnabled ?? false },
                    set: { enabled in
                        var next = store.aiSettings.configuration(for: kind)
                            ?? AIFeatureConfiguration(isEnabled: enabled, model: nil)
                        next.isEnabled = enabled
                        store.saveAISettings(store.aiSettings.updatingFeature(kind, configuration: next))
                    }
                ))
                .labelsHidden()
            }

            Divider().opacity(0.28)

            HStack(spacing: 10) {
                featureModelMenu(kind, configuration: configuration)
                    .frame(maxWidth: .infinity)
                featureReasoningMenu(kind, configuration: configuration)
                    .frame(width: 112)
            }
            if let reference = configuration.model,
               let model = store.aiSettings.provider(id: reference.providerID)?.models.first(where: { $0.id == reference.modelID }),
               !model.supports(kind) {
                Text(LLMServiceError.translationOnly.localizedDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
        .opacity(configuration.isEnabled ? 1 : 0.62)
        .accessibilityElement(children: .contain)
    }

    private func featureModelMenu(
        _ kind: AIFeatureKind,
        configuration: AIFeatureConfiguration
    ) -> some View {
        Menu {
            ForEach(store.aiSettings.providers.filter(\.isEnabled)) { provider in
                Menu {
                    ForEach(provider.models) { model in
                        Button {
                            store.saveAISettings(store.aiSettings.updatingFeature(
                                kind,
                                configuration: AIFeatureConfiguration(
                                    isEnabled: configuration.isEnabled,
                                    model: AIModelReference(providerID: provider.id, modelID: model.id),
                                    reasoningMode: configuration.reasoningMode
                                )
                            ))
                        } label: {
                            if configuration.model == AIModelReference(providerID: provider.id, modelID: model.id) {
                                Label(model.displayName + (model.adaptationBadge.map { " · " + $0 } ?? ""), systemImage: "checkmark")
                            } else {
                                Text(model.displayName + (model.adaptationBadge.map { " · " + $0 } ?? ""))
                            }
                        }
                        .disabled(!model.supports(kind))
                        .help(model.supports(kind) ? "" : LLMServiceError.translationOnly.localizedDescription)
                    }
                } label: {
                    HStack(spacing: 6) {
                        AIProviderIcon(kind: provider.kind, size: 16, providerID: provider.id)
                        Text(provider.name.isEmpty ? I18N.shared.localized("新供应商", "New provider") : localizedBuiltInProviderName(provider.name))
                    }
                }
            }
            Divider()
            Button(I18N.shared.localized("管理模型…", "Manage Models…")) {
                selectedAISettingsPane = .providers
            }
        } label: {
            HStack(spacing: 7) {
                if let reference = configuration.model,
                   let provider = store.aiProvider(id: reference.providerID) {
                    AIProviderIcon(kind: provider.kind, size: 21, providerID: provider.id)
                }
                Text(featureModelLabel(configuration.model))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!configuration.isEnabled || availableModelReferences.isEmpty)
    }

    private func featureReasoningMenu(
        _ kind: AIFeatureKind,
        configuration: AIFeatureConfiguration
    ) -> some View {
        let runtime = store.aiSettings.resolvedConfiguration(for: kind)
        let capabilities = runtime?.reasoningCapabilities
        let isTranslation = runtime?.usesTranslationAdaptation == true
        let valid = capabilities?.accepts(configuration.reasoningMode) == true
        return Menu {
            Text(localizedReasoningMode(capabilities?.source ?? "能力未确认"))
            if capabilities?.wireProtocol == .openRouter, let reference = configuration.model {
                Button(I18N.shared.localized("刷新模型能力", "Refresh capabilities")) {
                    Task { @MainActor in
                        do { try await store.refreshReasoningCapabilities(providerID: reference.providerID, force: true) }
                        catch { store.emitTransientNotice(error.localizedDescription) }
                    }
                }
            }
            ForEach(
                capabilities?.modes ?? ["自动"],
                id: \.self
            ) { mode in
                Button {
                    var next = configuration
                    next.reasoningMode = mode
                    store.saveAISettings(store.aiSettings.updatingFeature(kind, configuration: next))
                } label: {
                    if AIReasoningCapabilities.canonical(configuration.reasoningMode) == mode {
                        Label(localizedReasoningMode(mode), systemImage: "checkmark")
                    } else {
                        Text(localizedReasoningMode(mode))
                    }
                }
            }
        } label: {
            Text(I18N.shared.localizedFormat("思考：%@", localizedReasoningMode(isTranslation ? "不适用" : valid ? configuration.reasoningMode : "需重选")))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!configuration.isEnabled || isTranslation)
        .task(id: configuration.model) {
            guard !isTranslation, let reference = configuration.model else { return }
            do { try await store.refreshReasoningCapabilities(providerID: reference.providerID) }
            catch { /* 保留现有配置，用户可从菜单手动重试。 */ }
        }
    }

    private func featureIconName(_ kind: AIFeatureKind) -> String {
        switch kind {
        case .summary: "doc.text"
        case .bilingualTranslation: "character.bubble"
        case .selectionTranslation: "text.magnifyingglass"
        case .selectionExplanation: "text.book.closed"
        case .selectionAsk: "questionmark.bubble"
        }
    }

    private var availableModelReferences: [AIModelReference] {
        store.aiSettings.availableModelReferences
    }

    private func featureModelLabel(_ reference: AIModelReference?) -> String {
        guard let reference,
              let provider = store.aiProvider(id: reference.providerID),
              let model = provider.models.first(where: { $0.id == reference.modelID }) else {
            return I18N.shared.localized("需要配置模型", "Model required")
        }
        guard provider.isEnabled else {
            return I18N.shared.localized("供应商已停用", "Provider disabled")
        }
        return "\(localizedBuiltInProviderName(provider.name)) / \(model.displayName)" + (model.adaptationBadge.map { " · " + $0 } ?? "")
    }

    private func localizedReasoningMode(_ mode: String) -> String {
        switch mode {
        case "关闭": I18N.shared.localized("关闭", "Off")
        case "low", "低": I18N.shared.localized("低", "Low")
        case "medium", "中": I18N.shared.localized("中", "Medium")
        case "high", "高": I18N.shared.localized("高", "High")
        case "自动": I18N.shared.localized("自动", "Auto")
        case "开启": I18N.shared.localized("开启", "On")
        case "不适用": I18N.shared.localized("不适用", "Not applicable")
        case "需重选": I18N.shared.localized("需重选", "Reselect")
        case "官方协议规则": I18N.shared.localized("来源：官方协议规则", "Source: official protocol rules")
        case "模型目录": I18N.shared.localized("来源：模型目录（24 小时有效）", "Source: model catalog (valid for 24 hours)")
        case "手动协议": I18N.shared.localized("来源：手动协议，请按接口文档确认", "Source: manual protocol; check endpoint documentation")
        case "能力未确认，请刷新模型目录或选择协议", "能力未确认": I18N.shared.localized("能力未确认，请刷新模型目录或选择协议", "Capabilities unknown; refresh models or select a protocol")
        default: mode
        }
    }

    private func featureTitle(_ kind: AIFeatureKind) -> String {
        switch kind {
        case .summary: I18N.shared.localized("文章摘要", "Article Summary")
        case .bilingualTranslation: I18N.shared.localized("双语翻译", "Bilingual Translation")
        case .selectionTranslation: I18N.shared.localized("划词翻译", "Selection Translation")
        case .selectionExplanation: I18N.shared.localized("划词解释", "Selection Explanation")
        case .selectionAsk: I18N.shared.localized("划词提问", "Selection Q&A")
        }
    }

    private func featureDescription(_ kind: AIFeatureKind) -> String {
        switch kind {
        case .summary: I18N.shared.localized("为当前文章生成可长期保留的摘要。", "Generate a durable summary for the article.")
        case .bilingualTranslation: I18N.shared.localized("按可见段落生成原文与译文对照。", "Translate visible paragraphs alongside the original.")
        case .selectionTranslation: I18N.shared.localized("翻译阅读器中选中的文字。", "Translate selected text in the reader.")
        case .selectionExplanation: I18N.shared.localized("结合上下文解释选中的内容。", "Explain selected text using its context.")
        case .selectionAsk: I18N.shared.localized("围绕选中内容继续提问。", "Ask follow-up questions about selected text.")
        }
    }

    private func affectedFeatureTitles(providerID: String, modelID: String? = nil) -> [String] {
        AIFeatureKind.allCases.compactMap { kind in
            guard let reference = store.aiSettings.configuration(for: kind)?.model,
                  reference.providerID == providerID,
                  modelID == nil || reference.modelID == modelID else { return nil }
            return featureTitle(kind)
        }
    }

    private func providerDeletionMessage(_ provider: AIProviderProfile) -> String {
        let affected = affectedFeatureTitles(providerID: provider.id)
        let suffix = affected.isEmpty
            ? ""
            : I18N.shared.isEnglish
                ? " Affected features: \(affected.joined(separator: ", "))."
                : " 受影响功能：\(affected.joined(separator: "、"))。"
        return (I18N.shared.isEnglish
            ? "The provider \(provider.name) and its locally stored API key will be removed."
            : "供应商 \(provider.name) 及其本地保存的 API Key 将被删除。") + suffix
    }

    private func modelDeletionMessage(_ model: AIModelOption) -> String {
        let affected = affectedFeatureTitles(providerID: selectedProviderID, modelID: model.id)
        guard !affected.isEmpty else {
            return I18N.shared.localized("该修改将在保存供应商后生效。", "This change takes effect after saving the provider.")
        }
        return I18N.shared.isEnglish
            ? "Affected features: \(affected.joined(separator: ", ")). They will be rebound when you save."
            : "受影响功能：\(affected.joined(separator: "、"))。保存后会自动改绑。"
    }

    private var translationPreferencesSection: some View {
        settingsGroup(I18N.shared.localized("翻译偏好", "Translation Preferences")) {
            settingsRow(I18N.shared.localized("目标语言", "Target Language")) {
                Picker(I18N.shared.localized("目标语言", "Target Language"), selection: featurePreferenceBinding(\.targetLanguage)) {
                    ForEach(translationTargetLanguages, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .frame(width: 200, alignment: .trailing)
                .accessibilityIdentifier("translation-target-language")
            }
            settingsRow(I18N.shared.localized("翻译模式", "Translation Mode")) {
                SettingsCompactSwitcher(
                    options: TranslationDisplayMode.allCases,
                    selection: translationPreferenceBinding(\.mode),
                    accent: settingsAccentColor,
                    title: { $0 == .comparison
                        ? I18N.shared.localized("上下文对照", "Side by side")
                        : I18N.shared.localized("替换翻译", "Replacement") }
                )
                .accessibilityLabel(I18N.shared.localized("翻译模式", "Translation Mode"))
                .accessibilityIdentifier("translation-mode")
            }
            settingsRow(I18N.shared.localized("对照译文颜色", "Comparison Translation Color")) {
                HStack(alignment: .top, spacing: 20) {
                    translationColorRow(for: .light)
                    translationColorRow(for: .dark)
                }
                .disabled(store.aiSettings.features.translationPreferences.mode == .replacement)
                .opacity(store.aiSettings.features.translationPreferences.mode == .replacement ? 0.45 : 1)
            }
            translationPreferencesPreview
            HStack {
                Spacer()
                Button(I18N.shared.localized("恢复翻译显示默认值", "Reset Translation Display")) {
                    translationPreferenceBinding(\.self).wrappedValue = .default
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 12))
                .accessibilityIdentifier("translation-reset")
                Spacer()
            }
            .padding(.vertical, 14)
        }
    }

    private var translationTargetLanguages: [String] {
        let languages = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Português", "Italiano", "Русский", "العربية", "हिन्दी", "ไทย", "Tiếng Việt", "Bahasa Indonesia"]
        let current = store.aiSettings.features.targetLanguage
        // 保留旧配置中不在常用列表内的语言，避免切换控件时改写用户偏好。
        return languages.contains(current) || current.isEmpty ? languages : [current] + languages
    }

    private func translationPreferenceBinding<Value>(_ keyPath: WritableKeyPath<TranslationPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.aiSettings.features.translationPreferences[keyPath: keyPath] },
            set: { value in
                var preferences = store.aiSettings.features.translationPreferences
                preferences[keyPath: keyPath] = value
                featurePreferenceBinding(\.translationPreferences).wrappedValue = preferences
            }
        )
    }

    private func translationColorRow(for mode: ReaderAppearanceMode) -> some View {
        let title = mode == .light
            ? I18N.shared.localized("浅色", "Light")
            : I18N.shared.localized("深色", "Dark")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                SettingsCompactSwitcher(
                    options: TranslationColorSource.allCases,
                    selection: Binding(
                        get: { store.aiSettings.features.translationPreferences.colorSource(for: mode) },
                        set: { source in
                            var next = store.aiSettings.features.translationPreferences
                            next.setColorSource(source, for: mode)
                            featurePreferenceBinding(\.translationPreferences).wrappedValue = next
                        }
                    ),
                    accent: settingsAccentColor,
                    title: { $0 == .automatic
                        ? I18N.shared.localized("跟随主题", "Theme")
                        : I18N.shared.localized("自定义", "Custom") },
                    accessory: { source in
                        AnyView(Group {
                            if source == .custom {
                                TranslationColorWell(color: Binding(
                                    get: {
                                        let current = store.aiSettings.features.translationPreferences
                                        return Color(paperHex: (mode == .light ? current.customLightHex : current.customDarkHex)
                                            ?? TranslationPreferences.defaultCustomHex)
                                    },
                                    set: { color in
                                        var next = store.aiSettings.features.translationPreferences
                                        guard next.mode == .comparison else { return }
                                        next.setColorSource(.custom, for: mode)
                                        next.setCustomHex(color.readerHexString, for: mode)
                                        featurePreferenceBinding(\.translationPreferences).wrappedValue = next
                                    }
                                ))
                                .frame(width: 18, height: 18)
                                .clipShape(Circle())
                                .overlay { Circle().strokeBorder(.white, lineWidth: 1).allowsHitTesting(false) }
                                .padding(.trailing, 8)
                                .accessibilityLabel(title + I18N.shared.localized("自定义颜色", " Custom Color"))
                                .accessibilityIdentifier("translation-custom-" + mode.rawValue)
                            }
                        })
                    }
                )
                .accessibilityLabel(title + I18N.shared.localized("对照译文颜色", " Comparison Translation Color"))
                .accessibilityIdentifier("translation-color-" + mode.rawValue)


            }

        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var translationPreferencesPreview: some View {
        HStack(alignment: .top, spacing: 12) {
            translationPreferencesPreview(for: .light)
            translationPreferencesPreview(for: .dark)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .accessibilityIdentifier("translation-preview")
    }

    private func translationPreferencesPreview(for mode: ReaderAppearanceMode) -> some View {
        let preferences = store.aiSettings.features.translationPreferences
        let palette = store.readerAppearance.palette(for: mode)
        let showsLowContrast = preferences.mode == .comparison
            && preferences.colorSource(for: mode) == .custom
            && TranslationPreferences.contrastRatio(preferences.colorHex(palette: palette, mode: mode), palette.backgroundHex) < 4.5
        let contrastHint = I18N.shared.localized("与阅读背景对比度较低", "Low contrast against the reading background")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(mode == .light ? I18N.shared.localized("浅色预览", "Light Preview") : I18N.shared.localized("深色预览", "Dark Preview"))
                    .fixedSize()
                Text(contrastHint)
                    .lineLimit(1)
                    .opacity(showsLowContrast ? 1 : 0)
                    .accessibilityHidden(!showsLowContrast)
                    .help(showsLowContrast ? contrastHint : "")
            }
            .font(.caption)
            .foregroundStyle(Color(paperHex: palette.mutedHex))
            // 两种内容共同撑高，切换模式时保持预览和设置面板的布局稳定。
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reading opens a window to the world.")
                        .foregroundStyle(Color(paperHex: palette.inkHex))
                    Text("A文  阅读为我们打开一扇通向世界的窗。")
                        .foregroundStyle(Color(paperHex: preferences.colorHex(palette: palette, mode: mode)))
                }
                .opacity(preferences.mode == .comparison ? 1 : 0)
                .allowsHitTesting(preferences.mode == .comparison)
                .accessibilityHidden(preferences.mode != .comparison)

                VStack(alignment: .leading, spacing: 8) {
                    TranslationReplacementPreview()
                        .foregroundStyle(Color(paperHex: palette.inkHex))
                    Text(I18N.shared.localized("鼠标悬浮切换原文", "Hover to show the original text"))
                        .font(.caption)
                        .foregroundStyle(Color(paperHex: palette.mutedHex))
                }
                .opacity(preferences.mode == .replacement ? 1 : 0)
                .allowsHitTesting(preferences.mode == .replacement)
                .accessibilityHidden(preferences.mode != .replacement)
            }
        }
        .font(readerPreviewFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(paperHex: palette.backgroundHex), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("translation-preview-" + mode.rawValue)
    }

    private func featurePreferenceBinding<Value>(_ keyPath: WritableKeyPath<AIFeaturePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.aiSettings.features[keyPath: keyPath] },
            set: { value in
                var features = store.aiSettings.features
                features[keyPath: keyPath] = value
                store.saveAISettings(store.aiSettings.updatingFeatures(features))
            }
        )
    }

    private var filteredAIProviders: [AIProviderProfile] {
        var providers = store.aiSettings.providers.map { editor.drafts[$0.id]?.provider ?? $0 }
        if let id = editor.newProviderID, let draft = editor.drafts[id] { providers.append(draft.provider) }
        return providers
    }

    private var selectedAIProvider: AIProviderProfile? {
        editor.drafts[selectedProviderID]?.provider ?? store.aiProvider(id: selectedProviderID)
    }

    private var draftAIProvider: AIProviderProfile? { selectedAIProvider }

    private func providerSidebarRow(_ provider: AIProviderProfile) -> some View {
        let isSelected = provider.id == selectedProviderID
        let isEnabled = isSelected ? draftProviderEnabled : provider.isEnabled

        return ZStack(alignment: .trailing) {
            Button { selectProvider(provider.id) } label: {
                HStack(spacing: 12) {
                    AIProviderIcon(kind: provider.kind, size: 42, providerID: provider.id)
                        .opacity(isEnabled ? 1 : 0.48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.name.isEmpty ? I18N.shared.localized("新供应商", "New provider") : localizedBuiltInProviderName(provider.name))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(editor.drafts[provider.id]?.isDirty == true
                            ? I18N.shared.localized("未保存", "Unsaved")
                            : I18N.shared.localizedFormat("%lld 个模型", provider.models.count))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 48)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 26)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { provider.id == selectedProviderID ? draftProviderEnabled : provider.isEnabled },
                set: { setProviderEnabled(provider, enabled: $0) }
            ))
            .labelsHidden()
            .accessibilityLabel(I18N.shared.localized("启用供应商", "Enable Provider"))
            .padding(.trailing, 46)
        }
        .background(
            isSelected ? settingsAccentColor.opacity(0.13) : settingsGroupBackground,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? settingsAccentColor.opacity(0.25) : Color.primary.opacity(0.09), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
    }

    private var addProviderButton: some View {
        Button {
            cancelProviderOperations()
            selectedProviderID = editor.beginNewProvider()
            showsCompactProviderDetail = true
            showsAPIKey = false
            status = ""
            isProviderNameFocused = true
        } label: {
            Label(I18N.shared.localized("添加供应商", "Add Provider"), systemImage: "plus")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.provider.add")
    }

    private func setProviderEnabled(_ provider: AIProviderProfile, enabled: Bool) {
        editor.load(provider, apiKey: store.apiKey(for: provider.id))
        editor.edit(provider.id) { $0.provider.isEnabled = enabled }
    }

    private var providerDetailPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsScrollView {
            VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                if let provider = selectedAIProvider {
                    AIProviderIcon(kind: provider.kind, size: 46, providerID: provider.id)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedAIProvider?.name.isEmpty == false
                         ? localizedBuiltInProviderName(selectedAIProvider?.name ?? "")
                         : I18N.shared.localized("新供应商", "New provider"))
                        .font(.system(size: 19, weight: .semibold))
                    Text(localizedBuiltInProviderDescription(selectedAIProvider?.description ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(draftProviderEnabled ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(draftProviderEnabled
                    ? I18N.shared.localized("已启用", "Enabled")
                    : I18N.shared.localized("已停用", "Disabled"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 5) {
                Text(I18N.shared.localized("基础配置", "Connection"))
                    .font(.system(size: 17, weight: .semibold))
                Text(I18N.shared.localized(
                    "配置供应商连接，保存后即可添加和使用模型。",
                    "Configure the provider connection before adding and using models."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 11) {
                providerEditorRow(I18N.shared.localized("名称", "Name")) {
                    if selectedAIProvider?.isBuiltIn == true {
                        providerReadOnlyValue(localizedBuiltInProviderName(configuration.providerName))
                    } else {
                        TextField(I18N.shared.localized("例如：Gemini", "For example: Gemini"), text: localizedProviderNameBinding)
                            .focused($isProviderNameFocused)
                            .accessibilityIdentifier("settings.provider.name")
                            .textFieldStyle(SettingsInputStyle())
                    }
                }

                providerEditorRow(I18N.shared.localized("描述", "Description")) {
                    if selectedAIProvider?.isBuiltIn == true {
                        providerReadOnlyValue(localizedBuiltInProviderDescription(configuration.providerDescription))
                    } else {
                        TextField(I18N.shared.localized("例如：个人阅读助手", "For example: Reading assistant"), text: localizedProviderDescriptionBinding)
                            .textFieldStyle(SettingsInputStyle())
                    }
                }

                providerEditorRow("API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if showsAPIKey {
                                TextField(I18N.shared.localized("局域网模型可留空", "Optional for local models"), text: apiKeyBinding)
                            } else {
                                SecureField(I18N.shared.localized("局域网模型可留空", "Optional for local models"), text: apiKeyBinding)
                            }
                        }
                        .textFieldStyle(SettingsInputStyle())

                        Button { showsAPIKey.toggle() } label: {
                            Image(systemName: showsAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(I18N.shared.localized(showsAPIKey ? "隐藏密钥" : "显示密钥", showsAPIKey ? "Hide key" : "Show key"))
                    }
                }

                providerEditorRow("Base URL") {
                    if selectedAIProvider?.isBuiltIn == true {
                        providerReadOnlyValue(configuration.baseURL)
                            .textSelection(.enabled)
                    } else {
                        TextField(I18N.shared.localized("供应商 API 根地址", "Provider API root URL"), text: configurationBinding.baseURL)
                            .textFieldStyle(SettingsInputStyle())
                    }
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            }

            Divider().opacity(0.35)

            if selectedAIProvider?.isBuiltIn == false {
                Toggle(I18N.shared.localized("允许不安全的本地 HTTP 端点", "Allow insecure local HTTP endpoints"),
                       isOn: configurationBinding.allowInsecureLocalEndpoint)
                    .font(.system(size: 12))
            }
            providerModelManagementSection
            }
            .padding(16)
            }
            Divider().opacity(0.35)
            if !status.isEmpty {
                Text(status).font(.system(size: 12)).foregroundStyle(statusIsSuccess ? Color.secondary : Color.red)
                    .padding(.horizontal, 16).padding(.top, 8).textSelection(.enabled)
            }
            if let suggestion = adaptationSuggestion,
               suggestion.providerID == selectedProviderID, suggestion.revision == draftRevision {
                Button(I18N.shared.localized("采用检测到的适配", "Use detected adapter")) {
                    setModelAdaptation(suggestion.adaptation, modelID: suggestion.modelID)
                    adaptationSuggestion = nil
                    status = I18N.shared.localized("已更新草稿，请保存更改。", "Draft updated. Save changes to apply.")
                }
                .accessibilityIdentifier("settings.model.applyAdaptation")
                .padding(.horizontal, 16).padding(.top, 6)
            }
            HStack(spacing: 9) {
                if let provider = selectedAIProvider, !provider.isBuiltIn, editor.newProviderID != provider.id {
                    Button(I18N.shared.localized("删除供应商", "Delete Provider"), role: .destructive) {
                        providerPendingDeletion = provider
                        isShowingDeleteProviderAlert = true
                    }
                    .buttonStyle(.bordered)
                }

                if isProviderDraftDirty {
                    Button(I18N.shared.localized(editor.newProviderID == selectedProviderID ? "取消新增" : "放弃更改",
                                                 editor.newProviderID == selectedProviderID ? "Cancel New Provider" : "Discard Changes")) {
                        discardSelectedProvider()
                    }
                    .buttonStyle(.bordered)
                }
                if selectedAIProvider?.kind == .deepSeek {
                    Button(I18N.shared.localized("恢复推荐配置", "Restore Defaults")) { useDeepSeekDefaults() }
                        .buttonStyle(.bordered)
                }

                Spacer()

                Button(I18N.shared.localized(isTesting ? "正在测试…" : "测试连接", isTesting ? "Testing…" : "Test Connection")) {
                    test()
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || configuration.model.isEmpty)

                Button(I18N.shared.localized("保存更改", "Save Changes")) {
                    saveSelectedProvider()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isProviderDraftDirty)
                .accessibilityIdentifier("settings.provider.save")
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
    }

    private var providerModelManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(I18N.shared.localized("模型管理", "Models"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(I18N.shared.localized(
                        "添加后，模型即可在各项 AI 功能中选择。",
                        "Added models become available to individual AI features."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showAddModelsSheet()
                } label: {
                    Label(I18N.shared.localized("添加模型", "Add Model"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if draftModels.isEmpty {
                Text(I18N.shared.localized("尚未添加模型。", "No models added yet."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(draftModels) { model in
                        HStack(spacing: 11) {
                            ZStack {
                                Circle().fill(Color.primary.opacity(0.05))
                                Image(systemName: "cube")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(model.source == .manual
                                    ? I18N.shared.localized("手动添加", "Manually added")
                                    : I18N.shared.localized("供应商目录", "Provider catalog"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let badge = model.adaptationBadge {
                                Text(badge).font(.caption).foregroundStyle(.secondary)
                            }
                            if configuration.model == model.id {
                                Text(I18N.shared.localized("默认", "Default"))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(settingsAccentColor)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(settingsAccentColor.opacity(0.10), in: Capsule())
                            }

                            Menu {
                                Menu(I18N.shared.localized("模型适配：", "Model adapter: ") + model.adaptation.title) {
                                    Text(I18N.shared.localized("控制发给模型的消息格式", "Controls the message format sent to the model"))
                                    ForEach(AIModelAdaptation.allCases, id: \.self) { adaptation in
                                        Button((model.adaptation == adaptation ? "✓ " : "　") + adaptation.title) {
                                            setModelAdaptation(adaptation, modelID: model.id)
                                        }
                                    }
                                    Divider()
                                    Text(modelAdaptationExplanation(model))
                                }
                                Menu(I18N.shared.localized("思考协议：", "Reasoning protocol: ") + reasoningProtocolTitle(model.reasoningProtocol)) {
                                    Text(I18N.shared.localized("控制思考开关与等级参数的发送方式", "Controls how thinking switches and effort levels are sent"))
                                    ForEach(AIReasoningProtocol.allCases, id: \.self) { wire in
                                        Button((model.reasoningProtocol == wire ? "✓ " : "　") + reasoningProtocolTitle(wire)) {
                                            editor.edit(selectedProviderID) { draft in
                                                guard let index = draft.provider.models.firstIndex(where: { $0.id == model.id }) else { return }
                                                draft.provider.models[index].reasoningProtocol = wire
                                                draft.provider.models[index].reasoningMetadata = nil
                                            }
                                        }
                                    }
                                    Divider()
                                    if model.usesTranslationAdaptation {
                                        Text(I18N.shared.localized("翻译适配不发送思考参数", "Translation adapters do not send reasoning parameters"))
                                    } else {
                                        let wire = draftAIProvider?.runtimeConfiguration(modelID: model.id, features: store.aiSettings.features).reasoningCapabilities.wireProtocol ?? .automatic
                                        Text(I18N.shared.localized("当前识别：", "Currently resolved: ") + (wire == .automatic
                                            ? I18N.shared.localized("未确认，使用服务默认", "Unknown; use server defaults")
                                            : reasoningProtocolTitle(wire)))
                                    }
                                }
                                Button(I18N.shared.localized("测试模型", "Test Model")) { test(modelID: model.id) }
                                Button(I18N.shared.localized("删除模型", "Remove Model"), role: .destructive) {
                                    providerModelPendingDeletion = model
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 24, height: 24)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(accessibilityContrast == .increased ? 0.45 : 0.075), lineWidth: 0.8)
                        }
                    }
                }
            }
        }
    }

    private func showAddModelsSheet() {
        selectedCandidateModelIDs.removeAll()
        fetchedModelCandidates.removeAll()
        modelCandidateSearchText = ""
        isShowingAddModelsSheet = true
        fetchModels()
    }

    private func providerEditorRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 92, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 34)
    }

    private func providerReadOnlyValue(_ value: String) -> some View {
        Text(value)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            }
    }

    private func modelListDisclosure(_ provider: AIProviderProfile) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsAIModelList.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showsAIModelList ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    Text(I18N.shared.localizedFormat(
                        "已配置模型（%lld 个）",
                        provider.models.count
                    ))
                    .font(.subheadline.weight(.medium))

                    Spacer(minLength: 8)

                    Text(showsAIModelList
                        ? I18N.shared.localized("收起", "Collapse")
                        : I18N.shared.localized("展开", "Expand"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18N.shared.localized("模型列表", "Model list"))
            .accessibilityValue(showsAIModelList
                ? I18N.shared.localized("已展开", "Expanded")
                : I18N.shared.localized("已收起", "Collapsed"))
            .accessibilityAddTraits(.isToggle)

            if showsAIModelList {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(provider.models) { model in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text(model.displayName)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Button(I18N.shared.localized("测试", "Test")) { test(modelID: model.id) }
                                    .controlSize(.small)
                                Button(role: .destructive) {
                                    providerModelPendingDeletion = model
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(9)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.leading, 26)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 2)
    }

    private var addModelsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(I18N.shared.localized("添加模型", "Add Models")).font(.title3.weight(.semibold))
                    Text(localizedBuiltInProviderName(selectedAIProvider?.name ?? ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if isFetchingModels { ProgressView().controlSize(.small) }
            }
            .padding(20)

            TextField(I18N.shared.localized("搜索远端模型", "Search remote models"), text: $modelCandidateSearchText)
                .textFieldStyle(SettingsInputStyle())
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            List(filteredModelCandidates) { model in
                let alreadyConfigured = draftModels.contains(where: { $0.id == model.id })
                Button {
                    guard !alreadyConfigured else { return }
                    if selectedCandidateModelIDs.contains(model.id) {
                        selectedCandidateModelIDs.remove(model.id)
                    } else {
                        selectedCandidateModelIDs.insert(model.id)
                    }
                } label: {
                    HStack {
                        Image(systemName: alreadyConfigured ? "checkmark.circle.fill" : selectedCandidateModelIDs.contains(model.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(alreadyConfigured ? .secondary : settingsAccentColor)
                        Text(model.displayName).font(.system(.body, design: .monospaced))
                        Spacer()
                        if alreadyConfigured {
                            Text(I18N.shared.localized("已配置", "Configured"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(alreadyConfigured)
            }
            .overlay {
                if !isFetchingModels && fetchedModelCandidates.isEmpty {
                    ContentUnavailableView(
                        I18N.shared.localized("未获取到模型目录", "No Model Catalog"),
                        systemImage: "server.rack",
                        description: Text(I18N.shared.localized("可检查连接后重试，或在下方手动填写模型 ID。", "Check the connection and retry, or enter a model ID below."))
                    )
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField(I18N.shared.localized("手动输入模型 ID", "Enter model ID manually"), text: $manualModelID)
                    .textFieldStyle(SettingsInputStyle())
                Button(I18N.shared.localized("手动添加", "Add Manually")) { addManualModel() }
                    .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button(I18N.shared.localized("重新拉取", "Refresh")) { fetchModels() }
                    .disabled(isFetchingModels)
                Button(I18N.shared.localized("取消", "Cancel")) { isShowingAddModelsSheet = false }
                Button(I18N.shared.localizedFormat("添加 %lld 个", selectedCandidateModelIDs.count)) {
                    confirmCandidateModels()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCandidateModelIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var filteredModelCandidates: [AIModelOption] {
        let query = modelCandidateSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return fetchedModelCandidates }
        return fetchedModelCandidates.filter {
            $0.id.lowercased().contains(query) || $0.displayName.lowercased().contains(query)
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(I18N.shared.localized("关于", "About"))
                .font(.system(size: 26, weight: .bold))
            HStack(alignment: .center, spacing: 20) {
                appIconView
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("PaperRss").font(.system(size: 26, weight: .bold))
                        if AppInfo.currentVersion.contains("beta") {
                            Text("Beta")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(settingsAccentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(settingsAccentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(I18N.shared.localized("专注阅读，连接你的信息世界。", "A focused home for your reading."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Version \(AppInfo.currentVersion) · Build \(AppInfo.currentBuild)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(settingsAccentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(accessibilityContrast == .increased ? 0.4 : 0.08), lineWidth: 1)
            }

            settingsGroup(
                I18N.shared.localized("软件更新", "Software Update"),
                info: I18N.shared.localized(
                    "更新经数字签名验证后安装；Beta 通道可能不够稳定。",
                    "Updates are installed only after signature verification. The Beta channel may be less stable."
                )
            ) {
                settingsRow(
                    I18N.shared.localized("当前版本状态", "Current Version Status"),
                    description: updateStatusDescription
                ) {
                    updateStatusControls
                }

                #if os(macOS)
                Divider().padding(.horizontal, 18).opacity(0.18)

                settingsRow(
                    I18N.shared.localized("更新通道", "Update Channel")
                ) {
                    updateChannelPicker
                }
                #endif

                if let notes = activeReleaseNotes, !notes.isEmpty {
                    Divider().padding(.horizontal, 18).opacity(0.18)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(I18N.shared.localizedFormat("新版本更新说明 (%@)", activeReleaseVersion))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(notes)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(8)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
            }

            settingsGroup(
                I18N.shared.localized("开源社区", "Open Source")
            ) {
                settingsRow(
                    I18N.shared.localized("GitHub 官方仓库", "GitHub Repository")
                ) {
                    Button {
                        AppInfo.openURL(AppInfo.githubRepositoryURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text(I18N.shared.localized("前往 GitHub", "Open GitHub"))
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            feedbackSettings
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var updateStatusControls: some View {
        do {
            let coordinator = updateCoordinator
            switch coordinator.state {
            case .checking, .checkingSilently:
                ProgressView()
                    .controlSize(.small)
            case .downloading:
                ProgressView()
                    .controlSize(.small)
            case .preparing:
                ProgressView()
                    .controlSize(.small)
            case let .readyToInstall(release):
                Button {
                    coordinator.installAndRelaunch()
                } label: {
                    Label(I18N.shared.localized("重启并安装 %@", release.displayVersion), systemImage: "power.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            case let .updateAvailable(release):
                Button {
                    coordinator.beginDownload()
                } label: {
                    Label(
                        I18N.shared.localizedFormat("下载更新 %@", release.displayVersion),
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
            case .failed:
                Button(I18N.shared.localized("重试检查", "Retry Check")) {
                    coordinator.checkForUpdates()
                }
                .buttonStyle(.bordered)
            default:
                Button(I18N.shared.localized("检查更新", "Check for Updates")) {
                    coordinator.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.state.isActiveSession)
            }
        }
    }

    private var updateChannelPicker: some View {
        SettingsCompactSwitcher(
            options: UpdateChannel.allCases,
            selection: Binding(
                get: { updateCoordinator.channel },
                set: { channel in
                    guard updateCoordinator.canChangeChannel else { return }
                    updateCoordinator.selectChannel(channel)
                }
            ),
            accent: settingsAccentColor,
            title: { $0 == .stable
                ? I18N.shared.localized("Stable 稳定版", "Stable")
                : I18N.shared.localized("Beta 抢先版", "Beta") }
        )
        .disabled(!updateCoordinator.canChangeChannel)
        .accessibilityLabel(I18N.shared.localized("通道", "Channel"))
    }

    #endif

    private var activeReleaseNotes: String? {
        #if os(macOS)
        let coordinator = updateCoordinator
        switch coordinator.state {
        case let .updateAvailable(release):
            return release.releaseNotes
        case let .downloading(progress):
            return progress.release.releaseNotes
        case let .preparing(preparation):
            return preparation.release.releaseNotes
        case let .readyToInstall(release):
            return release.releaseNotes
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

    private var activeReleaseVersion: String {
        #if os(macOS)
        let coordinator = updateCoordinator
        switch coordinator.state {
        case let .updateAvailable(release):
            return release.displayVersion
        case let .downloading(progress):
            return progress.release.displayVersion
        case let .preparing(preparation):
            return preparation.release.displayVersion
        case let .readyToInstall(release):
            return release.displayVersion
        default:
            return ""
        }
        #else
        return ""
        #endif
    }

    private var updateStatusDescription: String {
        #if os(macOS)
        let coordinator = updateCoordinator
        switch coordinator.state {
        case .idle:
            return I18N.shared.localized("尚未检查", "Not checked yet")
        case .checking, .checkingSilently:
            return I18N.shared.localized("正在检查更新…", "Checking for updates...")
        case let .upToDate(checkedAt):
            let timeString = DateFormatter.localizedString(from: checkedAt, dateStyle: .none, timeStyle: .short)
            return I18N.shared.localizedFormat("已是最新版本（上次检查：%@）", timeString)
        case let .updateAvailable(release):
            return I18N.shared.localizedFormat("发现新版本：%@", release.displayVersion)
        case let .downloading(progress):
            if let fraction = progress.fractionCompleted {
                return I18N.shared.localizedFormat("正在下载更新：%lld%%", Int((fraction * 100).rounded()))
            }
            return I18N.shared.localized("正在下载更新…", "Downloading update…")
        case let .preparing(preparation):
            return I18N.shared.localizedFormat("正在准备更新：%lld%%", Int((preparation.fractionCompleted * 100).rounded()))
        case let .readyToInstall(release):
            return I18N.shared.localizedFormat("更新 %@ 已就绪，重启即可完成安装。", release.displayVersion)
        case let .installing(release):
            return I18N.shared.localizedFormat("正在安装更新 %@…", release.displayVersion)
        case .relaunching:
            return I18N.shared.localized("正在重启以完成安装…", "Relaunching to finish installation…")
        case let .deferredUntilQuit(release):
            return I18N.shared.localizedFormat("更新 %@ 将在退出应用时自动安装。", release.displayVersion)
        case let .failed(failure):
            return I18N.shared.localizedFormat("检查更新失败：%@", failure.message)
        }
        #else
        return I18N.shared.localized("此构建不支持应用内更新。", "In-app updates are unavailable in this build.")
        #endif
    }

    @ViewBuilder
    private var appIconView: some View {
        #if os(macOS)
        // 复用包内的多分辨率 macOS 图标，不额外打包图片。
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSApplication.shared.applicationIconImage
            ?? NSImage(size: NSSize(width: 64, height: 64))
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .padding(.top, 8)
        #else
        if let icon = UIImage(named: "AppIcon") {
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                .padding(.top, 8)
        } else {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)
        }
        #endif
    }

    /// 「已缓存 XX 篇文章，大小 xx MB」；stats 未加载时返回空格占位（保持行高稳定）。
    private var cacheStatsText: String {
        guard let cacheStats else { return " " }
        let mb = Double(cacheStats.totalBytes) / 1_048_576.0
        return I18N.shared.localizedFormat("已缓存 %lld 篇文章，大小 %.1f MB", cacheStats.count, mb)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(I18N.shared.localized("常规", "General"))
                .font(.system(size: 26, weight: .bold))
            languageSettings
            refreshSettings
        }
    }

    private var refreshSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(I18N.shared.localized("订阅刷新", "Feed Refresh")) {
                settingsRow("打开应用时自动刷新") {
                    Toggle(I18N.localized("打开应用时自动刷新"), isOn: Binding(
                        get: { store.refreshOnLaunch },
                        set: { store.setRefreshOnLaunch($0) }
                    ))
                    .labelsHidden()
                }
                Divider().padding(.horizontal, 18).opacity(0.18)
                settingsRow("自动刷新订阅") {
                    Picker(
                        "自动刷新订阅",
                        selection: Binding(
                            get: { store.refreshInterval },
                            set: { store.setRefreshInterval($0) }
                        )
                    ) {
                        ForEach(FeedRefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                }
                Divider().padding(.horizontal, 18).opacity(0.18)
                settingsRow("订阅源") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label(I18N.localized("刷新"), systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)

                        RefreshStatusView(store: store, compact: true)
                    }
                }
            }

            settingsGroup(
                I18N.shared.localized("维护与恢复", "Maintenance & Recovery"),
                info: I18N.shared.localized(
                    "清除本地缓存不会删除订阅或账号设置。",
                    "Clearing the local cache does not remove subscriptions or account settings."
                )
            ) {
                settingsRow("缓存数据") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button(role: .destructive) {
                            guard !isClearingCache else { return }
                            isClearingCache = true
                            cacheClearMessage = nil
                            cacheClearDismissTask?.cancel()
                            Task {
                                do {
                                    let count = try await store.clearArticleCaches()
                                    cacheStats = try? store.articleCacheStats()
                                    cacheClearMessage = I18N.shared.localizedFormat("已清除 %lld 条缓存", count)
                                } catch {
                                    cacheClearMessage = I18N.localized("清除失败")
                                }
                                isClearingCache = false
                                cacheClearDismissTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                                    cacheClearMessage = nil
                                }
                            }
                        } label: {
                            ZStack {
                                // 隐形占位：以最宽状态（转圈 + 正在清除…）锁定按钮尺寸，避免清除前后左右抖动
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small).opacity(0)
                                    Text(I18N.localized("正在清除…")).hidden()
                                }
                                if isClearingCache {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text(I18N.localized("正在清除…"))
                                    }
                                } else {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash")
                                        Text(I18N.localized("清除"))
                                    }
                                }
                            }
                        }
                        .disabled(isClearingCache)

                        // 固定槽位：清除结果消息优先，否则显示缓存统计；空时透明占位，行高恒定
                        Text(cacheClearMessage ?? cacheStatsText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .opacity((cacheClearMessage != nil || cacheStats != nil) ? 1 : 0)
                    }
                    .task {
                        cacheStats = try? store.articleCacheStats()
                    }
                }
            }

            #if os(macOS)
            reminderSettings
            #endif
        }
    }

    #if os(macOS)
    private var reminderSettings: some View {
        settingsGroup(
            I18N.shared.localized("提醒", "Alerts")
        ) {
            settingsRow(
                I18N.shared.localized("Dock 未读徽标", "Dock unread badge")
            ) {
                Toggle(
                    I18N.shared.localized("Dock 未读徽标", "Dock unread badge"),
                    isOn: Binding(
                        get: { attention.dockBadgeEnabled },
                        set: { attention.setDockBadgeEnabled($0) }
                    )
                )
                .labelsHidden()
            }
        }
    }
    #endif

    @ViewBuilder
    private func settingsGroup<Content: View>(
        _ title: String,
        info: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))

                if let info, !info.isEmpty {
                    SettingsInfoButton(message: info)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(accessibilityContrast == .increased ? 0.45 : 0.075), lineWidth: 0.8)
            }

        }
    }

    private func settingsSubsectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func settingsRow<Content: View>(
        _ title: String,
        description: String? = nil,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 15))

                if let description, !description.isEmpty {
                    Text(LocalizedStringKey(description))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)
            control()
                .controlSize(.regular)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .frame(minHeight: SettingsMetrics.rowMinimumHeight)
    }

    /// 内置默认文案属于产品界面，但字段本身允许用户编辑。读取时只翻译精确
    /// 匹配的内置值；写入时原样保存，避免语言切换覆盖自定义配置或迁移数据。
    private var localizedProviderNameBinding: Binding<String> {
        Binding(
            get: { localizedBuiltInProviderName(configuration.providerName) },
            set: { configuration.providerName = $0 }
        )
    }

    private var localizedProviderDescriptionBinding: Binding<String> {
        Binding(
            get: { localizedBuiltInProviderDescription(configuration.providerDescription) },
            set: { configuration.providerDescription = $0 }
        )
    }

    private func localizedBuiltInProviderName(_ value: String) -> String {
        switch value {
        case "OpenAI 兼容接口":
            I18N.shared.localized("OpenAI 兼容接口", "OpenAI-Compatible Endpoint")
        case "Google Gemini":
            I18N.shared.localized("Google Gemini", "Google Gemini")
        case "DeepSeek":
            value
        default:
            value
        }
    }

    private func localizedBuiltInProviderDescription(_ value: String) -> String {
        switch value {
        case "用于翻译、总结和解读文章":
            I18N.localized("用于翻译、总结和解读文章")
        case "DeepSeek OpenAI 兼容接口":
            I18N.shared.localized("DeepSeek OpenAI 兼容接口", "DeepSeek OpenAI-Compatible Endpoint")
        case "Google Gemini 官方 OpenAI 兼容接口":
            I18N.shared.localized("Google Gemini 官方 OpenAI 兼容接口", "Google Gemini official OpenAI-compatible endpoint")
        default:
            value
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if !status.isEmpty {
                Label(
                    status,
                    systemImage: statusIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(statusIsSuccess ? Color.green : Color.red)
                .lineLimit(2)
            }

            Spacer()

        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .background(settingsWindowBackground)
    }

    private var showsActionBar: Bool {
        !status.isEmpty && !(selectedSection == .aiService && selectedAISettingsPane == .providers)
    }

    private var settingsSidebarBackground: Color {
        #if os(macOS)
        Color(paperHex: store.readerAppearance.backgroundHex(for: readerAppearanceMode, surface: .sidebar))
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var settingsWindowBackground: Color {
        #if os(macOS)
        Color(paperHex: settingsAppearancePalette.backgroundHex)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    private var settingsGroupBackground: Color {
        #if os(macOS)
        Color(paperHex: store.readerAppearance.backgroundHex(for: readerAppearanceMode, surface: .articleList))
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    private var statusIsSuccess: Bool {
        status.hasPrefix("检测到") || status.hasPrefix("Detected") || status.hasPrefix("成功") || status.hasPrefix("已保存") || status.hasPrefix("已填入")
            || status.hasPrefix("已切换") || status.hasPrefix("已更新") || status.hasPrefix("已添加")
            || status.hasPrefix("Success") || status.hasPrefix("Saved") || status.hasPrefix("Recommended")
            || status.hasPrefix("Active") || status.hasPrefix("Updated") || status.hasPrefix("Added")
    }

    private func loadConfiguration() {
        for provider in store.aiSettings.providers { editor.load(provider, apiKey: store.apiKey(for: provider.id)) }
        if selectedAIProvider == nil { selectedProviderID = store.aiSettings.providers.first?.id ?? AIProviderID.deepSeek }
    }

    private func cancelProviderOperations() {
        editor.cancelOperations(for: selectedProviderID)
        adaptationSuggestion = nil
        modelFetchRequestID = nil
        testRequestID = nil
        isFetchingModels = false
        isTesting = false
    }

    private func selectProvider(_ providerID: String) {
        if providerID != selectedProviderID { cancelProviderOperations() }
        loadProvider(providerID)
        showsCompactProviderDetail = true
    }

    private func loadProvider(_ providerID: String) {
        cancelProviderOperations()
        if let provider = store.aiProvider(id: providerID) {
            editor.load(provider, apiKey: store.apiKey(for: providerID))
        }
        selectedProviderID = providerID
        manualModelID = ""
        showsAPIKey = false
        status = ""
    }

    private var isProviderDraftDirty: Bool { editor.drafts[selectedProviderID]?.isDirty ?? false }

    private func discardSelectedProvider() {
        let id = selectedProviderID
        editor.discard(id)
        loadProvider(store.aiProvider(id: id)?.id ?? store.aiSettings.providers.first?.id ?? AIProviderID.deepSeek)
    }

    @discardableResult
    private func saveSelectedProvider(updateStatus: Bool = true) -> Bool {
        guard let provider = draftAIProvider else { return false }
        do {
            guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = I18N.shared.localized("请填写供应商名称", "Enter a provider name")
                return false
            }
            try provider.validateConnection(requireModel: false)
            if editor.newProviderID == provider.id { store.addAIProvider(provider, apiKey: apiKey) }
            else { store.saveAIProvider(provider, apiKey: apiKey) }
            editor.markSaved(provider.id)
        } catch {
            status = error.localizedDescription
            return false
        }
        if updateStatus { status = I18N.shared.localized("已保存当前供应商配置", "Current provider configuration saved") }
        return true
    }

    private func useDeepSeekDefaults() {
        if selectedProviderID != AIProviderID.deepSeek {
            saveSelectedProvider(updateStatus: false)
        }
        guard let provider = store.aiProvider(id: AIProviderID.deepSeek) else { return }

        let currentFeatures = AIFeaturePreferences(configuration: configuration)
        var recommended = provider.runtimeConfiguration(features: currentFeatures)
        recommended.targetLanguage = currentFeatures.targetLanguage
        recommended.showsAISummary = currentFeatures.showsAISummary
        recommended.automaticallyGenerateSummary = currentFeatures.automaticallyGenerateSummary
        recommended.showsSelectionExplanation = currentFeatures.showsSelectionExplanation
        recommended.showsSelectionAsk = currentFeatures.showsSelectionAsk
        recommended.showsSelectionTranslation = currentFeatures.showsSelectionTranslation
        recommended.customPrompt = currentFeatures.customPrompt

        selectedProviderID = provider.id
        draftProviderEnabled = provider.isEnabled
        configuration = recommended
        apiKey = store.apiKey(for: provider.id)
        draftModels = provider.models
        status = I18N.shared.localized("已填入 DeepSeek 推荐配置；保存后即可测试。", "DeepSeek defaults filled in; save to test.")
    }

    private func addManualModel() {
        let modelID = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, var provider = draftAIProvider else { return }
        provider = provider.addingManualModel(id: modelID)
        draftModels = provider.models
        configuration.model = modelID
        showsAIModelList = true
        manualModelID = ""
        status = I18N.shared.localized("已添加模型", "Model added")
    }

    private func confirmCandidateModels() {
        for model in fetchedModelCandidates where selectedCandidateModelIDs.contains(model.id) {
            if let index = draftModels.firstIndex(where: { $0.id == model.id }) {
                draftModels[index].reasoningMetadata = model.reasoningMetadata
            } else { draftModels.append(model) }
        }
        if configuration.model.isEmpty { configuration.model = draftModels.first?.id ?? "" }
        selectedCandidateModelIDs.removeAll()
        showsAIModelList = true
        isShowingAddModelsSheet = false
        status = I18N.shared.localized("已加入供应商草稿，保存更改后生效", "Added to the provider draft. Save changes to apply.")
    }

    private func setModelEnabled(_ modelID: String, enabled: Bool) {
        guard var provider = draftAIProvider else { return }
        provider = provider.updatingModel(id: modelID, isEnabled: enabled)
        draftModels = provider.models
    }

    private func fetchModels() {
        guard let provider = draftAIProvider else { return }
        isFetchingModels = true
        status = ""
        let providerID = selectedProviderID
        let requestID = editor.beginOperation(for: providerID)
        let revision = draftRevision
        let requestedAPIKey = apiKey
        modelFetchRequestID = requestID
        let task = Task { @MainActor in
            defer {
                if modelFetchRequestID == requestID {
                    isFetchingModels = false
                }
            }
            do {
                let models = try await store.fetchAIModels(provider: provider, apiKey: requestedAPIKey)
                guard modelFetchRequestID == requestID, selectedProviderID == providerID, editor.accepts(requestID, for: providerID, revision: revision) else { return }
                fetchedModelCandidates = models
                editor.edit(providerID) { draft in
                    for index in draft.provider.models.indices {
                        if let fetched = models.first(where: { $0.id == draft.provider.models[index].id }) {
                            draft.provider.models[index].reasoningMetadata = fetched.reasoningMetadata
                        }
                    }
                }
                status = I18N.shared.isEnglish ? "Fetched \(models.count) models" : "已拉取 \(models.count) 个候选模型"
            } catch {
                guard modelFetchRequestID == requestID,
                      selectedProviderID == providerID,
                      editor.accepts(requestID, for: providerID, revision: revision) else { return }
                status = error.localizedDescription
            }
        }
        editor.register(task, for: providerID, token: requestID)
    }

    private func reasoningProtocolTitle(_ wire: AIReasoningProtocol) -> String {
        switch wire {
        case .automatic: I18N.shared.localized("自动", "Automatic")
        case .deepSeek: "DeepSeek"
        case .gemini: "Google Gemini"
        case .dashscope: I18N.shared.localized("阿里云百炼", "Alibaba Cloud Model Studio")
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        }
    }

    private func modelAdaptationExplanation(_ model: AIModelOption) -> String {
        switch model.adaptation {
        case .automatic:
            I18N.shared.localized("当前格式：", "Current format: ") + model.adaptation.resolved(modelID: model.id).title
        case .chat:
            I18N.shared.localized("分别发送系统指令与用户内容", "Sends system instructions and user content separately")
        case .userMessage:
            I18N.shared.localized("合并为一条用户消息，兼容不接受系统消息的接口", "Combines instructions and content for endpoints without system messages")
        case .qwenTranslation:
            I18N.shared.localized("发送原文与目标语言，仅用于翻译功能", "Sends source text and target language for translation features only")
        }
    }

    private func setModelAdaptation(_ adaptation: AIModelAdaptation, modelID: String) {
        editor.edit(selectedProviderID) { draft in
            guard let index = draft.provider.models.firstIndex(where: { $0.id == modelID }) else { return }
            draft.provider.models[index].adaptation = adaptation
        }
    }

    private func test() {
        test(modelID: configuration.model)
    }

    private func test(modelID: String) {
        guard let provider = draftAIProvider else { return }
        isTesting = true
        adaptationSuggestion = nil
        status = ""
        let providerID = selectedProviderID
        let requestID = editor.beginOperation(for: providerID)
        let revision = draftRevision
        let requestedAPIKey = apiKey
        testRequestID = requestID
        let task = Task { @MainActor in
            defer {
                if testRequestID == requestID {
                    isTesting = false
                }
            }
            do {
                var requestedProvider = provider.selectingModel(modelID)
                requestedProvider = requestedProvider.replacing(selectedModelID: modelID)
                let result = try await store.probeAIProvider(provider: requestedProvider, apiKey: requestedAPIKey)
                guard testRequestID == requestID, selectedProviderID == providerID, editor.accepts(requestID, for: providerID, revision: revision) else { return }
                if let adaptation = result.suggestedAdaptation {
                    adaptationSuggestion = (providerID, modelID, revision, adaptation)
                    status = I18N.shared.localized("检测到可用适配：", "Detected adapter: ") + adaptation.title
                        + I18N.shared.localized("。采用后请保存更改。", ". Apply and save changes to use it.")
                } else {
                    status = I18N.shared.localized("成功：当前模型可以响应。", "Success: selected model responded.")
                }
            } catch {
                guard testRequestID == requestID,
                      selectedProviderID == providerID,
                      editor.accepts(requestID, for: providerID, revision: revision) else { return }
                status = error.localizedDescription
            }
        }
        editor.register(task, for: providerID, token: requestID)
    }
}

private struct AppearanceThreeColumnPreview: View {
    let appearance: ReaderAppearance
    let mode: ReaderAppearanceMode
    let bodyFont: Font

    var body: some View {
        HStack(spacing: 1) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "newspaper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                previewRule(width: 38)
                previewRule(width: 48)
                previewRule(width: 32)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 90)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(surface(.sidebar))

            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        previewRule(width: index == 1 ? 70 : 82)
                        previewRule(width: index == 2 ? 48 : 58, opacity: 0.38)
                    }
                    if index < 2 {
                        Divider().opacity(0.35)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 142)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(surface(.articleList))

            VStack(alignment: .leading, spacing: 8) {
                Text(I18N.shared.localized("静夜思 · 李白", "Quiet Night Thoughts · Li Bai"))
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(ink)
                Text(I18N.shared.localized("唐诗选读 · 阅读预览", "Poetry · Reading Preview"))
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
                Text("床前明月光，疑是地上霜。\n举头望明月，低头思故乡。")
                    .font(bodyFont)
                    .lineSpacing(CGFloat(appearance.fontSize) * max(0, appearance.lineHeight - 1.2))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(I18N.shared.localized("在文字间放慢脚步，让阅读回归专注。主题同步呈现于侧栏、文章列表与正文，字体设置仅影响阅读内容。", "Slow down between the lines. The theme follows you across the sidebar, article list, and reader; font preferences apply only to reading content."))
                    .font(bodyFont)
                    .lineSpacing(CGFloat(appearance.fontSize) * max(0, appearance.lineHeight - 1.2))
                    .foregroundStyle(muted)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(surface(.reader))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                .stroke(ink.opacity(0.14), lineWidth: 1)
        }
        .environment(\.colorScheme, palette.colorScheme == .dark ? .dark : .light)
        .accessibilityElement(children: .combine)
    }

    private var palette: ReaderAppearancePalette {
        appearance.palette(for: mode)
    }

    private var ink: Color { Color(paperHex: palette.inkHex) }
    private var muted: Color { Color(paperHex: palette.mutedHex) }
    private var accent: Color { Color(paperHex: palette.accentHex) }

    private func surface(_ role: AppearanceSurfaceRole) -> Color {
        Color(paperHex: appearance.backgroundHex(for: mode, surface: role))
    }

    private func previewRule(width: CGFloat, opacity: Double = 0.62) -> some View {
        Capsule()
            .fill(ink.opacity(opacity))
            .frame(width: width, height: 4)
    }
}

private struct ReaderThemeSwatch: View {
    let preset: ReaderThemePreset

    var body: some View {
        let appearance = ReaderAppearance(preset: preset)
        let palette = appearance.palette(for: .light)

        HStack(spacing: 1) {
            ForEach(AppearanceSurfaceRole.allCases, id: \.self) { role in
                ZStack(alignment: .topLeading) {
                    Color(paperHex: appearance.backgroundHex(for: .light, surface: role))

                    VStack(alignment: .leading, spacing: 4) {
                        Capsule()
                            .fill(Color(paperHex: palette.inkHex).opacity(0.78))
                            .frame(width: role == .reader ? 20 : 13, height: 3)
                        Capsule()
                            .fill(Color(paperHex: palette.mutedHex).opacity(0.48))
                            .frame(width: role == .sidebar ? 12 : 18, height: 2.5)
                        if role == .reader {
                            Capsule()
                                .fill(Color(paperHex: palette.accentHex).opacity(0.7))
                                .frame(width: 15, height: 2.5)
                        }
                    }
                    .padding(7)
                }
            }
        }
        .frame(width: 112, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

private extension Color {
    var readerHexString: String {
        #if os(macOS)
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
        #endif
    }
}

struct RefreshStatusView: View {
    @ObservedObject var store: AppStore
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            statusText
        }
        .font(compact ? .caption : .subheadline)
        .foregroundStyle(statusColor)
        .lineLimit(1)
        .help(statusHelp)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch store.refreshStatus {
        case .refreshing:
            ProgressView()
                .controlSize(compact ? .mini : .small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .idle:
            Image(systemName: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch store.refreshStatus {
        case .refreshing:
            Text(I18N.localized("正在刷新订阅…"))
        case let .completed(updatedFeeds, finishedAt):
            HStack(spacing: 4) {
                Text(
                    updatedFeeds > 0
                        ? I18N.shared.localizedFormat("已检查 %lld 个订阅", updatedFeeds)
                        : I18N.shared.localized("已检查，没有新消息")
                )
                Text(I18N.localized("·"))
                Text(finishedAt, style: .time)
            }
        case let .failed(message, _):
            Text(I18N.shared.localizedFormat("刷新遇到问题：%@", message))
        case .idle:
            Text(I18N.localized("尚未刷新"))
        }
    }

    private var statusColor: Color {
        switch store.refreshStatus {
        case .refreshing, .idle: .secondary
        case .completed: .green
        case .failed: .orange
        }
    }

    private var statusHelp: String {
        switch store.refreshStatus {
        case .refreshing: I18N.shared.localized("正在请求订阅源最新内容")
        case .completed: I18N.shared.localized("订阅刷新完成")
        case .failed: I18N.shared.localized("部分订阅刷新失败")
        case .idle: I18N.shared.localized("还没有进行刷新")
        }
    }
}

private enum AccountProviderType: String, CaseIterable, Identifiable {
    case freshRSS

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .freshRSS: return "FreshRSS"
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .freshRSS: return I18N.shared.localized("兼容 Google Reader API 的自建 RSS 服务", "Google Reader compatible account")
        }
    }

    var icon: String {
        switch self {
        case .freshRSS: return "server.rack"
        }
    }
}

private struct AddAccountSheet: View {
    @ObservedObject var store: AppStore
    @Binding var isPresented: Bool
    @Environment(\.paperAppearancePalette) private var paperAppearancePalette

    @State private var selectedProvider: AccountProviderType? = nil

    // FreshRSS 表单状态
    @State private var freshRSSEndpoint = ""
    @State private var freshRSSUsername = ""
    @State private var freshRSSPassword = ""
    @State private var freshRSSDisplayName = ""
    @State private var isAdding = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if let provider = selectedProvider {
                switch provider {
                case .freshRSS:
                    freshRSSFormView
                }
            } else {
                providerChooserView
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, maxWidth: 500, minHeight: 360)
        #endif
    }

    private var headerView: some View {
        HStack {
            if selectedProvider != nil {
                Button {
                    withAnimation {
                        selectedProvider = nil
                        errorMessage = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(I18N.shared.localized("上一步", "Back"))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else {
                Text(I18N.shared.localized("添加账号", "Add Account"))
                    .font(.headline)
            }

            Spacer()

            if selectedProvider != nil {
                Text(selectedProvider?.title ?? "")
                    .font(.headline)
                Spacer()
            }

            Button(I18N.shared.localized("取消", "Cancel")) {
                isPresented = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var providerChooserView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18N.shared.localized("选择 RSS 服务提供商", "Choose an RSS Provider"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            List(AccountProviderType.allCases) { provider in
                Button {
                    withAnimation {
                        selectedProvider = provider
                        errorMessage = nil
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: provider.icon)
                            .font(.system(size: 22))
                            .foregroundStyle(Color(paperHex: paperAppearancePalette.accentHex))
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.primary)
                            Text(provider.subtitle)
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary.opacity(0.5))
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: false))
            #else
            .listStyle(.inset)
            #endif
        }
    }

    private var freshRSSFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(I18N.shared.localized("输入您的 FreshRSS 服务信息与 API 凭据。密码将安全保存在系统 Keychain 中。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    HStack {
                        Text(I18N.shared.localized("服务器地址"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        TextField(I18N.shared.localized("https://rss.example.com 或 /api/greader.php"), text: $freshRSSEndpoint)
                            .textFieldStyle(SettingsInputStyle())
                    }

                    HStack {
                        Text(I18N.shared.localized("用户名"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        TextField(I18N.shared.localized("FreshRSS 用户名"), text: $freshRSSUsername)
                            .textFieldStyle(SettingsInputStyle())
                    }

                    HStack {
                        Text(I18N.shared.localized("API 密码"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        SecureField(I18N.shared.localized("用户配置中生成的 API 密码"), text: $freshRSSPassword)
                            .textFieldStyle(SettingsInputStyle())
                    }

                    HStack {
                        Text(I18N.shared.localized("显示名称"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        TextField(I18N.shared.localized("可选（默认服务器域名）"), text: $freshRSSDisplayName)
                            .textFieldStyle(SettingsInputStyle())
                    }
                }

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.top, 4)
                }

                HStack {
                    Spacer()
                    Button {
                        Task {
                            isAdding = true
                            errorMessage = nil
                            do {
                                _ = try await store.addFreshRSSAccount(
                                    endpointURLText: freshRSSEndpoint,
                                    username: freshRSSUsername,
                                    password: freshRSSPassword,
                                    displayName: freshRSSDisplayName.isEmpty ? nil : freshRSSDisplayName
                                )
                                isPresented = false
                                freshRSSEndpoint = ""
                                freshRSSUsername = ""
                                freshRSSPassword = ""
                                freshRSSDisplayName = ""
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isAdding = false
                        }
                    } label: {
                        if isAdding {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(I18N.shared.localized("测试连接并添加账号"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAdding || freshRSSEndpoint.isEmpty || freshRSSUsername.isEmpty || freshRSSPassword.isEmpty)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }
}

/// 设置页的滚动条叠在右侧留白上，不参与内容宽度计算。
private struct SettingsScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    #if os(macOS)
    @State private var scrollbar = PaperFloatingScrollbarView()
    #endif

    var body: some View {
        ScrollView(.vertical) {
            content
                #if os(macOS)
                .background(SettingsScrollTarget(scrollbar: scrollbar))
                #endif
        }
        #if os(macOS)
        .scrollIndicators(.never, axes: .vertical)
        .overlay(alignment: .trailing) {
            SettingsScrollbarOverlay(scrollbar: scrollbar)
                .frame(width: PaperFloatingScrollbarView.hitLaneWidth)
                .accessibilityHidden(true)
        }
        #endif
    }
}

#if os(macOS)
private struct SettingsScrollbarOverlay: NSViewRepresentable {
    let scrollbar: PaperFloatingScrollbarView

    func makeNSView(context: Context) -> PaperFloatingScrollbarView { scrollbar }
    func updateNSView(_ nsView: PaperFloatingScrollbarView, context: Context) {}
}

/// 从内容内部向上绑定所属滚动容器，避免误选供应商页的相邻列表或嵌套文本框。
private struct SettingsScrollTarget: NSViewRepresentable {
    let scrollbar: PaperFloatingScrollbarView

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.scrollbar = scrollbar
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.scrollbar = scrollbar
        nsView.scheduleAttachment()
    }

    final class Probe: NSView {
        weak var scrollbar: PaperFloatingScrollbarView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleAttachment()
        }

        func scheduleAttachment() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                self.scrollbar?.attach(to: scrollView)
            }
        }
    }
}
#endif

/// 预览与阅读器一样按较长内容预留高度，避免悬浮时推动设置行。
private struct TranslationReplacementPreview: View {
    @State private var showsOriginal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("Reading opens a window to the world.")
                .opacity(showsOriginal ? 1 : 0)
                .accessibilityHidden(!showsOriginal)
            Text("阅读为我们打开一扇通向世界的窗。")
                .opacity(showsOriginal ? 0 : 1)
                .accessibilityHidden(showsOriginal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { showsOriginal = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: showsOriginal)
    }
}

/// 设置中的紧凑分段选择器，统一模式、配色和更新通道的比例。
private struct SettingsCompactSwitcher<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let accent: Color
    let title: (Option) -> String
    var accessory: ((Option) -> AnyView)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedText: Color {
        TranslationPreferences.contrastRatio(accent.readerHexString, "#FFFFFF") >= 4.5
            ? .white : Color(paperHex: "#18181B")
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                HStack(spacing: 0) {
                    Button { selection = option } label: {
                        Text(title(option))
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.system(size: 12, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? selectedText : Color.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if let accessory { accessory(option) }
                }
                .background(selected ? accent : Color.clear, in: Capsule())
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
    }
}

/// 使用原生最简色井，在自定义分段内部呈现圆形选色入口。
private struct TranslationColorWell: View {
    @Binding var color: Color

    var body: some View {
        #if os(macOS)
        NativeWell(color: $color)
            // 保留原生选色交互，用纯色圆覆盖原生悬浮标记。
            .overlay { Circle().fill(color).allowsHitTesting(false) }
        #else
        ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
        #endif
    }

    #if os(macOS)
    private struct NativeWell: NSViewRepresentable {
        @Binding var color: Color
        @Environment(\.isEnabled) private var isEnabled

        func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

        func makeNSView(context: Context) -> NSColorWell {
            let well = NSColorWell()
            well.colorWellStyle = .minimal
            well.isBordered = false
            well.target = context.coordinator
            well.action = #selector(Coordinator.changed(_:))
            well.color = NSColor(color)
            well.isEnabled = isEnabled
            return well
        }

        func updateNSView(_ well: NSColorWell, context: Context) {
            context.coordinator.color = $color
            well.isEnabled = isEnabled
            if !isEnabled, well.isActive { well.deactivate() }
            let next = NSColor(color)
            if well.color != next { well.color = next }
        }

        @MainActor
        final class Coordinator: NSObject {
            var color: Binding<Color>
            init(color: Binding<Color>) { self.color = color }
            @objc func changed(_ sender: NSColorWell) {
                color.wrappedValue = Color(nsColor: sender.color)
            }
        }
    }
    #endif
}

/// 设置输入框与阅读主题共用底色，聚焦时以主题色描边。
@MainActor
private struct SettingsInputStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .modifier(SettingsInputSurface())
    }
}

private struct SettingsInputSurface: ViewModifier {
    @Environment(\.paperAppearancePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color(paperHex: palette.inkHex))
            .focused($isFocused)
            .background(Color(paperHex: palette.backgroundHex), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isFocused ? Color(paperHex: palette.accentHex)
                            : Color(paperHex: palette.inkHex).opacity(contrast == .increased ? 0.5 : 0.18),
                        lineWidth: isFocused ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
    }
}
