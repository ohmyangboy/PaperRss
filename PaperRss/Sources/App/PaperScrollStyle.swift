import SwiftUI
#if os(macOS)
import AppKit

// MARK: - PaperOverlayScroller

/// Codex 风格细纤浮层 thumb：6pt 宽、无槽背景、中性灰、自动隐藏。
///
/// 只由 PaperNativeScrollStyler 安装在 Sidebar (column 0) 和 EntryList (column 1) 上，
/// 绝不全局注入，不影响 WKWebView / ArticleReader (column 2)。
final class PaperOverlayScroller: NSScroller {

    private var pointerInside = false
    private var isDragging = false
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

    // MARK: - 鼠标追踪与拖拽状态

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

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        needsDisplay = true
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        needsDisplay = true
        super.mouseUp(with: event)
    }

    // MARK: - 绘制 — 仅浮层 neutral capsule，无 track / slot / background / separator / border / shadow / arrows

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 有意留空：消灭任何灰色背景槽与轨道
    }

    override func drawKnob() {
        let native = rect(for: .knob)
        guard !native.isEmpty, native.height > 0, native.width > 0 else { return }

        let visualWidth: CGFloat = 6          // 6pt 浮层 capsule
        let trailingPad: CGFloat = 3          // 距右边缘内边距 3pt
        let vInset: CGFloat = 2               // 上下留白

        let x = bounds.maxX - trailingPad - visualWidth
        let knob = NSRect(
            x: x,
            y: native.minY + vInset,
            width: visualWidth,
            height: max(0, native.height - vInset * 2)
        )
        guard knob.height > 0 else { return }

        // idle: ~0.18, hover: ~0.32, drag: ~0.42
        let alpha: CGFloat = isDragging ? 0.42 : (pointerInside ? 0.32 : 0.18)
        NSColor.secondaryLabelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: knob, xRadius: visualWidth / 2, yRadius: visualWidth / 2).fill()
    }
}

// MARK: - PaperNativeScrollStyler

/// 精准目标化的滚动条样式配置器。
///
/// 通过 ThreeColumnSplitView 的已知列边界，仅对 column 0（Sidebar）和
/// column 1（EntryList）的真实 NSScrollView 进行配置，不扫描整个窗口，
/// 绝不触碰 column 2（ArticleReader / WKWebView）。
///
/// 查找策略：
///   rootView → 递归查找 NSTableView / NSOutlineView
///            → tableView.enclosingScrollView
/// 比从 SwiftUI .background 向上爬取更稳定，因为 enclosingScrollView 是 AppKit 官方 API。
@MainActor
enum PaperNativeScrollStyler {

    // 已处理过的 NSScrollView ObjectIdentifier 集合，避免重复配置
    private static var configured = Set<ObjectIdentifier>()

    /// 对指定列根视图下的 List scroll view 进行样式化（幂等）。
    ///
    /// - Parameter rootView: splitViewItems[0 or 1].viewController.view
    static func configureListScrollViews(in rootView: NSView) {
        let tableViews = findListViews(in: rootView)
        if tableViews.isEmpty {
            return
        }

        var seen = Set<ObjectIdentifier>()
        for tv in tableViews {
            guard let sv = tv.enclosingScrollView else { continue }
            let oid = ObjectIdentifier(sv)
            guard !seen.contains(oid) else { continue }
            seen.insert(oid)

            // 快速路径：若已完成配置且 scroller 正常，直接跳过
            if configured.contains(oid),
               sv.verticalScroller is PaperOverlayScroller,
               sv.scrollerStyle == .overlay,
               sv.autohidesScrollers {
                continue
            }

            // 异步解耦：避免在 SwiftUI AttributeGraph 更新或 AppKit 同步布局中途触发 tile() 导致重入崩溃
            DispatchQueue.main.async {
                install(on: sv)
            }
        }
    }

    // MARK: - 私有实现

    /// 安装 PaperOverlayScroller 和 overlay style（幂等）。
    private static func install(on sv: NSScrollView) {
        let oid = ObjectIdentifier(sv)

        // 幂等检查：若已配置且已经是 PaperOverlayScroller + overlay，则无需重复执行
        if configured.contains(oid),
           sv.verticalScroller is PaperOverlayScroller,
           sv.scrollerStyle == .overlay,
           sv.autohidesScrollers {
            return
        }

        // 1. 设置 overlay 与自动隐藏
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true

        // 2. 安装自定义 scroller
        if !(sv.verticalScroller is PaperOverlayScroller) {
            let prev = sv.verticalScroller?.frame ?? .zero
            let scroller = PaperOverlayScroller(frame: prev)
            sv.verticalScroller = scroller
        }

        // 3. 重申 overlay 与自动隐藏并 tile
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true
        sv.tile()

        configured.insert(oid)
    }

    /// 递归查找视图树中所有 NSTableView / NSOutlineView，不进入 WKWebView 子树。
    private static func findListViews(in view: NSView) -> [NSTableView] {
        // 遇到 WKWebView 立即停止（严格保护 ArticleReader）
        let className = String(describing: type(of: view))
        if className.contains("WKWebView") || className.contains("WebView") {
            return []
        }

        var result: [NSTableView] = []
        if let tv = view as? NSTableView {
            result.append(tv)
        }
        for sub in view.subviews {
            result.append(contentsOf: findListViews(in: sub))
        }
        return result
    }
}
// MARK: - View extension (Settings 专用，保留细粒度控制)

/// 仅用于 Settings 等独立面板，通过 SwiftUI background 注入。
/// 3 列主 UI 由 PaperNativeScrollStyler 处理，不用此方法。
extension View {
    public func paperListScrollStyle() -> some View {
        #if os(macOS)
        background(PaperScrollViewCustomizer())
        #else
        self
        #endif
    }
}

#if os(macOS)
// MARK: - PaperScrollViewCustomizer (Settings / standalone panel 专用)

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
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true
            if !(sv.verticalScroller is PaperOverlayScroller) {
                let scroller = PaperOverlayScroller(frame: sv.verticalScroller?.frame ?? .zero)
                sv.verticalScroller = scroller
            }
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true
            sv.tile()
        }
    }
}
#endif

#else
extension View {
    public func paperListScrollStyle() -> some View { self }
}
#endif
