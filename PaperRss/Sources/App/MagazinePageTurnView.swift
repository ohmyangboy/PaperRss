#if os(macOS)
import AppKit
import QuartzCore
import MetalKit
import SwiftUI

struct MagazinePageTurnRequest: Equatable, Sendable {
    let id = UUID()
    let targetPageID: String
    let forward: Bool
    var progress: Double? = nil
    var commit = true
}

struct MagazineTurnGeometry: Sendable {
    let forward: Bool
    var sourceIsLeft: Bool { !forward }
    var destinationIsLeft: Bool { forward }
    var anchorX: CGFloat { forward ? 0 : 1 }
    var finalAngle: CGFloat { forward ? -.pi : .pi }
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
        // 0.20, 0.85, 0.25, 1.0 贝塞尔：先反解时间，再求进度。
        let x = min(1, max(0, value))
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let t = (low + high) / 2
            let bx = 3 * (1-t) * (1-t) * t * 0.20 + 3 * (1-t) * t * t * 0.25 + t*t*t
            if bx < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1-t) * (1-t) * t * 0.85 + 3 * (1-t) * t*t + t*t*t
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
    let view: MTKView
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let before: MTLTexture
    private let after: MTLTexture
    private let forward: Bool
    private(set) var frameCount = 0
    private var requestedProgress = 0.0
    private var drewFrame = false

    init?(before: CGImage, after: CGImage, size: CGSize, forward: Bool) {
        guard let device = Self.device, let pipeline = Self.pipeline,
              let queue = device.makeCommandQueue() else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
        guard let old = try? loader.newTexture(cgImage: before, options: options),
              let new = try? loader.newTexture(cgImage: after, options: options) else { return nil }
        self.before = old; self.after = new; self.queue = queue; self.pipeline = pipeline; self.forward = forward
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
        var parameters = SIMD4<Float>(Float(progress), forward ? 1 : -1, Float(before.width), Float(before.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(before, index: 0)
        encoder.setFragmentTexture(after, index: 1)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    // 固定投影使文字沿折线保持对齐；远离折线的部分逐渐模糊和变暗。
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
        float x = (uv.x - 0.5) * 2.0;
        float angle = p * M_PI_F, c = cos(angle), sine = sin(angle);
        bool stationary = x * direction < 0;
        float4 base = stationary ? old.sample(s, uv) : next.sample(s, uv);
        // 射线与翻动半页的交点；t=0 为书脊，t=1 为外边缘。
        float divisor = direction * c + x * sine * 0.32;
        float t = abs(divisor) > 0.00001 ? x / divisor : -1;
        float depth = 1.0 - t * sine * 0.32;
        float y = (uv.y - 0.5) * depth + 0.5;
        if (t < 0 || t > 1 || y < 0 || y > 1) {
            float shadow = exp(-abs(x) * 30.0) * sine * 0.14;
            return float4(base.rgb * (1.0 - shadow), 1);
        }
        bool front = p < 0.5;
        float faceDirection = front ? direction : -direction;
        // 用观察平面的距离投影，避免整块文字被横向压缩。
        float sourceX = 0.5 + faceDirection * min(1.0, abs(x)) * 0.5;
        float2 source = float2(sourceX, uv.y);
        float motion = sine * sine;
        float gradient = pow(clamp(t, 0.0, 1.0), 1.35);
        float radius = 72.0 * motion * gradient;
        float3 color = float3(0);
        for (int j = -1; j <= 1; ++j) {
            for (int i = -1; i <= 1; ++i) {
                float weight = (i == 0 ? 2.0 : 1.0) * (j == 0 ? 2.0 : 1.0) / 16.0;
                float2 sampleUV = source + float2(i, j) * radius / params.zw;
                sampleUV.x = clamp(sampleUV.x, faceDirection > 0 ? 0.5 : 0.0, faceDirection > 0 ? 1.0 : 0.5);
                color += (front ? old.sample(s, sampleUV).rgb : next.sample(s, sampleUV).rgb) * weight;
            }
        }
        color *= 1.0 - min(0.72, motion * gradient * 1.2);
        float coverage = clamp((1.0 - t) / max(fwidth(t), 0.001), 0.0, 1.0);
        return float4(mix(base.rgb, color, coverage), 1);
    }
    """
}

struct MagazinePageTurnView<Content: View>: NSViewRepresentable {
    let pageID: String
    let request: MagazinePageTurnRequest?
    let reduceMotion: Bool
    let isActive: Bool
    let background: NSColor
    let content: Content
    let onComplete: @MainActor (UUID, Bool) -> Void
    func makeNSView(context: Context) -> MagazineTurnSurface<Content> {
        MagazineTurnSurface(content: content, pageID: pageID)
    }
    func updateNSView(_ view: MagazineTurnSurface<Content>, context: Context) {
        view.update(content: content, pageID: pageID, request: request,
            reduceMotion: reduceMotion, isActive: isActive, background: background, onComplete: onComplete)
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

@MainActor
final class MagazineTurnSurface<Content: View>: NSView {
    enum Phase { case preparing, interacting, completing }
    private let host: NSHostingView<Content>
    private var pageID: String
    private var currentRequest: MagazinePageTurnRequest?
    private var preparation: Task<Void, Never>?
    private var animation: Task<Void, Never>?
    private var completion: (@MainActor (UUID, Bool) -> Void)?
    private var cover: NSView?
    private var metal: MagazineMetalRenderer?
    private var lastSize: CGSize = .zero
    private var progress = 0.0
    private var reduceMotion = false
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
    }
    func update(content: Content, pageID: String, request: MagazinePageTurnRequest?,
                reduceMotion: Bool, isActive: Bool, background: NSColor,
                onComplete: @escaping @MainActor (UUID, Bool) -> Void) {
        completion = onComplete
        self.reduceMotion = reduceMotion
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
                self.finish(committed: true); return
            }
            if !reduceMotion, let renderer = MagazineMetalRenderer(before: before, after: after, size: size, forward: request.forward) {
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
            animation?.cancel(); animation = nil
            phase = .interacting
            draw(position)
        } else if phase != .completing {
            phase = .completing
            let start = progress
            let end = request.commit ? 1.0 : 0.0
            let duration = (reduceMotion || metal == nil) ? 0.12 : max(0.12, 0.52 * abs(end - start))
            animation = Task { @MainActor [weak self] in
                let began = CACurrentMediaTime()
                while !Task.isCancelled {
                    guard let self, self.currentRequest?.id == request.id else { return }
                    let time = min(1, (CACurrentMediaTime() - began) / duration)
                    self.draw(start + (end - start) * MagazineTurnGeometry.eased(time))
                    if time >= 1 { self.finish(committed: request.commit); return }
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                }
            }
        }
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
        animation?.cancel(); animation = nil
        metal = nil
        cover?.removeFromSuperview(); cover = nil
        if notify, let id { completeLater(id, committed: false) }
    }
    private func finish(committed: Bool) {
        let id = currentRequest?.id
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
