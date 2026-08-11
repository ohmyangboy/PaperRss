import Foundation

public enum ReaderShortcutAction: String, CaseIterable, Sendable, Equatable {
    case toggleBilingual
    case showSummary
    case previousArticle
    case nextArticle
    case toggleStar
}

public struct ReaderShortcutInvocation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let action: ReaderShortcutAction

    public init(id: UUID = UUID(), action: ReaderShortcutAction) {
        self.id = id
        self.action = action
    }
}

public enum ReaderShortcutPolicy {
    public static func action(
        for charactersIgnoringModifiers: String?,
        hasDisallowedModifiers: Bool = false,
        isRepeat: Bool = false
    ) -> ReaderShortcutAction? {
        guard !hasDisallowedModifiers,
              !isRepeat,
              let key = charactersIgnoringModifiers?.lowercased(),
              key.count == 1 else { return nil }
        switch key {
        case "c": return .toggleBilingual
        case "v": return .showSummary
        case "b": return .previousArticle
        case "n": return .nextArticle
        case "m": return .toggleStar
        default: return nil
        }
    }
}

public struct ReaderNavigationConfirmation: Sendable {
    public enum Key: Sendable, Equatable {
        case spaceNextArticle
        case previousArticle
        case nextArticle
    }

    public enum Result: Sendable, Equatable {
        case armed
        case confirmed
    }

    public struct Pending: Sendable, Equatable {
        public let action: Key
        public let entryID: String
        public let expiresAt: TimeInterval
    }

    public private(set) var pending: Pending?
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 2.5) {
        self.timeout = timeout
    }

    public mutating func register(
        _ action: Key,
        entryID: String,
        at timestamp: TimeInterval
    ) -> Result {
        if let pending,
           pending.action == action,
           pending.entryID == entryID,
           timestamp <= pending.expiresAt {
            self.pending = nil
            return .confirmed
        }

        pending = Pending(
            action: action,
            entryID: entryID,
            expiresAt: timestamp + timeout
        )
        return .armed
    }

    public mutating func cancel() {
        pending = nil
    }
}
