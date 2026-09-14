import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8'
);

const appSource = await readFile(
  new URL('../PaperRss/Sources/App/PaperRssApp.swift', import.meta.url),
  'utf8'
);

const helpSource = await readFile(
  new URL('../PaperRss/Sources/App/KeyboardShortcutHelpView.swift', import.meta.url),
  'utf8'
);

const bindingsSource = await readFile(
  new URL('../PaperRss/Sources/Core/ReaderShortcutBindings.swift', import.meta.url),
  'utf8'
);

const editorSource = await readFile(
  new URL('../PaperRss/Sources/App/ReaderShortcutEditorView.swift', import.meta.url),
  'utf8'
);

const script = source.match(
  /static let readerShortcutScript = WKUserScript\(\n        source: """([\s\S]*?)""",\n        injectionTime:/
)?.[1]?.replace(/\\\(readerShortcutMessageName\)/g, 'paperRssReaderShortcut') ?? '';

const scrollScript = source.match(
  /static let spacebarScript = WKUserScript\(\n        source: """([\s\S]*?)""",\n        injectionTime:/
)?.[1]
  ?.replace(/\\\(nextArticleMessageName\)/g, 'paperRssNextArticle')
  ?.replace(/\\\(focusListMessageName\)/g, 'paperRssFocusList') ?? '';

function codeFor(key) {
  if (key === ' ') return 'Space';
  if (key.length === 1) {
    if (/[a-z]/i.test(key)) return `Key${key.toUpperCase()}`;
    if (/[0-9]/.test(key)) return `Digit${key}`;
    return key;
  }
  return key;
}

function installReaderShortcutHandler({
  activeElement = null,
  selection = '',
  hasTransientReaderUI = false,
  bindings = undefined
} = {}) {
  let keydown;
  const messages = [];
  const window = {
    addEventListener(type, handler) {
      if (type === 'keydown') keydown = handler;
    },
    getSelection() {
      return { toString: () => selection, isCollapsed: selection.length === 0 };
    },
    paperRssShortcutBindings: bindings,
    webkit: {
      messageHandlers: {
        paperRssReaderShortcut: {
          postMessage(message) { messages.push(message); }
        }
      }
    }
  };
  const document = {
    activeElement,
    querySelector() { return hasTransientReaderUI ? {} : null; }
  };

  vm.runInNewContext(script, { window, document });
  assert.equal(typeof keydown, 'function', 'reader shortcut script must install a keydown handler');
  return { keydown, messages };
}

function keyboardEvent(key, overrides = {}) {
  return {
    key,
    code: overrides.code ?? codeFor(key),
    defaultPrevented: false,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    repeat: false,
    isComposing: false,
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true; },
    stopPropagation() { this.stopped = true; },
    ...overrides
  };
}

test('every bare reader key publishes its native action and consumes the event', () => {
  const mappings = {
    C: 'toggleBilingual',
    V: 'showSummary',
    K: 'previousArticle',
    J: 'nextArticle',
    M: 'toggleStar',
    F: 'toggleFullScreen',
    O: 'openOriginal'
  };

  for (const [key, action] of Object.entries(mappings)) {
    const harness = installReaderShortcutHandler();
    const event = keyboardEvent(key);

    harness.keydown(event);

    assert.equal(harness.messages.length, 1, `${key} must publish one action`);
    assert.equal(harness.messages[0].action, action);
    assert.equal(event.prevented, true);
    assert.equal(event.stopped, true);
  }
});

test('modified and repeated keys remain available to system shortcuts', () => {
  for (const overrides of [
    { metaKey: true },
    { altKey: true },
    { ctrlKey: true },
    { shiftKey: true },
    { repeat: true },
    { isComposing: true },
    { defaultPrevented: true }
  ]) {
    const harness = installReaderShortcutHandler();
    const event = keyboardEvent('c', overrides);
    harness.keydown(event);
    assert.deepEqual(harness.messages, []);
    assert.equal(event.prevented, false);
  }
});

test('injected bindings drive the dispatch and replace the defaults', () => {
  const bindings = {
    toggleBilingual: { base: 'KeyC', command: false, option: false, control: false, shift: false },
    showSummary: { base: 'KeyV', command: false, option: false, control: false, shift: false },
    previousArticle: { base: 'ArrowUp', command: false, option: true, control: false, shift: false },
    nextArticle: { base: 'ArrowDown', command: false, option: true, control: false, shift: false },
    toggleStar: { base: 'KeyM', command: true, option: false, control: false, shift: false },
    toggleFullScreen: { base: 'KeyF', command: false, option: false, control: false, shift: false },
    openOriginal: { base: 'KeyO', command: false, option: false, control: false, shift: false }
  };
  const harness = installReaderShortcutHandler({ bindings });

  const upper = keyboardEvent('ArrowUp', { code: 'ArrowUp', altKey: true });
  harness.keydown(upper);
  assert.equal(harness.messages[0]?.action, 'previousArticle');
  assert.equal(upper.prevented, true);

  const star = keyboardEvent('m', { code: 'KeyM', metaKey: true });
  harness.keydown(star);
  assert.equal(harness.messages[1]?.action, 'toggleStar');

  // 旧默认键已不再是绑定：普通 K 必须放行给页面/系统。
  const plainK = keyboardEvent('k', { code: 'KeyK' });
  harness.keydown(plainK);
  assert.equal(harness.messages.length, 2);
  assert.equal(plainK.prevented, false);
});

test('typing selection and transient reader UI block article shortcuts', () => {
  const contexts = [
    { activeElement: { tagName: 'INPUT', isContentEditable: false } },
    { activeElement: { tagName: 'TEXTAREA', isContentEditable: false } },
    { activeElement: { tagName: 'SELECT', isContentEditable: false } },
    { activeElement: { tagName: 'DIV', isContentEditable: true } },
    { selection: 'selected article text' },
    { hasTransientReaderUI: true }
  ];

  for (const context of contexts) {
    const harness = installReaderShortcutHandler(context);
    const event = keyboardEvent('c');
    harness.keydown(event);
    assert.deepEqual(harness.messages, []);
    assert.equal(event.prevented, false);
  }
});

function installScrollHandler({ bindings = undefined, scrollHeight = 100 } = {}) {
  let keydown;
  const messages = [];
  const window = {
    addEventListener(type, handler) {
      if (type === 'keydown') keydown = handler;
    },
    innerHeight: 100,
    scrollY: scrollHeight - 100,
    paperRssReaderInteractive: true,
    paperRssShortcutBindings: bindings,
    scrollTo(options) { this.scrolled = options; },
    getSelection() { return { toString: () => '' }; },
    webkit: {
      messageHandlers: {
        paperRssNextArticle: { postMessage() { messages.push('next'); } },
        paperRssFocusList: { postMessage() { messages.push('focus'); } }
      }
    }
  };
  const document = {
    activeElement: null,
    body: { scrollHeight },
    documentElement: { scrollHeight, scrollTop: 0 }
  };

  vm.runInNewContext(scrollScript, { window, document });
  assert.equal(typeof keydown, 'function', 'spacebar script must install a keydown handler');
  return { keydown, messages, window };
}

test('scroll key uses the injected binding and releases a rebound Space', () => {
  const bottomBindings = {
    scrollDown: { base: 'KeyN', command: false, option: false, control: false, shift: false }
  };

  const rebound = installScrollHandler({ bindings: bottomBindings });
  const space = keyboardEvent(' ');
  rebound.keydown(space);
  assert.deepEqual(rebound.messages, [], 'Space must be released once scroll is rebound');
  assert.equal(space.prevented, false);

  const reboundKey = keyboardEvent('n', { code: 'KeyN' });
  rebound.keydown(reboundKey);
  assert.deepEqual(rebound.messages, ['next'], 'the bound key switches to the next article at the bottom');

  const legacy = installScrollHandler();
  const defaultSpace = keyboardEvent(' ');
  legacy.keydown(defaultSpace);
  assert.deepEqual(legacy.messages, ['next'], 'unbound documents keep the Space default');
  assert.equal(defaultSpace.prevented, true);
});

test('reader shortcut rejections use transient feedback instead of blocking alerts', () => {
  const handler = source.match(
    /private func handleReaderShortcut\(_ action: ReaderShortcutAction\) \{([\s\S]*?)\n    private var effectiveArticleText:/
  )?.[1] ?? '';

  assert.notEqual(handler, '', 'reader shortcut handler must remain discoverable');
  assert.doesNotMatch(handler, /store\.reportError/);
  assert.match(handler, /onShortcutFeedback/);
});

test('Help menu opens a dedicated window documenting every current shortcut', () => {
  assert.match(appSource, /KeyboardShortcutHelpCommands\(\)/);
  assert.match(appSource, /Window\([\s\S]*id: KeyboardShortcutHelpWindow\.id/);
  assert.match(helpSource, /CommandGroup\(replacing: \.help\)/);
  assert.match(helpSource, /openWindow\(id: KeyboardShortcutHelpWindow\.id\)/);

  for (const shortcut of [
    '["←"]', '["→"]', '["⌘", "⇧", "R"]', '["⌘", "+"]',
    '["⌘", "−"]', '["⌘", "0"]', '["⌘", "/"]'
  ]) {
    assert.ok(helpSource.includes(shortcut), `help must document ${shortcut}`);
  }

  // 文章阅读分组改为由绑定表驱动，并且只有它提供编辑入口。
  assert.match(helpSource, /ReaderShortcutAction\.allCases\.enumerated\(\)/);
  assert.match(helpSource, /ReaderShortcutPresentation\.title\(for: action\)/);
  assert.match(helpSource, /Image\(systemName: "pencil"\)/);
  assert.match(helpSource, /"×2"/);
  assert.doesNotMatch(helpSource, /reader-translate|reader-summary|reader-previous|reader-next|reader-star|reader-fullscreen|reader-space/);
  assert.match(editorSource, /防误触/);
  assert.match(editorSource, /连续按下两次才会触发/);
});

test('the reader shortcut help window uses the floating thin scrollbar', () => {
  assert.match(helpSource, /PaperFloatingScrollView \{/);
});

test('default bindings include the O + O open-original action', () => {
  assert.match(source, /openOriginal: \{ base: "KeyO", command: false, option: false, control: false, shift: false \}/);
  assert.match(bindingsSource, /\.openOriginal: ReaderShortcutBinding\(combo: ReaderShortcutCombo\(base: \.keyO\)\)/);
});
