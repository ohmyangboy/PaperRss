# NetNewsWire 账号体系与 Google Reader (greader) 协议对标与可行性调研

> 研究日期：2026-08-13  
> 适用对象：PaperRss (iOS/macOS Swift) 架构师与开发团队  
> 文档状态：完成 / 可行性调研报告（支撑 Issue #2 "接入 FreshRSS 服务账号"的产品决策）  
> 前置文档：[freshrss-api-research.md](./freshrss-api-research.md)（协议规范调研）、[issue-2-freshrss-spec-draft.md](../../drafts/issue-2-freshrss-spec-draft.md)（集成草案）

---

## 摘要与核心结论

本报告基于 **NetNewsWire 当前 main 分支的完整源码快照**（下载于 2026-08-13，commit `ab2f35f33fa688a41fe4984bf9499934cde7d63b`）与 **greader 协议一手资料**（FreshRSS 官方文档、Mihai Parparita 的原始 Google Reader API 非官方规范、BazQux 官方 API 文档），对"NetNewsWire 账号体系"与"greader 协议"做了源码级对标，并给出 PaperRss 接入 FreshRSS 服务账号的可行性结论。

### 核心结论速览

1. **仓库地址更正**：任务中给出的 `https://github.com/NetNewsWire/NetNewsWire` 已不可访问（`git ls-remote` 返回 *Repository not found*），NetNewsWire 实际位于 **`https://github.com/Ranchero-Software/NetNewsWire`**（默认分支 `main`）。本报告全部源码路径均基于该仓库 main 分支快照核实。
2. **NetNewsWire 账号体系 = "一个 `Account` 门面类 + 一个 `AccountDelegate` 协议 + 按账号类型选择 delegate 实现"**。当前 main 分支 **没有** 独立的 `GoogleReader` 账号类型（服务已于 2013 年关闭）；FreshRSS / Inoreader / BazQux / The Old Reader 四种 greader 兼容服务 **共用同一个 `ReaderAPIAccountDelegate`，仅靠 `ReaderAPIVariant` 枚举区分**。这与 freshrss-api-research.md 中"NetNewsWire 有 GoogleReader 实现"的表述不同，本文以源码为准。
3. **greader 协议层面最重要的增量发现**：NetNewsWire 不使用 `unread-count`、`user-info`、`mark-all-as-read` 三个端点（未读计数全部本地计算；"全部已读"用"拉全量 ID + 本地标记 + edit-tag 写回"实现）；它额外使用 **`/reader/api/0/token` 写令牌端点**（所有写操作必须带 `T=` 参数，30 分钟有效，过期 401 重取）——这是 freshrss-api-research.md 未覆盖、但实现时必踩的环节。
4. **增量同步的正确姿势（BazQux "The Right Way to Sync"，FreshRSS 官方推荐）是"ID 差集法"而非 `ot` 增量**：拉 unread/starred 全量 ID 列表（`n=1000` 分页），与本地比对做差集；`ot` 只用于首次拉取的历史窗口。NetNewsWire 的实现完全遵循这一点。
5. **对 PaperRss 的结论**：**不完整照搬** NetNewsWire 账号体系（其复杂度来自每账号独立 SQLite 库 + 9 种账号类型 + 行为差异矩阵，PaperRss 单库 JSON 架构用不上），**但应借鉴它的 `AccountDelegate` 协议抽象**，只实现一个 greader 兼容 delegate（`ReaderAPICaller` 的端点/参数/ID 编码/token 处理可直接照抄），按"数据模型加 `accountID` + 读路径加账号维度 + 刷新分支 + 状态写回队列 + 侧栏账号分组"的轻量路径落地。分三阶段推进，阶段一（只读拉取 + 状态写回）价值最高、风险可控。

---

## 一、调研方法与一手来源说明

| 来源 | 类型 | 用途 |
| :--- | :--- | :--- |
| [Ranchero-Software/NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire)（main 分支完整源码 tarball） | 一手源码 | 问题一全部结论 + 问题二"NetNewsWire 怎么用 greader" |
| [FreshRSS 官方文档 · Google Reader compatible API](https://freshrss.github.io/FreshRSS/en/developers/06_GoogleReader_API.html) | 官方文档 | 问题二端点/认证/同步策略 |
| [mihaip/google-reader-api](https://github.com/mihaip/google-reader-api)（原始 Google Reader API 非官方规范，含 `wiki/` 各端点文档） | 一手规范 | 问题二协议语义（edit-tag、token、ItemId、分页） |
| [bazqux/bazqux-api](https://github.com/bazqux/bazqux-api#user-content-the-right-way-to-sync)（含 "The Right Way to Sync"） | 一手规范 | 问题二增量同步最佳实践 |
| PaperRss 本地源码（`PaperRss/Sources/Core|App`） | 一手代码 | 问题三可行性分析 |

> 版本说明：NetNewsWire 源码路径可能随版本演进变化。本文所有 `Modules/Account/Sources/Account/...` 路径均在本调研抓取的 main 快照中逐文件核实（文件名、类型名、方法名、行号来自该快照）。若后续 main 分支重构导致路径失效，以 "路径为调研时点快照" 为准。

---

## 二、问题一：NetNewsWire 账号体系的源码级实现

### 2.1 核心类型与文件地图

| 类型/文件 | 角色 |
| :--- | :--- |
| `AccountType`（enum） | 账号类型枚举，磁盘持久化的 rawValue 不可变 |
| `Account`（class，@MainActor） | 账号门面类：数据目录、`ArticlesDatabase`、feed 树（`topLevelFeeds`/`folders`）、凭据、`delegate` |
| `AccountDelegate`（protocol，@MainActor） | **账号行为协议**：刷新、状态同步、订阅管理、凭据校验的抽象 |
| `AccountManager`（class） | 账号注册表：加载/创建/删除账号、聚合刷新与状态同步 |
| `AccountBehaviors` | 账号能力差异描述（如"feed 不能在根目录"） |
| `ReaderAPIAccountDelegate` | **所有 greader 兼容服务的唯一 delegate 实现**（FreshRSS/Inoreader/BazQux/TheOldReader） |
| `ReaderAPICaller` | greader HTTP 客户端（端点、认证、token、ID 编码） |
| `LocalAccountDelegate` + `LocalAccountRefresher` | 本地"On My Mac"账号：直接抓 feed，无同步 |
| `CloudKitAccountDelegate` | iCloud 账号：本地抓 feed + CloudKit 同步 |
| `SyncDatabase`（独立模块） | 待写回服务器的文章状态队列（SQLite） |
| `SidebarTreeControllerDelegate` / `SidebarViewController` / `SidebarCell` | 侧栏多账号树与单元格呈现 |

源码文件位置（全部在 `Modules/Account/Sources/Account/` 下，已核实）：

```
Modules/Account/Sources/Account/
├── Account.swift                  # AccountType + Account
├── AccountDelegate.swift          # AccountDelegate 协议
├── AccountManager.swift           # 账号注册表
├── AccountBehaviors.swift         # 行为差异枚举
├── AccountSettings.swift          # endpointURL / lastArticleFetchStartTime / conditionalGet
├── LocalAccount/
│   ├── LocalAccountDelegate.swift
│   ├── LocalAccountRefresher.swift
│   └── InitialFeedDownloader.swift
├── ReaderAPI/
│   ├── ReaderAPIAccountDelegate.swift   # 1250 行，greader 同步引擎
│   ├── ReaderAPICaller.swift            # 672 行，greader HTTP 客户端
│   ├── ReaderAPIVariant.swift           # generic/freshRSS/inoreader/bazQux/theOldReader
│   ├── ReaderAPIEntry.swift             # 文章 JSON 模型（含 ID 转换）
│   ├── ReaderAPISubscription.swift      # 订阅 JSON 模型
│   ├── ReaderAPITag.swift / ReaderAPITagging.swift / ReaderAPIUnreadEntry.swift
│   └── URLRequest+ReaderAPI.swift       # Authorization 头构造
└── CloudKit/CloudKitAccountDelegate.swift  # iCloud 账号
```

### 2.2 `AccountType` / `Account` / `AccountDelegate`：协议如何抽象"本地"与"同步服务"

**`AccountType`**（[Account.swift:40-79](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/Account.swift#L40-L79)）：

```swift
nonisolated public enum AccountType: Int, Codable, Sendable {
    // Raw values should not change since they’re stored on disk.
    case onMyMac = 1
    case cloudKit = 2
    case feedly = 16
    case feedbin = 17
    case newsBlur = 19
    case freshRSS = 20
    case inoreader = 21
    case bazQux = 22
    case theOldReader = 23
}
```

要点：
- **没有 `googleReader` 类型**——Google Reader 服务已死，NetNewsWire 不再支持；现有 greader 兼容服务全部走 `ReaderAPIAccountDelegate`。
- 离散 rawValue（1/2/16/17/19/20/21/22/23）是历史演进结果，注释明确"不得改变，因为要落盘"。若 PaperRss 将来做多账号，`AccountType` 的 rawValue 稳定设计值得借鉴。
- `isDeveloperRestricted` 标记部分账号类型仅开发者模式可用（`cloudKit/feedbin/feedly/inoreader`），与账号类型本身的能力无关。

**`Account` 类**（[Account.swift:92](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/Account.swift#L92)）是门面：持有 `dataFolder`（每账号一个磁盘目录）、`database: ArticlesDatabase`（**每账号一个独立 SQLite 库**）、`topLevelFeeds`/`folders`（feed 树）、`settings: AccountSettings`、`credentials`、以及 `delegate: AccountDelegate`。**delegate 在 `init` 里按 `AccountType` 选择**（[Account.swift:295-315](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/Account.swift#L295-L315)）：

```swift
case .onMyMac:   self.delegate = LocalAccountDelegate()
case .cloudKit:  self.delegate = CloudKitAccountDelegate(dataFolder: dataFolder)
case .freshRSS:  self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, variant: .freshRSS)
case .inoreader: self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, variant: .inoreader)
case .bazQux:    self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, variant: .bazQux)
case .theOldReader: self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, variant: .theOldReader)
// feedbin / feedly / newsBlur 各自有独立 delegate
```

**`AccountDelegate` 协议**（[AccountDelegate.swift:15-70](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/AccountDelegate.swift)）是"本地 vs 同步服务"统一的抽象面，方法全集：

- 刷新：`refreshAll()` / `syncArticleStatus()` / `sendArticleStatus()` / `refreshArticleStatus()`
- 订阅管理：`createFolder/renameFolder/removeFolder`、`createFeed/renameFeed/addFeed/removeFeed/moveFeed/restoreFeed/restoreFolder`
- 状态：`markArticles(articleIDs:statusKey:flag:)`
- 生命周期：`accountDidInitialize()` / `accountWillBeDeleted()` / `validateCredentials(credentials:endpoint:)`（静态）
- 网络：`suspendNetwork()` / `resume()`；运维：`vacuumDatabases()`

**关键设计**：`LocalAccountDelegate`（[LocalAccountDelegate.swift:18](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/LocalAccount/LocalAccountDelegate.swift)）对这些方法给出"无同步"的空实现（`syncArticleStatus()` 返回 `false`、`sendArticleStatus()` 空操作、`refreshAll()` 调 `LocalAccountRefresher` 逐 feed 抓取）；`ReaderAPIAccountDelegate` 则给出完整的服务端同步实现。UI 层只依赖 `Account`/`AccountDelegate` 协议，**不感知具体服务**——这是"多账号"可扩展性的根本来源。

### 2.3 `AccountManager`：账号注册表与生命周期

[AccountManager.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/AccountManager.swift)：

- **默认本地账号永远存在**（`init` 中创建 `OnMyMac` 目录与账号，[L137-164](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/AccountManager.swift#L137-L164)）；启动时扫描 `Accounts/` 目录下的每个子目录恢复账号（"没有独立的账号清单文件"）。
- `createAccount(type:)`（L185）：建目录 → `Account(...)` → 入字典 → 发 `UserDidAddAccount` 通知。
- `deleteAccount(_:)`（L212）：`prepareForDeletion()` → 删目录 → `UserDidDeleteAccount` 通知。**账号数据（含文章库）随账号目录整体删除**。
- `duplicateServiceAccount(type:username:endpoint:)`（L238）：同一服务账号（同用户名/同 endpoint）不允许重复添加；自托管服务允许"同名用户 + 不同服务器"。
- **聚合刷新**：`refreshAll(errorHandler:)`（L319）用 `withTaskGroup` 并行调每个活跃账号的 `refreshAll()`，`CombinedRefreshProgress` 聚合进度——这与 PaperRss `AppStore.refresh` 的 TaskGroup 并发模型同构。
- **聚合状态同步**：`syncArticleStatusAll()`（L362）并行调每个账号 `syncArticleStatus()`，返回"是否有实际工作"（供调度器退避用）。

### 2.4 同步账号的接入管线：API 客户端 / 下载 / 状态写回如何协作

> 现状核实：**当前 main 分支（以及 2021 年的 mac-6.2.1 标签）中不存在独立的 "downloader/updater" 类型**（早期版本曾有 `FeedDownloader`/`ArticleStatusDownloader`/`ArticleContentDownloader` 之类的独立类，本调研未能在当前源码中核实其具体形态，标注 **待核实**）。现在的刷新逻辑全部内聚在各 `AccountDelegate` 实现内。下面以 greader 管线为准描述"类型协作"。

**管线一：`refreshAll()`（拉新文章）**——[ReaderAPIAccountDelegate.swift:110-185](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L110-L185)：

```
refreshAll()
 ├─ retrieveCredentialsIfNeeded(account)        // Keychain 取 Auth token
 ├─ refreshAccount(account)                     // ① 订阅树同步
 │    ├─ caller.retrieveTags()                  //    GET tag/list（带条件请求 304 跳过）
 │    ├─ caller.retrieveSubscriptions()         //    GET subscription/list（带条件请求）
 │    └─ syncFolders / syncFeeds / syncFeedFolderRelationship
 │          // 与本地 Account 的 folders/topLevelFeeds 树做增删改对账
 ├─ try? await sendArticleStatus()              // ② 先写回本地待发状态（失败不阻塞拉新）
 ├─ caller.retrieveItemIDs(.allForAccount)      // ③ 拉全站 ID 列表（ot=上次拉取时间||3个月前）
 │    └─ account.markAsReadAsync(articleIDs)    //    先乐观标记已读（随后对账纠正）
 ├─ refreshArticleStatus()                      // ④ 状态对账：
 │    ├─ retrieveItemIDs(.unread) + syncArticleReadState    // 拉未读 ID → 本地求差集
 │    └─ retrieveItemIDs(.starred) + syncArticleStarredState // 拉星标 ID → 本地求差集
 └─ refreshMissingArticles(account)             // ⑤ 补正文：
      ├─ account.fetchArticleIDsForStatusesWithoutArticlesNewerThanCutoffDateAsync()
      └─ caller.retrieveEntries(articleIDs: 150/批)  // POST stream/items/contents
           └─ mapEntriesToParsedItems → account.updateAsync(feedIDsAndItems:defaultRead:)
```

关键点：
- **先拉"ID 列表"再按需拉"正文"**——`stream/items/ids` 比 `stream/contents` 便宜得多，正文只在"有状态但无正文"的文章上补拉（`refreshMissingArticles`，[L1075-1107](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L1075-L1107)），每批 150 条。**这直接回答了 PaperRss 的 AI 管线问题：greader 服务账号的文章正文来自服务器的 `stream/items/contents` 响应（`summary.content` HTML），客户端不需要自己抓网页**（详见 4.4/5.2）。
- 订阅树对账（`syncFolders/syncFeeds/syncFeedFolderRelationship`，[L782-935](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L782-L935)）以**服务器为权威**：服务器没有的本地文件夹/feed 删除，服务器有的本地没有则创建。
- `ReaderAPICaller` 是唯一的 HTTP 客户端（[ReaderAPICaller.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift)），所有端点、认证头、`T=` 令牌、ID 编码都在这里。

**管线二：本地账号（对照）**——`LocalAccountDelegate.refreshAll()`（[LocalAccountDelegate.swift:46-58](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/LocalAccount/LocalAccountDelegate.swift#L46-L58)）调 `LocalAccountRefresher.refreshFeeds(_:)`（[LocalAccountRefresher.swift:88](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/LocalAccount/LocalAccountRefresher.swift#L88)），经 `DownloadSession` 并发抓取 + 条件请求（ETag/Last-Modified），解析后写入本地库。**这与 PaperRss 现有 `FeedService`/`AppStore.refresh` 几乎一一对应**，只是 PaperRss 把并发/超时直接写在 `AppStore` 里，NetNewsWire 把它封装在 refresher 里。

### 2.5 已读/星标状态写回管线（status 写入）

调用链（已核实）：

```
UI/命令层（Mac/AppDelegate.swift:1091、Shared/Extensions/ArticleUtilities.swift:27）
  → account.markArticles(articleIDs:statusKey:flag:)          // Account.swift:590
    → delegate.markArticles(...)                               // ReaderAPIAccountDelegate.swift:655
      ├─ account.updateStatusesAsync(...)                      // 本地 ArticlesDatabase 立即改状态（乐观更新）
      ├─ syncDatabase.insertStatuses(SyncStatus...)            // 写"待发队列"（Sync.sqlite3）
      ├─ 通知 .AccountDidQueueArticleStatuses                  // 唤醒状态同步调度
      └─ 若 pending > 100 → Task { sendArticleStatus() }       // 批量阈值触发即时 flush
```

- **待发队列**：`SyncDatabase`（独立模块 [Modules/SyncDatabase](https://github.com/Ranchero-Software/NetNewsWire/tree/main/Modules/SyncDatabase)，`SyncStatus { articleID, key(read|starred), flag, selected }`）。`markArticles` 只写队列 + 乐观更新本地，不阻塞 UI；实际发送由 `ArticleStatusSyncTimer`（[Shared/Timer/ArticleStatusSyncTimer.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Shared/Timer/ArticleStatusSyncTimer.swift)）每 2 分钟（空闲退避 30 分钟）触发 `AccountManager.syncArticleStatusAll()`。
- **发送**：`sendArticleStatusReturningCount`（[ReaderAPIAccountDelegate.swift:230-277](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L230-L277)）把队列按 read/starred × add/remove 分成四组，每组调 `caller.createUnreadEntries / deleteUnreadEntries / createStarredEntries / deleteStarredEntries`——全部落到 `edit-tag`（`a=`/`r=` + 状态 tag），每批 **1000 条**（`chunked(into: 1000)`）；成功删队列，失败重置 selected 待重试。
- **对账（防"本地方向为准"冲突）**：`syncArticleReadState`（[L1161-1186](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L1161-L1186)）下载服务器未读 ID 后，与本地未读 ID 求差集并**排除待发队列中的 ID**（"pending 是本地的 truth"），再标记已读/未读——这避免了"服务器旧状态把本地刚点掉的未读又翻回来"的经典 bug。
- **不可编码 ID 丢弃**：`articleIDIsSendable`（[L996-1001](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L996-L1001)）对非数字 ID（除 TheOldReader 外）直接丢弃并报错，防止"永远发不出去"的队列死循环。

### 2.6 侧栏 UI 的多账号呈现

- **树结构**（[Shared/Tree/SidebarTreeControllerDelegate.swift:26-141](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Shared/Tree/SidebarTreeControllerDelegate.swift)）：根节点下 = Smart Feeds 组 + **每个账号一个节点**（`sortedActiveAccounts`）；账号节点（`isGroupItem = true`）展开后 = 该账号的 `topLevelFeeds` + `folders`（`Container` 语义，账号/文件夹/feed 都遵循同一个 `Container` 协议）。**账号是树的顶层分组，feed/folder 挂在账号下面**。
- **单元格**（[Mac/MainWindow/Sidebar/SidebarViewController.swift:402-415](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Mac/MainWindow/Sidebar/SidebarViewController.swift#L402-L415)）：`isGroupItem` 的账号节点用 `HeaderCell`（组头样式，如 macOS 系统偏好设置的 group 行）；feed/folder 用 `SidebarCell`（[SidebarCell.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Mac/MainWindow/Sidebar/Cell/SidebarCell.swift)），含 favicon + 未读数。**本地账号与远程账号在界面上靠"组头 + 账号名 + 每账号专属图标/配色"区分**（如 `accountFreshRSS.imageset`、`Account icon colors/freshRSSColor.colorset` 资源）。
- **账号管理 UI**：Mac 在 `Settings > Accounts`（[AccountsReaderAPIWindowController.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Mac/Preferences/Accounts/AccountsReaderAPIWindowController.swift)），iOS 在 [iOS/Account/ReaderAPIAccountViewController.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/iOS/Account/ReaderAPIAccountViewController.swift)——用户输入 endpoint URL + 用户名 + API 密码，先以 `.readerBasic` 凭据调 `Account.validateCredentials`（→ ClientLogin 换 Auth token），成功后把 `.readerAPIKey` 凭据存 Keychain、endpoint 存 `AccountSettings`。
- **官方架构说明**：[Technotes/Accounts.markdown](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Accounts.markdown)（"账号的数据属于账号本身；刷新与同步是每个账号自己的职责"；数据存储 = 每账号目录下 Settings.plist / DB.sqlite3 / FeedMetadata.plist / Subscriptions.opml，同步账号另有 Sync.sqlite3）。

### 2.7 iCloud 账号（第二种"同步账号"形态）

`CloudKitAccountDelegate`（[Modules/Account/Sources/Account/CloudKit/CloudKitAccountDelegate.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/CloudKit/CloudKitAccountDelegate.swift)）：**文章抓取与本地账号相同（直接抓 feed），只是把 feed 树/文章/状态通过 CloudKit 多设备同步**。这与 PaperRss 的 `CloudSyncService` 思路一致（但 NetNewsWire 是分区级 CloudKit 同步，PaperRss 是单记录整库 JSON）。注意：iCloud 账号与 greader 账号**没有重叠**——服务账号的同步发生在"客户端 ↔ FreshRSS 服务器"，不经过 CloudKit。

---

## 三、问题二：Google Reader (greader) 协议

> 与 freshrss-api-research.md 重复的协议事实（端点表、API 密码、子目录部署、纯文本响应、ID 用 String 存储等）此处**简要引用不再展开**；重点补充 **(a) NetNewsWire 源码里怎么用这个协议**、**(b) 多实现兼容差异**、**(c) 前置文档缺失的 `token` 写令牌机制**。

### 3.1 认证流程

**第一步 ClientLogin 换 Auth 令牌**：
- 原始规范（[mihaip Authentication.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/Authentication.wiki)）：`POST /accounts/ClientLogin`，参数 `accountType=GOOGLE&Email=...&Passwd=...&service=reader`，响应是 `key=value` 文本行，取 `Auth=` 值；后续所有请求带 `Authorization: GoogleLogin auth=<value>`。
- FreshRSS 官方示例（[06_GoogleReader_API.html](https://freshrss.github.io/FreshRSS/en/developers/06_GoogleReader_API.html)）：`curl -X POST -d 'Email=alice&Passwd=Abcdef123456' '.../api/greader.php/accounts/ClientLogin'` → 返回 `SID=...`/`Auth=alice/<token>`；注意 FreshRSS 必须用 **API 专用密码**而非网页主密码（详见 freshrss-api-research.md 2.2）。
- **NetNewsWire 的实现**（[ReaderAPICaller.validateCredentials:106-147](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L106-L147) + [URLRequest+ReaderAPI.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/URLRequest%2BReaderAPI.swift)）：`.readerBasic` 凭据时请求体为 `Email=&Passwd=` 表单（**不传 `accountType`/`client`/`service`，FreshRSS 接受缺省**）；解析 `Auth=` 行 → 存为 `.readerAPIKey` 凭据；后续所有请求经 `URLRequest(readerAPICredentials:)` 自动加 `Authorization: GoogleLogin auth=<token>`。404 时抛 `urlNotFound`（对应"Nginx PATH_INFO 丢失"诊断）。

**第二步（前置文档缺失的关键环节）：写操作令牌 `T=`**：
- 原始规范（[ActionToken.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ActionToken.wiki)）：**所有 state-changing 请求除了 `GoogleLogin auth=` 头，还必须带 `T=<token>` 参数**（XSRF 防护）；token 由 `GET /reader/api/0/token` 获取，**30 分钟有效**，过期/缺失时服务端返回 401 并带响应头 `X-Reader-Google-Bad-Token: true`。
- FreshRSS 官方文档同样演示了 `/reader/api/0/token`（返回 `8e6845e089457af25303abc6f53356eb60bdb5f8ZZZZ...`）。
- **NetNewsWire 的实现**（[ReaderAPICaller.requestAuthorizationToken:149-177](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L149-L177) + `withWriteToken:181-191`）：内存缓存 token；所有写操作（edit-tag、subscription/edit、quickadd、disable-tag、rename-tag）经 `withWriteToken` 注入 `T=`；**遇 401/403 时丢弃缓存、重取 token、重试一次**——因为 FreshRSS 等实现的 token 也会过期，不重试会导致"下次同步全部失败直到重启"。

### 3.2 核心端点：规范全集 vs NetNewsWire 实际使用

FreshRSS/规范端点全集（[06_GoogleReader_API.html](https://freshrss.github.io/FreshRSS/en/developers/06_GoogleReader_API.html)、[mihaip wiki](https://github.com/mihaip/google-reader-api)）：

| 端点 | 方法 | 用途 | NetNewsWire 是否使用 |
| :--- | :--- | :--- | :--- |
| `/accounts/ClientLogin` | POST | 认证换 Auth | ✅ `validateCredentials` |
| `/reader/api/0/token` | GET | 写令牌 `T=` | ✅ `requestAuthorizationToken` |
| `/reader/api/0/user-info` | GET | 用户信息 | ❌ 不使用 |
| `/reader/api/0/subscription/list` | GET | 订阅列表 | ✅ `retrieveSubscriptions`（条件请求） |
| `/reader/api/0/tag/list` | GET | 文件夹/标签 | ✅ `retrieveTags`（条件请求；Inoreader 加 `types=1`） |
| `/reader/api/0/unread-count` | GET | 未读数 | ❌ 不使用（本地数据库算） |
| `/reader/api/0/stream/contents/{stream}` | GET | 流文章（含 `c` 分页） | ❌ 不使用（改用 ids + items/contents） |
| `/reader/api/0/stream/items/ids` | GET | 仅 ID 列表 | ✅ `retrieveItemIDs`（核心） |
| `/reader/api/0/stream/items/contents` | GET/POST | 按 ID 取正文 | ✅ `retrieveEntries`（POST，`i=` 重复参数） |
| `/reader/api/0/edit-tag` | POST | 状态/标签写回 | ✅ `updateStateToEntries`（核心） |
| `/reader/api/0/mark-all-as-read` | POST | 批量已读 | ❌ 不使用（"全部已读" = 拉全量 ID + 本地标记 + edit-tag） |
| `/reader/api/0/subscription/edit` | POST | 改名/移动/退订（`ac=edit\|unsubscribe`） | ✅ `changeSubscription`/`deleteSubscription` |
| `/reader/api/0/subscription/quickadd` | POST | 快速订阅 | ✅ `createSubscription` |
| `/reader/api/0/subscription/import` | POST | OPML 导入 | ✅ `importOPML` |
| `/reader/api/0/disable-tag` / `rename-tag` | POST | 删/改名文件夹 | ✅ `deleteTag`/`renameTag` |

**结论**：NetNewsWire 用到的端点集合是规范的一个**精心裁剪子集**——不做 `unread-count`（本地算）、不做 `user-info`（不需要用户 ID）、不做 `stream/contents`（用 `ids`+`items/contents` 更省流量）、不做 `mark-all-as-read`。PaperRss 实现时**照抄这个子集即可**，无需实现全部端点。

### 3.3 增量同步机制（ot / nt / continuation / n）

- 规范语义（[ApiStreamItemsIds.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ApiStreamItemsIds.wiki)、[ApiStreamContents.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ApiStreamContents.wiki)）：`n` 每页数量（ids 上限 10000，contents 上限 1000，默认 20）；`ot`/`nt` 为 Unix 秒级时间戳的"早于/晚于"窗口；`c` 为 continuation token（响应带 `continuation` 字段时用 `c=` 继续翻页）。
- **NetNewsWire 的实战参数**（[ReaderAPICaller.retrieveItemIDs:454-556](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L454-L556)）：
  - `n=1000&output=json`；
  - `.allForAccount`：`s=user/-/state/com.google/reading-list&ot=<lastArticleFetchStartTime 或 3 个月前>`；**翻页完成后用响应 Date 头把 `lastArticleFetchStartTime` 推进到本次拉取时刻**（服务端时间为准，避免客户端时钟漂移）；
  - `.unread`：`s=reading-list&xt=user/-/state/com.google/read`（排除已读）；`.starred`：`s=user/-/state/com.google/starred`；
  - `.allForFeed`：`s=<feedID>&ot=<3 个月前>`（新增 feed 时的初始拉取）；
  - 递归跟随 `continuation` 直到没有为止（[L517-556](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L517-L556)）。
- **BazQux "The Right Way to Sync"**（[bazqux-api README](https://github.com/bazqux/bazqux-api#user-content-the-right-way-to-sync)，FreshRSS 官方文档明确推荐的同步策略）：**不要**用 `ot` 做日常增量（会漏掉：新订阅 feed 的旧文、被手动翻回未读的旧文、服务端过滤/回收后消失的文章）；**正确姿势**是：拉 `subscription/list` + `tag/list` → 拉 unread/starred（及标签）的**全量 ID 列表**（`n=1000` 分页，建议客户端设 25000 条上限）→ 从本地删除不在列表里的文章 → 按需拉 `items/contents` 补正文 → 与本地状态做差集 → 用 `edit-tag` 写回。**NetNewsWire 的 refreshAll 管线（2.4）正是这个策略的完整实现**；其 `ot` 仅用于首次/新增 feed 的历史窗口，不用来做日常增量。

### 3.4 文章 ID 格式与 tag 系统

- **ID 两种形式**（[ItemId.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ItemId.wiki)）：内部是 **64 位整数**；长形式 = `tag:google.com,2005:reader/item/` + **16 位小写十六进制（0 填充，无符号）**；短形式 = **有符号十进制**（可为负，补码）。规范建议"把响应里的 ID 当不透明字符串存、原样传回，别做转换"。
- **NetNewsWire 的做法（与规范建议不同，但更省空间）**：响应中的长形式（如 `tag:google.com,2005:reader/item/00058a3b5197197b`）经 `ReaderAPIEntry.uniqueID`（[ReaderAPIEntry.swift:83-101](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIEntry.swift#L83-L101)）转成**十进制字符串**存库（TheOldReader 例外：保留原样字符串）；写回时 `itemIDParameter`（[ReaderAPICaller.swift:662-671](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L662-L671)）用 `String(format: "%.16llx", Int(id)!)` 转回 16 位十六进制长形式拼 `i=tag:google.com,2005:reader/item/<hex>`。**负数 ID 也能正确往返**（UInt64 格式化的补码语义）。非数字 ID（除 TheOldReader）被判定不可发送。
- **状态 tag 映射**（NetNewsWire `ReaderState`/`ReaderStreams`，[ReaderAPICaller.swift:35-42](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L35-L42)）：
  - 已读：`user/-/state/com.google/read`；未读 = `edit-tag` 里 `r=...read`（+ 可加 `a=...kept-unread`，NetNewsWire 未用 kept-unread）；
  - 星标：`user/-/state/com.google/starred`；全站流：`user/-/state/com.google/reading-list`；
  - 文件夹：`user/-/label/<name>`（`tag/list` 里过滤 `/label/` 即得文件夹，Inoreader 需 `type=="folder"` 过滤）；条目 `categories` 数组直接给出它所属的 label/state。
- **与 PaperRss 的映射**（沿用 freshrss-api-research.md 3.2，不重复）：`isRead ↔ com.google/read`、`isStarred ↔ com.google/starred`；`edit-tag` 的 `a=` 加标签 / `r=` 删标签。

### 3.5 多实现兼容差异与坑（重点补充）

**（a）服务端实现差异对照表**：

| 服务 | greader 兼容性 | NetNewsWire 接入 | 已知差异/坑 |
| :--- | :--- | :--- | :--- |
| **FreshRSS** | 完整（官方实现 [p/api/greader.php](https://github.com/FreshRSS/FreshRSS/blob/edge/p/api/greader.php)） | `ReaderAPIAccountDelegate(.freshRSS)`，endpoint 由用户在设置里填 | ① 必须用 API 专用密码；② **feed 不允许在根目录、不允许同时进多个文件夹**（`behaviors = [.disallowFeedInMultipleFolders, .disallowFeedInRootFolder]`，[ReaderAPIAccountDelegate.swift:69-75](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L69-L75)）；③ **标题/作者/feed 名中的 `& < >` 被转成全角 `＆＜＞`，需反转义**（`decodingFullwidthEscapedCharacters`，[L1242-1249](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L1242-L1249)，对应 [issue #5143](https://github.com/Ranchero-Software/NetNewsWire/issues/5143)） |
| **Inoreader** | 完整 + 扩展 | `.inoreader`，baseURL 固定 `https://www.inoreader.com` | ① 所有请求需 `AppId`/`AppKey` 头（`addVariantHeaders`，[ReaderAPICaller.swift:608-613](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L608-L613)）；② 响应带 `X-Reader-Zone1-Usage/Limit/Reset-After` 限流头，客户端据此刻意**跳过状态下载以省配额**（[ReaderAPIAccountDelegate.swift:1222-1234](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L1222-L1234)、[issue #4476](https://github.com/Ranchero-Software/NetNewsWire/issues/4476)）；③ `tag/list` 需 `types=1` 参数、文件夹按 `type=="folder"` 过滤 |
| **The Old Reader** | 完整 | `.theOldReader`，baseURL 固定 | ① **文章 ID 保留原始字符串**（不做 hex↔decimal 转换），`i=` 直接用 `tag:google.com,2005:reader/item/<raw>`；② 删除文件夹时**不调 `disable-tag`**（[ReaderAPIAccountDelegate.swift:441-448](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift#L441-L448)） |
| **BazQux** | 完整（官方 [bazqux-api](https://github.com/bazqux/bazqux-api)） | `.bazQux`，baseURL 固定 | ① 商业订阅制，登录失败有 `X-BQ-LoginErrorReason` 头（需展示"订阅过期"类错误）；② **不做"30 天自动已读"**，且每 feed 只保留最近 500 条、有真过滤——所以必须用 ID 差集法同步，不能用 `ot` 窗口（详见 3.3） |
| **Miniflux** | **无可用 greader 端点** | **不支持** | Miniflux 的 greader 实现是 [WIP PR #1115](https://github.com/miniflux/v2/pull/1115)（从未合并）；NetNewsWire 原生 Miniflux 账号 [PR #5335](https://github.com/Ranchero-Software/NetNewsWire/pull/5335) 长期 **OPEN** 未合并；用户强接会遇 [issue #3512 "miniflux greader errors"](https://github.com/Ranchero-Software/NetNewsWire/issues/3512)。**freshrss-api-research.md 中"GReaderAPIAdapter 可低成本适配 Miniflux"的表述不成立，本文予以更正** |
| **Tiny Tiny RSS** | 无原生 | 不支持 | greader 兼容需第三方 [freshapi 插件](https://github.com/eric-pierce/freshapi)，存在登录失败等兼容问题（[issue #14](https://github.com/eric-pierce/freshapi/issues/14)），不推荐作为目标服务 |

**（b）实现层通用坑（NetNewsWire 源码可证）**：
1. **写操作必须带 `T=` 令牌**，且令牌会过期——实现必须做"401/403 → 重取 token → 重试一次"（`withWriteToken` 模式），否则长期运行后所有写同步静默失败。
2. **`edit-tag` 的 `i=` 参数用长形式十六进制**（NetNewsWire 的做法），FreshRSS 等接受；直接用短形式十进制也合法（规范两种形式都接受），但**两种形式混用可能导致部分服务端去重失败**——建议固定一种。
3. **非数字文章 ID 无法编码**（除 TheOldReader）——设计数据模型时 ID 必须容忍"不可发送"状态并丢弃而非死循环重试。
4. **纯文本响应**（ClientLogin 的 `key=value`、edit-tag 的 `OK`）不能按 JSON 解析（与 freshrss-api-research.md 4.3 一致）。
5. **条件请求（ETag/Last-Modified）只适用于 `subscription/list` 与 `tag/list`**（`ConditionalGetKeys`，[ReaderAPICaller.swift:44-47](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L44-L47)）；304 返回空体→调用方跳过对账。文章流不做条件请求（以 ID 差集代替）。
6. **自托管服务（FreshRSS）的 baseURL 必须来自用户输入的 endpoint**（`apiBaseURL` 对 `.generic/.freshRSS` 读 `accountSettings.endpointURL`，[ReaderAPICaller.swift:81-91](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift#L81-L91)），托管服务（Inoreader/BazQux/TheOldReader）用固定 host——**同一套 caller 代码用 `ReaderAPIVariant` 切换**，这正是"协议复用收益"的源码体现。

---

## 四、问题三：PaperRss 接入 FreshRSS 服务账号的可行性

### 4.1 现状对照（PaperRss 现有架构 vs 目标形态）

| 维度 | PaperRss 现状（源码位置） | 引入服务账号后需要的形态 |
| :--- | :--- | :--- |
| 数据模型 | `AppDatabase` 单库 JSON：`feeds/entries/articleCaches/readingStates/artifacts/llmConfiguration/customFolders`（[Models.swift:471-503](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/Models.swift)）；`Feed.id: UUID`、`Entry.id: String`（= `"\(feedID)|\(itemID)".stableDigest`，[AppStore.swift:1633](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/AppStore.swift)）；`folder: String?` | 新增 `Account` 模型；`Feed` 加 `accountID: UUID?`；服务账号条目 ID 需用服务器 article ID；folder 需按账号隔离 |
| 读路径 | `EntryLibraryIndex` 预排序快照，`byFeed: [UUID:[Entry]]`、`byFolder: [String:[Entry]]`（[AppStore.swift:61-179](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/AppStore.swift)） | 分组 key 增加账号维度（文件夹同名冲突）；未读/星标/today 聚合语义不变 |
| 刷新编排 | `AppStore.refresh()`：TaskGroup 并发 6 + 每 feed 10s 超时，直接抓 feed URL（[AppStore.swift:717-826](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/AppStore.swift)、[FeedService.swift](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/FeedService.swift)） | 服务账号走"按账号刷新"（一次 `subscription/list + ids + contents + 状态对账`），不复用逐 feed 抓取 |
| 状态写回 | `markRead/toggleStar → update()`：改 `Entry` + `readingStates` → rebuild → persist → 2s 去抖 CloudKit（[AppStore.swift:828-873, 1652-1659](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/AppStore.swift)） | 服务账号条目需"乐观更新 + 待发队列 + `edit-tag` 写回 + 周期对账"；**不能走 CloudKit**（会与服务端双写冲突） |
| 云同步 | `CloudSyncService`：整库序列化成单条 CloudKit 记录，`updatedAt` 合并（[CloudSyncService.swift:13-39](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/CloudSyncService.swift)） | 服务账号数据建议**不参与** CloudKit 合并（服务端权威），或明确标记 local-only |
| AI 管线 | `articleText(for:)`：优先 feed 内正文，否则 `ArticleExtractor` 抓网页（[AppStore.swift:930-1008](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/AppStore.swift)） | **基本不动**：greader 正文（`stream/items/contents` 的 `summary.content` HTML）直接存 `Entry.contentHTML` 即可复用现有管线；摘要-only 时现有网页抓取兜底不变 |
| 侧栏 UI | 单一列表：智能订阅（today/unread/starred）+ 文件夹 + feed（[RootView.swift](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/App/RootView.swift)） | 增加账号分组节点；设置页加账号管理（参照 NetNewsWire Settings > Accounts） |

### 4.2 最小改动面与侵入点（逐项）

1. **数据模型（`PaperRssCore/Models.swift`）**——最小改动：
   - 新增 `AccountType`（`local`/`freshRSS`，rawValue 固定）与 `Account`（id/name/type/serverURL/username/allowSelfSignedCerts/authToken 或 credentialsRef）——可直接采用 issue-2 草案 1.1 的设想，仅需把凭据存储建议改为 Keychain 引用（PaperRss 现有 [KeychainStore.swift](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/Core/KeychainStore.swift) 可复用）。
   - `Feed` 加 `accountID: UUID?`（nil = 本地）；`AppDatabase` 加 `accounts: [Account]`（所有字段用 `decodeIfPresent` 保证旧库兼容——Models.swift 已有成熟先例）。
   - **`Entry.id` 是最大侵入点**：本地条目 = `stableDigest(feedID|itemID)`；服务账号条目应直接用服务器 article ID（十进制字符串）。建议服务账号条目的 `id` 带命名空间前缀（如 `fr:<articleID>`）或独立字段，避免与本地 digest 撞车、并让 CloudKit 去重/级联删除逻辑（`purgeEntriesFromInactiveFeeds`）能按 `accountID` 过滤。
   - **folder 冲突**：两个账号可以有同名文件夹。最小方案是 `EntryLibraryIndex` 的 folder key 改为 `(accountID, folder)` 二元组（见下）。
2. **读路径（`EntryLibraryIndex`）**——改动集中在分组 key：`byFolder`/`unreadByFolder`/`listItemsByFolder` 的 `[String: ...]` 需加账号维度（可用 `"\(accountID)|\(folder)"` 复合 key 或引入 `FolderKey` 结构）。全库聚合（unread/starred/today/未读数）语义不变，服务账号未读自动并入——这是单库架构的红利。
3. **刷新编排（`AppStore.refresh`）**——建议**分支而非改造**：`refresh` 里按 `feed.accountID` 分组，本地 feed 走现有 TaskGroup 管线；服务账号 feed 跳过，改由新的 `FreshRSSSyncEngine.refresh(account:)`（仿 `ReaderAPIAccountDelegate.refreshAll`：订阅树对账 → 拉 IDs → 乐观已读 → 状态对账 → 补正文）。`feedFetcher` 注入点可扩展为"账号刷新手柄"以保持可测试性。注意：服务账号刷新是"每账号 1 次大请求"而非"每 feed 1 次"，PaperRss 现有的 6 并发/10s 超时模型不适用于它。
4. **状态写回**——新增"待发队列"（`AppDatabase` 里加 `pendingSync: [PendingStatus]` 或仿 NetNewsWire `SyncDatabase` 建 SQLite；考虑到 PaperRss 全 JSON 持久化，建议先内存 + JSON 数组）。`markRead/toggleStar` 对服务账号条目：本地乐观更新不变 → 入队 → 后台调 `edit-tag`（批量 1000）→ 周期（如 2 分钟）跑一次"下载 unread/starred IDs 对账"，**对账必须排除 pending 中的条目**（NetNewsWire 的防回滚关键）。token 过期处理照抄 `withWriteToken` 模式。
5. **UI**——侧栏（SwiftUI `List`，[RootView.swift](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/App/RootView.swift)）：按 `accountID` 分组渲染 Section（账号名做组头，参照 NetNewsWire 的 `isGroupItem` 组头样式）；设置页（[SettingsView.swift](https://github.com/ohmyangboy/PaperRss/blob/main/PaperRss/Sources/App/SettingsView.swift)）加"服务账号"分节：endpoint + 用户名 + API 密码 → ClientLogin → 存 token；自签名证书开关（freshrss-api-research.md 4.2 的 `URLSessionDelegate`）。本地/远程区分：组头 + 账号图标/配色。
6. **AI 管线**——**零改动或近零改动**：`articleText(for:)` 已优先 `entry.contentHTML`；把 `ReaderAPIEntry.summary.content` 写入 `Entry.contentHTML` 即可让翻译/总结/解释复用全部现有逻辑与缓存（`AIArtifact` keyed by entryID）。唯一注意点：服务账号正文**只进本地 `articleCaches`/`contentHTML`，不进 CloudKit**（现有 `CloudLibrary` 本就不含 entries，天然满足）。若服务器只有摘要，`ArticleExtractor` 抓 `entry.url` 的兜底逻辑不变。
7. **CloudKit 交互（决策点）**：服务账号的 `feeds/readingStates` **建议不进 `CloudLibrary`**（服务端是权威，进 CloudKit 会造成"本机与服务器冲突 + 无凭据设备读到陈旧数据 + 删除/重命名跨设备打架"）。最小实现：`CloudLibrary.from(_:)` 过滤 `accountID == nil` 的 feed 及其 readingStates。这是比 NetNewsWire 更简单的边界（NetNewsWire 直接给每账号独立存储，天然隔离）。

### 4.3 分阶段建议与主要风险

**阶段一：只读拉取 + 状态写回（建议优先，覆盖核心价值）**
- 内容：`Account` 模型 + `FreshRSSClient`（greader：ClientLogin/token/subscription-list/tag-list/ids/items-contents/edit-tag）+ `FreshRSSSyncEngine`（订阅树对账、ID 差集、正文补拉、edit-tag 写回队列与对账）+ 侧栏账号分组 + 添加账号设置页。
- 验收（对应草案 issue-2 第 3 节）：ClientLogin 通过、拉取分类与订阅、本地点已读/加星实时反映并在后台 `edit-tag` 同步回 FreshRSS Web 端。
- 主要风险：
  - `Entry.id` 命名空间与旧库迁移（本地 digest 与服务账号 ID 混用导致去重/级联删除误伤）；
  - 同名文件夹跨账号冲突（读路径 key 必须带账号维度）；
  - token 过期导致写回静默失败（必须做 401 重取重试）；
  - 正文体积（`items/contents` 拉全量正文可能很重——用"有状态但无正文才补拉"策略控制，并设条目上限）。
- 结论：**改动面集中在 Core 层新增两个文件 + Models 三处字段 + AppStore 三处分支**，不触碰读渲染核心，风险可控。

**阶段二：订阅管理**
- 内容：`quickadd`（添加订阅）、`subscription/edit`（改名/移动/退订）、`disable-tag`/`rename-tag`（文件夹管理）、`subscription/import`（OPML 导入到服务端）；本地 `addFeed/deleteFeed/renameFolder` 等操作按 `accountID` 分流到服务端。
- 主要风险：
  - **语义分叉**：服务账号的订阅管理是"服务端权威 + 本地回读对账"，与 PaperRss 现有"本地即事实"的 `addFeed/deleteFeed/OPMLService` 语义冲突，需要显式分支而非复用；
  - **FreshRSS 强制 feed 必须入文件夹**（NetNewsWire 用 `AccountBehaviors.disallowFeedInRootFolder` 表达）——PaperRss 现有"根级 feed"与"文件夹"并存，需对服务账号 UI 做约束或自动建"未分类"文件夹；
  - 订阅创建后需立即拉一次该 feed 的初始文章（NetNewsWire `initialFeedDownload` 模式，`allForFeed + ot=3个月前`）。

**阶段三：完整多账号**
- 内容：多服务账号（多个 FreshRSS/未来其他 greader 服务）+ 账号启停/删除/重命名 + 每账号独立刷新调度 + 未读聚合与账号级未读数。
- 主要风险：
  - `EntryLibraryIndex` 全库聚合的重构（账号级过滤/计数）；
  - 刷新编排复杂度（每账号刷新频率、失败隔离、进度聚合）——NetNewsWire 用 `AccountManager.refreshAll` TaskGroup + `CombinedRefreshProgress`，可照搬模式；
  - CloudKit 边界在多账号下的规则固化（哪些数据属于哪个同步通道）；
  - AI 缓存（`AIArtifact`）按 entryID keyed，多账号同名 ID 需确认命名空间前缀已彻底隔离。

### 4.4 明确结论：完整照搬 vs 轻量适配

**不建议完整照搬 NetNewsWire 账号体系，建议轻量适配。** 理由：

1. **复杂度不匹配**：NetNewsWire 账号体系的复杂度来自三件事——每账号独立目录 + 每账号独立 SQLite（`ArticlesDatabase`）、9 种账号类型的 delegate 矩阵、`AccountBehaviors` 行为差异矩阵。PaperRss 是单库 JSON + 单目标服务（FreshRSS），这三件事都用不上；硬照搬等于把"多账号数据库隔离"的复杂度提前背上。
2. **协议层反而要照抄**：greader 协议实现（`ReaderAPICaller` 的端点子集、`T=` 令牌与 401 重试、ID 十六进制编码、`n=1000` 分页与 `ot` 历史窗口、edit-tag 批量 1000、状态对账排除 pending、`items/contents` 按需补正文）是**经 NetNewsWire 多年打磨、可直接复用的工程蓝本**——协议行为照抄，账号外壳轻量化。
3. **值得借鉴的两个抽象**：
   - **`AccountDelegate` 协议**：把"数据从哪来（refreshAll）、状态往哪写（markArticles/syncArticleStatus）"协议化，UI 与 AppStore 只依赖协议。PaperRss 可以把它降维成 `FreshRSSAccount` 一个实现 + 未来加 variant 参数即可扩展其他 greader 服务（Inoreader/BazQux/TheOldReader 只是 `ReaderAPIVariant` 的差异）。
   - **`AccountBehaviors` 思路**：至少需要一个"feed 必须在文件夹"的服务端约束表达，避免 UI 允许用户做服务器不支持的操作。
4. **数据归属原则**：服务账号数据"本地缓存、服务端权威、不进 CloudKit"；本地账号数据维持现状（CloudKit 单记录合并）。两条同步通道互不交叉，冲突面最小。

**一句话结论**：PaperRss 应实现"**一个 greader 兼容服务账号（阶段一先行）**"，数据模型加 `accountID`、刷新走独立 `FreshRSSSyncEngine`、状态写回走"乐观更新 + 待发队列 + edit-tag 对账"、侧栏加账号分组；协议实现直接对标 NetNewsWire `ReaderAPICaller`。此路径在不动读渲染核心与 AI 管线的前提下即可交付 FreshRSS 双端同步的核心价值。

---

## 五、参考资料

### NetNewsWire（一手源码，main 分支快照 commit `ab2f35f`）

- 仓库：[Ranchero-Software/NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire)（任务中给出的 `NetNewsWire/NetNewsWire` 已失效，特此更正）
- [Account.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/Account.swift)（`AccountType`/`Account`）
- [AccountDelegate.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/AccountDelegate.swift)
- [AccountManager.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/AccountManager.swift)
- [AccountBehaviors.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/AccountBehaviors.swift)
- [ReaderAPIAccountDelegate.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift)（greader 同步引擎，refreshAll/markArticles/对账/全角转义）
- [ReaderAPICaller.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPICaller.swift)（greader HTTP 客户端：端点/token/ID 编码/分页）
- [ReaderAPIVariant.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIVariant.swift)
- [ReaderAPIEntry.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/ReaderAPIEntry.swift)（ID 转换）
- [URLRequest+ReaderAPI.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/ReaderAPI/URLRequest%2BReaderAPI.swift)（认证头）
- [LocalAccountDelegate.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/LocalAccount/LocalAccountDelegate.swift) / [LocalAccountRefresher.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Sources/Account/LocalAccount/LocalAccountRefresher.swift)
- [SyncStatus.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/SyncDatabase/Sources/SyncDatabase/SyncStatus.swift)（待发状态队列模型）
- [ArticleStatusSyncTimer.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Shared/Timer/ArticleStatusSyncTimer.swift)（状态同步调度）
- [SidebarTreeControllerDelegate.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Shared/Tree/SidebarTreeControllerDelegate.swift)（侧栏账号树）
- [SidebarViewController.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Mac/MainWindow/Sidebar/SidebarViewController.swift) / [SidebarCell.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Mac/MainWindow/Sidebar/Cell/SidebarCell.swift)（账号组头/单元格）
- [Technotes/Accounts.markdown](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Accounts.markdown)（官方架构说明）
- [iOS/Account/ReaderAPIAccountViewController.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/iOS/Account/ReaderAPIAccountViewController.swift)（账号添加流程）
- NetNewsWire 相关 issue：[#5143 FreshRSS 全角转义](https://github.com/Ranchero-Software/NetNewsWire/issues/5143)、[#4476 Inoreader 限流](https://github.com/Ranchero-Software/NetNewsWire/issues/4476)、[#3593 Miniflux 账号](https://github.com/Ranchero-Software/NetNewsWire/issues/3593)、[PR #5335 Miniflux（未合并）](https://github.com/Ranchero-Software/NetNewsWire/pull/5335)、[#3512 Miniflux greader 报错](https://github.com/Ranchero-Software/NetNewsWire/issues/3512)

### greader 协议（一手规范与官方文档）

- [FreshRSS 官方文档 · Google Reader compatible API](https://freshrss.github.io/FreshRSS/en/developers/06_GoogleReader_API.html)（认证示例、token、端点、同步策略链接）
- [FreshRSS 服务端实现 p/api/greader.php](https://github.com/FreshRSS/FreshRSS/blob/edge/p/api/greader.php)
- [mihaip/google-reader-api](https://github.com/mihaip/google-reader-api)：[Authentication.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/Authentication.wiki)、[ApiEditTags.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ApiEditTags.wiki)、[ActionToken.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ActionToken.wiki)、[ItemId.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ItemId.wiki)、[ApiStreamItemsIds.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ApiStreamItemsIds.wiki)、[ApiStreamItemsContents.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ApiStreamItemsContents.wiki)、[ApiStreamContents.wiki](https://github.com/mihaip/google-reader-api/blob/master/wiki/ApiStreamContents.wiki)
- [bazqux/bazqux-api（含 The Right Way to Sync）](https://github.com/bazqux/bazqux-api#user-content-the-right-way-to-sync)
- [miniflux/v2 PR #1115（greader 实现，WIP 未合并）](https://github.com/miniflux/v2/pull/1115)
- [eric-pierce/freshapi（TTRSS greader 插件）issue #14](https://github.com/eric-pierce/freshapi/issues/14)

### PaperRss（本地源码，路径为相对仓库根）

- `PaperRss/Sources/Core/Models.swift`、`AppStore.swift`、`CloudSyncService.swift`、`FeedService.swift`、`FeedParser.swift`、`KeychainStore.swift`、`OPMLService.swift`
- `PaperRss/Sources/App/RootView.swift`、`ThreeColumnSplitView.swift`、`SettingsView.swift`
- 前置调研：[docs/research/freshrss-api-research.md](./freshrss-api-research.md)、[drafts/issue-2-freshrss-spec-draft.md](../../drafts/issue-2-freshrss-spec-draft.md)

---

## 六、未能核实/存疑的点（如实标注）

1. **早期 NetNewsWire 的独立 downloader/updater 类型**：当前 main 分支与 mac-6.2.1 标签中均已不存在独立的 `FeedDownloader`/`ArticleStatusDownloader`/`ArticleContentDownloader` 类（刷新逻辑内聚在 delegate 内，此结论已核实）；但更早期（约 2019 年前）是否曾有该类及其精确文件路径，本次调研未逐版本核实，**待核实**。若需写进对外文档，建议以当前架构为准。
2. **FreshRSS 对"十六进制长形式 `i=`"的接受度**：NetNewsWire 实测可用（其兼容客户端列表中包含 NetNewsWire），但未在 FreshRSS 源码中逐行确认 ID 解析分支；如需严谨结论，应直接读 `p/api/greader.php` 的 `edit-tag` 实现（**建议阶段一实现时验证**）。
3. **`mark-all-as-read` 端点**：FreshRSS 实现了它（freshrss-api-research.md 已列），但原始 Google Reader 规范（mihaip wiki）中没有该端点的独立条目，NetNewsWire 也从不使用；其精确参数语义（`s=` + `ts=`？）**待核实**——PaperRss 若走"拉全量 ID + 本地标记"路线可完全回避。
4. **`/reader/api/0/token` 在 FreshRSS 中的有效期**：原始规范为 30 分钟，FreshRSS 行为未单独实测；NetNewsWire 的"401/403 重取重试"模式已能容忍任何有效期，建议照抄该模式即可。
5. **`user-info`/`unread-count` 端点的响应细节**：NetNewsWire 不使用，本文未逐字段核实其 JSON 结构（freshrss-api-research.md 有部分描述）；PaperRss 不需要实现这两个端点。
6. **任务背景中"NetNewsWire 有 GoogleReader 账号类型/实现"的表述**与当前 main 源码不符（无 `googleReader` case、无 GoogleReader delegate 文件）。本文以当前源码为准；若任务背景所指为历史版本或另一仓库，建议以本文源码结论复核。

---

*本报告基于 2026-08-13 抓取的 NetNewsWire main 分支源码快照与公开协议文档整理，归档至 PaperRss 官方文档库，供 Issue #2 架构评审使用。*
