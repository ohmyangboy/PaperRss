# FreshRSS API 接口规范与 iOS/macOS 客户端集成方案调研

> 研究日期：2026-08-13  
> 适用对象：PaperRss (iOS/macOS Swift) 架构师与开发团队  
> 文档状态：完成 / 规范调研报告  

---

## 摘要与核心结论

随着自托管（Self-Hosted）RSS 服务的普及，**FreshRSS** 已成为极具代表性的开源 Feed 聚合平台。为了让 **PaperRss**（iOS/macOS 客户端）具备与 FreshRSS 的无缝双向同步能力，本报告对 FreshRSS 的开放接口规范、身份验证机制、数据同步范式以及客户端集成踩坑点进行了深入研究。

### 核心结论速览

1. **协议选择**：**强烈推荐并必须采用 Google Reader API 兼容层（`greader.php`）**。该 API 已成为 RSS 领域的*事实行业标准*（De Facto Standard），支持细粒度分页、流式增量更新与 Tag 状态标记；而 Fever API（`fever.php`）已属于废弃/遗留协议，存在数据传输冗余大、无法细粒度分页及安全防范较差的缺陷。
2. **鉴权机制**：FreshRSS 采用两级安全保障。网页端设置必须开启**“允许 API 访问”**，且客户端连接时**严禁使用网页主密码**，必须使用在账户设置中生成的 **API Password（应用专用密码）**。认证流程优先使用 `ClientLogin` 方式获取 `Auth` 令牌，并在后续 HTTP 请求头中携带 `Authorization: GoogleLogin auth=<token>`。
3. **数据同步与 Tag 系统**：FreshRSS 完全沿用了 Google Reader 的 Tag 映射模型。已读、星标等状态均通过 `user/-/state/com.google/read` 和 `user/-/state/com.google/starred` 等系统标签进行表达，通过 `/reader/api/0/edit-tag` 接口实现增与删。增量同步依靠 `ot`/`nt`（时间戳过滤）与 `c`（Continuation token）实现流畅翻页。
4. **客户端适配重难点**：
   - 需适配各种子目录部署路径（如 `/freshrss/api/greader.php`），处理 Nginx 代理下的 `PATH_INFO` 解析丢失问题；
   - 在 Swift 中需要为 `ClientLogin` 和 `edit-tag` 等接口处理纯文本（`text/plain`）响应而非强制 JSON 解析；
   - 文章 ID 必须全程使用 `String` 存储与传输，切勿解析为固定位数的整数；
   - 支持自签名证书与 ATS 网络安全策略配置。

---

## 一、 FreshRSS 常用 API 机制与端点

### 1.1 Google Reader API (`greader.php`) 与 Fever API (`fever.php`) 的对比与选择

FreshRSS 内置了两种第三方客户端兼容接口，位于其 `p/api/` 目录下。下表总结了二者的关键差异：

| 评估维度 | Google Reader API 兼容层 (`greader.php`) | Fever API 兼容层 (`fever.php`) |
| :--- | :--- | :--- |
| **生态地位与推荐度** | **首选 / 工业标准**（NetNewsWire, Reeder, Read You, FeedMe 等普遍优先采用） | 废弃 / 遗留兼容（原 Fever 服务于 2016 年停更，生态持续收缩） |
| **数据同步效率** | **高**。支持精确的增量拉取 (`nt`/`ot`)、流式分页 (`c`)、按需加载与差异化更新 | **低**。基于全量 ID 列表比对 (`unread_item_ids`, `saved_item_ids`)，大数据量下请求/响应体积巨大 |
| **状态与标签表达** | **丰富**。天然支持 Folder/Label 层次、系统 State（Read, Starred, Kept Unread）及自定义 Tag | **有限**。仅支持组（Groups）、星标（Saved）与已读，无法扩展细粒度标签或目录管理 |
| **接口粒度** | **细粒度**。支持针对单篇或批量文章执行 `edit-tag` 操作，支持单个 Feed 的即时标记 | **粗粒度**。通常需要提交大批次 ID 列表，缺乏灵活的打标签/删标签原子接口 |
| **安全性与鉴权** | 支持 `ClientLogin` 派生 Token 机制与 API 专用密码，可无缝结合 HTTP Header | 使用 `api_key = md5(username:password)` 的静态 Hash，缺乏 Session 撤销能力 |

#### 为什么主流客户端（如 NetNewsWire）优先选择 Google Reader API？

1. **架构契合度**：NetNewsWire 等现代 RSS 客户端内部的数据抽象（`Account -> Folder -> Feed -> Article -> ArticleState`）与 Google Reader API 的概念树（`Categories -> Subscriptions -> Stream -> Stream Items -> Tags`）一模一样。
2. **大规模数据处理性能**：当用户存在几万篇未读文章时，Google Reader API 允许客户端只拉取最新的未读 ID 列表，或者通过 `xt=user/-/state/com.google/read`（排除已读）结合 Continuation Token (`c`) 增量分块拉取全文；而 Fever API 则需要一次性传输所有未读 ID 组成的千字节字符串，给客户端与服务端带来沉重的解析负担。
3. **协议复用收益**：客户端一旦实现了一套成熟的 `GReaderAPIAdapter`，不仅能无缝对接 FreshRSS，还能以极低成本适配 Inoreader, BazQux, The Old Reader, Miniflux 等底层提供 GReader API 兼容层的其他主流服务。

---

### 1.2 基础 URL 结构与 API Endpoint 汇总

客户端配置的 **Base URL** 统一指向 FreshRSS 的 `greader.php` 入口，形如：
`https://example.com/api/greader.php` 或 `https://example.com/freshrss/api/greader.php`

所有规范接口均在该 Base URL 之下进行拓展。下表列举了核心 Endpoint：

| 接口分类 | Relative Path | HTTP Method | 功能说明 | 核心 Response 格式 |
| :--- | :--- | :--- | :--- | :--- |
| **身份验证** | `/accounts/ClientLogin` | `POST` | 提交凭据，获取 `Auth` 认证 Token | 纯文本 (`text/plain`) `Auth=username/token...` |
| **账户信息** | `/reader/api/0/user-info` | `GET` | 获取当前登录用户的 ID、用户名及邮箱 | JSON (含 `userId`, `userName`) |
| **订阅列表** | `/reader/api/0/subscription/list` | `GET` | 拉取所有订阅 Feed 及其所属分类/文件夹 | JSON (含 `subscriptions` 数组) |
| **标签列表** | `/reader/api/0/tag/list` | `GET` | 拉取用户创建的所有文件夹与自定义标签 | JSON (含 `tags` 数组) |
| **未读计数** | `/reader/api/0/unread-count` | `GET` | 快速获取各 Feed 及全站的未读文章数量 | JSON (含 `unreadcounts` 数组) |
| **流文章列表** | `/reader/api/0/stream/contents/{stream_id}` | `GET` | 获取特定流（全站/分类/Feed/星标/未读）的文章内容 | JSON (含 `items` 数组及 `continuation`) |
| **流 ID 列表** | `/reader/api/0/stream/items/ids` | `GET` | 仅获取特定流的文章 ID 列表与时间戳 | JSON (含 `itemRefs` 数组及 `continuation`) |
| **编辑标签/状态** | `/reader/api/0/edit-tag` | `POST` | 修改文章状态（标记已读/未读、加星/取消星标等） | 纯文本 `OK` |
| **批量设为已读** | `/reader/api/0/mark-all-as-read` | `POST` | 将某个 Stream 或 Feed 在特定时间点前全部标记已读 | 纯文本 `OK` |

---

## 二、 身份验证与安全机制

### 2.1 FreshRSS “允许 API 访问” 配置项

在 FreshRSS 中，API 访问属于敏感功能。管理员/用户需在 Web 界面进行显式授权：
- **位置**：`系统管理 (Administration)` -> `认证 (Authentication)` -> `允许 API 访问 (Allow API access)`。
- **作用**：若此配置项未勾选，FreshRSS 的 API 转发逻辑将直接拦截所有指向 `/api/greader.php` 的请求并返回 `HTTP 403 Forbidden` 或认证错误。客户端必须在登录失败时给出明确提示：“请检查 FreshRSS 服务端是否启用了‘允许 API 访问’选项”。

---

### 2.2 网页主密码 vs API Password（应用专用密码）

FreshRSS 在安全机制上实行了严格的“凭据隔离”策略：

```
+-----------------------------------------------------------------------+
|                            FreshRSS 用户                             |
+-----------------------------------++----------------------------------+
                                    ||
                   +----------------++----------------+
                   |                                  |
                   v                                  v
     +---------------------------+      +---------------------------+
     |   Web 主密码 (Login Pass) |      |   API Password (应用密码) |
     +---------------------------+      +---------------------------+
     | - 仅用于 Web 界面登录     |      | - 用于 greader / fever    |
     | - 保护系统管理权限        |      | - 加盐生成子令牌          |
     | - 禁止跨 API 接口传输     |      | - 泄露后可随时单向重置    |
     +---------------------------+      +---------------------------+
```

1. **主密码（Web Pass）**：仅用于通过浏览器登录 FreshRSS Web 页面。出于安全考虑，FreshRSS API 默认**拒绝使用主密码进行认证**。
2. **API Password**：用户需登录 Web 端，在 `个人账户 (Profile)` -> `API 管理 (API Management)` 中单独设定/生成的密码。
3. **底层加密逻辑**：FreshRSS 会将 `username` 与 `API Password` 结合内部 Salt 计算一个哈希密钥。即便客户端保存了 API Password 或派生的 Token，攻击者也无法反向推导出用户的 Web 网页主密码。

---

### 2.3 Authentication 授权流程

FreshRSS 的 `greader.php` 兼容层提供了两种认证验证路径：

#### 路径 A：标准 ClientLogin 认证（强烈推荐）

1. **发起登录请求**：
   ```http
   POST /api/greader.php/accounts/ClientLogin HTTP/1.1
   Host: example.com
   Content-Type: application/x-www-form-urlencoded

   Email=your_username&Passwd=your_api_password&client=PaperRss&accountType=HOSTED
   ```
2. **服务端响应**（`200 OK`, `Content-Type: text/plain`）：
   ```text
   SID=user/31a7...
   LSID=user/31a7...
   Auth=user/31a7b45a67f...
   ```
3. **后续 API 请求标头**：
   提取响应中的 `Auth` 完整值，在后续对 `/reader/api/0/...` 的每个 HTTP Request 中添加如下 Header：
   ```http
   Authorization: GoogleLogin auth=user/31a7b45a67f...
   ```
   > ⚠️ **关键注意**：标头格式前缀为 `GoogleLogin auth=`，而非现代 OAuth2 的 `Bearer `！

#### 路径 B：HTTP Basic Auth 兼容模式

部分客户端（或经过 Nginx/Apache 反向代理）直接在 Request Header 中注入标准 Basic Auth：
```http
Authorization: Basic Base64(username:api_password)
```
FreshRSS 的 `greader.php` 内部也会检查 `$_SERVER['PHP_AUTH_USER']` 并完成认证。然而在某些复杂的反向代理架构下，`Authorization` 标头可能会被中间件过滤掉，因此 **ClientLogin + GoogleLogin auth=** 具有更高的穿越性与可靠性。

---

## 三、 核心数据同步与 API 字段

### 3.1 订阅列表接口 (`/reader/api/0/subscription/list`)

用于获取用户订阅的所有 Feed 以及所在的分类目录（Categories）。

- **请求方式**：`GET /reader/api/0/subscription/list?output=json`
- **Header**：`Authorization: GoogleLogin auth=...`
- **响应示例 (JSON)**：
  ```json
  {
    "subscriptions": [
      {
        "id": "feed/12",
        "title": "Daring Fireball",
        "categories": [
          {
            "id": "user/-/label/Tech",
            "label": "Tech"
          }
        ],
        "sortid": "0000000C",
        "firstitemmsec": 1720000000000,
        "url": "https://daringfireball.net/feeds/main",
        "htmlUrl": "https://daringfireball.net/",
        "iconUrl": "https://example.com/freshrss/p/themes/icons/default/favicon.ico"
      }
    ]
  }
  ```
- **Swift 数据映射建议**：
  - 将 `id` 去除 `"feed/"` 前缀解析出数字主键 ID (`12`)。
  - `categories` 数组若为空，则归入根目录（Uncategorized）。

---

### 3.2 未读/已读同步逻辑与 Tag 系统

Google Reader 协议将文章的所有状态抽象为 **Tag（标签）**：
- **已读状态（Read）**：`user/-/state/com.google/read`
- **星标状态（Starred）**：`user/-/state/com.google/starred`
- **保持未读（Kept Unread）**：`user/-/state/com.google/kept-unread`
- **阅读列表（Reading List）**：`user/-/state/com.google/reading-list`

#### 状态修改接口 (`POST /reader/api/0/edit-tag`)

当用户在客户端将文章标记为已读/未读、加星/取消星标时，调用此接口进行双向同步。

- **Content-Type**：`application/x-www-form-urlencoded`
- **Form 参数**：
  - `i`：文章 ID（可多次传递 `i` 以支持批量修改，例如 `i=1001&i=1002&i=1003`）。
  - `a`：（Add Tag）需要添加的标签。
  - `r`：（Remove Tag）需要移除的标签。

#### 常见操作代码对照表

| 用户动作 | 接口参数组合 |
| :--- | :--- |
| **标记为已读** | `a=user/-/state/com.google/read&i=1001` |
| **标记为未读** | `r=user/-/state/com.google/read&a=user/-/state/com.google/kept-unread&i=1001` |
| **文章加星** | `a=user/-/state/com.google/starred&i=1001` |
| **取消星标** | `r=user/-/state/com.google/starred&i=1001` |

- **响应格式**：成功时服务端返回纯文本字符串 `OK`（`HTTP 200`）。

---

### 3.3 增量同步与条件过滤

在拉取文章列表 (`/reader/api/0/stream/contents/{stream_id}`) 时，配合参数可实现高性能的增量同步。

#### 常用 Stream ID 构建规范

- **全站所有文章**：`user/-/state/com.google/reading-list`
- **全站星标文章**：`user/-/state/com.google/starred`
- **特定分类下的文章**：`user/-/label/分类名称`
- **特定 Feed 下的文章**：`feed/12`

#### 关键查询参数

1. **`xt` (Exclude Target - 排除目标)**：
   例如只拉取未读文章：
   `GET /reader/api/0/stream/contents/user/-/state/com.google/reading-list?xt=user/-/state/com.google/read&output=json`
2. **`n` (Number - 数量限制)**：
   限制单次返回的最大文章条数，默认值为 20，推荐客户端设置为 `n=100` 或 `n=250`。
3. **`ot` (Older Than - 时间上限)**：
   仅返回发布时间戳早于 `ot`（Unix 时间戳，秒级）的文章。
4. **`nt` (Newer Than - 时间下限)**：
   **增量同步的核心**。客户端保存上次同步的时间戳 `T_last`，请求时附带 `nt=T_last`，服务端将仅返回在 `T_last` 之后更新/新入库的文章。
5. **`c` (Continuation Token - 分页标记)**：
   当请求结果超过 `n` 条时，返回的 JSON 根部会包含 `"continuation": "1723456789"`。客户端进行“上滑加载更多”或下一页拉取时，必须携带 `?c=1723456789`。

---

## 四、 常见踩坑点与适配建议

### 4.1 子目录部署模式与 URL 拼接适配

在实际自托管环境中，用户部署 FreshRSS 的 URL 形式百花齐放：
- 形式 A：`https://rss.example.com`（根域名部署）
- 形式 B：`https://example.com/freshrss/`（子目录部署）
- 形式 C：`https://example.com/p/api/greader.php`（暴露完整路径）

#### 拼接陷阱与解决方案

1. **URL 标准化规范**：
   客户端输入框应允许用户输入上述任意形式。客户端在内部应通过 URL 规范化算法统一清洗为标准的 **API Base URL**（即以 `/api/greader.php` 结尾）：
   ```swift
   func normalizeFreshRSSURL(_ input: String) -> URL? {
       var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
       if !path.hasPrefix("http://") && !path.hasPrefix("https://") {
           path = "https://" + path
       }
       while path.hasSuffix("/") {
           path.removeLast()
       }
       if !path.hasSuffix("/api/greader.php") {
           if path.hasSuffix("/api") {
               path += "/greader.php"
           } else {
               path += "/api/greader.php"
           }
       }
       return URL(string: path)
   }
   ```
2. **Nginx 反向代理与 `PATH_INFO` 丢失**：
   有些 Nginx 配置缺少 `fastcgi_split_path_info`，导致 `/api/greader.php/accounts/ClientLogin` 被 Nginx 当作静态文件寻找，返回 `404 Not Found`。
   - **客户端防范**：在检测到 HTTP 404 或 400 时，给用户友好的诊断提示：“未能找到 API 端点，请检查服务器 Nginx 是否配置了 PATH_INFO 规则”。

---

### 4.2 HTTPS / 自签名证书 / ATS（App Transport Security）策略

由于 FreshRSS 多部署于家庭实验室（Homelab）或局域网 NAS 中，大量用户使用 IP、HTTP 或自签名 HTTPS 证书。

- **iOS/macOS ATS 限制**：默认情况下，`URLSession` 会拒绝非 HTTPS 连接以及未通过 CA 信任链验证的自签名证书。
- **Swift 适配建议**：
  1. 在 `Account` 设置中提供开关选项：`[x] 允许自签名/不安全 TLS 证书`。
  2. 实现自定义 `URLSessionDelegate` 的 `urlSession(_:didReceive:challenge:completionHandler:)` 方法：
     ```swift
     if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
        let serverTrust = challenge.protectionSpace.serverTrust,
        account.allowSelfSignedCertificates {
         completionHandler(.useCredential, URLCredential(trust: serverTrust))
         return
     }
     completionHandler(.performDefaultHandling, nil)
     ```

---

### 4.3 纯文本响应与 JSON 解析异常处理

在大部分 REST API 中，响应格式通常保持 JSON 统一。但 Google Reader API 规范具有历史遗留特性：
- `/accounts/ClientLogin` 返回的是 **Key=Value** 文本串 (`text/plain`)；
- `/reader/api/0/edit-tag` 和 `/mark-all-as-read` 返回的是纯文本 **`OK`**。

#### 踩坑表现
若使用 Swift `Combine` 或 `async/await` 结合 `JSONDecoder()` 直接解析全量响应，遇到 `edit-tag` 返回的 `"OK"` 时系统会抛出 `DecodingError.dataCorrupted`。

#### 适配方案
针对 Endpoint 区分 Data 解包方式：若为 `edit-tag` / `ClientLogin`，直接按 `String(data: data, encoding: .utf8)` 解析校验。

---

### 4.4 文章 ID 溢出与字符串存储要求

FreshRSS 服务端在处理 RSS 条目时，会生成包含哈希或长整数的文章 ID（如 `"tag:google.com,2005:reader/item/000000006492a10b"` 或 `"7246991191025541387"`）。

- **防坑规则**：客户端内存模型及 CoreData/SQLite 数据库中，**必须始终将 Article ID 存储为 `String` 字符串**。严禁解析为 32 位或 64 位整数，否则可能导致溢出截断或比较失败。

---

## 五、 规范文档与参考来源

为保障调研结论的可追溯性，本报告引用的官方与行业规范文档如下：

1. **FreshRSS 官方 GitHub 仓库与文档**
   - FreshRSS Source Code: [FreshRSS/FreshRSS (`p/api/greader.php`)](https://github.com/FreshRSS/FreshRSS)
   - FreshRSS User Documentation: [FreshRSS API Access & Password Configuration](https://freshrss.github.io/FreshRSS/en/users/06_Mobile_apps.html)
2. **Google Reader API 逆向工程规范 (De Facto Standard)**
   - Google Reader API Developer Guide (Archived): [Google Reader API Unofficial Guide by Mihai Parparita](https://github.com/mihaip/google-reader-api)
   - Pyrfeed Google Reader API Reference: [Google Reader Protocol Documentation](https://code.google.com/archive/p/pyrfeed/wikis/GoogleReaderAPI.wiki)
3. **开源 RSS 客户端集成参考**
   - NetNewsWire Architecture & Source: [Ranchero-Software/NetNewsWire (ReaderAPI Integration)](https://github.com/Ranchero-Software/NetNewsWire)
   - Read You Open Source RSS Client: [Read You FreshRSS Adapter](https://github.com/ReadYouApp/ReadYou)

---
*本报告整理完成并归档至 PaperRss 官方文档库。*
