(function initGitHubStars() {
  const WORKER_URL = 'https://paperrss-github-stars.ohmyangboy.workers.dev/github-stars';
  const STORAGE_KEY = 'paperrss_gh_stars';
  const CACHE_TTL_MS = 10 * 60 * 1000; // 10 minutes

  let isFetching = false;

  function getStoredCache() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed.stars === 'number' && typeof parsed.updatedAt === 'number') {
        return parsed;
      }
    } catch {
      // Ignore localStorage or JSON parse errors in restricted environments
    }
    return null;
  }

  function setStoredCache(stars) {
    try {
      const data = {
        stars: stars,
        updatedAt: Date.now(),
      };
      localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
    } catch {
      // Ignore localStorage write failures
    }
  }

  function formatStars(count) {
    if (typeof count !== 'number' || isNaN(count) || count < 0) {
      return '';
    }
    if (count >= 1000) {
      return (count / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return String(count);
  }

  function applyStars(formattedCount) {
    if (!formattedCount) return;
    const starElements = document.querySelectorAll('.gh-star-count');
    starElements.forEach((el) => {
      el.textContent = formattedCount;
    });
  }

  function fetchFreshStars() {
    if (isFetching) return;
    isFetching = true;

    fetch(WORKER_URL, {
      headers: { 'Accept': 'application/json' },
    })
      .then((response) => {
        if (!response.ok) throw new Error('Worker response not ok');
        return response.json();
      })
      .then((data) => {
        if (data && typeof data.stars === 'number' && data.stars >= 0) {
          setStoredCache(data.stars);
          const formatted = formatStars(data.stars);
          if (formatted) {
            applyStars(formatted);
          }
        }
      })
      .catch(() => {
        // Keep current rendered fallback or cached stars on error
      })
      .finally(() => {
        isFetching = false;
      });
  }

  function checkAndRefresh() {
    const cached = getStoredCache();
    const now = Date.now();

    if (cached) {
      const formatted = formatStars(cached.stars);
      if (formatted) {
        applyStars(formatted);
      }
      // Check cache age
      if (now - cached.updatedAt < CACHE_TTL_MS) {
        return; // Cache is fresh, stop request
      }
    }

    // Cache missing or expired, fetch in background
    fetchFreshStars();
  }

  // 1. Initial check on page load
  checkAndRefresh();

  // 2. Refresh when page becomes visible and cache is stale
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      const cached = getStoredCache();
      const now = Date.now();
      if (!cached || now - cached.updatedAt >= CACHE_TTL_MS) {
        fetchFreshStars();
      }
    }
  });
})();
