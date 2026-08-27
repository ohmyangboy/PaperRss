# PaperRss 内容与版权说明 / Content and Copyright Notice

**生效日期 / Effective date:** 2026-08-27  
**权利事项联系 / Rights contact:** [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com)

## 1. 产品定位 / Purpose of PaperRss

PaperRss 是供用户管理订阅并进行个人阅读的本地优先 RSS 客户端，不是内容发布平台、公共全文数据库或内容授权机构。

PaperRss is a local-first RSS client for managing subscriptions and personal reading. It is not a publishing platform, public full-text database, or content licensing authority.

## 2. 内容来源与按需正文提取 / Content sources and on-demand extraction

PaperRss 优先使用 RSS、Atom、JSON Feed 或用户连接的兼容服务主动提供的标题、摘要和正文。Feed 内容不足时，用户打开相应文章可能使客户端向 Feed 中标注的公开文章 URL 发出普通网页请求，在用户设备上提取适合阅读的正文并生成本地缓存。

PaperRss first uses titles, summaries, and content supplied through RSS, Atom, JSON Feed, or a compatible service connected by the user. If a feed supplies insufficient content, opening the article may cause the client to make an ordinary request to the publicly accessible article URL identified by the feed, extract readable content on the user's device, and create a local cache.

该功能面向按需个人阅读。当前项目不运营集中抓取文章正文、建立跨用户全文库或向公众重新发布文章的 PaperRss 服务。网页请求失败或受到访问限制时，客户端应回退到 Feed 内容或让用户打开原网页；PaperRss 不提供专门绕过登录、付费墙、验证码或其他访问控制的功能。

This feature is intended for on-demand personal reading. The project does not currently operate a PaperRss service that centrally extracts article bodies, builds a cross-user full-text corpus, or republishes articles to the public. If a page request fails or is access-restricted, the client should fall back to feed content or let the user open the original page. PaperRss does not provide a feature specifically designed to bypass login requirements, paywalls, CAPTCHAs, or other access controls.

## 3. 权利归属 / Ownership

- 第三方文章、图片、音视频、标题、标识和商标的权利归其作者、出版者或其他权利人所有。
- 内容出现在 Feed、公开网页或 PaperRss 阅读器中，不表示相关权利已转让给 PaperRss，也不表示权利人放弃版权。
- PaperRss 的 GPL-3.0 开源许可证只适用于 PaperRss 项目代码及明确标注适用该许可证的项目材料，不适用于用户订阅或读取的第三方内容。
- 阅读器尽可能保留文章标题、作者、Feed 来源和原文链接；第三方页面或 Feed 中的版权与许可证声明仍然适用。

- Rights in third-party articles, images, audio, video, titles, identifiers, and trademarks remain with their authors, publishers, or other rightsholders.
- Availability through a feed, public webpage, or the PaperRss reader does not transfer those rights to PaperRss or mean that copyright has been waived.
- PaperRss's GPL-3.0 license applies only to PaperRss project code and project materials expressly licensed under it. It does not apply to third-party content that a user subscribes to or reads.
- The reader aims to retain the article title, author, feed source, and original link. Copyright and licensing notices supplied by the publisher remain applicable.

## 4. 用户责任 / User responsibilities

用户应当：

- 仅订阅、访问和使用自己有权访问的 Feed、账户及内容；
- 遵守适用法律以及内容提供者有效的许可和服务条款；
- 不使用 PaperRss 绕过访问控制，或批量导出、公开分享、出售、训练、建立搜索库或重新发布无权使用的完整文章；
- 在把文章内容提交给第三方 AI 服务前，确认其有权这样做，并审查服务商条款；
- 对保密内容、个人信息、付费内容和未公开内容采取额外谨慎措施。

Users should:

- subscribe to, access, and use only feeds, accounts, and content they are authorized to access;
- comply with applicable law and valid licenses and terms imposed by content providers;
- not use PaperRss to bypass access controls or to bulk-export, publicly share, sell, train on, index, or republish complete articles without permission;
- confirm that they are permitted to submit article content to a third-party AI provider and review that provider's terms; and
- exercise additional care with confidential content, personal information, paid content, and unpublished material.

## 5. 本地缓存 / Local caching

网页正文缓存用于提高同一用户设备上的阅读和离线体验，不构成公开传播许可。用户可在 PaperRss 设置中清除网页正文缓存。删除缓存不会删除原网站、Feed 服务商或第三方 AI 服务已经独立处理的数据。

Extracted web content is cached to improve reading and offline access on the same user's device. A local cache is not permission to distribute the content publicly. Users can clear extracted article caches in PaperRss Settings. Clearing a cache does not delete data independently processed by the publisher, feed service, or third-party AI provider.

## 6. 权利人请求 / Rightsholder requests

如果你认为 PaperRss 的默认行为或项目材料不当涉及你有权控制的内容，请发送邮件至 [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com)，并尽量提供：

1. 权利人或授权代表的姓名及联系方式；
2. 相关作品、Feed、文章 URL 或域名；
3. 你的权利基础或授权关系说明；
4. 希望采取的措施，例如更正署名、移除项目材料、停止默认提取或加入域名屏蔽；
5. 足以协助核实请求的其他信息，但不要发送无关的敏感个人信息。

项目维护者会善意审查可核实的请求，并根据具体情况采取更正、移除、技术限制或在后续版本中加入域名例外等合理措施。PaperRss 无法删除由原网站、第三方 Feed/AI 服务或用户自行控制的副本。

If you believe PaperRss's default behavior or project materials improperly involve content that you control, email [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com) and, where possible, provide:

1. the name and contact details of the rightsholder or authorized representative;
2. the relevant work, feed, article URL, or domain;
3. the basis of your rights or authority;
4. the action requested, such as correcting attribution, removing project material, disabling default extraction, or adding a domain block; and
5. other information reasonably needed to verify the request, without unrelated sensitive personal information.

The maintainer will review verifiable requests in good faith and may take reasonable action such as correction, removal, technical restriction, or a domain exception in a later version. PaperRss cannot delete copies controlled by the original publisher, a third-party feed or AI service, or an individual user.

## 7. 法律边界 / Legal scope

本说明用于透明解释产品行为和项目政策，不构成对第三方内容的授权，也不是法律意见。版权例外、网站条款及自动访问规则会因国家、内容、访问方式和用途而异；发生具体争议时应取得专业法律意见。

This notice explains product behavior and project policy. It does not grant rights in third-party content and is not legal advice. Copyright exceptions, website terms, and automated-access rules vary by jurisdiction, content, access method, and purpose. Obtain professional legal advice for a specific dispute.

