(() => {
  const ONELEAF_URL =
    "https://download.1leaf.cc/PaperRss-latest.dmg";

  const GITHUB_API =
    "https://api.github.com/repos/ohmyangboy/PaperRss/releases/latest";

  const GITHUB_RELEASES =
    "https://github.com/ohmyangboy/PaperRss/releases/latest";

  const TIMEOUT_MS = 3000;

  function isOneLeafHost() {
    return (
      location.hostname === "rss.1leaf.cc" ||
      location.hostname.endsWith(".1leaf.cc")
    );
  }

  async function fetchWithTimeout(url, options = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

    try {
      return await fetch(url, {
        ...options,
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }
  }

  async function getGitHubDownload() {
    try {
      const response = await fetchWithTimeout(GITHUB_API, {
        headers: {
          Accept: "application/vnd.github+json",
        },
        cache: "no-store",
      });

      if (!response.ok) {
        return GITHUB_RELEASES;
      }

      const release = await response.json();
      const asset = release.assets?.find((item) =>
        /\.dmg$/i.test(item.name)
      );

      return asset?.browser_download_url || GITHUB_RELEASES;
    } catch (_) {
      return GITHUB_RELEASES;
    }
  }

  function initSmartDownload() {
    const links = document.querySelectorAll("[data-smart-download]");

    if (isOneLeafHost()) {
      // 1leaf 域名：固定走 1leaf 镜像下载，不自动切到 GitHub
      links.forEach((link) => {
        link.href = ONELEAF_URL;
      });
      return;
    }

    // GitHub Pages 或其他域名：固定走 GitHub 下载，不自动切到 1leaf
    links.forEach((link) => {
      link.href = GITHUB_RELEASES;

      link.addEventListener("click", async (event) => {
        event.preventDefault();

        if (link.dataset.downloading === "1") {
          return;
        }

        link.dataset.downloading = "1";
        link.setAttribute("aria-busy", "true");

        try {
          const url = await getGitHubDownload();
          window.location.href = url;
        } finally {
          link.dataset.downloading = "";
          link.removeAttribute("aria-busy");
        }
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initSmartDownload);
  } else {
    initSmartDownload();
  }
})();
