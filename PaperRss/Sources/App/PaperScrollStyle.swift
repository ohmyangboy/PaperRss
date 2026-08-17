import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - View Compatibility Extension

extension View {
    /// 兼容性保留修饰符（3 栏主界面已由 PaperColumnContainerController 统一接管独立浮层滚动条，零侵入）
    public func paperListScrollStyle() -> some View {
        self
    }
}
