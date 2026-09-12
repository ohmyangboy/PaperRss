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

## Content-aware magazine editions and folding navigation

The magazine canvas stays centered at a maximum 1100pt measure. Each edition page
contains a bounded set of loaded stories (normally six on a desktop, adapting to
window width and height). Actual SwiftUI measurements place the next tile in the
shortest available masonry column, rather than reserving the tallest tile's row
height. An available photograph can earn a two-column lead and two supporting
stories; text-only editions do not reserve a lead slot. Short text-only notes use
slightly larger serif type. Single-column windows use compact text-led rows.
Images, title and summary keep their intrinsic height with no blank minimum slots.

The permanent top-right view popover adds two magazine-only preferences:

- Arrangement: balanced edition (default), subscription source, folder, or time.
  Balanced mode clusters sources inside a bounded page and promotes an illustrated
  story for layout, without AI, external requests or changing the underlying SQL
  order. Source/folder grouping is account-aware. Every loaded article is included
  exactly once. All grouping is confined to the currently loaded timeline;
  reaching its end uses the existing database pagination. The list and card modes
  keep their existing sort and filtering semantics.
- Page navigation: continuous scroll (default) or folding pages. The fold is an
  application-local two-panel perspective/shading transition, not a screen-capture
  overlay. Reduce Motion substitutes a short fade. Buttons, Page Up/Page Down and
  deliberate horizontal drags turn pages. A fixed bottom horizontal tick rail
  previews that page's article titles on hover, permits direct jumps and includes
  separate previous/next buttons. It navigates magazine pages of article previews,
  not the paragraphs of a single article. Oversized content remains scrollable
  within a page instead of being truncated to viewport height.

A stable article identity anchors the current page across resizing, regrouping and
reading/return. Page turns only change presentation, never read/star state. Opening
an article collapses the timeline, not the subscription sidebar. The live reader
stays mounted. The browse-only filter/mark-all cluster disappears when opening an article.
The back button is standalone immediately before the centered reader capsule,
and the view switcher stays at the far right. Visual browsing uses exactly two flexible toolbar spaces, with
balanced outer accessories. Existing three-column list and Zen routes are retained.

### Cover regression: Weekly issue 273

On 2026-09-12 the public feed `https://weekly.tw93.fun/rss.xml` advertised the cover
`https://cdn.tw93.fun/uPic/27342.JPG` in Media RSS/enclosure fields. An anonymous
response probe measured 9,176,164 bytes for this original, exceeding the existing
8 MiB thumbnail response limit. The same item's description already supplied a
same-host Cloudflare resized version (width=2000), measured at 759,262 bytes.
The image was extracted correctly but rejected by the bounded byte loader.

Extraction revision 2 prefers an already supplied, verified same-asset resize
before downloading. Scheme, host, port, original path, query and bounded width are
checked; no CDN URL is fabricated and no webpage or Open Graph is fetched.
Requested older entries are repaired in existing 100-item background batches.
Previously extracted covers survive retention/purged bodies. The 8 MiB response
limit, pixel limit, cache isolation and article states are unchanged. A changed URL
also avoids reusing the failed original URL's negative-cache entry.

### Inspiration and verification boundary

Reviewed Mac-Duo at `e60f71bfc14aa54fc01bb5d672c50906140d4716`:
`https://github.com/sumimakito/Mac-Duo`. Its depth renderer uses perspective and
height-dependent dimming/blur over a captured screen texture. The magazine uses
its own application-local page transition inspired by that visual idea; it does not import
Mac-Duo code, dependencies, hardware sensors or screen-recording permissions.

Automated coverage includes stable grouping/IDs, no omissions/duplicates, masonry
non-overlap and compact text, source resize verification, v1-to-v2 backfill with
retained read/star state, toolbar centering/order and controller lifetime. Run
`--core`, `--feature`, `--web`, shell syntax checks and unsigned macOS host build.
Real macOS interaction remains **Manual UI verification required**, especially
fold smoothness, hover rail, repeated fast navigation, large text, long titles,
image-off layouts, source grouping and returning from a translated article.

## Book-leaf turn and scroll hot-path follow-up

Forward navigation keeps the old left half stationary, places the destination
right half underneath, and rotates the old right half around the exact centre
crease by 180 degrees. The reverse face is the destination left half, with its
own 180-degree transform to avoid mirrored text. Backward navigation reverses
this geometry. Mild blur and shading affect only the turning leaf. Reduce Motion
uses a short fade. No screen recording or private APIs are used: the native view
captures only its own visible viewport twice per requested turn, bounded to a
3-million-pixel budget. It does not duplicate live SwiftUI scroll views per half
or do per-frame text measurement. Snapshots are released at completion, resize,
route change and dismantle. Late completions are request-ID checked.

Edition grouping and the article-to-page index are cached by actual inputs.
Repeated scroll offsets on the same page no longer publish state changes;
hover/focus state lives inside the rail. Masonry reuses measurements between size
and placement calls, invalidating for changed geometry/subviews. Magazine no
longer emits unused per-article frame preferences; one frame per lazy page is
sufficient. Appending entries or updating read flags does not force a scroll-to-top.
The image pipeline is still bounded and off-main-thread; it was not loosened.

The bottom rail follows the existing reader TOC's 8-by-3 ticks rotated to 3-by-8,
with identical-size dark active ticks and pale inactive ticks. It floats without
an edge-to-edge material bar, divider or changing-width page pill. Hover and
keyboard focus show only the actual titles on that page, anchored above the tick
and clamped inside the window. Separate previous/next buttons remain on its sides.
This rail still navigates pages, never marks articles read.

Validation: full core/feature/web regression and unsigned macOS build; operation
count tests for grouping/scroll notifications, snapshot bounds, forward/backward
geometry, no-window fallback, and toolbar routing. These are not a measured FPS
claim. **Manual UI verification required** on the maintainer's actual Mac for
capture orientation, fold smoothness, long-page scroll positions and hover edges.
