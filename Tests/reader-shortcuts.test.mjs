import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8'
);

const script = source.match(
  /static let readerShortcutScript = WKUserScript\(\n        source: """([\s\S]*?)""",\n        injectionTime:/
)?.[1]?.replace(/\\\(readerShortcutMessageName\)/g, 'paperRssReaderShortcut') ?? '';

function installReaderShortcutHandler({
  activeElement = null,
  selection = '',
  hasTransientReaderUI = false
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
    B: 'previousArticle',
    N: 'nextArticle',
    M: 'toggleStar'
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

test('reader shortcut rejections use transient feedback instead of blocking alerts', () => {
  const handler = source.match(
    /private func handleReaderShortcut\(_ action: ReaderShortcutAction\) \{([\s\S]*?)\n    private var effectiveArticleText:/
  )?.[1] ?? '';

  assert.notEqual(handler, '', 'reader shortcut handler must remain discoverable');
  assert.doesNotMatch(handler, /store\.reportError/);
  assert.match(handler, /onShortcutFeedback/);
});
