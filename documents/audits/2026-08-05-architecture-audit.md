# PaperRss 项目审计报告与修复方案

- **审计日期**：2026-08-05
- **审计范围**：全部 18 个 Swift 源文件（7 App + 11 Core，9,370 行）、测试套件、构建配置、发布脚本、仓库卫生
- **审计方法**：逐文件通读 + 实测复现（XMLParser 行为、iOS/macOS 双端构建）+ 独立子代理交叉验证
- **验证基线**：
  - ✅ `swift test`：**35/35 通过**
  - ✅ macOS Debug 构建：**成功**（10 个 Swift 6 严格并发警告）
  - ❌ **iOS 目标构建：失败**（2 个编译错误，详见 P0-1）

---

## 一、发现汇总

| 严重度 | 数量 | 类别 |
|---|---|---|
| **高** | 4 | 1 个 iOS 编译失败（含后台刷新功能损坏）、1 个正文丢失 bug、1 个功能死代码、1 个 AI 调度静默丢弃 |
| **中** | 7 | 翻译失败段落处理缺陷（半截译文冒充最终结果 + 付费重复请求）、双端不同步、持久化放大、状态残留、Swift 6 并发警告 |
| **低** | 11 | 性能、仓库卫生、文档过时、死代码 |

---

## 二、高严重度问题

### H1. iOS 目标无法编译，后台刷新链路整体损坏

**位置**：`PaperRss/Sources/App/RootView.swift:53`、`RootView.swift:736`

两个编译错误（已用 `xcodebuild -scheme "PaperRss iOS"` 实测确认，BUILD FAILED）：

1. `RootView.swift:53`：`BackgroundRefresh.schedule()` 无参调用，但签名是 `schedule(interval: FeedRefreshInterval)`（`BackgroundRefresh.swift:8`，无默认参数）。iOS 的 `.backgroundTask(.appRefresh)` 注册（`PaperRssApp.swift:20-26`）本身是完整的，但调度入口编译不过，整个 BG 刷新链路不成立——README 承诺的"iPhone 后台刷新"功能实际无法构建。
2. `RootView.swift:736`：`EntryListView`（macOS/iOS 共享结构体）直接调用 `.listStyle(.inset(alternatesRowBackgrounds: false))`——`alternatesRowBackgrounds` 是 macOS 专用 API，iOS 编译报错"unavailable in iOS"。

**修复方案**：
- `RootView.swift:53`：改为 `BackgroundRefresh.schedule(interval: store.refreshInterval)`（与 `PaperRssApp.swift:24` 写法一致，显然是笔误）。
- `RootView.swift:736`：加 `#if os(macOS)` 包裹 macOS 专用 listStyle，iOS 分支用 `.listStyle(.inset)` 或 `.plain`。
- 修复后需执行 `xcodebuild -scheme "PaperRss iOS" -destination 'generic/platform=iOS Simulator' build` 验证。

### H2. FeedParser 静默丢弃 `content:encoded` 全文正文（**已修复** 2026-08-05）

**位置**：`PaperRss/Sources/Core/FeedParser.swift:117、144`

**已实测复现**：XMLParser 默认（`shouldProcessNamespaces = false`）的 `elementName` 参数返回**带命名空间前缀的限定名**（`content:encoded`），而 `didStartElement`/`didEndElement` 中的 `let local = elementName.lowercased()` 与 switch case（`"content"`、`"encoded"` 等无前缀名）永不匹配。实测结果：`<content:encoded>` 元素的内容**完全丢失**，条目正文回退为 `<description>` 摘要。

**影响**：`content:encoded` 是 RSS 2.0 生态（WordPress、阮一峰、绝大多数中文博客）最常用的全文正文载体。影响链条：正文丢失 → `sourceText` 变短 → `needsExtraction`（`ArticleExtractor.swift:17`，`sourceText.count < 500` 时触发）→ 依赖网页抓取补正文。后果：慢、易被反爬失败、离线无全文；`dc:creator` 等前缀元素同理丢失作者信息。现有 35 个测试无一覆盖此场景（`testParsesRSSAndUsesGuid` 只用无前缀元素）。

**修复方案（已实施）**：在 `didStartElement`/`didEndElement` 中通过 `localName(of:)` 剥离命名空间前缀（`content:encoded` → `encoded`、`dc:creator` → `creator`），补上 `dc:creator` → `author` 的映射，并将提取条件从"content 总是覆盖"收紧为"先到先得"（`item[key] == nil` 才写入），防止剥离前缀后 `<media:content>` 等媒体模块元素覆盖真正文。

**回归测试**：`testParsesContentEncodedFullBodyAndDcCreator` —— 覆盖 `content:encoded` 正文提取、`dc:creator` 作者提取、`media:content` 不覆盖正文三个断言。

**验证**：`swift test` 37/37 通过；macOS Debug 构建 BUILD SUCCEEDED。

### H3. 定时自动刷新是死代码，设置界面选项完全无效

**位置**：`AppStore.swift:481-507`（`startAutomaticRefresh`）、`AppStore.swift:453-458`、`RootView.swift:51-56`

**已确认**：全项目搜索 `startAutomaticRefresh` 只有定义、无任何调用点。后果链：
- `setRefreshInterval` → `restartAutomaticRefreshIfNeeded`（`AppStore.swift:514`）因 `automaticRefreshTask == nil` 直接 return → 定时循环永远不启动。
- SettingsView 中"运行期间 · 自动刷新订阅"的间隔选项（每 30 分钟 / 1 / 2 / 4 / 8 小时）在 macOS 上**全部无效**。
- `refreshOnLaunch` 开关同样失效——`RootView.swift:51-56` 的 `.task` 无条件 `store.refresh()`，与"仅手动"设置矛盾（启动时仍会刷新全部订阅，`FeedRefreshInterval.manual.detail` 文案明确承诺"应用保持打开时不自动刷新；打开应用时仍会按上方开关刷新"，但开关从未生效）。

**修复方案**：在 `PaperRssApp` 的 `RootView` `.task` 中调用一次 `store.startAutomaticRefresh()`（与 `.task` 内的首刷并存即可）；若想尊重 `refreshOnLaunch`，把 `RootView.swift:55` 的无条件 `await store.refresh()` 收进 `refreshOnLaunch` 判断或复用 `startAutomaticRefresh` 内部的首刷逻辑（现逻辑已含 `if self.refreshOnLaunch` 判断）。修复后手动验证：设置为"每 30 分钟"后日志应周期性刷新、设为"仅手动"后不再自动刷新。

### H4. 全局 AI 单锁：视口翻译被静默丢弃且链不恢复

**位置**：`AppStore.swift:875-878、971、1078、1160`；`ArticleReaderView.swift:673-716`

- `translateBilingualParagraphs`（`AppStore.swift:1160`）在 `activeAIRequest != nil` 时**静默 return**——无错误、无排队、无重试。
- `requestVisibleTranslationsIfPossible`（`ArticleReaderView.swift:676`）在 AI 忙时同样静默 return，且**不重新调度**：若此时有摘要/划词解释在跑，视口翻译被跳过；当占用者完成后没有事件触发恢复，用户必须手动滚动一下才能重新发起翻译链。
- `generateSummary` 用 `lastError = "已有 AI 任务正在进行…"` 拒绝（`AppStore.swift:876`）；划词解释/选区翻译抛 `requestInProgress`。
- 该问题在 HANDOFF（2026-07-31）已记录为"推荐下一步 2"：统一 AI 请求调度，但至今未实施。

**影响**：双语模式下若先点摘要再滚动，新增可见段落可能长时间不翻译；多个功能互相阻塞。

**修复方案**（按 HANDOFF 建议落地优先级队列）：
1. **短期（低风险）**：把 `translateBilingualParagraphs` 的 `guard activeAIRequest == nil else { return }` 改为在视图层排队：`requestVisibleTranslationsIfPossible` 设置一个 `pendingRequestedBatch`，当 `activeAIRequest` 变为 nil 时（通过 `onChange(of: store.activeAIRequest)` 或请求完成回调）自动重新调用。同时 `ArticleReaderView` 在翻译 Task 完成后已有尾部 `requestVisibleTranslationsIfPossible()`，把同一逻辑补到摘要/解释完成路径。
2. **中期**：AppStore 增加统一优先级队列（用户划词 > 当前视口翻译 > 预加载翻译 > 自动摘要），用 `@Published pendingAIRequests: [AIRequestStatus]` 替代单一 `activeAIRequest` 语义；`isGeneratingAI` 保持不变供 UI 读取。

---

## 三、中严重度问题

### M1. 翻译失败段落的处理缺陷：半截译文显示为最终结果 + 无差别的自动重试成本

**位置**：`ArticleReaderView.swift:662-671`（`handleVisibleParagraphIDs`）、`700-712`（流式回填与失败处理）、`112-123`（`bilingualSegments`）、`678-687`（batch 过滤）

两个相互关联的缺陷（均已逐行核实）：

1. **部分文本被当作最终译文渲染且永久阻塞重试**：`onDelta` 做 `streamingBilingualTranslations[id, default: ""] += delta`（`700`），但失败处理只在**成功**段落的 ID 上执行 `removeValue(forKey:)`（`710-712`）。中途失败（429、模型拒绝、流中断）的段落把半截译文留在字典里；`bilingualSegments`（`116-121`）无失败过滤，把它当作最终译文渲染——用户看到截断的译文，**没有任何失败标记**。更糟的是，`translatedIDs = Set(bilingualSegments.map(\.id))`（`678`）包含该 stale 文本 → 段落被当作"已翻译"排除出后续 batch → **永远不会自动重试**，直到切换文章（`188-190` 才清理）。
2. **立即失败的段落每次滚动都重复付费请求**：若失败发生在任何 delta 到达之前（`streamingBilingualTranslations` 无条目或空串），`bilingualSegments` 过滤掉空文本 → 段落重新进 batch；同时 `handleVisibleParagraphIDs` 视口一变就 `failedBilingualParagraphIDs.removeAll()`（`667`）→ 滚动 N 次产生 N 次同内容的付费请求，失败原因不消失时永不收敛。

**修复**：
1. 失败路径显式清理：请求返回失败时从 `streamingBilingualTranslations` 移除该段落 ID（在 `708` 的 `unsuccessfulIDs` 上执行），避免半截文本冒充最终译文；`bilingualSegments` 增加"仅渲染进行中或已完成"过滤，失败段落显示"翻译失败"占位并可点击重试。
2. 失败标记不清空，仅在（a）文章内容哈希变化、（b）用户主动重试、或（c）失败原因（如 429）已过冷却期后清除；或对同一段落增加失败次数上限（如 2 次）后不再自动重试。

### M2. iOS 字号设置不实时生效（双端不同步，违反 CLAUDE.md 约束）

**位置**：`ArticleReaderView.swift` macOS `updateNSView:2030` vs iOS `updateUIView:2522-2526`

macOS 每次 update 都执行 `--paper-font-size` JS 同步；iOS 的 `updateUIView` 只调 `loadIfNeeded` + `synchronizeSummaryCard`，字号仅初始加载时生效（`documentHTML` 内联变量），运行中修改字号 iOS 端无效。CLAUDE.md 明确"Mac 和 iOS WebView coordinators 必须保持同步"。

**修复**：iOS `updateUIView` 补上与 macOS 等价的 `webView.evaluateJavaScript("document.documentElement.style.setProperty('--paper-font-size', ...)")`。

### M3. 流式翻译逐段全库持久化 + CloudKit 全量上传放大

**位置**：`AppStore.swift:1188-1190`（流式路径每段 `persist()`）、`AppStore.swift:1478-1491`、`CloudSyncService.swift:36-41`

每段翻译完成 → 一次完整 AppDatabase JSON 编码（含全部正文缓存，可达数 MB）+ 原子磁盘写 + `scheduleICloudSync()`。上传侧有 2 秒 debounce（`AppStore.swift:1527-1535`：每次 persist 取消 pending 任务并重排 2s 定时器），因此段落完成间隔 <2s 时一个 burst 只触发**一次**全量上传（单 CKRecord + CKAsset），仅在段落间隔 >2s（慢模型）时才会多次全量上传。**每段一次的全库编码是无条件的**（`DatabasePersistenceWriter` 的 revision 只丢弃旧写、不省编码），这是主要开销；CloudKit 上传放大按需评估。修复优先级：批量 persist（每 3-4 段或 500ms 节流一次，复用 `scheduleSummaryStreamNotification` 模式）优先，云同步节流次之。

**修复**：
1. 流式路径改为批量 persist（每 3-4 段或 500ms 节流一次），可复用 `scheduleSummaryStreamNotification` 的模式。
2. CloudKit 同步增加变更节流：`syncICloud` 内做 30-60s 合并窗口；或对 artifacts 同步改增量（仅传 changedAt 之后修改的条目）。

### M4. CloudKit 合并策略的隐患：`updatedAt` 缺省值 `now` 会覆盖远端

**位置**：`Models.swift:116`（`Feed.updatedAt` decode 缺省 `.now`）、`CloudSyncService.swift:20-29`

旧版本库中缺 `updatedAt` 的 Feed 解码为 `.now`（当前时间），在 `merged(local:remote:)` 按 updatedAt 比较时会被判定为"最新"，用本地旧数据覆盖远端新数据；同问题出现在 `ReadingState` 之外的 entry 合并路径。另外单记录全量同步无增量、无重试（CKError networkFailure/rateLimit 直接抛错）。

**修复**：decode 缺省改为 `.distantPast`（或首次持久化时回填）；`CloudSyncService.synchronize` 对 CKError 增加有限重试（2-3 次退避）。

### M5. 手动刷新在自动刷新期间被静默丢弃

**位置**：`AppStore.swift:541`（`guard !isRefreshing else { return }`）、`AppStore.swift:520-527`（`addFeed`）

自动刷新（启动即触发，串行拉取所有 feed，慢 feed 可拖到 30s 超时×数量）进行中：
- 用户点工具栏"刷新全部订阅"（⌘⇧R）→ 静默无响应；
- 新增订阅 → `refresh(feedIDs: [feed.id])` 被吞，新订阅**不会拉取内容**。

且刷新为**串行**：`for id in ids { await FeedService.fetch }`（`AppStore.swift:555-581`），几十个 feed 依次阻塞，最慢的 feed 拖累全部（超时 30s×N）。

**修复**：
1. 手动刷新与自动刷新区分：手动刷新用 `Task` 并发执行，或在 `isRefreshing` 时把请求合并到进行中的循环（记录 pendingFeedIDs 在循环结束后补刷）。
2. 拉取改并发（如 4-6 个并发，`withTaskGroup`），保留顺序写入。注意 `database` 是 `@MainActor` 上可变状态，并发写需在 MainActor 上合并结果（现架构下可在任务组内收集结果、MainActor 统一 merge）。

### M6. 删除订阅/重命名文件夹后 UI 状态残留

**位置**：`RootView.swift:447-455、533-537`（删除后 `selectedEntryID` 未清空）、`RootView.swift:1038-1089`（重命名后 selection 悬空、重名静默合并）

- 删除正在阅读的订阅：详情区显示占位（不崩溃），但 `showsReaderCapsule: selectedEntryID != nil`（`RootView.swift:117`）仍为 true，工具栏渲染一个 ~108pt 空胶囊占位。
- 重命名文件夹：若当前选中 `.folder(oldName)`，重命名后侧栏高亮消失、中间栏显示"没有文章"、阅读器仍开着旧文章；`canSubmit` 不查重名，A→B（B 已存在）时 `renameFolder`（`AppStore.swift:391-403`）静默合并两个文件夹。

**修复**：
1. 删除按钮（feed/folder 两个入口）显式 `selectedEntryID = nil`。
2. `RenameFolderSheet.submit` 提交后若 `selection == .folder(oldName)` 则更新为 `.folder(newName)`；`canSubmit` 禁止与现有文件夹重名。

### M7. Swift 6 严格并发警告（10 条，macOS 构建已出现）

**位置**：`ThreeColumnSplitView.swift:108-110`

KVO `observe(\.window)` 回调闭包内直接调用 `@MainActor` 的 `configureToolbar`，且捕获了 `window`/`toolbarConfigured`/`splitView` 等 main-actor 隔离属性；`Sidebar.Type` 等非 Sendable 类型被 Sendable 闭包捕获。当前运行时安全（KVO 回调在主线程），但切 Swift 6 语言模式会编译失败。

**修复**：闭包内包一层 `Task { @MainActor in ... }`（或 `MainActor.assumeIsolated`），并尽量只捕获最小必要状态。

---

## 四、低严重度问题

| # | 位置 | 问题 | 建议 |
|---|---|---|---|
| L1 | `RootView.swift:75` | `fileExporter` 每次 body 求值都急切执行全量 OPML 导出（刷新进度逐条 tick 都会触发） | `showsExporter` 变 true 时惰性生成 |
| L2 | `SettingsView.swift:1004-1012` | `useDeepSeekDefaults()` 重置整组配置（targetLanguage/temperature/reasoningMode/showsAISummary/allowInsecureLocalEndpoint），静默清掉用户偏好 | 逐字段合并 |
| L3 | `RootView.swift:963-973` | `AddFeedSheet` 失败（URL 无效/重复）时仍无条件 dismiss，输入丢失、错误只出现在背后 alert | 失败时不 dismiss |
| L4 | `RootView.swift:784-828` | `PaperCapsuleButton` 死代码，全项目无引用 | 删除 |
| L5 | `FeedParser.swift:86-98` | `parseDate` 每次调用新建 ISO8601DateFormatter + 多个 DateFormatter（重量级对象），大 feed 刷新时每条目 2-3 个 | 静态/复用 formatter（注意线程安全用 `Sendable` 包装或每线程缓存） |
| L6 | `AppStore.swift:266-269` | 启动即查 GitHub Release API，无节流（多次启动频繁触发；`checkedAt` 存了但没用） | 启动检查间隔 ≥1 天（读 `UpdateCheckStatus.checkedAt`） |
| L7 | `ArticleReaderView.swift` 512-565 vs 2938-2989 | `floatingCapsuleToolbar` 与 `ReaderCapsuleToolbar` 重复实现（图标/布局近似） | 收敛为单一组件 |
| L8 | 根目录 | 遗留文件：`fix_toolbar.patch`（未应用的工具栏 spinner 修复）、`update_reader.sh`（过时脚本）、`patch.swift`（占位符） | 清理或入档 |
| L9 | `.gitignore` | `dist/` 未忽略——`PaperRss-v0.1.0.dmg`（4.9MB）、xcarchive（含完整 .app 二进制）已入库（commit 0e6f8ec） | `.gitignore` 增加 `dist/`，用 `git rm -r --cached dist` 移出跟踪（保留本地文件） |
| L10 | `KeychainStore.swift` | 文件名与类型名不一致（文件内定义的是 `LocalAPIKeyStore`）；CLAUDE.md 引用了不存在的 `LocalAPIKeyStore.swift` | 重命名文件，更新 CLAUDE.md |
| L11 | `Models.swift:478-484` | `stableDigest` 用 FNV-1a 64 位哈希作为 AI 缓存键，理论碰撞会把错误缓存命中给用户 | 可接受（个人阅读器），如后续扩展可换 SHA-256 |

---

## 五、建议的修复顺序

> **方向约束（2026-08-05 用户明确）**：目前不出版 iOS 版本，只专注 macOS 版。所有 iOS 专属项（H1、M2、BackgroundRefresh/BGTask 相关）**暂缓**，不作为当前修复目标；但 macOS/iOS 共享代码（Core 层、ArticleReaderView 双端 coordinator）改动时仍保持双端一致，避免将来出 iOS 版时回归。

### ✅ 已完成（2026-08-05）
- **H2** FeedParser `content:encoded` 前缀剥离 + `dc:creator` 映射 + 回归测试（37/37 通过）→ 恢复 RSS 2.0 全文正文
- **H5** iCloud 同步闪退修复（entitlement 防御，36→37 测试）
- **H1** iOS 编译错误 ×2 已修复（`BackgroundRefresh.schedule(interval:)` 缺参、`inset(alternatesRowBackgrounds:)` 平台分支）——iOS 目标恢复 BUILD SUCCEEDED；`isICloudEntitled` 按平台分支（SecTask 是 macOS 专属，iOS 暂禁用同步）
- **H3** 定时自动刷新已接线：RootView `.task` 调用 `startAutomaticRefresh()`，`refreshOnLaunch` 开关与刷新间隔选项恢复生效；iOS 侧 `BackgroundRefresh.schedule(interval:)` 同步修正
- **H4** 视口翻译链已恢复：`.onChange(of: store.activeAIRequest == nil)` 在任一 AI 请求（自动摘要/划词解释/选区翻译）结束后自动重新发起视口翻译——修复"摘要进行中点击翻译无反应"（推特等所有文章共因）
- **M1** 失败段落处理：失败时清理 `streamingBilingualTranslations` 中的半截译文（不再冒充最终译文、不再阻塞重试）；失败集合改为计数 `[String: Int]`，上限 2 次后停止自动重试（滚动不再清空计数，杜绝重复付费请求）
- **M6** 删除/重命名 UI 状态：删除订阅/文件夹后通过 `onDeleteSelection` 回调清空 `selectedEntryID`（含非当前选中场景）；`RenameFolderSheet` 增加重名校验 + 重命名后同步侧栏选择

### 待办（未做）
1. **M3** 流式翻译批量持久化
2. **M4** `updatedAt` 缺省值修正 + CloudKit 重试（若改自建同步则一并重估）
3. **M5** 刷新并发化 + 手动刷新不丢弃（自动刷新在跑时工具栏"刷新全部"仍会被静默丢弃）
4. **M7** Swift 6 并发警告清理
5. **L1-L11** 按需处理（建议至少做 L8/L9/L10 仓库卫生）
6. **M2** iOS 字号同步 —— iOS 非当前目标，暂缓

### 建议的回归验证清单
- `swift test`（新增 content:encoded 用例后应 37+ 通过）
- macOS：`xcodebuild -scheme PaperRss -configuration Debug build`（0 新增警告）
- macOS 手测：设置刷新间隔 → 观察定时刷新；双语模式 → 摘要进行中滚动视口 → 摘要完成后新段落应自动翻译；失败段落不再重复请求

---

## 七、2026-08-05 用户报告并已修复：iCloud 同步点击闪退（SIGABRT）

**报告现象**：点击设置 → 同步 → 启用 iCloud 同步开关后，app 数秒内崩溃（SIGABRT / Abort trap: 6）。

**崩溃栈定位**（用户 crash report 已给出）：
- `CloudKit` 内部 `objc_exception_throw`（经 `_dispatch_once_callout`）
- → `CloudSyncService.database.getter`（`CloudSyncService.swift:43`，即 `CKContainer.default().privateCloudDatabase`）
- → `download()` → `synchronize()` → `AppStore.syncICloud()`（855）→ `scheduleICloudSync()`（1533）

**根因**：`CKContainer.default()` 在应用**没有 CloudKit iCloud entitlement** 时抛出 Objective-C 异常；Swift 的 `do/catch` 无法捕获 ObjC 异常，异常直接导致进程 abort。核实项目配置：
- `project.pbxproj` 中**没有任何** `CODE_SIGN_ENTITLEMENTS` 配置；
- `PaperRss/Resources/PaperRss.entitlements.template` 只是模板，未被 Xcode target 使用；
- 用户运行的 app 是 ad-hoc 签名（HANDOFF 记载），ad-hoc 签名**不可能携带** iCloud entitlement。

因此该崩溃是确定性的：只要 `isICloudSyncEnabled` 被置位（开关或 UserDefaults 遗留标记），2 秒后调度任务必然触发崩溃。额外隐患：一旦 UserDefaults 保存过启用标记，之后每次启动在任意 `persist()` 后都会调度同步并崩溃。

**已实施的修复（三层防御，`swift test` 36/36 通过 + macOS 构建成功）**：

1. **运行时 entitlement 检查**（`CloudSyncService.swift`）：新增 `CloudSyncService.isICloudEntitled`，用 `SecTaskCreateFromSelf` + `SecTaskCopyValueForEntitlement` 读取 `com.apple.developer.icloud-services` 运行时 entitlement；`synchronize()` 入口 `guard`，无权限抛 `CloudSyncError.notEntitled`。
2. **AppStore 全路径防御**（`AppStore.swift`）：
   - `setICloudSyncEnabled(true)` 无 entitlement 时拒绝启用，状态栏显示 `notEntitled` 文案；
   - `init` 时若 UserDefaults 遗留启用标记但无 entitlement，强制重置为 false 并清除标记，杜绝"启动后任意 persist 触发崩溃"的隐藏路径；
   - `syncICloud()` 增加 entitlement guard 兜底。
3. **UI 禁用**（`SettingsView.swift`）：无 entitlement 时同步开关 `.disabled`，状态行显示原因。

**新增回归测试**：`testUnentitledBuildsAreRejectedBeforeAnyCloudKitCall` —— 无 entitlement 环境（SPM 测试进程）断言 `synchronize()` 在触碰任何 CloudKit API 前被拒绝并抛 `notEntitled`。

**注意**：要让同步真正可用，需要（a）Xcode target 配置 `CODE_SIGN_ENTITLEMENTS = PaperRss.entitlements.template`（或新建 entitlements 文件），（b）开发者证书 + provisioning profile 签名（ad-hoc 签名不支持 iCloud），（c）Xcode 中开启 CloudKit capability。修复保证的是：在达成这些条件前，UI 明确提示且**绝不崩溃**。

---

## 六、审计确认无问题的方面

- **API key 安全**：App 层与 Core 层零 `print`/`Logger`/`NSLog`，key 不落日志；`LocalAPIKeyStore` 存 UserDefaults 不参与 iCloud 同步；LLMService 强制 HTTPS（除显式局域网选项）。
- **无崩溃点**：全项目无 force unwrap 危险用法、无越界数组访问（`splitViewItems[0..2]` 恒为 3 项）、`PaperGrain` 用溢出安全乘法。
- **持久化线程模型**：`@MainActor` AppStore + revisioned actor 写盘（`Task.detached`），编码/写盘离主线程，正确。
- **WebView 桥接**：CSP `script-src 'none'` 下 WKUserScript 注入正常；message handler 在 `dismantle` 时移除，无泄漏；macOS/iOS 的 selection 请求串行队列实现等价（除 M2 字号同步外）。
- **删除级联**：删 feed 级联删 entries/caches/readingStates + AIArtifact 墓碑（防 CloudKit 复活），已实现且正确。
- **测试**：35/35 通过；SSE 流式、DeepSeek thinking 禁用、HTML 清洗、索引分组等关键路径有回归覆盖。
