---
trigger: always_on
---

# PaperRss 构建原则

本文档是 Agent 构建 PaperRss 时唯一的规则来源。只在这里保存无法从代码或配置直接推导、违反后代价较高的项目约束。

## 1. 产品信任边界

- 扩大平台、改变产品或隐私行为、引入依赖以及执行发布前，必须有明确授权。
- PaperRss 本地优先：阅读数据、模型配置和诊断默认留在本地，不静默加入遥测、设备标识、附件或后台上传。
- API 密钥只经现有凭据入口读写，不注入 Prompt，不进入日志、导出或同步数据；仓库不保存秘密、PII 或私有基础设施信息。

## 2. 架构与数据不变量

- `PaperRss/Sources/Core/` 承担模型、解析、持久化、网络、同步、AI 和纯策略，不依赖 SwiftUI、AppKit 或 UIKit。
- `PaperRss/Sources/App/` 承担 SwiftUI、应用生命周期和系统桥接，依赖方向固定为 App → Core。
- 持久化变更兼容旧数据；标识符、排序、去重和缓存键保持稳定。
- 修改 `ArticleReaderView` 的 JavaScript Bridge 时，同步核对 macOS/iOS Coordinator、消息协议与行为测试。

## 3. 产品表面

- macOS 是主要体验；未开启ios计划时，不考虑ios功能范围
- UI 文案进入 String Catalog 或现有本地化入口；i18n结构同步，语言切换即时且不改变 AI 输出设置。
- 官网保持原生；`website/` 是唯一发布源码，i18n页面同步维护

## 4. 开发工作流

- 调用或接续 `triage`、`research`、`to-spec`、`to-tickets`、`implement` 时，修改文档或代码前完整读取并遵循 [Matt 开发工作流](../docs/development-workflow.md)。

## 5. 证据与完成

- Swift Core 改动运行 `swift test`；App 改动再运行 `swift build --product PaperRssDesktop`。
- WebView Bridge 或网站改动运行 `node --test Tests/*.test.mjs`；视觉和交互变化还需要真实运行验证。
- Agent 或文档结构改动运行 `node --test Tests/repository-policy.test.mjs` 与 `git diff --check`。
- “发布”只有在测试、构建、版本传播、产物、Tag/Release、官网部署和公开访问验证全部完成后才能宣称成功。