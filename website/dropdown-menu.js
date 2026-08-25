(() => {
  function initDropdown() {
    const toggleButtons = document.querySelectorAll('.dl-toggle');
    
    toggleButtons.forEach((toggle) => {
      const parent = toggle.closest('.dl-split') || toggle.parentElement;
      const menu = parent ? parent.querySelector('.dl-menu') : null;
      if (!menu) return;

      function openMenu() {
        toggle.setAttribute('aria-expanded', 'true');
        menu.classList.add('is-open');
      }

      function closeMenu() {
        toggle.setAttribute('aria-expanded', 'false');
        menu.classList.remove('is-open');
      }

      toggle.addEventListener('click', (e) => {
        e.stopPropagation();
        const expanded = toggle.getAttribute('aria-expanded') === 'true';
        if (expanded) {
          closeMenu();
        } else {
          openMenu();
        }
      });

      document.addEventListener('click', (e) => {
        if (!parent.contains(e.target)) {
          closeMenu();
        }
      });

      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') {
          closeMenu();
          toggle.focus();
        }
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initDropdown);
  } else {
    initDropdown();
  }
})();
