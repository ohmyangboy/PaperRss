(() => {
  const frames = [...document.querySelectorAll("iframe.supporters-frame[data-src]")];
  if (!frames.length) return;

  const load = (frame) => {
    if (!frame.dataset.src) return;
    frame.src = frame.dataset.src;
    delete frame.dataset.src;
  };

  // 不提前设置 src，避免浏览器原生懒加载在临近首屏时预取远端页面。
  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        load(entry.target);
        observer.unobserve(entry.target);
      }
    }, { rootMargin: "0px", threshold: 0 });
    frames.forEach((frame) => observer.observe(frame));
  } else {
    // 旧浏览器同样等到曝光后加载，并在全部加载后移除监听。
    const check = () => {
      for (const frame of frames) {
        const bounds = frame.getBoundingClientRect();
        if (bounds.top < window.innerHeight && bounds.bottom > 0) load(frame);
      }
      if (frames.every((frame) => !frame.dataset.src)) {
        window.removeEventListener("scroll", check);
        window.removeEventListener("resize", check);
      }
    };
    window.addEventListener("scroll", check, { passive: true });
    window.addEventListener("resize", check);
    check();
  }
})();
