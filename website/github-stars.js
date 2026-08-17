(function initGitHubStars() {
  const GITHUB_API_URL = 'https://api.github.com/repos/ohmyangboy/PaperRss';
  const STORAGE_KEY = 'paperrss_gh_stars';
  const CACHE_TTL = 10 * 60 * 1000; // 10分钟 (毫秒)

  let isFetching = false;

  function formatStars(count) {
    if (typeof count !== 'number' || isNaN(count) || count < 0) {
      return '';
    }
    if (count >= 1000) {
      return (count / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return String(count);
  }

  function applyStars(count) {
    if (!count) return;
    const starElements = document.querySelectorAll('.gh-star-count');
    starElements.forEach((el) => {
      el.textContent = count;
    });
  }

  function getStoredCache() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed.count !== 'undefined' && typeof parsed.timestamp === 'number') {
        return parsed;
      }
    } catch (e) {
      // 忽略解析错误
    }
    return null;
  }

  function fetchFreshStars() {
    if (isFetching) return;
    isFetching = true;

    fetch(GITHUB_API_URL)
      .then((response) => {
        if (!response.ok) throw new Error('GitHub API response not ok');
        return response.json();
      })
      .then((data) => {
        const rawCount = data.stargazers_count;
        if (typeof rawCount === 'number' && rawCount >= 0) {
          const count = formatStars(rawCount);
          if (count) {
            // 更新页面
            applyStars(count);
            // 写入本地缓存
            try {
              localStorage.setItem(
                STORAGE_KEY,
                JSON.stringify({
                  count,
                  timestamp: Date.now()
                })
              );
            } catch (e) {
              // 忽略 localStorage 写入失败（如隐私模式）
            }
          }
        }
      })
      .catch(() => {
        // 请求失败（大概率是触发了 GitHub 60次/小时 的 IP 限制）：
        // 保持当前数字，不进行修改、不清空数字、不显示NaN。
        // 失败时不修改缓存时间，保证 GitHub API 恢复后能够重新尝试获取最新 Star。
      })
      .finally(() => {
        isFetching = false;
      });
  }

  function checkAndRefresh() {
    const cached = getStoredCache();
    const now = Date.now();

    // 如果存在缓存，立即应用，保证第一时间看到数字
    if (cached) {
      applyStars(cached.count);
      
      // 检查缓存年龄
      if (now - cached.timestamp < CACHE_TTL) {
        return; // 未超过 TTL，不请求 GitHub
      }
    }

    // 没有缓存，或者缓存已过期（超过 TTL），执行后台刷新
    fetchFreshStars();
  }

  // 1. 页面加载时执行
  checkAndRefresh();

  // 2. 页面重新激活刷新
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      const cached = getStoredCache();
      const now = Date.now();
      if (!cached || now - cached.timestamp >= CACHE_TTL) {
        fetchFreshStars(); // 超过 TTL，后台刷新
      }
    }
  });
})();
