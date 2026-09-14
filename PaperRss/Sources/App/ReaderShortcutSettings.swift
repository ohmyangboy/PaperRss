import Combine
import Foundation
#if os(macOS)
import AppKit
#endif
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// 「文章阅读」自定义快捷键的唯一读写入口。
///
/// 持久化到 `UserDefaults`（JSON），并通过通知驱动主窗口的 AppKit 监听与
/// 阅读器 WebView 的注入脚本实时更新，面板改动无需重启。
@MainActor
final class ReaderShortcutSettings: ObservableObject {
    static let shared = ReaderShortcutSettings()

    static let storageKey = "PaperRss.readerShortcutBindings"
    static let didChangeNotification = Notification.Name("PaperRss.readerShortcutBindingsDidChange")

    /// 组合键不可用时的原因，供录制器与提示文案使用。
    enum Conflict: Equatable {
        /// 系统或应用固定快捷键，禁止覆盖。
        case reserved(label: String)
        /// 已被另一个「文章阅读」动作占用。
        case duplicate(action: ReaderShortcutAction)
    }

    @Published private(set) var bindings: ReaderShortcutBindings

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = ReaderShortcutBindings.default
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(ReaderShortcutBindings.self, from: data) {
            loaded = decoded
        }
        #if os(macOS)
        loaded = ReaderShortcutReservedCatalog.shared.sanitize(loaded)
        #endif
        bindings = loaded
    }

    /// 分配组合键；冲突时不写入。
    @discardableResult
    func assign(_ combo: ReaderShortcutCombo, to action: ReaderShortcutAction) -> Conflict? {
        if let conflict = conflict(for: combo, assignedTo: action) {
            return conflict
        }
        try? bindings.setKey(combo, for: action)
        persist()
        return nil
    }

    /// 预检冲突，供录制器实时提示；未冲突返回 nil。
    func conflict(for combo: ReaderShortcutCombo, assignedTo action: ReaderShortcutAction) -> Conflict? {
        if bindings[action].combo == combo {
            return nil
        }
        #if os(macOS)
        if let label = ReaderShortcutReservedCatalog.shared.reservedLabel(for: combo) {
            return .reserved(label: label)
        }
        #endif
        if let occupied = bindings.action(for: combo) {
            return .duplicate(action: occupied)
        }
        return nil
    }

    func setRequiresConfirmation(_ value: Bool, for action: ReaderShortcutAction) {
        guard bindings[action].requiresConfirmation != value else { return }
        bindings.setRequiresConfirmation(value, for: action)
        persist()
    }

    func reset(_ action: ReaderShortcutAction) {
        guard !isDefault(action) else { return }
        bindings.reset(action)
        persist()
    }

    func resetAll() {
        guard !bindings.isDefault else { return }
        bindings.resetAll()
        persist()
    }

    func isDefault(_ action: ReaderShortcutAction) -> Bool {
        bindings[action] == ReaderShortcutBindings.default[action]
    }

    /// 注入 WebView 的绑定表（动作 rawValue → 组合键字段）。
    /// 保留组合在任何情况下都不会下发：即使存储被手改成系统快捷键，
    /// 页面脚本也只会拿到该动作的默认键，浏览器复制/粘贴等行为不受影响。
    var javaScriptPayloadJSON: String {
        var payload: [String: [String: Any]] = [:]
        for action in ReaderShortcutAction.allCases {
            var combo = bindings[action].combo
            #if os(macOS)
            if ReaderShortcutReservedCatalog.shared.isReserved(combo) {
                combo = ReaderShortcutBindings.default[action].combo
            }
            #endif
            payload[action.rawValue] = [
                "base": combo.base.rawValue,
                "command": combo.command,
                "option": combo.option,
                "control": combo.control,
                "shift": combo.shift
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

#if os(macOS)
extension ReaderShortcutCombo {
    /// 从 AppKit 事件构造组合键；未列入自定义表的按键（Tab、Esc、功能键等）返回 nil。
    @MainActor
    init?(event: NSEvent) {
        guard let base = ReaderShortcutBaseKey(keyCode: event.keyCode) else { return nil }
        let flags = event.modifierFlags
        self.init(
            base: base,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
    }
}
#endif
