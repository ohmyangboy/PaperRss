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

## 2026-09-12 整页出版编排与 Duo 翻页（已批准）

杂志以一张完整纸面为视觉主体，最大宽度 1100pt，宽窗口两侧各 40pt、
窄窗口各 20pt。两栏间距 32pt，章节间距 40pt。文章不再使用常驻卡片
边框，保留选中和悬停反馈；卡片模式沿用原有样式。

App 层测量与显示共用字体、图片高度和标题/摘要行数，生成有序文章、角色
和位置组成的页面结果。主稿为 32–36pt 衬线标题，次稿 22pt，短讯 20pt，
摘要 15pt。图片主稿、文字主稿及短讯双栏根据内容确定；窄窗口单栏。
按可用高度逐篇放入，剩余文章进入下一页，不保留页内滚动。极小窗口的
单篇预览先去图片、收摘要，再限制标题行数，完整内容仍通过阅读器打开。

分页、标题导航和键盘导航共用一个顺序。智能编排不调用 AI；来源、文件夹、
时间选项保留。追加数据与已读状态更新保留已有页面位置，字号和字重不因已读
改变。窗口与编排变更按文章身份恢复。图片失败使用同页文字空间，不跨页移动。

翻页仅捕获本应用源页和目标页，每张限制三百万像素。原生 Metal 渲染器从固定
观察平面投影图片，右半页向左翻，背面显示新左半页；上一页对称。模糊和变暗
随角度与距折线的位置变化，结束帧恢复清晰。点击约 520ms，拖动直接控制进度，
按距离和预测终点完成或回弹。减少动态效果或渲染不可用时使用 120ms 淡化。
所有准备与动画任务有请求身份校验、取消与释放机制，不按帧重新测量或解码。

底部细刻度带前后按钮，无整体胶囊和常驻页数；悬停、聚焦展示实际文章标题。
阅读时隐藏浏览操作，独立返回按钮位于文章工具左侧；文章工具以阅读区域为
视觉中心，浏览时筛选和全部已读以浏览区域为中心。

头图保持提取第 2 版、8 MiB 上限和旧条目后台回填。第 273 期使用 RSS 已有的
同图压缩链接，保持协议、域名、路径、查询和宽度检查，不新增数据库迁移。
参考 https://github.com/chuspeeism/iphone-duo 的固定投影与渐变模糊思路，
使用自编原生渲染实现，无第三方代码或资源移植，无录屏权限。

验证要求：core、feature、工具栏回归、macOS 宿主编译和隔离实例交互。Metal
关键帧由同一着色器离屏验证。测试设置使用独立域并清理。仅创建本地提交，
不推送、合并或发布。未经实际观察的视觉项目保留 Manual UI verification required。

### 本轮验证结果

- 功能回归通过：49 项 Core、35 项 App；覆盖实测排版、图片晚到、追加稳定性、
  Metal 中间帧、宿主重挂载、取消与真实渲染生命周期。
- 工具栏生命周期的 1296 种切换组合通过；macOS 宿主构建成功。
- Core 全量首次仅 5 万条查询性能项超时，其余通过；该项在并行构建结束后
  单独复跑通过，未调整门限。两项原有 App 测试按环境跳过。
- 隔离实例已实际验证连续翻页、拖动完成、跨页跳转、阅读返回、工具栏居中、
  第 273 期头图、配图开关及深浅主题。
- 约三百万像素的离屏 GPU 单帧中位约 0.45ms、P95 约 0.89ms；不包含快照和
  屏幕调度，不能等同于端到端动画帧率。
- Manual UI verification required：屏幕逐帧接缝、慢拖回弹手感、全部窗口尺寸、
  自定义主题、导航浮层边界和端到端帧率。
