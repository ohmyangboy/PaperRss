# PaperRss MCP × Grok Bot 接入方案调研

> 调研日期：2026-10-29（Asia/Shanghai）。源码基线：`main` / `363be45d9ffe05acae908b5c9648ec97577bc394`。
> 本次只读源码、测试与公开文档，只新增本报告；未启动 App、读取真实阅读库、部署网关、安装依赖或修改客户端配置。未构建、运行产品测试或做 Grok Bot 实机联调，未 commit、push、开 PR 或发版。
> 下文“当前源码”指上述 checkout；v1.5.1 的既有本地 MCP 和 Oliver 的 `AddMcpServer` 行为来自任务背景，不把源码核对当成已安装版本的运行验收。

## 1. 结论摘要

**现在首选 D：利用 Grok Bot 已有的受审批本机执行能力，让已经接入 PaperRss MCP 的本机助手代调，先完成一个小阅读任务。** 这最贴近目前一个用户的需求，不需要 PaperRss 立即承担公网服务、远程凭据和隧道运维。Grok 官方文档已确认能经桌面端在用户本机执行命令；Oliver 的版本、账户和管理员策略是否放行，仍须在其 Mac 上确认。[Grok 本机执行设置](https://cursor.com/docs/grok-bot/settings#run-commands-on-your-desktop)

**如果验收要求是“PaperRss 出现在 Grok Bot 自己的 MCP 工具列表中并能直接调用”，D 不满足，应选 B：Mac 上的独立、可选网关，把现有 stdio MCP 转成受鉴权的 HTTPS MCP。** 首轮只开放限定账户的元数据。它是最小的直连接入方向，但尚无本项目的即用配置或联调证明；在确认 Grok 的协议版本、请求头或 OAuth 能力前，不部署公网入口。

其余判断：

- A：App 内建远程 HTTP 服务或随 App 分发官方网关，可行，但产品维护范围更大；等 B 证明需求后再决定是否产品化。
- C：原生 machine-local MCP 值得争取；本次未找到 `AddMcpServer.command` 可选择 Oliver 的 Mac 的公开依据，标为**待产品侧**。本机 Shell 已有依据，两者不能混为一谈。
- “数据留本机”只能承诺不新增托管阅读库副本。发送给 Grok 的标题、摘要、正文或本地助手输出都会离开 Mac，不能承诺处理全程在本机。
- 不推荐裸 TCP、匿名公网 MCP、整库上传、静态文件冒充 MCP，也不以 Full 模式解决连接问题。

## 2. 问题到底在哪里

现有调用链是：本机助手 → stdio `paperrss-agent` → 本机 UDS → 正在运行的 PaperRss App → App 已打开的库。helper 不拥有数据库，不持有 RSS 或 AI 服务密钥，也不会自动启动 App。依据：`Package.swift`、`PaperRss/Sources/AgentHelper/AgentMain.swift`、`PaperRss/Sources/AgentMCP/AgentMCPServer.swift`。

Oliver 当前的链路则是 Grok Bot → Linux box 上的 `command`。即使填入 Mac 的 `/Applications/PaperRss.app/Contents/MacOS/paperrss-agent`，进程也没有转移到 Mac；复制可执行文件或 socket 路径不能解决跨机器、操作系统和本机身份边界。Grok 的 HTTPS 入口也不会自行理解 PaperRss 的内部 IPC：stdio 是换行分帧 JSON-RPC，UDS 是长度前缀 JSON，二者都需要真正的 MCP HTTP 适配器。

另一个容易误判的点是请求从哪里发出。Grok 官方说明远程 MCP 经 Cursor 服务端访问。因此，“Linux box 能访问某个 VPN 地址”或“Mac 上有 localhost 服务”，都不足以证明 Grok 的 URL MCP 能访问它；须从实际 MCP 连接路径验证。[Grok MCP 网络策略](https://cursor.com/docs/grok-bot/security#mcp-servers-and-the-network-policy)

## 3. 源码确认的现有边界

| 事项 | 当前源码证据 | 对方案的约束 |
| --- | --- | --- |
| 接入形式 | `AgentMain.swift` 只接受 `serve --stdio` 及 `--client`、`--fixture`，没有 HTTP server 或业务查询 CLI 子命令 | 不能写一个不存在的 `paperrss-agent list-articles` 命令给 Oliver |
| 开关 | App 的 `PaperRss.agentMCPEnabled` 默认关；helper 另要求 `PAPERRSS_AGENT_ENABLED=1` | 新远程入口应另设默认关闭的开关；不能复用本地开启状态自动开放公网 |
| 本机认证 | `AgentIPC.swift`：当前 UID、0700 目录、0600 文件/socket、双端 peer UID、随机 token、IPC 版本与实例握手；重新开启轮换 token | 这些是同一 macOS 用户的信任，不能直接充当远程认证 |
| 客户端身份 | `--client` 是自报诊断标签；`paired=true` 对应 `local_user_token` | 不能声称已经把 Grok 与其他同用户进程安全隔离，也不能把标签作为配对凭据 |
| 查询与正文 | `AgentBridgeController.swift`、`AgentLibraryService.swift`：可查已启用账户的受限元数据；正文要求 App 签发的 selection，读取已有内容 | 不因新增传输而开放全历史、任意正文或自动抓网页；当前 Debug 正文 QA 参数不能作为发布方案 |
| 会话 | 每条 IPC 连接持有独立业务会话、游标、selection、计划与预算，断开撤销；helper 出错后可重新连接 | 网关不能把不同远程身份混到一个 helper；后端重连后也不能继续冒用旧授权 |
| MCP 版本 | `AgentMCPServer.swift` 支持 `2025-11-25`、`2025-06-18`、`2025-03-26`、`2024-11-05` 的初始化协商 | 不能因为网关支持较新规范，就宣称 helper 也已支持 |

正文现有约束包括一次选择 1–20 篇、15 分钟有效、每篇默认 8,000／最多 20,000 字符、每业务会话输出预算最多 100,000 字符，以及每分钟最多 60 次非 status 业务调用。预算按会话计算，重连会获得新会话，**不等于按远程用户累计的出库上限**。依据：`AgentAccessPolicy.swift`、`AgentLibraryService.swift`。

`documents/features/agent-mcp-local-mvp.md` 和 `documents/research/paperrss-agent-integration-cli-mcp.md` 提供设计背景；前者早期批次的“所有写入都必须点击批准”、后者的“接口尚未存在”不能覆盖当前源码事实。正文授权仍只有受信 App hook 与 Debug QA 入口的证据，本次未确认面向普通用户的正式正文确认流程。

## 4. 可行路径对比

| 路径 | 怎么接到 Mac | 优点 | 成本、限制与判断 |
| --- | --- | --- | --- |
| **A1：App 内建远程 HTTP MCP** | App 承接 HTTP；跨公网仍要解决 HTTPS、可达性、认证 | 生命周期、撤销和权限 UI 可统一；有机会做完整产品体验 | App 新增网络攻击面、证书/认证/升级兼容责任；单加 HTTP 不会穿透 NAT。**现在不优先** |
| **A2：PaperRss 官方可选网关** | 独立进程承接 HTTP，经现有 helper 或内部受限接口访问 App | 保持 App 数据所有权；安装、诊断和关闭可产品化 | 仍需维护网关、配对、签名分发与客户端兼容。可从 B 试点演进，不能视为只多一个 URL |
| **B：用户管理的本机网关＋隧道** | Mac 上运行 stdio→HTTP MCP 网关，仅监听 loopback；隧道提供 Grok 可达的 HTTPS 地址 | 可复用当前 helper，无需立即修改业务代码；能完成真正的 URL MCP 直连 | 网关与 Mac/App 都须在线；要管密钥、第三方代理、限额、睡眠恢复和关闭。**需要直连时首选，先小范围试点** |
| **C：Grok 原生本机 Mac MCP／machine-local command** | Grok 桌面端在 Mac 启动 helper，并维护 stdio 会话 | 若产品支持，最符合当前 PaperRss 接入方式，无需公网入口 | 官方已支持本机命令执行，但未验证能将已添加的 MCP server 放到 Mac。**原生 MCP 部分待产品侧，不能作为已可用方案** |
| **D：本机 Shell／本机助手代调** | Grok 经批准在 Mac 调用已连接 PaperRss 的本机助手；必要时由真正的 MCP 客户端脚本维护 stdio 会话 | 不新增公网入口，继续使用现有 App 权限与业务路径；可先验证阅读任务价值 | 多一层调用，输出/错误更难追踪；若用第二个云模型，增加数据接收方。不是 Grok 原生 MCP 直连。**现在首选的过渡方案** |

Cursor 编辑器官方支持 stdio、SSE、Streamable HTTP，远程配置可带 headers；这能证明编辑器的连接方式，**不能外推成 Grok Bot 的 `AddMcpServer` 支持同一份配置、相同鉴权字段或相同执行位置**。[Cursor MCP 文档](https://cursor.com/docs/mcp#how-it-works)

### B 的可行性与边界

建议链路为 Grok 的 MCP 请求 → HTTPS 隧道入口 → Mac 上仅监听 `127.0.0.1` 的受鉴权 MCP 网关 → stdio helper → UDS → App。隧道提供网络通路，网关负责 MCP 传输转换和远程权限；二者都必须存在。

已有开源实现证明“stdio→Streamable HTTP”是可行的适配方向。例如 Supergateway 公开说明支持该模式、legacy stateful 会话与入口 API key，但默认监听所有接口、默认不要求入口 key，不能照搬默认启动方式。本次只核对其公开说明，未安装、执行、锁定版本或审计，**不把它作为已验收的 PaperRss 连接器**。[Supergateway 官方仓库](https://github.com/supercorp-ai/supergateway)

Cloudflare Tunnel 的公开文档说明，可将公共 hostname 映射到本机服务，并通过出站连接建立通路；这解决 NAT/入口问题，不会自动增加 MCP 实现或 PaperRss 授权。自建反向代理也可承担入口，但会增加服务器维护责任。[Cloudflare Tunnel 路由说明](https://developers.cloudflare.com/tunnel/concepts/routing/)

仅在 Mac 上装 VPN 不保证 Cursor 服务端能进入该私网；依赖浏览器登录页的反向代理也不等于支持机器客户端的 MCP OAuth。能否注入对应认证头、完成授权并访问目标地址，须从 Grok 实际工具调用验收。

## 5. 安全设计：必须保留什么

### 数据本地保存与外发要分别说明

App 继续拥有阅读库、已有账户同步和业务操作，方案不新增云端阅读库。helper／网关不复制 SQLite，不托管全库或正文缓存。查询结果进入 Grok 时已跨出设备；本机助手如果调用另一个模型，结果可能先到那个服务。HTTPS 入口若由第三方终止 TLS，该代理也进入数据处理信任边界，不能宣传为 Mac 到模型之间的端到端保密。

元数据也可能暴露私人订阅、阅读兴趣和敏感链接。默认先返回限定范围的标题、时间、必要链接与计数；片段控制长度，过滤 URL 中凭据与敏感参数。不能保证 URL path 没有秘密，用户应能排除私人 Feed。库读取授权不等于任意正文外发许可，正文应独立确认；文章、标题和助手输出一律作为不可信数据，不能据此升权或调用任意 Shell。

### Ask／Auto／Full 的准确含义

下表来自 `AgentBridgeController.swift` 的 `AgentMCPApprovalMode.automaticallyApplies`、`registerApproval` 以及 `SettingsView.swift` 的设置文案；不是引用旧设计推测。

| PaperRss 模式 | 已读／收藏状态计划 | 添加／重命名／删除订阅计划 | 不能误解成 |
| --- | --- | --- | --- |
| **Ask（默认）** | App 内逐次批准后立即执行 | App 内逐次批准后立即执行 | 每次元数据查询或每次外发都弹窗 |
| **Auto** | App 自动批准并执行 | 仍需 App 内批准 | 自动允许订阅删除、正文外发或扩大账户范围 |
| **Full** | App 自动批准并执行 | App 自动批准并执行，包含删除订阅 | 绕过认证、正文 selection、参数校验、预算或回执 |

这些模式决定 App 如何处理**操作计划**，不是网络身份认证，也不是内容外发开关。Full 下入口凭据失窃可能直接造成订阅及历史删除；不能把“plan”字样当成无副作用保证。

Grok 的本机执行审批、云端 Auto Review 与 PaperRss 的审批模式是三层不同控制。D 建议逐命令确认、本机助手只执行限定任务、PaperRss 保持 Ask；通用 Shell 自身能接触本机文件，权限范围可能超过 PaperRss MCP，因此不可用一次宽泛授权包办后续命令。B 的首版应在服务端拒绝所有写工具，**即使本机 App 设置为 Full，远程入口也只能读**。

### token、配对与公网入口

1. **本机 token 不出 Mac。** 现有 UDS token 继续由本机 helper 读取，不发给 Grok、不放 URL、聊天、报告或公网配置；`--client grok` 仍只是标签。
2. **远程凭据单独签发。** 配对时在本机明确展示“哪个连接、哪些账户、哪些能力、有效期”，经用户确认签发独立高熵凭据；支持到期、轮换和立即撤销。单个凭据代表被授权连接，不保证识别 Grok 账户里的某一个 Bot。
3. **每次请求都鉴权。** 若双方支持，单用户试点可用安全 secret 入口注入的 Bearer token；它是受限部署方案，不是完整 MCP OAuth 实现。面向通用客户端的产品化版本应按 MCP HTTP 授权规范处理发现、OAuth、scope 与 token audience。凭据不放查询字符串，会话 ID 不能代替认证。[MCP HTTP 授权规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
4. **公网可达不等于公网可用。** 外部全程 HTTPS，本机网关仅 loopback；校验 Host、出现时的 Origin，关闭不需要的 CORS。无 Origin 的受认证机器请求不因此自动获信任；加入请求体积、超时、并发和速率限制。URL 难猜、路由器未开端口、IP 白名单都不能替代鉴权。[MCP 2025-11-25 传输安全](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#security-warning)
5. **权限在执行入口强制。** 不能只从 `tools/list` 隐藏工具，仍允许客户端手写 `tools/call`；旧工具别名、resources 与 prompts 也不能成为旁路。用远程凭据累计限额，避免重连重置预算；账户范围须逐请求检查，status 也不能泄露未授权账户。
6. **默认关闭、可即时停用。** 新远程开关独立于本地 MCP；关闭网关、撤销配对或关闭 App MCP 后，已有连接和在途结果都须失权。日志只留必要诊断，不记 Authorization、原文、私人 URL 或完整检索词；隧道/代理不得缓存 MCP 响应或记录响应正文。

单纯 stdio 转发器可接通协议，却会继承当前 helper 的全部工具与 App 全局审批模式。若需要上述账户白名单、只读保证和配对 UI，就必须验证网关确有这些强制能力，或开发最小策略层；没有依据时不能承诺“加个隧道就安全”。当前 App 仍只识别本机 UID/token，网关自身因此是受信组件；其失守不受独立的 App 远程身份策略兜底。

## 6. 推荐怎么推进

### 现在：先走 D，完成一次受控的元数据任务

先在 Oliver 的 Grok 桌面端确认 `Execution on this computer`／旧名 `Execution on Local Computer` 可用并设为逐命令确认。官方提示设置随账户和 rollout 变化；可见本机执行也不改变 `AddMcpServer.command` 当前仍在 Linux box 运行的事实。[Grok 设置说明](https://cursor.com/docs/grok-bot/settings#computer)

让 Grok 请求在 Mac 上调用**已经成功连接 PaperRss MCP 的本机助手**，只完成“列出某个指定 Feed 的最近 20 条未读标题和链接”。本机助手内部实际调用 `paperrss_status`、受限列表工具，交回最少必要结果和真实错误；不要求 Grok 获得任意本机文件读取权限，不顺带读正文或改状态。

如果改由 Shell 直接驱动 helper，需要一个真正的 MCP 客户端来完成 initialize、通知、请求/响应匹配，并在同一进程会话里完成查询；只启动 `serve --stdio` 不会自动得到文章列表。当前没有证据证明 Oliver 已装好这样的脚本，也未验证 Grok 可直接编排本机助手的具体调用方式，因此这是**建议验证的工作流，不是已打通的接入结果**。本机执行不可用时，可由用户在本机助手完成同一查询，再主动把少量结果交给 Grok；不临时降级为匿名公网服务。

代价是多一层助手和潜在模型处理方，错误、耗时和结果来源需要区分；它也不能给 Grok 提供 PaperRss 原生工具发现。若这使阅读工作流明显不顺，再转入 B，而不是继续堆叠助手调用。

**D 的验收标准一句话：Oliver 逐次批准本机执行后，Grok 能取得指定 Feed 的真实受限未读元数据和可区分的失败结果，查询不改变阅读状态、不读取未授权正文，也不新增公网端口。**

### 确需原生直连时：B 的最小 MVP 范围

这是后续候选范围，本次不实现、不部署。先核验 Grok 的三件事：**实际请求来源可到达入口；支持与 helper 兼容的 HTTP MCP 版本；可通过安全配置携带认证头或完成 MCP OAuth。** 任务提供的 `AddMcpServer` 事实仅确认 URL／command 两种入口，不能据此假设 headers、secret 存储、OAuth 或本机会话管理已具备。仅收 URL 且无法安全认证时，公网 MVP 不进入实施。

| 项目 | 只做的范围 |
| --- | --- |
| 使用者与生命周期 | 一位 Mac 用户、一个经本机确认的 Grok 连接；网关前台按需运行，不加 launchd、自启或 App 退出后访问；Mac/App 不在线就明确失败 |
| 部署方式 | Mac 上独立网关＋用户管理的 HTTPS 出站隧道；网关 loopback-only，关闭网关即停止库访问，不建立云端库副本 |
| 远程权限 | 仅开放 `paperrss_status`、`paperrss_list_feeds`、`paperrss_list_articles`、`paperrss_get_article`；限定显式选定的已启用账户和现有可读范围；status 过滤其他账户、后台计划及无权使用的工具信息 |
| 明确拒绝 | 正文 `get_content`、App 定位 `open`、全部状态/订阅计划与 apply、旧写别名；首版关闭 resources/prompts 入口，避免绕过只读和账户限制 |
| 认证与配对 | 本机确认权限，独立远程凭据、有效期、撤销；每请求鉴权；先以双方验证支持的安全 header 方式试点，若必须 OAuth，重新评估范围，不私自改为 URL token |
| 协议与会话 | 验证双方共同支持的版本；每个远程授权会话绑定独立且持续的 helper/IPC 会话，处理通知、并发响应、取消与会话回收；后端重连视为新会话并失效旧游标/授权 |
| 配额与隐私 | 保留现有服务限制，另按远程凭据累计限额与并发上限；不靠重连刷新预算，不记录正文/密钥，不缓存响应 |
| 诊断与停用 | 区分 HTTP 认证失败、App `NOT_ENABLED`／`APP_NOT_RUNNING`、协议不兼容和限额；撤销及关闭阻止已有会话继续出库；不从旧副本伪造成功 |

协议版本必须写进验收记录。若双方验证共同支持 `2025-11-25`，可按该版的初始化及有状态 HTTP 会话映射到现有 helper。**不要把这套会话设计无条件套到最新版**：公开的 `2026-07-28` 规范采用逐请求元数据，移除了旧的 HTTP session／独立 GET SSE 机制；网关支持新版不意味着现有 helper 可透明使用新版。双方没有共同版本时停止该 MVP，显式评估版本适配工作。[MCP 新版与旧版兼容说明](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#earlier-streamable-http-revisions)

新实现优先选择双方支持的 Streamable HTTP；SSE 流式响应是传输选项，不要求为普通列表常开流。旧 HTTP+SSE 仅在 Grok 实际兼容要求明确时考虑，不因界面写着 HTTP/SSE 就同时实现两套协议。HTTP 请求结束也不能一律销毁 helper，否则分页、预算和后续授权会丢失。

**B 的验收标准一句话：Grok Bot 通过实际 HTTPS MCP 工具调用只能读到已配对账户的受限元数据，所有正文、写入及旁路请求均被服务端拒绝，且撤销、到期、关闭 App MCP、断网或后端重连不会泄漏数据或复用旧授权，即使 App 设为 Full 也成立。**

## 7. 不做清单与待产品侧事项

本轮及上述最小 MVP 不做：

- 将 UDS 用 `socat`／裸 TCP 映射到公网，或公开 `0.0.0.0` 上无鉴权的转发器。
- 把阅读库、全量 OPML、正文缓存复制到 Linux box／云端，再把副本称为“本地 MCP”。
- 用静态 JSON、静态网页或下载地址冒充 MCP server；静态文件不能完成真实查询、会话、授权与错误处理。
- 把 UDS token、AI Key、RSS 凭据交给 Grok；把远程凭据塞入 URL、聊天提示或仓库；用随机 URL 代替认证。
- 只限制工具展示、靠 prompt 告知“不要写”、依赖 Grok Auto Review 来弥补服务端越权。
- 为联网改成 Full；Full 不提高可达性，且会放大入口失窃后果。未来若加远程写入，须另行设计远程权限与 App 模式的共同约束。
- 同时交付多用户、公网 SaaS、完整 CLI、通用 Shell/SQL、无人值守全库摘要或完整 OAuth 平台；这些都不属于此次最小接入。

待 Grok 产品侧或 Oliver 实机核验：

| 问题 | 当前结论 |
| --- | --- |
| `AddMcpServer` 能否指定 machine-local／Mac，并持有 stdio 子进程？ | 未找到公开依据，**待产品侧**；若确认可用，可优先复用现有本地接入取代网关 |
| HTTPS MCP 支持哪些协议版本、headers、secret 引用和 OAuth 流程？ | Cursor 编辑器有相关文档，Grok 此入口未逐项验证；不得直接套用 |
| Oliver 是否可用本机执行，能否通过它调用已有本机助手？ | 官方存在该能力；账户、版本、管理员限制与具体调用待实机确认 |
| 隧道／私网地址能否从实际远程 MCP 请求路径访问？ | 要验证 Cursor 服务端路径；Linux box／浏览器单独连通不算证明 |
| Mac 睡眠、App 关闭后是否仍要求定时运行？ | 若要求，当前 App 在线模型不足，需重新定范围，不能默认为已支持 |

## 8. 证据与验证边界

本次阅读的主要本地证据：

- `PaperRss/Sources/AgentHelper/AgentMain.swift`、`PaperRss/Sources/AgentMCP/AgentMCPServer.swift`、`AgentMCPTools.swift`：入口、MCP 版本与工具分发。
- `PaperRss/Sources/Core/AgentProtocol/AgentIPC.swift`：UDS、token、同 UID 信任、分帧、断连与重连。
- `PaperRss/Sources/App/AgentBridgeController.swift`、`AgentApprovalCenter.swift`、`SettingsView.swift`：开关、会话、Ask/Auto/Full 与受信 App 审批。
- `PaperRss/Sources/Core/Agent/AgentAccessPolicy.swift`、`AgentLibraryService.swift`：账户范围、正文 selection、预算、既存内容读取与计划回执。
- `Tests/AgentMCPTests/AgentIPCTests.swift`：禁用/退出区分、会话隔离、重连、token/版本拒绝；`Tests/AgentLibraryServiceTests.swift`：正文授权、计划批准与回执；`Tests/AgentMCPTests/AgentMCPTests.swift`：协议与参数校验。**仅阅读测试源码，本轮未运行。**
- `documents/features/agent-mcp-local-mvp.md`、`documents/research/paperrss-agent-integration-cli-mcp.md`：历史设计、验收记录与边界；既有研究文件保持原样。

公开资料均为调研时查看的官方协议／产品文档或项目维护者仓库，链接随相应判断列出。已确认的是架构可行性、源码行为与文档声明；**未确认的是 Oliver 的客户端实用性、网关安全验收及任何 Grok→PaperRss 的端到端成功。** 插件目录没有 PaperRss connector 与 Linux `command` 的现状按任务给定事实使用，本次未登录 Oliver 的账户核对。
