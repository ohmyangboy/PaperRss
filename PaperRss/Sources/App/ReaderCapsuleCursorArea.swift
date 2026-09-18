#if os(macOS)
import AppKit
import SwiftUI

/// 阅读工具栏胶囊区域的光标锚定视图。
///
/// 禅模式下顶部工具栏是透明的、胶囊浮在正文之上；胶囊自身不声明光标时，
/// 窗口会沿视图层级取到下方 WebView 的文本光标（I-beam）。这里在胶囊范围内
/// 固定箭头光标，同时不参与命中测试，因此不会抢走按钮点击。
struct ReaderCapsuleCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}
#endif
