# 01 — OPML 文件选择器 UTI 类型支持修复

**What to build:**
修复 macOS 文件选择面板中的文件类型过滤配置，确保用户在点击导入 OPML 时，系统文件选择器中的 `.opml` 和 `.OPML` 后缀文件不再显示为置灰状态，用户可以流畅地选择并读取这些文件。

**Blocked by:** None — can start immediately.

**Status:** completed

- [x] 用户在 macOS 系统文件选择框中打开目录时，`.opml` 及 `.OPML` 扩展名的文件处于正常高亮可点状态。
- [x] 选中 `.opml` 或 `.OPML` 文件并点击“Open/确定”后，程序能正确读取文件字节数据并传入 OPML 解析引擎。
