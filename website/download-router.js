(() => {
  const ONELEAF_URL =
    "https://download.1leaf.cc/PaperRss-latest.dmg";

  const GITHUB_API =
    "https://api.github.com/repos/ohmyangboy/PaperRss/releases/latest";

  const GITHUB_RELEASES =
    "https://github.com/ohmyangboy/PaperRss/releases/latest";

  const TIMEOUT_MS = 3000;

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

  async function getOneLeafDownload() {
    try {
      const response = await fetchWithTimeout(ONELEAF_URL, {
        method: "HEAD",
        mode: "cors",
        cache: "no-store",
      });

      if (response.ok) {
        return ONELEAF_URL;
      }
    } catch (_) {}

    return null;
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
        return null;
      }

      const release = await response.json();

      const asset = release.assets?.find((asset) =>
        /\.dmg$/i.test(asset.name)
      );

      return asset?.browser_download_url || null;
    } catch (_) {
      return null;
    }
  }

  function preferOneLeaf() {
    return location.hostname === "rss.1leaf.cc";
  }

  async function chooseDownload() {
    if (preferOneLeaf()) {
      // 官方站：1leaf → GitHub
      return (
        (await getOneLeafDownload()) ||
        (await getGitHubDownload()) ||
        GITHUB_RELEASES
      );
    }

    // GitHub Pages：GitHub → 1leaf
    return (
      (await getGitHubDownload()) ||
      (await getOneLeafDownload()) ||
      GITHUB_RELEASES
    );
  }

  function initSmartDownload() {
    document
      .querySelectorAll("[data-smart-download]")
      .forEach((link) => {
        link.addEventListener("click", async (event) => {
          event.preventDefault();

          if (link.dataset.downloading === "1") {
            return;
          }

          link.dataset.downloading = "1";
          link.setAttribute("aria-busy", "true");

          try {
            const url = await chooseDownload();
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
