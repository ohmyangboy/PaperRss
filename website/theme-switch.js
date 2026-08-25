(() => {
  function applyTheme(theme) {
    if (theme === 'dark') {
      document.documentElement.classList.add('dark');
    } else {
      document.documentElement.classList.remove('dark');
    }
  }

  function initThemeSwitch() {
    const buttons = document.querySelectorAll('.theme-opt');
    buttons.forEach((btn) => {
      btn.addEventListener('click', () => {
        const selected = btn.getAttribute('data-theme');
        if (selected) {
          localStorage.setItem('theme', selected);
          applyTheme(selected);
        }
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initThemeSwitch);
  } else {
    initThemeSwitch();
  }
})();
