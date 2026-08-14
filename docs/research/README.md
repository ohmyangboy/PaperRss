# PaperRss 技术调研索引

本目录保存可复用的技术调研、竞品架构分析与第三方协议可行性研究。

新调研默认先写入 `.scratch/issue-<N>-<slug>/research/`；只有经维护者确认、完成脱敏且具有长期价值后，才移动到本目录并更新索引。

## 报告

| 主题 | 文档 | 内容 |
| --- | --- | --- |
| 账号与同步 | [`netnewswire-account-system-and-greader.md`](netnewswire-account-system-and-greader.md) | NetNewsWire 账号架构与 Google Reader 协议 |
| 第三方服务 | [`freshrss-api-research.md`](freshrss-api-research.md) | FreshRSS Google Reader 兼容接口与鉴权 |
| 阅读与过滤 | [`rss-keyword-filtering.md`](rss-keyword-filtering.md) | RSS 关键词过滤产品与实现模式 |
| 分发与发布 | [`app-beta-soft-launch-channels.md`](app-beta-soft-launch-channels.md) | macOS Beta 软启动渠道与规则 |

## 写作要求

- 优先使用官方文档、协议标准、官方源码和维护者公开说明。
- 明确区分来源证实、工程推断与尚未验证的假设，并把引用放在对应结论附近。
- 记录检索日期、适用版本与验证边界，避免把调研建议写成已实现事实。
- 使用示例凭据和公共地址，遵循 `.agents/rules/principle.md`。
