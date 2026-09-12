#if os(macOS)
import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// One explicit navigation request. Re-layouts and late image arrivals never
/// start a turn. No custom Animatable conformance crosses actor boundaries.
struct MagazinePageTurnRequest: Equatable, Sendable {
    let id = UUID()
    let targetPageID: String
    let forward: Bool
}

struct MagazineTurnGeometry: Sendable {
    let forward: Bool
    var sourceIsLeft: Bool { !forward }
    var destinationIsLeft: Bool { forward }
    var anchorX: CGFloat { forward ? 0 : 1 }
    var finalAngle: CGFloat { forward ? -.pi : .pi }

    /// Snapshots are viewport-sized, never the full scroll document. Bound the
    /// pixel budget even on Retina / very tall displays.
    static func snapshotScale(size: CGSize, displayScale: CGFloat) -> CGFloat {
        let pixels = max(1, size.width * size.height)
        return min(max(1, displayScale), 2, sqrt(3_000_000 / pixels))
    }

    static func crop(_ image: CGImage, left: Bool) -> CGImage? {
        let mid = image.width / 2
        let x = left ? 0 : mid
        return image.cropping(to: CGRect(x: x, y: 0, width: left ? mid : image.width - mid, height: image.height))
    }
}

/// One live page host, with two frozen viewport textures only during a turn.
/// This captures our own NSView, not the screen, and needs no recording access.
struct MagazinePageTurnView<Content: View>: NSViewRepresentable {
    let pageID: String
    let request: MagazinePageTurnRequest?
    let reduceMotion: Bool
    let isActive: Bool
    let background: NSColor
    let content: Content
    let onComplete: @MainActor (UUID) -> Void

    func makeNSView(context: Context) -> MagazineTurnSurface<Content> {
        MagazineTurnSurface(content: content, pageID: pageID)
    }

    func updateNSView(_ view: MagazineTurnSurface<Content>, context: Context) {
        view.update(content: content, pageID: pageID, request: request,
                    reduceMotion: reduceMotion, isActive: isActive, background: background,
                    onComplete: onComplete)
    }

    static func dismantleNSView(_ view: MagazineTurnSurface<Content>, coordinator: ()) {
        view.cancelTurn(notify: false)
    }
}

@MainActor
final class MagazineTurnSurface<Content: View>: NSView {
    private let host: NSHostingView<Content>
    private var pageID: String
    private var currentRequest: MagazinePageTurnRequest?
    private var preparation: Task<Void, Never>?
    private var completion: (@MainActor (UUID) -> Void)?
    private var cover: NSView?
    private var lastSize: CGSize = .zero
    private lazy var imageContext = CIContext(options: [.cacheIntermediates: false])
    private(set) var snapshotCount = 0
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
    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        if lastSize != bounds.size {
            lastSize = bounds.size
            cancelTurn()
        }
        host.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelTurn() }
    }

    func update(content: Content, pageID: String, request: MagazinePageTurnRequest?,
                reduceMotion: Bool, isActive: Bool, background: NSColor,
                onComplete: @escaping @MainActor (UUID) -> Void) {
        completion = onComplete
        layer?.backgroundColor = background.cgColor
        guard pageID != self.pageID else {
            host.rootView = content
            if !isActive || request?.id != currentRequest?.id { cancelTurn() }
            return
        }
        cancelTurn()
        let shouldTurn = isActive && request?.targetPageID == pageID && window != nil
        let before = shouldTurn ? snapshot(background: background) : nil
        self.pageID = pageID
        host.rootView = content
        guard let request, shouldTurn, let before else {
            if let request { completeLater(request.id) }
            return
        }
        currentRequest = request
        let size = bounds.size
        // Keep the old viewport visible while SwiftUI lays out the new page.
        let cover = NSView(frame: bounds)
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
                self.cancelTurn()
                return
            }
            self.animate(from: before, to: after, size: size, request: request, reduceMotion: reduceMotion)
        }
    }

    func cancelTurn(notify: Bool = true) {
        let id = currentRequest?.id
        currentRequest = nil
        preparation?.cancel()
        preparation = nil
        cover?.layer?.removeAllAnimations()
        cover?.removeFromSuperview()
        cover = nil
        if notify, let id { completeLater(id) }
    }

    private func completeLater(_ id: UUID) {
        let callback = completion
        Task { @MainActor in callback?(id) }
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
        context.setFillColor(background.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        snapshotCount += 1
        return context.makeImage()
    }

    private func imageLayer(_ image: CGImage, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsGravity = .resize
        layer.isDoubleSided = false
        return layer
    }

    private func blurred(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let output = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
        return imageContext.createCGImage(output, from: source.extent)
    }

    private func pulse(_ layer: CALayer, keyPath: String, values: [Double], duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: keyPath)
    }

    private func animate(from before: CGImage, to after: CGImage, size: CGSize,
                         request: MagazinePageTurnRequest, reduceMotion: Bool) {
        guard let root = cover?.layer else { cancelTurn(); return }
        let geometry = MagazineTurnGeometry(forward: request.forward)
        let full = CGRect(origin: .zero, size: size)
        let half = CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        guard let oldMoving = MagazineTurnGeometry.crop(before, left: geometry.sourceIsLeft),
              let oldStationary = MagazineTurnGeometry.crop(before, left: !geometry.sourceIsLeft),
              let newBack = MagazineTurnGeometry.crop(after, left: geometry.destinationIsLeft) else {
            cancelTurn(); return
        }
        let duration = reduceMotion ? 0.12 : 0.58
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentRequest?.id == request.id else { return }
                self.cancelTurn()
            }
        }
        root.contents = after
        if reduceMotion {
            let old = imageLayer(before, frame: full)
            old.opacity = 0
            root.addSublayer(old)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = duration
            old.add(fade, forKey: "fade")
        } else {
            // The destination sits underneath. Old left stays still until the
            // reverse face (new left) sweeps across it; new right is uncovered.
            let stationary = imageLayer(oldStationary, frame: half.offsetBy(dx: request.forward ? 0 : half.width, dy: 0))
            root.addSublayer(stationary)
            let stage = CATransformLayer()
            stage.frame = full
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / max(800, size.width * 2.4)
            stage.sublayerTransform = perspective
            root.addSublayer(stage)
            let leaf = CATransformLayer()
            leaf.bounds = half
            leaf.anchorPoint = CGPoint(x: geometry.anchorX, y: 0.5)
            leaf.position = CGPoint(x: size.width / 2, y: size.height / 2)
            stage.addSublayer(leaf)
            let front = imageLayer(oldMoving, frame: half)
            let back = imageLayer(newBack, frame: half)
            // The second rotation cancels the leaf's final rotation. Text on
            // the reverse face is never mirrored when it lands on the left.
            back.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            leaf.addSublayer(front)
            leaf.addSublayer(back)
            for face in [front, back] {
                let image = face === front ? oldMoving : newBack
                if let softened = blurred(image) {
                    let blur = imageLayer(softened, frame: half)
                    blur.opacity = 0
                    face.addSublayer(blur)
                    pulse(blur, keyPath: "opacity", values: [0, 0.8, 1, 0.65, 0], duration: duration)
                }
                let shade = CAGradientLayer()
                shade.frame = half
                shade.colors = [NSColor.black.withAlphaComponent(0.04).cgColor, NSColor.black.withAlphaComponent(0.38).cgColor]
                shade.startPoint = CGPoint(x: 0, y: 0.5)
                shade.endPoint = CGPoint(x: 1, y: 0.5)
                shade.opacity = 0
                face.addSublayer(shade)
                pulse(shade, keyPath: "opacity", values: [0, 0.5, 1, 0.5, 0], duration: duration)
            }
            leaf.transform = CATransform3DMakeRotation(geometry.finalAngle, 0, 1, 0)
            let rotation = CABasicAnimation(keyPath: "transform.rotation.y")
            rotation.fromValue = 0
            rotation.toValue = geometry.finalAngle
            rotation.duration = duration
            rotation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.68, 0.15, 1)
            leaf.add(rotation, forKey: "page-turn")
        }
        CATransaction.commit()
    }
}
#endif
