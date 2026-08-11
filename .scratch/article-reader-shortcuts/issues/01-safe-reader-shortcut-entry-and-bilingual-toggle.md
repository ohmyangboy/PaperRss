# 01 — 建立无冲突的阅读快捷键入口并交付 C 对照翻译

**What to build:** 当文章已经打开时，用户可以在侧栏、文章列表或正文获得焦点的情况下裸按 C 切换逐段对照翻译；任何输入、划词或弹层上下文以及系统组合键都不会被阅读快捷键打断。

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] 仅 macOS 主阅读窗口且当前文章已打开时响应裸按 C，并忽略系统 key repeat。
- [x] Command、Option、Control、Shift 等修饰键组合不触发阅读动作，`⌘C`、`⌘V` 等系统行为保持正常。
- [x] 添加订阅、设置、原生文本输入、WebView 输入框、输入法组合、正文选区、划词操作条和 AI Popover 出现时不触发快捷键。
- [x] AI 忙碌时允许关闭已有对照翻译；开启新的对照翻译则给出提示且不取消当前 AI 请求。
- [x] 现有翻译控件显示 C 快捷键帮助和辅助功能提示，并覆盖纯 Swift 策略及 WebView 门禁回归测试。
- [x] 按仓库验证规则重新编译并启动应用验证。

**Answer:** 新增统一的裸键策略、主窗口监听与 WebView 门禁；Debug 应用实测 `⌘C/⌘V` 不触发阅读动作，添加订阅输入框可正常输入和复制粘贴。专项测试、完整 Swift 测试、构建与 `scripts/dev.sh` 均通过。
