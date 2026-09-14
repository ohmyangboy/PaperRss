import Foundation

/// 可自定义的物理主键（ANSI 布局位置）。
///
/// 键位用 AppKit `keyCode` / DOM `event.code` 识别，而不是输入产生的字符：
/// 这样 `⌥J` 之类的组合不会被 macOS 的 Option 字符映射干扰，键盘布局与
/// 输入法切换也不会改变已保存的绑定。
public enum ReaderShortcutBaseKey: String, CaseIterable, Codable, Hashable, Sendable {
    case keyA = "KeyA"
    case keyB = "KeyB"
    case keyC = "KeyC"
    case keyD = "KeyD"
    case keyE = "KeyE"
    case keyF = "KeyF"
    case keyG = "KeyG"
    case keyH = "KeyH"
    case keyI = "KeyI"
    case keyJ = "KeyJ"
    case keyK = "KeyK"
    case keyL = "KeyL"
    case keyM = "KeyM"
    case keyN = "KeyN"
    case keyO = "KeyO"
    case keyP = "KeyP"
    case keyQ = "KeyQ"
    case keyR = "KeyR"
    case keyS = "KeyS"
    case keyT = "KeyT"
    case keyU = "KeyU"
    case keyV = "KeyV"
    case keyW = "KeyW"
    case keyX = "KeyX"
    case keyY = "KeyY"
    case keyZ = "KeyZ"

    case digit0 = "Digit0"
    case digit1 = "Digit1"
    case digit2 = "Digit2"
    case digit3 = "Digit3"
    case digit4 = "Digit4"
    case digit5 = "Digit5"
    case digit6 = "Digit6"
    case digit7 = "Digit7"
    case digit8 = "Digit8"
    case digit9 = "Digit9"

    case minus = "Minus"
    case equal = "Equal"
    case bracketLeft = "BracketLeft"
    case bracketRight = "BracketRight"
    case backslash = "Backslash"
    case semicolon = "Semicolon"
    case quote = "Quote"
    case comma = "Comma"
    case period = "Period"
    case slash = "Slash"
    case backquote = "Backquote"

    case space = "Space"
    case arrowUp = "ArrowUp"
    case arrowDown = "ArrowDown"
    case arrowLeft = "ArrowLeft"
    case arrowRight = "ArrowRight"
    case enter = "Enter"
    case backspace = "Backspace"
    case forwardDelete = "Delete"
    case home = "Home"
    case end = "End"
    case pageUp = "PageUp"
    case pageDown = "PageDown"

    /// AppKit `NSEvent.keyCode` → 主键。未列出的按键（Tab、Esc、功能键、
    /// 小键盘等）不参与自定义绑定。
    public init?(keyCode: UInt16) {
        guard let key = Self.keyCodeMap[keyCode] else { return nil }
        self = key
    }

    /// 面板键帽与提示文案使用的标签。
    public var displayLabel: String {
        switch self {
        case .keyA: "A"
        case .keyB: "B"
        case .keyC: "C"
        case .keyD: "D"
        case .keyE: "E"
        case .keyF: "F"
        case .keyG: "G"
        case .keyH: "H"
        case .keyI: "I"
        case .keyJ: "J"
        case .keyK: "K"
        case .keyL: "L"
        case .keyM: "M"
        case .keyN: "N"
        case .keyO: "O"
        case .keyP: "P"
        case .keyQ: "Q"
        case .keyR: "R"
        case .keyS: "S"
        case .keyT: "T"
        case .keyU: "U"
        case .keyV: "V"
        case .keyW: "W"
        case .keyX: "X"
        case .keyY: "Y"
        case .keyZ: "Z"
        case .digit0: "0"
        case .digit1: "1"
        case .digit2: "2"
        case .digit3: "3"
        case .digit4: "4"
        case .digit5: "5"
        case .digit6: "6"
        case .digit7: "7"
        case .digit8: "8"
        case .digit9: "9"
        case .minus: "-"
        case .equal: "="
        case .bracketLeft: "["
        case .bracketRight: "]"
        case .backslash: "\\"
        case .semicolon: ";"
        case .quote: "'"
        case .comma: ","
        case .period: "."
        case .slash: "/"
        case .backquote: "`"
        case .space: "Space"
        case .arrowUp: "↑"
        case .arrowDown: "↓"
        case .arrowLeft: "←"
        case .arrowRight: "→"
        case .enter: "↩"
        case .backspace: "⌫"
        case .forwardDelete: "⌦"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        }
    }

    private static let keyCodeMap: [UInt16: ReaderShortcutBaseKey] = [
        0: .keyA, 1: .keyS, 2: .keyD, 3: .keyF, 4: .keyH, 5: .keyG,
        6: .keyZ, 7: .keyX, 8: .keyC, 9: .keyV, 11: .keyB,
        12: .keyQ, 13: .keyW, 14: .keyE, 15: .keyR, 16: .keyY, 17: .keyT,
        18: .digit1, 19: .digit2, 20: .digit3, 21: .digit4, 22: .digit6,
        23: .digit5, 24: .equal, 25: .digit9, 26: .digit7, 27: .minus,
        28: .digit8, 29: .digit0,
        30: .bracketRight, 31: .keyO, 32: .keyU, 33: .bracketLeft, 34: .keyI, 35: .keyP,
        37: .keyL, 38: .keyJ, 39: .quote, 40: .keyK, 41: .semicolon,
        42: .backslash, 43: .comma, 44: .slash, 45: .keyN, 46: .keyM,
        47: .period, 50: .backquote,
        36: .enter, 49: .space, 51: .backspace, 117: .forwardDelete,
        115: .home, 116: .pageUp, 119: .end, 121: .pageDown,
        123: .arrowLeft, 124: .arrowRight, 125: .arrowDown, 126: .arrowUp
    ]
}

/// 一次按键组合：主键 + 修饰键。
public struct ReaderShortcutCombo: Codable, Hashable, Sendable {
    public var base: ReaderShortcutBaseKey
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(
        base: ReaderShortcutBaseKey,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) {
        self.base = base
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    private enum CodingKeys: String, CodingKey {
        case base
        case command
        case option
        case control
        case shift
    }

    /// 宽容解码：缺省的修饰键按未按下处理。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.base = try container.decode(ReaderShortcutBaseKey.self, forKey: .base)
        self.command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? false
        self.option = try container.decodeIfPresent(Bool.self, forKey: .option) ?? false
        self.control = try container.decodeIfPresent(Bool.self, forKey: .control) ?? false
        self.shift = try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
    }

    public var hasModifiers: Bool {
        command || option || control || shift
    }

    /// 键帽：[⌘] [⇧] [⌥] [⌃] [主键]。
    public var displayCaps: [String] {
        var caps: [String] = []
        if command { caps.append("⌘") }
        if shift { caps.append("⇧") }
        if option { caps.append("⌥") }
        if control { caps.append("⌃") }
        caps.append(base.displayLabel)
        return caps
    }

    /// 提示文案里连续展示的组合，例如 `⌘⇧R`。
    public var displayString: String {
        displayCaps.joined()
    }
}

/// 单个动作的绑定：组合键 + 是否需要「同一组合按两次」防误触确认。
public struct ReaderShortcutBinding: Codable, Hashable, Sendable {
    public var combo: ReaderShortcutCombo
    public var requiresConfirmation: Bool

    public init(combo: ReaderShortcutCombo, requiresConfirmation: Bool = true) {
        self.combo = combo
        self.requiresConfirmation = requiresConfirmation
    }

    private enum CodingKeys: String, CodingKey {
        case combo
        case requiresConfirmation
    }

    /// 宽容解码：旧数据或手写 JSON 缺字段时按默认值补齐。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.combo = try container.decode(ReaderShortcutCombo.self, forKey: .combo)
        self.requiresConfirmation = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresConfirmation
        ) ?? true
    }
}
