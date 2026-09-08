import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

test('展开收起和首次同步均保留阅读工具栏实例', async () => {
  const source = await readFile(process.env.PAPERRSS_TOOLBAR_SOURCE ?? new URL('../PaperRss/Sources/App/ThreeColumnSplitView.swift', import.meta.url), 'utf8');
  const start = source.indexOf('                if compactToolbarLayout != isSidebarCollapsed {');
  const end = source.indexOf('                let buttonIDs:', start);
  assert.ok(start >= 0 && end > start);
  const block = source.slice(start, end);
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
}
final class Harness: NSObject, NSToolbarDelegate {
    var compactToolbarLayout: Bool?
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
`);
    execFileSync('xcrun', ['swift', '-module-cache-path', '/tmp/paperrss-swift-module-cache', path], { timeout: 60000, encoding: 'utf8' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});
