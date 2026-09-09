import Foundation

/// 账号类型枚举。
public enum AccountType: String, Codable, Hashable, Sendable {
    case local
    case freshRSS
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

/// 刷新原因。
public enum RefreshReason: Sendable, Equatable {
    case launch
    case scheduled
    case manual
    case subscriptionManagement
    case userInitiated
}

/// 账号刷新结果。
public struct RefreshResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case success
        case failed(String)
        case notModified
    }
    public var status: Status

    public init(status: Status = .success) {
        self.status = status
    }
}

/// 账号服务提供者抽象协议。
///
/// 遵循 Architecture Contract (Section 7.2 / INV-01)。
public protocol AccountProvider: Sendable {
    var accountID: String { get }

    func refresh(reason: RefreshReason) async throws -> RefreshResult
    func pushPendingArticleStates() async throws

    // MARK: - 订阅与文件夹生命周期管理 (CRUD)
    func addFeed(url: URL, title: String?, folder: String?) async throws -> Feed
    func deleteFeed(feedID: UUID) async throws
    func addFolder(name: String) async throws -> FolderRecord
    func deleteFolder(name: String) async throws
}

/// 账号刷新进度；总量未知时显示准备状态，计数仅在落库批次完成后发布。
public struct AccountRefreshProgress: Sendable, Equatable {
    public enum Phase: Sendable { case preparing, downloading, reconciling }
    public let completed: Int
    public let total: Int?
    public let phase: Phase

    public init(completed: Int = 0, total: Int? = nil, phase: Phase? = nil) {
        self.completed = completed
        self.total = total
        self.phase = phase ?? (total == nil ? .preparing : .downloading)
    }

    public var fraction: Double? {
        guard phase == .downloading, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}
