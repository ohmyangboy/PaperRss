import AppKit
import Foundation
import XCTest

@MainActor
final class EntryListTitleToolbarLayoutTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testThreeColumnSplitViewImplementsTitleTruncationAndButtonProtection() throws {
        let splitViewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/ThreeColumnSplitView.swift"),
            encoding: .utf8
        )

        // 1. 标题必须配置单行与尾部截断
        XCTAssertTrue(splitViewSource.contains("label.lineBreakMode = .byTruncatingTail"))
        XCTAssertTrue(splitViewSource.contains("label.maximumNumberOfLines = 1"))
        XCTAssertTrue(splitViewSource.contains("label.usesSingleLineMode = true"))
        XCTAssertTrue(splitViewSource.contains("label.allowsDefaultTighteningForTruncation = true"))

        // 2. 标题必须解除自动转换约束，并降低水平压缩抗性，使系统优先压缩标题而非按钮
        XCTAssertTrue(splitViewSource.contains("label.translatesAutoresizingMaskIntoConstraints = false"))
        XCTAssertTrue(splitViewSource.contains("label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(50), for: .horizontal)"))

        // 3. 必须通过约束限制最大宽度，并预留按钮所需空间
        XCTAssertTrue(splitViewSource.contains("label.widthAnchor.constraint(lessThanOrEqualToConstant: maxTitleWidth)"))
        XCTAssertTrue(splitViewSource.contains("let reservedWidth: CGFloat = actions.showsUnreadFilter ? 116 : 76"))
        XCTAssertTrue(splitViewSource.contains("let maxTitleWidth = max(40, columnWidth - reservedWidth)"))

        // 4. 按钮必须声明 required 水平抗压缩，避免被撑出中间栏
        XCTAssertTrue(splitViewSource.contains("button.setContentCompressionResistancePriority(.required, for: .horizontal)"))

        // 5. 必须监听 splitView 子视图尺寸变化，动态同步标题宽度上限
        XCTAssertTrue(splitViewSource.contains("NSSplitView.didResizeSubviewsNotification"))
        XCTAssertTrue(splitViewSource.contains("updateTitleWidthLimit()"))

        // 6. 截断时提供 toolTip 提示完整 Feed 名称
        XCTAssertTrue(splitViewSource.contains("label.toolTip = actions.selectionTitle"))
    }

    func testLongTitleTextFieldFittingSizeIsBoundedByMaxWidthConstraint() {
        let longTitle = "Share & showcase - Obsidian Forum (Very Long Feed Title That Could Overflow Column)"
        let label = NSTextField(labelWithString: longTitle)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(50), for: .horizontal)

        let intrinsicWidth = label.intrinsicContentSize.width
        XCTAssertGreaterThan(intrinsicWidth, 200, "长标题的原始测量宽度应远大于 200pt")

        let maxAllowedWidth: CGFloat = 140
        let constraint = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxAllowedWidth)
        constraint.isActive = true

        let fitting = label.fittingSize
        // NSTextField fittingSize 包含微小 cell 边距，应受控在约束附近（允许 <= maxAllowedWidth + 6）
        XCTAssertLessThanOrEqual(fitting.width, maxAllowedWidth + 6, "施加最大宽度约束后，fittingSize 必须受控于设定上限")
    }

    func testShortTitleTextFieldDoesNotExpandToMaxWidth() {
        let shortTitle = "今天"
        let label = NSTextField(labelWithString: shortTitle)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(50), for: .horizontal)

        let maxAllowedWidth: CGFloat = 200
        let constraint = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxAllowedWidth)
        constraint.isActive = true

        let fitting = label.fittingSize
        XCTAssertLessThan(fitting.width, 60, "短标题不应被最大宽度约束拉伸")
    }
}
