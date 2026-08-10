# 02 — 侧边栏支持 Feed 多选与中间文章流聚合渲染

**What to build:**
允许用户在侧边栏使用 Cmd/Shift 键选择多个订阅源（Feed），同时中间栏文章列表能够自动响应并渲染所有选中 Feed 的合并文章流。

**Blocked by:**
01 — Core 层支持批量 Feed 操作与合并文章查询

**Status:** completed

- [x] 侧边栏支持多选集合 `selectedFeedIDs: Set<UUID>` 绑定与 Cmd/Shift 交互处理
- [x] 选中多个 Feed 时，高亮侧边栏对应的多个 Row
- [x] 中间栏 `EntryListView` 接入多源筛选，实时呈合并后的文章流
