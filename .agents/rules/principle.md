---
trigger: always_on
---

# PaperRss 构建原则

本文档是 Agent 构建 PaperRss 时唯一的规则来源

## 对话风格

- 避免空话，保持回答清晰、明了，优先采用具体行为和小的示例说明，而不是抽象概述、密集术语
- 在回应用户反馈或分析时，先明确表示你同意或不同意，然后再说明你所做的更改。
- 解释非平凡的设计和问题时，请按以下结构说明：问题、具体示例或简短跟踪，然后解决方案。说明解决方案为何必要，并将其与可选的复杂性区分开来。

## 编码原则

- 除非必要，勿增实体
- 人机协作工作流：调用或接续 `triage`、`research`、`to-spec`、`to-tickets`、`implement` 时，修改文档或代码前完整读取并遵循 [Matt 开发工作流](../docs/development-workflow.md)。
- 自动化测试与分级验证矩阵：完成开发后，严格按照改动影响范围在对应层级完成验证，未经验证不得宣称完成：

  1. **Tier 1 (纯 Core / 数据层)**：仅修改 `PaperRss/Sources/Core/` 时，强制执行 `./scripts/verify.sh --feature` 或 `--core`；免拉起 GUI 进程。
  2. **Tier 2 (Web / 治理 / 脚本)**：仅修改 `website/`、`Tests/*.test.mjs` 或工程脚本时，强制执行 `./scripts/verify.sh --web` 或直接运行目标脚本；免拉起 GUI 进程。
  3. **Tier 3 (App 视图 / 系统桥接 / 视觉交互)**：凡涉及 `PaperRss/Sources/App/`（如 SwiftUI 布局、主题色彩、Toolbar、侧边栏、快捷键、系统 Dock 联动及 `ArticleReaderView` 容器桥接），**必须执行 `./scripts/dev.sh` 启动真实 macOS 进程验证**。交付时必须附带直接证据（控制台无关键 warning/error 日志、交互响应行为或截图），严禁以编译通过或推测替代真实验证。
- 发布全链路：遵守SemVer版本规范(`vX.Y.Z-beta.N`）；发布需涵盖测试、构建、产物、ChangeLog、官网和README状态同步、Tag/Release 及线上验证全链路闭环。
- PaperRss对标业界最佳实践，参考netnewsware、freshRSS等优秀的开源实践

## 工程边界

- 扩大平台、改变产品或隐私行为、引入依赖以及执行发布前，必须有明确授权。
- 持久化变更兼容旧数据：保护PaperRss 本地数据（JSON或者数据库文件），阅读数据、模型配置等持久化默认留在本地，启动开发前需要授权并备份，并且保证本轮开发不影响数据完整性。
- API 密钥只经现有凭据入口读写，不注入 Prompt，不进入日志、导出或同步数据；仓库不保存秘密、PII 或私有基础设施信息。
- `PaperRss/Sources/Core/` 承担模型、解析、持久化、网络、同步、AI 和纯策略，不依赖 SwiftUI、AppKit 或 UIKit。
- `PaperRss/Sources/App/` 承担 SwiftUI、应用生命周期和系统桥接，依赖方向固定为 App → Core。
- 修改 `ArticleReaderView` 的 JavaScript Bridge 时，同步核对 macOS/iOS Coordinator、消息协议与行为测试。
- 官网保持原生；`website/` 是唯一发布源码，i18n页面同步维护
- UI 文案进入 String Catalog 或现有本地化入口；i18n结构同步，语言切换即时且不改变 AI 输出设置。
- cloudKit等需要apple 开发者付费账户的功能暂未支持

## 业务边界

- macOS 是主要体验；未开启ios计划时，不考虑ios功能范围