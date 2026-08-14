# GitHub + 本地 Markdown 工单

GitHub Issue 是公开需求和分诊结论的权威来源；被 Git 忽略的 `.scratch/` 是 spec 与实施工单的本地执行区。完整生命周期见 [Matt 开发工作流](development-workflow.md)。

## 基本结构

- 每个工作项一个目录：`.scratch/issue-<N>-<slug>/`
- 待批准规格：`.scratch/issue-<N>-<slug>/spec.md`
- 临时调研：`.scratch/issue-<N>-<slug>/research/<topic>.md`
- 实现工单：`.scratch/issue-<N>-<slug>/issues/<NN>-<slug>.md`，从 `01` 开始，一票一文件
- 工单头部使用 `Status:` 记录状态，标签含义见 `triage-labels.md`
- 讨论追加在文件末尾的 `## Comments` 下

`triage` 对 GitHub Issue 读写；`research`、`to-spec` 与 `to-tickets` 按上面的本地路径写入。读取时优先使用用户提供的 Issue 编号或路径，并核对 Issue 与本地目录是否对应。

## Wayfinding 结构

- 地图：`.scratch/<effort>/map.md`，保存 Notes、Decisions so far 与 Fog。
- 子工单：`.scratch/<effort>/issues/NN-<slug>.md`，头部使用 `Type:` 与 `Status:`。
- 阻塞：`Blocked by: NN, NN`；列出的工单全部为 `resolved` 后才算解除。
- 前沿：按编号选择第一个未阻塞、未认领的开放工单。
- 认领：工作前写入 `Status: claimed` 并保存。
- 解决：在 `## Answer` 下写结论，改为 `Status: resolved`，再把摘要与链接加入地图的 Decisions so far。

`.scratch/` 不进入公开提交，也不自动清理；需要长期保留的内容按工作流经维护者确认、脱敏后移动到 `docs/`。
