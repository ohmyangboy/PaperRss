#if os(macOS)
import AudioToolbox
import Accelerate
import Combine
import CoreAudio
import Foundation
import os

/// 只在内存中保留短暂采样窗口用于频谱分析；系统音频不落盘、不上传，也不接触麦克风。
@MainActor
final class SystemOutputVolumeMonitor: ObservableObject {
    static let shared = SystemOutputVolumeMonitor()
    @Published private(set) var levels = Array(repeating: CGFloat.zero, count: AudioWaveSpectrum.barCount)
    @Published private(set) var captureFailed = false
    var level: CGFloat { levels.max() ?? 0 }
    private var capture: SystemAudioTap?
    private var timer: Timer?
    private var preferenceObserver: AnyCancellable?
    private var enabled = false
    private var spectrum = AudioWaveSpectrum()

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
        spectrum = AudioWaveSpectrum()
        levels = Array(repeating: 0, count: AudioWaveSpectrum.barCount)
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
        let next = spectrum.advance(frame: capture?.consumeFrame())
        if next != levels { levels = next }
    }
}

struct AudioSpectrumFrame: Sendable {
    let channels: [[Float]]
    let sampleRate: Double
}

/// 对短窗口做 FFT；频谱决定低频到高频的主体轮廓，细微摆动仅用于视觉呈现。
struct AudioWaveSpectrum {
    // 48 kHz 下约 43 ms，覆盖 30 Hz 刷新间隔，避免短促声音落在两次 FFT 之间。
    static let sampleCount = 2048
    static let barCount = 64
    private let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = (0..<sampleCount).map { index in
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(sampleCount - 1)))
    }
    private var displayed = Array(repeating: CGFloat.zero, count: barCount)
    private var variation = Array(repeating: CGFloat.zero, count: barCount)
    private var variationSeed: UInt64 = 0x9E3779B97F4A7C15
    private var recentPeakDecibels = -70.0

    mutating func advance(frame: AudioSpectrumFrame?) -> [CGFloat] {
        var decibelsByBar = Array(repeating: -160.0, count: Self.barCount)
        if let frame, frame.sampleRate > 0, let fft {
            let maxBin = min(Self.sampleCount / 2 - 1,
                Int(10_000 * Double(Self.sampleCount) / frame.sampleRate))
            if maxBin > 0 {
                let binWidth = frame.sampleRate / Double(Self.sampleCount)
                let topFrequency = min(10_000, Double(maxBin) * binWidth)
                let bottomFrequency = min(40.0, topFrequency / 2)
                let frequencyRatio = topFrequency / bottomFrequency
                for samples in frame.channels where samples.count == Self.sampleCount {
                    var real = zip(samples, window).map { $0 * $1 }
                    var imaginary = Array(repeating: Float.zero, count: Self.sampleCount)
                    var outputReal = imaginary
                    var outputImaginary = imaginary
                    real.withUnsafeMutableBufferPointer { realBuffer in
                        imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                            outputReal.withUnsafeMutableBufferPointer { outputRealBuffer in
                                outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryBuffer in
                                    let input = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                                    var output = DSPSplitComplex(realp: outputRealBuffer.baseAddress!, imagp: outputImaginaryBuffer.baseAddress!)
                                    fft.forward(input: input, output: &output)
                                }
                            }
                        }
                    }
                    for bar in decibelsByBar.indices {
                        let lowerFrequency = bottomFrequency * pow(frequencyRatio, Double(bar) / Double(Self.barCount))
                        let upperFrequency = bottomFrequency * pow(frequencyRatio, Double(bar + 1) / Double(Self.barCount))
                        let lower = max(1, min(maxBin, Int(ceil(lowerFrequency / binWidth))))
                        let upper = max(lower + 1, min(maxBin + 1, Int(ceil(upperFrequency / binWidth))))
                        var strongest: Float = 0
                        for bin in lower..<upper {
                            strongest = max(strongest, hypot(outputReal[bin], outputImaginary[bin]))
                        }
                        // Hann 窗的相干增益约 0.5；转换为与 getFloatFrequencyData 相同的 dB 尺度。
                        let amplitude = Double(strongest) * 4 / Double(Self.sampleCount)
                        // 补偿常见的频谱低频倾斜，避免少量可见刻度时第一根长期独占峰值。
                        let centerFrequency = sqrt(lowerFrequency * upperFrequency)
                        let compensation = min(12, max(0, 3 * log2(centerFrequency / 100)))
                        let decibels = 20 * log10(max(amplitude, 1e-10)) + compensation
                        decibelsByBar[bar] = max(decibelsByBar[bar], decibels)
                    }
                }
            }
        }
        let peak = decibelsByBar.max() ?? -160
        // 以近期实际峰值为参照，强拍立即抬起，弱拍仍保留相对落差。
        recentPeakDecibels = max(-70, peak, recentPeakDecibels - 0.45)
        let activity = min(1, max(0, (peak + 70) / 25))
        for index in displayed.indices {
            let relative = min(1, max(0, (decibelsByBar[index] - recentPeakDecibels + 30) / 30))
            // 录屏里的细微、不同行摆动只作视觉修饰；静音时完全由真实频谱归零。
            variationSeed = variationSeed &* 6364136223846793005 &+ 1442695040888963407
            let noise = CGFloat(Double(variationSeed >> 40) / Double(1 << 24) * 2 - 1)
            variation[index] += (noise - variation[index]) * 0.55
            let spectral = pow(relative, 1.4) * activity
            let target = CGFloat(min(1, max(0,
                0.15 * activity + 0.8 * spectral + 0.12 * activity * Double(variation[index]))))
            // 每个频段独立回落，留下短暂余韵；不沿轨道移动历史样本。
            let speed: CGFloat = target > displayed[index] ? 0.9 : 0.38
            displayed[index] += (target - displayed[index]) * speed
            if displayed[index] < 0.005 { displayed[index] = 0 }
        }
        return displayed
    }

    static func level(_ levels: [CGFloat], slot: Int, slots: Int) -> CGFloat {
        guard !levels.isEmpty, slots > 0, slot >= 0, slot < slots else { return 0 }
        let lower = slot * levels.count / slots
        let upper = max(lower + 1, (slot + 1) * levels.count / slots)
        return levels[lower..<min(upper, levels.count)].max() ?? 0
    }
}

/// Core Audio 回调只更新内存中的双声道环形采样；FFT 在阅读界面的计时器上执行。
private final class AudioSpectrumAccumulator: Sendable {
    private struct CallbackInput: @unchecked Sendable {
        let pointer: UnsafePointer<AudioBufferList>
    }
    private struct State {
        var channels = (0..<2).map { _ in Array(repeating: Float.zero, count: AudioWaveSpectrum.sampleCount) }
        var writeIndex = 0
        var filled = 0
        var hasNewSamples = false
        var sampleRate = 0.0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func configure(sampleRate: Double) { state.withLock { $0.sampleRate = sampleRate } }
    func receive(_ input: UnsafePointer<AudioBufferList>) {
        let callback = CallbackInput(pointer: input)
        state.withLock { state in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: callback.pointer))
            guard let first = buffers.first, first.mNumberChannels > 0 else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
            guard frames > 0 else { return }
            for frame in 0..<frames {
                var channel = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let count = Int(buffer.mNumberChannels)
                    guard count > 0 else { continue }
                    guard frame < Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count) else { continue }
                    for offset in 0..<count where channel < 2 {
                        let value = samples[frame * count + offset]
                        state.channels[channel][state.writeIndex] = value.isFinite ? value : 0
                        channel += 1
                    }
                }
                if channel == 1 { state.channels[1][state.writeIndex] = state.channels[0][state.writeIndex] }
                state.writeIndex = (state.writeIndex + 1) % AudioWaveSpectrum.sampleCount
                state.filled = min(AudioWaveSpectrum.sampleCount, state.filled + 1)
            }
            state.hasNewSamples = true
        }
    }
    func consume() -> AudioSpectrumFrame? {
        state.withLock { state in
            guard state.hasNewSamples, state.sampleRate > 0 else { return nil }
            state.hasNewSamples = false
            let channels = state.channels.map { ring in
                let ordered = Array(ring[state.writeIndex...]) + Array(ring[..<state.writeIndex])
                return state.filled == AudioWaveSpectrum.sampleCount
                    ? ordered : Array(repeating: Float.zero, count: AudioWaveSpectrum.sampleCount - state.filled)
                        + Array(ordered.suffix(state.filled))
            }
            return AudioSpectrumFrame(channels: channels, sampleRate: state.sampleRate)
        }
    }
}

/// 启停可能等待系统授权，由独立 actor 执行，不能阻塞阅读界面。
private actor SystemAudioTap {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let spectrum = AudioSpectrumAccumulator()
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
        spectrum.configure(sampleRate: format.mSampleRate)
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
        let spectrum = spectrum
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { @Sendable _, input, _, _, _ in
            spectrum.receive(input)
        })
        try check(AudioDeviceStart(device, io))
    }

    nonisolated func consumeFrame() -> AudioSpectrumFrame? { spectrum.consume() }
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
