import Foundation
import Combine

/// Stable / Beta 更新通道。Stable 是默认通道；Beta 需要构建注入 SUBetaFeedURL 才能选择。
public enum UpdateChannel: String, CaseIterable, Equatable, Sendable {
    case stable
    case beta
}

@MainActor
public protocol UpdatePreferencesPort: AnyObject {
    func loadChannel() -> UpdateChannel?
    func saveChannel(_ channel: UpdateChannel)
}

public struct UpdateRelease: Equatable, Sendable {
    public let version: String
    public let displayVersion: String
    public let releaseNotes: String?
    public let isCritical: Bool

    public init(
        version: String,
        displayVersion: String,
        releaseNotes: String?,
        isCritical: Bool = false
    ) {
        self.version = version
        self.displayVersion = displayVersion
        self.releaseNotes = releaseNotes
        self.isCritical = isCritical
    }
}

/// 下载进度；`fractionCompleted == nil` 表示总量未知（不确定进度）。
public struct UpdateDownloadProgress: Equatable, Sendable {
    public let release: UpdateRelease
    public let fractionCompleted: Double?

    public init(release: UpdateRelease, fractionCompleted: Double?) {
        self.release = release
        self.fractionCompleted = fractionCompleted
    }
}

/// 解压/准备安装进度，取值 0...1。
public struct UpdatePreparation: Equatable, Sendable {
    public let release: UpdateRelease
    public let fractionCompleted: Double

    public init(release: UpdateRelease, fractionCompleted: Double) {
        self.release = release
        self.fractionCompleted = fractionCompleted
    }
}

public struct UpdateFailure: Equatable, Sendable {
    public let message: String
    public let fallbackURL: URL

    public init(message: String, fallbackURL: URL) {
        self.message = message
        self.fallbackURL = fallbackURL
    }
}

/// 两段式交互的状态集：空闲 → 检查 → 可用 → 下载 → 准备 → 就绪 → 安装/重启。
/// 没有 skip / dismiss / 标准窗口投影；左下角胶囊是唯一入口。
public enum UpdateState: Equatable {
    case idle
    case checking
    /// 冷启动静默检查：胶囊不渲染转圈，无更新时不产生任何提示。
    case checkingSilently
    case upToDate(checkedAt: Date)
    case updateAvailable(UpdateRelease)
    case downloading(UpdateDownloadProgress)
    case preparing(UpdatePreparation)
    case readyToInstall(UpdateRelease)
    case installing(UpdateRelease)
    case relaunching(UpdateRelease)
    case deferredUntilQuit(UpdateRelease)
    case failed(UpdateFailure)

    /// 会话是否活跃（活跃期间禁止切换通道、合并并发检查请求）。
    public var isActiveSession: Bool {
        switch self {
        case .idle, .upToDate, .failed:
            false
        case .checking, .checkingSilently, .updateAvailable, .downloading, .preparing,
             .readyToInstall, .installing, .relaunching, .deferredUntilQuit:
            true
        }
    }

    /// 胶囊主按钮语义。
    public var primaryAction: UpdatePrimaryAction {
        switch self {
        case .idle, .upToDate, .failed, .checking, .checkingSilently:
            .checkForUpdates
        case .updateAvailable:
            .download
        case .downloading, .preparing:
            .none
        case .readyToInstall:
            .installAndRelaunch
        case .installing, .relaunching, .deferredUntilQuit:
            .none
        }
    }
}

public enum UpdatePrimaryAction: Equatable, Sendable {
    case checkForUpdates
    case download
    case installAndRelaunch
    case none
}

public enum UpdaterEvent: Equatable, Sendable {
    case noUpdate
    case updateAvailable(UpdateRelease)
    case downloading(UpdateDownloadProgress)
    case preparing(UpdatePreparation)
    case readyToInstall(UpdateRelease)
    case installing(UpdateRelease)
    case relaunching(UpdateRelease)
    case deferredUntilQuit(UpdateRelease)
    case failed(message: String)
}

/// 更新器端口：App 层唯一可注入的更新会话边界。实现方负责把底层框架
/// （Sparkle）的公开生命周期映射为上述事件；候选回复是一次性能力，
/// 由 beginDownload/installAndRelaunch 恰好消费一次。
@MainActor
public protocol UpdaterPort: AnyObject {
    var eventHandler: ((UpdaterEvent) -> Void)? { get set }

    func start() throws
    func checkForUpdates(userInitiated: Bool) throws
    func beginDownload() throws
    func installAndRelaunch() throws
    func cancelActiveOperation()
    func selectChannel(_ channel: UpdateChannel) throws
}

// MARK: - 协调器

@MainActor
public final class UpdateCoordinator: ObservableObject {
    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var channel: UpdateChannel
    @Published public private(set) var lastUpToDateNoticeAt: Date?

    private let updater: any UpdaterPort
    private let fallbackURL: URL
    private let preferences: any UpdatePreferencesPort
    private var now: () -> Date
    private var hasStarted = false

    public convenience init(updater: any UpdaterPort, fallbackURL: URL) {
        self.init(
            updater: updater,
            fallbackURL: fallbackURL,
            preferences: VolatileUpdatePreferences()
        )
    }

    public init(
        updater: any UpdaterPort,
        fallbackURL: URL,
        preferences: any UpdatePreferencesPort,
        now: @escaping () -> Date = { Date() }
    ) {
        self.updater = updater
        self.fallbackURL = fallbackURL
        self.preferences = preferences
        self.now = now
        channel = preferences.loadChannel() ?? .stable
        updater.eventHandler = { [weak self] event in
            self?.receive(event)
        }
        do {
            try updater.selectChannel(channel)
        } catch {
            applyFailure(error.localizedDescription)
        }
    }

    // MARK: 生命周期

    /// 启动长生命周期会话（幂等）。每次冷启动（进程从无到有）执行一次检查；
    /// 回前台不触发检查。手动检查随时可用且不受此限制。
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            try updater.start()
        } catch {
            applyFailure(error.localizedDescription)
            return
        }
        initiateCheck(userInitiated: false)
    }

    // MARK: 用户意图

    /// 手动检查。会话活跃期间合并（忽略）重复请求；若正在静默检查，
    /// 将其提升为可见检查（结果按手动检查呈现，含无更新提示）。
    public func checkForUpdates() {
        if case .checkingSilently = state {
            state = .checking
            return
        }
        guard !state.isActiveSession else { return }
        initiateCheck(userInitiated: true)
    }

    /// 第一段：开始下载可用更新。
    public func beginDownload() {
        guard case let .updateAvailable(release) = state else { return }
        do {
            try updater.beginDownload()
            state = .downloading(UpdateDownloadProgress(release: release, fractionCompleted: nil))
        } catch {
            applyFailure(error.localizedDescription)
        }
    }

    /// 第二段：重启并安装已就绪更新。
    public func installAndRelaunch() {
        guard case let .readyToInstall(release) = state else { return }
        do {
            try updater.installAndRelaunch()
            state = .installing(release)
        } catch {
            applyFailure(error.localizedDescription)
        }
    }

    /// 取消当前检查/下载（若底层支持）。
    public func cancelActiveOperation() {
        updater.cancelActiveOperation()
        if case .checking = state {
            state = .idle
        }
    }

    /// 关闭失败态胶囊（回到空闲，不产生任何更新会话副作用）。
    public func dismissFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    public var canChangeChannel: Bool {
        !state.isActiveSession
    }

    public func selectChannel(_ newChannel: UpdateChannel) {
        guard canChangeChannel, newChannel != channel else { return }
        do {
            try updater.selectChannel(newChannel)
            preferences.saveChannel(newChannel)
            channel = newChannel
        } catch {
            applyFailure(error.localizedDescription)
        }
    }

    // MARK: 私有

    private func initiateCheck(userInitiated: Bool) {
        state = userInitiated ? .checking : .checkingSilently
        do {
            try updater.checkForUpdates(userInitiated: userInitiated)
        } catch {
            applyFailure(error.localizedDescription)
        }
    }

    private func receive(_ event: UpdaterEvent) {
        switch event {
        case .noUpdate:
            let wasUserInitiated = state == .checking
            state = .upToDate(checkedAt: now())
            if wasUserInitiated {
                lastUpToDateNoticeAt = now()
            }
        case let .updateAvailable(release):
            state = .updateAvailable(release)
        case let .downloading(progress):
            state = .downloading(progress)
        case let .preparing(preparation):
            state = .preparing(preparation)
        case let .readyToInstall(release):
            state = .readyToInstall(release)
        case let .installing(release):
            state = .installing(release)
        case let .relaunching(release):
            state = .relaunching(release)
        case let .deferredUntilQuit(release):
            state = .deferredUntilQuit(release)
        case let .failed(message):
            applyFailure(message)
        }
    }

    private func applyFailure(_ message: String) {
        state = .failed(.init(message: message, fallbackURL: fallbackURL))
    }
}

@MainActor
private final class VolatileUpdatePreferences: UpdatePreferencesPort {
    func loadChannel() -> UpdateChannel? { nil }
    func saveChannel(_ channel: UpdateChannel) {}
}
