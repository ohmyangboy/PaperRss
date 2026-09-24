# 阅读正文中英文字体分别设置

- **Status**: accepted
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/27

## 已批准范围

阅读排版设置提供「西文字体 + 中文字体」两个独立字体项。只包含拉丁字形的英文字体可作为正文首选字体，缺字形时由用户指定的中文字体逐字符承接 CJK，不再落到不可控的系统默认字体。沿用现有本机字体搜索与选择交互，不新建字体发现机制。

## 实现约束

仍只保存系统字体族标识，不导入、下载、打包或同步字体文件；不改 CSP 远程字体策略。正文 CSS 栈按「西文字体 → 中文字体 → 现有系统 fallback」生成，不做 unicode-range 或逐字符 DOM 重写。标题与译文同样按「西文 → 中文 → fallback」分工（标题/译文回退既有 serif 栈，未配置字体时与升级前一致）；PaperRss 自有 UI、摘要卡与 TOC 保持既有字体策略。旧版本只有 `fontFamilyName` 的持久化数据必须无损读取，旧单字体选择的显示结果与升级前等价。运行时更换字体经现有 appearance 更新链路即时刷新，不重启、不重抓文章、不触发 AI 请求。

维护者补充要求（2026-09-23）：

- 标题与译文也要应用中英文区分规则。
- 设置项顺序：中文字体在前，西文字体在下。
- 三栏预览补充英文样例（莎士比亚「To be, or not to be…」）。

## 验收

可分别选择西文与中文字体，并在关闭设置页及重启后保持；只含拉丁字形的西文字体 + 中文字体时，中英混排正文均按预期可读；任一设置为系统默认时有稳定 fallback，无自定义字体时与旧版视觉兼容；含引号、反斜杠的字体族名不破坏注入的 CSS/JS；字号、行高、主题、双语翻译、选区解释与文章刷新无回归。

## 实施与验证记录（2026-09-23）

实现：

- `ReaderAppearance` 拆出 `latinFontFamilyName`（编码键沿用 `fontFamilyName`，保持旧数据可读与旧版本降级可读）与 `cjkFontFamilyName`，新增 `bodyFontStack` 生成「西文 → 中文 → 系统 fallback」并对引号/反斜杠转义、大小写不敏感去重；`AppStore` 提供 `setReaderLatinFontFamily` / `setReaderCJKFontFamily`。
- 设置页抽出复用的 `ReaderFontPicker`，排版面板按「中文字体」「西文字体」顺序提供两行；三栏预览按脚本分配字体，复现 WebView 的逐字符回退，并补充莎士比亚英文样例；并排预览区高度随新增控件从 300 调整到 380。
- `ArticleReaderView` 的 `--paper-body-font-family` 改用 `appearance.bodyFontStack`，CSS 首帧与 JS 同步链路共用同一份输出，切换字体即时刷新。
- 标题与译文：新增 `titleFontStack`（西文 → 中文 → 既有 serif 栈），文章标题、`h1`–`h6` 与标题旁译文统一使用 `--paper-title-font-family`；替换模式的译文继续复制源块计算后的字体栈，未配置字体时保持升级前的 serif 观感。

自动化验证：

- `./scripts/verify.sh --filter ReaderAppearanceTests`：15 项通过（含旧数据解码、正文字体栈与标题字体栈顺序、转义/去重、编码键兼容、Store 持久化、设置项顺序与预览样例断言）。
- `./scripts/verify.sh --core`：全量 Swift 测试通过。
- `./scripts/verify.sh --feature`：App 核心功能回归通过。
- `./scripts/verify.sh --web`：Web Reader / JS Bridge 测试通过（199 项）。
- `./scripts/dev.sh --isolated`：编译并拉起隔离实例，用独立 Bundle ID 与临时数据、本地 RSS 源中的中英混排文章完成真实界面观察。

手工验收（隔离实例，桌面 2，未触碰日常实例与数据）：

- 排版面板正确显示两项字体，搜索、选择与单项「系统默认」均可用。
- 西文 Iowan Old Style + 中文 Songti SC：拉丁使用 Iowan，中文使用宋体；混排段落中 `Typography` 与中文字形各自归位。
- 中文字体改为 PingFang SC 后，正文中文立即变为黑体、拉丁保持 Iowan；在第二个窗口打开同一篇文章时，从另一个窗口切换字体，阅读器即时刷新，未重启、未重抓文章。
- 中文字体设为系统默认后，中文回退系统默认字体，拉丁仍为 Iowan。
- 退出并重新启动后，两项设置保持，文章渲染与重启前一致。
- 补充要求复验（西文 Avenir Next + 中文 Songti SC）：设置项顺序为中文字体在上、西文字体在下；三栏预览的中文标题与正文用宋体、新增的莎士比亚英文样例用 Avenir Next，中英分工在预览中直接可见。
- 标题与译文的字体分工由确定性测试覆盖：`titleFontStack` 精确断言、阅读器 CSS 三处 `var(--paper-title-font-family)` 与 `h1 + .paper-rss-translation` 规则、替换模式复制计算后字体栈。阅读器实机标题复验因屏幕锁定未完成，标记为人工复核项。
- 遗留观察：返回设置页再回阅读器时偶发空白态，重新选择「今天」即恢复；该状态在本轮字体改动前同样出现过（添加订阅后首次打开时），未发现与字体设置相关。用辅助功能脚本驱动侧边栏行选择时遇到一次 SwiftUI `OutlineListCoordinator` 内部栈溢出崩溃，崩溃堆栈不含字体或阅读器代码；随后改用坐标点击完成验收。建议另行跟踪，不在本票范围。

界面证据（本地、未入库）：`build/visual-verification/issue27/`。
