import Foundation

/// 「文章阅读」动作的键位表。
///
/// 不变量：任意两个动作不会共享同一个组合键；解码与 `setKey` 都会维持它。
/// 除冲突（`UpdateError.duplicate`）外的任何输入都不会让类型进入非法状态。
public struct ReaderShortcutBindings: Codable, Hashable, Sendable {
    public enum UpdateError: Error, Equatable {
        case duplicate(ReaderShortcutAction)
    }

    private var storage: [ReaderShortcutAction: ReaderShortcutBinding]

    public static let `default` = ReaderShortcutBindings(storage: Self.defaultStorage)

    public init() {
        self = .default
    }

    private init(storage: [ReaderShortcutAction: ReaderShortcutBinding]) {
        self.storage = storage
    }

    public subscript(action: ReaderShortcutAction) -> ReaderShortcutBinding {
        storage[action] ?? Self.defaultStorage[action]
            ?? ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyC))
    }

    public func action(for combo: ReaderShortcutCombo) -> ReaderShortcutAction? {
        for action in ReaderShortcutAction.allCases where self[action].combo == combo {
            return action
        }
        return nil
    }

    public var isDefault: Bool {
        ReaderShortcutAction.allCases.allSatisfy { self[$0] == Self.defaultStorage[$0] }
    }

    /// 分配组合键；若已被其他动作占用则抛错并保持原状。
    ///
    /// 带修饰键（`⌘ ⇧ ⌥ ⌃`）的组合视为明确意图，自动关闭「防误触」；
    /// 裸键保留动作当前的防误触设置。用户仍可在弹层里手动改回。
    public mutating func setKey(
        _ combo: ReaderShortcutCombo,
        for action: ReaderShortcutAction
    ) throws {
        if let existing = self.action(for: combo), existing != action {
            throw UpdateError.duplicate(existing)
        }
        storage[action] = ReaderShortcutBinding(
            combo: combo,
            requiresConfirmation: combo.hasModifiers
                ? false
                : self[action].requiresConfirmation
        )
    }

    public mutating func setRequiresConfirmation(
        _ value: Bool,
        for action: ReaderShortcutAction
    ) {
        storage[action] = ReaderShortcutBinding(
            combo: self[action].combo,
            requiresConfirmation: value
        )
    }

    public mutating func reset(_ action: ReaderShortcutAction) {
        storage[action] = Self.defaultStorage[action]
    }

    public mutating func resetAll() {
        storage = Self.defaultStorage
    }

    // MARK: - Codable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var raw: [String: ReaderShortcutBinding] = [:]
        for action in ReaderShortcutAction.allCases {
            raw[action.rawValue] = self[action]
        }
        try container.encode(raw)
    }

    /// 合并解码：只接受已知动作且不与其他绑定冲突的条目，其余回落到默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: ReaderShortcutBinding].self)
        var result = ReaderShortcutBindings.default
        for action in ReaderShortcutAction.allCases {
            guard let binding = raw[action.rawValue] else { continue }
            if let existing = result.action(for: binding.combo), existing != action { continue }
            result.storage[action] = binding
        }
        self = result
    }

    // MARK: - Defaults

    private static let defaultStorage: [ReaderShortcutAction: ReaderShortcutBinding] = [
        .toggleBilingual: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyC)),
        .showSummary: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyV)),
        .previousArticle: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyK)),
        .nextArticle: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyJ)),
        .toggleStar: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyM)),
        .toggleFullScreen: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyF)),
        .openOriginal: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .keyO)),
        .scrollDown: ReaderShortcutBinding(combo: ReaderShortcutCombo(base: .space))
    ]
}
