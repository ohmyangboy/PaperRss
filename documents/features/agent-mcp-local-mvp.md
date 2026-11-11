# 本地 Agent / MCP：UDS MVP 验收

2026-10-27；在 `codex/agent-mcp-spike` / `8c78350` 上继续实现。研究依据：只读参考 `documents/research/paperrss-agent-integration-cli-mcp.md` §10–§12，该未跟踪副本不提交。

**helper 不带 `--fixture` 时已接入 App 的 Unix domain socket；App 使用自己已打开的 LibraryDatabase 提供查询。** 默认关闭。自动化使用隔离库和真实 socket，不等同于日常库、GUI 客户端或签名安装包验收。当前支持所有已启用的 local、iCloud、FreshRSS、Miniflux 账户的库内元数据读取，以及 App 内定位；正文仍需显式选择授权。

## 数据与安全边界

- helper 仅依赖 `PaperRssAgentProtocol`、`PaperRssAgentMCP`；不链接 PaperRssCore、SQLite、CloudKit，不持有 RSS 凭据或 AI Key。App → LibraryDatabase 是唯一数据所有者。
- 默认目录为 `/tmp/paperrss-agent-$(id -u)`（macOS `/tmp` 指向 `/private/tmp`），socket 为该目录的 `bridge.sock`。目录 0700，socket、`token`、`owner`、`state` 文件 0600；检查当前 UID、文件类型、权限，拒绝符号链接凭据与不安全目录。双端检查 Unix peer UID。
- 开启后 App 生成随机 token；helper 从同目录读取，token 不进 argv、MCP 配置或日志。握手包含协议版本，App 返回实例 ID。每次重新开启轮换 token；不支持匿名读取。
- 这是**当前 macOS 用户范围的信任**，并非代码签名绑定或逐客户端人工配对。同用户能读取 token 的进程也能连接；`--client` 只是标签，不是身份。每个已认证连接独立授权、预算、游标；断开撤销。不要把任意同用户进程视为已隔离的安全主体。
- App 初始化库成功后取得 `owner` 排他锁。OFF 保留 owner 锁和 disabled 状态，移除数据 listener/token，并撤销已有会话；进程退出释放锁。helper 据此区分 `NOT_ENABLED` 与 `APP_NOT_RUNNING`。崩溃留下的 socket 只有在持有 owner 锁且确认无活跃 listener 后才清理；拒绝覆盖活跃实例。OFF 只留下状态文件，不提供库查询端口。
- UDS 采用长度前缀 JSON；请求上限 64 KiB、响应上限 1 MiB，有限连接数、15 秒阻塞读写超时；认证后空闲等待不主动断开，阻塞 I/O 在后台队列。stdio stdout 只输出 JSON-RPC。无 TCP/HTTP 端口、launchd、云连接、自动打开 App 或全库导出。
- 元数据允许所有已启用账户 unread/starred/selection；正文最多选 20 篇，每篇最多 20,000 字符，默认 8,000，selection 有效 15 分钟。每会话共享默认 100,000 字符预算及每分钟 60 个业务调用。正文仅用已存内容，不抓网页、不写缓存、不隐式标已读。文章文本全部视为不可信输入。
- 真实 App 通过 `state.write.approval` 开放人工批准后的状态写入（见 Batch 2）；Feed 管理使用同一人工审批链路（见 Batch 3）。未更改保留或清理策略。

## 构建与启用

在 macOS App 中打开 **设置 → AI → MCP → 连接外部助手**，即可开启或关闭现有 MCP listener；默认关闭。「一键安装」按 Codex CLI、Claude Code、DeepSeek dsh、Cursor、VS Code、VS Code Insiders 排序（Insiders 仍仅在已安装时出现）；其他助手可通过「复制配置」获取通用配置与提示词。关闭开关时两个区域置灰且不可操作。原生 App 将签名的 helper 内嵌在 `PaperRss.app/Contents/MacOS/paperrss-agent`。移动 App 后需重新复制配置；Release 缺少 helper 时提示重新安装，Debug 则可使用开发构建路径并提示构建。

以下均在本 worktree 执行。构建本身不启动 App：

```sh
cd /Users/yangbukun/.codex/worktrees/b9dd/PaperRss
swift build --product paperrss-agent
./scripts/dev.sh --build-only
```

原生 App：`build/Build/Products/Debug/PaperRss.app`。如果本机 Xcode 签名/构建环境受限，可用 `swift build --product PaperRssDesktop`，然后使用 `.build/debug/PaperRssDesktop` 做 Debug QA；这不证明原生 bundle 签名/分发成功。

启动真实库实例前正常退出旧 PaperRss，并按 [开发数据备份](../../.agents/docs/dev-data-backup.md) 保存一致快照。不要同时启动第二个使用同一库的 App。App 正常初始化本身可能执行原有迁移、同步和刷新，因此不能把“Agent 查询只读”理解成整个 App 启动只读。

本次进程启用（推荐 QA，不保存全局偏好）：

```sh
./build/Build/Products/Debug/PaperRss.app/Contents/MacOS/PaperRss \
  -PaperRss.agentMCPEnabled YES
# SwiftPM 备选：
# .build/debug/PaperRssDesktop -PaperRss.agentMCPEnabled YES
```

持久偏好方式（原生 bundle ID）：

```sh
defaults write com.yangbukun.PaperRss PaperRss.agentMCPEnabled -bool YES
```

退出再启动本次构建产物。关闭时可直接关闭设置开关；也可退出后以 `-PaperRss.agentMCPEnabled NO` 启动，或 `defaults write ... -bool NO` 后重启。启动参数优先于持久 defaults；外部 `defaults write` 的跨进程实时通知不作为本轮保证。App 内同一 defaults 对象变更会驱动 listener 关闭，每次业务调用也再次检查开关。

**helper 还有独立进程开关** `PAPERRSS_AGENT_ENABLED=1`，两个开关都必需。helper 不会自动打开 App。`PAPERRSS_AGENT_SOCKET_DIR` 仅供隔离 socket 冒烟测试覆盖 helper 目录；日常 QA 不设置，App 使用固定默认目录。

## 客户端配置（真实 App，无 --fixture）

将 command 换成本 worktree 编译产物的绝对路径。Claude Desktop 开发者配置 `claude_desktop_config.json` / Cursor `mcp.json` 示例：

```json
{
  "mcpServers": {
    "paperrss-local": {
      "command": "/Applications/PaperRss.app/Contents/MacOS/paperrss-agent",
      "args": ["serve", "--stdio", "--client", "oliver-qa"],
      "env": {"PAPERRSS_AGENT_ENABLED": "1"}
    }
  }
}
```

Codex 本地 `config.toml` 示例：

```toml
[mcp_servers.paperrss_local]
command = "/Applications/PaperRss.app/Contents/MacOS/paperrss-agent"
args = ["serve", "--stdio", "--client", "oliver-qa"]

[mcp_servers.paperrss_local.env]
PAPERRSS_AGENT_ENABLED = "1"
```

保存后重新连接对应 MCP server。这里没有修改任何全局客户端配置，也没有验收三个客户端 GUI。stdio 支持 initialize、ping、tools/list、tools/call、cancelled 通知；工具数 13，失败包含 `isError: true` 与结构化错误码。协议版本覆盖 2025-11-25、2025-06-18、2024-11-05；不是完整 MCP conformance 声明。

## Debug 正文授权路径

正式确认 UI 尚未接入。本轮提供**App 侧、仅 Debug、显式篇目、一次启动一次**的 QA consent。**不能热授权**：必须先 metadata 拿真实 `article_id` → 退出 App → 带 QA argv 重启 → 同一 MCP 连接再用 `selection_ids[0]` 调 `get_content`（详见下方「验收说明」置顶）。等 App **窗体就绪**再连 helper。

1. 先用 metadata 工具取得真实文章 ID，人工检查并选 1–20 篇。正文可能被客户端送到它配置的模型服务；仅选择同意外发的篇目。
2. 断开所有测试 MCP 客户端，正常退出 App，再在终端启动 App，指定所选 ID：

```sh
./build/Build/Products/Debug/PaperRss.app/Contents/MacOS/PaperRss \
  -PaperRss.agentMCPEnabled YES \
  --agent-qa-allow-content-egress \
  --agent-qa-content-ids 'ARTICLE_ID_1,ARTICLE_ID_2'
```

SwiftPM 备选将可执行文件替换为 `.build/debug/PaperRssDesktop`。不能把这些 App 参数放到 helper args。

3. 启动后 15 分钟内只连接预期的一个 MCP helper，首先调用 `paperrss_status {}`。App 将固定篇目授予第一个发起业务调用的连接；读取返回的 `selection_ids[0]`。该 selection 自签发起有效 15 分钟，不自动续期。
4. 使用同一个 MCP 连接调用 `paperrss_get_content`，传入 account_id、article_id、selection_id。selection 不跨连接共享；只读列表不会标已读。未指定双重 QA 参数、Release 构建、任意伪造 selection 均不会获得正文授权。
5. 关闭 App 开关、断开该 helper 或退出 App 都会撤销授权；重新连接不会自动领取第二份 QA grant。要重新授权须重新人工启动 App。验证完退出并去掉上述 QA 参数，勿保存为日常启动配置。

这条路径没有 MCP 自批准工具。它是临时 QA 入口：首个连接领取意味着测试时必须控制同用户其他 helper；正式版本仍需要可见的逐客户端配对、篇目确认和撤销 UI。

## 验收说明（可直接发 Bro / Oliver）

**置顶（明早真库冒烟必读）**

1. **可执行文件**：本 worktree 若尚无原生 `PaperRss.app`，用 SwiftPM 产物 `.build/debug/PaperRssDesktop`。先编：`./scripts/dev.sh --build-only`，或 `swift build --product PaperRssDesktop` 与 `swift build --product paperrss-agent`。有 `build/Build/Products/Debug/PaperRss.app` 时优先用原生 bundle；两者均须本分支 Debug。
2. **开闸**：App `-PaperRss.agentMCPEnabled YES`（或 Desktop 等价）；helper 环境 `PAPERRSS_AGENT_ENABLED=1`；MCP args **不带 `--fixture`**。
3. **等窗体就绪再连 helper**：App 的 Agent attach / UDS listen 在库初始化后异步完成。窗体已出现、库可浏览后再连 MCP；过早连接可能短暂 `APP_NOT_RUNNING`，稍后再试即可。
4. **QA 两段式（不能热授权）**：
   - **第一段（仅 metadata）**：开闸启动 App（**不要**带 `--agent-qa-*`）→ 连 helper → `status` / `list_feeds` / `list_articles(unread)` / `get_article`，记下真实 `article_id`。
   - **退出**：断开所有 MCP，正常退出 App。
   - **第二段（正文）**：用同一批 ID 重启 App，加上 `--agent-qa-allow-content-egress --agent-qa-content-ids 'ID1,ID2'`（参数在 **App** argv，不是 helper）→ **等窗体就绪** → 再开**同一个** MCP 连接 → `paperrss_status` 取 `selection_ids[0]` → 同一连接 `get_content`。客户端不能自签 approval；不能在已运行进程上热加 QA 参数。

本轮已补上 helper → Unix socket → App-owned library。请用本分支 Debug App + helper。

**逐步核对**

1. `paperrss_status {}`：应返回 `enabled: true`、`paired: true`、`transport: "unix_socket"`，从 `accounts` 读取 `enabled: true` 的 account_id（本地通常是 `local-default`）。不能出现 `fixture: true`。
2. `paperrss_list_feeds {"account_id":"local-default","limit":20}`：返回 App 本地账户的真实订阅和计数。也可传入已启用的 iCloud/FreshRSS/Miniflux account_id；查询共享库，不发起网络请求。
3. `paperrss_list_articles {"account_id":"local-default","scope":"unread","limit":20}`：与 App 的本地未读文章核对。可加 feed_id、since、query；query 只搜索标题/摘要。再试 scope=starred。列表响应不含正文，不改变已读。
4. 从列表取真实 ID，`paperrss_get_article {"account_id":"local-default","article_id":"REAL_ID"}`：核对标题、状态和 content_available；无正文。超出 unread/starred/selection 范围的已读未星标文章应 UNAUTHORIZED。
5. 按置顶「QA 两段式」从 **App 终端参数**授权所选篇目，再从 status 取 `selection_ids[0]`，调用 `paperrss_get_content {"account_id":"local-default","article_id":"REAL_ID","selection_id":"STATUS_RETURNED_ID","max_chars":8000}`。应返回已存文本；检查原文章已读状态没变。没有已有正文时可能报内容不可用，不会隐式抓网页。
6. 同一连接伪造 selection 必须 UNAUTHORIZED；业务错误后有效 selection 仍可使用。另开 helper 不能复用该 selection。
7. helper 不设置启用环境变量 → NOT_ENABLED；App 运行但 flag OFF → NOT_ENABLED；App 退出/无 listener/崩溃残留 socket → APP_NOT_RUNNING。再次打开 App 后可重新连接；旧 selection 失效。过早连 helper 的短暂 `APP_NOT_RUNNING` 见置顶第 3 条。
8. 检查目录 0700、socket/token 0600（只查看权限，不把 token 内容贴群）。普通关闭 App 后应移除 socket/token；owner 文件可能保留但不再持锁。再次启动不得覆盖其它活跃实例。
9. Feed 写工具创建待批准计划（见 Batch 3）；状态写工具按下方 Batch 2 流程，未在 App 点击批准必须拒绝执行。

离线 smoke 仍支持：

```sh
PAPERRSS_AGENT_ENABLED=1 .build/debug/paperrss-agent serve --stdio --fixture --client offline-qa
```

fixture 是纯合成数据；不能用它代替上面真实库验收。验收反馈请包含构建提交、客户端版本、调用参数（不含 token/正文秘密）、结构化错误码。

## 自动化与当前交付证据

常规入口：

```sh
./scripts/verify.sh --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests|AgentIPCTests|AgentIPCIntegrationTests'
```

当前执行环境默认 Clang 缓存位于沙箱外，普通入口在 manifest 编译阶段失败；使用同一报告/锁入口，将缓存限制在本 worktree，并关闭 SwiftPM 内层 sandbox（外层权限仍有效）：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/build/agent-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/agent-module-cache" \
PAPERRSS_RUN_GUI_TESTS=0 PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS=0 \
python3 scripts/build-support.py --lane tests --temporary -- \
  swift test --disable-sandbox --scratch-path "$PWD/.build" --skip-update \
  --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests|AgentIPCTests|AgentIPCIntegrationTests'
```

本轮最终结果（2026-10-27 Asia/Shanghai）：

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| SwiftPM / verify 相关测试 | **48 通过 / 0 失败**（Core 17 + App bridge 1 + IPC integration 10 + AgentIPC 11 + MCP 9） | `build/reports/agent-ipc-unsandboxed-verify.log` |
| Codex sandbox 曾阻断 UDS bind | 当时 31 通过 / 17 失败（环境 EPERM，非逻辑回归） | `build/reports/run-93rrh250.log`、`agent-ipc-sandbox-probe.json` |
| 普通终端 UDS bind 探针 | `bind_ok=true` | 本机补跑记录 |
| helper 产品子进程 smoke | 含 without `--fixture` / disabled / missing App / fixture | IPC / product smoke 日志 |
| 本地 commit | `c32854d`（及文档证据修正 commit，见 git log）在 `codex/agent-mcp-spike`；**未 push** | `git log -1` |
| 研究副本 | 仍 untracked，未 stage | `documents/research/paperrss-agent-integration-cli-mcp.md` |

**结论：** helper ↔ App UDS IPC 在普通本机自动化已跑通（隔离库 + temp socket）。这仍**不等于**日常生产库 + Claude/Cursor/Codex GUI 三端已验收；请按上方「验收说明」人工走真实库。未 merge/push/PR/tag/release。

交接文件：`build/reports/agent-mcp-ipc-handoff.md`；审阅补丁：`build/reports/agent-mcp-ipc.patch`。

## 剩余缺口

- 逐客户端身份配对、正文确认 UI 和升级链路仍待完善；状态写入已有 App 审批 UI（Batch 2）；只验证当前用户 token 信任模型，不保证 Mac App Store sandbox 可用。
- 真实 App/Claude Desktop/Cursor/Codex GUI 三端尚需按上述步骤人工验收。自动化使用 App 相同 controller/service 和隔离 SQLite 库，不是生产阅读库验收。
- 元数据与人工批准的状态写入支持全部已启用账户；Feed 管理已接入 App 人工审批（见 Batch 3）。读取库内数据不代表跨设备/iCloud/远端同步已验收。
- 会话/selection/游标不持久化；断开或重启失效。预算为每连接，重新连接可获得新预算；正式版需要跨连接全局配额与可见授权管理。
- 分页是查询/会话绑定的短期 live-offset cursor，非冻结快照；并发增删可能重复或遗漏，每次最多扫描 500 候选。正文现有的会话限量不等于不可绕过的永久出库上限。
- URL 已过滤 userinfo/query/fragment，但无法识别所有 path 内秘密；正文授权仍需人工审查隐私和内容使用范围。本地传输不等于外部模型处理在本机。
- 未覆盖睡眠/恢复、升级重启竞争、故意慢速传输的完整压力测试，也未宣称正式生产安全验收完成。

## 普通终端补跑（2026-10-27 22:49 Asia/Shanghai）

Codex `workspace-write` 沙箱曾禁止 Unix socket `bind`（当时完整相关用例 31 通过 / 17 失败）。随后在**普通本机终端**（非 Codex sandbox）补跑：

- UDS bind 探针：`bind_ok=true`
- `./scripts/verify.sh --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests|AgentIPCTests|AgentIPCIntegrationTests'` → **exit 0**
- 日志：`build/reports/agent-ipc-unsandboxed-verify.log`
- 覆盖含真实 temp socket roundtrip、disabled/missing App、token/version 拒绝、stale reclaim、helper product without `--fixture`、App 隔离库正文授权路径等。

status DTO 已对齐：fixture / Core / App overlay 均提供 `paired` + `pair_state` + `transport`（fixture 另带 `fixture=true`；真实 UDS 连接 `transport=unix_socket`、`pair_state=local_user_token`）。

Bro 硬要求（UDS-only 非 fixture、enable gate listen/revoke、0700/0600+peer UID+token、QA-only 受信授权、status 字段统一、研究 `??` 不提交）已并入本轮实现。

## 常见客户端快速接入

设置 → AI → MCP 提供 Cursor 安装链接；VS Code 和 VS Code Insiders 使用各自的 MCP 安装链接。Codex CLI、Claude Code 与 DeepSeek dsh 复制终端命令（Codex CLI、ChatGPT 桌面应用与 Codex IDE 扩展共享配置）。Claude Desktop、Windsurf / Devin Desktop 和 Gemini CLI 等其他客户端通过「复制配置」取得通用配置与提示词，按各自要求合并配置并保留其他服务器。连接时需要开启「连接外部助手」并保持 PaperRss 运行。

格式参考：[Cursor](https://cursor.com/docs/context/mcp/install-links)、[VS Code](https://code.visualstudio.com/api/extension-guides/ai/mcp)、[Claude Code](https://code.claude.com/docs/en/mcp)、[Codex](https://developers.openai.com/codex/mcp)、[Claude Desktop / MCP](https://modelcontextprotocol.io/docs/develop/connect-local-servers)、[Devin Desktop](https://docs.devin.ai/desktop/cascade/mcp)、[Gemini CLI](https://geminicli.com/docs/tools/mcp-server/)。

### Icon sources & licensing

- Cursor：[官方品牌素材](https://cursor.com/brand)中的 Cursor App Icon 2D Light。
- VS Code：[官方品牌素材](https://code.visualstudio.com/brand)中的图标，Microsoft 商标；Insiders 未找到应用图标时使用此素材。
- Claude：[Anthropic 已验证的 Claude Code for VS Code 扩展](https://open-vsx.org/extension/Anthropic/claude-code) 2.1.312 中的 `claude-logo.png`，© Anthropic PBC。
- Codex：[OpenAI 已验证的 Codex 扩展](https://open-vsx.org/extension/openai/chatgpt) 26.51021.22027 中的 `blossom.dark.png`；OpenAI 商标，按 [OpenAI 品牌指引](https://openai.com/brand/)用于标识集成。

素材仅缩放，作为兼容性标识；带 bundle identifier 的目标优先通过 `NSWorkspace` 读取已安装应用的实际图标。


## Batch 1：dsh、丰富状态与 App 内定位（2026-10-28）

DeepSeek dsh 是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)，npm 包 `@deepseek-ai/dsh`，命令为 `dsh`。它没有 `mcp add` 命令；设置行复制一条 POSIX sh 命令，使用 `@deepseek-ai/dsh-mcp-client` loader 插件，将以下条目写入 `${DSH_HOME:-$HOME/.dsh}/cordis.patch.yml` 顶层 YAML 数组，作用于每个 profile：

```yaml
- insert:
    - id: mcp-paperrss
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: paperrss
        transport: stdio
        command: '/Applications/PaperRss.app/Contents/MacOS/paperrss-agent'
        args: [serve, --stdio, --client, dsh]
        env:
          PAPERRSS_AGENT_ENABLED: '1'
```

注意：dsh 的 patch 层（`cordis-plugin-include`）只能覆盖已有 id；直接写 `- id: mcp-paperrss` 会报 `patch: entry "mcp-paperrss" not found` 并被忽略，新条目必须包在顶层 `insert:` 中。已用 dsh 0.2.1-rc.2 在临时 `DSH_HOME` 下 `dsh web --dump-config` 验证该条目被加载。

命令创建父目录、仅在不存在 `id: mcp-paperrss` 行时追加；纯空白/注释或空流数组 `[]` 会替换为新数组，其他条目保留。helper 路径分别进行 YAML 单引号和 shell 单引号转义。重复运行不重复添加；已有同 ID 条目不会更新，移动 App 后需手动更新该条目的路径。设置仍只复制命令，由用户在终端执行。

依据：已安装 `@deepseek-ai/dsh` 的 README 及嵌套 `@deepseek-ai/dsh-mcp-client/README.md`。dsh 在重启或配置 HMR 时加载 patch；不支持 MCP prompts，工具名为 `mcp__paperrss__<tool>`。`AgentMCPDeepSeek` 图标来自该官方安装包内 `node_modules/@deepseek-ai/dsh-web-frontend/dist/favicon.svg`，仅用于标识集成。安装行使用 accessibility children contain，使行 ID 与内部 `settings.agentMCPInstall.<id>` 按钮 ID 均可访问。

`paperrss_status` 保留原有字段，并增加：

- `app: {version, build, debug}`：版本和构建号取 App 进程的 Bundle；SwiftPM 无 Bundle 元数据时为 `unknown`，绝不采用 helper 版本冒充。
- `accounts[]: {account_id, type, display_name, enabled, server_host, feed_count, unread_count, last_sync_at, capabilities}`：包含 App 已知的禁用账户；禁用账户 capabilities 为空。type 为 `local` / `iCloud` / `freshRSS` / `miniflux`。
- `server_host` 仅服务器账户返回 `host[:port]`，其他账户为 null；不返回 URL 的 userinfo、路径、查询或任何凭据字段。`last_sync_at` 为已知同步完成时间 ISO8601 或 null，本地账户可用最近 Feed 刷新时间。
- 顶层 `capabilities` 为当前会话的 `metadata.read`、`content.read.selection`、`ui.open`；DB-only 测试未注入 opener 时没有 `ui.open`。`tools` 是 helper 公布的工具名称（Batch 3 增加三个 feed plan 工具并保留旧名别名）；是否可执行以 capability / App 审批为准。

快照由 attach(to:) 注入的 MainActor provider 读取 AppStore 账户/同步状态和既有 LibraryDatabase；不刷新、不同步、不访问网络。账户启停在后续请求中重新检查，不重置会话预算或授权。

`paperrss_open` 参数为 `account_id`，加且仅加 `article_id` 或 `feed_id`。服务先校验账户已启用及对象所有权；不存在、不匹配或禁用返回 `NOT_FOUND`，参数组合非法返回 `INVALID_ARGUMENT`。App handler 选择侧栏 Feed，必要时打开文章阅读器并激活/恢复/重建主窗口。响应为 `{opened: "article"|"feed", id, title, feed_title}`，标题仍是不可信内容。该工具标注 readOnlyHint=true、idempotentHint=true、openWorldHint=false；Agent 打开显式抑制自动标已读（包括列表视觉状态），不需要写入授权，也不签发任何写入授权。

UI 定位需要运行中的 App，helper 不负责启动 App。真实窗口、客户端与签名 Xcode 构建仍由人工验收；服务和导航模型测试不能替代该验收。


本批自动化结果：仓库内 module cache 下 `swift build --disable-sandbox` 通过；Agent 相关筛选共 67 项，49 项通过，18 项因执行环境禁止绑定 Unix socket（`Cannot bind private listener` / `Operation not permitted`）受阻。非 IPC 的 45 项全部通过，包含新增快照脱敏、远程账户读取、open 与预算、动态自动已读抑制及 dsh shell 测试。dsh 另有 10 组实际命令/YAML 解析验证通过。完整日志：`build/reports/agent-batch1-build-local-cache.log`、`build/reports/agent-batch1-tests.log`、`build/reports/install-command-validation.log`。未启动真实 App、未修改客户端配置，Xcode 与窗口交互验收未执行。


## Batch 2：App 人工审批与批量已读（2026-10-28）

所有已启用的 local、iCloud、FreshRSS、Miniflux 账户均可创建状态计划；实际写入必须由用户在 PaperRss 内点击「批准」。helper、MCP/IPC 参数、环境变量和 Release 启动参数均不能签发批准。`--client` 通过已认证的 IPC 握手作为诊断标签传入，显示为「来自 <label>（自报）」；缺失时显示「未知助手」。它不用于鉴权，不证明客户端身份。

计划出现时 App 展示「Agent 请求批准」非模态浮动面板，并请求 informational attention，不激活 App、不抢当前输入焦点。设置 → AI → MCP 顶部「待批准的操作」显示相同请求与批准/拒绝按钮。批准按钮不绑定 Return。界面展示账户名称和类型、操作、影响篇数、至多 5 个截断的纯文本示例标题、同步/保留提示和到期时间；标题与标签均是不可信文本。请求按 `(sessionID, planID)` 隔离，拒绝后不可执行，过期自动移除；关闭 MCP 或断开连接移除对应待批准请求并撤销会话。

流程（文本图）：

```text
MCP client → plan_state_change / plan_mark_read
           → App 冻结文章 ID 和目标状态，返回 pending 计划
           → App 浮动面板 + 设置中的待批准操作
用户点击「拒绝」 → owning session.deny → status: denied → apply: DENIED
用户点击「批准」 → owning session.approve → status: approved + approval_id
MCP client → status {plan_id} → apply_plan {plan_id, approval_id, idempotency_key}
           → 再检账户/文章归属及有效期 → AppStore 正常写入路径
           → 本地提交 + 远端 pending-state/iCloud 同步路径 + UI 计数刷新
           → receipt；相同 key 重试返回同一 receipt
```

| 工具 | 参数与语义 |
| --- | --- |
| `paperrss_plan_mark_read`（新增） | `account_id`、`scope: feed|folder|account`；feed 必填 `feed_id`，folder 必填 `folder`（名称或 ID）。可用 ISO8601 `before` 限定发布时间，缺失发布时间时用接收时间。快照最多 5000 篇未读，超过返回 `INVALID_ARGUMENT` 并要求缩小范围。计划不改变文章状态，`readOnlyHint=false`、`destructiveHint=false`。 |
| `paperrss_plan_state_change` | 1–50 个明确文章 ID，`field: read|starred`、`value`；使用同一 App 审批流程。 |
| `paperrss_apply_plan`（新增） | `plan_id`、`approval_id`、`idempotency_key`；执行任何已批准计划。只处理冻结的 ID，新到文章不受影响；重新检查账户归属、文章存在及有效期，跳过已满足目标状态的文章。 |
| `paperrss_apply_state_change` | `paperrss_apply_plan` 的向后兼容别名，参数和批准要求相同。 |
| `paperrss_status` | 新增 `pending_approvals`；指定 `plan_id` 返回 `pending|approved|denied|expired|committed`。仅 `approved` 状态包含 `approval_id`。 |

计划响应包含 `plan_id`、`summary`、`affected_count`、`expires_at`、`approval: "pending"` 与 `next_step`，指示先请求用户在 PaperRss 批准，再查 status、最后 apply。回执包含 `applied_count`、`skipped_count` 和 `sync: local_only|queued_for_sync|synced`。`queued_for_sync` 表示交给正常同步队列，不表示服务器或其他设备已确认；真实远端收敛仍由人工验收。

Core 使用注入的 `AgentWriteExecutor`，真实 App 通过 AppStore/provider 的正常状态写入路径更新，FreshRSS/Miniflux 进入待同步队列，iCloud 使用既有同步路径；不对远端账户绕过同步直接写 SQL。单元测试使用隔离数据库与 recording executor。批量计划冻结的是文章集合，不会因为新文章到达扩大已批准范围。

本批验收边界：自动化不启动真实 PaperRss、不读取或修改用户阅读库及客户端配置；沙箱可能阻断 Unix socket 与缓存。原生 Xcode 构建、非抢焦点窗口行为和真实同步由用户补验，历史批次测试数字不能作为本批通过证据。

本批自动化（2026-10-28）：使用仓库内 module cache，`swift build --disable-sandbox` 通过。最终非 socket 筛选 45 项全部通过：AgentLibraryServiceTests 26、AgentMCPTests 13、AgentApprovalCenterTests 5、会话审批路由桥接测试 1。此前包含 IPC 的筛选中另有 2 项通过，10 项受沙箱禁止 Unix socket bind 阻断（`Cannot bind private listener` / `Operation not permitted`），不能视为 IPC 通过。日志：`build/reports/agent-batch2-build-final.log`、`build/reports/agent-batch2-tests-final.log`、`build/reports/agent-batch2-tests.log`。新增源码由 Package.swift 的目录 target 与 Xcode filesystem-synchronized group 自动纳入；未启动真实 App，未执行 Git 写操作。


## Batch 3：跨账户订阅管理与显式 `/`、`@` 调用（2026-10-28）

### 订阅计划

| 工具 | 参数与语义 |
| --- | --- |
| `paperrss_plan_add_feed` | `account_id`、HTTP(S) `url`，可选 `title`、`folder`；创建添加订阅计划，返回 pending，等待 App 点击批准。拒绝带 userinfo 的 URL、file/其他协议；同账户已订阅返回 `CONFLICT`。 |
| `paperrss_plan_rename_feed` | `account_id`、`feed_id`、1–200 字符的非空 `title`；创建重命名计划并校验订阅属于目标账户。 |
| `paperrss_plan_remove_feed` | `account_id`、`feed_id`；创建删除计划，显示文章总数和收藏数、永久删除且无法撤销的警告；工具 `destructiveHint=true`，计划 `destructive_hint=true`。 |
| `paperrss_add_feed` / `paperrss_rename_feed` / `paperrss_remove_feed` | 上述三个计划工具的兼容别名，参数相同，只创建计划，不直接写入，也不接受客户端自签批准。 |
| `paperrss_apply_plan` | 沿用 Batch 2 的 App-issued `approval_id`、会话与幂等键约束；执行前再次检查账户、订阅归属、重复 URL 和有效期。添加成功回执包含 `feed_id`、`feed_title`。 |

每个可写账户在 status 公布 `feeds.manage.approval`。Local 使用本地 provider；iCloud 使用既有 provider/同步路径；FreshRSS、Miniflux 使用 UI 相同的 ReaderAccountProvider 服务端订阅 API。删除等待 provider 成功，不能把排队的 fire-and-forget 当作成功回执。provider 缺失或不支持操作时返回 `UNSUPPORTED`；任何服务端原始错误中的 URL 或凭据均不直接传给客户端。`sync` 的含义仍按回执解释，iCloud 队列提交不代表其他设备已收敛。

所有写入继续使用同一 App 审批中心：计划 → 用户在 PaperRss 点击批准 → `paperrss_status {plan_id}` → `paperrss_apply_plan`。prompt、resource、旧工具别名、环境变量、RPC 参数都不能代替该点击。Feed 标题、文章标题及 prompt 参数视为不可信数据；URL 摘要不回显 userinfo/query/fragment 中的秘密。

### Prompts 与 resources

initialize 同时公布 `tools`、`prompts`、`resources`；实现 `prompts/list`、`prompts/get`、`resources/list`、`resources/read`、`resources/templates/list`。prompts 仅返回用户显式调用的工具操作模板，不调用 bridge、不执行读写；不自动批准任何计划。

| Prompt | 参数 | 模板指导 |
| --- | --- | --- |
| `digest` | 可选 `since`（`today`、ISO 日期或 ISO8601 时间）、`account_id` | 发现授权账户，按时间读取未读元数据，按 feed 分组摘要；分页受预算限制，不获取正文、不标已读。 |
| `feeds` | 可选 `account_id` | 读取订阅与未读数量，必要时跟随游标。 |
| `mark_feed_read` | 必填 `feed`（标题或 ID） | 查找明确的 feed，创建 mark-read 计划，请用户在 App 批准，轮询 status 后 apply；歧义先澄清。 |
| `open` | 必填 `query`（标题词或 ID） | 查找文章或 feed，调用 `paperrss_open`，不隐式标已读。 |

resources 全部为只读 JSON（`mimeType: application/json`），使用相同 bridge、账户授权、调用速率和输出预算，不刷新或获取正文：

- `paperrss://status`：当前状态和授权账户信息。
- `paperrss://feeds`：授权账户的订阅元数据和未读数量。
- `paperrss://unread/today`：App/helper 本地日界线之后的未读元数据。
- 模板 `paperrss://feed/{feed_id}/unread`：指定 feed 的未读元数据。

资源返回 `untrusted` 标记，并保留分页信息与后续工具参数；单次读取最多 20 个账户、每账户首个 20 项页面，不能把首个页面当作完整库。未知 URI 返回 JSON-RPC 错误。`--fixture` 同样提供 prompts/resources，数据为合成元数据，仍不签发批准或执行写入。

### 各客户端的显式入口

下表记录本批约定的入口；显示方式会随客户端版本变化。**本批未在真实客户端 CLI/GUI 验证任何一行**，自动化 MCP 协议测试不等于客户端菜单或快捷入口验收。

| 客户端 | Prompts / `/` | Resources / `@` | Tools |
| --- | --- | --- | --- |
| Claude Code | `/mcp__paperrss__digest`，或菜单中的 `/paperrss:digest (MCP)` | `@paperrss:paperrss://feeds` | MCP 工具调用 |
| VS Code / Insiders | `/mcp.paperrss.digest` | Add Context › MCP Resources，或 `MCP: Browse Resources` | `#` tool picker |
| Cursor | `/` 菜单中选择 MCP prompt | 支持 MCP resources，按客户端上下文入口选择 | MCP 工具调用 |
| Codex CLI | 以 tools 为主；本表不宣称支持 prompt `/` 入口 | 以当前版本内置资源工具可提供的 list/read 能力为准，不宣称资源 `@` 快捷语法 | MCP 工具调用 |
| DeepSeek dsh | 不支持 MCP prompts | 通过 `dsh-mcp-resources` | `mcp__paperrss__*` |

Verification:

> 待用户补填：客户端名称与版本、操作系统、真实 CLI/GUI、prompt/resource/tool 的实际入口、通过/失败结果、日期及日志。当前所有客户端行均为未实机验证。

本批测试使用隔离 SQLite fixture 与 fake executor/provider，覆盖计划校验、App 批准、回执、跨账户路由及 prompts/resources 协议；不访问真实阅读库或网络，不启动真实 PaperRss，不修改客户端配置。完整 Xcode 构建、真实服务端行为和客户端入口由用户补验；本节不借用前两批测试数字宣称本批通过。

本批自动化结果（2026-10-28）：仓库内缓存配合 `--disable-sandbox` 的 `swift build` 通过；最终非 socket 筛选共 58 项通过（AgentLibraryServiceTests 31、AgentMCPTests 17、AgentApprovalCenterTests 6、AgentBridgeControllerTests 4）。首轮附带的 IPC 测试有 2 项通过、10 项因 Unix socket bind 被沙箱拒绝而失败，未宣称 IPC 验收通过。日志：`build/reports/agent-batch3-build-final.log`、`build/reports/agent-batch3-tests-final.log`、`build/reports/agent-batch3-tests.log`。全部修改位于现有 Swift 文件；Package.swift 目录 target、Xcode filesystem-synchronized group 与现有 helper 显式引用已覆盖，无新增源文件需注册。

## helper 退出与宿主回收（2026-11-04）

保留 stdio：每条有效 MCP 连接有一个轻量 helper，App 仍是唯一数据所有者。已初始化的连接可以长期空闲；不根据空闲时长或同名进程数量推断连接已废弃，也不自动修改 Codex 配置或结束用户现有进程。

stdin EOF、父进程退出、SIGTERM/SIGINT、stdio 读写失败进入同一关闭流程：停止接收新请求，永久关闭 helper 的 IPC bridge，取消未完成请求，并由独立 watchdog 保证两秒内结束进程。`shutdown()` 永久关闭 bridge，原有 `disconnect()` 仍允许后续重连；单个 RPC 取消不销毁其他请求的会话。已经交给 App 的写操作仍按原有提交边界处理，断连不代表回滚，已有成功回执不能被取消覆盖。

macOS 管道在仍有未读数据时，`poll` 的 HUP 可能不足以观测写端关闭。helper 对管道/socket stdin 另用 `kqueue` 的 `EV_EOF` 监测，输出回压和请求槽占满时也保持启用；它不消费或丢弃积压请求，输入缓冲仍有界。进程回归使用 96 个请求覆盖这一组合场景。

stderr 仅以最佳努力输出固定生命周期记录（PID、父 PID、启动/退出原因），不包含文章、请求参数、路径或 token；stderr 无人消费不能阻塞退出。新行为只存在于重建后的 helper。SwiftPM 验证先构建 `paperrss-agent`，再运行 `AgentHelperLifecycleTests` / `AgentIPCTests`；测试默认使用 `.build/debug/paperrss-agent`，可通过 `PAPERRSS_AGENT_TEST_HELPER_PATH` 指定产物，缺少产物必须失败而非跳过。安装版需更新包含新版 helper 的 App，已有客户端连接需重新建立才使用新代码。

自动化使用合成 fixture 和隔离 UDS：初始化前后 EOF、初始化后正常空闲超过两秒仍可 ping、启动时 stdin 描述符无效、真实 IPC 断开、IPC 阻塞时 EOF、父进程死亡但 stdin 写端仍被持有、SIGTERM/SIGINT、stdout 关闭或 96 个 catalog 请求形成回压、stderr 填满，以及两 helper 互不影响。先断言三秒测试容差内自然退出，失败后才清理测试创建的进程；不能用主动 terminate 代替退出断言。

本次自动化结果：SwiftPM helper 构建通过（`build/reports/run-k2hfbxjv.log`），`PAPERRSS_AGENT_NATIVE` 原生 helper 编译通过（`build/reports/run-vg23v6fv.log`）。相关回归 71 项全部通过：helper 生命周期 12、IPC 16、MCP 19、App 审批/会话 14、隔离 App IPC 集成 10；最终日志 `build/reports/run-qotoc61b.log`。这不代表完整原生 App 打包、签名、安装或真实 Codex 聊天卸载验收已完成；未替换 `/Applications/PaperRss.app`，未修改 Codex 全局配置。

### 真实 Codex 宿主验收（待用户操作，尚未完成）

使用一个隔离聊天建立 PaperRss MCP 连接，记录 Codex 版本、helper 的 PID/父 PID、时间及脱敏生命周期日志；由用户结束该聊天或退出持有连接的宿主，再观察管道与 helper。聊天卸载与 MCP 管道关闭分别记录，不能假定前者必然触发后者：

| 观察结果 | 归属与后续 |
| --- | --- |
| stdin 已关闭，helper 超过三秒仍存在 | PaperRss 退出缺陷；保留日志和复现步骤，修复 helper。 |
| 已确认聊天卸载，但 Codex 仍持有 stdin 管道 | 宿主连接回收问题；记录版本、PID、时间和操作步骤，单独报告，不通过误杀 helper 掩盖。 |
| 聊天仍加载，管道保持连接 | 有效连接可以空闲等待，不作为残留。 |
| 持有连接的宿主退出后，helper 及时退出 | 证明父进程退出路径有效，不能代替聊天卸载回收验收。 |

本节的自动化结果与真实 Codex 回收结果分别报告；前者通过不能把本节手动验收标成已完成。

## 批量订阅管理（2026-11-07）

`paperrss_plan_manage_feeds` 为同一明确账号创建包含 1–50 项操作的不可变计划；原有单条 `plan_add_feed` / `plan_rename_feed` / `plan_remove_feed` 及兼容别名保持可用。“修改”指重命名；添加时可指定文件夹。既有订阅由 `list_feeds` 返回的 ID 精确定位，不按模糊名称删除。

```json
{
  "account_id": "account-id",
  "operations": [
    {"action": "add_feed", "url": "https://example.org/rss", "title": "News", "folder": "Tech"},
    {"action": "rename_feed", "feed_id": "existing-feed-id", "title": "New title"},
    {"action": "remove_feed", "feed_id": "another-feed-id"}
  ]
}
```

- 同一个现有 Feed ID / 新 URL 在一批中只能出现一次。整批参数及归属验证完成后才生成计划；无效批次不会留下子计划。
- Ask / Auto 模式仍需 App 批准一次，Full 自动执行。面板逐项展示动作、来源订阅和目标名称；包含删除时标红，并明确文章及收藏也会删除。
- 执行前逐项重新校验账号、归属、重复 URL 和到期时间，使用账号 Provider。批量不保证原子性；单项失败后其余项继续执行。
- `receipt.results` 按输入顺序返回 `index`（从 0 开始）、`action`、`status`（`applied` / `failed`）、`feed_id`、`feed_title`、`error_code`、`sync`；不会回传任意服务器错误文本。
- 必须检查 `failed_count` 与 `local_commit`（`committed` / `partial` / `failed`）。`plan_state=committed` 只表示已产生终态回执，不等于整批成功。
- 无论相同还是新的幂等键，重放已执行计划只返回原回执，不重做其中的成功或失败项。核对目标账号实际状态后，仅为失败项创建新计划；服务器可能在网络报错前已完成部分动作。

## 免审批刷新（2026-11-11）

`paperrss_refresh_feeds` 调用 App 已有的刷新，不另写抓取器，也不经过批准面板。`scope=all` 就是工具栏「刷新全部订阅」：`store.refresh(origin: .agent)`。来源 `.agent` 只用于区分调用方；远端同步原因与手点相同，为 `RefreshReason.manual`，因此 FreshRSS / Miniflux 仍会推送已有 outbox、同步订阅目录并调和文章。系统通知只对定时刷新弹出。

`scope=account` 刷新一个已启用账号。本地和 iCloud 走 `refresh(feedIDs:)`，只含该账号未删除的源。FreshRSS / Miniflux 走该账号自己的 `provider.refresh`，效果与它在「刷新全部」里的那一段相同。`scope=feeds` 只接受本地或 iCloud 的 1–50 个源 ID；服务端账号返回 `UNSUPPORTED`，应改用 `scope=account`。现有按源刷新不会悄悄扩大成整账号同步。

调用立刻返回 `operation_id`（`refresh-` 前缀），不等待抓取结束。helper 与 App 的 Unix socket 单次读超时是 15 秒，全库刷新经常更久。客户端用 `paperrss_status` 传入该 `operation_id` 轮询，间隔约 2 秒。`status` 不计入每分钟 60 次工具限额。`plan_id` 与 `operation_id` 互斥。

全进程同时只有一次刷新，并与工具栏共用 `isRefreshing`。相同目标加入该次操作（`joined: true`）；不同目标返回 `REFRESH_IN_PROGRESS`。相同目标在完成后 30 秒内直接交回那次回执，助手不会连打源站。断开会话不取消已经开始的刷新。关闭 MCP 后不能再发起或查询。

完成回执只有计数、最多 50 个 `new_article_ids`、`truncated`、`subscriptions_synced` 和失败码（`timeout` / `network` / `fetch_failed` / `sync_failed` / `refresh_busy`）。不含标题、摘要、链接或正文。不标记已读，不接受 URL。`subscriptions_synced` 只在 FreshRSS / Miniflux 账号同步时为 true。最近 20 次结果保留 15 分钟。

能力名是 `feeds.refresh`，与 Ask / Auto / Full 无关。设置里的工具目录在「只读」和「需审批写入」之间增加「刷新 / Refresh」。fixture 不联网，对合成库返回一次已完成、计数为 0 的操作。

```sh
./scripts/verify.sh --filter 'AgentLibraryServiceTests|AgentRefreshTests|AgentMCPTests|AgentBridgeControllerTests|AgentIPCTests|AgentIPCIntegrationTests'
```
