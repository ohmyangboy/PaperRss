# PaperRss：Miniflux 账号扩展技术方案

**路线：Google Reader 兼容 API，共享协议层与状态同步基础设施**  
**状态：技术提案，尚未实施或完成服务端联调**  
**编写日期：2026-09-15**  
**代码基线：`ohmyangboy/PaperRss`，`main` 提交 `9c04916de3b92d60bf8aa3a7f687bb64127a2445`（2026-09-14）**

本方案基于当前账号模型、数据库迁移、Repository、FreshRSS HTTP 客户端、Provider、凭据存储，以及 AppStore / 设置 / 侧栏中的账号类型分支进行静态核对。Miniflux 行为依据其官方文档与当前 `internal/googlereader` 实现；这些资料不代表所有历史发布版本均具备相同能力。实施前须锁定实际测试的发布版本和镜像摘要，验证最低支持版本。本文不表示已经修改仓库、运行测试或对真实 Miniflux 账户联调。

## 1. 推荐决策与边界

**新增 Miniflux 服务身份，复用 Google Reader 协议实现；共享账号、数据库、文章状态和离线队列，通过服务配置与同步策略处理差异。**

这里区分两件事：账号类型描述“连接哪个服务”，协议实现描述“怎样与它通信”。因此可以保留 `freshRSS`、增加 `miniflux`，同时让二者使用一个 Reader API 客户端和共享 Provider 骨架，不需要把旧 FreshRSS 账号批量改名为 Google Reader 账号。

本次交付以 FreshRSS、Miniflux 两个明确预设为验收范围。底层预留通用 Reader 服务配置，未来开放“其他 Google Reader 兼容服务”高级入口；该入口不是本次 Miniflux 接入的前置条件，也不能据此宣称支持全部兼容服务。若同批发布通用入口，须单独补充账号类型、数据库约束及能力验收。

第一阶段不接入 Miniflux 原生 REST API，不引入第二套认证，不重做文章渲染、AI 能力、GRDB 数据模型或本地账号。Miniflux 原生 API 保留为后续需要额外服务能力时的独立决策，不混入首版同步链路。

### 1.1 首期功能范围

| 功能 | 首期要求 |
| --- | --- |
| 添加、启用、停用、删除 Miniflux 账号 | 支持；与本地、FreshRSS 账号并存 |
| 账号重启恢复、凭据更新 | 支持；凭据仅进 Keychain |
| 订阅、分类、文章读取 | 支持；包含服务端空分类 |
| 已读 / 未读、星标 / 取消星标 | 双向同步；支持离线修改和重试 |
| 批量“全部已读” | 针对本地查询命中的文章，逐项进入现有状态队列 |
| 添加、退订订阅 | 支持；使用服务端返回的真实订阅标识 |
| 删除分类 | 支持 Miniflux 的“保留订阅、重新归类”语义 |
| 单独创建空分类 | 首版不承诺；界面禁用并解释限制，不伪造本地成功 |
| 独立分类重命名、移动订阅 | 不扩大本次必交范围；接口能力与界面后续单独接入 |
| 服务端强制抓取所有源、规则管理、用户管理 | 不在首期范围 |

“连接成功”只表示账户和必要读取接口通过校验；“同步完成”必须满足本轮文章和状态同步目标，二者不能混用。

## 2. 当前代码核对结果

下表中的“当前行为”是代码事实；“处理要求”是本方案建议。

| 当前位置 | 已核实的当前行为 | 处理要求 |
| --- | --- | --- |
| `Core/Account/Account.swift` | `AccountType` 只有 `local`、`freshRSS`；已有 `AccountProvider` 抽象 | 增加服务身份，保留统一 Provider 边界 |
| `Core/Account/SyncCoordinator.swift` | 通过 `any AccountProvider` 注册、调度账号 | 复用调度；核对停用、移除及异步重入保护 |
| `Persistence/DatabaseMigrations.swift` | `accounts.type` 有 `CHECK (type IN ('local', 'freshRSS'))` | 必须新增正式迁移，仅改 Swift 枚举会被数据库拒绝 |
| `Persistence/Repositories/AccountRepository.swift` | 去重逻辑只检查 FreshRSS，并使用其专用地址规范化 | 统一有效端点与账号去重规则 |
| `Persistence/Repositories/ArticleStateRepository.swift` | 单篇已读、单篇星标、全部已读三条路径只为 FreshRSS 生成 outbox | 改为明确的远端状态同步能力判断 |
| `FreshRSS/ReaderAPIClient.swift` | 普通地址自动追加 `/api/greader.php` | 地址解析必须由服务配置决定 |
| 同上，`fetchItemContents` | POST 正文请求只有 Authorization 和 `i`，没有表单 `T` | 为 Miniflux 的 POST 认证补齐 `T` |
| 同上，文章流方法 | 调用 `GET /stream/contents/...` | Miniflux 使用 IDs + POST contents 路径 |
| `FreshRSS/FreshRSSAccountProvider.swift` | 初次和后续文章同步依赖文章流接口 | 抽出文章发现策略，不照搬调用链 |
| 同上，分类同步 | 仅把 `subscriptions[].categories` 当作权威分类来源 | Miniflux 还需要 `tag/list`，避免丢失空分类 |
| 同上，`deleteFolder` | 会退订分类中订阅，并吞掉部分远端错误后修改本地数据 | Miniflux 路径不得复用该删除语义 |
| `Core/Account/CredentialStore.swift` | 接口名称与默认 Keychain service 都是 FreshRSS 专用 | 泛化调用接口，但保留旧 Keychain 命名空间 |
| `Core/AppStore.swift` | Provider 注册与账号管理包含 FreshRSS 分支 | 集中到账号工厂与通用账号生命周期 |
| `App/SettingsView.swift`、`App/RootView.swift` | 账号展示 / 筛选存在 FreshRSS 专用条件 | 账号列表与侧栏改为服务配置驱动 |

来源见文末 S1–S11。特别注意：架构文档中部分“首期非目标”是历史规划；判断当前实现时以本次实际代码为准。

## 3. 目标结构

```text
SwiftUI / AppKit
  SettingsView / RootView
          │
       AppStore
          │
   AccountProviderFactory
          │
   SyncCoordinator
       ┌──┴─────────────────────────────┐
       │                                │
LocalAccountProvider              ReaderAccountProvider
                                      │
                    ┌─────────────────┴────────────────┐
                    │                                  │
          FreshRSS 服务配置与策略              Miniflux 服务配置与策略
                    └─────────────────┬────────────────┘
                                      │
                                ReaderAPIClient
                                      │
                         ReaderAPIAuthenticator
                         ReaderEndpointResolver
                                      │
                              FreshRSS / Miniflux

共享：LibraryDatabase / Repository / ArticleStateOutboxProcessor
      文章、状态、正文缓存、AI 产物及账号隔离规则
```

“共享 Provider”意味着复用刷新编排、落库、状态调和、进度、重试，并不要求两个服务执行完全相同的网络请求。FreshRSS 原有文章流策略先保持行为不变；Miniflux 采用 IDs 枚举策略。

建议只新增实际需要的几个抽象，不建设通用插件框架：

| 新增或调整模块 | 职责 |
| --- | --- |
| `AccountProviderFactory` | 根据账号类型创建 Provider、配置凭据作用域、恢复账号 |
| `ReaderServiceProfile` | 地址规则、认证要求、读取策略、分类规则及能力 |
| `ReaderEndpointResolver` | 返回一致的登录地址与 API 根地址；禁止各处自行拼接 |
| `ReaderAccountProvider` | 共享刷新顺序、落库和字段级状态调和 |
| `ReaderSyncStrategy` | 封装 FreshRSS 文章流与 Miniflux IDs 发现差异 |
| `ReaderAPIClient` | HTTP / 编解码，不依赖 UI，不直接写数据库 |

`FreshRSSAccountProvider` 可以先保留为薄封装，以旧初始化接口构造共享 Provider 的 FreshRSS 配置。不要复制整个旧 Provider 作为 `MinifluxAccountProvider` 再分别维护。

## 4. 账号模型、能力与数据库迁移

### 4.1 保留服务身份，单独派生协议

以下为接口草案，不是可直接应用的补丁：

```swift
public enum AccountType: String, Codable, Hashable, Sendable {
    case local
    case freshRSS   // 保留已有持久化值
    case miniflux
}

public enum AccountBackend: Sendable {
    case localFeed
    case googleReader
}

extension AccountType {
    public var backend: AccountBackend {
        switch self {
        case .local:
            return .localFeed
        case .freshRSS, .miniflux:
            return .googleReader
        }
    }

    public var syncsRemoteArticleStates: Bool {
        switch self {
        case .local:
            return false
        case .freshRSS, .miniflux:
            return true
        }
    }
}
```

持久化的 `AccountRecord.type` 仍可保留 String 映射，转换为领域类型时显式处理未知值：标为不受支持，不要当成本地账号，也不要用 `type != local` 推断所有未来类型都能同步。

本次无需增加冗余的数据库 `protocol` 字段；服务身份可派生当前协议。若未来同一服务支持用户选择原生 API 和 Reader API，再单独设计可持久化的连接方式，避免现在提前扩大模型。

### 4.2 数据库约束迁移是必做项

新增下一条具名迁移，例如 `extend-account-types-for-miniflux`，扩展为：

```sql
CHECK (type IN ('local', 'freshRSS', 'miniflux'))
```

不要修改已经发布的 `v1-create-library-schema`。本方案不更换 `account_id`，也不重建 items、articles、article_states、outbox 等业务身份。

变更 CHECK 应通过当前 GRDB 版本支持的安全表重建迁移流程进行，遵守 SQLite 官方对外键、索引和引用的要求。迁移前备份；在正确的迁移连接及事务边界管理外键；先构建新表、拷贝完整账号行，再替换旧表并恢复索引；进行外键与完整性校验后提交。不要先随意重命名父表导致子表引用变化，也不要在外键级联生效的情况下直接删除父表。不要通过业务代码零散 DDL 或 writable_schema 字符串替换绕过迁移。

验收不只比较 accounts 行数，还要检查账号 ID、订阅、分类关联、文章状态、outbox revision、正文缓存、AI 产物与同步状态均保留；`foreign_key_check` 不得产生错误。失败时整条迁移回滚，应用不得自动清库。

这属于有明确测试边界的数据层演进，不是重做数据库。SQLite 迁移依据见 S15。

### 4.3 账号去重

建议按以下有效连接身份做同事务去重：

```text
Google Reader 协议 + 规范化协议根地址 + 用户名
```

数据库去重、登录测试和实际请求必须共享同一个 EndpointResolver。保留部署子路径和用户名大小写语义，不能只比较域名。尾斜杠等无意义差异应归一；凭据绝不参与明文去重键。

本期至少覆盖“同一 Miniflux 账号重复添加”。未来开放通用入口后，同一地址与用户名不能通过 Miniflux 预设和通用入口重复添加。首次不用为此强制引入新的账号身份字段；可先沿用现有事务内查询模式。

## 5. 地址与认证

### 5.1 统一输出已解析的端点

建议由 resolver 返回：

```swift
public struct ReaderEndpoints: Sendable {
    public let protocolRootURL: URL
    public let loginURL: URL
    public let apiBaseURL: URL
}
```

`apiBaseURL` 的含义固定为包含 `/reader/api/0` 的 API 前缀。`protocolRootURL` 是其上层公共协议根，不与 API 前缀混用。

| 服务 | 地址处理 | 登录与 API |
| --- | --- | --- |
| FreshRSS | 保留现有对根地址、`/api/greader.php`、`/p/api/greader.php` 的兼容 | 协议根下 `accounts/ClientLogin` 与 `reader/api/0` |
| Miniflux | 用户填写部署根地址；保留配置的子路径；不追加 PHP 路径 | 部署根下 `accounts/ClientLogin` 与 `reader/api/0` |
| 未来通用入口 | 用户明确提供协议根地址；不猜测服务品牌 | 根据经过校验的配置构造端点 |

示例：

```text
输入 https://reader.example/miniflux/
登录 https://reader.example/miniflux/accounts/ClientLogin
API  https://reader.example/miniflux/reader/api/0
```

规范化不要删除有效子路径、反复追加 `/reader/api/0`，也不要接受 URL 中嵌入密码。认证请求不得静默跨主机重定向或降级 TLS。自托管网络策略沿用应用约束，不能为接入一个服务关闭全局证书校验。

### 5.2 Miniflux 使用 Google Reader 集成凭据

用户在 Miniflux“设置 → 集成”启用 Google Reader API，并配置这套接口的用户名和密码。它与 Miniflux 原生 API 的 `X-Auth-Token` 路线不同；不能在同一个密码框里混用两种认证。[S12、S14]

协议要求：登录使用表单 `Email`、`Passwd`；GET API 使用 `Authorization: GoogleLogin auth=...`；POST API 使用表单 `T`。尤其是 `POST stream/items/contents` 虽然是读取正文，也必须携带 `T`。`edit-tag` 的 `a`、`r` 放在请求体。[S12]

所有表单统一编码并覆盖 `+`、`&`、`=`、`%`、中文及空格测试。当前使用 URLComponents 构造请求体的地方应核对其是否满足服务端表单解码语义，不要假定 URL 查询编码等同于所有表单字符规则。

### 5.3 认证重试的关键约束

401 后失效 auth token 与 write token，重新认证，并重新构造整个请求，包括 Authorization 和表单 `T`。避免闭包捕获旧 writeToken 后只更新请求头。每次业务请求最多进行受控认证重试，不无限循环。

认证会话必须属于单个 accountID。共享的是客户端代码，不是多个账号的 token。多个并发请求触发登录时使用单次登录合并机制；凭据更新时使旧会话失效。

403 应结合接口和响应区分权限或令牌问题；不要把所有 403 都解释为密码错误。网络、HTTP、认证、响应结构、服务能力、业务失败分别分类，并对错误正文脱敏。

### 5.4 Keychain 向后兼容

当前默认 service 是 `com.paperrss.freshrss`，读取键包含 accountID。[S8]

建议泛化 CredentialStore 方法名或增加中性接口，但 FreshRSS 继续读取旧 service。Miniflux 使用独立命名空间，例如 `com.paperrss.miniflux.googlereader`。首版没有必要批量迁移旧凭据。

SQLite、UserDefaults、日志和错误消息中不保存密码、auth token、write token。令牌继续只放内存。

## 6. 协议兼容差异与响应校验

### 6.1 Miniflux 不直接使用现有文章流路径

PaperRss 当前 Provider 初次调用 `fetchRecentStreamContents`，后续调用 `fetchIncrementalStreamContents`，依赖 `GET stream/contents/...`。Miniflux 当前路由提供的是 `GET stream/items/ids` 与 `POST stream/items/contents`，未知 API 路径可能返回 HTTP 200 和 `[]`。[S4、S5、S12、S13]

所以 Miniflux 策略必须选择：

```text
读取文章 ID → 本地身份/缓存差集 → 分批 POST 获取正文
```

不能通过“某接口 HTTP 200”认定该能力存在，也不能把解码失败统一吞掉转换为空列表。合法空对象列表和不支持接口必须区分。例如订阅响应应匹配 subscription list 对象结构，正文响应应匹配包含 items 的对象，而不是顶层数组。

新增账号只做无破坏性的读取校验，不用退订、删除分类或改文章状态来探测能力。某个空账户缺乏正文样本时，标注对应能力尚未在该账户运行验证，交由固定测试环境验证，不伪造生产测试。

### 6.2 文章与订阅标识

Miniflux 的 IDs 响应与正文响应使用不同文章 ID 表达形式；feed 的读取 ID 和订阅创建参数也不同。[S12]

沿用 ReaderItemIDCodec，在协议边界进行已验证的十进制 / Tag URI 对齐；数据库继续保存远端原始身份和现有内部身份规则，不把远端 ID 改成 Int 或重新生成所有本地 item ID。

所有查重、状态调和、内容查询及外键关联都必须限定 accountID。不同服务可以出现相同远端 ID，同一文章 URL 也可能属于不同账号，不能据此合并阅读状态。

订阅源使用服务端返回的 `feed/<numeric_id>` 进行读取、修改和退订。不能把缺失的 Miniflux streamId 静默替换成 `feed/<url>` 当作已创建订阅身份。

## 7. Miniflux 同步策略

### 7.1 不把 `ot` 当成可靠的修改游标

Miniflux 当前 `stream/items/ids` 的 `ot` 按文章发布时间过滤，而不是 PaperRss 本地同步时间，也不是通用的服务端修改序列。仅使用“上次刷新时间减五分钟”会漏掉后来入库但发布时间较旧的文章。[S12]

首版建议采用 **完整 ID 枚举 + 差集正文下载** 作为正确性优先基线，不对 Miniflux 复用 FreshRSS 的时间窗口增量逻辑。它是轻量身份全量核对，不是每次重新下载全库正文。库特别大时仍有 O(远端条目数) 的 ID 枚举成本，应测量后再优化，不预设虚假的性能提升比例。

本地 `lastArticleFetchAt` 可以保留为运行记录，但不得赋予 Miniflux 服务端增量游标语义。优化路线可在后续评估 Miniflux 原生 API 的更新过滤能力，不在首版混合协议。

### 7.2 刷新流程

```text
进入当前账号同步会话
  → 推送可重试的 outbox
  → 拉取订阅与分类，并校验完整响应
  → 拉取全量未读 ID 与星标 ID
  → 枚举 reading-list ID
  → 优先处理最近文章、未读和星标
  → 本地身份 / 内容策略差集计算
  → 分批拉取正文并独立事务落库
  → 对本地状态做字段级调和
  → 再次推进 outbox
  → 提交本轮完成状态与进度
```

建议 ID 页大小从 1000 开始配置，正文批次沿用当前 50 篇，二者都应可测试和调整；这不是性能保证值。Miniflux 的单页 ID 上限为 10000。[S4、S12]

初次同步先让最近 200 篇及未读、星标内容可阅读，再在同一个可取消的应用同步任务中分批补齐服务端保留的其余历史。这是建议的 Miniflux 初始化策略，不修改 FreshRSS 原来的首屏策略。大账号的首次历史下载量会更高，应显示真实阶段与进度。

若产品决定保留“仅最近文章”模式，应另定义历史发现基线或保留策略，不能在下一次全量 ID 差集时又无意下载全部历史。不要以一个临时的 maxTotal 截断冒充完整同步。

正文下载目标应由本地身份和缓存保留策略共同决定：新身份、确需修复的失败内容、未读/星标的必要内容。刻意按保留策略移除的正文不能每次刷新都被重新下载。已有文章正文的全库修改追踪不是这条 ID 差集策略天然具备的能力；首期重点是新条目与阅读状态，全文强制重拉属于明确的修复动作。

### 7.3 失败与恢复

每批正文独立落库，失败不回滚已成功批次，也不清空本地阅读库。下次重新枚举 IDs，以本地差集恢复，而不是长期保存 Miniflux 的 offset continuation 跨会话续传。

需要区分：分页已耗尽、本轮正文获取完成、初次完整同步完成。达到上限、取消、解码失败或正文请求失败，均不得写入“本轮全部完成”。首屏可读不等于初次完整同步结束。

正文响应缺少部分请求 ID 时，不伪造内容，也不立即删除本地缓存；重新核对本轮身份集合，区分同步过程中远端删除与实际传输缺失。未完成目标保留到下轮重试，确已不在远端的目标从本轮待处理集合中排除。

### 7.4 分页并发与状态完整性

Miniflux 的 continuation 是数字 offset，不是不可变快照游标。即使跟完分页，在远端集合变化时也可能出现重复或遗漏。[S12]

要求：对 ID 去重、检测 continuation 循环、不把失败页当空页、账号内避免重叠刷新。分页耗尽只是网络遍历完成，不宣称获得强一致快照。

对于“本地原来未读/星标、这次集合里没有”的负向变化，先确认集合确实完整；在多页且可能并发变化时，通过指定 ID 正文中的 categories 再确认候选变化。确认失败时保留旧状态，下轮重试，不能因为一次集合缺失就批量取消星标。读取回来的正文 categories 也不能覆盖当前仍有 pending 的本地字段。

## 8. 状态队列与多账号隔离

必须同时修改 ArticleStateRepository 的 `markRead`、`markStarred` 和 `markAllRead`，从 FreshRSS 特判转为明确的同步能力判断。[S3]

保持现有不变量：

```text
同一数据库事务：更新本地状态 + upsert outbox
同一 accountID / itemID / stateKey：只保留最新 desiredValue
每次用户修改：递增 revision
成功确认：只删除与本次发送 revision 相同的 outbox
远端拉取落库时：重新读取当前 pending，逐字段保护
```

发送的是“希望已读/星标为真或假”，不是“切换一次”。不能用不可安全重试的 toggle 替代。只要队列尚未确认，相应本地字段不被旧远端状态覆盖。

保留用户停用账户期间的队列；重新启用后继续发送。账号未知类型不自动入队，不要把坏数据默认当远端服务。认证失效应暂停发送并提示重新验证，保留队列和本地阅读能力。

本期“全部已读”沿用对本地当前列表命中文章的逐项状态变更。不要悄悄替换成服务器 `mark-all-as-read`，否则可能标记尚未下载、当前界面没显示的历史文章，改变产品语义。需要“全服务端标已读”时另设明确动作和确认说明。

## 9. 分类与订阅管理

### 9.1 完整读取分类

Miniflux 通过 `tag/list` 读取分类集合，并结合订阅 categories 构建 feed-folder 关系。过滤内建 starred 等状态标签，只把真正 label 视为分类；接受 `user/-/label/...` 和服务端实际用户编号形式，不写死为 `user/-`。[S12]

整个分类响应和订阅响应校验成功后，才允许将缺失对象判为远端删除。这样才能保留服务端真实存在的空分类，避免请求失败触发本地清空。

Miniflux 的分类规则与通用多标签模型并不等同。为 Miniflux 写入订阅所属分类时遵循单分类能力，不让通用 UI 产生服务器无法表达的多个分类状态。

### 9.2 删除分类不能级联退订

当前 FreshRSS Provider 会遍历分类内订阅并退订；Miniflux 的 disable-tag 会移除分类并把订阅重新归入剩余分类，且至少需要保留一个分类。[S5、S12]

Miniflux 分支应只调用 disable-tag，成功后重新拉取分类与订阅，再更新本地映射。任何远端失败都不能被 `try?` 吞掉后假装成功。删除最后一个分类时，UI 可预先提醒，最终以服务端结果为准。

将“删除分类并保留订阅”和“退订整个分类内全部订阅”分成不同意图，不用同一个破坏性实现替代。首版不改变 FreshRSS 已有产品语义，但共享代码不能让 FreshRSS 的破坏性流程泄漏到 Miniflux。

### 9.3 创建分类与添加订阅

首版不伪造独立创建空分类能力；AccountProvider 的方法可以保留，但由 capability 禁用 UI，调用时返回明确 unsupportedOperation。不要返回只写本地的 FolderRecord 并宣称远端已创建。

添加订阅：quickadd → 检查 numResults 与 streamId → 必要的既有分类配置 → 重新读取服务端订阅元数据 → 落库。`numResults == 0` 是未找到订阅，不是成功。出现创建成功但后续分类编辑失败时，应报告部分结果并重新拉取，不自动再次创建同一个订阅。[S12]

## 10. 账号生命周期与界面

### 10.1 添加账号

表单包含服务预设、服务器根地址、Google Reader 用户名、Google Reader 密码与显示名称。Miniflux 的提示明确指向“设置 → 集成”，避免用户填写原生 API Key。

建议流程：

```text
校验输入与端点
  → 使用临时内存凭据执行登录及必要只读请求
  → 生成 accountID 并保存 Keychain
  → 同事务重复检查及数据库保存
  → 注册 Provider
  → 启动初次同步
```

Keychain 和 SQLite 不存在跨存储原子事务。数据库保存失败时清理本次新建的凭据；清理失败记录脱敏的可恢复错误。不得覆盖重复账号已有凭据。不要先注册临时账号让 UI 或后台刷新看到半成品。

### 10.2 启用、停用、更新凭据、移除

AppStore 调用通用账号生命周期方法，ProviderFactory 管理实例构造。更新凭据沿用 accountID，清理旧内存 token，不清空队列。

停用账号要阻止新的网络工作，并保存待同步状态。移除账号前取消并收束在途同步，使用账号会话代次检查，避免旧响应迟到后再次落库；随后移除本地账号数据、注册项和对应 Keychain。移除 PaperRss 账号不等于退订 Miniflux 服务端所有源。若存在未同步修改，删除确认中明确会丢弃这些本地待同步修改。

Swift actor 在 await 期间仍可能重入；不能仅凭“用了 actor”认定刷新、推送和账号删除已经互斥。检查 SyncCoordinator、Provider、outbox processor 的组合调度。

### 10.3 界面审计

替换 SettingsView、RootView 中用 FreshRSS 类型筛选所有远端账户的逻辑。账号行展示服务名与同步状态；侧栏、添加订阅目标、分类操作、来源徽标和错误说明采用账号配置或能力，不再散落品牌判断。

通用“Google Reader 兼容服务”入口后续可复用同一表单，其兼容状态单独标注。未知实现的能力默认保守，不以 HTTP 200 自动开通写操作。

## 11. 文件级实施清单

以下“新增”文件是建议组织方式，实施时可以在不扩大公共接口的前提下合并。

| 位置 | 操作 |
| --- | --- |
| `PaperRss/Sources/Core/Account/Account.swift` | 增加 Miniflux 类型、派生 backend 与状态同步能力 |
| `PaperRss/Sources/Core/Account/AccountProviderFactory.swift`（新增） | 集中创建服务 Provider 与凭据作用域 |
| `PaperRss/Sources/Core/Account/CredentialStore.swift` | 中性凭据接口及旧 service 兼容 |
| `PaperRss/Sources/Core/Account/SyncCoordinator.swift` | 检查启停、取消、移除、并发保护 |
| `PaperRss/Sources/Core/Persistence/DatabaseMigrations.swift` | 新迁移扩展 CHECK，保留旧数据 |
| `PaperRss/Sources/Core/Persistence/Repositories/AccountRepository.swift` | 通用有效端点去重 |
| `PaperRss/Sources/Core/Persistence/Repositories/ArticleStateRepository.swift` | 三条状态入口的能力判断 |
| `PaperRss/Sources/Core/ReaderAPI/ReaderServiceProfile.swift`（新增） | 服务差异、能力、策略选择 |
| `PaperRss/Sources/Core/ReaderAPI/ReaderEndpointResolver.swift`（新增） | 端点统一解析 |
| `PaperRss/Sources/Core/ReaderAPI/ReaderAccountProvider.swift`（新增/提取） | 共享 Provider 骨架 |
| `PaperRss/Sources/Core/ReaderAPI/ReaderSyncStrategy.swift`（新增） | FreshRSS 与 Miniflux 的文章发现策略 |
| 当前 `Core/FreshRSS/ReaderAPIClient.swift`、Authenticator、Models、Codec | 逐步中性化；补齐 POST T、响应校验及重试 |
| 当前 `Core/FreshRSS/ArticleStateOutboxProcessor.swift` | 复用；验证 Miniflux 请求及 revision 语义 |
| 当前 `Core/FreshRSS/FreshRSSAccountProvider.swift` | 提取公共部分，保留旧调用兼容 |
| `PaperRss/Sources/Core/AppStore.swift` | 账号工厂及通用生命周期入口 |
| `PaperRss/Sources/App/SettingsView.swift` | Miniflux 表单、账号列表、认证提示 |
| `PaperRss/Sources/App/RootView.swift`、`Core/Models.swift` | 侧栏筛选、来源标记、操作能力 |
| `Tests/FreshRSSIntegrationTests.swift` | 保留并补强旧行为回归 |
| `Tests/MinifluxCompatibilityTests.swift`（新增） | Miniflux 请求/响应 fixture 与同步用例 |
| `Tests/ReaderAccountMigrationTests.swift`（新增） | 旧数据库、凭据、账号隔离迁移测试 |
| `documents/technical/` 与用户接入文档 | 记录支持范围、账号设置、分类与同步限制 |

移动目录时同步核对 Swift Package 与 Xcode target 的源文件归属，避免 Swift Package 测试通过但 App target 缺少新文件。首个重构 PR 可以暂不搬目录，先保证行为一致，减少无关 diff。

## 12. 推荐 PR 拆分

| PR | 内容 | 合并门槛 |
| --- | --- | --- |
| 1：基线与共享协议骨架 | 冻结 PaperRss 基线与服务端版本；添加 FreshRSS characterization tests；提取 endpoint/profile/共享骨架 | 现有 FreshRSS 行为不变；不暴露半成品 Miniflux 入口 |
| 2：账号、迁移与凭据 | AccountType、CHECK 迁移、工厂、去重、Keychain、outbox 能力判断 | 旧数据库完整保留；本地不入队，两个远端服务正确入队 |
| 3：Miniflux 同步 | POST T、IDs + contents、分页、ID 编码、空分类、状态调和 | Mock 测试及锁定版本的真实测试实例通过 |
| 4：界面与管理动作 | 表单、重启恢复、启停/移除、添加/退订、分类删除语义 | 登录到双向同步的端到端链路通过 |
| 5：发布验收与文档 | 多账号、失败注入、大库、FreshRSS 回归、接入文档 | 无阻断缺陷，明确支持版本与已知边界 |

版本与任务应依据测试结果安排，不按未经联调的“改一个地址即可”估算。上线开关只关闭新增入口时，已有 Miniflux 账号仍需可读取和正确处理，不应被当成未知数据删除。

## 13. 验收矩阵

| 类别 | 关键用例与断言 |
| --- | --- |
| 地址 | 根路径、子路径、尾斜杠、FreshRSS PHP 完整路径；不产生重复前缀 |
| 认证 | 正确/错误/未启用集成；特殊字符密码；401 重登录后请求体 T 更新 |
| 协议形状 | 未知接口 `200 + []` 不算成功；合法空订阅对象不算错误 |
| 内容 | 不依赖 GET stream/contents；POST contents 的 T / i / output 正确 |
| ID | 十进制和完整/短 Tag URI 对齐；不同账号相同 ID 不冲突 |
| 大规模分页 | 超过 10000 条、循环 continuation、重复 ID、失败页和远端并发变化 |
| 老文章新入库 | 发布时间很旧、刚被服务端收录的普通已读文章可被发现 |
| 首次同步 | 最近内容先可读；历史分批；取消重试不重复落库、不伪报完成 |
| 状态回写 | 单篇已读、未读、星标、取消星标，以及全部已读全部覆盖 |
| 离线与重启 | 离线多次修改只保留最新目标；重启后队列继续发送 |
| revision | 发出旧请求期间产生新修改，旧成功响应不得删除新队列项 |
| 调和竞态 | 拉取期间产生本地 pending，远端状态不得覆盖对应字段 |
| 分类 | 空分类保留；真实 user ID 标签可识别；最后分类删除失败不改本地 |
| 删除分类 | 不调用 unsubscribe；订阅保留，刷新后处于服务端决定的分类 |
| 创建订阅 | numResults=0 不成功；分类编辑失败不重复创建订阅 |
| 多账号 | Local + FreshRSS A/B + Miniflux A/B；状态和 token 不串号 |
| 生命周期 | 停用不发网络请求；删除后旧响应不能恢复账号数据 |
| 迁移 | 全新库、现有库、待发送队列；父子表数量与身份不变，外键检查通过 |
| 凭据 | 旧 FreshRSS 无需重输密码；Miniflux 凭据不进入 SQLite 或日志 |
| UI 与构建 | 设置与侧栏可见、能力门控正确；Swift Package 和 App target 均验证 |

测试分三层：URLSession/协议 fixture、真实 SQLite/Repository 集成、锁定 Miniflux 发布版本的真实实例端到端。真实环境至少验证“PaperRss 修改 → Miniflux 网页可见”和“Miniflux 网页修改 → PaperRss 刷新可见”，并保留一个 FreshRSS 实例作为回归对照。

不能仅以 Mock 返回预期 JSON 或登录成功宣布完成。

## 14. 风险与回退

最主要的风险不是增加账号表单，而是父表迁移、FreshRSS 专用语义泄漏、Miniflux POST 认证、未实现接口伪成功、分页状态不完整和账号状态队列漏入。

发布前保存可恢复数据库备份，迁移失败回滚。旧版本二进制是否能读取新增类型需要单独验证，不承诺任意降级兼容；回退优先发布保留新模型兼容能力的修复版本，或使用明确的备份恢复路径。不要通过把 Miniflux 账号 type 改成 freshRSS 来伪装兼容。

没有必要现在重构全部服务端同步，也不应保留明显会导致 Miniflux 误退订或状态不同步的旧分支。应以兼容测试保护 FreshRSS，以小范围策略分离完成 Miniflux 接入。

## 15. 完成标准

**同一套 PaperRss 账号与本地数据库体系中，Miniflux 可以稳定登录、恢复、拉取订阅和文章、双向同步阅读状态，离线修改可恢复，分类操作不会误退订；现有 FreshRSS 账号、凭据、状态队列和阅读体验不回退。**

这才是“支持 Miniflux”，不是出现一个可填写服务器地址的表单。

---

## 证据索引

PaperRss 链接均固定到本方案代码基线；Miniflux 官方实现链接为核对日的 main，实施时必须替换/补充锁定版本链接与测试记录。

- **S1** 账号模型与 Provider 接口：[Account.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/Account/Account.swift)
- **S2** 数据库约束与迁移：[DatabaseMigrations.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/Persistence/DatabaseMigrations.swift)
- **S3** 状态与 outbox 三条入口：[ArticleStateRepository.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/Persistence/Repositories/ArticleStateRepository.swift)
- **S4** 地址、正文、分页和状态请求：[ReaderAPIClient.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/FreshRSS/ReaderAPIClient.swift)
- **S5** 现有同步和分类操作：[FreshRSSAccountProvider.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/FreshRSS/FreshRSSAccountProvider.swift)
- **S6** 账号去重：[AccountRepository.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/Persistence/Repositories/AccountRepository.swift)
- **S7** 多账号调度：[SyncCoordinator.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/Account/SyncCoordinator.swift)
- **S8** 凭据接口与 Keychain：[CredentialStore.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/Account/CredentialStore.swift)
- **S9** 账号恢复与管理：[AppStore.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/Core/AppStore.swift)
- **S10** 设置与侧栏：[SettingsView.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/App/SettingsView.swift)、[RootView.swift](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/PaperRss/Sources/App/RootView.swift)
- **S11** 已接受的架构原则：[架构规范](https://github.com/ohmyangboy/PaperRss/blob/9c04916de3b92d60bf8aa3a7f687bb64127a2445/documents/technical/paperrss-data-account-architecture-v1.md)
- **S12** Miniflux 协议说明：[官方实现 README](https://github.com/miniflux/v2/blob/main/internal/googlereader/README.md)
- **S13** Miniflux 实际路由：[handler.go](https://github.com/miniflux/v2/blob/main/internal/googlereader/handler.go)
- **S14** Miniflux 接入与原生 API：[Google Reader 文档](https://miniflux.app/docs/google_reader.html)、[原生 API 文档](https://miniflux.app/docs/api.html)
- **S15** SQLite 表结构重建：[官方 ALTER TABLE 文档，第 8 节](https://www.sqlite.org/lang_altertable.html)
