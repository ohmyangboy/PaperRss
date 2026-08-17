# PaperRss GitHub Stars Worker 代理

本项目为 **PaperRss** 官网的 GitHub Stars 数据提供轻量级、高可用的生产级边缘缓存代理，基于 Cloudflare Worker 实现。

---

## 架构与缓存策略

```
[ 用户浏览器 ]
      │
      ├─ 1. 读取 localStorage (paperrss_gh_stars)
      │     └─ 命中 (< 10分钟): 立即渲染，无需请求
      │
      └─ 2. 未命中 / 缓存过期 (>= 10分钟): 请求 Worker
                  │
                  ▼
      [ Cloudflare Worker 边缘节点 ]
                  │
                  ├─ 3. 查询 Cloudflare Cache API (TTL: 10分钟)
                  │     └─ 命中: 直接返回缓存响应 (0 回源)
                  │
                  └─ 4. 未命中: 向上游 GitHub API 请求并缓存
                              │
                              ▼
                    [ GitHub REST API ]
```

- **双层缓存架构**：
  1. **浏览器客户端**：`localStorage` 本地持久缓存 10 分钟，支持页面切换、刷新秒开，并在 `visibilitychange` 时按需检测刷新。
  2. **边缘节点**：Cloudflare Edge Cache (`caches.default`) 缓存 10 分钟，降低对 GitHub API 的请求频次，彻底避免触发 GitHub API 60次/小时 的 IP 限流。
- **高可用与异常兜底**：
  - 上游 GitHub API 异常（限流或网络故障）时，Worker 返回安全降级数据 `{ "stars": 0, "fallback": true }`。
  - 前端加载异常时不会抹除原有 DOM 数值，始终展示静态兜底数字（默认 `16`）或上一次成功获取的有效数值。
- **全跨域支持**：内置完善的 CORS (`Access-Control-Allow-Origin: *`) 与 OPTIONS 预检支持。

---

## 快速开始与本地调试

### 1. 安装 Wrangler CLI

确保本地已安装 Node.js (>= 18)，在当前目录执行：

```bash
cd workers/github-stars
npm install -g wrangler # 或使用 npx wrangler
```

### 2. 本地开发预览

```bash
npx wrangler dev
```

本地服务启动后，访问 `http://localhost:8787/github-stars` 即可查看返回的 JSON 数据：

```json
{
  "stars": 18,
  "updatedAt": "2026-08-17T15:00:00.000Z"
}
```

---

## 部署上线

### 方法一：使用 Wrangler CLI 自动部署（推荐）

1. 登录 Cloudflare 账号：
   ```bash
   npx wrangler login
   ```
2. 部署 Worker：
   ```bash
   npx wrangler deploy
   ```
3. 部署完成后，控制台将输出分配的 Worker 访问地址（例如 `https://paperrss-github-stars.<你的-subdomain>.workers.dev/github-stars`）。

### 方法二：Cloudflare Dashboard 手动创建

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. 导航至 **Workers & Pages** -> **Create application** -> **Create Worker**。
3. 命名为 `paperrss-github-stars`，点击 **Deploy**。
4. 进入编辑代码界面，将 `index.js` 的完整内容复制粘贴并保存部署即可。

---

## 绑定自定义域名（可选）

若希望使用自己的独立域名（如 `api.paperrss.com` 或 `stars.paperrss.com`）：

1. 打开 Cloudflare 控制台 -> **Workers & Pages** -> 选择已部署的 `paperrss-github-stars`。
2. 点击 **Settings** -> **Domains & Routes** -> **Add** -> **Custom Domain**。
3. 输入你的自定义子域名（例如 `api.paperrss.com`）并确认添加。
4. Cloudflare 会自动配置该域名的 DNS 解析与 SSL 证书。

---

## 官网前端配置 Worker URL

部署好 Worker 后，将获得的访问 URL 配置到官网前端代码中：

1. 打开 `website/github-stars.js`。
2. 修改文件顶部的 `WORKER_URL` 常量：

```javascript
// 修改为你的实际 Worker 地址或自定义域名
const WORKER_URL = 'https://paperrss-github-stars.ohmyangboy.workers.dev/github-stars';
// 或自定义域名：
// const WORKER_URL = 'https://api.paperrss.com/github-stars';
```

3. 保存并推送到生产环境，官网即可无缝使用全新代理方案。
