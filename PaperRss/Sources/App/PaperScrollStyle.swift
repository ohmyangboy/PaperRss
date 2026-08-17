import SwiftUI
#if os(macOS)
import AppKit

/// A thin overlay scroller that completely suppresses the permanent opaque background track/slot
/// while preserving native macOS knob dragging, momentum scrolling, and accessibility.
final class PaperOverlayScroller: NSScroller {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.controlSize = .small
        self.knobStyle = .default
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.controlSize = .small
        self.knobStyle = .default
    }

    override class var isCompatibleWithOverlayScrollers: Bool {
        return true
    }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { /* lock to overlay style */ }
    }

    override var isOpaque: Bool {
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        // Suppress drawing the background track completely; only render the floating knob.
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Suppress drawing the gray knob slot/gutter for a quiet, thin overlay appearance.
    }
}

private struct PaperScrollViewCustomizer: NSViewRepresentable {
    func makeNSView(context: Context) -> CustomizerView {
        let view = CustomizerView()
        return view
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
                var current: NSView? = self
                while let candidate = current {
                    if let scrollView = candidate as? NSScrollView {
                        scrollView.scrollerStyle = .overlay
                        scrollView.autohidesScrollers = true
                        scrollView.scrollerKnobStyle = .default
                        if !(scrollView.verticalScroller is PaperOverlayScroller) {
                            let scroller = PaperOverlayScroller()
                            scrollView.verticalScroller = scroller
                        }
                        break
                    }
                    current = candidate.superview
                }
            }
        }
    }
}

extension View {
    /// Applies a polished, thin overlay scrollbar to macOS List and ScrollView containers.
    /// Strictly scoped to the target view container without modifying global appearance
    /// or Reader WKWebView components.
    public func paperListScrollStyle() -> some View {
        self.background(PaperScrollViewCustomizer())
    }
}
#else
extension View {
    public func paperListScrollStyle() -> some View {
        self
    }
}
#endif
