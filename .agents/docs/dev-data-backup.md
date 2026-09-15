# 开发数据备份

改动持久化、迁移或需要真实数据做 GUI 验收前，先备份 App 数据。备份文件不进入仓库，备份前先清点，超限时提示用户。


## 位置与命名

| 项 | 约定 |
| --- | --- |
| 位置 | App 数据目录的同级兄弟目录，默认 `~/Library/Application Support/PaperRss-dev-backups`，与 App 数据同卷 |
| 内容 | `Application Support/PaperRss` 的全部持久化文件：`library.sqlite` 及 `-wal`/`-shm`、遗留 `library.json` |
| 命名 | `<YYYYMMDD-HHMMSS>-<任务名>` |
| 保留 | 最多 3 份；新建前清点，不得出现第 4 份 |

同级目录而不是仓库或系统临时目录：App 只读写 `Application Support/PaperRss`，兄弟目录不会被 App 读到，同卷复制也最快。

## 检查与清除

创建新备份前先清点该目录：

- 不足 3 份：直接备份。
- 已达到 3 份：列出每份的目录名、创建时间与占用（`du -sh`），提示用户并确认删除哪几份；用户确认后才能删除，然后继续备份与后续开发。

不自动删除，也不进入 `clean.sh` 或报告轮转范围。用户未确认时才自动清除，在最后回答中提示。

## 恢复

关闭 App 后进行，避免 WAL 与新进程混写：

```sh
mv ~/Library/Application\ Support/PaperRss ~/Library/Application\ Support/PaperRss-broken
mv ~/Library/Application\ Support/PaperRss-dev-backups/<快照> ~/Library/Application\ Support/PaperRss
```

## 已知边界

- 备份是人工快照，没有定时任务，也不是 Time Machine 替代品；长期保全由自行安排。
- 迁移备份 `library.json.pre-sqlite-*.backup` 是 App 功能产物（`LegacyJSONMigrator`），不属于本流程。
