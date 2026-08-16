import Foundation

/// 账号类型枚举。
public enum AccountType: String, Codable, Hashable, Sendable {
    case local
    case freshRSS = "freshrss"
}

/// 核心 Account 领域模型。
///
/// 遵循 Architecture Contract (Section 7 / INV-01)。
public struct Account: Identifiable, Hashable, Sendable {
    public let id: String
    public let type: AccountType
    public var displayName: String
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = "local-default",
        type: AccountType = .local,
        displayName: String = "本地订阅",
        isActive: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let localDefault = Account(
        id: "local-default",
        type: .local,
        displayName: "本地订阅",
        isActive: true
    )
}
