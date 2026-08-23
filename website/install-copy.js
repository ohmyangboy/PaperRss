// PaperRss — install command copy button (native, no framework)
(() => {
  const buttons = document.querySelectorAll(".install-cmd-copy");
  buttons.forEach((button) => {
    const target = document.getElementById(button.dataset.copyTarget);
    if (!target) return;
    button.addEventListener("click", async () => {
      const original = button.textContent;
      const copiedLabel = button.dataset.copiedLabel || "已复制 ✓";
      const failLabel = button.dataset.failLabel || "复制失败";
      try {
        await navigator.clipboard.writeText(target.textContent.trim());
        button.textContent = copiedLabel;
        button.classList.add("copied");
      } catch {
        button.textContent = failLabel;
      }
      setTimeout(() => {
        button.textContent = original;
        button.classList.remove("copied");
      }, 1600);
    });
  });
})();
