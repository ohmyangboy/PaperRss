# 工单分诊标签

GitHub Issue 使用以下固定标签。Agent 只能使用表中字符串，不另造同义标签。

| 状态 | 含义 |
| --- | --- |
| `needs-triage` | 等待维护者评估范围与优先级 |
| `in-draft` | 正在调研与编写方案 |
| `needs-info` | 等待报告者补充信息 |
| `ready-for-agent` | 范围、验收与约束完整，可由 Agent 实现 |
| `ready-for-human` | 需要维护者执行或作出关键判断 |
| `wontfix` | 维护者决定不处理 |

本地实施工单另使用 `claimed` 与 `resolved`，只表示执行占用和完成状态，不替代 GitHub Issue 的产品分诊结论。
