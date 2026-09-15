# Miniflux 账号接入说明

> 状态：已实现（Google Reader 兼容 API 路线）
> 适用版本：PaperRss 支持 `AccountType.miniflux` 及以上
> 相关设计：[PaperRss-Miniflux-Account-Extension-RFC](../research/PaperRss-Miniflux-Account-Extension-RFC.md)

## 支持范围

| 能力 | 状态 |
| --- | --- |
| 添加、启用、停用、移除 Miniflux 账号 | 支持；与本地、FreshRSS 账号并存 |
| 订阅与分类拉取（含服务端空分类） | 支持 |
| 文章同步（全量 ID 枚举 + 差集正文下载） | 支持 |
| 已读 / 未读、星标双向同步（离线队列 + 重试） | 支持 |
| 添加订阅、退订订阅 | 支持；使用服务端返回的 `feed/<id>` 身份 |
| 删除分类 | 支持 Miniflux 语义：保留订阅、重新归类，不退订 |
| 单独创建空分类 | 不支持（Miniflux API 无法表达）；界面禁用并给出说明 |
| Miniflux 原生 REST API（`/v1/` + API Key） | 不在本期范围 |
| 服务端强制抓取、规则管理、用户管理 | 不在本期范围 |

## 用户接入步骤

1. 在 Miniflux 中打开 **设置 → 集成 → Google Reader**，启用并设置一组用户名与密码。
2. 在 PaperRss 中打开 **设置 → 账号 → 添加账号 → Miniflux**。
3. 填写：
   - **服务器地址**：Miniflux 部署根地址（如 `https://rss.example.com`），可带子路径，不需要也不应包含 `/reader/api/0`；
   - **用户名 / 密码**：第 1 步中 Google Reader 集成凭据，不是 Miniflux 原生 API Key，也不是网页登录密码。
4. 点击「测试连接并添加账号」，PaperRss 通过 `POST /accounts/ClientLogin` 校验凭据并启动首次同步。

## 实现要点

- 协议实现复用 Google Reader API 栈（`ReaderAPIClient` / `ReaderAPIAuthenticator`），服务差异由 `ReaderServiceVariant` 预设表达：
  - FreshRSS：协议根地址为 `<base>/api/greader.php`；
  - Miniflux：协议根地址为部署根地址，保留子路径。
- Miniflux 不实现 `GET /reader/api/0/stream/contents/...`，因此文章发现采用 **全量 `stream/items/ids` 枚举 + 本地正文差集 + 分批 `POST stream/items/contents`**；不使用 `ot` 作为增量游标（它按发布时间过滤，会漏掉后入库的旧文章）。
- Miniflux 要求所有 POST 携带表单 `T`（包括读取正文的 `stream/items/contents`），401/403 重试时会同时刷新 Auth Token 与 Write Token 并重建请求体。
- 分类来源为 `tag/list`（保留空分类）与 `subscriptions[].categories` 的并集；兼容 `user/-/label/...` 与 `user/<id>/label/...` 两种标签形式。
- 文章状态写回沿用 `article_state_outbox`：同事务更新本地状态 + upsert 队列，revision 保护、指数退避与账号隔离规则与 FreshRSS 一致。
- 凭据存于独立 Keychain 命名空间 `com.paperrss.miniflux.googlereader`；FreshRSS 旧命名空间保持不变。

## 已知边界

- 首次同步会拉取服务端当前保留的全部历史文章（新→旧分批），大账号耗时会明显高于 FreshRSS 的「最近 200 篇」首屏策略；同步进度按真实批次展示，可取消并续传。
- Miniflux continuation 是 offset 而非不可变快照游标；同步过程中远端集合变化时，下一轮全量枚举会自动补齐。
- 同一 Miniflux 实例与用户名只能添加一个账号（按规范化端点 + 用户名去重）。
- 不支持多分类：Miniflux 每个订阅只属于一个分类。

## 验证基线

- `Tests/MinifluxCompatibilityTests.swift`：以 Miniflux 行为对齐的 Mock 覆盖登录、`T` 校验、long-form ID、offset 分页、空分类、`disable-tag` 不退订、添加订阅使用真实 `feed/<id>`、重复账号拒绝。
- `Tests/ReaderAccountMigrationTests.swift`：验证 accounts 表 `CHECK` 约束迁移保留旧数据、允许 `miniflux`、拒绝未知类型且外键完整。
- 真实 Miniflux 实例端到端验收需锁定具体发布版本，并同时保留 FreshRSS 回归对照。
