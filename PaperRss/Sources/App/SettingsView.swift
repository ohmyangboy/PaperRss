import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

private enum SettingsSection: String, CaseIterable, Identifiable {
    case ai
    case sync

    var id: Self { self }
    var title: String {
        switch self {
        case .ai: "AI 服务"
        case .sync: "同步"
        }
    }
}

private enum AISettingsPane: String, CaseIterable, Identifiable {
    case connection
    case assistant

    var id: Self { self }
    var title: String {
        switch self {
        case .connection: "服务连接"
        case .assistant: "阅读助手"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selectedSection: SettingsSection = .ai
    @State private var configuration = LLMConfiguration.default
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var usesCustomModel = false
    @State private var status = ""
    @State private var isTesting = false
    @State private var selectedAIPane: AISettingsPane = .connection

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider()

            Group {
                switch selectedSection {
                case .ai:
                    aiSettings
                case .sync:
                    syncSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            actionBar
        }
        .background(PaperSurface(kind: .page, textureOpacity: 0.42))
        #if os(macOS)
        .frame(minWidth: 700, idealWidth: 740, minHeight: 540, idealHeight: 590)
        #endif
        .onAppear(perform: loadConfiguration)
    }

    private var settingsHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "newspaper")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PaperTheme.accent)
                Text("Paper RSS 设置")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            Picker("设置类别", selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 500)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(PaperHeaderSurface())
    }

    private var aiSettings: some View {
        VStack(spacing: 0) {
            providerHeader

            Picker("AI 设置", selection: $selectedAIPane) {
                ForEach(AISettingsPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.top, 14)
            .padding(.bottom, 4)

            switch selectedAIPane {
            case .connection:
                connectionSettings
            case .assistant:
                readingAssistantSettings
            }
        }
    }

    private var connectionSettings: some View {
        Form {
                Section("服务商") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DeepSeek 推荐配置")
                            Text("官方 OpenAI 兼容地址与 Flash 模型")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("使用") { useDeepSeekDefaults() }
                    }

                    LabeledContent("名称") {
                        TextField("例如：DeepSeek", text: $configuration.providerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                    }
                    LabeledContent("描述") {
                        TextField("例如：个人阅读助手", text: $configuration.providerDescription)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                    }
                }

                Section("连接") {
                    LabeledContent("API Key") {
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

                    LabeledContent("Base URL") {
                        TextField("https://api.deepseek.com", text: $configuration.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }

                    LabeledContent("模型") {
                        if configuration.usesDeepSeekAPI && !usesCustomModel {
                            Picker("模型", selection: $configuration.model) {
                                Text("deepseek-v4-flash（推荐）").tag("deepseek-v4-flash")
                                Text("deepseek-v4-pro").tag("deepseek-v4-pro")
                            }
                            .labelsHidden()
                            .frame(maxWidth: 300)
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
                        Toggle("输入自定义模型名称", isOn: $usesCustomModel)
                    }

                    Text("填写 API 根地址即可；Paper RSS 会自动追加 /chat/completions。密钥只保存在这台设备。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
    }

    private var providerHeader: some View {
        HStack(spacing: 13) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(PaperTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(configuration.providerName.isEmpty ? "OpenAI 兼容接口" : configuration.providerName)
                    .font(.headline)
                Text(
                    configuration.automaticallyGenerateSummary
                        ? "自动摘要已开启；其他 AI 功能仍按需发送"
                        : "仅在你主动使用 AI 功能时发送当前所需正文"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    private var readingAssistantSettings: some View {
        Form {
            Section("摘要") {
                Toggle(
                    "打开文章时自动生成 AI 摘要",
                    isOn: $configuration.automaticallyGenerateSummary
                )
                Text(
                    configuration.automaticallyGenerateSummary
                        ? "首次打开尚无摘要的文章时自动生成；已有缓存不会重复请求。"
                        : "保持手动模式，只在你点击“生成摘要”后请求模型。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("翻译") {
                LabeledContent("目标语言") {
                    TextField("简体中文", text: $configuration.targetLanguage)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 240)
                }
                Text("逐段翻译只处理当前屏幕和即将进入视口的少量段落。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("模型行为") {
                Picker("推理偏好", selection: $configuration.reasoningMode) {
                    Text("自动").tag("自动")
                    Text("关闭").tag("关闭")
                    Text("低").tag("低")
                    Text("中").tag("中")
                    Text("高").tag("高")
                }
                .pickerStyle(.menu)

                LabeledContent("温度") {
                    HStack {
                        Slider(value: $configuration.temperature, in: 0...1, step: 0.1)
                            .frame(maxWidth: 260)
                        Text(configuration.temperature, format: .number.precision(.fractionLength(1)))
                            .font(.body.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                Toggle("允许局域网 HTTP（不安全）", isOn: $configuration.allowInsecureLocalEndpoint)
            }

            Section {
                Text(reasoningFooter + " 选中文字解释始终由你手动触发。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var syncSettings: some View {
        Form {
            Section("iCloud") {
                Toggle(
                    "同步订阅、已读、收藏和 AI 结果",
                    isOn: Binding(
                        get: { store.isICloudSyncEnabled },
                        set: { store.setICloudSyncEnabled($0) }
                    )
                )

                LabeledContent("状态") {
                    Text(store.iCloudSyncStatus)
                        .foregroundStyle(.secondary)
                }

                Button("立即同步") {
                    Task { await store.syncICloud() }
                }
                .disabled(!store.isICloudSyncEnabled)
            }

            Section("隐私") {
                LabeledContent("API Key") {
                    Text("仅存于本机，不参与同步")
                        .foregroundStyle(.secondary)
                }
                Text("网页缓存、HTTP 缓存和调试日志不会同步到 iCloud。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

            if selectedSection == .ai && selectedAIPane == .connection {
                Button(isTesting ? "正在测试…" : "测试连接") { test() }
                    .disabled(isTesting)
            }

            if selectedSection != .sync {
                Button("保存配置") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(PaperHeaderSurface())
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
