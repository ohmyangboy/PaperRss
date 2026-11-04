import XCTest
@testable import PaperRssCore

final class CancellableDelayGateTests: XCTestCase {
    /// 取消必须立刻返回，不能把整个延时熬完（否则旧任务会一直占着 AppStore）。
    func testCancelReturnsImmediatelyInsteadOfFinishingDelay() async {
        let gate = CancellableDelayGate()
        let started = ContinuousClock.now
        let waiting = Task { await gate.wait(5) }
        try? await Task.sleep(for: .milliseconds(20))
        gate.cancel()
        _ = await waiting.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(2), "取消后不应继续等到 5 秒延时结束")
    }

    /// 取消早于注册也必须立刻返回：这正是上一版丢掉唤醒的场景。
    func testCancelBeforeRegistrationStillWakesTheWait() async {
        let gate = CancellableDelayGate()
        gate.cancel()
        let started = ContinuousClock.now
        await gate.wait(5)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "已经取消的等待不能阻塞在延时上")
    }

    /// 等待任务的父级被取消时，`withTaskCancellationHandler` 必须能叫醒它。
    func testTaskCancellationWakesTheDelay() async {
        let gate = CancellableDelayGate()
        let started = ContinuousClock.now
        let waiting = Task {
            await gate.wait(5)
        }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        _ = await waiting.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    /// 重复取消或取消后延时到期都只能唤醒一次，不能触发 continuation 二次 resume。
    func testRepeatedCancelAndExpiryWakeOnlyOnce() async {
        let gate = CancellableDelayGate()
        let waiting = Task { await gate.wait(0.05) }
        gate.cancel()
        gate.cancel()
        _ = await waiting.value
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// 零延时直接返回，不注册任何等待点。
    func testZeroDelayReturnsWithoutSuspending() async {
        let gate = CancellableDelayGate()
        await gate.wait(0)
        gate.cancel()
    }
}
