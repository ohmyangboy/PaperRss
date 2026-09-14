import AppKit
import Foundation
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// 不可被「文章阅读」自定义覆盖的系统与应用固定快捷键。
///
/// 来源分两层：
/// 1. 静态表：栏目/列表方向键导航与 `ThreeColumnSplitView` 硬编码的字号、
///    返回时间线等组合（包括 `=`/`+`、`-`/`_` 之类的等价别名）。
/// 2. 动态表：运行时扫描 `NSApp.mainMenu`，覆盖复制、粘贴、关闭、退出等
///    菜单快捷键，避免应用版本变化后静态表过期。
@MainActor
final class ReaderShortcutReservedCatalog {
    static let shared = ReaderShortcutReservedCatalog()

    struct Entry {
        let combo: ReaderShortcutCombo
        let label: String
    }

    private init() {}

    func reservedLabel(for combo: ReaderShortcutCombo) -> String? {
        entries().first { $0.combo == combo }?.label
    }

    func isReserved(_ combo: ReaderShortcutCombo) -> Bool {
        reservedLabel(for: combo) != nil
    }

    /// 清理历史/手写数据中的保留组合，保证任何来源的绑定都不会遮蔽系统快捷键。
    func sanitize(_ bindings: ReaderShortcutBindings) -> ReaderShortcutBindings {
        let reserved = Set(entries().map(\.combo))
        var result = ReaderShortcutBindings.default
        var claimed = Set(ReaderShortcutAction.allCases.map { result[$0].combo })
        // 两轮：第一轮让用户改走的默认位释放出来，第二轮补上因此空出的槽位。
        for _ in 0..<2 {
            for action in ReaderShortcutAction.allCases {
                let stored = bindings[action]
                let current = result[action].combo
                guard !reserved.contains(stored.combo) else { continue }
                guard stored.combo != current else {
                    result.setRequiresConfirmation(stored.requiresConfirmation, for: action)
                    continue
                }
                guard !claimed.contains(stored.combo) else { continue }
                claimed.remove(current)
                claimed.insert(stored.combo)
                try? result.setKey(stored.combo, for: action)
                result.setRequiresConfirmation(stored.requiresConfirmation, for: action)
            }
        }
        return result
    }

    private func entries() -> [Entry] {
        staticEntries() + menuEntries()
    }

    private func staticEntries() -> [Entry] {
        let navigation = I18N.localized("栏目导航", englishFallback: "Column Navigation")
        let list = I18N.localized("列表导航", englishFallback: "List Navigation")
        let timeline = I18N.localized("返回时间线", englishFallback: "Return to Timeline")
        let fontSize = I18N.localized("正文字号", englishFallback: "Article Text Size")
        let refresh = I18N.localized("刷新全部订阅", englishFallback: "Refresh All Feeds")
        let help = I18N.localized("键盘快捷键", englishFallback: "Keyboard Shortcuts")

        return [
            Entry(combo: ReaderShortcutCombo(base: .arrowLeft), label: navigation),
            Entry(combo: ReaderShortcutCombo(base: .arrowRight), label: navigation),
            Entry(combo: ReaderShortcutCombo(base: .arrowUp), label: list),
            Entry(combo: ReaderShortcutCombo(base: .arrowDown), label: list),
            Entry(combo: ReaderShortcutCombo(base: .arrowLeft, command: true), label: timeline),
            Entry(combo: ReaderShortcutCombo(base: .arrowLeft, command: true, shift: true), label: timeline),
            Entry(combo: ReaderShortcutCombo(base: .bracketLeft, command: true), label: timeline),
            Entry(combo: ReaderShortcutCombo(base: .bracketLeft, command: true, shift: true), label: timeline),
            Entry(combo: ReaderShortcutCombo(base: .equal, command: true), label: fontSize),
            Entry(combo: ReaderShortcutCombo(base: .equal, command: true, shift: true), label: fontSize),
            Entry(combo: ReaderShortcutCombo(base: .minus, command: true), label: fontSize),
            Entry(combo: ReaderShortcutCombo(base: .minus, command: true, shift: true), label: fontSize),
            Entry(combo: ReaderShortcutCombo(base: .digit0, command: true), label: fontSize),
            Entry(combo: ReaderShortcutCombo(base: .keyR, command: true, shift: true), label: refresh),
            Entry(combo: ReaderShortcutCombo(base: .slash, command: true), label: help)
        ]
    }

    private func menuEntries() -> [Entry] {
        guard let mainMenu = NSApp.mainMenu else { return [] }
        var result: [Entry] = []
        var visited = Set<ObjectIdentifier>()

        func walk(_ menu: NSMenu) {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return }
            for item in menu.items {
                if !item.keyEquivalent.isEmpty,
                   let combo = ReaderShortcutCombo(
                       keyEquivalent: item.keyEquivalent,
                       modifiers: item.keyEquivalentModifierMask
                   ) {
                    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(Entry(combo: combo, label: title.isEmpty ? combo.displayString : title))
                }
                if let submenu = item.submenu {
                    walk(submenu)
                }
            }
        }

        walk(mainMenu)
        return result
    }
}

extension ReaderShortcutCombo {
    /// 将菜单的 `keyEquivalent` 字符还原为物理主键组合。
    init?(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) {
        guard let scalar = keyEquivalent.unicodeScalars.first else { return nil }

        let base: ReaderShortcutBaseKey
        var impliedShift = false
        switch scalar.value {
        case 0xF700: base = .arrowUp
        case 0xF701: base = .arrowDown
        case 0xF702: base = .arrowLeft
        case 0xF703: base = .arrowRight
        case 0x0D: base = .enter
        case 0x20: base = .space
        case 0x08: base = .backspace
        case 0x7F: base = .forwardDelete
        default:
            guard let mapped = Self.baseKey(forMenuCharacter: scalar) else { return nil }
            base = mapped.base
            impliedShift = mapped.impliedShift
        }

        self.init(
            base: base,
            command: modifiers.contains(.command),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            shift: modifiers.contains(.shift) || impliedShift
        )
    }

    private static func baseKey(
        forMenuCharacter scalar: Unicode.Scalar
    ) -> (base: ReaderShortcutBaseKey, impliedShift: Bool)? {
        let impliedShift = CharacterSet.uppercaseLetters.contains(scalar)
        guard let character = Character(scalar).lowercased().first else { return nil }
        switch character {
        case "a": return (.keyA, false)
        case "b": return (.keyB, false)
        case "c": return (.keyC, false)
        case "d": return (.keyD, false)
        case "e": return (.keyE, false)
        case "f": return (.keyF, false)
        case "g": return (.keyG, false)
        case "h": return (.keyH, false)
        case "i": return (.keyI, false)
        case "j": return (.keyJ, false)
        case "k": return (.keyK, false)
        case "l": return (.keyL, false)
        case "m": return (.keyM, false)
        case "n": return (.keyN, false)
        case "o": return (.keyO, false)
        case "p": return (.keyP, false)
        case "q": return (.keyQ, false)
        case "r": return (.keyR, false)
        case "s": return (.keyS, false)
        case "t": return (.keyT, false)
        case "u": return (.keyU, false)
        case "v": return (.keyV, false)
        case "w": return (.keyW, false)
        case "x": return (.keyX, false)
        case "y": return (.keyY, false)
        case "z": return (.keyZ, false)
        case "0": return (.digit0, false)
        case "1": return (.digit1, false)
        case "2": return (.digit2, false)
        case "3": return (.digit3, false)
        case "4": return (.digit4, false)
        case "5": return (.digit5, false)
        case "6": return (.digit6, false)
        case "7": return (.digit7, false)
        case "8": return (.digit8, false)
        case "9": return (.digit9, false)
        case "-": return (.minus, false)
        case "_": return (.minus, true)
        case "=": return (.equal, false)
        case "+": return (.equal, true)
        case "[": return (.bracketLeft, false)
        case "{": return (.bracketLeft, true)
        case "]": return (.bracketRight, false)
        case "}": return (.bracketRight, true)
        case "\\": return (.backslash, false)
        case "|": return (.backslash, true)
        case ";": return (.semicolon, false)
        case ":": return (.semicolon, true)
        case "'": return (.quote, false)
        case "\"": return (.quote, true)
        case ",": return (.comma, false)
        case "<": return (.comma, true)
        case ".": return (.period, false)
        case ">": return (.period, true)
        case "/": return (.slash, false)
        case "?": return (.slash, true)
        case "`": return (.backquote, false)
        case "~": return (.backquote, true)
        default:
            return nil
        }
    }
}
