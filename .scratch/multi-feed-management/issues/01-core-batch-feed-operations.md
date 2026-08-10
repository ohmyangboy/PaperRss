# 01 — Core 层支持批量 Feed 操作与合并文章查询

**What to build:**
为 `AppStore` 增加多订阅源（Feed）批量处理方法与查询接口，使用户能够同时操作多个订阅源数据，并能高效获取选中订阅源组合的文章流。

**Blocked by:**
None — can start immediately

**Status:** completed

- [x] 在 `AppStore` 中实现 `markRead(feedIDs: Set<UUID>)` 批量标记已读方法
- [x] 在 `AppStore` 中实现 `setFeedFolder(feedIDs: Set<UUID>, folder: String?)` 批量设置分类文件夹方法
- [x] 在 `AppStore` 中实现 `deleteFeeds(feedIDs: Set<UUID>)` 批量删除订阅源方法
- [x] 在 `AppStore` 中增加根据 `Set<UUID>` 过滤未读/全部文章列表的聚合查询 API
