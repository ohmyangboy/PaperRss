import SwiftUI
#if os(macOS)
import AppKit

// MARK: - PaperScrollGutter (MODEL B: 稳定保留滚动条槽)

/// 侧边栏与文章列表滚动条固定槽位尺寸与布局常量。
///
/// 遵循原则：
/// 1. 绝不运行时侵入或修改 SwiftUI List 底层的 NSScrollView / NSOutlineView 属性，
///    从根本上彻底杜绝 AttributeGraph 重入异常（AG::precondition_failure）和 AppKit 递归死锁崩溃。
/// 2. 在容器层级（Container Level）预留恒定的滚动条空间，无论是 hidden、hover 还是 active，
///    内容区（未读角标、发布日期、标题等）始终对齐恒定的 trailing 引导线，实现 0 水平位移（Zero Layout Shift）。
/// 3. 严格隔离 Column 2（ArticleReader / WKWebView）。
@MainActor
public enum PaperScrollGutter {
    /// 预留的固定滚动条宽度（基于 macOS 系统小号滚动条或标准 overlay 槽位）。
    public static var width: CGFloat {
        #if os(macOS)
        let style = NSScroller.preferredScrollerStyle
        let w = NSScroller.scrollerWidth(for: .small, scrollerStyle: style)
        return max(w, 10)
        #else
        return 0
        #endif
    }
}

// MARK: - View extension

extension View {
    public func paperListScrollStyle() -> some View {
        self
    }
}

#else
public enum PaperScrollGutter {
    public static var width: CGFloat { 0 }
}

extension View {
    public func paperListScrollStyle() -> some View { self }
}
#endif
