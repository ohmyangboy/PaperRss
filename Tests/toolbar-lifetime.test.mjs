import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

function method(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, `Missing production method: ${signature}`);
  const brace = source.indexOf('{', start);
  let depth = 1;
  let end = brace + 1;
  while (depth && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}

test('列表、杂志、卡片阅读、侧栏与禅模式往返保持居中布局和工具栏实例', async () => {
  const source = await readFile(process.env.PAPERRSS_TOOLBAR_SOURCE ?? new URL('../PaperRss/Sources/App/ThreeColumnSplitView.swift', import.meta.url), 'utf8');
  const order = method(source, 'func toolbarItemOrder(');
  const reconcile = method(source, 'func reconcileToolbarItems(');
  const dir = await mkdtemp(join(tmpdir(), 'paper-toolbar-lifetime-'));
  try {
    const path = join(dir, 'check.swift');
    await writeFile(path, `
import Foundation
// Execute the production order and reconciliation, not a copied approximation.
final class NSToolbarItem {
    struct Identifier: Hashable {
        let value: String
        init(_ value: String) { self.value = value }
        static let flexibleSpace = Self("flex")
        static let space = Self("space")
        static let toggleSidebar = Self("toggle")
    }
    let itemIdentifier: Identifier
    init(itemIdentifier: Identifier) { self.itemIdentifier = itemIdentifier }
}
final class NSToolbar {
    var items: [NSToolbarItem] = []
    func insertItem(withItemIdentifier id: NSToolbarItem.Identifier, at index: Int) {
        items.insert(NSToolbarItem(itemIdentifier: id), at: index)
    }
    func removeItem(at index: Int) { items.remove(at: index) }
}
extension NSToolbarItem.Identifier {
    static let paperSidebarTracker = Self("sidebar")
    static let paperTimelineTracker = Self("timeline")
    static let paperEntryListTitle = Self("title")
    static let paperReaderCapsule = Self("reader")
    static let paperRefresh = Self("refresh")
    static let paperAddMenu = Self("add")
    static let paperMarkAllRead = Self("mark")
    static let paperUnreadFilter = Self("filter")
    static let paperTimelineBack = Self("back")
    static let paperTimelineControls = Self("views")
    static let paperVisualLeadingSpace = Self("visual-leading")
    static let paperVisualTrailingSpace = Self("visual-trailing")
}
final class Harness {
    struct Actions {
        var isZenMode = false
        var showsUnreadFilter = true
        var usesVisualTimeline = false
        var isTimelineBrowsing = false
        var showsTimelineReturn: Bool { usesVisualTimeline && !isTimelineBrowsing && !isZenMode }
    }
    var actions = Actions()
    ${order}
    ${reconcile}
}
let harness = Harness()
let toolbar = NSToolbar()
let initial = harness.toolbarItemOrder(sidebarCollapsed: false)
harness.reconcileToolbarItems(in: toolbar, identifiers: initial)
let reader = toolbar.items.first { $0.itemIdentifier == .paperReaderCapsule }!
let views = toolbar.items.first { $0.itemIdentifier == .paperTimelineControls }!
for _ in 0..<3 {
    for visual in [false, true, true, false] {
        for browsing in [true, false, true] {
            for zen in [false, true, false] {
                for collapsed in [false, true, false] {
                    for filter in [false, true] {
                        harness.actions = .init(isZenMode: zen, showsUnreadFilter: filter,
                                                usesVisualTimeline: visual, isTimelineBrowsing: browsing)
                        let expected = harness.toolbarItemOrder(sidebarCollapsed: collapsed)
                        for _ in 0..<2 { harness.reconcileToolbarItems(in: toolbar, identifiers: expected) }
                        let ids = toolbar.items.map(\\.itemIdentifier)
                        assert(ids == expected, "工具栏顺序与当前路由不一致")
                        assert(toolbar.items.first { $0.itemIdentifier == .paperReaderCapsule } === reader,
                               "阅读胶囊被销毁重建")
                        assert(toolbar.items.last === views, "右上角切换器被销毁或移位")
                        assert(ids.contains(.paperTimelineTracker) == (!visual && !zen),
                               "折叠栏仍保留跟踪分隔项")
                        if harness.actions.showsTimelineReturn {
                            let back = ids.firstIndex(of: .paperTimelineBack)!
                            let capsule = ids.firstIndex(of: .paperReaderCapsule)!
                            let spring = ids.firstIndex(of: .flexibleSpace)!
                            assert(spring < back && back < capsule)
                            assert(ids[back + 1] == .space)
                            assert(!ids.contains(.paperMarkAllRead) && !ids.contains(.paperUnreadFilter),
                                   "阅读态不能保留批量已读或筛选按钮")
                        }
                        if visual && !zen {
                            assert(ids.contains(.paperMarkAllRead) == browsing)
                            assert(ids.contains(.paperUnreadFilter) == (browsing && filter))
                            assert(ids.filter { $0 == .flexibleSpace }.count == 2,
                                   "可视浏览只能有一对对称弹性空间")
                        }
                        if !zen && !visual {
                            let capsule = ids.firstIndex(of: .paperReaderCapsule)!
                            assert(Array(ids[(capsule - 2)...]) == [.paperTimelineBack, .flexibleSpace,
                                .paperReaderCapsule, .flexibleSpace, .paperTimelineControls],
                                "阅读工具两侧的弹性空间必须对称")
                        }
                    }
                }
            }
        }
    }
}
harness.actions = .init()
harness.reconcileToolbarItems(in: toolbar, identifiers: initial)
assert(toolbar.items.map(\\.itemIdentifier) == initial)
print("Verified 1296 route transitions and idempotent repeats")
`);
    const args = ['-module-cache-path', join(dir, 'module-cache'), path];
    execFileSync(process.platform === 'darwin' ? 'xcrun' : 'swift', process.platform === 'darwin' ? ['swift', ...args] : args,
      { timeout: 60000, encoding: 'utf8' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});
