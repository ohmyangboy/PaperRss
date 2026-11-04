import Foundation

/// 可取消的延时等待。
///
/// 与 `Task.sleep` 的区别：取消不抛错，而是立即返回。`scheduleMissingIconProbe` 取消时只关心
/// 「不要再探测」，抛出 `CancellationError` 会被 XCTest 记成失败。
/// 取消早于 continuation 注册时也必须立即返回，不能把整个延时熬完。
final class CancellableDelayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isCancelled = false
    private var isFinished = false

    /// 最多等待 `delay` 秒；期间取消则立即返回。
    func wait(_ delay: TimeInterval) async {
        guard delay > 0 else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(continuation, delay: delay)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let pending = takePending()
        lock.unlock()
        pending?.resume()
    }

    /// 注册等待点；取消已先到或等待已结束时立即唤醒，不再排定时器。
    private func install(_ continuation: CheckedContinuation<Void, Never>, delay: TimeInterval) {
        lock.lock()
        guard !isCancelled, !isFinished else {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let pending = takePending()
            lock.unlock()
            pending?.resume()
        }
    }

    /// 调用方必须持锁；返回待唤醒的 continuation，并保证只唤醒一次。
    private func takePending() -> CheckedContinuation<Void, Never>? {
        guard !isFinished else { return nil }
        isFinished = true
        defer { continuation = nil }
        return continuation
    }
}
