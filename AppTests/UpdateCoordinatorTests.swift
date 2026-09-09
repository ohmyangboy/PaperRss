import XCTest
#if SWIFT_PACKAGE
@testable import PaperRssUpdateSupport
#endif

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    // MARK: - 基础会话

    func testManualCheckPublishesCheckingThenUpToDate() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        coordinator.checkForUpdates()
        XCTAssertEqual(coordinator.state, .checking)

        updater.send(.noUpdate)
        guard case .upToDate = coordinator.state else {
            return XCTFail("Expected an up-to-date result")
        }
    }

    func testStartIsIdempotentAndKeepsOneLongLivedSession() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        coordinator.start()
        coordinator.start()

        XCTAssertEqual(updater.startCount, 1)
        XCTAssertEqual(updater.checkCount, 1, "冷启动检查只执行一次")
    }

    func testColdStartAlwaysChecksOnce() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        coordinator.start()

        XCTAssertEqual(updater.checkCount, 1, "每次冷启动必须检查一次，无日门禁")
        XCTAssertEqual(coordinator.state, .checkingSilently)
    }

    func testColdStartNoUpdateIsSilentWithoutToast() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        coordinator.start()
        updater.send(.noUpdate)

        guard case .upToDate = coordinator.state else {
            return XCTFail("Expected up-to-date")
        }
        XCTAssertNil(coordinator.lastUpToDateNoticeAt, "静默检查无更新不得产生提示")
    }

    func testManualCheckNoUpdateShowsToastNotice() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        coordinator.checkForUpdates()
        updater.send(.noUpdate)

        XCTAssertNotNil(coordinator.lastUpToDateNoticeAt, "手动检查无更新应产生约 3 秒提示")
    }

    func testManualCheckDuringSilentCheckPromotesToVisible() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        coordinator.start()
        XCTAssertEqual(coordinator.state, .checkingSilently)

        coordinator.checkForUpdates()
        XCTAssertEqual(coordinator.state, .checking, "手动检查应把静默会话提升为可见")

        updater.send(.noUpdate)
        XCTAssertNotNil(coordinator.lastUpToDateNoticeAt, "提升后的结果按手动检查呈现")
        XCTAssertEqual(updater.checkCount, 1, "不重复发起检查")
    }

    func testStartFailureLandsInFailedStateWithFallback() {
        let fallbackURL = URL(string: "https://example.com/releases")!
        let updater = FakeUpdaterPort(startError: TestUpdaterError.configurationMissing)
        let coordinator = UpdateCoordinator(
            updater: updater,
            fallbackURL: fallbackURL,
            preferences: FakeUpdatePreferences()
        )

        coordinator.start()

        XCTAssertEqual(
            coordinator.state,
            .failed(.init(message: "Software updates are not configured for this build.", fallbackURL: fallbackURL))
        )
    }

    // MARK: - 并发合并与会话互斥

    func testConcurrentManualChecksAreMergedWhileChecking() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        coordinator.checkForUpdates()
        coordinator.checkForUpdates()
        coordinator.checkForUpdates()

        XCTAssertEqual(updater.checkCount, 1)
    }

    func testManualCheckDuringActiveDownloadIsIgnored() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)
        let release = release("20")

        coordinator.checkForUpdates()
        updater.send(.updateAvailable(release))
        coordinator.beginDownload()
        updater.send(.downloading(UpdateDownloadProgress(release: release, fractionCompleted: 0.4)))

        coordinator.checkForUpdates()

        XCTAssertEqual(updater.checkCount, 1)
        XCTAssertEqual(coordinator.state, .downloading(UpdateDownloadProgress(release: release, fractionCompleted: 0.4)))
    }

    // MARK: - 两段式交互

    func testTwoStageFlowFromAvailableToReadyToRelaunch() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)
        let release = release("20")

        coordinator.checkForUpdates()
        updater.send(.updateAvailable(release))
        XCTAssertEqual(coordinator.state.primaryAction, .download)

        coordinator.beginDownload()
        XCTAssertTrue(updater.didBeginDownload)

        updater.send(.downloading(UpdateDownloadProgress(release: release, fractionCompleted: nil)))
        XCTAssertEqual(coordinator.state, .downloading(UpdateDownloadProgress(release: release, fractionCompleted: nil)))

        updater.send(.downloading(UpdateDownloadProgress(release: release, fractionCompleted: 0.7)))
        updater.send(.preparing(UpdatePreparation(release: release, fractionCompleted: 0.5)))
        XCTAssertEqual(coordinator.state.primaryAction, .none)

        updater.send(.readyToInstall(release))
        XCTAssertEqual(coordinator.state, .readyToInstall(release))
        XCTAssertEqual(coordinator.state.primaryAction, .installAndRelaunch)

        coordinator.installAndRelaunch()
        XCTAssertTrue(updater.didInstallAndRelaunch)
        XCTAssertEqual(coordinator.state, .installing(release))

        updater.send(.relaunching(release))
        XCTAssertEqual(coordinator.state, .relaunching(release))
    }

    func testQuitInstallPublishesDeferredUntilQuit() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)
        let release = release("20")

        updater.send(.deferredUntilQuit(release))

        XCTAssertEqual(coordinator.state, .deferredUntilQuit(release))
        XCTAssertFalse(coordinator.canChangeChannel)
    }

    func testDismissFailureReturnsToIdleWithoutSideEffects() {
        let updater = FakeUpdaterPort()
        let coordinator = makeCoordinator(updater: updater)

        updater.send(.failed(message: "feed unreachable"))
        guard case .failed = coordinator.state else {
            return XCTFail("Expected failed state")
        }

        coordinator.dismissFailure()
        XCTAssertEqual(coordinator.state, .idle)

        // 空闲态重复关闭是空操作
        coordinator.dismissFailure()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(updater.checkCount, 0)
    }

    // MARK: - 通道

    func testStableIsDefaultAndBetaSelectionPersistsAcrossSessions() {
        let preferences = FakeUpdatePreferences()
        let firstSession = makeCoordinator(updater: FakeUpdaterPort(), preferences: preferences)
        XCTAssertEqual(firstSession.channel, .stable)

        firstSession.selectChannel(.beta)
        XCTAssertEqual(firstSession.channel, .beta)

        let secondUpdater = FakeUpdaterPort()
        let secondSession = makeCoordinator(updater: secondUpdater, preferences: preferences)
        XCTAssertEqual(secondSession.channel, .beta)
        XCTAssertEqual(secondUpdater.selectedChannel, .beta)
    }

    func testChannelSwitchingIsBlockedForEveryActiveUpdateSessionState() {
        let updater = FakeUpdaterPort()
        let preferences = FakeUpdatePreferences()
        let coordinator = makeCoordinator(updater: updater, preferences: preferences)
        let release = release("20")

        coordinator.checkForUpdates()
        XCTAssertFalse(coordinator.canChangeChannel)

        for event in [
            UpdaterEvent.updateAvailable(release),
            .downloading(UpdateDownloadProgress(release: release, fractionCompleted: 0.2)),
            .preparing(UpdatePreparation(release: release, fractionCompleted: 0.9)),
            .readyToInstall(release),
            .installing(release),
            .relaunching(release),
            .deferredUntilQuit(release)
        ] {
            updater.send(event)
            XCTAssertFalse(coordinator.canChangeChannel, "Channel changed during \(event)")
        }
    }

    func testBetaSelectionFailsClosedWhenConfigurationRejectsIt() {
        let updater = FakeUpdaterPort(channelError: TestUpdaterError.configurationMissing)
        let preferences = FakeUpdatePreferences()
        let coordinator = makeCoordinator(updater: updater, preferences: preferences)

        coordinator.selectChannel(.beta)

        XCTAssertEqual(coordinator.channel, .stable)
        XCTAssertNil(preferences.loadChannel())
        guard case .failed = coordinator.state else {
            return XCTFail("Expected fail-closed state after channel rejection")
        }
    }

    // MARK: - 更新日志与重启跳转及关闭逻辑

    func testInstallAndRelaunchPersistsPendingChangelogNotice() {
        let updater = FakeUpdaterPort()
        let preferences = FakeUpdatePreferences()
        let coordinator = makeCoordinator(updater: updater, preferences: preferences)
        let release = release("20")

        updater.send(.readyToInstall(release))
        coordinator.installAndRelaunch()

        XCTAssertEqual(preferences.loadPendingChangelogNotice(), "2.0.0", "重启安装时必须持久化记录目标显示版本")
    }

    func testNextSessionLoadsPendingNoticeAndRetainsPersistenceUntilDismissed() {
        let preferences = FakeUpdatePreferences()
        preferences.savePendingChangelogNotice("2.0.0")

        let updater = FakeUpdaterPort()
        let nextSession = makeCoordinator(updater: updater, preferences: preferences, currentVersion: "2.0.0")

        XCTAssertEqual(nextSession.pendingChangelogNotice, "2.0.0", "新会话必须激活更新日志提示")
        XCTAssertEqual(preferences.loadPendingChangelogNotice(), "2.0.0", "用户未点击或关闭前，持久化必须保留以便下次重启继续展示")
    }

    func testDismissChangelogNoticeClearsInMemoryStateAndPersistence() {
        let preferences = FakeUpdatePreferences()
        preferences.savePendingChangelogNotice("2.0.0")

        let updater = FakeUpdaterPort()
        let session = makeCoordinator(updater: updater, preferences: preferences, currentVersion: "2.0.0")

        XCTAssertNotNil(session.pendingChangelogNotice)
        session.dismissChangelogNotice()
        XCTAssertNil(session.pendingChangelogNotice, "手动关闭后内存状态必须立即清空")
        XCTAssertNil(preferences.loadPendingChangelogNotice(), "手动关闭后持久化必须清空，确保之后不再展示")
    }

    func testSubsequentSessionRetainsNoticeIfNotDismissed() {
        let preferences = FakeUpdatePreferences()
        preferences.savePendingChangelogNotice("2.0.0")

        // 第一次会话启动：用户既没有跳转也没有手动关闭，直接退出
        let firstUpdater = FakeUpdaterPort()
        let firstSession = makeCoordinator(updater: firstUpdater, preferences: preferences, currentVersion: "2.0.0")
        XCTAssertEqual(firstSession.pendingChangelogNotice, "2.0.0")

        // 第二次会话启动：下次重启依旧保留
        let secondUpdater = FakeUpdaterPort()
        let secondSession = makeCoordinator(updater: secondUpdater, preferences: preferences, currentVersion: "2.0.0")
        XCTAssertEqual(secondSession.pendingChangelogNotice, "2.0.0", "若未点击跳转或关闭，下次重启依旧保留展示")
    }

    func testSubsequentSessionDoesNotShowAfterDismiss() {
        let preferences = FakeUpdatePreferences()
        preferences.savePendingChangelogNotice("2.0.0")

        // 第一次会话启动并手动关闭
        let firstUpdater = FakeUpdaterPort()
        let firstSession = makeCoordinator(updater: firstUpdater, preferences: preferences, currentVersion: "2.0.0")
        firstSession.dismissChangelogNotice()

        // 第二次会话启动：不再展示
        let secondUpdater = FakeUpdaterPort()
        let secondSession = makeCoordinator(updater: secondUpdater, preferences: preferences, currentVersion: "2.0.0")
        XCTAssertNil(secondSession.pendingChangelogNotice, "关闭后本次版本之后就不再展示")
    }

    func testCurrentVersionMismatchClearsStaleNotice() {
        let preferences = FakeUpdatePreferences()
        preferences.savePendingChangelogNotice("2.0.0")

        let updater = FakeUpdaterPort()
        // 假设更新失败，当前依然是旧版本 1.9.0
        let session = makeCoordinator(updater: updater, preferences: preferences, currentVersion: "1.9.0")

        XCTAssertNil(session.pendingChangelogNotice, "版本不匹配时不得激活更新日志提示")
        XCTAssertNil(preferences.loadPendingChangelogNotice(), "旧版本失效标记被安全清理")
    }

    // MARK: - Helpers

    private func makeCoordinator(
        updater: FakeUpdaterPort,
        preferences: any UpdatePreferencesPort = FakeUpdatePreferences(),
        currentVersion: String? = nil
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            updater: updater,
            fallbackURL: URL(string: "https://example.com/releases")!,
            preferences: preferences,
            currentVersion: currentVersion
        )
    }

    private func release(_ version: String) -> UpdateRelease {
        UpdateRelease(version: version, displayVersion: "2.0.0", releaseNotes: nil, isCritical: false)
    }
}

@MainActor
private final class FakeUpdaterPort: UpdaterPort {
    var eventHandler: ((UpdaterEvent) -> Void)?
    private let startError: Error?
    private let checkError: Error?
    private let channelError: Error?
    private(set) var startCount = 0
    private(set) var checkCount = 0
    private(set) var selectedChannel: UpdateChannel?
    private(set) var didBeginDownload = false
    private(set) var didInstallAndRelaunch = false

    init(
        startError: Error? = nil,
        checkError: Error? = nil,
        channelError: Error? = nil
    ) {
        self.startError = startError
        self.checkError = checkError
        self.channelError = channelError
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func checkForUpdates(userInitiated: Bool) throws {
        checkCount += 1
        if let checkError { throw checkError }
    }

    func beginDownload() throws {
        didBeginDownload = true
    }

    func installAndRelaunch() throws {
        didInstallAndRelaunch = true
    }

    func cancelActiveOperation() {}

    func selectChannel(_ channel: UpdateChannel) throws {
        if let channelError { throw channelError }
        selectedChannel = channel
    }

    func send(_ event: UpdaterEvent) {
        eventHandler?(event)
    }
}

@MainActor
private final class FakeUpdatePreferences: UpdatePreferencesPort {
    private var storedChannel: UpdateChannel?
    private var storedChangelogNotice: String?

    func loadChannel() -> UpdateChannel? {
        storedChannel
    }

    func saveChannel(_ channel: UpdateChannel) {
        storedChannel = channel
    }

    func loadPendingChangelogNotice() -> String? {
        storedChangelogNotice
    }

    func savePendingChangelogNotice(_ version: String?) {
        storedChangelogNotice = version
    }
}


private enum TestUpdaterError: LocalizedError {
    case configurationMissing

    var errorDescription: String? {
        "Software updates are not configured for this build."
    }
}
