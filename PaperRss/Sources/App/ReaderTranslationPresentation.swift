import Foundation

/// 与增量翻译共用的本地展示层。原始节点始终保留，悬浮无需经过 Swift bridge。
enum ReaderTranslationPresentation {
    static let style = """
    .paper-rss-translation { color: var(--paper-translation-color, var(--paper-muted)); }
    html[data-paper-translation-mode="replacement"] .paper-rss-translation.is-loading { display: none; }
    .paper-rss-replacement {
      display: grid;
      grid-template-columns: minmax(0, 1fr);
      position: relative;
    }
    .paper-rss-replacement > .paper-rss-source-layer,
    .paper-rss-replacement > .paper-rss-translation {
      grid-area: 1 / 1;
      min-width: 0;
      margin: 0 !important;
      transition: opacity .15s ease;
    }
    .paper-rss-replacement > .paper-rss-translation {
      color: var(--paper-ink);
      padding: 0;
      align-self: start;
    }
    .paper-rss-replacement > .paper-rss-translation .paper-rss-translation-label { display: none; }
    .paper-rss-replacement [data-paper-hidden="true"] {
      opacity: 0;
      pointer-events: none;
      user-select: none;
      -webkit-user-select: none;
    }
    .paper-rss-replacement [data-paper-hidden="false"] { opacity: 1; }
    .paper-rss-replacement:focus-visible { outline: 1px solid var(--paper-accent); outline-offset: 3px; }
    @media (prefers-reduced-motion: reduce) {
      .paper-rss-replacement > .paper-rss-source-layer,
      .paper-rss-replacement > .paper-rss-translation { transition: none; }
    }
    """

    static let bootstrapScript = """
    if (!window.paperRssTranslationPresentation) {
      const records = new Map();
      const finePointer = window.matchMedia('(hover: hover) and (pointer: fine)');
      let hovered = null;
      let focused = null;
      let pressed = null;
      let keyboardFocus = true;
      let selected = new Set();
      const recordFor = node => {
        const element = node?.nodeType === 1 ? node : node?.parentElement;
        const host = element?.closest('.paper-rss-replacement');
        return host ? records.get(host.dataset.translationId) : null;
      };
      const hasSelection = record => {
        const selection = window.getSelection();
        if (!selection || selection.isCollapsed) return false;
        for (let i = 0; i < selection.rangeCount; i++) {
          if (selection.getRangeAt(i).intersectsNode(record.host)) return true;
        }
        return false;
      };
      const show = (record, original) => {
        if (!record || record.original === original) return;
        record.original = original;
        for (const [node, hidden] of [[record.source, !original], [record.aside, original]]) {
          node.dataset.paperHidden = String(hidden);
          node.setAttribute('aria-hidden', String(hidden));
          node.inert = hidden;
        }
      };
      const hasFocus = record => document.activeElement === record.host
        ? keyboardFocus
        : record.host.contains(document.activeElement);
      const refresh = record => {
        if (!record || pressed === record) return;
        if (hasSelection(record)) { selected.add(record); return; }
        show(record, hovered === record || hasFocus(record));
      };
      document.addEventListener('pointerover', event => {
        if (!finePointer.matches || event.pointerType === 'touch') return;
        const next = recordFor(event.target);
        if (next === hovered) return;
        const old = hovered; hovered = next;
        refresh(old); refresh(next);
      });
      document.addEventListener('pointerout', event => {
        if (!hovered || hovered.host.contains(event.relatedTarget)) return;
        const old = hovered; hovered = recordFor(event.relatedTarget);
        refresh(old); refresh(hovered);
      });
      document.addEventListener('focusin', event => {
        const old = focused; focused = recordFor(event.target);
        refresh(old); refresh(focused);
      });
      document.addEventListener('focusout', () => queueMicrotask(() => {
        const old = focused; focused = recordFor(document.activeElement);
        refresh(old); refresh(focused);
      }));
      document.addEventListener('keydown', event => {
        if (event.key === 'Tab') keyboardFocus = true;
      });
      document.addEventListener('pointerdown', event => {
        keyboardFocus = false;
        pressed = recordFor(event.target);
      });
      const release = () => { const old = pressed; pressed = null; refresh(old); };
      document.addEventListener('pointerup', release);
      document.addEventListener('pointercancel', release);
      document.addEventListener('selectionchange', () => {
        const selection = window.getSelection();
        const candidates = new Set([...selected, recordFor(selection?.anchorNode), recordFor(selection?.focusNode)].filter(Boolean));
        selected.clear();
        // 保留跨段选择经过的中间段落，清除选区时一并恢复，不能只记两端。
        for (const record of candidates) refresh(record);
      });
      finePointer.addEventListener('change', () => {
        const old = hovered; hovered = null; refresh(old);
      });
      const restoreAttribute = (node, name, value) => {
        if (value === null) node.removeAttribute(name); else node.setAttribute(name, value);
      };
      const unwrap = id => {
        const record = records.get(id);
        if (!record) return;
        const {source, aside, host} = record;
        source.classList.remove('paper-rss-source-layer');
        for (const node of [source, aside]) {
          node.removeAttribute('data-paper-hidden');
          restoreAttribute(node, 'aria-hidden', node === source ? record.sourceAria : record.asideAria);
          node.inert = node === source ? record.sourceInert : record.asideInert;
        }
        restoreAttribute(aside, 'style', record.asideStyle);
        if (record.container) {
          record.container.append(...source.childNodes);
          record.container.after(aside);
          host.remove();
        } else {
          host.replaceWith(source, aside);
        }
        records.delete(id);
        if (hovered === record) hovered = null;
        if (focused === record) focused = null;
        if (pressed === record) pressed = null;
        selected.delete(record);
      };
      const reconcile = id => {
        let source = document.querySelector('[data-paper-rss-id="' + CSS.escape(id) + '"]');
        const aside = document.getElementById('paper-rss-translation-' + id);
        if (!source || !aside || aside.classList.contains('is-loading') ||
            document.documentElement.dataset.paperTranslationMode !== 'replacement') {
          unwrap(id); return;
        }
        if (records.has(id)) return;
        const computed = getComputedStyle(source);
        // 列表项、定义及图注保留外层标签，在其内部叠放，避免非法父子结构。
        const container = ['LI', 'DT', 'DD', 'FIGCAPTION'].includes(source.tagName) ? source : null;
        const host = document.createElement('div');
        host.className = 'paper-rss-replacement';
        host.dataset.translationId = id;
        host.tabIndex = 0;
        host.setAttribute('role', 'group');
        host.setAttribute('aria-label', window.paperRssSelectionOptions?.labels?.showOriginal || '查看原文');
        host.style.marginTop = container ? '0px' : computed.marginTop;
        host.style.marginBottom = container ? '0px' : computed.marginBottom;
        const typography = {};
        for (const property of ['font-family', 'font-size', 'font-weight', 'font-style', 'line-height', 'letter-spacing', 'text-align']) {
          typography[property] = computed.getPropertyValue(property);
        }
        if (container) {
          source = document.createElement('div');
          source.append(...container.childNodes);
        }
        const record = {source, aside, host, container, original: null,
          sourceAria: source.getAttribute('aria-hidden'), asideAria: aside.getAttribute('aria-hidden'),
          sourceInert: source.inert, asideInert: aside.inert, asideStyle: aside.getAttribute('style')};
        for (const [property, value] of Object.entries(typography)) aside.style.setProperty(property, value);
        if (container) container.append(host); else source.before(host);
        host.append(source, aside);
        source.classList.add('paper-rss-source-layer');
        records.set(id, record);
        show(record, hasFocus(record));
      };
      window.paperRssTranslationPresentation = {
        reconcile,
        remove: unwrap,
        setLabel: label => {
          if (label) for (const record of records.values()) record.host.setAttribute('aria-label', label);
        },
        setPreferences: (mode, color, refreshTypography = false) => {
          const root = document.documentElement;
          root.style.setProperty('--paper-translation-color', color);
          const changed = root.dataset.paperTranslationMode !== mode;
          root.dataset.paperTranslationMode = mode;
          if (!changed && !refreshTypography) return;
          // 仅切换模式或排版时遍历完成态；分批译文只更新对应 ID。
          for (const id of Array.from(records.keys())) unwrap(id);
          if (mode === 'replacement') {
            document.querySelectorAll('[data-paper-rss-translation-for]').forEach(node => {
              reconcile(node.dataset.paperRssTranslationFor);
            });
          }
          window.dispatchEvent(new Event('paperRssLayoutRefresh'));
        }
      };
    }
    """
}
