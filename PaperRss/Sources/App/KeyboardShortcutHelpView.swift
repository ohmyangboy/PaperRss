#if os(macOS)
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

enum KeyboardShortcutHelpWindow {
    static let id = "keyboard-shortcuts"
}

struct KeyboardShortcutHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(I18N.localized("键盘快捷键…", englishFallback: "Keyboard Shortcuts…")) {
                openWindow(id: KeyboardShortcutHelpWindow.id)
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}

struct KeyboardShortcutHelpView: View {
    @ObservedObject private var settings = ReaderShortcutSettings.shared
    @State private var editingAction: ReaderShortcutAction?

    private struct Shortcut: Identifiable {
        let id: String
        let keys: [String]
        let title: String
        let detail: String
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let shortcuts: [Shortcut]
    }

    private var fixedSections: [Section] {
        [
            Section(
                id: "navigation",
                title: localized("栏目导航", "Column Navigation"),
                shortcuts: [
                    shortcut("navigation-left", ["←"], "移到左侧栏目", "在订阅源、文章列表和正文之间移动焦点。"),
                    shortcut("navigation-right", ["→"], "移到右侧栏目", "在订阅源、文章列表和正文之间移动焦点。")
                ]
            ),
            Section(
                id: "global",
                title: localized("全局", "Global"),
                shortcuts: [
                    shortcut("global-refresh", ["⌘", "⇧", "R"], "刷新全部订阅", "立即检查所有订阅源。"),
                    shortcut("global-increase", ["⌘", "+"], "放大正文字号", "增大文章正文的显示字号。"),
                    shortcut("global-decrease", ["⌘", "−"], "缩小正文字号", "减小文章正文的显示字号。"),
                    shortcut("global-reset", ["⌘", "0"], "默认正文字号", "恢复默认文章正文字号。"),
                    shortcut("global-help", ["⌘", "/"], "打开快捷键帮助", "显示这个帮助窗口。")
                ]
            )
        ]
    }

    var body: some View {
        PaperFloatingScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                readerSection

                ForEach(fixedSections) { section in
                    fixedSectionView(section)
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(localized("键盘快捷键", "Keyboard Shortcuts"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localized("键盘快捷键", "Keyboard Shortcuts"), systemImage: "keyboard")
                .font(.title2.weight(.semibold))

            Text(localized(
                "文章阅读的按键组合可逐行自定义；输入文字、选择正文或打开 AI 交互弹层时不会触发。栏目导航与全局快捷键保持系统设置，冲突的组合会被拒绝，⌘C 与 ⌘V 始终保留系统复制、粘贴行为。",
                "Article-reading shortcuts are customizable per row. They stay disabled while typing, selecting text, or using an AI popover. Column navigation and global shortcuts keep their system defaults, conflicting combinations are rejected, and ⌘C / ⌘V always keep the system Copy and Paste behavior."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 文章阅读（可自定义）

    private var readerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("文章阅读", "Article Reading"))
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Button(localized("全部恢复默认", "Restore All Defaults")) {
                    settings.resetAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(settings.bindings.isDefault ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .disabled(settings.bindings.isDefault)
                .help(localized("把文章阅读的快捷键恢复为默认值", "Restore article-reading shortcuts to their defaults"))
            }

            VStack(spacing: 0) {
                ForEach(Array(ReaderShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                    readerShortcutRow(action)
                    if index < ReaderShortcutAction.allCases.count - 1 {
                        Divider().padding(.leading, 18)
                    }
                }
            }
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }

            Text(localized(
                "点击右侧编辑按钮后直接按下新的组合键（如 ⌥J、⇧⌘↑）；键帽右侧的 ×2 表示需要连按两次。系统与栏目导航占用的组合会提示不可用。",
                "Use the edit button on the right, then press a new combination (such as ⌥J or ⇧⌘↑). A small ×2 beside the keys marks shortcuts that need two consecutive presses. Combinations reserved by the system or column navigation are rejected with a notice."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readerShortcutRow(_ action: ReaderShortcutAction) -> some View {
        let binding = settings.bindings[action]
        return HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ReaderShortcutPresentation.title(for: action))
                    .font(.body.weight(.medium))
                Text(ReaderShortcutPresentation.detail(for: action))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // 快捷键区整体贴文字底部对齐，并尽量靠右；编辑入口无底色。
            HStack(alignment: .center, spacing: 10) {
                keycapGroups(for: binding)

                // 固定在键帽右侧的小字倍率标记；保留槽位让各行键帽左侧对齐。
                Text(binding.requiresConfirmation ? "×2" : "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(!binding.requiresConfirmation)

                shortcutEditButton(for: action)
            }
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func shortcutEditButton(for action: ReaderShortcutAction) -> some View {
        Button {
            editingAction = action
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(localized("编辑这个动作的快捷键", "Edit this action’s shortcut"))
        .accessibilityLabel(Text(String(
            format: localized("自定义「%@」快捷键", "Customize the “%@” shortcut"),
            ReaderShortcutPresentation.title(for: action)
        )))
        .popover(isPresented: editorBinding(action), arrowEdge: .trailing) {
            ReaderShortcutEditorView(action: action) { revealed in
                DispatchQueue.main.async {
                    editingAction = revealed
                }
            }
        }
    }

    private func keycapGroups(for binding: ReaderShortcutBinding) -> some View {
        HStack(spacing: 8) {
            keycapRow(binding.combo.displayCaps)
            if binding.requiresConfirmation {
                keycapRow(binding.combo.displayCaps)
            }
        }
    }

    private func keycapRow(_ caps: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .frame(minWidth: key.count > 1 ? 44 : 26, minHeight: 26)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.primary.opacity(0.12), lineWidth: 1)
                    }
            }
        }
    }

    private func editorBinding(_ action: ReaderShortcutAction) -> Binding<Bool> {
        Binding(
            get: { editingAction == action },
            set: { isPresented in
                if !isPresented, editingAction == action {
                    editingAction = nil
                }
            }
        )
    }

    // MARK: - 固定分组

    private func fixedSectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach(Array(section.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    shortcutRow(shortcut)
                    if index < section.shortcuts.count - 1 {
                        Divider().padding(.leading, 18)
                    }
                }
            }
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private func shortcutRow(_ shortcut: Shortcut) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.title)
                    .font(.body.weight(.medium))
                Text(shortcut.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            HStack(spacing: 5) {
                ForEach(shortcut.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .frame(minWidth: key == "Space" ? 62 : 26, minHeight: 26)
                        .padding(.horizontal, key.count > 1 && key != "Space" ? 4 : 0)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.primary.opacity(0.12), lineWidth: 1)
                        }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func shortcut(
        _ id: String,
        _ keys: [String],
        _ chineseTitle: String,
        _ chineseDetail: String,
        englishTitle: String? = nil,
        englishDetail: String? = nil
    ) -> Shortcut {
        Shortcut(
            id: id,
            keys: keys,
            title: localized(chineseTitle, englishTitle ?? englishTitleForShortcut(id)),
            detail: localized(chineseDetail, englishDetail ?? englishDetailForShortcut(id))
        )
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        I18N.localized(chinese, englishFallback: english)
    }

    private func englishTitleForShortcut(_ id: String) -> String {
        switch id {
        case "navigation-left": "Move to the Left Column"
        case "navigation-right": "Move to the Right Column"
        case "global-refresh": "Refresh All Feeds"
        case "global-increase": "Increase Article Text Size"
        case "global-decrease": "Decrease Article Text Size"
        case "global-reset": "Reset Article Text Size"
        case "global-help": "Open Keyboard Shortcut Help"
        default: id
        }
    }

    private func englishDetailForShortcut(_ id: String) -> String {
        switch id {
        case "navigation-left", "navigation-right": "Moves focus between feeds, the article list, and the reader."
        case "global-refresh": "Checks every feed for new articles now."
        case "global-increase": "Increases the article body text size."
        case "global-decrease": "Decreases the article body text size."
        case "global-reset": "Restores the default article body text size."
        case "global-help": "Shows this help window."
        default: id
        }
    }
}
#endif
