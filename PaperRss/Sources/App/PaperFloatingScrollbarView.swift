#if os(macOS)
import AppKit
import SwiftUI

// MARK: - PaperFloatingScrollbarView

/// 真正浮动的独立滚动条视图（Overlay Sibling）。
///
/// 核心架构原则：
/// 1. 它是 List / ScrollView 的同级兄弟视图（或叠加在容器上的独立视图），
///    绝对不参与 SwiftUI List 内容区域的宽度排版，彻底解决内容跳动与 1px 移动问题。
/// 2. 纯 AppKit CALayer 本地状态绘制，零 SwiftUI 状态分发，绝不调用 `scrollView.tile()`。
/// 3. 仿照 Codex 设计规范：
///    - 宽 5pt，全圆角药丸 (pill) 形状
///    - Idle: 完全透明隐藏 (opacity: 0.0)
///    - Scrolling: 细腻中性灰色 (opacity: 0.38)
///    - Hover / Drag: 增强对比度 (opacity: 0.68)
///    - 滚动停止 0.8s 后平滑淡出
@MainActor
final class PaperFloatingScrollbarView: NSView {

    // MARK: 私有属性

    private weak var targetScrollView: NSScrollView?
    private let thumbLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    nonisolated(unsafe) private var fadeOutTimer: Timer?
    private var isHovered = false
    private var isDragging = false
    private var dragStartMouseY: CGFloat = 0
    private var dragStartScrollY: CGFloat = 0

    nonisolated(unsafe) private var boundsObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var frameObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var documentFrameObserver: (any NSObjectProtocol)?

    // MARK: 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    deinit {
        fadeOutTimer?.invalidate()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let documentFrameObserver { NotificationCenter.default.removeObserver(documentFrameObserver) }
    }

    override var isFlipped: Bool { true }

    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        thumbLayer.cornerRadius = 2.5
        thumbLayer.masksToBounds = true
        thumbLayer.opacity = 0.0
        updateThumbColor()
        layer?.addSublayer(thumbLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThumbColor()
    }

    private func updateThumbColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            thumbLayer.backgroundColor = NSColor.white.cgColor
        } else {
            thumbLayer.backgroundColor = NSColor.black.cgColor
        }
    }

    // MARK: 绑定目标 NSScrollView

    func attach(to scrollView: NSScrollView) {
        if targetScrollView === scrollView { return }

        // 清理旧监听
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let documentFrameObserver { NotificationCenter.default.removeObserver(documentFrameObserver) }

        targetScrollView = scrollView

        // 1. 隐藏原生滚动条可视化（零 gutter 占位）
        scrollView.hasVerticalScroller = false
        scrollView.verticalScroller?.isHidden = true
        scrollView.autohidesScrollers = true

        // 2. 开启 clipView 的滚动通知
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true

        // 3. 监听滚动与尺寸变化
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScrollChange(animated: false)
            }
        }

        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncGeometry()
            }
        }

        if let docView = scrollView.documentView {
            docView.postsFrameChangedNotifications = true
            documentFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: docView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncGeometry()
                }
            }
        }

        syncGeometry()
    }

    // MARK: 几何计算与同步

    override func layout() {
        super.layout()
        thumbLayer.cornerRadius = bounds.width / 2.0
        syncGeometry()
    }

    private func handleScrollChange(animated: Bool) {
        syncGeometry()
        if !isHovered && !isDragging {
            showThumb(opacity: 0.38, animated: true)
            scheduleFadeOut()
        }
    }

    private func syncGeometry() {
        guard let scrollView = targetScrollView else {
            thumbLayer.opacity = 0
            return
        }

        let clipView = scrollView.contentView
        let viewportH = clipView.bounds.height
        let documentH = max(viewportH, scrollView.documentView?.bounds.height ?? viewportH)
        let scrollableH = documentH - viewportH
        let trackH = bounds.height

        guard trackH > 0, scrollableH > 1.0 else {
            thumbLayer.isHidden = true
            return
        }

        thumbLayer.isHidden = false

        // 计算比例与高度（参考 Codex 规范，最小高度 24pt）
        let ratio = max(0.06, min(1.0, viewportH / documentH))
        let minThumbH: CGFloat = 24.0
        let thumbH = max(minThumbH, trackH * ratio)
        let availableTravel = trackH - thumbH

        let currentY = clipView.bounds.origin.y
        let progress = max(0.0, min(1.0, currentY / scrollableH))
        let thumbY = availableTravel * progress

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.frame = CGRect(
            x: 0,
            y: thumbY,
            width: bounds.width,
            height: thumbH
        )
        CATransaction.commit()
    }

    // MARK: 动效管理

    private func showThumb(opacity: Float, animated: Bool) {
        guard !thumbLayer.isHidden else { return }
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil

        if animated {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = thumbLayer.presentation()?.opacity ?? thumbLayer.opacity
            anim.toValue = opacity
            anim.duration = 0.12
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            thumbLayer.add(anim, forKey: "fade")
        }
        thumbLayer.opacity = opacity
    }

    private func scheduleFadeOut(delay: TimeInterval = 0.8) {
        guard !isHovered, !isDragging else { return }
        fadeOutTimer?.invalidate()
        fadeOutTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, !self.isHovered, !self.isDragging else { return }
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = self.thumbLayer.presentation()?.opacity ?? self.thumbLayer.opacity
                anim.toValue = 0.0
                anim.duration = 0.28
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.thumbLayer.add(anim, forKey: "fade")
                self.thumbLayer.opacity = 0.0
            }
        }
    }

    // MARK: 鼠标追踪 (Hover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        showThumb(opacity: 0.68, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        if !isDragging {
            scheduleFadeOut(delay: 0.3)
        }
    }

    // MARK: 鼠标拖拽 (Drag to Scroll)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if bounds.contains(localPoint) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView = targetScrollView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let thumbFrame = thumbLayer.frame

        if thumbFrame.contains(point) {
            // 点中 thumb：开始平滑拖拽
            isDragging = true
            dragStartMouseY = point.y
            dragStartScrollY = scrollView.contentView.bounds.origin.y
            showThumb(opacity: 0.75, animated: true)
        } else {
            // 点击轨道其他位置：按点击位置立即跳转
            isDragging = true
            showThumb(opacity: 0.75, animated: true)
            scrollToRatio(at: point.y)
            dragStartMouseY = point.y
            dragStartScrollY = scrollView.contentView.bounds.origin.y
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let scrollView = targetScrollView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let deltaY = point.y - dragStartMouseY

        let clipView = scrollView.contentView
        let viewportH = clipView.bounds.height
        let documentH = max(viewportH, scrollView.documentView?.bounds.height ?? viewportH)
        let scrollableH = documentH - viewportH
        let trackH = bounds.height
        let thumbH = thumbLayer.frame.height
        let availableTravel = max(1.0, trackH - thumbH)

        let deltaProgress = deltaY / availableTravel
        let targetScrollY = dragStartScrollY + (deltaProgress * scrollableH)
        let clampedY = max(0, min(scrollableH, targetScrollY))

        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clampedY))
        scrollView.reflectScrolledClipView(clipView)
        syncGeometry()
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if isHovered {
            showThumb(opacity: 0.68, animated: true)
        } else {
            scheduleFadeOut(delay: 0.5)
        }
    }

    private func scrollToRatio(at clickY: CGFloat) {
        guard let scrollView = targetScrollView else { return }
        let clipView = scrollView.contentView
        let viewportH = clipView.bounds.height
        let documentH = max(viewportH, scrollView.documentView?.bounds.height ?? viewportH)
        let scrollableH = documentH - viewportH
        let trackH = max(1.0, bounds.height)

        let targetRatio = max(0.0, min(1.0, clickY / trackH))
        let targetScrollY = targetRatio * scrollableH
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetScrollY))
        scrollView.reflectScrolledClipView(clipView)
        syncGeometry()
    }
}

// MARK: - PaperColumnContainerController

/// 包装单栏 NSHostingController 与独立 PaperFloatingScrollbarView 的容器控制器。
///
/// 结构：
/// ┌───────────────────────────────────────────────┐
/// │ PaperColumnContainerController.view          │
/// │ ┌───────────────────────────────────────────┐ │
/// │ │ NSHostingController.view (SwiftUI List)   │ │
/// │ └───────────────────────────────────────────┘ │
/// │                                         ▐ 浮层│
/// └───────────────────────────────────────────────┘
@MainActor
final class PaperColumnContainerController<Content: View>: NSViewController {

    let hostingController: NSHostingController<Content>
    let scrollbar = PaperFloatingScrollbarView()

    init(rootView: Content) {
        self.hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var rootView: Content {
        get { hostingController.rootView }
        set {
            hostingController.rootView = newValue
            // 数据源或视图更新后，异步同步一次滚动条几何
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.findAndAttachScrollViewIfNeeded()
                }
            }
        }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 1. 添加 hostingController 作为子控制器
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)

        // 2. 添加浮层滚动条到最顶层（不参与 List 内部排版）
        scrollbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollbar)

        NSLayoutConstraint.activate([
            // hosting view 填满容器
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 浮层滚动条贴在右侧，固定 5pt 宽，上下预留 4pt 边距
            scrollbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            scrollbar.widthAnchor.constraint(equalToConstant: 5),
            scrollbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            scrollbar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        findAndAttachScrollViewIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        findAndAttachScrollViewIfNeeded()
    }

    private func findAndAttachScrollViewIfNeeded() {
        guard let scrollView = findScrollView(in: hostingController.view) else { return }
        scrollbar.attach(to: scrollView)
    }

    /// 递归查找视图树中的 NSScrollView（严格排除 WKWebView 子树）
    private func findScrollView(in view: NSView) -> NSScrollView? {
        let className = String(describing: type(of: view))
        if className.contains("WKWebView") || className.contains("WebView") {
            return nil
        }
        if let sv = view as? NSScrollView {
            return sv
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
#endif
