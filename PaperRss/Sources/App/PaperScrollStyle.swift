import SwiftUI
#if os(macOS)
import AppKit

/// PaperRss's lightweight scrollbar for ordinary native list surfaces.
///
/// Important: this is installed only by `paperListScrollStyle()` on the
/// Sidebar / article-list style surfaces. It must never be installed globally,
/// otherwise WKWebView / ArticleReader scrolling would be affected as well.
final class PaperOverlayScroller: NSScroller {
    private var pointerInside = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // Keep a comfortable native control/hit area. The visible knob is drawn
        // much thinner in `drawKnob()`, so usability is not traded for styling.
        controlSize = .regular
        knobStyle = .default
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override class var isCompatibleWithOverlayScrollers: Bool {
        true
    }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { /* This scroller is intentionally overlay-only. */ }
    }

    override var isOpaque: Bool {
        false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
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

    override func draw(_ dirtyRect: NSRect) {
        // Do not ask AppKit to draw arrows or a knob slot. A single floating
        // capsule is the complete visual treatment.
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Intentionally transparent: no full-height scrollbar track / gutter.
    }

    override func drawKnob() {
        var nativeKnob = rect(for: .knob)
        guard !nativeKnob.isEmpty, nativeKnob.height > 0 else { return }

        // Keep the native scroller frame as the generous hit target, while the
        // visible thumb stays Codex-like: thin, rounded and quiet.
        let visualWidth: CGFloat = 7
        let trailingInset: CGFloat = 4
        let verticalInset: CGFloat = 1
        let x = max(bounds.minX, bounds.maxX - trailingInset - visualWidth)

        nativeKnob.origin.x = x
        nativeKnob.size.width = visualWidth
        nativeKnob = nativeKnob.insetBy(dx: 0, dy: verticalInset)

        // `secondaryLabelColor` automatically adapts to light/dark appearance.
        // Hover only increases contrast; native overlay visibility still owns
        // the appear/disappear timing.
        let opacity: CGFloat = pointerInside ? 0.42 : 0.24
        let color = NSColor.secondaryLabelColor.withAlphaComponent(opacity)
        color.setFill()

        let radius = visualWidth / 2
        NSBezierPath(
            roundedRect: nativeKnob,
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

private struct PaperScrollViewCustomizer: NSViewRepresentable {
    func makeNSView(context: Context) -> CustomizerView {
        CustomizerView()
    }

    func updateNSView(_ nsView: CustomizerView, context: Context) {
        nsView.applyCustomScrollStyle()
    }

    final class CustomizerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyCustomScrollStyle()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyCustomScrollStyle()
        }

        func applyCustomScrollStyle() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Walk only upward from this explicitly attached helper until
                // the nearest backing NSScrollView is found. Never scan the
                // whole window; that isolation protects ArticleReader/WKWebView.
                var current: NSView? = self
                while let candidate = current {
                    if let scrollView = candidate as? NSScrollView {
                        install(on: scrollView)
                        break
                    }
                    current = candidate.superview
                }
            }
        }

        private func install(on scrollView: NSScrollView) {
            let previousFrame = scrollView.verticalScroller?.frame ?? .zero

            // The geometry requirement comes first: an appearing scrollbar must
            // overlay content instead of shrinking the clip/document width.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.scrollerKnobStyle = .default

            if !(scrollView.verticalScroller is PaperOverlayScroller) {
                let scroller = PaperOverlayScroller(frame: previousFrame)
                scrollView.verticalScroller = scroller
            }

            // Assigning a custom verticalScroller can cause AppKit/SwiftUI to
            // retile the scroll view. Reassert overlay style *after* assignment
            // and tile once so no legacy-width gutter is reserved.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.tile()
        }
    }
}

extension View {
    /// Applies PaperRss's thin, trackless overlay scrollbar to the nearest
    /// native macOS List / ScrollView backing this particular view.
    ///
    /// This is deliberately local rather than an NSScroller appearance proxy,
    /// keeping ArticleReader / WKWebView's special scrollbar untouched.
    public func paperListScrollStyle() -> some View {
        background(PaperScrollViewCustomizer())
    }
}
#else
extension View {
    public func paperListScrollStyle() -> some View {
        self
    }
}
#endif
