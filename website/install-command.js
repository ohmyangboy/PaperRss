(() => {
  document.querySelectorAll('[data-install-toggle]').forEach((button) => {
    const panel = document.getElementById(button.getAttribute('aria-controls'));
    if (!panel) return;
    button.addEventListener('click', () => {
      const expanded = button.getAttribute('aria-expanded') !== 'true';
      button.setAttribute('aria-expanded', String(expanded));
      panel.hidden = !expanded;
    });
  });

  document.querySelectorAll('.install-tabs').forEach((tablist) => {
    const tabs = [...tablist.querySelectorAll('[role="tab"]')];
    const select = (active) => {
      tabs.forEach((tab) => {
        const selected = tab === active;
        tab.setAttribute('aria-selected', String(selected));
        tab.tabIndex = selected ? 0 : -1;
        document.getElementById(tab.getAttribute('aria-controls')).hidden = !selected;
      });
    };
    tabs.forEach((tab, index) => {
      tab.addEventListener('click', () => select(tab));
      tab.addEventListener('keydown', (event) => {
        let next;
        if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
        else if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
        else if (event.key === 'Home') next = 0;
        else if (event.key === 'End') next = tabs.length - 1;
        else return;
        event.preventDefault();
        select(tabs[next]);
        tabs[next].focus();
      });
    });
  });

  document.querySelectorAll('[data-copy-command]').forEach((button) => {
    const code = document.getElementById(button.dataset.copyCommand);
    if (!code) return;
    const label = button.getAttribute('aria-label');
    let resetTimer;
    button.hidden = false;
    button.addEventListener('click', async () => {
      clearTimeout(resetTimer);
      try {
        await navigator.clipboard.writeText(code.textContent.trim());
        button.setAttribute('data-copied', '');
        button.setAttribute('aria-label', button.dataset.copiedLabel);
        button.title = button.dataset.copiedLabel;
      } catch {
        // 剪贴板不可用时选中命令，允许用户手动复制。
        const range = document.createRange();
        range.selectNodeContents(code);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        button.removeAttribute('data-copied');
        button.setAttribute('aria-label', button.dataset.errorLabel);
        button.title = button.dataset.errorLabel;
      }
      resetTimer = setTimeout(() => {
        button.removeAttribute('data-copied');
        button.setAttribute('aria-label', label);
        button.title = label;
      }, 2400);
    });
  });
})();
