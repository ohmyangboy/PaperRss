# 04 — 多选 Feed 拖拽（Drag & Drop）与放置交互

**What to build:**
支持选中单个或多个 Feed 进行拖拽移入文件夹或移出文件夹，拖拽时呈现带数量徽章的卡片 Preview，并限制放置到系统内置分类。

**Blocked by:**
02 — 侧边栏支持 Feed 多选与中间文章流聚合渲染

**Status:** completed

- [x] 实现自定义 Drag Preview，渲染带有选中数量徽章（如“3 个订阅源”）的拖拽卡片
- [x] 为 Folder 行增加 `.dropDestination`，接受拖拽的 Feed 集合并更新对应 `folder`
- [x] 为侧边栏根容器/空白区增加 `.dropDestination`，放置时将 Feed 的 `folder` 设为 `nil`（移出文件夹）
- [x] 在系统分类（今天/未读/收藏）上屏蔽放置行为
