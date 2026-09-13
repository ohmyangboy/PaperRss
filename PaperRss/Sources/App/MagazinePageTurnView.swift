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
    /// 明确页面对的源身份，使 TOC 反向跨过边界时可以复用上一对的源宿主。
    var sourcePageID: String? = nil
    var scrubSessionID: UUID? = nil
    var settleFrom: Double? = nil
    var progress: Double? = nil
    var commit = true
    var releaseVelocity: Double? = nil
    /// TOC 吸附使用短收尾，普通点击/手势仍沿用页面预设时长。
    var settleDuration: Double? = nil
    let variation = MagazineTurnVariation.random()
}

/// 每次手势只选一次预设，形变和速度在整次翻页中保持连续。
struct MagazineTurnVariation: Equatable, Sendable {
    let corner: Float
    let duration: Double
    static let presets: [Self] = [
        .init(corner: -0.8, duration: 0.34), .init(corner: 0.65, duration: 0.36),
        .init(corner: -0.35, duration: 0.32), .init(corner: 1, duration: 0.35)
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
        // 0.28, 0.12, 0.22, 1.0 贝塞尔：柔和缓入，自然呼吸感展开与平稳合页。
        let x = min(1, max(0, value))
        if x == 0 || x == 1 { return x }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let t = (low + high) / 2
            let bx = 3 * (1-t) * (1-t) * t * 0.28 + 3 * (1-t) * t * t * 0.22 + t*t*t
            if bx < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1-t) * (1-t) * t * 0.12 + 3 * (1-t) * t * t * 1.00 + t*t*t
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
    private var before: MTLTexture
    private var after: MTLTexture
    private var forward: Bool
    private let insetFraction: Float
    private var corner: Float
    private(set) var frameCount = 0
    private var requestedProgress = 0.0
    private var drewFrame = false

    static func texture(_ image: CGImage) -> MTLTexture? {
        guard let device else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
        if let texture = try? loader.newTexture(cgImage: image, options: options) { return texture }
        // ImageRenderer 会将纯文字页面压成灰度图，MTKTextureLoader 不支持
        // 部分灰度/浮点格式。统一成 RGBA，避免文字页静默退化为淡入淡出。
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rgba = context.makeImage() else { return nil }
        return try? loader.newTexture(cgImage: rgba, options: options)
    }

    convenience init?(before: CGImage, after: CGImage, size: CGSize, forward: Bool, verticalInset: CGFloat = 0, corner: Float = 0) {
        guard let old = Self.texture(before), let new = Self.texture(after) else { return nil }
        self.init(before: old, after: new, size: size, forward: forward, verticalInset: verticalInset, corner: corner)
    }

    init?(before: MTLTexture, after: MTLTexture, size: CGSize, forward: Bool, verticalInset: CGFloat = 0, corner: Float = 0) {
        guard let device = Self.device, let pipeline = Self.pipeline,
              let queue = device.makeCommandQueue() else { return nil }
        self.before = before; self.after = after; self.queue = queue; self.pipeline = pipeline; self.forward = forward
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

    func setPages(before: MTLTexture, after: MTLTexture, forward: Bool, corner: Float) {
        self.before = before; self.after = after; self.forward = forward
        self.corner = min(1, max(-1, corner))
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
        // 透视除法随页上位置变化；外缘向观察者抬起，书脊固定。
        // 边距缩小时同步降低透视深度，保留真实投影并避免页边超出舞台。
        float maxDepth = inset > 0.0 ? min(0.16, inset * 1.7) : 0.16;
        // 上下角的抬起位置不同，但深度始终在原有舞台预算以内。
        float cornerWeight = clamp(0.72 + params.w * (paperY - 0.5) * 0.5, 0.45, 1.0);
        float depth = maxDepth * sine * (params.w == 0.0 ? 1.0 : cornerWeight);
        float projectedEdge = direction * c / (1.0 - depth);
        bool onLeaf = abs(projectedEdge) > 0.0001
            && x * projectedEdge >= 0.0 && abs(x) <= abs(projectedEdge);
        // 翻动页抬起前，外缘先只露出目标页的空白纸面；抬起过半后再淡入正文，
        // 避免纸面外缘出现一条被裁切的下一篇文章正文。纸面色取自目标页右缘留白。
        // 纸页之外的舞台条带仍直接采样目标页，保持既有留白行为。
        float coverage = clamp(abs(projectedEdge), 0.0, 1.0);
        float reveal = p < 0.5 ? (1.0 - smoothstep(0.55, 0.92, coverage)) : 1.0;
        float4 nextColor = next.sample(s, uv);
        bool onPaper = paperY >= 0.0 && paperY <= 1.0;
        float4 paper = next.sample(s, float2(0.985, 0.5));
        float4 under = onPaper ? mix(paper, nextColor, reveal) : nextColor;
        float4 base = stationary ? old.sample(s, uv) : under;
        float hingeShadow = (paperY >= 0.0 && paperY <= 1.0) ? exp(-abs(x) * 32.0) * sine * 0.05 : 0.0;
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
        float faceShade = 1.0 - motion * (0.025 + 0.045 * edge);
        float outerHighlight = smoothstep(0.90, 1.0, t) * sine * 0.035;
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
    var source: Content? = nil
    let onComplete: @MainActor (UUID, Bool) -> Void
    func makeNSView(context: Context) -> MagazineTurnSurface<Content> {
        MagazineTurnSurface(content: content, pageID: pageID)
    }
    func updateNSView(_ view: MagazineTurnSurface<Content>, context: Context) {
        view.update(content: content, pageID: pageID, request: request,
            reduceMotion: reduceMotion, isActive: isActive, background: background, verticalInset: verticalInset, playsSound: playsSound, fades: fades, source: source, onComplete: onComplete)
    }
    static func dismantleNSView(_ view: MagazineTurnSurface<Content>, coordinator: ()) {
        view.cancelTurn(notify: false)
    }
}

@MainActor
private final class MagazineSnapshotCover: NSView {
    // 快照只负责绘制；鼠标释放仍交给原 NSHostingView 的手势识别器。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 分数尺寸下宿主与快照都可能差 1 个物理像素；裁掉越界内容，
        // 不让渲染器或旧快照在纸面外留下细线。
        clipsToBounds = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
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
    /// 宿主之下的实底：宿主或 Metal 图层在分数尺寸下少画 1px 时，
    /// 露出的永远是舞台底色而不是图层默认黑色。
    private let backgroundView = NSView()
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
    private var stageBackground: NSColor = .windowBackgroundColor
    private struct ScrubUpdate {
        let request: MagazinePageTurnRequest
        let content: Content
        let source: Content
        let verticalInset: CGFloat
        let fades: Bool
    }
    private struct ScrubPage {
        let id: String
        let content: Content
        let image: CGImage
        let texture: MTLTexture?
    }
    private var scrubSessionID: UUID?
    private var pendingScrub: ScrubUpdate?
    private var scrubPages: [ScrubPage] = []
    private var scrubTarget: Content?
    private var scrubFront: CALayer?
    private var pendingProgress: Double?
    private(set) var rendererCount = 0
    private(set) var preparedSourcePageID: String?
    private(set) var preparedTargetPageID: String?
    var cachedScrubPageCount: Int { scrubPages.count }
    var displayedProgress: Double { progress }
    private(set) var phase: Phase?
    private(set) var snapshotCount = 0
    private(set) var renderedFrames = 0
    var isAnimating: Bool { currentRequest != nil || pendingScrub != nil }

    init(content: Content, pageID: String) {
        self.host = NSHostingView(rootView: content)
        self.pageID = pageID
        super.init(frame: .zero)
        wantsLayer = true
        host.sizingOptions = []
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        backgroundView.autoresizingMask = [.width, .height]
        addSubview(backgroundView)
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        if lastSize != bounds.size { lastSize = bounds.size; cancelTurn() }
        // 分数尺寸下 SwiftUI 内容与宿主层可能差 1 个物理像素；
        // 宿主之下的实底永远补上这 1px，避免露出不透明图层的黑色。
        backgroundView.frame = bounds
        host.frame = bounds
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelTurn() }
        else { MagazineMetalRenderer.prepare() }
    }
    func update(content: Content, pageID: String, request: MagazinePageTurnRequest?,
                reduceMotion: Bool, isActive: Bool, background: NSColor, verticalInset: CGFloat = 0, playsSound: Bool = false, fades: Bool = false,
                source: Content? = nil, onComplete: @escaping @MainActor (UUID, Bool) -> Void) {
        completion = onComplete
        self.reduceMotion = reduceMotion
        self.playsSound = playsSound
        self.stageBackground = background
        layer?.backgroundColor = background.cgColor
        backgroundView.layer?.backgroundColor = background.cgColor
        host.layer?.backgroundColor = background.cgColor
        if isActive, !reduceMotion, window != nil, let request,
           let sessionID = request.scrubSessionID, let source {
            if scrubSessionID != sessionID {
                cancelTurn(notify: false)
                scrubSessionID = sessionID
            }
            // 输入只替换一个槽位。截图、上传和绘制都由显示时钟消费最新请求。
            pendingScrub = ScrubUpdate(request: request, content: content, source: source,
                verticalInset: verticalInset, fades: fades)
            startClock()
            return
        }
        if scrubSessionID != nil { cancelTurn(notify: false) }
        if pageID == self.pageID {
            if currentRequest == nil {
                host.rootView = content
                // 防御：任何遗留的快照/渲染器都要清掉，避免在纸面边缘留下细线。
                if cover != nil || metal != nil { cancelTurn(notify: false) }
                // 宿主在手势期间被重新挂载时已是目标页，不能留下未完成的请求。
                if isActive, let request { completeLater(request.id, committed: request.commit) }
                return
            }
            guard isActive, let request, request.id == currentRequest?.id else { cancelTurn(); return }
            currentRequest = request
            if phase != .preparing { advance(request) }
            return
        }
        // TOC 快速拖动会在相邻页面边界切换页面对。通常宿主已经是上一对的
        // 目标页；反向越过边界时则优先恢复请求明确的源宿主，避免把后一页
        // 错当成新折页的源页。两种路径都抑制旧请求回调。
        let previousSourceContent = sourceContent
        let previousSourcePageID = sourcePageID
        let reusePreviousSource = currentRequest != nil
            && request?.sourcePageID != nil
            && request?.sourcePageID == previousSourcePageID
            && previousSourceContent != nil
        if currentRequest != nil {
            sourceContent = nil
            sourcePageID = nil
            cancelTurn(notify: false)
            if reusePreviousSource, let previousSourceContent, let previousSourcePageID {
                host.rootView = previousSourceContent
                self.pageID = previousSourcePageID
                host.layoutSubtreeIfNeeded()
            }
        } else {
            cancelTurn()
        }
        let shouldTurn = isActive && request?.targetPageID == pageID && window != nil
        let before = shouldTurn ? snapshot(background: background) : nil
        if shouldTurn, before != nil {
            sourceContent = host.rootView
            sourcePageID = self.pageID
        }
        guard let request, shouldTurn, let before else {
            self.pageID = pageID
            host.rootView = content
            if let request { completeLater(request.id, committed: true) }
            return
        }
        let size = bounds.size
        // 1. 立即挂上 cover 遮盖旧页面，彻底屏蔽底层新页面排版或重绘引起的瞬间穿透闪烁
        let cover = MagazineSnapshotCover(frame: bounds)
        cover.wantsLayer = true
        cover.layer?.contents = before
        cover.layer?.contentsGravity = .resize
        cover.layer?.backgroundColor = background.cgColor
        addSubview(cover)
        self.cover = cover

        // 2. 在 cover 的完全遮挡下更新 host 内容并抓取目标页快照
        self.pageID = pageID
        host.rootView = content
        self.host.layoutSubtreeIfNeeded()
        guard self.bounds.size == size, let after = self.snapshot(background: background) else {
            self.finish(committed: request.commit); return
        }

        // 3. 构建并挂载 Metal 渲染器，首帧准备就绪后启动翻页
        currentRequest = request
        phase = .preparing
        progress = 0
        if !reduceMotion && !fades, let renderer = MagazineMetalRenderer(before: before, after: after, size: size, forward: request.forward, verticalInset: verticalInset, corner: request.variation.corner) {
            self.metal = renderer
            configure(renderer: renderer)
            self.cover?.addSubview(renderer.view)
            if !renderer.draw(progress: 0) { renderer.view.removeFromSuperview(); self.metal = nil }
        }
        self.phase = .interacting
        if let latest = self.currentRequest { self.advance(latest) }
    }
    /// Metal 图层默认以不透明黑兜底；分数尺寸或重挂载时边缘绝不能露黑。
    private func configure(renderer: MagazineMetalRenderer) {
        renderer.view.autoresizingMask = [.width, .height]
        renderer.view.frame = cover?.bounds ?? bounds
        renderer.view.layer?.backgroundColor = stageBackground.cgColor
    }
    private func advance(_ request: MagazinePageTurnRequest) {
        if let position = request.progress {
            phase = .interacting
            pendingProgress = position
            startClock()
        } else if phase != .completing {
            phase = .completing
            if request.commit && playsSound { MagazinePageSound.play() }
            let start = progress
            let end = request.commit ? 1.0 : 0.0
            animationDuration = reduceMotion ? 0.12 : (request.settleDuration
                ?? max(0.12, (metal == nil ? 0.20 : request.variation.duration) * abs(end - start)))
            if let velocity = request.releaseVelocity {
                animationDuration = reduceMotion ? 0.12 : min(0.42, max(0.22, abs(end - start) * 0.48))
                // 三次曲线保留松手速度，终点速度为零；限制切线避免越界。
                let delta = end - start
                animationSlope = abs(delta) > 0.001 ? min(3, max(-1, velocity * animationDuration / delta)) : 0
            } else { animationSlope = nil }
            animationStart = CACurrentMediaTime()
            animationFrom = start
            animationTo = end
            pendingProgress = nil
            startClock()
        }
    }
    private func startClock() {
        guard displayClock == nil else { return }
        let target = MagazineDisplayLinkTarget { [weak self] link in self?.tick(link) }
        let clock = displayLink(target: target, selector: #selector(MagazineDisplayLinkTarget.tick(_:)))
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayClock = clock
        clock.add(to: .main, forMode: .common)
    }
    private func tick(_ link: CADisplayLink) {
        if let update = pendingScrub {
            pendingScrub = nil
            prepareScrub(update)
        }
        if let position = pendingProgress {
            pendingProgress = nil
            draw(position)
        }
        if phase != .completing {
            displayClock?.invalidate(); displayClock = nil
            return
        }
        guard let request = currentRequest, phase == .completing else { return }
        let time = min(1, max(0, (link.targetTimestamp - animationStart) / animationDuration))
        let eased: Double
        if let slope = animationSlope {
            eased = MagazineTurnGeometry.settled(time, slope: slope)
        } else { eased = MagazineTurnGeometry.eased(time) }
        draw(animationFrom + (animationTo - animationFrom) * eased)
        if time >= 1 { finish(committed: request.commit) }
    }

    private func scrubPage(id: String, content: Content, update: ScrubUpdate) -> ScrubPage? {
        if let index = scrubPages.firstIndex(where: { $0.id == id }) {
            let page = scrubPages.remove(at: index)
            scrubPages.append(page)
            return page
        }
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        // 快速浏览使用逻辑像素预览。直接绘制 SwiftUI 内容，避免反复挂载宿主、
        // 触发文章的 onAppear/task 和 AppKit cacheDisplay 的整棵视图刷新。
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(bounds.size)
        renderer.scale = min(1, sqrt(1_000_000 / max(1, bounds.width * bounds.height)))
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        snapshotCount += 1
        let page = ScrubPage(id: id, content: content, image: image,
            texture: update.fades ? nil : MagazineMetalRenderer.texture(image))
        scrubPages.append(page)
        if scrubPages.count > 4 { scrubPages.removeFirst(scrubPages.count - 4) }
        return page
    }

    private func prepareScrub(_ update: ScrubUpdate) {
        let request = update.request
        guard request.scrubSessionID == scrubSessionID, let sourceID = request.sourcePageID else { return }
        if currentRequest?.id == request.id {
            currentRequest = request
            if request.progress == nil, phase != .completing, let latest = request.settleFrom {
                progress = min(1, max(0, latest))
            }
            advance(request)
            return
        }
        guard let before = scrubPage(id: sourceID, content: update.source, update: update),
              let after = scrubPage(id: request.targetPageID, content: update.content, update: update) else {
            host.rootView = update.content
            pageID = request.targetPageID
            cancelTurn(notify: false)
            completeLater(request.id, committed: true)
            return
        }
        currentRequest = request
        sourceContent = before.content; sourcePageID = before.id
        scrubTarget = after.content; pageID = after.id
        preparedSourcePageID = before.id; preparedTargetPageID = after.id
        if cover == nil {
            let cover = MagazineSnapshotCover(frame: bounds)
            cover.wantsLayer = true
            addSubview(cover)
            self.cover = cover
            let front = CALayer()
            front.frame = cover.bounds
            front.contentsGravity = .resize
            cover.layer?.addSublayer(front)
            scrubFront = front
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cover?.layer?.contents = after.image
        cover?.layer?.contentsGravity = .resize
        scrubFront?.contents = before.image
        CATransaction.commit()
        if let old = before.texture, let new = after.texture {
            if let metal {
                metal.setPages(before: old, after: new, forward: request.forward, corner: request.variation.corner)
            } else if let renderer = MagazineMetalRenderer(before: old, after: new, size: bounds.size,
                forward: request.forward, verticalInset: update.verticalInset, corner: request.variation.corner) {
                metal = renderer
                rendererCount += 1
                configure(renderer: renderer)
                cover?.addSubview(renderer.view)
            }
        }
        phase = .interacting
        progress = request.progress ?? request.settleFrom ?? 0
        // 新页面对从手指当前角度开始，不能先绘制进度零再跳到最新位置。
        advance(request)
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
            if let scrubFront { scrubFront.opacity = Float(1 - progress) }
            else { cover?.layer?.opacity = Float(1 - progress) }
            CATransaction.commit()
        }
        renderedFrames += 1
    }
    func cancelTurn(notify: Bool = true) {
        let id = pendingScrub?.request.id ?? currentRequest?.id
        currentRequest = nil; phase = nil
        pendingScrub = nil; pendingProgress = nil
        scrubSessionID = nil; scrubTarget = nil; scrubFront = nil
        scrubPages.removeAll()
        preparedSourcePageID = nil; preparedTargetPageID = nil
        preparation?.cancel(); preparation = nil
        displayClock?.invalidate(); displayClock = nil
        metal = nil
        if let sourceContent, let sourcePageID {
            host.rootView = sourceContent
            pageID = sourcePageID
            host.layoutSubtreeIfNeeded()
        }
        sourceContent = nil; sourcePageID = nil
        if let cover {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cover.removeFromSuperview()
            self.cover = nil
            CATransaction.commit()
        }
        if notify, let id { completeLater(id, committed: false) }
    }
    private func finish(committed: Bool) {
        let id = currentRequest?.id
        if committed, let scrubTarget {
            host.rootView = scrubTarget
            host.layoutSubtreeIfNeeded()
        }
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
        // cacheDisplay 会同步栅格化整个 AppKit 图层树；纸张阴影在这里进入
        // CPU 高斯卷积，足以阻塞整个窗口。普通翻页也直接绘制 SwiftUI，
        // 保留 Retina 像素预算，不把宿主的外层图层再次截图。
        let renderer = ImageRenderer(content: host.rootView
            .frame(width: bounds.width, height: bounds.height)
            .background(Color(nsColor: background)))
        renderer.proposedSize = ProposedViewSize(bounds.size)
        renderer.scale = MagazineTurnGeometry.snapshotScale(size: bounds.size,
            displayScale: window?.backingScaleFactor ?? 1)
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        snapshotCount += 1
        return image
    }
}
#endif
