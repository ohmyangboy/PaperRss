import SwiftUI
#if os(macOS)
import AppKit

// MARK: - PaperNativeScrollStyler

/// 安全的 macOS 列表原生滚动条样式配置器。
///
/// 遵循原则：
/// 1. 绝对不替换 SwiftUI 的 verticalScroller 实例（保持系统原生层级与完整生命周期）。
/// 2. 绝对不手动调用 NSScrollView.tile() 或强制刷新布局（彻底杜绝 AttributeGraph 重入崩溃）。
/// 3. 仅设置安全的原生属性：scrollerStyle = .overlay, autohidesScrollers = true, controlSize = .mini。
/// 4. 仅作用于 Column 0（Sidebar）与 Column 1（EntryList），严格隔离 Column 2（ArticleReader / WKWebView）。
@MainActor
enum PaperNativeScrollStyler {

    private static var configured = Set<ObjectIdentifier>()
    private static var isScheduled = false

    /// 在给定的列根视图中调度滚动条配置（防抖合并到下一个 RunLoop 循环）。
    static func scheduleConfiguration(for splitVC: NSSplitViewController) {
        guard !isScheduled else { return }
        isScheduled = true

        DispatchQueue.main.async {
            isScheduled = false
            guard splitVC.splitViewItems.count >= 2 else { return }
            configureListScrollViews(in: splitVC.splitViewItems[0].viewController.view)
            configureListScrollViews(in: splitVC.splitViewItems[1].viewController.view)
        }
    }

    /// 对指定根视图下的 NSTableView / NSOutlineView 宿主 NSScrollView 应用原生 overlay 样式（幂等）。
    static func configureListScrollViews(in rootView: NSView) {
        let tableViews = findListViews(in: rootView)
        if tableViews.isEmpty { return }

        for tv in tableViews {
            guard let sv = tv.enclosingScrollView else { continue }
            let oid = ObjectIdentifier(sv)
            if configured.contains(oid) {
                continue
            }
            // 预先标记已配置，防止重入
            configured.insert(oid)

            // 仅配置原生安全的 overlay 属性，不替换 verticalScroller，不调用 tile()
            if sv.scrollerStyle != .overlay {
                sv.scrollerStyle = .overlay
            }
            if !sv.autohidesScrollers {
                sv.autohidesScrollers = true
            }
            if let scroller = sv.verticalScroller, scroller.controlSize != .mini {
                scroller.controlSize = .mini
            }
        }
    }

    /// 递归查找视图树中所有 NSTableView / NSOutlineView，不进入 WKWebView 子树。
    private static func findListViews(in view: NSView) -> [NSTableView] {
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

// MARK: - View extension

extension View {
    public func paperListScrollStyle() -> some View {
        self
    }
}

#else
extension View {
    public func paperListScrollStyle() -> some View { self }
}
#endif
