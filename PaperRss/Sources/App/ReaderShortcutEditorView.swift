import SwiftUI
#if os(macOS)
import AppKit
#endif
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// 面板与录制器共享的动作文案。
enum ReaderShortcutPresentation {
    static func title(for action: ReaderShortcutAction) -> String {
        switch action {
        case .toggleBilingual:
            I18N.localized("切换对照翻译", englishFallback: "Toggle Bilingual Translation")
        case .showSummary:
            I18N.localized("查看 AI 摘要", englishFallback: "Show AI Summary")
        case .previousArticle:
            I18N.localized("查看上一篇", englishFallback: "Previous Article")
        case .nextArticle:
            I18N.localized("查看下一篇", englishFallback: "Next Article")
        case .toggleStar:
            I18N.localized("切换收藏", englishFallback: "Toggle Star")
        case .toggleFullScreen:
            I18N.localized("切换禅模式", englishFallback: "Toggle Focus Mode")
        case .openOriginal:
            I18N.localized("打开原文", englishFallback: "Open Original in Browser")
        case .scrollDown:
            I18N.localized("向下阅读", englishFallback: "Read Down")
        }
    }

    static func detail(for action: ReaderShortcutAction) -> String {
        switch action {
        case .toggleBilingual:
            I18N.localized("在当前文章中开启或关闭逐段对照翻译。", englishFallback: "Turns paragraph-by-paragraph bilingual translation on or off.")
        case .showSummary:
            I18N.localized("优先显示已有 AI 摘要；没有缓存时开始生成。", englishFallback: "Shows a cached summary first, or starts generating one.")
        case .previousArticle:
            I18N.localized("在当前列表中查看上一篇，不循环。", englishFallback: "Opens the previous article in the current list without wrapping.")
        case .nextArticle:
            I18N.localized("在当前列表中查看下一篇，不循环。", englishFallback: "Opens the next article in the current list without wrapping.")
        case .toggleStar:
            I18N.localized("收藏或取消收藏当前文章。", englishFallback: "Stars or unstars the current article.")
        case .toggleFullScreen:
            I18N.localized("进入或退出沉浸禅模式。", englishFallback: "Enters or exits Focus Mode.")
        case .openOriginal:
            I18N.localized("在默认浏览器中打开当前文章的原始链接。", englishFallback: "Opens the current article’s original link in your default browser.")
        case .scrollDown:
            I18N.localized("滚动正文；到达底部后切换下一篇。", englishFallback: "Scrolls the article; at the bottom, moves on to the next article.")
        }
    }
}

#if os(macOS)
/// VS Code 风格的录制弹层：打开即监听，按下组合键立即生效，Esc 取消。
struct ReaderShortcutEditorView: View {
    let action: ReaderShortcutAction
    var onRevealAction: (ReaderShortcutAction) -> Void

    @ObservedObject private var settings = ReaderShortcutSettings.shared
    @StateObject private var recorder = ReaderShortcutRecorder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ReaderShortcutPresentation.title(for: action))
                .font(.headline)

            Text(I18N.localized("请直接按下新的快捷键组合", englishFallback: "Press the new shortcut now"))
                .font(.caption)
                .foregroundStyle(.secondary)

            recorderField

            if let conflict = recorder.conflict {
                conflictView(conflict)
            } else if let hint = recorder.hint {
                Label(hint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(isOn: confirmationBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18N.localized("防误触", englishFallback: "Prevent Accidental Triggers"))
                        .font(.callout)
                    Text(settings.bindings[action].requiresConfirmation
                         ? I18N.localized(
                             "当前快捷键需连续按下两次才会触发。",
                             englishFallback: "The shortcut triggers only after two consecutive presses."
                         )
                         : I18N.localized(
                             "当前快捷键按一次即触发。",
                             englishFallback: "The shortcut triggers on a single press."
                         ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            HStack {
                Button(I18N.localized("恢复默认", englishFallback: "Restore Default")) {
                    settings.reset(action)
                }
                .disabled(settings.isDefault(action))

                Spacer()

                Button(I18N.localized("完成", englishFallback: "Done")) {
                    dismiss()
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            recorder.start(action: action, settings: settings) {
                dismiss()
            }
        }
        .onDisappear {
            recorder.stop()
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { settings.bindings[action].requiresConfirmation },
            set: { settings.setRequiresConfirmation($0, for: action) }
        )
    }

    private var recorderField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if recorder.previewCaps.isEmpty {
                    Text(I18N.localized("等待按键…", englishFallback: "Waiting for keys…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(recorder.previewCaps.enumerated()), id: \.offset) { _, cap in
                        Text(cap)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .frame(minWidth: cap.count > 1 ? 44 : 26, minHeight: 26)
                            .padding(.horizontal, cap.count > 1 ? 4 : 0)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(.primary.opacity(0.12), lineWidth: 1)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.primary.opacity(0.12), lineWidth: 1)
            }

            Text(I18N.localized(
                "Esc 取消 · Tab 与裸方向键保留给系统交互",
                englishFallback: "Esc cancels · Tab and bare arrow keys stay reserved for the system"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Text(I18N.localized(
                "带 ⌘ / ⇧ / ⌥ / ⌃ 的组合会自动关闭防误触。",
                englishFallback: "Combinations with ⌘ / ⇧ / ⌥ / ⌃ automatically turn off Prevent Accidental Triggers."
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func conflictView(_ conflict: ReaderShortcutSettings.Conflict) -> some View {
        switch conflict {
        case let .reserved(label):
            Label {
                Text(I18N.shared.localizedFormat("该组合是系统快捷键「%@」，无法绑定", label))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

        case let .duplicate(other):
            Button {
                onRevealAction(other)
            } label: {
                Label {
                    Text(I18N.shared.localizedFormat(
                        "已被「%@」使用，点此前往修改",
                        ReaderShortcutPresentation.title(for: other)
                    ))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }
}

/// 录制期监听：keyDown 构造组合键，flagsChanged 实时预览修饰键。
@MainActor
final class ReaderShortcutRecorder: ObservableObject {
    @Published private(set) var previewCaps: [String] = []
    @Published private(set) var conflict: ReaderShortcutSettings.Conflict?
    @Published private(set) var hint: String?

    nonisolated(unsafe) private var monitor: Any?
    private weak var settings: ReaderShortcutSettings?
    private var action: ReaderShortcutAction?
    private var onFinish: (() -> Void)?

    deinit {
        // 视图意外销毁时也要摘掉全局键盘监听，避免残留的监听吞掉按键。
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start(
        action: ReaderShortcutAction,
        settings: ReaderShortcutSettings,
        onFinish: @escaping () -> Void
    ) {
        stop()
        self.action = action
        self.settings = settings
        self.onFinish = onFinish
        previewCaps = settings.bindings[action].combo.displayCaps
        conflict = nil
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                self?.handle(event) ?? false
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        settings = nil
        action = nil
        onFinish = nil
    }

    /// 返回 true 表示事件已被录制器消费。
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            let caps = Self.modifierCaps(for: event.modifierFlags)
            if !caps.isEmpty {
                previewCaps = caps
            }
            return true

        case .keyDown:
            if event.keyCode == 53 {
                // Esc：取消录制，不写入任何改动。
                onFinish?()
                return true
            }
            if event.keyCode == 48 {
                conflict = nil
                hint = I18N.localized(
                    "Tab 用于系统焦点导航，无法绑定",
                    englishFallback: "Tab is reserved for system focus navigation"
                )
                return true
            }
            guard let combo = ReaderShortcutCombo(event: event) else {
                conflict = nil
                hint = I18N.localized(
                    "暂不支持该按键，请换一个组合",
                    englishFallback: "This key is not supported; try another combination"
                )
                return true
            }

            previewCaps = combo.displayCaps
            guard let action, let settings else { return true }

            if let conflict = settings.conflict(for: combo, assignedTo: action) {
                self.conflict = conflict
                hint = nil
                return true
            }

            settings.assign(combo, to: action)
            conflict = nil
            onFinish?()
            return true

        default:
            return false
        }
    }

    private static func modifierCaps(for flags: NSEvent.ModifierFlags) -> [String] {
        var caps: [String] = []
        if flags.contains(.command) { caps.append("⌘") }
        if flags.contains(.shift) { caps.append("⇧") }
        if flags.contains(.option) { caps.append("⌥") }
        if flags.contains(.control) { caps.append("⌃") }
        return caps
    }
}
#endif
