#if os(macOS)
import AppKit
import QuartzCore
import MetalKit
import SwiftUI

/// 本地短音效只在翻页提交时播放，不跟随拖动逐帧触发。
@MainActor
enum MagazinePageSound {
    private static let sound: NSSound? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "MagazinePageTurn", withExtension: "wav")
            ?? bundle.url(forResource: "MagazinePageTurn", withExtension: "wav", subdirectory: "Audio"),
              let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        sound.volume = 0.72
        return sound
    }()

    static func play() {
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

struct MagazinePageTurnRequest: Equatable, Sendable {
    let id = UUID()
    let targetPageID: String
    let forward: Bool
    var progress: Double? = nil
    var commit = true
    var releaseVelocity: Double? = nil
    let variation = MagazineTurnVariation.random()
}

/// 每次手势只选一次预设，形变和速度在整次翻页中保持连续。
struct MagazineTurnVariation: Equatable, Sendable {
    let corner: Float
    let duration: Double
    static let presets: [Self] = [
        .init(corner: -0.8, duration: 0.28), .init(corner: 0.65, duration: 0.30),
        .init(corner: -0.35, duration: 0.26), .init(corner: 1, duration: 0.29)
    ]
    static func random() -> Self { presets.randomElement()! }
}

struct MagazineTurnGeometry: Sendable {
    let forward: Bool
    var sourceIsLeft: Bool { !forward }
    var destinationIsLeft: Bool { forward }
    var anchorX: CGFloat { forward ? 0 : 1 }
    var finalAngle: CGFloat { forward ? -.pi : .pi }
    /// 初始切线保留手势速度，终点切线为零；回落前允许轻微顺势延伸。
    static func settled(_ time: Double, slope: Double) -> Double {
        let t = min(1, max(0, time))
        return (-2 * t * t * t + 3 * t * t) + slope * (t * t * t - 2 * t * t + t)
    }

    static func snapshotScale(size: CGSize, displayScale: CGFloat) -> CGFloat {
        let pixels = max(1, size.width * size.height)
        return min(max(1, displayScale), 2, sqrt(3_000_000 / pixels))
    }
    static func crop(_ image: CGImage, left: Bool) -> CGImage? {
        let mid = image.width / 2
        return image.cropping(to: CGRect(x: left ? 0 : mid, y: 0,
            width: left ? mid : image.width - mid, height: image.height))
    }
    static func eased(_ value: Double) -> Double {
        // 0.23, 1.0, 0.32, 1.0 贝塞尔：先反解时间，再求进度。
        let x = min(1, max(0, value))
        if x == 0 || x == 1 { return x }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let t = (low + high) / 2
            let bx = 3 * (1-t) * (1-t) * t * 0.23 + 3 * (1-t) * t * t * 0.32 + t*t*t
            if bx < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1-t) * (1-t) * t + 3 * (1-t) * t*t + t*t*t
    }
}

/// 只在翻页时绘制；着色器从固定观察点采样两张视口纹理。
@MainActor
final class MagazineMetalRenderer: NSObject, MTKViewDelegate {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "pageVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "pageFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()
    static func prepare() { _ = pipeline }

    let view: MTKView
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let before: MTLTexture
    private let after: MTLTexture
    private let forward: Bool
    private let insetFraction: Float
    private let corner: Float
    private(set) var frameCount = 0
    private var requestedProgress = 0.0
    private var drewFrame = false

    init?(before: CGImage, after: CGImage, size: CGSize, forward: Bool, verticalInset: CGFloat = 0, corner: Float = 0) {
        guard let device = Self.device, let pipeline = Self.pipeline,
              let queue = device.makeCommandQueue() else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
        guard let old = try? loader.newTexture(cgImage: before, options: options),
              let new = try? loader.newTexture(cgImage: after, options: options) else { return nil }
        self.before = old; self.after = new; self.queue = queue; self.pipeline = pipeline; self.forward = forward
        self.corner = min(1, max(-1, corner))
        self.insetFraction = Float(min(0.4, max(0, verticalInset / max(1, size.height))))
        view = MTKView(frame: CGRect(origin: .zero, size: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: before.width, height: before.height)
        super.init()
        view.delegate = self
    }

    @discardableResult func draw(progress: Double) -> Bool {
        requestedProgress = progress
        drewFrame = false
        // draw() 在回调结束后归还 drawable，不能在生命周期外重复 present 同一缓冲区。
        view.draw()
        return drewFrame
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer(),
              encode(progress: requestedProgress, target: drawable.texture, buffer: buffer) else { return }
        buffer.present(drawable)
        buffer.commit()
        frameCount += 1
        drewFrame = true
    }

    /// 同一渲染入口也支持离屏帧校验，不依赖屏幕截图或窗口刷新时机。
    func encode(progress: Double, target: MTLTexture, buffer: MTLCommandBuffer) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var parameters = SIMD4<Float>(Float(progress), forward ? 1 : -1, insetFraction, corner)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(before, index: 0)
        encoder.setFragmentTexture(after, index: 1)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    // 参考 Duo 的核心几何：固定半页不动，另一半围绕中轴旋转。翻动页只在
    // 自己的投影范围内绘制，避免把整张目标页混成灰色重影。
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Raster { float4 position [[position]]; float2 uv; };
    vertex Raster pageVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Raster r; r.position = float4(p * 2.0 - 1.0, 0, 1);
        r.uv = float2(p.x, 1.0 - p.y); return r;
    }
    fragment float4 pageFragment(Raster r [[stage_in]], texture2d<float> old [[texture(0)]],
        texture2d<float> next [[texture(1)]], constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float p = clamp(params.x, 0.0, 1.0), direction = params.y;
        float2 uv = r.uv;
        if (p <= 0.00001) return old.sample(s, uv);
        if (p >= 0.99999) return next.sample(s, uv);
        float inset = params.z, paperHeight = 1.0 - 2.0 * inset;
        float paperY = (uv.y - inset) / paperHeight;
        float x = (uv.x - 0.5) * 2.0;
        float angle = p * M_PI_F, c = cos(angle), sine = sin(angle);
        bool stationary = x * direction < 0;
        float4 base = stationary ? old.sample(s, uv) : next.sample(s, uv);
        // 透视除法随页上位置变化；外缘向观察者抬起，书脊固定。
        // 边距缩小时同步降低透视深度，保留真实投影并避免页边超出舞台。
        float maxDepth = inset > 0.0 ? min(0.16, inset * 1.7) : 0.16;
        // 上下角的抬起位置不同，但深度始终在原有舞台预算以内。
        float cornerWeight = clamp(0.72 + params.w * (paperY - 0.5) * 0.5, 0.45, 1.0);
        float depth = maxDepth * sine * (params.w == 0.0 ? 1.0 : cornerWeight);
        float projectedEdge = direction * c / (1.0 - depth);
        bool onLeaf = abs(projectedEdge) > 0.0001
            && x * projectedEdge >= 0.0 && abs(x) <= abs(projectedEdge);
        float hingeShadow = (paperY >= 0.0 && paperY <= 1.0) ? exp(-abs(x) * 38.0) * sine * 0.12 : 0.0;
        if (!onLeaf) return float4(base.rgb * (1.0 - hingeShadow), 1);
        // t=0 为中轴，t=1 为外边缘；正面采旧页，背面采目标页另一半。
        float localX = x * direction;
        float t = clamp(localX / (c + localX * depth), 0.0, 1.0);
        bool front = p < 0.5;
        float faceDirection = front ? direction : -direction;
        float sourceX = 0.5 + faceDirection * t * 0.5;
        float yScale = 1.0 - depth * t;
        float2 source = float2(sourceX, (paperY - 0.5) * yScale + 0.5);
        if (source.y < 0.0 || source.y > 1.0) return float4(base.rgb, 1);
        source.y = inset + source.y * paperHeight;
        float edge = pow(t, 1.35), motion = sine * sine;
        // 文字保持清晰，立体感由真实投影和随角度变化的光照承担。
        float3 color = front ? old.sample(s, source).rgb : next.sample(s, source).rgb;
        float faceShade = 1.0 - motion * (0.06 + 0.12 * edge);
        float outerHighlight = smoothstep(0.94, 1.0, t) * sine * 0.12;
        color = color * faceShade + outerHighlight;
        return float4(color, 1);
    }
    """
}

struct MagazinePageTurnView<Content: View>: NSViewRepresentable {
    let pageID: String
    let request: MagazinePageTurnRequest?
    let reduceMotion: Bool
    let isActive: Bool
    let background: NSColor
    var verticalInset: CGFloat = 0
    var playsSound = false
    var fades = false
    let content: Content
    let onComplete: @MainActor (UUID, Bool) -> Void
    func makeNSView(context: Context) -> MagazineTurnSurface<Content> {
        MagazineTurnSurface(content: content, pageID: pageID)
    }
    func updateNSView(_ view: MagazineTurnSurface<Content>, context: Context) {
        view.update(content: content, pageID: pageID, request: request,
            reduceMotion: reduceMotion, isActive: isActive, background: background, verticalInset: verticalInset, playsSound: playsSound, fades: fades, onComplete: onComplete)
    }
    static func dismantleNSView(_ view: MagazineTurnSurface<Content>, coordinator: ()) {
        view.cancelTurn(notify: false)
    }
}

@MainActor
private final class MagazineSnapshotCover: NSView {
    // 快照只负责绘制；鼠标释放仍交给原 NSHostingView 的手势识别器。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 显示时钟只持有弱捕获闭包；结束或离窗时立即停止刷新。
@MainActor
private final class MagazineDisplayLinkTarget: NSObject {
    let callback: (CADisplayLink) -> Void
    init(_ callback: @escaping (CADisplayLink) -> Void) { self.callback = callback }
    @objc func tick(_ link: CADisplayLink) { callback(link) }
}

@MainActor
final class MagazineTurnSurface<Content: View>: NSView {
    enum Phase { case preparing, interacting, completing }
    private let host: NSHostingView<Content>
    private var pageID: String
    private var currentRequest: MagazinePageTurnRequest?
    private var preparation: Task<Void, Never>?
    private var displayClock: CADisplayLink?
    private var animationStart = 0.0
    private var animationDuration = 0.0
    private var animationFrom = 0.0
    private var animationSlope: Double?
    private var animationTo = 1.0
    private var sourceContent: Content?
    private var sourcePageID: String?
    private var completion: (@MainActor (UUID, Bool) -> Void)?
    private var cover: NSView?
    private var metal: MagazineMetalRenderer?
    private var lastSize: CGSize = .zero
    private var progress = 0.0
    private var reduceMotion = false
    private var playsSound = false
    private(set) var phase: Phase?
    private(set) var snapshotCount = 0
    private(set) var renderedFrames = 0
    var isAnimating: Bool { currentRequest != nil }

    init(content: Content, pageID: String) {
        self.host = NSHostingView(rootView: content)
        self.pageID = pageID
        super.init(frame: .zero)
        wantsLayer = true
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        if lastSize != bounds.size { lastSize = bounds.size; cancelTurn() }
        host.frame = bounds
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelTurn() }
        else { MagazineMetalRenderer.prepare() }
    }
    func update(content: Content, pageID: String, request: MagazinePageTurnRequest?,
                reduceMotion: Bool, isActive: Bool, background: NSColor, verticalInset: CGFloat = 0, playsSound: Bool = false, fades: Bool = false,
                onComplete: @escaping @MainActor (UUID, Bool) -> Void) {
        completion = onComplete
        self.reduceMotion = reduceMotion
        self.playsSound = playsSound
        layer?.backgroundColor = background.cgColor
        if pageID == self.pageID {
            if currentRequest == nil {
                host.rootView = content
                // 宿主在手势期间被重新挂载时已是目标页，不能留下未完成的请求。
                if isActive, let request { completeLater(request.id, committed: request.commit) }
                return
            }
            guard isActive, let request, request.id == currentRequest?.id else { cancelTurn(); return }
            currentRequest = request
            if phase != .preparing { advance(request) }
            return
        }
        cancelTurn()
        let shouldTurn = isActive && request?.targetPageID == pageID && window != nil
        let before = shouldTurn ? snapshot(background: background) : nil
        if shouldTurn, before != nil {
            sourceContent = host.rootView
            sourcePageID = self.pageID
        }
        self.pageID = pageID
        host.rootView = content
        guard let request, shouldTurn, let before else {
            if let request { completeLater(request.id, committed: true) }
            return
        }
        currentRequest = request
        phase = .preparing
        progress = 0
        let size = bounds.size
        let cover = MagazineSnapshotCover(frame: bounds)
        cover.wantsLayer = true
        cover.layer?.contents = before
        cover.layer?.contentsGravity = .resize
        cover.layer?.backgroundColor = background.cgColor
        addSubview(cover)
        self.cover = cover
        preparation = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.currentRequest?.id == request.id else { return }
            self.host.layoutSubtreeIfNeeded()
            self.host.displayIfNeeded()
            guard self.bounds.size == size, let after = self.snapshot(background: background) else {
                self.finish(committed: self.currentRequest?.commit ?? true); return
            }
            if !reduceMotion && !fades, let renderer = MagazineMetalRenderer(before: before, after: after, size: size, forward: request.forward, verticalInset: verticalInset, corner: request.variation.corner) {
                self.metal = renderer
                self.cover?.addSubview(renderer.view)
                if !renderer.draw(progress: 0) { renderer.view.removeFromSuperview(); self.metal = nil }
            }
            self.phase = .interacting
            if let latest = self.currentRequest { self.advance(latest) }
        }
    }
    private func advance(_ request: MagazinePageTurnRequest) {
        if let position = request.progress {
            displayClock?.invalidate(); displayClock = nil
            phase = .interacting
            draw(position)
        } else if phase != .completing {
            phase = .completing
            if request.commit && playsSound { MagazinePageSound.play() }
            let start = progress
            let end = request.commit ? 1.0 : 0.0
            animationDuration = reduceMotion ? 0.12 : max(0.12, (metal == nil ? 0.20 : request.variation.duration) * abs(end - start))
            if let velocity = request.releaseVelocity {
                animationDuration = reduceMotion ? 0.12 : min(0.42, max(0.22, abs(end - start) * 0.48))
                // 三次曲线保留松手速度，终点速度为零；限制切线避免越界。
                let delta = end - start
                animationSlope = abs(delta) > 0.001 ? min(3, max(-1, velocity * animationDuration / delta)) : 0
            } else { animationSlope = nil }
            animationStart = CACurrentMediaTime()
            animationFrom = start
            animationTo = end
            let target = MagazineDisplayLinkTarget { [weak self] link in self?.tick(link) }
            let clock = displayLink(target: target, selector: #selector(MagazineDisplayLinkTarget.tick(_:)))
            displayClock = clock
            clock.add(to: .main, forMode: .common)
        }
    }
    private func tick(_ link: CADisplayLink) {
        guard let request = currentRequest, phase == .completing else { return }
        let time = min(1, max(0, (link.targetTimestamp - animationStart) / animationDuration))
        let eased: Double
        if let slope = animationSlope {
            eased = MagazineTurnGeometry.settled(time, slope: slope)
        } else { eased = MagazineTurnGeometry.eased(time) }
        draw(animationFrom + (animationTo - animationFrom) * eased)
        if time >= 1 { finish(committed: request.commit) }
    }
    private func draw(_ value: Double) {
        progress = min(1, max(0, value))
        if let metal {
            if !metal.draw(progress: progress) {
                metal.view.removeFromSuperview()
                self.metal = nil
            }
        }
        if metal == nil {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cover?.layer?.opacity = Float(1 - progress)
            CATransaction.commit()
        }
        renderedFrames += 1
    }
    func cancelTurn(notify: Bool = true) {
        let id = currentRequest?.id
        currentRequest = nil; phase = nil
        preparation?.cancel(); preparation = nil
        displayClock?.invalidate(); displayClock = nil
        metal = nil
        if let sourceContent, let sourcePageID {
            host.rootView = sourceContent
            pageID = sourcePageID
            host.layoutSubtreeIfNeeded()
        }
        sourceContent = nil; sourcePageID = nil
        cover?.removeFromSuperview(); cover = nil
        if notify, let id { completeLater(id, committed: false) }
    }
    private func finish(committed: Bool) {
        let id = currentRequest?.id
        if committed { sourceContent = nil; sourcePageID = nil }
        cancelTurn(notify: false)
        if let id { completeLater(id, committed: committed) }
    }
    private func completeLater(_ id: UUID, committed: Bool) {
        let callback = completion
        Task { @MainActor in callback?(id, committed) }
    }
    private func snapshot(background: NSColor) -> CGImage? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        host.layoutSubtreeIfNeeded()
        let scale = MagazineTurnGeometry.snapshotScale(size: bounds.size, displayScale: window?.backingScaleFactor ?? 1)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: max(2, Int(bounds.width * scale)), pixelsHigh: max(2, Int(bounds.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background.cgColor); context.fill(rect); context.draw(image, in: rect)
        snapshotCount += 1
        return context.makeImage()
    }
}
#endif
