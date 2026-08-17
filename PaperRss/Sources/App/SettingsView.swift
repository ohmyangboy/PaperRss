import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if SWIFT_PACKAGE
import PaperRssCore
#endif

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case accounts
    case aiService
    case refresh
    case language
    case sync
    case feedback
    case about

    var id: Self { self }

    @MainActor
    var title: String {
        switch self {
        case .appearance: I18N.shared.localized("外观", "Appearance")
        case .accounts: I18N.shared.localized("账号", "Accounts")
        case .aiService: I18N.shared.localized("AI 功能", "AI Features")
        case .refresh: I18N.shared.localized("刷新", "Refresh")
        case .language: I18N.shared.localized("语言", "Language")
        case .sync: I18N.shared.localized("同步", "Sync")
        case .feedback: I18N.shared.localized("反馈与赞赏", "Feedback & Sponsor")
        case .about: I18N.shared.localized("关于", "About")
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintpalette"
        case .accounts: "person.crop.circle"
        case .aiService: "sparkles"
        case .refresh: "arrow.clockwise.circle"
        case .language: "globe"
        case .sync: "icloud"
        case .feedback: "heart.circle"
        case .about: "info.circle"
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .appearance: I18N.shared.localized("控制界面颜色主题与文章阅读字号")
        case .accounts: I18N.shared.localized("管理本地与 FreshRSS 订阅账号及双向状态同步")
        case .aiService: I18N.shared.localized("配置模型服务、阅读助手与生成偏好")
        case .refresh: I18N.shared.localized("控制订阅的自动更新")
        case .language: I18N.shared.localized("切换应用界面语言")
        case .sync: I18N.shared.localized("同步阅读状态和 AI 结果")
        case .feedback: I18N.shared.localized("赞赏支持开发者、提交问题反馈与交流")
        case .about: I18N.shared.localized("版本信息、GitHub 仓库与软件更新")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    #if os(macOS)
    @ObservedObject var attention: MacSystemAttentionController
    #endif
    @State private var selectedSection: SettingsSection = SettingsSection.allCases.first ?? .appearance
    @State private var configuration = LLMConfiguration.default
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var usesCustomModel = false
    @State private var status = ""
    @State private var isTesting = false
    @State private var showingTargetLanguagePopover = false

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

    var body: some View {
        Group {
            #if os(macOS)
            macOSBody
            #else
            iOSBody
            #endif
        }
        .preferredColorScheme(store.appTheme.colorScheme)
        .onChange(of: configuration) {
            save(updateStatus: false)
        }
        .onChange(of: apiKey) {
            save(updateStatus: false)
        }
    }

    #if os(macOS)
    private var macOSBody: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: 210)

            Divider().opacity(0.5)

            VStack(spacing: 0) {
                contentHeader

                ScrollView {
                    settingsPage
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                }
                .scrollContentBackground(.hidden)

                Divider().opacity(0.5)
                actionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(settingsWindowBackground)
        .frame(minWidth: 840, idealWidth: 920, minHeight: 580, idealHeight: 660)
        .onAppear(perform: loadConfiguration)
    }
    #else
    private var iOSBody: some View {
        GeometryReader { geometry in
            if geometry.size.width > 520 {
                HStack(spacing: 0) {
                    sidebarView
                        .frame(width: 200)

                    Divider().opacity(0.5)

                    VStack(spacing: 0) {
                        contentHeader

                        ScrollView {
                            settingsPage
                                .padding(.horizontal, 24)
                                .padding(.vertical, 20)
                        }
                        .paperListScrollStyle()

                        Divider().opacity(0.5)
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

                    contentHeader

                    ScrollView {
                        settingsPage
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                    }
                    .paperListScrollStyle()

                    Divider()
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
            sidebarHeader

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
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.accentColor)

            Text(I18N.shared.localized("设置", "Settings"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func sidebarItem(for section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedSection = section
                status = ""
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))

                Spacer(minLength: 0)

                if section == .about && store.updateStatus.hasNewVersion {
                    Text(I18N.localized("NEW"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.4)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(I18N.localized("PaperRss"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedSection.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)

            Text(selectedSection.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    @ViewBuilder
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch selectedSection {
            case .accounts:
                accountsSettings
            case .appearance:
                appearanceSettings
            case .aiService:
                aiServiceSettings
            case .refresh:
                refreshSettings
            case .language:
                languageSettings
            case .sync:
                syncSettings
            case .feedback:
                feedbackSettings
            case .about:
                aboutSettings
            }
        }
    }

    private var accountsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                I18N.shared.localized("当前账号", "Current Accounts"),
                footer: I18N.shared.localized("PaperRss 支持多账号并行。本地订阅与 FreshRSS 远端订阅相互隔离，各账号独立管理与同步。")
            ) {
                // 本地账号
                HStack(spacing: 12) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 20))
                        .foregroundStyle(PaperTheme.accent)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(I18N.shared.localized("我的 Mac (本地账号)"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(I18N.shared.localized("本机独立存储与离线阅读"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(I18N.shared.localized("默认"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // FreshRSS 账号列表
                let freshRSSAccounts = store.accounts.filter { $0.type == AccountType.freshRSS.rawValue }
                ForEach(freshRSSAccounts, id: \.id) { account in
                    Divider().padding(.horizontal, 18).opacity(0.35)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 20))
                                .foregroundStyle(PaperTheme.accent)
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

                            Button(I18N.shared.localized("立即同步")) {
                                Task {
                                    await store.syncAccount(accountID: account.id)
                                }
                            }
                            .controlSize(.small)

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

                        // 同步状态展示
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
                            .padding(.leading, 40)
                        }
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
                I18N.shared.localized("赞赏与支持"),
                footer: I18N.shared.localized(
                    store.appLanguage.resolvedLocalization() == .en
                        ? "如果 PaperRss 改善了你的阅读体验，可以通过 PayPal 支持持续开发。"
                        : "如果 PaperRss 改善了你的阅读体验，欢迎使用微信扫码赞赏支持持续开发。"
                )
            ) {
                if store.appLanguage.resolvedLocalization() == .en {
                    HStack(spacing: 20) {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(PaperTheme.accent)

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
                                UpdateCheckService.openURL(url)
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
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
            }

            settingsGroup(
                I18N.shared.localized("问题反馈与建议", "Feedback & Issues"),
                footer: I18N.shared.localized("遇到了 Bug 或有新的功能想法？欢迎随时提交 GitHub Issue 或联系开发者。")
            ) {
                settingsRow(
                    I18N.shared.localized("提交 GitHub Issue", "Submit GitHub Issue"),
                    description: I18N.shared.localized("直接前往 GitHub 仓库提交反馈或功能建议")
                ) {
                    Button {
                        if let url = URL(string: "https://github.com/ohmyangboy/PaperRss/issues") {
                            UpdateCheckService.openURL(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text(I18N.shared.localized("新建 Issue", "New Issue"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow(
                    I18N.shared.localized("开发者社区", "Developer Community"),
                    description: "GitHub @ohmyangboy"
                ) {
                    Button {
                        if let url = URL(string: "https://github.com/ohmyangboy") {
                            UpdateCheckService.openURL(url)
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
            settingsGroup(
                I18N.shared.localized("颜色主题"),
                footer: I18N.shared.localized("选择浅色、深色或自动跟随系统的外观风格。", "Choose Light, Dark, or automatically follow system appearance.")
            ) {
                settingsRow(I18N.shared.localized("外观模式", "Theme Mode")) {
                    Picker(
                        I18N.shared.localized("外观模式", "Theme Mode"),
                        selection: Binding(
                            get: { store.appTheme },
                            set: { store.setAppTheme($0) }
                        )
                    ) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
            }

            settingsGroup(
                I18N.shared.localized("正文字号", "Article Font Size"),
                footer: I18N.shared.localized("调整文章阅读器中的正文字体大小，支持预设与微调。")
            ) {
                settingsRow(
                    I18N.shared.localized("预设字号", "Preset Sizes")
                ) {
                    HStack(spacing: 8) {
                        Button(I18N.localized("小 (14pt)")) { store.setArticleFontSize(14) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 14 ? Color.accentColor : .primary)

                        Button(I18N.localized("标准 (17pt)")) { store.setArticleFontSize(17) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 17 ? Color.accentColor : .primary)

                        Button(I18N.localized("大 (20pt)")) { store.setArticleFontSize(20) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 20 ? Color.accentColor : .primary)

                        Button(I18N.localized("特大 (23pt)")) { store.setArticleFontSize(23) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 23 ? Color.accentColor : .primary)
                    }
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow(
                    I18N.shared.localized("精确调节", "Fine Tuning"),
                    description: I18N.shared.localized("范围：13pt ~ 25pt", "Range: 13pt ~ 25pt")
                ) {
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(store.articleFontSize) },
                                set: { store.setArticleFontSize(Int($0)) }
                            ),
                            in: 13...25,
                            step: 1
                        )
                        .frame(width: 200)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)

                        Text("\(store.articleFontSize) pt")
                            .font(.body.monospacedDigit().bold())
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }

            settingsGroup(
                I18N.shared.localized("实时预览", "Live Preview")
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(I18N.localized("The Morning Digest · 晨间速览"))
                        .font(.system(size: CGFloat(store.articleFontSize) * 1.2, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)

                    Text(I18N.localized("PaperRss 专为沉浸式阅读打造。在保持纸张排版美感的同时，提供舒适的长文阅读体验。字号调整会同步到所有文章。"))
                        .font(.system(size: CGFloat(store.articleFontSize), weight: .regular))
                        .lineSpacing(6)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                I18N.shared.localized("界面语言", "Display Language"),
                footer: I18N.shared.localized("默认跟随系统设置；也可以随时在这里切换，应用界面会立即更新。")
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

    private var aiServiceSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                "服务商与连接",
                footer: "API Key 只保存在这台设备，不会参与 iCloud 同步。"
            ) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(I18N.localized("DeepSeek 推荐配置"))
                            .font(.body.weight(.medium))
                        Text(I18N.localized("官方 OpenAI 兼容地址与 Flash 模型"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Button(I18N.localized("使用推荐配置")) { useDeepSeekDefaults() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("名称", description: "用于识别这组 AI 配置") {
                    TextField(I18N.localized("例如：DeepSeek"), text: $configuration.providerName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("描述") {
                    TextField(I18N.localized("例如：个人阅读助手"), text: $configuration.providerDescription)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if showsAPIKey {
                                TextField(I18N.localized("局域网模型可留空"), text: $apiKey)
                            } else {
                                SecureField(I18N.localized("局域网模型可留空"), text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showsAPIKey.toggle()
                        } label: {
                            Image(systemName: showsAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(I18N.shared.localized(showsAPIKey ? "隐藏密钥" : "显示密钥"))
                    }
                    .frame(maxWidth: 360)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("Base URL") {
                    TextField(I18N.localized("https://api.deepseek.com"), text: $configuration.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("模型") {
                    if configuration.usesDeepSeekAPI && !usesCustomModel {
                        Picker(I18N.localized("模型"), selection: $configuration.model) {
                            Text(I18N.localized("deepseek-v4-flash（推荐）")).tag("deepseek-v4-flash")
                            Text(I18N.localized("deepseek-v4-pro")).tag("deepseek-v4-pro")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300, alignment: .trailing)
                    } else {
                        TextField(
                            configuration.usesDeepSeekAPI ? "deepseek-v4-flash" : "例如：gpt-4o-mini",
                            text: $configuration.model
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                    }
                }

                if configuration.usesDeepSeekAPI {
                    Divider().padding(.horizontal, 18).opacity(0.35)

                    settingsRow("自定义模型") {
                        Toggle(I18N.localized("输入自定义模型名称"), isOn: $usesCustomModel)
                            .labelsHidden()
                    }
                }
            }

            settingsGroup(
                "阅读助手：摘要",
                footer: configuration.automaticallyGenerateSummary
                    ? "首次打开尚无摘要的文章时自动生成；已有缓存不会重复请求。"
                    : "保持手动模式，只在你点击“生成摘要”后请求模型。"
            ) {
                settingsRow(
                    "展示 AI 摘要模块",
                    description: "关闭后，文章阅读页不显示摘要模块；已生成的摘要不会被删除。"
                ) {
                    Toggle(I18N.localized("展示 AI 摘要模块"), isOn: $configuration.showsAISummary)
                        .labelsHidden()
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow(
                    "打开文章时自动生成 AI 摘要",
                    description: "开启后，打开没有缓存摘要的文章会自动发送正文到模型。"
                ) {
                    Toggle(I18N.localized("自动生成摘要"), isOn: $configuration.automaticallyGenerateSummary)
                        .labelsHidden()
                }
            }

            settingsGroup(
                "阅读助手：翻译与划词",
                footer: "逐段翻译只处理当前屏幕视口内容；划词功能触发后以浮窗形式呈现。"
            ) {
                settingsRow("翻译目标语言") {
                    HStack(spacing: 8) {
                        Button {
                            showingTargetLanguagePopover.toggle()
                        } label: {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(PaperTheme.accent)
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            showingTargetLanguagePopover = isHovered
                        }
                        .popover(isPresented: $showingTargetLanguagePopover, arrowEdge: .trailing) {
                            Text(I18N.localized("你可以自由填入你想翻译成的语言，例如中文、英语、法语等。"))
                                .font(.subheadline)
                                .padding(12)
                                .frame(width: 220)
                        }

                        TextField(I18N.localized("简体中文"), text: $configuration.targetLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("划词解释按钮", description: "开启后，划词选择文本时展示“直接解释”按钮") {
                    Toggle(I18N.localized("划词解释按钮"), isOn: $configuration.showsSelectionExplanation)
                        .labelsHidden()
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("划词提问按钮", description: "开启后，划词选择文本时展示“向 AI 提问”按钮") {
                    Toggle(I18N.localized("划词提问按钮"), isOn: $configuration.showsSelectionAsk)
                        .labelsHidden()
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("划词翻译按钮", description: "开启后，划词选择文本时展示“翻译”按钮") {
                    Toggle(I18N.localized("划词翻译按钮"), isOn: $configuration.showsSelectionTranslation)
                        .labelsHidden()
                }
            }

            settingsGroup(
                "个性化 Prompt",
                footer: "自定义指令会附加在系统默认 Prompt 之后（例如：“请用通俗易懂的口语解释”或“侧重分析工程实现细节”）。"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $configuration.customPrompt)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 120)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            settingsGroup(
                "生成偏好（高级）",
                footer: reasoningFooter
            ) {
                settingsRow(
                    "推理偏好",
                    description: "仅在服务商明确支持时生效；翻译和划词解释会自动关闭推理。"
                ) {
                    Picker(I18N.localized("推理偏好"), selection: $configuration.reasoningMode) {
                        Text(I18N.localized("自动")).tag("自动")
                        Text(I18N.localized("关闭")).tag("关闭")
                        Text(I18N.localized("低")).tag("低")
                        Text(I18N.localized("中")).tag("中")
                        Text(I18N.localized("高")).tag("高")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150, alignment: .trailing)
                }
            }

            settingsGroup(
                "连接安全（高级）",
                footer: "仅用于模型 Base URL。HTTP 未加密，只有在你信任局域网环境时才建议开启。"
            ) {
                settingsRow("允许局域网 HTTP（不安全）") {
                    Toggle(I18N.localized("允许局域网 HTTP"), isOn: $configuration.allowInsecureLocalEndpoint)
                        .labelsHidden()
                }
            }
        }
    }

    private var syncSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(I18N.shared.localized("同步功能暂未上线", "Sync is not available yet"))
                        .font(.body.weight(.semibold))

                    Text(I18N.shared.localized(
                        "我们正在完善 iCloud 同步功能，正式上线前请继续使用本机数据。",
                        "We are still working on iCloud sync. Please continue using local data until it is released."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.orange.opacity(0.28), lineWidth: 0.8)
            }
            .accessibilityElement(children: .combine)

            settingsGroup(
                "iCloud",
                footer: "API Key、网页正文、网页缓存、HTTP 缓存和调试日志不会同步。"
            ) {
                settingsRow("同步内容", description: "订阅、已读、收藏和 AI 结果") {
                    Toggle(I18N.localized("同步订阅、已读、收藏和 AI 结果"), isOn: Binding(
                        get: { store.isICloudSyncEnabled },
                        set: { store.setICloudSyncEnabled($0) }
                    ))
                    .labelsHidden()
                    // 无 CloudKit entitlement 的构建（ad-hoc 签名、纯 SPM
                    // 产物）调用 CloudKit 会抛无法捕获的 Objective-C 异常
                    // 并终止应用，因此在没有权限时直接禁用入口。
                    .disabled(!CloudSyncService.isICloudEntitled)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("状态") {
                    Text(store.iCloudSyncStatus)
                        .foregroundStyle(.secondary)
                        .frame(width: 240, alignment: .trailing)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("操作") {
                    Button(I18N.localized("立即同步")) {
                        Task { await store.syncICloud() }
                    }
                    .disabled(!store.isICloudSyncEnabled)
                }
            }

            settingsGroup("隐私") {
                settingsRow("API Key") {
                    Text(I18N.localized("仅存于本机，不参与同步"))
                        .foregroundStyle(.secondary)
                        .frame(width: 240, alignment: .trailing)
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 12) {
                appIconView

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(I18N.localized("PaperRss"))
                            .font(.system(size: 22, weight: .bold))
                        Text(I18N.localized("Beta"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PaperTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PaperTheme.accent.opacity(0.12), in: Capsule())
                    }

                    Text("Version \(UpdateCheckService.currentVersion) (Build \(UpdateCheckService.currentBuild))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(I18N.localized("专为沉浸式阅读打造的现代 RSS 订阅与 AI 阅读助手。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Text(I18N.localized("当前为个人 Beta 版本，感谢您的使用和反馈。"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PaperTheme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            }

            settingsGroup(
                I18N.shared.localized("开源社区", "Open Source"),
                footer: I18N.shared.localized("欢迎在 GitHub 上提出 Issue、提交 Feedback 或 Star 本项目。")
            ) {
                settingsRow(
                    I18N.shared.localized("GitHub 官方仓库", "GitHub Repository"),
                    description: "https://github.com/ohmyangboy/PaperRss"
                ) {
                    Button {
                        UpdateCheckService.openURL(UpdateCheckService.githubRepositoryURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text(I18N.shared.localized("前往 GitHub", "Open GitHub"))
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            settingsGroup(
                I18N.shared.localized("软件更新", "Software Update"),
                footer: I18N.shared.localized("应用启动时会自动在后台检查 Release 更新；您也可以随时点击右侧按钮手动检查。")
            ) {
                settingsRow(
                    I18N.shared.localized("当前版本状态", "Current Version Status"),
                    description: updateStatusDescription
                ) {
                    if store.updateStatus.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else if case let .hasUpdate(release, _) = store.updateStatus {
                        Button {
                            UpdateCheckService.openURL(release.htmlURL)
                        } label: {
                            Label(I18N.shared.localized("下载新版本", "Download New Release"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task {
                                await store.checkForUpdates(isUserInitiated: true)
                            }
                        } label: {
                            Text(I18N.shared.localized("检查更新", "Check for Updates"))
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if case let .hasUpdate(release, _) = store.updateStatus, let body = release.body, !body.isEmpty {
                    Divider().padding(.horizontal, 18).opacity(0.35)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(I18N.shared.localizedFormat("新版本更新说明 (%@)", release.tagName))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(body)
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
        }
    }

    private var updateStatusDescription: String {
        switch store.updateStatus {
        case .idle:
            return I18N.shared.localized("尚未检查", "Not checked yet")
        case .checking:
            return I18N.shared.localized("正在连接 GitHub 检查 Release 更新…", "Checking GitHub for updates...")
        case let .upToDate(checkedAt):
            let timeString = DateFormatter.localizedString(from: checkedAt, dateStyle: .none, timeStyle: .short)
            return I18N.shared.localizedFormat("已是最新版本（上次检查：%@）", timeString)
        case let .hasUpdate(release, _):
            return I18N.shared.localizedFormat("发现新版本：%@", release.tagName)
        case let .failed(message):
            return I18N.shared.localizedFormat("检查更新失败：%@", message)
        }
    }

    @ViewBuilder
    private var appIconView: some View {
        #if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
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

    private var refreshSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                "启动",
                footer: store.refreshOnLaunch
                    ? "每次打开或回到前台时，PaperRss 会立即检查所有订阅。"
                    : "已关闭启动刷新；你仍可以使用底部的刷新按钮手动获取最新消息。"
            ) {
                settingsRow("打开应用时自动刷新") {
                    Toggle(I18N.localized("打开应用时自动刷新"), isOn: Binding(
                        get: { store.refreshOnLaunch },
                        set: { store.setRefreshOnLaunch($0) }
                    ))
                    .labelsHidden()
                }
            }

            settingsGroup("运行期间", footer: store.refreshInterval.detail) {
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
            }

            settingsGroup("状态") {
                settingsRow("当前状态") {
                    RefreshStatusView(store: store)
                        .frame(width: 240, alignment: .trailing)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("操作") {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label(I18N.localized("立即刷新"), systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
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
            I18N.shared.localized("提醒", "Alerts"),
            footer: I18N.shared.localized(
                "Dock 徽标显示全部未读文章。",
                "The Dock badge shows all unread articles."
            )
        ) {
            settingsRow(
                I18N.shared.localized("Dock 未读徽标", "Dock unread badge"),
                description: I18N.shared.localized("立即显示当前未读数，超过 99 显示 99+。")
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
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

            content()

            if let footer, !footer.isEmpty {
                Text(LocalizedStringKey(footer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
            } else {
                Spacer(minLength: 12)
            }
        }
        .background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
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
                    .font(.body)

                if let description, !description.isEmpty {
                    Text(LocalizedStringKey(description))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
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

            if selectedSection == .aiService {
                Button(I18N.shared.localized(isTesting ? "正在测试…" : "测试连接")) { test() }
                    .disabled(isTesting)
            }

            if selectedSection == .aiService {
                Button(I18N.localized("保存设置")) { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var settingsSidebarBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var settingsWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    private var settingsGroupBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    private var reasoningFooter: String {
        configuration.usesDeepSeekAPI
            ? "DeepSeek 会按此选项发送 thinking；选择低、中、高时也会发送对应的 reasoning_effort。"
            : "其他 OpenAI 兼容接口只在明确支持时使用对应推理参数。"
    }

    private var statusIsSuccess: Bool {
        status.hasPrefix("成功") || status.hasPrefix("已保存") || status.hasPrefix("已填入")
            || status.hasPrefix("Success") || status.hasPrefix("Saved") || status.hasPrefix("Recommended")
    }

    private func loadConfiguration() {
        selectedSection = .appearance
        configuration = store.llmConfiguration
        apiKey = store.loadAPIKey()
        usesCustomModel = !["deepseek-v4-flash", "deepseek-v4-pro"].contains(configuration.model)
    }

    private func save(updateStatus: Bool = true) {
        let storage = store.saveLLMConfiguration(configuration, apiKey: apiKey)
        if updateStatus {
            status = storage.savedMessage
        }
    }

    private func useDeepSeekDefaults() {
        let currentKey = apiKey
        let automaticallyGenerateSummary = configuration.automaticallyGenerateSummary
        let showsSelectionExplanation = configuration.showsSelectionExplanation
        let showsSelectionAsk = configuration.showsSelectionAsk
        let showsSelectionTranslation = configuration.showsSelectionTranslation
        configuration = .deepSeek
        configuration.automaticallyGenerateSummary = automaticallyGenerateSummary
        configuration.showsSelectionExplanation = showsSelectionExplanation
        configuration.showsSelectionAsk = showsSelectionAsk
        configuration.showsSelectionTranslation = showsSelectionTranslation
        apiKey = currentKey
        usesCustomModel = false
        status = I18N.shared.localized("已填入 DeepSeek 推荐配置；保存后即可测试。")
    }

    private func test() {
        save()
        isTesting = true
        status = ""
        Task {
            do {
                try await store.testLLM(configuration: configuration, apiKey: apiKey)
                status = I18N.shared.localized("成功：接口可以响应。")
            } catch {
                status = error.localizedDescription
            }
            isTesting = false
        }
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
                            .foregroundStyle(PaperTheme.accent)
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
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text(I18N.shared.localized("用户名"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        TextField(I18N.shared.localized("FreshRSS 用户名"), text: $freshRSSUsername)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text(I18N.shared.localized("API 密码"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        SecureField(I18N.shared.localized("用户配置中生成的 API 密码"), text: $freshRSSPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text(I18N.shared.localized("显示名称"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        TextField(I18N.shared.localized("可选（默认服务器域名）"), text: $freshRSSDisplayName)
                            .textFieldStyle(.roundedBorder)
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
