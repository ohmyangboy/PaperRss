# 构建产物与存储管理

日常构建复用固定目录，禁止按 Issue、任务或日期复制整套 DerivedData。以下目录中的编译缓存可重建，但不能仅凭目录名执行删除。

| 用途 | 固定位置 | 入口 |
| --- | --- | --- |
| macOS 日常构建 | `build/` | `./scripts/verify.sh --build`、`./scripts/dev.sh` |
| 隔离 UI 构建 | `build/isolated/` | `./scripts/dev.sh --isolated` |
| 新用户测试 | `build/FreshLaunchTest/` | `./scripts/test.sh` |
| SwiftPM 测试 | `.build/` | `./scripts/verify.sh --core`、`--feature`、`--filter` |
| 发布归档中间产物 | `build/archive/` | `archive.sh`、`build_with_provenance.sh` |
| 本地升级验证中间产物 | `build/upgrade/` | `prepare_local_real_upgrade.sh` |

构建入口通过 `scripts/build-support.py` 锁定 `build/.pipeline.lock`，跨进程串行执行。锁随进程关闭自动释放，**不要删除锁文件**，否则等待者可能锁定不同 inode。直接运行 Xcode GUI 或绕过脚本的命令不受此锁保护；维护前仍需检查进程。手动命令使用：

```sh
python3 scripts/build-support.py -- xcodebuild -project PaperRss.xcodeproj -scheme PaperRss -destination 'platform=macOS' -derivedDataPath "$PWD/build" build
```

Web 测试外层不持构建锁，避免内部发布脚本测试再次申请锁造成死锁；内部真正的构建仍加锁。SwiftPM 与 Web 测试的 TMPDIR 指向本次创建的 `.scratch/tmp/run-*`，正常结束、失败、INT 或 TERM 后回收。SIGKILL、断电可能留下目录，确认无人使用且只有生成产物后再人工处理，不自动扫描删除未知旧目录。

`dev.sh --isolated` 不传路径时自动创建并回收本次测试 HOME；显式传入路径时保留调用者数据，供重启持久化验收使用。`PAPERRSS_DEV_DERIVED_DATA` 仅用于确有必要的人工隔离，使用者负责检查、保全并回收额外编译目录。新用户测试继续复用构建，退出时回收运行数据。升级验证脚本默认回收自建临时工作区，显式 `--workspace`、`--keep` 的产物由调用者管理。

构建和测试报告写入 `.scratch/reports/run-*.log`，后续持锁运行清除超过 30 天的报告；不设置后台定时任务。只有本工具创建的普通日志文件参与轮转，符号链接、人工报告、历史研究、截图、补丁与运行数据备份不参与自动删除。需长期保存的报告应复制到命名清晰的人工归档位置。

发布产物与缓存分开：`dist/release/<tag>` 与 `dist/archive/<日期时间>-<进程号>` 长期保留，不参与自动轮转；`archive.sh` 不再清空 `dist`。归档、dSYM、安装包、签名与发布校验记录须由发布维护者确认后单独处理。

清理顺序：检查 Git 工作区及构建/应用进程；核对脚本输出路径、DerivedData 的 WorkspacePath、实际内容及依赖 checkout 改动；将不可重建的脚本、素材、符号与报告保全并生成原址映射；只删除已审核的生成缓存；重新构建。不要直接清理 `.git`，也不要以项目名匹配删除系统临时目录或共享模拟器。
