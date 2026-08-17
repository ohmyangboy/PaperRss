import SwiftUI
#if os(macOS)
import AppKit

// MARK: - PaperOverlayScroller

/// Codex 风格的细纤浮层 thumb：4pt 宽、无槽、中性灰、自动隐藏。
///
/// 仅由 `paperListScrollStyle()` 显式安装在 Sidebar / 文章列表 / Settings，
/// 不全局注入，不影响 WKWebView / ArticleReaderView。
final class PaperOverlayScroller: NSScroller {

    private var pointerInside = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        controlSize = .regular
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: 鼠标追踪（hover 增强 alpha）

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
        pointerInside = true
        needsDisplay = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        needsDisplay = true
        super.mouseExited(with: event)
    }

    // MARK: 绘制 — 仅绘制 thumb capsule，不绘制 track/slot/arrow/background

    override func draw(_ dirtyRect: NSRect) {
        // 不调 super.draw：彻底跳过 AppKit 绘制 slot 背景的整个管线
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 有意留空：消灭任何灰色背景槽
    }

    override func drawKnob() {
        let native = rect(for: .knob)
        guard !native.isEmpty, native.height > 0, native.width > 0 else { return }

        let visualWidth: CGFloat = 4          // 比系统默认 ~8pt 细一半
        let trailingPad: CGFloat = 2          // 距右边缘
        let vInset: CGFloat = 2               // 上下留白

        let x = bounds.maxX - trailingPad - visualWidth
        let knob = NSRect(
            x: x,
            y: native.minY + vInset,
            width: visualWidth,
            height: max(0, native.height - vInset * 2)
        )
        guard knob.height > 0 else { return }

        let alpha: CGFloat = pointerInside ? 0.40 : 0.22
        NSColor.secondaryLabelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: knob, xRadius: visualWidth / 2, yRadius: visualWidth / 2).fill()
    }
}

// MARK: - ScrollStyleEnforcer (KVO 持续防守)

/// KVO 监听者：当系统（或 SwiftUI List tile()）把 scrollerStyle 改回 legacy 时，
/// 立即拦截并重设为 overlay，防止 "始终显示滚动条" 系统偏好破坏布局宽度。
@MainActor
private final class ScrollStyleEnforcer: NSObject {
    private weak var scrollView: NSScrollView?
    private var isEnforcing = false   // 防止 KVO 回调触发无限递归

    init(_ sv: NSScrollView) {
        self.scrollView = sv
        super.init()
        sv.addObserver(self, forKeyPath: "scrollerStyle", options: [.new], context: nil)
    }

    deinit {
        scrollView?.removeObserver(self, forKeyPath: "scrollerStyle")
    }

    override nonisolated func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "scrollerStyle" else { return }
        let rawValue = change?[.newKey] as? Int ?? 1
        let newStyle = NSScroller.Style(rawValue: rawValue) ?? .legacy
        guard newStyle != .overlay else { return }

        // KVO 回调可能在非主线程，必须跳回主线程修改 UI 属性
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isEnforcing, let sv = self.scrollView else { return }
            self.isEnforcing = true
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true
            sv.tile()
            self.isEnforcing = false
        }
    }
}

// MARK: - AssociatedObject 辅助

private enum AssociatedKeys {
    nonisolated(unsafe) static var enforcer: UInt8 = 0
}

private func attachEnforcer(_ enforcer: ScrollStyleEnforcer, to scrollView: NSScrollView) {
    objc_setAssociatedObject(
        scrollView,
        &AssociatedKeys.enforcer,
        enforcer,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func hasEnforcer(on scrollView: NSScrollView) -> Bool {
    objc_getAssociatedObject(scrollView, &AssociatedKeys.enforcer) is ScrollStyleEnforcer
}

// MARK: - PaperScrollViewCustomizer (NSViewRepresentable)

/// 附着在目标 View 背景中的透明 Representable。
/// 向上遍历视图树找到最近的 NSScrollView，
/// 安装 PaperOverlayScroller 并挂上 KVO enforcer，一次安装，持续生效。
private struct PaperScrollViewCustomizer: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var node: NSView? = self
                while let v = node {
                    if let sv = v as? NSScrollView {
                        Self.install(on: sv)
                        return
                    }
                    node = v.superview
                }
            }
        }

        private static func install(on sv: NSScrollView) {
            // --- 1. 安装 KVO enforcer（只装一次，持续保活）---
            if !hasEnforcer(on: sv) {
                let enforcer = ScrollStyleEnforcer(sv)
                attachEnforcer(enforcer, to: sv)
            }

            // --- 2. 立即设为 overlay ---
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true

            // --- 3. 安装自定义 thumb（若已是则跳过）---
            if !(sv.verticalScroller is PaperOverlayScroller) {
                let prev = sv.verticalScroller?.frame ?? .zero
                let scroller = PaperOverlayScroller(frame: prev)
                sv.verticalScroller = scroller
            }

            // --- 4. 重申 overlay，让 tile() 生效后仍保持 ---
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true
            sv.tile()
        }
    }
}

// MARK: - View extension

extension View {
    /// 将 PaperRss 的细纤 overlay thumb 安装到最近的 NSScrollView。
    ///
    /// 仅用于 Sidebar / 文章列表 / Settings 等普通列表；
    /// ArticleReaderView / WKWebView 严禁调用此方法。
    public func paperListScrollStyle() -> some View {
        background(PaperScrollViewCustomizer())
    }
}

#else
extension View {
    public func paperListScrollStyle() -> some View { self }
}
#endif
