#if os(macOS)
import Foundation
import Sparkle
#if SWIFT_PACKAGE
import PaperRssCore
import PaperRssUpdateSupport
#endif

/// 自定义 SPUUserDriver 适配器：Sparkle 保持下载、验签、暂存、安装与重启的
/// 全部权威；本类只把公开生命周期投影为 UpdateSupport 事件，并把用户意图
/// （开始下载 / 重启安装）作为一次性能力回传给 Sparkle。
/// 直接创建 SPUUpdater + 本 driver，不使用任何 Sparkle 标准窗口控制器。
///
/// 线程模型：Sparkle 在主线程调用 driver/delegate 回调；桥接类以
/// MainActor.assumeIsolated 转发，保证状态机全部运行在主 actor。
@MainActor
final class SparkleUpdaterAdapter: NSObject, UpdaterPort {
    var eventHandler: ((UpdaterEvent) -> Void)?

    private let configuration: SparkleConfiguration
    private var selectedChannel: UpdateChannel = .stable
    private var feedURLString: String
    private var isStarted = false

    // 受状态机约束的一次性能力（exactly-once 消费）。
    private var pendingFoundReply: ((SPUUserUpdateChoice) -> Void)?
    private var pendingReadyReply: Reply?
    private var pendingCheckCancellation: (() -> Void)?
    private var pendingDownloadCancellation: (() -> Void)?
    private var activeRelease: UpdateRelease?

    // 安装语义：胶囊点击 = 安装并重启；正常退出补装 = 静默安装不重开。
    private var wantsRelaunchAfterInstall = true
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    fileprivate let bridge = SPUDriverBridge()
    private lazy var updater = SPUUpdater(
        hostBundle: Bundle.main,
        applicationBundle: Bundle.main,
        userDriver: bridge,
        delegate: bridge
    )

    /// showReadyToInstallAndRelaunch 的回复签名在 2.9.x 为 SPUUserUpdateChoice。
    typealias Reply = (SPUUserUpdateChoice) -> Void

    init(configuration: SparkleConfiguration) {
        self.configuration = configuration
        feedURLString = configuration.stableFeedURL.absoluteString
        super.init()
        bridge.attach(self)
    }

    // MARK: - UpdaterPort

    func start() throws {
        guard !isStarted else { return }
        // 自动节奏由 UpdateCoordinator 的日检查策略驱动，这里关闭 Sparkle
        // 自身的周期检查，避免双重事实来源。
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        try updater.start()
        isStarted = true
    }

    func checkForUpdates(userInitiated: Bool) {
        // 统一走用户主动路径（SPUUserInitiatedUpdateDriver）：它保证
        // showErrorToUser:YES——无更新回调 showUpdateNotFound、失败回调
        // showUpdaterError，每个检查必然以状态机事件收尾。
        // 后台路径（SPUScheduledUpdateDriver）在展示更新前会静默吞掉
        // 失败（404 等），会让胶囊永远停在“检查中”。
        updater.checkForUpdates()
    }

    func beginDownload() throws {
        guard let reply = pendingFoundReply else {
            throw UpdateInteractionFailure(message: I18N.shared.localized(
                "当前没有可开始的更新下载。",
                "There is no update download to begin."
            ))
        }
        pendingFoundReply = nil
        reply(.install)
    }

    func installAndRelaunch() throws {
        guard let reply = pendingReadyReply else {
            throw UpdateInteractionFailure(message: I18N.shared.localized(
                "当前没有已就绪的更新可安装。",
                "There is no ready-to-install update."
            ))
        }
        pendingReadyReply = nil
        wantsRelaunchAfterInstall = true
        reply(.install)
    }

    func cancelActiveOperation() {
        pendingCheckCancellation?()
        pendingDownloadCancellation?()
    }

    func selectChannel(_ channel: UpdateChannel) throws {
        let feedURL: URL
        do {
            feedURL = try configuration.feedURL(for: channel)
        } catch SparkleConfigurationError.missingBetaFeedURL {
            throw UpdateConfigurationFailure(message: I18N.shared.localized(
                "此构建尚未配置 HTTPS Beta 更新源。请切回 Stable 通道。",
                "This build does not have an HTTPS Beta update feed configured. Switch back to the Stable channel."
            ))
        }
        let changed = selectedChannel != channel || feedURLString != feedURL.absoluteString
        selectedChannel = channel
        feedURLString = feedURL.absoluteString
        if changed, isStarted {
            updater.resetUpdateCycle()
        }
    }

    // MARK: - 主线程处理函数（由桥接类转发）

    fileprivate func handlePermissionRequest(reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 零权限弹窗硬门槛：自动接受自动检查授权，绝不弹系统式询问。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    fileprivate func handleUserInitiatedCheck(cancellation: @escaping () -> Void) {
        pendingCheckCancellation = cancellation
    }

    fileprivate func handleUpdateFound(
        _ item: SUAppcastItem,
        stage: SPUUserUpdateStage,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let release = register(releaseFrom: item)
        pendingFoundReply = reply
        switch stage {
        case .downloaded:
            // 上次会话已下载完成（中断恢复）：直接进入就绪态。
            eventHandler?(.readyToInstall(release))
        case .installing:
            eventHandler?(.installing(release))
        default:
            eventHandler?(.updateAvailable(release))
        }
    }

    fileprivate func handleUpdateNotFound() {
        pendingCheckCancellation = nil
        eventHandler?(.noUpdate)
    }

    fileprivate func handleUpdaterError(_ message: String) {
        pendingCheckCancellation = nil
        pendingDownloadCancellation = nil
        eventHandler?(.failed(message: message))
    }

    fileprivate func handleDownloadInitiated(cancellation: @escaping () -> Void) {
        pendingDownloadCancellation = cancellation
        expectedContentLength = 0
        receivedContentLength = 0
        emitIndeterminateDownloadProgress()
    }

    fileprivate func handleExpectedContentLength(_ length: UInt64) {
        expectedContentLength = length
        emitDownloadProgress(fractionCompleted: length > 0 ? 0 : nil)
    }

    fileprivate func handleReceivedContentLength(_ length: UInt64) {
        receivedContentLength += length
        emitDownloadProgress(fractionCompleted: downloadFraction())
    }

    fileprivate func handleExtractionStarted() {
        pendingDownloadCancellation = nil
        guard let activeRelease else { return }
        eventHandler?(.preparing(UpdatePreparation(release: activeRelease, fractionCompleted: 0)))
    }

    fileprivate func handleExtractionProgress(_ progress: Double) {
        guard let activeRelease else { return }
        eventHandler?(.preparing(UpdatePreparation(
            release: activeRelease,
            fractionCompleted: min(max(progress, 0), 1)
        )))
    }

    fileprivate func handleReadyToInstall(reply: @escaping Reply) {
        pendingReadyReply = reply
        if let activeRelease {
            eventHandler?(.readyToInstall(activeRelease))
        }
    }

    fileprivate func handleInstallingUpdate() {
        if let activeRelease {
            eventHandler?(.installing(activeRelease))
        }
    }

    fileprivate func handleInstallationDismissed() {
        // 会话被框架收尾：只回收一次性能力，状态保持由下一次检查驱动。
        resetCapabilities()
    }

    fileprivate func handleFeedURL(for updater: SPUUpdater) -> String? {
        feedURLString
    }

    fileprivate func handleAllowedChannels(for updater: SPUUpdater) -> Set<String> {
        selectedChannel == .beta ? ["beta"] : []
    }

    fileprivate func handleShouldRelaunch() -> Bool {
        wantsRelaunchAfterInstall
    }

    /// 正常退出时有已就绪/已暂存更新 → 静默安装，不自动重开。
    fileprivate func handleWillInstallOnQuit(
        item: SUAppcastItem,
        immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let release = register(releaseFrom: item)
        wantsRelaunchAfterInstall = false
        eventHandler?(.deferredUntilQuit(release))
        immediateInstallHandler()
        return true
    }

    // MARK: - 私有

    private func emitIndeterminateDownloadProgress() {
        guard let activeRelease else { return }
        eventHandler?(.downloading(UpdateDownloadProgress(
            release: activeRelease,
            fractionCompleted: nil
        )))
    }

    private func emitDownloadProgress(fractionCompleted: Double?) {
        guard let activeRelease else { return }
        eventHandler?(.downloading(UpdateDownloadProgress(
            release: activeRelease,
            fractionCompleted: fractionCompleted
        )))
    }

    private func downloadFraction() -> Double? {
        guard expectedContentLength > 0 else { return nil }
        return min(Double(receivedContentLength) / Double(expectedContentLength), 1)
    }

    private func resetCapabilities() {
        pendingFoundReply = nil
        pendingReadyReply = nil
        pendingCheckCancellation = nil
        pendingDownloadCancellation = nil
    }

    private func register(releaseFrom item: SUAppcastItem) -> UpdateRelease {
        let release = UpdateRelease(
            version: item.versionString,
            displayVersion: item.displayVersionString,
            releaseNotes: item.itemDescription,
            isCritical: item.isCriticalUpdate
        )
        activeRelease = release
        return release
    }
}

/// 非 MainActor 的 @objc 桥接层：满足 Sparkle 的 @objc 协议，
/// 并把（保证发生在主线程的）回调转发回适配器。
final class SPUDriverBridge: NSObject {
    fileprivate private(set) weak var adapter: SparkleUpdaterAdapter?

    fileprivate func attach(_ adapter: SparkleUpdaterAdapter) {
        self.adapter = adapter
    }

    private func withAdapter<T: Sendable>(_ body: @MainActor (SparkleUpdaterAdapter) -> T) -> T? {
        guard let adapter else { return nil }
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated {
            body(adapter)
        }
    }
}

extension SPUDriverBridge: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        withAdapter { $0.handlePermissionRequest(reply: reply) }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        withAdapter { $0.handleUserInitiatedCheck(cancellation: cancellation) }
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        withAdapter { $0.handleUpdateFound(appcastItem, stage: state.stage, reply: reply) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // 发布说明来自 appcast item 描述，无需二次下载渲染。
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // 说明下载失败不影响更新会话。
    }

    func showUpdateNotFoundWithError(_ error: Error) async {
        withAdapter { $0.handleUpdateNotFound() }
    }

    func showUpdaterError(_ error: Error) async {
        withAdapter { $0.handleUpdaterError(error.localizedDescription) }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        withAdapter { $0.handleDownloadInitiated(cancellation: cancellation) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        withAdapter { $0.handleExpectedContentLength(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        withAdapter { $0.handleReceivedContentLength(length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        withAdapter { $0.handleExtractionStarted() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        withAdapter { $0.handleExtractionProgress(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        withAdapter { $0.handleReadyToInstall(reply: reply) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        withAdapter { $0.handleInstallingUpdate() }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        // 安装完成即应用重启；无成功通知（证据 = 胶囊消失 + 版本号）。
    }

    func dismissUpdateInstallation() {
        withAdapter { $0.handleInstallationDismissed() }
    }

    func showUpdateInFocus() {
        // 胶囊常驻侧边栏底部，无需额外聚焦动作。
    }
}

extension SPUDriverBridge: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        withAdapter { $0.handleFeedURL(for: updater) } ?? nil
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        withAdapter { $0.handleAllowedChannels(for: updater) } ?? []
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        withAdapter { $0.handleShouldRelaunch() } ?? true
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        withAdapter { $0.handleWillInstallOnQuit(item: item, immediateInstallHandler: immediateInstallHandler) } ?? false
    }
}

// MARK: - 配置（fail-closed）

struct SparkleConfiguration {
    let stableFeedURL: URL
    let betaFeedURL: URL?

    init(stableFeedURLString: String?, betaFeedURLString: String?, publicKey: String?) throws {
        guard
            let stableFeedURLString,
            let stableFeedURL = Self.httpsURL(from: stableFeedURLString)
        else {
            throw SparkleConfigurationError.invalidFeedURL
        }
        guard let publicKey, !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SparkleConfigurationError.missingPublicKey
        }
        self.stableFeedURL = stableFeedURL
        betaFeedURL = betaFeedURLString.flatMap(Self.httpsURL(from:))
    }

    init(bundle: Bundle) throws {
        try self.init(
            stableFeedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            betaFeedURLString: bundle.object(forInfoDictionaryKey: "SUBetaFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }

    func feedURL(for channel: UpdateChannel) throws -> URL {
        switch channel {
        case .stable:
            stableFeedURL
        case .beta:
            try betaFeedURL ?? { throw SparkleConfigurationError.missingBetaFeedURL }()
        }
    }

    private static func httpsURL(from string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }
}

private enum SparkleConfigurationError: LocalizedError {
    case invalidFeedURL
    case missingPublicKey
    case missingBetaFeedURL

    var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            "The stable update feed must use HTTPS."
        case .missingPublicKey:
            "The Sparkle update signing public key is missing."
        case .missingBetaFeedURL:
            "The beta update feed must use HTTPS before the Beta channel can be selected."
        }
    }
}

private struct UpdateConfigurationFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct UpdateInteractionFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
private final class UnavailableUpdaterPort: UpdaterPort {
    var eventHandler: ((UpdaterEvent) -> Void)?

    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func start() throws {
        throw error
    }

    func checkForUpdates(userInitiated: Bool) throws {
        throw error
    }

    func beginDownload() throws {
        throw error
    }

    func installAndRelaunch() throws {
        throw error
    }

    func cancelActiveOperation() {}

    func selectChannel(_ channel: UpdateChannel) throws {
        throw error
    }
}

@MainActor
enum UpdateCoordinatorFactory {
    static let fallbackURL = URL(string: "https://github.com/ohmyangboy/PaperRss/releases")!

    static func make(bundle: Bundle = .main) -> UpdateCoordinator {
        let preferences = UserDefaultsUpdatePreferences(defaults: .standard)
        do {
            let configuration = try SparkleConfiguration(bundle: bundle)
            return UpdateCoordinator(
                updater: SparkleUpdaterAdapter(configuration: configuration),
                fallbackURL: fallbackURL,
                preferences: preferences
            )
        } catch let configurationError as SparkleConfigurationError {
            let message: String
            switch configurationError {
            case .invalidFeedURL:
                message = I18N.shared.localized(
                    "此构建尚未配置 HTTPS 更新源。请使用发布页手动下载。",
                    "This build does not have an HTTPS update feed configured. Download manually from the release page."
                )
            case .missingPublicKey:
                message = I18N.shared.localized(
                    "此构建尚未配置更新签名公钥。请使用发布页手动下载。",
                    "This build does not have an update signing public key configured. Download manually from the release page."
                )
            case .missingBetaFeedURL:
                message = I18N.shared.localized(
                    "此构建尚未配置 HTTPS Beta 更新源。请切回 Stable 通道。",
                    "This build does not have an HTTPS Beta update feed configured. Switch back to the Stable channel."
                )
            }
            return makeUnavailable(message: message, preferences: preferences)
        } catch {
            return makeUnavailable(
                message: error.localizedDescription,
                preferences: preferences
            )
        }
    }

    private static func makeUnavailable(
        message: String,
        preferences: any UpdatePreferencesPort
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            updater: UnavailableUpdaterPort(error: UpdateConfigurationFailure(message: message)),
            fallbackURL: fallbackURL,
            preferences: preferences
        )
    }
}

@MainActor
private final class UserDefaultsUpdatePreferences: UpdatePreferencesPort {
    private static let channelKey = "PaperRss.UpdateChannel"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadChannel() -> UpdateChannel? {
        defaults.string(forKey: Self.channelKey).flatMap(UpdateChannel.init(rawValue:))
    }

    func saveChannel(_ channel: UpdateChannel) {
        defaults.set(channel.rawValue, forKey: Self.channelKey)
    }
}

#endif
