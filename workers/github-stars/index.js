/**
 * PaperRss GitHub Stars Edge Cache Proxy (Cloudflare Worker)
 * 
 * 缓存策略:
 * - 生产环境利用 Cloudflare Cache API (caches.default) 进行边缘缓存 (TTL: 10分钟)
 * - 遇到 GitHub API 异常/限流时，降级返回安全 fallback: { "stars": 0 }
 * - 全局支持 CORS (*)，满足前端跨域请求
 */

const GITHUB_REPO_API = 'https://api.github.com/repos/ohmyangboy/PaperRss';
const CACHE_TTL_SECONDS = 600; // 10 分钟 (600秒)

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept',
  'Access-Control-Max-Age': '86400',
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 1. 处理 CORS 预检请求 (Preflight)
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: CORS_HEADERS,
      });
    }

    // 2. 仅允许 GET / HEAD 方法
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response(
        JSON.stringify({ error: 'Method Not Allowed' }),
        {
          status: 405,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            ...CORS_HEADERS,
          },
        }
      );
    }

    // 3. 路由匹配：支持 /github-stars 以及根路径 /
    if (url.pathname !== '/github-stars' && url.pathname !== '/' && url.pathname !== '') {
      return new Response(
        JSON.stringify({ error: 'Not Found' }),
        {
          status: 404,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            ...CORS_HEADERS,
          },
        }
      );
    }

    // 4. 尝试从 Cloudflare Cache API 读取缓存
    let cache = null;
    try {
      if (typeof caches !== 'undefined' && caches.default) {
        cache = caches.default;
      }
    } catch {
      // 容错: 非 CF 运行时忽略
    }

    // 使用统一的 cacheKey 保证 query 参数不影响缓存命中率
    const cacheKeyUrl = new URL(url.origin + '/github-stars');
    const cacheKey = new Request(cacheKeyUrl.toString(), {
      method: 'GET',
    });

    if (cache) {
      try {
        const cachedResponse = await cache.match(cacheKey);
        if (cachedResponse) {
          const headers = new Headers(cachedResponse.headers);
          for (const [key, value] of Object.entries(CORS_HEADERS)) {
            headers.set(key, value);
          }
          return new Response(cachedResponse.body, {
            status: cachedResponse.status,
            statusText: cachedResponse.statusText,
            headers,
          });
        }
      } catch {
        // Cache match 异常时直接回源
      }
    }

    // 5. 缓存未命中，回源请求 GitHub API
    try {
      const ghResponse = await fetch(GITHUB_REPO_API, {
        headers: {
          'User-Agent': 'PaperRss-GitHub-Stars-Worker/1.0',
          'Accept': 'application/vnd.github.v3+json',
        },
      });

      if (!ghResponse.ok) {
        throw new Error(`GitHub API error: ${ghResponse.status} ${ghResponse.statusText}`);
      }

      const data = await ghResponse.json();
      const stars = typeof data.stargazers_count === 'number' ? data.stargazers_count : 0;
      const updatedAt = new Date().toISOString();

      const responsePayload = JSON.stringify({
        stars,
        updatedAt,
      });

      const response = new Response(responsePayload, {
        status: 200,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': `public, max-age=${CACHE_TTL_SECONDS}, s-maxage=${CACHE_TTL_SECONDS}`,
          ...CORS_HEADERS,
        },
      });

      // 异步存入 Cloudflare 边缘缓存
      if (cache && ctx && typeof ctx.waitUntil === 'function') {
        ctx.waitUntil(cache.put(cacheKey, response.clone()));
      }

      return response;
    } catch (err) {
      // 6. 异常兜底：返回安全的 fallback 数据 { "stars": 0 }
      return new Response(
        JSON.stringify({
          stars: 0,
          updatedAt: new Date().toISOString(),
          fallback: true,
        }),
        {
          status: 200,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Cache-Control': 'no-store, no-cache, must-revalidate',
            ...CORS_HEADERS,
          },
        }
      );
    }
  },
};
