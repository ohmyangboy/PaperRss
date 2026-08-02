# PaperRss

一个面向 macOS 与 iPhone 的本地优先 RSS 阅读器。它提供三栏阅读、OPML、RSS/Atom/JSON Feed、离线正文缓存，以及通过你自己的 OpenAI Chat Completions 兼容 API 手动生成翻译、上下对照、总结和解读。

## 当前实现

- macOS 三栏 / iPhone 折叠导航，深色模式、Dynamic Type、VoiceOver 标签和 Mac 快捷键。
- RSS、Atom、JSON Feed 解析；ETag / Last-Modified 条件刷新；稳定 ID 去重。
- OPML 导入导出，已读、收藏、本地 JSON 持久化和正文缓存。
- 网页正文的安全降级提取：先使用 Feed 正文，再从 `article` / `main` / `body` 提取纯文本；失败时回退 Feed 摘要并保留原网页链接。
- OpenAI 兼容 `POST /chat/completions`：SSE 流式输出优先，失败后自动重试普通响应；API Key 仅存当前 Mac 的本地应用配置，不参与 iCloud 同步。
- 全文翻译、逐段上下对照、总结与解读。翻译逐段保存，可在中断后复用已完成内容。
- iPhone 通过 `BGAppRefreshTask` 请求后台刷新；系统并不保证精确执行时间。

## 构建现状与 Xcode 27

此机器运行 macOS 27.0 beta，但安装的 Xcode 26.6 无法加载 `IDESimulatorFoundation`，即使运行 `xcodebuild -runFirstLaunch` 后仍然失败。这是工具链与系统的二进制不匹配，不是工程错误。

请从 Apple Developer 下载或更新到**与 macOS 27 对应的 Xcode beta / RC**，然后：

1. 打开 `PaperRss.xcodeproj`。
2. 在两个 target 选择你的 Development Team，并把 Bundle Identifier 改为你自己的反向域名。
3. Mac target 可以直接运行；iOS target 选择真机或模拟器运行。
4. 真机后台刷新需要在 Xcode 的 Signing & Capabilities 中确认 Background Modes。

当前代码仍可不依赖 Xcode 工程生成器地校验：

```sh
swift test
swift build --product PaperRssDesktop
```

## 启用 iCloud / CloudKit

项目提供了 `PaperRss/Resources/PaperRss.entitlements.template`。在 Xcode 中复制为每个 target 的 `.entitlements` 文件，修改容器 ID，并在 Signing & Capabilities 添加 iCloud + CloudKit。CloudKit 容器必须在你的开发者账号中创建；它不能由此仓库安全地代为创建。

代码已实现 CloudKit 私有数据库镜像：订阅、删除 tombstone、已读/收藏状态和 AI 成果会合并后写入一个私有 `CKAsset` 记录；按 `updatedAt` 取较新版本。网页正文、图片和 HTTP 缓存始终只保存在本地。完成签名配置后，在设置中开启“同步订阅、已读、收藏和 AI 结果”。没有可用 Team / 容器时应用会显示同步失败，而不会伪造“已同步”。

### 本地 API Key

API Key 只保存在当前 Mac 的 PaperRss 本地应用配置中，不参与 iCloud 同步、OPML 导出或日志记录；读取它不会触发 macOS 钥匙串密码弹窗。这样更适合个人设备上“配置一次、直接使用”的工作流。作为权衡，它不具备系统 Keychain 的静态加密保护；请不要在多人共用的 Mac 账户中保存长期有效的 Key。

## 隐私与限制

- AI 请求仅在你手动点击后发生。正文会发送给你配置的 API 服务，请只使用可信端点。
- 默认要求 HTTPS。局域网 HTTP 是高级选项；iPhone 建议改用 HTTPS 的局域网反向代理。
- 网页正文提取不是浏览器渲染；登录墙、付费墙和强动态站点会回退为 Feed 摘要。
- 本版本不包含账号系统、多人协作、商业支付或服务端全文搜索。
