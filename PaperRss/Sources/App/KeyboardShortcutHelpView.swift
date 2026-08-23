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

    private var sections: [Section] {
        [
            Section(
                id: "reader",
                title: localized("文章阅读", "Article Reading"),
                shortcuts: [
                    shortcut("reader-translate", ["C", "C"], "切换对照翻译", "在当前文章中再次按 C 确认切换。"),
                    shortcut("reader-summary", ["V", "V"], "查看 AI 摘要", "在当前文章中再次按 V 确认，优先显示已有摘要；没有缓存时开始生成。"),
                    shortcut("reader-previous", ["K", "K"], "查看上一篇", "在当前列表中再次按 K 确认，不循环。"),
                    shortcut("reader-next", ["J", "J"], "查看下一篇", "在当前列表中再次按 J 确认，不循环。"),
                    shortcut("reader-star", ["M", "M"], "切换收藏", "在当前文章中再次按 M 确认收藏或取消收藏。"),
                    shortcut("reader-fullscreen", ["F", "F"], "切换禅模式", "在当前文章中再次按 F 确认进入或退出沉浸禅模式。"),
                    shortcut("reader-space", ["Space"], "向下阅读", "滚动正文；到达底部后再次按空格切换下一篇。")
                ]
            ),
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                ForEach(sections) { section in
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
                "C、V、B、N、M 等裸键只在文章 Feed 阅读界面有效。输入文字、选择正文或打开 AI 交互弹层时不会触发；⌘C 与 ⌘V 始终保留系统复制、粘贴行为。",
                "Bare keys such as C, V, B, N, and M work only while reading an article feed. They are disabled while typing, selecting text, or using an AI popover. ⌘C and ⌘V always keep the system Copy and Paste behavior."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        case "reader-translate": "Toggle Bilingual Translation"
        case "reader-summary": "Show AI Summary"
        case "reader-previous": "Previous Article"
        case "reader-next": "Next Article"
        case "reader-star": "Toggle Star"
        case "reader-space": "Read Down"
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
        case "reader-translate": "Turns paragraph-by-paragraph bilingual translation on or off."
        case "reader-summary": "Shows a cached summary first, or starts generating one."
        case "reader-previous": "Press B again to confirm within the current list; navigation does not wrap."
        case "reader-next": "Press N again to confirm within the current list; navigation does not wrap."
        case "reader-star": "Stars or unstars the current article."
        case "reader-space": "Scrolls the article; at the bottom, press Space again to open the next article."
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
