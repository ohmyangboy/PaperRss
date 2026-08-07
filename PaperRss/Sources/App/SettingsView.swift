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
    case aiService
    case refresh
    case language
    case sync
    case about

    var id: Self { self }

    @MainActor
    var title: String {
        switch self {
        case .appearance: I18N.shared.tr("外观", "Appearance")
        case .aiService: I18N.shared.tr("AI 功能", "AI Features")
        case .refresh: I18N.shared.tr("刷新", "Refresh")
        case .language: I18N.shared.tr("语言", "Language")
        case .sync: I18N.shared.tr("同步", "Sync")
        case .about: I18N.shared.tr("关于", "About")
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintpalette"
        case .aiService: "sparkles"
        case .refresh: "arrow.clockwise.circle"
        case .language: "globe"
        case .sync: "icloud"
        case .about: "info.circle"
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .appearance: I18N.shared.tr("控制界面颜色主题与文章阅读字号", "Control interface color theme and reading font size")
        case .aiService: I18N.shared.tr("配置模型服务、阅读助手与生成偏好", "Configure model service, reading assistant, and preferences")
        case .refresh: I18N.shared.tr("控制订阅的自动更新", "Control automatic feed updates")
        case .language: I18N.shared.tr("切换应用界面语言", "Switch application display language")
        case .sync: I18N.shared.tr("同步阅读状态和 AI 结果", "Synchronize reading state and AI results")
        case .about: I18N.shared.tr("版本信息、GitHub 仓库与软件更新", "Version info, GitHub repository, and update checks")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selectedSection: SettingsSection = .appearance
    @State private var configuration = LLMConfiguration.default
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var usesCustomModel = false
    @State private var status = ""
    @State private var isTesting = false

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

                        Divider().opacity(0.5)
                        actionBar
                    }
                }
            } else {
                VStack(spacing: 0) {
                    Picker("设置类别", selection: $selectedSection) {
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

            Text(I18N.shared.tr("设置", "Settings"))
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
                    Text("NEW")
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
                Text("Paper RSS")
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
            case .about:
                aboutSettings
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                I18N.shared.tr("颜色主题", "Color Theme"),
                footer: I18N.shared.tr("选择浅色、深色或自动跟随系统的外观风格。", "Choose Light, Dark, or automatically follow system appearance.")
            ) {
                settingsRow(I18N.shared.tr("外观模式", "Theme Mode")) {
                    Picker(
                        I18N.shared.tr("外观模式", "Theme Mode"),
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
                I18N.shared.tr("正文字号", "Article Font Size"),
                footer: I18N.shared.tr("调整文章阅读器中的正文字体大小，支持预设与微调。", "Adjust body font size in article reader with presets and fine tuning.")
            ) {
                settingsRow(
                    I18N.shared.tr("预设字号", "Preset Sizes")
                ) {
                    HStack(spacing: 8) {
                        Button("小 (14pt)") { store.setArticleFontSize(14) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 14 ? Color.accentColor : .primary)

                        Button("标准 (17pt)") { store.setArticleFontSize(17) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 17 ? Color.accentColor : .primary)

                        Button("大 (20pt)") { store.setArticleFontSize(20) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 20 ? Color.accentColor : .primary)

                        Button("特大 (23pt)") { store.setArticleFontSize(23) }
                            .buttonStyle(.bordered)
                            .tint(store.articleFontSize == 23 ? Color.accentColor : .primary)
                    }
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow(
                    I18N.shared.tr("精确调节", "Fine Tuning"),
                    description: I18N.shared.tr("范围：13pt ~ 25pt", "Range: 13pt ~ 25pt")
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
                I18N.shared.tr("实时预览", "Live Preview")
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The Morning Digest · 晨间速览")
                        .font(.system(size: CGFloat(store.articleFontSize) * 1.2, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)

                    Text("Paper RSS 专为沉浸式阅读打造。在保持传统报纸排版美感的同时，为您提供最舒适的阅读体验。调整字号可实时同步至所有文章阅读页面。")
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
                I18N.shared.tr("界面语言", "Display Language"),
                footer: I18N.shared.tr("默认跟随系统设置或简体中文，可以自由切换为英文。", "Default uses Simplified Chinese or System, switchable to English.")
            ) {
                settingsRow(I18N.shared.tr("语言选择", "Select Language")) {
                    Picker(I18N.shared.tr("语言选择", "Select Language"), selection: $store.appLanguage) {
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
                        Text("DeepSeek 推荐配置")
                            .font(.body.weight(.medium))
                        Text("官方 OpenAI 兼容地址与 Flash 模型")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Button("使用推荐配置") { useDeepSeekDefaults() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("名称", description: "用于识别这组 AI 配置") {
                    TextField("例如：DeepSeek", text: $configuration.providerName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("描述") {
                    TextField("例如：个人阅读助手", text: $configuration.providerDescription)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if showsAPIKey {
                                TextField("局域网模型可留空", text: $apiKey)
                            } else {
                                SecureField("局域网模型可留空", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showsAPIKey.toggle()
                        } label: {
                            Image(systemName: showsAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsAPIKey ? "隐藏密钥" : "显示密钥")
                    }
                    .frame(maxWidth: 360)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("Base URL") {
                    TextField("https://api.deepseek.com", text: $configuration.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("模型") {
                    if configuration.usesDeepSeekAPI && !usesCustomModel {
                        Picker("模型", selection: $configuration.model) {
                            Text("deepseek-v4-flash（推荐）").tag("deepseek-v4-flash")
                            Text("deepseek-v4-pro").tag("deepseek-v4-pro")
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
                        Toggle("输入自定义模型名称", isOn: $usesCustomModel)
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
                    Toggle("展示 AI 摘要模块", isOn: $configuration.showsAISummary)
                        .labelsHidden()
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow(
                    "打开文章时自动生成 AI 摘要",
                    description: "开启后，打开没有缓存摘要的文章会自动发送正文到模型。"
                ) {
                    Toggle("自动生成摘要", isOn: $configuration.automaticallyGenerateSummary)
                        .labelsHidden()
                }
            }

            settingsGroup(
                "阅读助手：翻译与划词",
                footer: "逐段翻译只处理当前屏幕视口内容；划词解释需手动触发。"
            ) {
                settingsRow("翻译目标语言") {
                    TextField("简体中文", text: $configuration.targetLanguage)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }

                Divider().padding(.horizontal, 18).opacity(0.35)

                settingsRow("划词解释触发") {
                    Text("选中文字后手动触发")
                        .foregroundStyle(.secondary)
                        .frame(width: 180, alignment: .trailing)
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
                    Picker("推理偏好", selection: $configuration.reasoningMode) {
                        Text("自动").tag("自动")
                        Text("关闭").tag("关闭")
                        Text("低").tag("低")
                        Text("中").tag("中")
                        Text("高").tag("高")
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
                    Toggle("允许局域网 HTTP", isOn: $configuration.allowInsecureLocalEndpoint)
                        .labelsHidden()
                }
            }
        }
    }

    private var syncSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                "iCloud",
                footer: "API Key、网页正文、网页缓存、HTTP 缓存和调试日志不会同步。"
            ) {
                settingsRow("同步内容", description: "订阅、已读、收藏和 AI 结果") {
                    Toggle("同步订阅、已读、收藏和 AI 结果", isOn: Binding(
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
                    Button("立即同步") {
                        Task { await store.syncICloud() }
                    }
                    .disabled(!store.isICloudSyncEnabled)
                }
            }

            settingsGroup("隐私") {
                settingsRow("API Key") {
                    Text("仅存于本机，不参与同步")
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

                VStack(spacing: 4) {
                    Text("Paper RSS")
                        .font(.system(size: 22, weight: .bold))

                    Text("Version \(UpdateCheckService.currentVersion) (Build \(UpdateCheckService.currentBuild))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("专为沉浸式阅读打造的现代 RSS 订阅与 AI 强力阅读助手。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                I18N.shared.tr("开源社区", "Open Source"),
                footer: I18N.shared.tr("欢迎在 GitHub 上提出 Issue、提交 Feedback 或 Star 本项目。", "Welcome to file issues, give feedback, or star this project on GitHub.")
            ) {
                settingsRow(
                    I18N.shared.tr("GitHub 官方仓库", "GitHub Repository"),
                    description: "https://github.com/ohmyangboy/PaperRss"
                ) {
                    Button {
                        UpdateCheckService.openURL(UpdateCheckService.githubRepositoryURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text(I18N.shared.tr("前往 GitHub", "Open GitHub"))
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            settingsGroup(
                I18N.shared.tr("软件更新", "Software Update"),
                footer: I18N.shared.tr("应用启动时会自动在后台检查 Release 更新；您也可以随时点击右侧按钮手动检查。", "App automatically checks for release updates on launch; you can also manually check anytime.")
            ) {
                settingsRow(
                    I18N.shared.tr("当前版本状态", "Current Version Status"),
                    description: updateStatusDescription
                ) {
                    if store.updateStatus.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else if case let .hasUpdate(release, _) = store.updateStatus {
                        Button {
                            UpdateCheckService.openURL(release.htmlURL)
                        } label: {
                            Label(I18N.shared.tr("下载新版本", "Download New Release"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task {
                                await store.checkForUpdates(isUserInitiated: true)
                            }
                        } label: {
                            Text(I18N.shared.tr("检查更新", "Check for Updates"))
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if case let .hasUpdate(release, _) = store.updateStatus, let body = release.body, !body.isEmpty {
                    Divider().padding(.horizontal, 18).opacity(0.35)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("新版本更新说明 (\(release.tagName))")
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
            return I18N.shared.tr("尚未检查", "Not checked yet")
        case .checking:
            return I18N.shared.tr("正在连接 GitHub 检查 Release 更新…", "Checking GitHub for updates...")
        case let .upToDate(checkedAt):
            let timeString = DateFormatter.localizedString(from: checkedAt, dateStyle: .none, timeStyle: .short)
            return I18N.shared.tr("已是最新版本 (上次检查: \(timeString))", "Up to date (Last checked: \(timeString))")
        case let .hasUpdate(release, _):
            return I18N.shared.tr("发现新版本: \(release.tagName)", "New version available: \(release.tagName)")
        case let .failed(message):
            return I18N.shared.tr("检查更新失败: \(message)", "Check failed: \(message)")
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
                    ? "每次打开或回到前台时，Paper RSS 会立即检查所有订阅。"
                    : "已关闭启动刷新；你仍可以使用底部的刷新按钮手动获取最新消息。"
            ) {
                settingsRow("打开应用时自动刷新") {
                    Toggle("打开应用时自动刷新", isOn: Binding(
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
                        Label("立即刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }
            }
        }
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

            content()

            if let footer, !footer.isEmpty {
                Text(footer)
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
                Text(title)
                    .font(.body)

                if let description, !description.isEmpty {
                    Text(description)
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
                Button(isTesting ? "正在测试…" : "测试连接") { test() }
                    .disabled(isTesting)
            }

            if selectedSection == .aiService {
                Button("保存设置") { save() }
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
    }

    private func loadConfiguration() {
        selectedSection = .appearance
        configuration = store.database.llmConfiguration
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
        configuration = .deepSeek
        configuration.automaticallyGenerateSummary = automaticallyGenerateSummary
        apiKey = currentKey
        usesCustomModel = false
        status = "已填入 DeepSeek 推荐配置；保存后即可测试。"
    }

    private func test() {
        save()
        isTesting = true
        status = ""
        Task {
            do {
                try await store.testLLM(configuration: configuration, apiKey: apiKey)
                status = "成功：接口可以响应。"
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
            Text("正在刷新订阅…")
        case let .completed(updatedFeeds, finishedAt):
            HStack(spacing: 4) {
                Text(updatedFeeds > 0 ? "已检查 \(updatedFeeds) 个订阅" : "已检查，没有新消息")
                Text("·")
                Text(finishedAt, style: .time)
            }
        case let .failed(message, _):
            Text("刷新遇到问题：\(message)")
        case .idle:
            Text("尚未刷新")
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
        case .refreshing: "正在请求订阅源最新内容"
        case .completed: "订阅刷新完成"
        case .failed: "部分订阅刷新失败"
        case .idle: "还没有进行刷新"
        }
    }
}
