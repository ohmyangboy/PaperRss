#if os(macOS)
import AppKit
import SwiftUI

// MARK: - PaperFloatingScrollbarView

/// 真正浮动的独立滚动条视图（Overlay Sibling）。
///
/// 核心架构原则：
/// 1. 作为 List / ScrollView 的同级兄弟视图（叠加在单栏容器 Trailing 边缘），
///    绝对不参与 SwiftUI List 内容区域的排版，实现 0 像素位移（Zero Layout Shift）。
/// 2. 纯观察者模式（Observer-Only）：只读取 NSScrollView 的滚动与几何状态，
///    绝对不修改 hasVerticalScroller、verticalScroller、insets 等任何 AppKit 属性，
///    绝不调用 `scrollView.tile()` 或 `layoutSubtreeIfNeeded()`。
/// 3. 分离命中测试车道 (Hit Lane, 11pt) 与视觉 Thumb (3pt)。
/// 4. 极度克制的中性系统语义色彩与透明度动效。
@MainActor
final class PaperFloatingScrollbarView: NSView {

    // MARK: 常量配置

    static let hitLaneWidth: CGFloat = 12.0
    static let thumbWidth: CGFloat = 4.5
    static let trailingInset: CGFloat = 2.5
    static let topInset: CGFloat = 6.0
    static let bottomInset: CGFloat = 6.0
    static let minThumbHeight: CGFloat = 24.0

    static let opacityIdle: Float = 0.0
    static let opacityScrolling: Float = 0.18
    static let opacityHover: Float = 0.28
    static let opacityDragging: Float = 0.36

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
    nonisolated(unsafe) private var liveScrollStartObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var liveScrollObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var liveScrollEndObserver: (any NSObjectProtocol)?

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
        if let liveScrollStartObserver { NotificationCenter.default.removeObserver(liveScrollStartObserver) }
        if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
        if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
    }

    override var isFlipped: Bool { true }

    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        thumbLayer.cornerRadius = Self.thumbWidth / 2.0
        thumbLayer.masksToBounds = true
        thumbLayer.opacity = Self.opacityIdle
        updateThumbColor()
        layer?.addSublayer(thumbLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThumbColor()
    }

    private func updateThumbColor() {
        // 使用系统级语义色彩，不使用纯黑纯白
        thumbLayer.backgroundColor = NSColor.labelColor.cgColor
    }

    // MARK: 绑定目标 NSScrollView (纯观察者，零属性突变)

    func attach(to scrollView: NSScrollView) {
        if targetScrollView === scrollView { return }

        // 清理旧监听
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let documentFrameObserver { NotificationCenter.default.removeObserver(documentFrameObserver) }
        if let liveScrollStartObserver { NotificationCenter.default.removeObserver(liveScrollStartObserver) }
        if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
        if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }

        targetScrollView = scrollView

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true

        // 1. 几何同步通知 (只更新几何，不触发显隐闪烁)
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncGeometry()
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

        // 2. 真实滚动事件通知 (控制显隐与淡出)
        liveScrollStartObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHovered, !self.isDragging else { return }
                self.showThumb(opacity: Self.opacityScrolling, animated: true)
            }
        }

        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHovered, !self.isDragging else { return }
                self.showThumb(opacity: Self.opacityScrolling, animated: false)
                self.scheduleFadeOut(delay: 0.8)
            }
        }

        liveScrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHovered, !self.isDragging else { return }
                self.scheduleFadeOut(delay: 0.5)
            }
        }

        syncGeometry()
    }

    // MARK: 几何计算与绘制

    override func layout() {
        super.layout()
        thumbLayer.cornerRadius = Self.thumbWidth / 2.0
        syncGeometry()
    }

    private func syncGeometry() {
        guard let scrollView = targetScrollView else {
            thumbLayer.opacity = Self.opacityIdle
            return
        }

        let clipView = scrollView.contentView
        let viewportH = clipView.bounds.height
        let documentH = max(viewportH, scrollView.documentView?.bounds.height ?? viewportH)
        let scrollableH = documentH - viewportH

        let usableTrackH = max(1.0, bounds.height - Self.topInset - Self.bottomInset)

        guard usableTrackH > 0, scrollableH > 1.0 else {
            thumbLayer.isHidden = true
            return
        }

        thumbLayer.isHidden = false

        // 真实视口/文档比例计算
        let ratio = min(1.0, viewportH / documentH)
        let proportionalH = usableTrackH * ratio
        let thumbH = max(Self.minThumbHeight, proportionalH)
        let availableTravel = max(0.0, usableTrackH - thumbH)

        let currentY = clipView.bounds.origin.y
        let progress = max(0.0, min(1.0, currentY / scrollableH))
        let thumbY = Self.topInset + (availableTravel * progress)
        let thumbX = bounds.width - Self.trailingInset - Self.thumbWidth

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.frame = CGRect(
            x: thumbX,
            y: thumbY,
            width: Self.thumbWidth,
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
                anim.toValue = Self.opacityIdle
                anim.duration = 0.28
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.thumbLayer.add(anim, forKey: "fade")
                self.thumbLayer.opacity = Self.opacityIdle
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
        showThumb(opacity: Self.opacityHover, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        if !isDragging {
            scheduleFadeOut(delay: 0.3)
        }
    }

    // MARK: 命中检测与鼠标拖拽

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint), !thumbLayer.isHidden, thumbLayer.opacity > 0.01 else {
            return nil
        }
        // 仅在 Thumb 及其附近拖拽区域返回 self，其余空白区域返回 nil 透传给 List 行
        let hitRect = thumbLayer.frame.insetBy(dx: -4, dy: -4)
        if hitRect.contains(localPoint) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView = targetScrollView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hitRect = thumbLayer.frame.insetBy(dx: -4, dy: -4)

        if hitRect.contains(point) {
            isDragging = true
            dragStartMouseY = point.y
            dragStartScrollY = scrollView.contentView.bounds.origin.y
            showThumb(opacity: Self.opacityDragging, animated: true)
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
        let usableTrackH = max(1.0, bounds.height - Self.topInset - Self.bottomInset)
        let thumbH = thumbLayer.frame.height
        let availableTravel = max(1.0, usableTrackH - thumbH)

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
            showThumb(opacity: Self.opacityHover, animated: true)
        } else {
            scheduleFadeOut(delay: 0.5)
        }
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

        // 1. 添加 hostingController 作为底层子控制器
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

            // 浮层滚动条车道贴在右侧，宽度 11pt，全高
            scrollbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollbar.widthAnchor.constraint(equalToConstant: PaperFloatingScrollbarView.hitLaneWidth),
            scrollbar.topAnchor.constraint(equalTo: view.topAnchor),
            scrollbar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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

    /// 递归查找视图树中的 NSTableView / NSOutlineView 的 enclosingScrollView（严格排除 WKWebView 子树）
    private func findScrollView(in view: NSView) -> NSScrollView? {
        let className = String(describing: type(of: view))
        if className.contains("WKWebView") || className.contains("WebView") {
            return nil
        }
        if let tv = view as? NSTableView {
            return tv.enclosingScrollView
        }
        if let ov = view as? NSOutlineView {
            return ov.enclosingScrollView
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
