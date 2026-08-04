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
    case aiService
    case assistant
    case refresh
    case language
    case sync

    var id: Self { self }

    @MainActor
    var title: String {
        switch self {
        case .aiService: I18N.shared.tr("AI 服务", "AI Service")
        case .assistant: I18N.shared.tr("阅读助手", "Reading Assistant")
        case .refresh: I18N.shared.tr("刷新", "Refresh")
        case .language: I18N.shared.tr("语言", "Language")
        case .sync: I18N.shared.tr("同步", "Sync")
        }
    }

    var icon: String {
        switch self {
        case .aiService: "sparkles"
        case .assistant: "text.book.closed"
        case .refresh: "arrow.clockwise.circle"
        case .language: "globe"
        case .sync: "icloud"
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .aiService: I18N.shared.tr("配置模型服务、接口和生成偏好", "Configure model service, endpoint, and preferences")
        case .assistant: I18N.shared.tr("控制摘要、翻译和划词解释", "Control summary, translation, and selection explanation")
        case .refresh: I18N.shared.tr("控制订阅的自动更新", "Control automatic feed updates")
        case .language: I18N.shared.tr("切换应用界面语言", "Switch application display language")
        case .sync: I18N.shared.tr("同步阅读状态和 AI 结果", "Synchronize reading state and AI results")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selectedSection: SettingsSection = .aiService
    @State private var configuration = LLMConfiguration.default
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var usesCustomModel = false
    @State private var status = ""
    @State private var isTesting = false

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(spacing: 0) {
            settingsToolbar
            Divider().opacity(0.65)

            ScrollView {
                settingsPage
                    .frame(maxWidth: 700, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
            }
            .scrollContentBackground(.hidden)

            Divider().opacity(0.65)
            actionBar
        }
        .background(settingsWindowBackground)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 600, idealHeight: 680)
        .onAppear(perform: loadConfiguration)
    }

    private var settingsToolbar: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                    status = ""
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: section.icon)
                            .font(.system(size: 28, weight: .regular))
                            .symbolRenderingMode(.hierarchical)

                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(selectedSection == section ? Color.accentColor : .secondary)
                    .frame(width: 96, height: 78)
                    .background(
                        selectedSection == section
                            ? AnyShapeStyle(.quaternary)
                            : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.16), value: selectedSection)
    }
    #else
    private var iOSBody: some View {
        VStack(spacing: 0) {
            Picker("设置类别", selection: $selectedSection) {
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

            Divider()
            actionBar
        }
        .background(settingsWindowBackground)
        .onAppear(perform: loadConfiguration)
    }
    #endif

    @ViewBuilder
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 4) {
                Image(systemName: selectedSection.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                Text(selectedSection.title)
                    .font(.system(size: 25, weight: .bold))

                Text(selectedSection.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)

            switch selectedSection {
            case .aiService:
                aiServiceSettings
            case .assistant:
                readingAssistantSettings
            case .refresh:
                refreshSettings
            case .language:
                languageSettings
            case .sync:
                syncSettings
            }
        }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                I18N.shared.tr("界面语言", "Display Language"),
                footer: I18N.shared.tr("默认跟随系统设置或简体中文，可以自由切换为英文。", "Default uses Simplified Chinese or System, switchable to English.")
            ) {
                Picker(I18N.shared.tr("语言选择", "Select Language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.inline)
                #endif
            }
        }
    }

    private var aiServiceSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                "服务商",
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

                settingsRow("名称", description: "用于识别这组 AI 配置") {
                    TextField("例如：DeepSeek", text: $configuration.providerName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                }

                settingsRow("描述") {
                    TextField("例如：个人阅读助手", text: $configuration.providerDescription)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                }
            }

            settingsGroup(
                "连接",
                footer: "填写 API 根地址即可；Paper RSS 会自动追加 /chat/completions。"
            ) {
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

                settingsRow("Base URL") {
                    TextField("https://api.deepseek.com", text: $configuration.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

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
                    settingsRow("自定义模型") {
                        Toggle("输入自定义模型名称", isOn: $usesCustomModel)
                            .labelsHidden()
                    }
                }
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

                settingsRow(
                    "输出温度",
                    description: "较低值更稳定，较高值更多样；默认值适合摘要和翻译。"
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $configuration.temperature, in: 0...1, step: 0.1)
                            .frame(width: 220)
                        Text(configuration.temperature, format: .number.precision(.fractionLength(1)))
                            .font(.body.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    }
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

    private var readingAssistantSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(
                "摘要",
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

                settingsRow(
                    "打开文章时自动生成 AI 摘要",
                    description: "开启后，打开没有缓存摘要的文章会自动发送正文到模型。"
                ) {
                    Toggle("自动生成摘要", isOn: $configuration.automaticallyGenerateSummary)
                        .labelsHidden()
                }
            }

            settingsGroup(
                "翻译",
                footer: "逐段翻译只处理当前屏幕和即将进入视口的少量段落。"
            ) {
                settingsRow("目标语言") {
                    TextField("简体中文", text: $configuration.targetLanguage)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
            }

            settingsGroup(
                "划词解释",
                footer: "选择文章中的文字后手动触发；不会在阅读过程中自动发送正文。"
            ) {
                settingsRow("触发方式") {
                    Text("手动触发")
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .trailing)
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
                }

                settingsRow("状态") {
                    Text(store.iCloudSyncStatus)
                        .foregroundStyle(.secondary)
                        .frame(width: 240, alignment: .trailing)
                }

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
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.top, 15)
                .padding(.bottom, 5)

            content()

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 15)
            } else {
                Spacer(minLength: 15)
            }
        }
        .background(settingsGroupBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
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

            if selectedSection == .aiService || selectedSection == .assistant {
                Button("保存设置") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var settingsWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
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
        configuration = store.database.llmConfiguration
        apiKey = store.loadAPIKey()
        usesCustomModel = !["deepseek-v4-flash", "deepseek-v4-pro"].contains(configuration.model)
    }

    private func save() {
        let storage = store.saveLLMConfiguration(configuration, apiKey: apiKey)
        status = storage.savedMessage
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
