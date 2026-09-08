# PaperRss 构建存储清理记录（2026-09-08）

清理及构建验证后，文件系统可用空间净增加 **12.46 GB（11.60 GiB）**。删除目录的 `du` 块统计合计 **18.52 GiB**，该值不等同于物理释放量；共享块、系统后台写入及重新构建均会影响实测差值。本次以清理前和最终 `disk_usage.free` 差值为准，备份占用与重建增量已计入。

## 核查与保全

- 开始时 `git status --short` 为空；无正在运行的 PaperRss、Fresh 测试应用或编译进程。未执行提交、推送或 `.git` 清理。
- 核查 `build`、`.scratch`、`.build`、三个 `build-*`、`dist`，以及 `/private/tmp`、当前用户系统临时目录、Xcode DerivedData。系统名称匹配的 5953 项只作候选，逐项结合 WorkspacePath、内容与脚本判断。
- 22 套重复 DerivedData 已回收：9 套仓库内 `build`/`.build`/`build-*` 编译目录、3 套 `.scratch` 升级验证中间产物、9 套 `/private/tmp` 构建和 1 套当前项目的系统 DerivedData。精确清单以恢复目录的 `derived-plan.json` 为准。
- 所有候选依赖 checkout 已检查，无本地改动。`build/issue21` 的旧绝对 alternates 路径失效，通过临时 `GIT_ALTERNATE_OBJECT_DIRECTORIES` 指向现有对象库完成只读检查，未修改 Git 元数据。
- 118 项符号/日志等保护目录已按原始绝对路径迁移，另复制系统临时目录中的独立脚本、补丁、研究文档与素材。迁移文件 SHA-256 校验通过。
- `dist` 全部保留，包括版本发布目录、DMG、归档及其 dSYM；发布与素材的 2218 个文件 SHA-256 校验通过。`.scratch` 的补丁、工具、素材、源码与运行数据备份保留；`build` 内图标和视觉验收素材保留。
- 临时发布源码副本及其独立 DerivedData、测试 HOME/运行数据、研究仓库和无法充分归因的临时文件保留。系统的 11 个模拟器均为关闭状态，未发现可明确归属 PaperRss 的专用测试设备，保持原状。
- 另有 870 个旧夹具与当前 Node 测试源码中的创建前缀及实际内容相符。先完整压缩并逐文件验证 SHA-256，再回收；归档约 6.5 MB。没有对系统临时目录进行通配删除。

## 后续机制

详见 [构建产物与存储管理](../technical/build-storage.md)。

- 日常 macOS、隔离 UI、Fresh 测试、SwiftPM、发布和升级验证各自复用固定目录。
- 构建入口统一通过 `build-support.py` 跨进程加锁；Web 外层只在轮转日志时短暂持锁，内部构建自行加锁，避免嵌套死锁。
- SwiftPM/Web 测试使用自建临时目录，退出、失败、INT/TERM 时回收。无参数的隔离 UI 自动回收测试 HOME，显式传入的 HOME 保留。
- 新报告保留 30 天，在后续脚本运行时轮转；不自动删除历史人工报告或发布资料。
- `archive.sh` 不再删除整个 `dist`，归档写入独立持久目录。
- 验证中发现本地 TLS 夹具会在仓库根目录产生 `.srl`，已将 CA 序列号文件显式写入夹具目录；旧生成文件已保全，针对性复验后未再出现。

## 验证

- 最终 `./scripts/verify.sh --build`：macOS `BUILD SUCCEEDED`。
- `./scripts/verify.sh --web`：153 项通过；后续发布脚本针对性复验 13 项通过；TLS 输出路径修正后的升级测试 6 项通过。
- Python 脚本测试：7 项通过，覆盖跨进程互斥、失败回收、信号退出、保留期限、调用者 HOME 保全及归档失败时历史发布文件保全。
- 修改的 shell 脚本语法、Node 语法及 `git diff --check` 通过；本次临时运行目录已回收。
- 本轮只涉及构建治理及脚本，未改 App/Core 产品逻辑；没有进行正式应用 GUI 或在线发布验收。

## 恢复位置

本机恢复根目录：`~/Documents/PaperRss-cleanup/20260908/`（仅当前用户可访问，长期保留，不参与 30 天报告轮转）。

- `recovery-map.json`：每项原址和当前保存位置。按映射复制所需符号/日志回原址，或直接在保护目录读取。
- `protected/`、`protected-sha256.json`：保护文件及校验值。
- `test-fixtures.tar.gz`、`fixture-result.json`、`fixture-sha256.json`：旧夹具完整备份、原始目录清单及校验值；先解压到独立目录，再按原路径选择恢复，避免覆盖新测试输出。
- `original-scripts/`：本轮修改前的 Git HEAD 版本，供逐文件恢复；初始工作区没有未提交脚本。
- `system-inventory.json`、`derived-plan.json`、`cleanup-result.json`、`final-metrics.json`：核查清单与空间测量。原始及最终验证日志也在此处。
- 删除的编译缓存未全量备份；用固定构建入口重新生成。恢复符号不会恢复整套 DerivedData。
