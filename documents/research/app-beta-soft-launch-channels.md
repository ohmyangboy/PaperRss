# PaperRss 测试期「低营销感」宣传与投稿渠道调研

> 研究日期：2026-08-11
>
> 产品基线：PaperRss v1.2.3，macOS 14+，中英文界面，GPLv3 开源，通过 GitHub Release 提供 DMG；当前安装包尚未 Apple 公证。产品事实来自仓库的 [README](../../README.md) 与 [English README](../../README_EN.md)。
> 证据原则：平台规则只引用平台官方帮助、官方投稿页、官方社区规则或版主公告；没有找到当前官方规则的渠道不按“可投稿”处理。

## 结论先行

PaperRss 现在最合适的不是一次“大发布”，而是做 **两轮小范围、作者本人在场的公开测试**：

1. **中文首轮**：V2EX「分享创造」+ 小众软件论坛「讨论分享 > alpha」。两个渠道都明确允许开发者分享正在做的东西，且可以把重点放在“请帮忙测试三个具体问题”，不必写成广告。
2. **英文首轮**：Show HN；如果已有 Reddit 社区积累，再择一发布到 r/MacApps。Show HN 官方明确接受早期但可运行的本人作品；r/MacApps 则有 10 点社区 karma、30 天频率、格式和披露门槛。
3. **长期可发现性**：先把 GitHub README、Release、Topics、反馈入口做好；等安装体验更稳，尤其完成 Developer ID 签名与 Apple 公证后，再提交 AlternativeTo 和 MacUpdate。
4. **内容型投稿**：少数派 Matrix 适合写“为什么做一个克制、纸感、本地优先的 RSS 阅读器”这类真实开发文章，不适合只贴下载链接。
5. **暂缓**：Product Hunt 留到真正正式发布；BetaList 当前所有投稿都收费；MacRumors 编辑投稿需要真正的新闻角度；Indie Hackers 本次未找到足够清晰的当前官方自荐规则。

当前最大的传播阻力不是文案，而是 **未公证安装包的信任成本**。Apple 明确说明，站外分发的 Mac 软件会由 Gatekeeper 检查 Developer ID，并默认要求公证；未签名/未公证软件需要用户覆盖安全设置，Apple 也提示这可能带来安全风险。[Apple：Safely open apps on your Mac](https://support.apple.com/en-us/102445)、[Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

因此：现在可以面向了解风险的开发者/开源用户做公开测试，但在 r/MacApps、MacUpdate、AlternativeTo 等更偏普通 Mac 用户的地方扩大传播前，优先完成公证。若暂时做不到，所有帖子都应正面说明“开源、未公证、下载与源码位置”，不要把 `xattr` 绕过命令藏在文末。

## 证据标签

- **✅ 官方确认**：平台当前官方帮助、投稿页或版主公告明确写出。
- **🟡 规则推断**：平台规则已确认，但对 PaperRss 的适配度、推荐写法和优先级是基于规则做出的判断。
- **⚪ 无法确认**：本次没有找到足够明确、足够新的官方规则；不据此执行。

## 推荐优先级

| 档位 | 渠道 | 现在是否执行 | 原因 |
| --- | --- | --- | --- |
| 首选 | GitHub README / Release / Topics / Discussions | 立即 | 是所有外部帖子共同指向的可信来源与反馈闭环，不是硬推广 |
| 首选 | V2EX「分享创造」 | 第一周 | 官方明确欢迎独立开发者发布新作；适合作者本人讲动机、限制和求反馈 |
| 首选 | 小众软件「讨论分享 > alpha」 | 第一周 | 官方明确把“想要测试”和初始 alpha 导向这里，甚至允许少写介绍 |
| 首选 | Show HN | 第二周 | 官方接受早期、可运行、本人开发、容易试用的项目，反馈导向强 |
| 条件首选 | r/MacApps | 第二周，满足账号门槛后 | 用户高度匹配，但规则严格；未公证会放大安全质疑 |
| 后续常驻 | AlternativeTo | 账号满一周、开放测试稳定后 | 允许开发者自己添加；开放 beta 可接受；适合长期被搜索到 |
| 后续常驻 | MacUpdate App listing | 公证后 | 官方支持 DMG/ZIP 直链，且要求事实性描述、避免推广话术 |
| 谨慎 | 少数派 Matrix / 开发者说 | 有完整文章角度再做 | 明确欢迎独立开发者自荐，但本质是写作投稿，不是短帖 |
| 谨慎 | r/macOS Developer Saturday | 需要额外样本时 | 官方允许周六自荐且接受非 App Store 开源项目，但这是明确的推广窗口 |
| 暂缓 | Apple TestFlight / Developer Forums | 以后配置 App Store Connect 时 | 是测试分发和反馈设施，不会自动带来测试者；当前项目也未走该分发链 |
| 暂缓 | Product Hunt | 正式 launch 再做 | 免费且允许 maker 自荐，但榜单式 launch 天然更像营销活动 |
| 不推荐 | BetaList | 不做 | 当前官方 FAQ 明确所有投稿都收费，没有免费投稿 |
| 不推荐 | MacRumors 普通论坛乱发帖 | 不做 | 普通规则禁止自荐和招募测试者；只能严格按开发者专用版规发自己的单一主题 |
| 无法确认 | Indie Hackers | 不做 | 未找到清晰、当前、官方的自荐与新账号门槛说明 |

## 中国大陆渠道

### 1. V2EX「分享创造」——当前最值得投

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | **很适合**。macOS 原生、RSS、开源、本地优先都与开发者社区相关，且已经有可直接下载运行的版本。🟡 |
| 允许怎样自荐 | V2EX 官方帮助明确写道，非常欢迎独立开发者把新作发布到「分享创造」；公司营销内容应放到「推广」。✅ |
| 营销感 | 低到中。讲“为什么做、现在有什么、哪里还不确定、具体希望测试什么”会比功能堆砌自然。🟡 |
| 门槛/审核 | 需要选择正确节点；若正文被判断为营销内容，管理员可移动到「推广」，多次忽略规则可能影响账号。✅ |
| 推荐发法 | 一篇主帖，附 1 张真实界面图、官网、GitHub、Release、三个具体测试问题；开发者在 24–48 小时内持续回答。不要请求点赞、Star 或“支持一下”。🟡 |
| 特别限制 | V2EX About 明确写“请不要把 AI 生成的内容发送到这里”。本报告中的模板只能作为信息清单，**最终帖子必须由开发者本人重新组织和亲自写作，不能原样粘贴**。✅ |
| 官方来源 | [V2EX 节点帮助：分享创造 / 推广](https://www.v2ex.com/help/node)、[About V2EX：禁止发送 AI 生成内容](https://global.v2ex.com/about) |
| 截至 2026-08-11 | **已核验，✅ 官方确认。** |

推荐节点只选 `/go/create`，不要同时发「macOS」「程序员」「分享发现」等多个节点。等有实质大版本再新发；小修复回原帖更新。

### 2. 小众软件论坛「讨论分享 > alpha」——比“发现频道投稿”更适合现在

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | **很适合当前测试阶段**。官方规则明确：如果“想要测试”，发「讨论分享」；随意分享或初始发布可用 `alpha` 分类。✅ |
| 允许怎样自荐 | `alpha` 分类可少写几个字，甚至不写介绍；但建议 PaperRss 仍说明 macOS 版本、未公证、源码和想测试的内容。✅ / 🟡 |
| 营销感 | 低。它就是面向讨论与测试的入口，不要求包装成编辑投稿。🟡 |
| 门槛/审核 | 论坛账号；`alpha` 不受发现频道的大部分投稿条款限制。✅ |
| 推荐发法 | 标题写“PaperRss alpha / 公开测试”，正文列出下载、源码、系统要求和三项测试请求，随后用回复更新修复结果。🟡 |
| 官方来源 | [小众软件联系页：分享软件前往投稿页](https://www.appinn.com/contact/)、[官方论坛内容提交规则，第 8、19 条](https://meta.appinn.net/t/topic/43728) |
| 截至 2026-08-11 | **已核验，✅ 官方确认。** |

### 3. 小众软件「发现频道」——稳定后再投，不要现在混用

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | 产品类型适合，但当前目标是测试，官方规则已明确导向「讨论分享」，所以现在不应投发现频道。✅ / 🟡 |
| 允许怎样自荐 | 允许开发者提交开源未上架应用，但需提供源码地址；需给官网/应用商店/下载链接。✅ |
| 营销感 | 中等偏低，属于编辑发现线；但已发布内容会自动同步到多个外部渠道，因此不适合把半成品反复发。✅ |
| 门槛/审核 | 全部人工审核；不保证收录。不得复制粘贴商店介绍、不得标题党、不得伪装成普通用户、一个产品一个帖子。✅ |
| 推荐发法 | 完成公证、安装无阻后，写事实性介绍：解决什么、与现有 RSS 阅读器的差别、系统要求、价格（免费）、源码与 DMG；不要写“史上最强”等。🟡 |
| 费用 | 普通发现投稿不等于付费推广；官方另设商业/高级推广与赞助插队，PaperRss 当前无需使用。✅ |
| 官方来源 | [小众软件官方论坛内容提交规则](https://meta.appinn.net/t/topic/43728) |
| 截至 2026-08-11 | **已核验，✅ 官方确认。** |

### 4. 少数派 Matrix /「开发者说」——以真实开发文章自荐

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | **有条件适合**。PaperRss 有明确审美、RSS 阅读和本地优先取舍，足以写成有观点的开发文章。只贴下载链接则不适合。🟡 |
| 允许怎样自荐 | 少数派官方曾明确欢迎独立开发者在 Matrix 撰文自荐数字产品；Matrix 主张真实观点、独立思考和实用价值。✅ |
| 营销感 | 写“我做了什么取舍、踩了什么坑、还没解决什么”时较低；写功能清单、二维码、推广通稿时很高，甚至可能被屏蔽。✅ / 🟡 |
| 门槛/审核 | 官方机制有过调整：2021 FAQ 仍写手动申请；2023 官方社区更新写发文已向所有少数派用户开放，新用户实名认证后发布需审核，成功发布 3 篇后成为正式作者。提交前应以当时界面为准。✅ |
| 推荐发法 | 选题建议：“我为什么又做了一个 RSS 阅读器：在纸感排版、AI 主动触发和本地优先之间的取舍”。正文 70% 讲问题与判断，30% 才介绍 PaperRss，并明确作者身份与测试状态。🟡 |
| 独家/授权 | 若走少数派的“投稿通道”，官方说明原则上要求独家首发并配合编辑；只做社区分享可走社区通道。不要把已在其他平台全文发布的文章再当独家稿投。✅ |
| 官方来源 | [Matrix 社区 FAQ](https://sspai.com/post/65521)、[2023 社区速递：发文机制](https://sspai.com/post/80643)、[独立开发者自荐产品](https://sspai.com/post/40262)、[共创体系：社区/投稿通道](https://sspai.com/post/72089) |
| 截至 2026-08-11 | **部分当前机制已确认；专门的开发者自荐说明较旧，提交前需复核当前入口。✅ / 🟡** |

## 海外渠道

### 1. GitHub——先把接住用户的地方做好

GitHub 不是一次性投稿站，但对开源 PaperRss 来说，它是所有宣传的底座。

| 能力 | 官方确认 | PaperRss 推荐做法 |
| --- | --- | --- |
| README | 官方建议写清项目用途、价值、上手方法、求助渠道和维护者 | 中英文 README 首屏保持一句定位、真实截图、系统要求、下载、未公证说明、反馈入口 |
| Release | Release 用于打包可部署的软件迭代、发布说明和二进制资产 | 将测试版本标为 pre-release（若确属测试）；每版写“请重点测试”与已知问题，不只写 changelog |
| Topics | 官方说明 Topics 帮助别人发现并参与项目，最多 20 个 | 使用少而准的主题，例如 `rss-reader`、`macos`、`swiftui`、`open-source`、`local-first`，不要堆无关关键词 |
| Discussions | 官方定位是公告、开放式讨论、方向和反馈；需仓库管理员启用 | 建立 `Feedback`、`Ideas`、`Show and tell` 或“公开测试反馈”类别；Issue 继续用于可复现 bug |
| Social preview | GitHub 允许自定义仓库链接在社交平台展开时的图片 | 使用真实 PaperRss 三栏截图和简短标题，不做促销海报 |

官方来源：[README](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)、[Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)、[Topics](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics)、[Discussions](https://docs.github.com/en/discussions/collaborating-with-your-community-using-discussions/about-discussions)、[Social preview](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview)。截至 2026-08-11 均为 **✅ 官方确认**；具体字段建议为 🟡 产品推断。

### 2. Hacker News「Show HN」——英文首选

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | **适合**。官方明确包括能在电脑上运行的作品，并接受早期、不够精致但已经可试用的项目。✅ |
| 允许怎样自荐 | 必须是本人参与开发、本人在场讨论、用户能实际试用；标题以 `Show HN:` 开头。✅ |
| 营销感 | 低到中。HN 要的是“show + discussion”，不接受只有注册页、落地页或募资页，也不欢迎把 HN 主要当推广渠道。✅ |
| 门槛/审核 | 项目应非琐碎、已经可运行、尽量无注册/邮箱障碍；例行小版本更新通常不够再次发 Show HN。✅ |
| 推荐发法 | 链接到英文 README 或官网；第一条评论解释为什么做、技术取舍、已知限制和三个想听意见的问题。发帖当天留出时间回复。🟡 |
| 禁止事项 | 不让朋友集中点赞/评论，不求 upvote，不写夸张标题，不删除重发；HN 还明确禁止生成式/AI 编辑后的评论内容，因此最终帖子与回复应由开发者本人写。✅ |
| 官方来源 | [Show HN Guidelines](https://news.ycombinator.com/showhn.html)、[Hacker News Guidelines](https://news.ycombinator.com/newsguidelines.html) |
| 截至 2026-08-11 | **已核验，✅ 官方确认。** |

### 3. Reddit r/MacApps——高度匹配，但先成为社区成员

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | 受众很匹配，开源和 Mac 原生是优势；但未公证会让安全讨论盖过产品反馈。🟡 |
| 允许怎样自荐 | 允许开发者 App 帖，但有格式与频率限制。Reddit 全站规则禁止重复或无请求的大规模推广，并要求主要发布自有链接的账号控制频率。✅ |
| 营销感 | 中。按规则写成短、透明、可比较的测试帖可以降低营销感；新号直接丢链接很容易被移除。🟡 |
| 当前门槛 | 需要至少 10 点 r/MacApps 社区 karma；开源标题加 `[OS]`；2026-02 新版规把频率收紧为“每位开发者 30 天一个 App 帖”；开源 GitHub 账号需有 30 天以上历史且有真实代码。✅ |
| 必填内容 | 问题、与主要替代品的区别、价格 + 链接、changelog/roadmap、AI 使用披露；官方建议少于 200 词。✅ |
| 推荐发法 | 先用一周真诚参与其他 Mac App 讨论，达到门槛后发一篇 `[OS]` 测试帖；披露“我是开发者”、免费/GPLv3、未公证、源码可审查，并请求安装、OPML 导入、长文/AI 三类反馈。🟡 |
| 官方来源 | [r/MacApps 2026 发帖指南](https://www.reddit.com/r/macapps/comments/1qghsc5/new_post_guidelines_and_updates_on_rmacapps/)、[2026 Phase 2 要求](https://www.reddit.com/r/macapps/comments/1r6d06r/new_post_requirements_to_combat_low_quality/)、[Reddit Spam Policy](https://support.reddithelp.com/hc/en-us/articles/360043504051-Spam) |
| 截至 2026-08-11 | **已核验版主最新公告，✅ 官方社区规则。发帖当天仍应再看侧栏规则。** |

### 4. Reddit r/macOS「Developer Saturday」——只在指定时间补充触达

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | 受众相关，但社区主体是 macOS 综合讨论，不是 App 发布站；只适合作为已经完成一轮测试后的补充渠道。🟡 |
| 允许怎样自荐 | 版主公告规定 App 与开发者自荐只在每周六 `00:00–23:59 UTC` 开放，每位用户每周最多一帖；需要披露自己是开发者、解释 App 的用途，不能只丢链接。✅ |
| 非 App Store App | 公告明确欢迎 GitHub 仓库；版主在同帖回复确认，非 App Store App 也可在周六发布。当前仍应正面披露未公证状态。✅ / 🟡 |
| 营销感 | 中。平台把它定义为集中开放的推广时段，所以虽然合规，却不如 Show HN 或 Appinn alpha 符合“低营销感”。🟡 |
| 推荐发法 | 不与 r/MacApps 同日重复同一正文；只在需要额外 macOS 安装样本时选择，并用真实截图、测试问题与开发者披露替代口号。🟡 |
| 官方来源 | [r/macOS：Developer Saturday 版主公告](https://www.reddit.com/r/MacOS/comments/1rsxzup/new_policy_introducing_developer_saturday/) |
| 截至 2026-08-11 | **已核验 2026 版主公告，✅ 官方社区规则；发帖当天仍需复核侧栏。** |

### 5. AlternativeTo——适合稳定开放测试后的长期目录

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | **适合**。PaperRss 有英文界面、开源许可证和明确同类产品，可作为 RSS 阅读器替代项。✅ / 🟡 |
| 允许怎样自荐 | 官方 FAQ 明确允许用户自己“Suggest new application”，开发者也可申请其产品页管理权。✅ |
| 营销感 | 低。它更像结构化软件目录，而不是发布日活动。🟡 |
| 门槛/审核 | 新账号创建一周后才能提交；全部内容需英文；管理员审核通常需要数天到一周；封闭 beta 不接受，开放 beta 或容易取得访问权的测试版可能接受。✅ |
| 推荐发法 | 在完成至少一轮公开测试后提交；描述只写功能与差异，关联 NetNewsWire、Reeder、Feedly 等实际替代关系。不要在简介塞链接或 UTM，官方通常不允许。🟡 |
| 官方来源 | [AlternativeTo FAQ](https://alternativeto.net/faq/) |
| 截至 2026-08-11 | **已核验，✅ 官方确认。** |

### 6. MacUpdate——公证后提交结构化 App listing

| 项目 | 判断 |
| --- | --- |
| 适不适合 PaperRss | 类目高度匹配；MacUpdate 有 Newsreaders / RSS 分类，并接受站外 DMG、PKG、ZIP 下载链接。✅ |
| 允许怎样自荐 | 官方有 Add App / New App Submission Guidelines，要求 App 名称、下载 URL、产品页、价格、短描述、详细描述、版本变化和系统要求。✅ |
| 营销感 | 低到中。官方明确要求描述避免推广话术和价格信息（价格另填字段），适合事实性登记。✅ |
| 门槛/审核 | 需完整稳定的产品页和下载；本次未找到官方承诺的审核时长或免费/付费分发保证。⚪ |
| 推荐发法 | 完成签名/公证后再投；下载 URL 指向版本化 DMG 或官方 Release，描述里正面写 GPLv3、本地优先、macOS 14+ 和 AI 需用户自行配置。🟡 |
| 官方来源 | [MacUpdate New App Submission Guidelines](https://www.macupdate.com/help/submit-app) |
| 截至 2026-08-11 | **提交字段已确认；审核、收费与推荐效果无法确认。✅ / ⚪** |

### 7. Apple TestFlight + Developer Forums——测试基础设施，不是自然获客渠道

Apple 官方确认：TestFlight 支持 macOS beta 分发、公开链接、最多 10,000 名外部测试者、90 天 build 有效期、崩溃/截图/文字反馈；首个外部测试 build 需要 Beta App Review。Apple 还在 Developer Forums 的 TestFlight 标签下明确提供“分享公开链接”的二级渠道。[TestFlight Overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)、[Apple TestFlight](https://developer.apple.com/testflight/)、[Developer Forums: TestFlight](https://developer.apple.com/forums/tags/testflight)

但它不适合 PaperRss 当前立即执行：

- 当前项目通过 GitHub DMG 分发，未配置 App Store Connect / TestFlight 链；
- TestFlight 能降低安装和反馈摩擦，却不会自动给公开链接带来测试者；仍需从社区把人带过去；
- 为了“宣传”而迁移分发链会扩大当前任务范围。

结论：**暂缓，✅ 官方能力确认；“不是获客社区”是 🟡 产品推断。** 将来若已有 Apple Developer Program、签名和 App Store Connect 计划，再把它作为统一测试分发入口。

### 8. Product Hunt——正式发布时再用

Product Hunt 官方允许 maker 自己提交产品，使用个人账号，提交和使用本身免费；社区以每日产品榜单、投票和评论为核心。官方同时禁止付钱请人 hunt、购买流量或操纵排名，并建议账号至少提前一周加入社区。[Product Hunt Launch Guide](https://www.producthunt.com/launch)、[How Product Hunt works](https://www.producthunt.com/launch/how-product-hunt-works)、[Sharing your launch](https://www.producthunt.com/launch/sharing-your-launch)

它符合“可以自荐”，但不符合用户当前想要的“简单投一下、不要明显营销”：准备 launch 素材、同日互动与榜单竞争本身就是高强度发布行为。建议等到：

- 安装已签名/公证；
- 英文产品页和 onboarding 稳定；
- 已经从两轮测试中确认核心定位；
- 有明确的正式版发布节点。

结论：**暂缓，✅ 官方规则确认；优先级为 🟡 产品推断。**

### 9. BetaList——当前不推荐

BetaList 官方支持仍在 pre-launch 或刚发布的技术 startup，但当前 FAQ 明确：**所有投稿都收费，没有免费提交选项**；不同计划主要区别在上线速度和 newsletter inclusion，编辑仍保留拒绝权。[BetaList Support & FAQ](https://betalist.com/support)、[Submission Guidelines](https://betalist.com/criteria)、[Submission Terms](https://betalist.com/terms/submissions)

PaperRss 是可下载的开源 Mac App，当前目标是收集少量高质量测试反馈，不需要为了目录曝光付费。结论：**不推荐，✅ 官方确认。**

### 10. MacRumors——论坛可按开发者特例发，但普通乱投不行；编辑 tip 仅限真正新闻

MacRumors 普通论坛规则禁止以宣传产品为目的加入、禁止招募产品测试者、禁止在普通讨论中自荐；但其单独的 Software Developer Guidelines 允许 Mac 软件开发者在指定 Mac Applications 版块为自己的产品开一个主题、披露身份、讨论产品并招募 beta testers，要求同一产品/大版本最多一个主题，后续小更新回原帖。[MacRumors Forum Rules](https://forums.macrumors.com/threads/macrumors-forum-rules.1672419/)、[Guidelines for Software Developers](https://forums.macrumors.com/threads/guidelines-for-software-developers.1677170/)

相关专门指南正文较旧，实际使用前应复核 Help Center，并只在指定版块发一个透明主题。编辑线的 [Submit a Tip](https://www.macrumors.com/share.php) 收的是 news/rumor item，不保证收录 App；普通 beta invite 不应包装成新闻。结论：**论坛开发者特例为 ✅，当前优先级谨慎；编辑收录效果 ⚪ 无法确认。**

## 不推荐的做法

1. **同一天复制同一正文到多个论坛。** Reddit 明确把重复、大规模曝光行为列为 spam 风险；社区用户也很容易识别跨站模板。
2. **伪装成用户推荐自己的产品。** 小众软件明确禁止“假装用户”，MacRumors 视为 shilling，AlternativeTo 也会封禁用个人资料打广告的账号。
3. **请求点赞、Star、顶帖或集中评论。** Show HN 明确禁止请求朋友 upvote/comment；Product Hunt 禁止购买 hunt/流量和操纵排名。
4. **把 AI 生成文案原样发到 V2EX/HN。** V2EX 明令禁止 AI 生成内容，HN 也禁止生成式/AI 编辑后的评论；最终文字必须来自开发者本人。
5. **弱化未公证事实。** 这会在 Mac 用户社区迅速损伤信任。应把开源、签名/公证状态和安装方式放在下载按钮附近。
6. **把测试版写成正式发布，或为曝光付费插队。** Show HN 接受早期作品，Appinn 有 alpha；BetaList、小众软件商业推广和 Product Hunt 广告都不是此阶段必需。
7. **未经规则确认去泛社区撒链接。** 有入口不等于允许自荐；先看当天规则，无法确认就问版主或不发。

## 低打扰的两周执行清单

### 第 1–2 天：把反馈入口准备好

- [ ] README 首屏同时给出：一句定位、macOS 14+、免费开源、真实截图、最新版下载、未公证说明、反馈入口。
- [ ] Release notes 增加“这版想请你测试什么”和“已知问题”；如果确属测试版，考虑使用 GitHub pre-release 标记。
- [ ] 检查 GitHub Topics，只保留真正相关的 5–8 个；整理 Discussions 或区分 bug/建议 Issue 模板。
- [ ] 准备一张真实三栏截图，不做带口号的营销海报。
- [ ] 明确三个反馈问题：安装/首次启动、OPML 导入与刷新、长文阅读/AI 功能；若短期无法公证，README 与帖子都直接说明。

### 第 3 天：中文首帖，只发 V2EX

- [ ] 开发者本人根据下方“信息骨架”重新写一篇 200–400 字的帖子，不能复制 AI 生成模板。
- [ ] 发布到「分享创造」，附官网、GitHub、Release 和一张截图。
- [ ] 当天与次日回答问题、记录可复现 bug，不在其他中文社区同步相同正文。

### 第 5 天：小众软件 alpha

- [ ] 根据 V2EX 第一轮反馈修掉最明显的安装/崩溃/数据问题。
- [ ] 发到「讨论分享 > alpha」，文案比 V2EX 更短，重点列版本、下载、源码、未公证和测试请求。
- [ ] 后续小更新在原帖回复，不重复投发现频道。

### 第 6–7 天：反馈收口

- [ ] 将反馈按安装信任、Feed 兼容、性能、阅读体验、AI 配置、功能建议归类，并发布小版本或明确回复。
- [ ] 记录每个渠道带来的下载、Issue/Discussion、可复现 bug、有效对话数。GitHub Releases API 提供 release asset 的 `download_count`，但不必做跨站追踪或虚荣指标目标。[GitHub Releases API](https://docs.github.com/en/rest/releases/releases)

### 第 8–9 天：准备英文

- [ ] 修正英文 README 的安装、未公证和反馈说明。
- [ ] 至少准备 1–2 张英文界面的真实截图；当前英文 README 明示所用截图仍为中文界面。
- [ ] 选择 **Show HN 或 r/MacApps 其一作为首个英文渠道**。
- [ ] 若 Reddit 账号没有 10 点 r/MacApps 社区 karma，不为发帖刷 karma；先正常参与讨论，或本轮只发 Show HN。
- [ ] 最终英文正文由开发者本人写；可用下方模板核对信息是否齐全，但不要照抄。

### 第 10 天：英文首帖

- [ ] Show HN：标题以 `Show HN:` 开头，链接直接可试用；发帖后留时间交流，不请求 upvote。
- [ ] 或 r/MacApps：满足 `[OS]`、价格、changelog、AI 使用披露与频率规则；正面写未公证。
- [ ] 不在同一天继续发 r/macOS、Product Hunt、AlternativeTo。

### 第 11–12 天：建立长期目录入口

- [ ] 现在就注册 AlternativeTo 账号，满一周且开放测试稳定后提交英文条目。
- [ ] 若已经完成 Developer ID 签名与公证，提交 MacUpdate；若没有，先暂缓。
- [ ] 不提交 BetaList，不准备 Product Hunt launch。

### 第 13–14 天：决定下一轮，而不是继续撒渠道

- [ ] 总结最常见的三个问题和已修内容；只有已有真实取舍和反馈故事才考虑少数派长文。
- [ ] 下轮只选一个目标：修安装与信任、扩大普通用户，或寻找重度 RSS 用户。
- [ ] 若第一轮反馈已足够，停止发帖，专心迭代；“没有继续投稿”也是有效选择。

## 克制的投稿信息骨架

> **重要：以下是信息骨架，不是可直接发布的成稿。** V2EX 明确禁止发送 AI 生成内容，HN 也禁止生成式/AI 编辑后的评论。开发者需要用自己的经历和说话方式重新写，尤其不要复制标题和整段正文。

### A. 中文论坛骨架（V2EX「分享创造」）

> 做了一个 macOS 原生 RSS 阅读器 PaperRss，想请大家帮我测一下安装和长文阅读

**正文应包含：**

1. 真实动机：自己日常订阅多，希望有一个安静的三栏阅读器，同时只在需要时主动调用 AI。
2. 当前能力：macOS 14+；RSS/Atom/JSON Feed、OPML、中英文界面；本地优先；可配置 OpenAI 兼容接口；GPLv3。
3. 当前状态：早期公开测试；目前通过 GitHub Release 发 DMG；**尚未 Apple 公证**，源码公开，可先审查再决定是否安装。
4. 只问三个具体问题：DMG 安装与首次启动、OPML/Feed 刷新、长文阅读与划词操作。
5. 链接：官网、GitHub、最新版 Release、反馈入口。
6. 结尾：只写“如果你正好还在用 RSS，愿意的话请告诉我遇到的具体问题”；不要写“求 Star / 求支持 / 冲榜”。

### B. 英文 Show HN 骨架

> Show HN: PaperRss – a local-first, open-source RSS reader for macOS

**Opening comment should cover, in the maker's own words:**

- why another RSS reader was worth building, and the tradeoff between quiet three-column reading, local-first storage, and explicit rather than always-on AI;
- what works today, plus source, website, and a direct no-account GitHub Release;
- honest limitation: the current DMG is not Apple-notarized yet;
- three concrete questions about installation, feed compatibility, and long-article reading;
- availability to answer technical and product questions in the thread.

Do not ask for votes, repost a routine patch release, or use a polished launch slogan. The HN submission and every reply should be written by the developer, not pasted from this document.

### C. 短测试邀请骨架（小众软件 alpha / 已有用户群）

> PaperRss v1.2.3 目前做一轮 macOS 公开测试。它是一个免费开源的三栏 RSS 阅读器，支持 RSS/Atom/JSON Feed、OPML 和按需 AI 摘要/划词操作。现在最想确认的是：首次安装、OPML 导入、长文阅读是否稳定。
>
> 适用系统：macOS 14+
>
> 当前限制：安装包尚未 Apple 公证；源码与构建说明公开，请了解后再安装。
>
> 下载 / 源码 / 反馈：分别给出官方链接。
> 如果遇到问题，请附 macOS 版本、Feed 地址（可公开时）和复现步骤。

同样，发到 V2EX 时不能直接使用这段；在小众软件 alpha 或自己的既有用户群中，也建议用开发者自己的语气缩短重写。

## 如何判断这两周是否值得继续

不要用“曝光量”作为唯一答案。记录每渠道的 Release 下载、可复现 bug、真实场景反馈、安装/未公证问题占比、回复修复投入，以及哪些用户回来第二次反馈，不预设效果承诺。

如果大多数反馈停在“无法放心安装”，下一步不是继续换平台，而是先完成签名与公证。如果安装顺利但没人持续使用，再回到产品定位和首次体验，不要用更多投稿掩盖留存问题。

## 核验边界与待复核项

### 已由官方规则确认

- V2EX 的分享/推广节点与禁 AI 内容规则；小众软件测试/alpha/发现频道规则；少数派真实内容与自荐边界。
- GitHub README、Release、Topics、Discussions 与 social preview 的用途；Show HN 对早期可运行本人项目及禁拉票规则。
- r/MacApps、r/macOS 的 2026 版主规则与 Reddit 反 spam 规则；AlternativeTo 的账号、英文、开放 beta 和审核要求。
- MacUpdate 提交字段；TestFlight 的 macOS beta、公开链接、审核、人数与反馈能力。
- Product Hunt 允许 maker 免费自荐；BetaList 投稿全部收费；MacRumors 普通限制、开发者特例与 tip 表单存在。

### 基于规则做出的推断

- PaperRss 当前渠道排序、营销感等级和两周节奏。
- 未公证应成为扩大普通用户前的优先阻力，而不是阻止所有开发者测试。
- GitHub、V2EX、Appinn alpha、Show HN 组合比一次性 Product Hunt launch 更符合“低营销感”。
- 少数派应写开发取舍文章，MacUpdate/AlternativeTo 应等安装体验更稳。

### 当前无法确认

- 任一渠道能带来多少下载、留存或有效反馈；本报告不提供流量数字或效果承诺。
- MacUpdate 当前普通 App listing 的审核时长、是否收取费用、是否一定展示。
- MacRumors 编辑是否会报道普通 beta App；tip 表单存在不等于会收录。
- Indie Hackers 当前官方自荐规则与新账号门槛。
- 少数派 2017 年“开发者说”专门自荐入口在 2026 年是否仍完全按原流程运作；提交前应查看当前界面。
- 各 Reddit 社区侧栏规则在实际发帖当天是否又有调整；版主规则经常迭代，必须当天复核。
- PaperRss 未来是否采用 TestFlight、Mac App Store 或 Developer ID 站外分发；这是产品/发布决策，不是本研究擅自确定的范围。

## 最终建议

如果只做三件事：

1. 先把 GitHub 的测试说明、未公证提示和反馈入口整理清楚；
2. 第一周由开发者本人分别写一篇 V2EX「分享创造」和小众软件 `alpha`，不跨站复制；
3. 修完第一轮最明显问题后，第二周只发一个英文渠道，优先 Show HN；已有 Reddit 社区积累时再选 r/MacApps。

这是目前最符合 PaperRss 阶段、产品气质和“简单投稿、不要明显营销”的路径。Product Hunt、付费推广和大范围媒体投递都可以等到安装信任与产品定位更稳定后再决定。
