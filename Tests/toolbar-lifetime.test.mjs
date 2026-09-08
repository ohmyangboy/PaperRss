import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

test('侧栏与禅模式往返保持工具栏顺序和阅读实例', async () => {
  const source = await readFile(process.env.PAPERRSS_TOOLBAR_SOURCE ?? new URL('../PaperRss/Sources/App/ThreeColumnSplitView.swift', import.meta.url), 'utf8');
  const start = source.indexOf('                if compactToolbarLayout != isSidebarCollapsed {');
  const end = source.indexOf('                let buttonIDs:', start);
  assert.ok(start >= 0 && end > start);
  const block = source.slice(start, end);
  const headerStart = source.indexOf('            if let toolbar = splitViewController?.view.window?.toolbar, !actions.isZenMode');
  const headerEnd = source.indexOf('            if let button = unreadFilterButton {', headerStart);
  assert.ok(headerStart >= 0 && headerEnd > headerStart);
  const header = source.slice(headerStart, headerEnd).replace('if let toolbar = splitViewController?.view.window?.toolbar, ', 'if ');
  const zenStart = source.indexOf('        private func syncLegacyToolbarItemVisibility(');
  const zenEnd = source.indexOf('        // MARK: NSToolbarDelegate', zenStart);
  assert.ok(zenStart >= 0 && zenEnd > zenStart);
  const zen = source.slice(zenStart, zenEnd).replace('private func', 'func');
  const dir = await mkdtemp(join(tmpdir(), 'paper-toolbar-lifetime-'));
  try {
    const path = join(dir, 'check.swift');
    await writeFile(path, `
import Foundation
// 用引用对象模拟工具栏项生命周期，执行生产代码的实际显隐逻辑。
protocol NSToolbarDelegate {}
final class NSToolbarItem {
    struct Identifier: Hashable {
        let value: String
        init(_ value: String) { self.value = value }
        static let flexibleSpace = Self("space")
    }
    let itemIdentifier: Identifier
    init(itemIdentifier: Identifier) { self.itemIdentifier = itemIdentifier }
}
final class NSToolbar {
    var items: [NSToolbarItem] = []
    var delegate: NSToolbarDelegate?
    init(identifier: String) {}
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
    static let paperAddMenu = Self("add")
    static let paperMarkAllRead = Self("mark")
    static let paperUnreadFilter = Self("filter")
}
final class Harness: NSObject, NSToolbarDelegate {
    var compactToolbarLayout: Bool?
    var zenRemovedToolbarItemIndexes: [NSToolbarItem.Identifier: Int] = [:]
    struct Actions { var isZenMode = false; var showsUnreadFilter = true }
    var actions = Actions()
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.paperAddMenu, .paperSidebarTracker, .paperEntryListTitle, .flexibleSpace,
         .paperMarkAllRead, .paperTimelineTracker, .flexibleSpace, .paperReaderCapsule, .flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        NSToolbarItem(itemIdentifier: id)
    }
    func sync(_ toolbar: NSToolbar, collapsed isSidebarCollapsed: Bool) {
${block}
    }
    func header(_ toolbar: NSToolbar, collapsed isSidebarCollapsed: Bool) {
${header}
    }
${zen}
}
let harness = Harness()
let toolbar = NSToolbar(identifier: "test")
toolbar.delegate = harness
for (index, id) in harness.toolbarDefaultItemIdentifiers(toolbar).enumerated() {
    toolbar.insertItem(withItemIdentifier: id, at: index)
}
let reader = toolbar.items.first { $0.itemIdentifier == .paperReaderCapsule }!
for collapsed in [false, false, true, true, false, true, false] {
    harness.sync(toolbar, collapsed: collapsed)
    assert(toolbar.items.first { $0.itemIdentifier == .paperReaderCapsule } === reader,
           "阅读工具栏被销毁重建")
    assert(toolbar.items.contains { $0.itemIdentifier == .paperTimelineTracker } == !collapsed)
}
// 复现实际 update 调用顺序：先同步 Header，此时分栏仍处于禅模式的收起状态，
// 随后展开分栏、恢复结构项，最后再次同步 Header。
for showsUnreadFilter in [false, true] {
    harness.actions.showsUnreadFilter = showsUnreadFilter
    harness.header(toolbar, collapsed: false)
    let expected = toolbar.items.map(\\.itemIdentifier)
    for _ in 0..<3 {
        harness.actions.isZenMode = true
        harness.syncLegacyToolbarItemVisibility(in: toolbar, isZenMode: true)
        harness.header(toolbar, collapsed: true)
        harness.actions.isZenMode = false
        harness.header(toolbar, collapsed: true)
        harness.syncLegacyToolbarItemVisibility(in: toolbar, isZenMode: false)
        harness.header(toolbar, collapsed: false)
        assert(toolbar.items.map(\\.itemIdentifier) == expected, "退出禅模式后工具栏顺序改变")
        assert(toolbar.items.first { $0.itemIdentifier == .paperReaderCapsule } === reader)
    }
}
`);
    execFileSync('xcrun', ['swift', '-module-cache-path', '/tmp/paperrss-swift-module-cache', path], { timeout: 60000, encoding: 'utf8' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});
