import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const root = await readFile(new URL('../PaperRss/Sources/App/RootView.swift', import.meta.url), 'utf8');
const settings = await readFile(new URL('../PaperRss/Sources/App/SettingsView.swift', import.meta.url), 'utf8');

test('侧栏按独立分组筛选，切换文章和订阅不清除，关闭后恢复顺序', async () => {
  const methods = root.match(/    private var filtersUnreadFeeds:[\s\S]*?(?=    private func filterAction)/)?.[0];
  assert.ok(methods);
  const dir = await mkdtemp(join(tmpdir(), 'paper-sidebar-filter-'));
  try {
    const path = join(dir, 'check.swift');
    await writeFile(path, `
import Foundation
struct Feed: Equatable { let id: Int }
enum SidebarSelection: Hashable {
  case account(String), folder(accountID: String, folderName: String), feed(Int), feeds(Set<Int>), unread, today
}
final class Store {
  var counts = [1: 2, 2: 0, 3: 1]
  func unreadCount(feedID: Int) -> Int { counts[feedID, default: 0] }
  func folders(for accountID: String) -> [String] { ["有未读", "全已读"] }
  func unreadCount(folder: String, accountID: String) -> Int { folder == "有未读" ? counts.values.reduce(0, +) : 0 }
}
struct Sidebar {
  var unreadFilteredGroups: Set<SidebarSelection> = []
  let store = Store()
  var selection: SidebarSelection? = .folder(accountID: "local", folderName: "博客")
  ${methods}
  mutating func verify() {
    let feeds = [Feed(id: 3), Feed(id: 2), Feed(id: 1)]
    func visible(_ account: String = "local", _ folder: String? = "博客") -> [Int] {
      visibleFeeds(feeds, accountID: account, folder: folder).map(\\.id)
    }
    assert(visible() == [3, 2, 1])
    unreadFilteredGroups.insert(.folder(accountID: "local", folderName: "博客"))
    assert(visible() == [3, 1])
    assert(visible("local", "技术") == [3, 2, 1])
    assert(visible("remote", "博客") == [3, 2, 1])
    selection = .feed(1)
    assert(visible() == [3, 1])
    selection = .today
    assert(visible() == [3, 1])
    store.counts[3] = 0
    assert(visible() == [1])
    unreadFilteredGroups.insert(.account("remote"))
    assert(visible("remote", "技术") == [1])
    unreadFilteredGroups.remove(.folder(accountID: "local", folderName: "博客"))
    assert(visible() == [3, 2, 1])
    assert(visible("remote", "技术") == [1])
    unreadFilteredGroups.remove(.account("remote"))
    assert(visible("remote", "技术") == [3, 2, 1])
  }
}
var sidebar = Sidebar()
sidebar.verify()
`);
    execFileSync('xcrun', ['swift', path], { timeout: 60000, encoding: 'utf8' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('账号范围贯穿列表、导航、标读；筛选时避免错位重排', () => {
  assert.equal((root.match(/return \.feeds\(feedIDs: Set\(store.feeds\(for: id\)/g) ?? []).length, 2);
  assert.equal((root.match(/store.markAllRead\(accountID: id\)/g) ?? []).length, 2);
  assert.match(root, /case \.account, \.folder, \.feed, \.feeds: return true/);
  assert.match(root, /onTapGesture \{ selectAccount\(accountID\) \}/);
  assert.equal((root.match(/guard !filtersUnreadFeeds else \{ return \}/g) ?? []).length, 3);
});

test('移除文章联动设置，独立筛选由根视图持有', () => {
  assert.doesNotMatch(root + settings, /sidebarFollowsUnreadFilter/);
  assert.match(root, /@State private var unreadFilteredGroups/);
  assert.match(root, /selection == row \|\| unreadFilteredGroups.contains\(row\)/);
  assert.match(root, /isFolderExpandedBinding\(key:.*wrappedValue = true/);
  assert.match(root, /reduceMotion \? nil : \.timingCurve/);
});

test('列表工具栏图标与阅读工具栏共用字号', async () => {
  const chrome = await readFile(new URL('../PaperRss/Sources/App/ThreeColumnSplitView.swift', import.meta.url), 'utf8');
  const reader = await readFile(new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url), 'utf8');
  assert.match(chrome, /pointSize: ReaderCapsuleToolbar.symbolPointSize, weight: \.medium/);
  assert.match(chrome, /let side: CGFloat = 18/);
  assert.match(chrome, /button.image = listToolbarImage\(button.image\)/);
  assert.match(reader, /font\(\.system\(size: Self.symbolPointSize, weight: \.medium\)\)/);
});
