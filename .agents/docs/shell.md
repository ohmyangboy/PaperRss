# Shell 脚本与入口清单

本文是 `scripts/` 的索引：作用、依赖、频率与触发方式。新增或删除脚本时同步更新。

## 核心执行器

| 脚本 | 作用 | 依赖 | 触发 |
| --- | --- | --- | --- |
| `scripts/build-support.py` | 常规构建与测试共用执行器：泳道锁（app/tests）、超期缓存回收、报告轮转 | 无 | 被常规构建 / 测试入口复用；独立 WebKit 探针除外 |
| `scripts/verify.sh` | 分级验证：`--core` 仅 Core；`--feature` App 子集；`--filter <名>` 指定回归；无参数或 `--all` 全 Swift + Web + build + diff，默认关闭可见窗口；`--gui [过滤器]` / `--diagnostics` 显式窗口专项；另有 `--web`、`--build` 与三个 WebKit 探针入口 | `build-support.py`、swift、xcodebuild、node | 手动 / Agent / 发布构建；PR CI 调用 --core / --web |
| `scripts/dev.sh` | 编译并拉起 macOS App；`--icloud` 选择 CloudKit Development 签名并自动 provisioning；`--build-only` 只构建、不启动或关闭实例；`--isolated [目录]` 隔离本机数据和构建产物、保留日常实例，但仍共享桌面且不能与 `--icloud` 合用 | `build-support.py --lane app` | 手动交互 / 显式调试；构建检查用 `--build-only` |
| `scripts/clean.sh` | 预览回收构建缓存；`--apply` 持锁执行，`--keep-days N` 调固定根保留期 | `build-support.py --clean` | 手动；与构建入口的自动回收同逻辑 |

构建入口每次持锁运行都会顺带回收超期缓存，无需手动调度，也不设置后台定时任务。

四个 `test-*-webkit.sh` 探针独立调用 `swiftc` 并运行探针进程，不经过 `build-support.py`。执行时将完整标准输出与错误输出保存到 `build/reports/`，保留原始退出码，再读取摘要与失败上下文；不要假定统一执行器已自动生成报告。

## 缓存回收口径

| 类别 | 判定 | 保留期 |
| --- | --- | --- |
| 固定根 | `build/isolated`、`build/archive`、`build/upgrade`、`build/FreshLaunchTest`、主 DerivedData 组件（`Build`、`SourcePackages`、`Index.noindex`…）、`.build` | 3 天（`--keep-days` 可调） |
| 一次性根 | 其余形如 DerivedData 的目录（含 `info.plist` 且含 `Build`/`Logs`/`XCBuildData`），通常由 `PAPERRSS_DEV_DERIVED_DATA` 临时指定 | 1 天 |
| 不回收 | 锁文件、`build/visual-verification` 等素材、`dist/` 发布产物、报告 | — |

报告由构建入口轮转，保留 30 天。回收按泳道隔离：`app` 泳道只扫 `build/`，`tests` 泳道只扫 `.build/`，`--unlocked`（web 测试）不回收。

## 测试与验收

| 脚本 | 作用 | 依赖 | 触发 |
| --- | --- | --- | --- |
| `scripts/check-pr.mjs` | PR 正文结构、图片链接形态与 base/head 差异检查；本地夹具 `node --test Tests/pr-policy.test.mjs` | Node、Git | PR CI / 手动，读取事件 JSON |
| `scripts/test.sh` | 启动隔离数据的“新用户”实例（`build/FreshLaunchTest`），仍共享桌面；`--skip-build` 复用上次构建 | `build-support.py --lane app` | 手动（首启 / 新用户验收） |
| `scripts/test-mathjax-webkit.sh` | MathJax Tier3 探针（拉起 WebKit） | Xcode | `verify.sh --mathjax-webkit` 或手动 |
| `scripts/test-highlight-webkit.sh` | 代码高亮 Tier3 探针 | Xcode | `verify.sh --highlight-webkit` 或手动 |
| `scripts/test-reader-image-inversion-webkit.sh` | 深色纸面插图反相 Tier3 探针 | Xcode | `verify.sh --image-invert-webkit` 或手动 |
| `scripts/test-reader-media-webkit.sh` | Reader 媒体 Tier3 探针 | Xcode | 手动（无入口引用） |
| `scripts/archive.sh` | 归档 `.xcarchive`，不推送 | `build-support.py --lane all` | 手动 / 发布前 |

## 发布链路

| 脚本 | 作用 | 依赖 | 触发 |
| --- | --- | --- | --- |
| `scripts/release.sh` | 唯一发布编排入口：`build` / `verify` / `publish`，门禁输出 `[PASS]`/`[FAIL]`；`build` 执行全自动化回归，真实交互另行验收 | `verify.sh --all`、`sparkle/*` | 手动（维护者） |
| `scripts/build_dmg.sh` | 本地 `release.sh build` 的兼容代理；无参数 / `--help` 显示用法，接受 build 参数或显式 `build`，拒绝 `verify` / `publish` | `release.sh build` | 手动 |
| `scripts/sparkle/build_with_provenance.sh` | xcodebuild `archive` 并写入源码 provenance | `build-support.py --lane all` | 经 `release.sh build` |
| `scripts/sparkle/export_and_notarize.sh` | Developer ID 导出 + 签名 / 公证 / Staple / Gatekeeper 门禁（PASS3–6）；启动冒烟默认跳过，显式开关见下文 | Xcode | 经 `release.sh` |
| `scripts/sparkle/build_artifacts.sh` | 生成 ZIP、DMG 与 manifest | `build_with_provenance.sh`、`artifact_manifest.mjs`、`validate_artifacts.sh` | 经 `release.sh` |
| `scripts/sparkle/validate_artifacts.sh` | 产物与 manifest 一致性校验 | `artifact_manifest.mjs` | 经 `build_artifacts.sh` |
| `scripts/sparkle/artifact_manifest.mjs` | manifest 生成与校验（架构名归一化、签名、摘要） | `lipo`、`plutil`、`unzip`、`hdiutil` | 经上游脚本 |
| `scripts/sparkle/make_release_dmg.sh` | 从已 Staple 的 App 制作美化发布 DMG | Xcode | 经 `release.sh` |
| `scripts/sparkle/changelog.mjs` | 按版本精确抽取 CHANGELOG 中英文整节；Release/appcast 共用，缺段失败 | Node | `node scripts/sparkle/changelog.mjs CHANGELOG.md v1.5.1` |
| `scripts/sparkle/appcast.mjs` | stable / beta appcast 契约 | — | 经发布与升级脚本 |
| `scripts/sparkle/publish_release.sh` | 正式 Sparkle Release 编排；默认本地 dry-run，远程需双重确认 | `publish_release_dry_run.sh`、`publish_appcast_github.mjs`、`publish_homebrew.mjs` | 手动（维护者） |
| `scripts/sparkle/publish_release_dry_run.sh`、`scripts/sparkle/publish_release_dry_run.mjs` | 只读发布计划器 | — | 经 `publish_release.sh` |
| `scripts/sparkle/publish_appcast_github.mjs` | 受审计的 GitHub Contents 发布（两个 appcast feed） | GitHub API | 经 `publish_release.sh` |
| `scripts/sparkle/publish_homebrew.mjs` | Homebrew 同步，默认只检查本地产物 | git | 经 `publish_release.sh` |
| `scripts/sparkle/prepare_local_real_upgrade.sh` | 本地真实 N/N+1 升级验收环境（不碰 Release、appcast 与私钥） | `build-support.py`、`appcast.mjs`、`build_artifacts.sh`、`local_https_feed_server.mjs` | 手动（升级验收） |
| `scripts/sparkle/local_https_feed_server.mjs` | 本地临时 HTTPS feed 服务 | node | 经 `prepare_local_real_upgrade.sh` |
| `scripts/sparkle/test-local-upgrade.sh` | 执行 `Tests/sparkle-upgrade-recovery.test.mjs` | node `--test` | 手动 |
| `scripts/sparkle/release.env` | 发布凭据与配置，`release.env.example` 为模板（`.env` 不入库） | — | 手动维护 |

启动冒烟默认输出 `[SKIP]`，不代表启动已验证。只有 `PAPERRSS_RUN_LAUNCH_SMOKE=1` 且未设置 `PAPERRSS_SKIP_LAUNCH_SMOKE` 时才启动导出产物；使用临时 `CFFIXED_USER_HOME` 隔离数据，跟踪自己启动的 PID 并观察完整 3 秒，退出时只清理该进程。它仍可能显示窗口或取得焦点；需要无打扰时，在经过验证的独立图形会话中运行。存活探针不替代发布真实交互门禁。

## 按需：素材与预览

| 脚本 | 作用 | 触发 |
| --- | --- | --- |
| `scripts/preview_website.sh` | 本地预览 `website/` | 手动 |
| `scripts/capture-sponsors-preview.py` | 截取公开赞赏页名单，不修改源页面 | CI（deploy-pages，含每 12 小时 cron） |
| `scripts/requirements-sponsors-preview.txt` | `capture-sponsors-preview.py` 的 Python 依赖 | CI 安装 |
| `scripts/apply_icon.py` | 生成并写入 App 图标 | 手动（改图标时） |
| `scripts/render_macos_app_icon.swift` | 渲染 macOS 图标资源 | 手动 |
| `scripts/generate_dmg_background.swift` | 生成 DMG 背景图 | 手动 |

## 依赖主干

```
dev.sh ────┐
test.sh ───┤
verify.sh ─┼──► build-support.py ──► 泳道锁 + 缓存回收 + 报告轮转
archive.sh ┤                          └── xcodebuild / swift test / node --test
clean.sh ──┘

release.sh ──► verify.sh --all
           ├──► sparkle/build_with_provenance.sh ──► build_artifacts.sh
           │                                        ├── artifact_manifest.mjs
           │                                        └── validate_artifacts.sh
           └──► sparkle/publish_release.sh ──► publish_appcast_github.mjs
                                            └──► publish_homebrew.mjs
```

## CI 触发

| 工作流 | 触发 | 执行 |
| --- | --- | --- |
| `pr-checks.yml` | 面向 main 的 PR 创建、更新、重开、正文编辑、就绪 | 规范检查、Web/Core 实测及始终汇总的 PR gate |
| `deploy-pages.yml` | push `main` 且改动 `website/**`、本工作流或赞赏预览脚本 / 依赖；每 12 小时 cron；手动 | 更新 stars / 赞赏预览后部署 Pages，并同步官网服务器 |
| `sync-release-server.yml` | 正式 Release 发布（非 prerelease）自动触发；手动 | 经 SSH 同步发布服务器资产 |

deploy-pages 与 sync-release-server 两个 CI 工作流负责部署与分发，没有执行 `verify.sh`。它们运行成功不能替代代码回归或发布候选的交互验收。
