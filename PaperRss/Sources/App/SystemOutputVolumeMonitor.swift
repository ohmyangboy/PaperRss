#if os(macOS)
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

/// 只保留实时强度；原始系统音频不保存、不上传，也不接触麦克风。
@MainActor
final class SystemOutputVolumeMonitor: ObservableObject {
    static let shared = SystemOutputVolumeMonitor()
    @Published private(set) var levels = Array(repeating: CGFloat.zero, count: 32)
    @Published private(set) var captureFailed = false
    var level: CGFloat { levels.last ?? 0 }
    private var capture: SystemAudioTap?
    private var timer: Timer?
    private var preferenceObserver: AnyCancellable?
    private var enabled = false
    private var envelope = AudioWaveEnvelope()

    private init() {
        preferenceObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.synchronizePreference() }
            }
        synchronizePreference()
    }

    func synchronizePreference() {
        let next = UserDefaults.standard.bool(forKey: "reader_audio_wave_enabled")
        guard next != enabled else { return }
        enabled = next
        timer?.invalidate(); timer = nil
        let previous = capture
        capture = nil
        if let previous { Task { await previous.stop() } }
        envelope = AudioWaveEnvelope()
        levels = Array(repeating: 0, count: 32)
        captureFailed = false
        guard next else { return }
        guard #available(macOS 14.2, *) else { captureFailed = true; return }
        let source = SystemAudioTap()
        capture = source
        Task { [weak self] in
            do {
                try await source.start()
                guard let self, self.enabled, self.capture === source else {
                    await source.stop()
                    return
                }
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            } catch {
                await source.stop()
                guard let self, self.capture === source else { return }
                self.capture = nil
                self.captureFailed = true
            }
        }
    }

    private func refresh() {
        let next = envelope.advance(rms: capture?.consumeRMS() ?? 0)
        if next != levels { levels = next }
    }
}

/// 快速响应瞬态、平滑回落；各刻度显示过去约一秒的真实能量。
struct AudioWaveEnvelope {
    private var current: CGFloat = 0
    private var recentPeak = 0.08
    private var history = Array(repeating: CGFloat.zero, count: 32)
    mutating func advance(rms: Double) -> [CGFloat] {
        let energy = rms.isFinite ? min(1, max(0, rms)) : 0
        // 以近期真实峰值为参照，避免对数压缩让音乐长期挤在高位。
        // 峰值缓慢下降，弱拍收短、强拍抬高；不引入周期或随机运动。
        recentPeak = max(0.02, energy, recentPeak * 0.995)
        let relative = min(1, max(0, (energy / recentPeak - 0.25) / 0.75))
        let target = energy > 0.001 ? CGFloat(pow(relative, 1.4)) : 0
        current += (target - current) * (target > current ? 0.9 : 0.45)
        if current < 0.002 { current = 0 }
        history.removeFirst()
        history.append(current)
        return history
    }
}

/// Core Audio 回调与主线程仅交换累积能量，锁内不做音频处理。
private final class AudioEnergyAccumulator: Sendable {
    private struct State { var squares = 0.0; var count = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func receive(_ input: UnsafePointer<AudioBufferList>) {
        var sum = 0.0, count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<n {
                let sample = Double(samples[index])
                if sample.isFinite { sum += sample * sample; count += 1 }
            }
        }
        state.withLock { [sum, count] in $0.squares += sum; $0.count += count }
    }
    func consume() -> Double {
        state.withLock {
            let rms = $0.count > 0 ? sqrt($0.squares / Double($0.count)) : 0
            $0 = State()
            return rms
        }
    }
}

/// 启停可能等待系统授权，由独立 actor 执行，不能阻塞阅读界面。
private actor SystemAudioTap {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let energy = AudioEnergyAccumulator()
    private struct CaptureError: Error { let status: OSStatus }
    private func check(_ status: OSStatus) throws {
        if status != noErr { throw CaptureError(status: status) }
    }

    @available(macOS 14.2, *)
    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "PaperRss 阅读音浪"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap))
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { throw CaptureError(status: -1) }
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PaperRss 阅读音浪",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &device))
        let energy = energy
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { @Sendable _, input, _, _, _ in
            energy.receive(input)
        })
        try check(AudioDeviceStart(device, io))
    }

    nonisolated func consumeRMS() -> Double { energy.consume() }
    func stop() {
        if let io {
            AudioDeviceStop(device, io)
            AudioDeviceDestroyIOProcID(device, io)
        }
        io = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if #available(macOS 14.2, *), tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
}
#endif
