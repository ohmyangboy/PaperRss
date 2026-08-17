(function initGitHubStars() {
  const cachedStars = sessionStorage.getItem('paperrss_gh_stars');
  if (cachedStars) {
    applyStars(cachedStars);
  }

  fetch('https://api.github.com/repos/ohmyangboy/PaperRss', {
    headers: { 'Accept': 'application/vnd.github.v3+json' }
  })
    .then((response) => {
      if (!response.ok) throw new Error('GitHub API response not ok');
      return response.json();
    })
    .then((data) => {
      if (data && typeof data.stargazers_count === 'number') {
        const count = formatStars(data.stargazers_count);
        sessionStorage.setItem('paperrss_gh_stars', count);
        applyStars(count);
      }
    })
    .catch(() => {
      // Keep static fallback
    });

  function formatStars(count) {
    if (count >= 1000) {
      return (count / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return String(count);
  }

  function applyStars(count) {
    const starElements = document.querySelectorAll('.gh-star-count');
    starElements.forEach((el) => {
      el.textContent = count;
    });
  }
})();
