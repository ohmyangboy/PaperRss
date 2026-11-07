# 指定账号导入与跨账号添加订阅

## 行为

- 「导入 OPML」先展示目标账号与文件选择，再由用户明确启动导入。默认选择当前启用账号，可改选本地、iCloud、FreshRSS 或 Miniflux。
- 本地 / iCloud 沿用事务导入，保留 OPML 文件夹（含空文件夹、多分类）。服务器账号逐条调用原有订阅 API；同 URL 只取文件中首次出现的分类，空文件夹不导入，限制在面板中明确显示。
- 导入结果显示已添加、已存在和失败数量，列出失败的订阅标题；可重试，已成功添加的 URL 自动跳过。
- 单个或多选 Feed 可拖到其他账号行或该账号的文件夹行。跨账号只添加订阅副本，不迁移来源历史、已读或收藏状态；目标账号已有该 URL 时保持原订阅不变。
- 本地 / iCloud 同账号内仍移动分类，身份与文章保持不变。FreshRSS / Miniflux 同账号分类重组不在本次范围；混合跨账号选择中的已有目标订阅会跳过。
- 禁用、归档、已删除账号或无效 Feed ID 不会回退写入本地账号；同一目标账号的重复并发导入被阻止。

## 设计依据与验证边界

账号和文件夹作为侧边栏拖拽目标，参考 [NetNewsWire 的跨账号侧边栏拖拽](https://netnewswire.blog/2019/05/31/netnewswire-a.html)。本次按需求中的「添加」采用复制订阅语义，来源资料保留；不声称与 NetNewsWire 的所有移动规则一致。

新增面板沿用原生 SwiftUI Sheet、Picker、File Importer、进度和结果反馈；账号行显示拖入高亮及导入进度，文件夹复用现有高亮。无需数据库迁移或新增依赖。

`SubscriptionManagementTests` 使用隔离 SQLite、iCloud 同步替身和服务器替身覆盖指定账号、跨账号双向复制、同账号分类移动、去重、软删除后重新订阅、来源阅读/收藏保留、无效账号及服务器部分失败重试。真实文件选择、鼠标拖放、真实 FreshRSS / Miniflux 服务及跨设备 iCloud 仍需人工验收。

MCP 用法和失败回执见 [批量订阅管理](agent-mcp-local-mvp.md#批量订阅管理2026-11-07)。

## 本轮验证（2026-11-07）

环境：macOS 27.0.1，Xcode 27.2（27B52）。

- `./scripts/verify.sh --build`：macOS 宿主构建成功；未启动真实用户库。
- `./scripts/verify.sh --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests|AgentApprovalCenterTests|OPMLStructureTests|SubscriptionManagementTests|AppFeatureRegressionTests'`：124 项中 123 通过、1 个测试夹具失败。夹具误将 FreshRSS 构造为归档账号，违反已有数据库约束。
- 将上述夹具改为合法的 iCloud 暂停/归档状态后，`./scripts/verify.sh --filter 'SubscriptionManagementTests'`：6 通过、0 失败、0 跳过。生产源码未因夹具修正改变，其他已通过证据继续有效。
- `./scripts/verify.sh --filter 'LocalAccountProviderTests|ICloudAccountProviderTests'`：24 通过、0 失败、0 跳过。
- 合并证据共 148 个不同用例通过；过滤器下未匹配的其他测试 target 不计入通过数。`git diff --check` 通过。

初次编译暴露的 Swift 主线程隔离、FileDocument 访问范围和测试私有方法访问问题均已修正。完整原始日志（包括失败轮次）及候选 App 保存在主工作区 `build/qa/feed-account-management/`。鼠标拖放、系统文件选择面板、真实服务器及 iCloud 跨设备同步未验收；未安装、发布或推送。
