import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const root = await readFile(new URL('../PaperRss/Sources/App/RootView.swift', import.meta.url), 'utf8');
const settings = await readFile(new URL('../PaperRss/Sources/App/SettingsView.swift', import.meta.url), 'utf8');

test('侧栏按独立分组筛选，切换文章和订阅不清除，关闭后恢复顺序', async () => {
  const methods = root.match(/    private var filtersUnreadFeeds:[\s\S]*?    private func visibleFeeds[\s\S]*?^    \}\n/m)?.[0];
  assert.ok(methods, 'filtersUnreadFeeds 与 visibleFeeds 必须可整体提取');
  assert.ok(!methods.includes('setUnreadFilteredGroups'), '提取片段只允许包含纯筛选逻辑');
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
  assert.match(root, /@AppStorage\("timeline_unread_filter_scopes_raw"\) private var articleFilteredScopesRaw/);
  assert.match(root, /@AppStorage\("sidebar_unread_filter_groups_raw"\) private var unreadFilteredGroupsRaw/);
  assert.match(root, /selection == row \|\| unreadFilteredGroups.contains\(row\)/);
  assert.match(root, /isFolderExpandedBinding\(key:.*wrappedValue = true/);
  assert.match(root, /reduceMotion \? nil : \.timingCurve/);
});

test('取消Feed源过滤保留账号与文件夹展开状态，仅开启时自动展开', () => {
  const action = root.match(/    private func filterAction\(for row: SidebarSelection\)[\s\S]*?^    \}\n/m)?.[0];
  assert.ok(action, 'filterAction 必须可整体提取');
  assert.match(action, /let enabling = !unreadFilteredGroups\.contains\(row\)/);
  assert.match(action, /guard enabling else \{ return \}/);
  assert.match(action, /isFolderExpandedBinding\(key:.*wrappedValue = true/, '开启Feed源过滤仍应展开有未读的文件夹');
  assert.doesNotMatch(action, /wrappedValue = false/, '取消Feed源过滤不得收起账号或文件夹');
});

test('Feed源过滤与文章过滤互不联动，文章过滤按范围独立记忆', () => {
  const extract = (pattern) => root.match(pattern)?.[0];
  const stripComments = (snippet) =>
    snippet
      .split('\n')
      .map((line) => line.replace(/\/\/.*$/, ''))
      .join('\n');
  const filterAction = extract(/    private func filterAction\(for row: SidebarSelection\)[\s\S]*?^    \}\n/m);
  const clearFeedFilters = extract(/    private func clearFeedFilters\(in scope: SidebarSelection\)[\s\S]*?^    \}\n/m);
  const clearArticleFilters = extract(/    private func clearArticleFilters\(in scope: SidebarSelection\)[\s\S]*?^    \}\n/m);
  const toggleArticleFilter = extract(/    private func toggleUnreadFilter\(\)[\s\S]*?^    \}\n/m);
  assert.ok(filterAction && clearFeedFilters && clearArticleFilters && toggleArticleFilter, '四个过滤动作必须可整体提取');

  for (const snippet of [filterAction, clearFeedFilters]) {
    assert.doesNotMatch(stripComments(snippet), /unreadOnly|articleFilteredScopes|toggleUnreadFilter/, 'Feed源过滤不得读写文章过滤状态');
  }
  for (const snippet of [clearArticleFilters, toggleArticleFilter]) {
    assert.doesNotMatch(stripComments(snippet), /unreadFilteredGroups|clearAllFeedFilters/, '文章过滤不得读写Feed源过滤状态');
  }

  assert.match(root, /onClearFeedFilters: \{ clearFeedFilters\(in: \$0\) \}/, '清除订阅过滤绑定独立回调');
  assert.match(root, /onClearArticleFilters: \{ clearArticleFilters\(in: \$0\) \}/, '清除文章过滤绑定独立回调');

  // 文章过滤不是全局固定开关：按当前范围切换，只看该范围自己的键
  assert.match(root, /supportsUnreadFilter && articleFilteredScopes\.contains\(currentSelection\)/);
  assert.match(toggleArticleFilter, /scopes\.contains\(currentSelection\)/);
  assert.match(toggleArticleFilter, /scopes\.insert\(currentSelection\)/);
  assert.match(toggleArticleFilter, /scopes\.remove\(currentSelection\)/);
  assert.match(root, /private var articleFilteredScopes: Set<SidebarSelection>/);
});

test('未读过滤状态跨启动持久化：编码稳定且可还原', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'paper-sidebar-filter-key-'));
  try {
    const path = join(dir, 'check.swift');
    const keySource = root.match(
      /    \/\/\/ 未读订阅过滤只作用在账号与文件夹两级行[\s\S]*?static func unreadFilterGroup\(from key: String\) -> SidebarSelection\? \{[\s\S]*?^    \}\n/m,
    )?.[0];
    assert.ok(keySource, 'SidebarSelection 过滤键编解码必须可整体提取');
    await writeFile(path, `
import Foundation
enum SidebarSelection: Hashable {
  case account(String), folder(accountID: String, folderName: String), feed(UUID), feeds(Set<UUID>), unread, today
  ${keySource}
}

// 编解码往返：账号、含冒号的文件夹名、非过滤级选择
let groups: Set<SidebarSelection> = [
  .account("local-default"),
  .folder(accountID: "freshrss-1", folderName: "科技:AI"),
  .feed(UUID())
]
let encoded = groups.compactMap(\\.unreadFilterGroupKey).sorted().joined(separator: "\\n")
assert(encoded == "account:local-default\\nfolder:freshrss-1:科技:AI")
let decoded = Set(encoded.split(separator: "\\n").map(String.init).compactMap(SidebarSelection.unreadFilterGroup(from:)))
assert(decoded.count == 2, "feed 级选择不参与持久化")
assert(decoded.contains(.account("local-default")))
assert(decoded.contains(.folder(accountID: "freshrss-1", folderName: "科技:AI")))
assert(SidebarSelection.unreadFilterGroup(from: "folder:acc") == nil, "缺文件夹名的键必须被拒绝")
assert(SidebarSelection.unreadFilterGroup(from: "starred") == nil, "未知键必须被拒绝")
assert(SidebarSelection.feed(UUID()).unreadFilterGroupKey == nil, "订阅行没有过滤入口")
`);
    execFileSync('xcrun', ['swift', path], { timeout: 60000, encoding: 'utf8' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('文章过滤按范围独立持久化：Feed/文件夹/账号/多选编码稳定且可还原', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'paper-article-filter-key-'));
  try {
    const path = join(dir, 'check.swift');
    const keySource = root.match(
      /    \/\/\/ 文章过滤（列表[\s\S]*?static func articleFilterScope\(from key: String\) -> SidebarSelection\? \{[\s\S]*?^    \}\n/m,
    )?.[0];
    assert.ok(keySource, '文章过滤范围键编解码必须可整体提取');
    await writeFile(path, `
import Foundation
enum SidebarSelection: Hashable {
  case account(String), folder(accountID: String, folderName: String), feed(UUID), feeds(Set<UUID>), unread, today, starred
  ${keySource}
}

let feedA = UUID()
let feedB = UUID()
let scopes: Set<SidebarSelection> = [
  .account("local-default"),
  .folder(accountID: "freshrss-1", folderName: "科技:AI"),
  .feed(feedA),
  .feeds(Set([feedA, feedB]))
]
assert(scopes.contains(.feeds(Set([feedB, feedA]))), "多选集合无序")
let encoded = scopes.compactMap(\\.articleFilterScopeKey).sorted().joined(separator: "\\n")
assert(encoded.contains("account:local-default"))
assert(encoded.contains("folder:freshrss-1:科技:AI"))
assert(encoded.contains("feed:\\(feedA.uuidString)"))
assert(encoded.contains("feeds:\\([feedA.uuidString, feedB.uuidString].sorted().joined(separator: ","))"))
let decoded = Set(encoded.split(separator: "\\n").map(String.init).compactMap(SidebarSelection.articleFilterScope(from:)))
assert(decoded.count == 4, "四个范围都必须可还原")
assert(decoded.contains(.account("local-default")))
assert(decoded.contains(.folder(accountID: "freshrss-1", folderName: "科技:AI")))
assert(decoded.contains(.feed(feedA)))
assert(decoded.contains(.feeds(Set([feedA, feedB]))))
assert(SidebarSelection.articleFilterScope(from: "feed:not-a-uuid") == nil, "非法 UUID 必须被拒绝")
assert(SidebarSelection.articleFilterScope(from: "feeds:") == nil, "空多选必须被拒绝")
assert(SidebarSelection.articleFilterScope(from: "feeds:\\(feedA.uuidString),bad") == nil, "多选含非法 UUID 必须整体拒绝")
assert(SidebarSelection.articleFilterScope(from: "starred") == nil, "未知键必须被拒绝")
assert(SidebarSelection.today.articleFilterScopeKey == nil)
assert(SidebarSelection.unread.articleFilterScopeKey == nil)
assert(SidebarSelection.starred.articleFilterScopeKey == nil)
assert(SidebarSelection.feeds([]).articleFilterScopeKey == nil, "空多选不产生键")
`);
    execFileSync('xcrun', ['swift', path], { timeout: 60000, encoding: 'utf8' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('右键按行子树清除：账号两个入口，文件夹/订阅仅文章过滤，无可清除时禁用', () => {
  const menu = root.match(/    private func unreadFilterClearMenuItems\(for scope: SidebarSelection, includesFeedFilters: Bool\)[\s\S]*?^    \}\n/m)?.[0];
  assert.ok(menu, '清除菜单组必须可整体提取');
  assert.match(root, /private func clearFeedFilters\(in scope: SidebarSelection\)/);
  assert.match(root, /private func clearArticleFilters\(in scope: SidebarSelection\)/);
  assert.equal((root.match(/unreadFilterClearMenuItems\(for: /g) ?? []).length, 7, '7 处注入（账号 1、文件夹 2、订阅单选/多选 4）');
  assert.equal((root.match(/includesFeedFilters: true/g) ?? []).length, 1, '仅账号行提供 Feed 源过滤清除');
  assert.equal((root.match(/includesFeedFilters: false/g) ?? []).length, 6);
  assert.match(menu, /if includesFeedFilters \{/);
  assert.match(menu, /\.disabled\(!unreadFilteredGroups\.contains \{ sidebarScopeContains\(scope, \$0, store: store\) \}\)/);
  assert.match(menu, /\.disabled\(!articleFilteredScopes\.contains \{ sidebarScopeContains\(scope, \$0, store: store\) \}\)/);
  assert.match(root, /var articleFilteredScopes: Set<SidebarSelection>/);
  assert.match(root, /var onClearFeedFilters: \(SidebarSelection\) -> Void/);
  assert.match(root, /var onClearArticleFilters: \(SidebarSelection\) -> Void/);
  assert.match(root, /清除所有订阅过滤/);
  assert.match(root, /清除所有文章过滤/);
});

test('按行子树判定：账号含文件夹/订阅/多选，文件夹含订阅，子范围不含父范围', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'paper-filter-scope-'));
  try {
    const path = join(dir, 'check.swift');
    const helper = root.match(/extension SidebarSelection \{[\s\S]*?^\}\n/m)?.[0];
    assert.ok(helper, 'containsFilterScope 必须可整体提取');
    await writeFile(path, `
import Foundation
enum SidebarSelection: Hashable {
  case account(String), folder(accountID: String, folderName: String), feed(UUID), feeds(Set<UUID>), unread, today, starred
}
${helper}

let a1 = UUID(), a2 = UUID(), b1 = UUID()
let accountFeeds: (String) -> Set<UUID> = { $0 == "A" ? [a1, a2] : ($0 == "B" ? [b1] : []) }
let folderFeeds: (String, String) -> Set<UUID> = { account, folder in account == "A" && folder == "F" ? [a1] : [] }
func inScope(_ scope: SidebarSelection, _ candidate: SidebarSelection) -> Bool {
  scope.containsFilterScope(candidate, accountFeeds: accountFeeds, folderFeeds: folderFeeds)
}

let accountA = SidebarSelection.account("A")
let folderAF = SidebarSelection.folder(accountID: "A", folderName: "F")
let feedA1 = SidebarSelection.feed(a1)
let multi = SidebarSelection.feeds(Set([a1, b1]))

// 账号子树：自身、其文件夹、其订阅、完全落在账号内的多选
assert(inScope(accountA, .account("A")))
assert(inScope(accountA, folderAF))
assert(inScope(accountA, feedA1))
assert(inScope(accountA, .feeds(Set([a1, a2]))))
assert(!inScope(accountA, .account("B")))
assert(!inScope(accountA, .folder(accountID: "B", folderName: "F")))
assert(!inScope(accountA, .feed(b1)))
assert(!inScope(accountA, multi), "跨账号多选不属于该账号")

// 文件夹子树：自身、其订阅、完全落在文件夹内的多选；不含父范围
assert(inScope(folderAF, folderAF))
assert(inScope(folderAF, feedA1))
assert(inScope(folderAF, .feeds(Set([a1]))))
assert(!inScope(folderAF, .feed(a2)))
assert(!inScope(folderAF, .feeds(Set([a1, a2]))), "跨文件夹多选不属于该文件夹")
assert(!inScope(folderAF, .account("A")), "父范围不属于子行")

// 订阅行只含自身；多选行含选中集合内的订阅
assert(inScope(feedA1, feedA1))
assert(!inScope(feedA1, .feed(a2)))
assert(!inScope(feedA1, .account("A")))
assert(inScope(multi, .feed(a1)))
assert(inScope(multi, .feed(b1)))
assert(!inScope(multi, .feed(a2)))
assert(inScope(multi, .feeds(Set([a1]))))
assert(!inScope(multi, .feeds(Set([a1, a2]))))
`);
    execFileSync('xcrun', ['swift', path], { timeout: 60000, encoding: 'utf8' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('列表工具栏图标与阅读工具栏共用字号', async () => {
  const chrome = await readFile(new URL('../PaperRss/Sources/App/ThreeColumnSplitView.swift', import.meta.url), 'utf8');
  const reader = await readFile(new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url), 'utf8');
  assert.match(chrome, /pointSize: ReaderCapsuleToolbar.symbolPointSize, weight: \.medium/);
  assert.match(chrome, /let side: CGFloat = 18/);
  assert.match(chrome, /button.image = listToolbarImage\(button.image\)/);
  assert.match(reader, /font\(\.system\(size: Self.symbolPointSize, weight: \.medium\)\)/);
});
