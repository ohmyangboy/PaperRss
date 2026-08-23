(function initGitHubStars() {
  const scriptUrl = document.currentScript ? document.currentScript.src : window.location.href;
  const jsonUrl = new URL('github-stars.json', scriptUrl).href;

  function formatStars(count) {
    if (typeof count !== 'number' || isNaN(count) || count <= 0) {
      return '';
    }
    if (count >= 1000) {
      return (count / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return String(count);
  }

  function applyStars(formattedCount) {
    if (!formattedCount) return;
    const starCounts = document.querySelectorAll('.gh-star-count');
    const starBadges = document.querySelectorAll('.gh-star-badge');
    starCounts.forEach((el) => {
      el.textContent = formattedCount;
    });
    starBadges.forEach((badge) => {
      badge.classList.add('is-visible');
    });
  }

  fetch(jsonUrl)
    .then((response) => {
      if (!response.ok) throw new Error('Failed to load GitHub stars JSON');
      return response.json();
    })
    .then((data) => {
      if (data && typeof data.stars === 'number' && data.stars > 0) {
        const formatted = formatStars(data.stars);
        if (formatted) {
          applyStars(formatted);
        }
      }
    })
    .catch(() => {
      // Keep hidden if fetch fails or no valid stars count
    });
})();
