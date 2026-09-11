# Article preview images and timeline views

- **Status**: accepted
- **Issues**: https://github.com/ohmyangboy/PaperRss/issues/32, https://github.com/ohmyangboy/PaperRss/issues/18
- **Baseline**: main at 012eb1c34057427cd86cf693ea83f88deed97ff2
- **Delivery branch**: feature/issue-32-18-image-views
- **Native acceptance**: Manual UI verification required

## Scope and acceptance

The macOS toolbar has a permanent upper-right view button. Its popover contains
three horizontally arranged icon choices: list, magazine, cards. Existing list
navigation, chronological order, unread-session retention, reader actions,
sidebar, theme and account behavior are preserved. Visual modes use the same
paged timeline and can expand into the reader area; opening an article restores
the reader, and a return-to-browse action restores the visual timeline.

Preview selection uses explicit item images, then the first usable image from
raw description/summary HTML, then content HTML. Local RSS/Atom/JSON Feed and
FreshRSS share selection rules. Metadata is persisted and included in both
list and neighbor projections without loading full HTML into timeline items.
Existing visible pages are backfilled in bounded batches, off the main thread.
No webpage, Open Graph lookup, proxy, new dependency or fabricated cover is used.

Image bytes use an account-isolated, bounded, cancellable memory/disk cache,
with off-main-thread ImageIO downsampling and finite failure caching. URLs are
limited to HTTP(S), with no provider credentials, cookies or referrer forwarded.
The default list retains its former no-image behavior. Explicitly choosing a
view or enabling images opts in; an explicit off preference applies to all views
and is preserved when switching layouts. Missing/failed images fall back to text.

## Data and delivery boundaries

Additive migration only; no change to read/star state or item identity. No real
user library is opened during implementation. Publish a feature branch, never
merge main or publish a release. Existing description HTML that older versions
already discarded cannot be reconstructed; it can be recovered only when the
source returns that item again. The image cache is disposable and not synced.

## Verification

Run core, feature and reader/web regression plus unsigned macOS host build.
Exercise extraction edge cases, metadata insert/update/restoration, bounded
backfill, account isolation, cache cancellation, failure handling and preferences.
The branch's read-only Preview Views Verification workflow records the exact
commit, individual logs and source snapshot. A failing command must fail its
step even when its output is piped through tee. No signing/deployment occurs.

Actual macOS interaction remains **Manual UI verification required** until a
maintainer checks split widths, focus, keyboard shortcuts, scroll restoration,
all three layouts, image-off behavior, dark/light themes and long mixed feeds.
Do not close the Issues or merge/release solely on the basis of a CI result.

## 本地二次验收

建议用单独 worktree 和隔离数据目录，避免切换当前工作区或打开日常数据库：

```bash
git fetch origin
git worktree add -b review/image-views ../PaperRss-image-views origin/feature/issue-32-18-image-views
cd ../PaperRss-image-views
mkdir -p .scratch/ui-review
./scripts/dev.sh --isolated "$PWD/.scratch/ui-review"
```

该目录保留测试用数据，便于反复启动；不要把正式数据库直接作为隔离目录使用。
导入一份测试 OPML，加入有图、无图和 description 带图的订阅，并添加测试 FreshRSS
账号。先检查三栏列表，再点击右上角常驻按钮选择杂志、卡片；点击文章后返回浏览，
检查位置/选择/已读状态。手动关闭配图后切换三种视图，确认仍为纯文字。最后检查
窄窗口、侧栏折叠、禅模式、上下箭头/回车/空格、深浅主题、收藏和上下篇导航。

本轮另外修正测试夹具对非隔离 async XCTestCase 默认 setup/teardown 的多余调用，
以及 Node 测试辅助函数覆盖子进程 PATH 的问题；没有改动相应产品功能或跳过断言。
