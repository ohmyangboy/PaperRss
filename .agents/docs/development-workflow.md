# Matt 开发工作流

在 PaperRss 中使用 `triage → research → to-spec → to-tickets → implement` 时遵循本文。GitHub Issue、`.scratch/` 与 `docs/` 分别承担公开需求、私有执行和公开知识，正文只保留一个权威副本。

## 信息边界

- **GitHub Issue**：功能或缺陷的公开入口，保存分诊结论、维护者决策和最终结果。进入本工作流的事项必须关联 Issue/或者本地docs文档流程。
- **`.scratch/issue-<N>-<slug>/`**：被 Git 忽略的本地工作区，保存研究过程、待批准 spec 和实施 tickets。
- **`docs/`**：GitHub 仓库中的公开知识库。内容进入前必须具有长期价值、完成脱敏并得到维护者确认；它不会自动发布到官网。

路径使用小写 kebab-case；同一工作项始终沿用 `issue-<N>-<slug>`。详细的工单格式和状态分别见 [工单配置](issue-tracker.md) 与 [分诊标签](triage-labels.md)。修改领域术语或架构决策时再读取 [领域文档说明](domain.md)。

## 生命周期

1. **Triage**：在 GitHub Issue 上分诊并使用仓库固定标签。判定不做时，在 Issue 写明理由并关闭；不另建 `.out-of-scope` 文档。
2. **Research**：默认写入 `.scratch/issue-<N>-<slug>/research/<topic>.md`。维护者确认其可复用且已脱敏后，移动到 `docs/research/` 并更新索引；移动后不保留第二份正文。
3. **To spec**：将待批准规格写入 `.scratch/issue-<N>-<slug>/spec.md`，至少覆盖问题、范围、验收条件、关键约束和未决风险。
4. **Accept**：只有维护者明确批准开发后，才把 spec 移动到 `docs/drafts/issue-<N>-<slug>.md`，并在文档头部记录一行 `- **Status**: accepted` 与原始 GitHub Issue 链接。该公开草案随即成为唯一权威规格。
5. **To tickets**：根据 accepted 草案，在 `.scratch/issue-<N>-<slug>/issues/<NN>-<slug>.md` 生成纵向实施工单，一票一文件，从 `01` 开始。
6. **Implement**：读取 accepted 草案和本地 tickets，完成代码、匹配风险的测试及 review。只有用户明确要求时才执行 `git add` 或创建 commit。
7. **Complete**：更新或关闭 GitHub Issue。用户可见的稳定行为整理到 `docs/features/`，协议、架构或运维知识整理到 `docs/technical/`；没有独立长期价值时删除 accepted 草案，使 `docs/drafts/` 只剩等待实现的规格。
8. **Clean up**：`.scratch/` 默认保留；只有维护者明确授权才删除。Agent 可以建议放弃 accepted 方案，但只有维护者能确认放弃、删除草案并关闭 Issue。

## 完成门槛

- 公开文档不包含凭据、PII、私有服务地址、本机绝对路径或原始对话流水账。
- 研究结论区分来源事实、工程推断和未验证假设，并就近标注一手来源、检索日期和适用版本。
- 实现报告分别列出已验证、未验证和环境限制；编译、真实 UI、设备、签名及线上状态不能互相替代。