import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8',
);

function tocSwiftLiteral() {
  return source.match(
    /static let tocRailScript = WKUserScript\(\n\s+source: """([\s\S]*?)""",\n\s+injectionTime:/,
  )?.[1] ?? '';
}

function tocScript() {
  // Swift consumes one layer of backslash escaping in a multiline literal
  // before WKUserScript receives the JavaScript source.
  return tocSwiftLiteral().replaceAll('\\\\', '\\');
}

class FakeClassList {
  #values = new Set();

  add(...values) { values.forEach((value) => this.#values.add(value)); }
  remove(...values) { values.forEach((value) => this.#values.delete(value)); }
  contains(value) { return this.#values.has(value); }
  toggle(value, force) {
    const next = force === undefined ? !this.contains(value) : force;
    if (next) this.add(value); else this.remove(value);
    return next;
  }
}

class FakeElement {
  constructor(tagName, text = '') {
    this.tagName = tagName.toUpperCase();
    this.textContent = text;
    this.children = [];
    this.parentNode = null;
    this.dataset = {};
    this.style = { display: '', height: '' };
    this.classList = new FakeClassList();
    this.attributes = new Map();
    this.listeners = new Map();
    this.capturedPointerId = null;
    this.absoluteTop = 0;
    this.rectHeight = 30;
  }

  appendChild(child) {
    child.parentNode = this;
    child.ownerDocument = this.ownerDocument;
    this.children.push(child);
    return child;
  }

  removeChild(child) {
    const index = this.children.indexOf(child);
    if (index >= 0) this.children.splice(index, 1);
    child.parentNode = null;
  }

  remove() { this.parentNode?.removeChild(this); }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
    if (name === 'id') this.id = String(value);
    if (name === 'class') this.className = String(value);
  }

  getAttribute(name) { return this.attributes.get(name) ?? null; }

  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) ?? [];
    listeners.push(listener);
    this.listeners.set(name, listeners);
  }

  setPointerCapture(pointerId) { this.capturedPointerId = pointerId; }
  releasePointerCapture(pointerId) {
    if (this.capturedPointerId === pointerId) this.capturedPointerId = null;
  }

  removeEventListener(name, listener) {
    const listeners = this.listeners.get(name) ?? [];
    this.listeners.set(name, listeners.filter((candidate) => candidate !== listener));
  }

  dispatchEvent(event) {
    event.target ??= this;
    for (const listener of this.listeners.get(event.type) ?? []) listener(event);
  }

  getBoundingClientRect() {
    const scrollY = this.ownerDocument?.defaultView?.scrollY ?? 0;
    return {
      top: this.absoluteTop - scrollY,
      bottom: this.absoluteTop - scrollY + this.rectHeight,
      height: this.rectHeight,
    };
  }

  matches(selector) {
    if (selector === '.paper-header-title') return this.classList.contains('paper-header-title');
    if (selector.startsWith('.')) return this.classList.contains(selector.slice(1));
    if (selector === '[data-paper-toc-button]') return this.dataset.paperTocButton !== undefined;
    if (selector.startsWith('#')) return this.id === selector.slice(1);
    if (/^h[1-6]$/i.test(selector)) return /^H[1-6]$/.test(this.tagName);
    if (selector.includes(',')) return selector.split(',').some((part) => this.matches(part.trim()));
    return this.tagName.toLowerCase() === selector.toLowerCase();
  }

  closest(selector) {
    let node = this;
    while (node) {
      if (node.matches(selector)) return node;
      node = node.parentNode;
    }
    return false;
  }

  querySelectorAll(selector) {
    const selectors = selector.split(',').map((part) => part.trim());
    const matches = [];
    const visit = (node) => {
      if (selectors.some((part) => node.matches(part))) matches.push(node);
      node.children.forEach(visit);
    };
    this.children.forEach(visit);
    return matches;
  }

  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
}

class FakeDocument extends FakeElement {
  constructor() {
    super('#document');
    this.documentElement = new FakeElement('html');
    this.head = new FakeElement('head');
    this.body = new FakeElement('body');
    this.documentElement.ownerDocument = this;
    this.head.ownerDocument = this;
    this.body.ownerDocument = this;
    this.documentElement.appendChild(this.head);
    this.documentElement.appendChild(this.body);
    this.scrollHeight = 2400;
    this.clientHeight = 800;
    this.documentElement.scrollHeight = this.scrollHeight;
    this.body.scrollHeight = this.scrollHeight;
    this.listeners = new Map();
  }

  createElement(tagName) {
    const node = new FakeElement(tagName);
    node.ownerDocument = this;
    return node;
  }

  querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); }
  querySelector(selector) { return this.documentElement.querySelector(selector); }
  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) ?? [];
    listeners.push(listener);
    this.listeners.set(name, listeners);
  }
  removeEventListener(name, listener) {
    const listeners = this.listeners.get(name) ?? [];
    this.listeners.set(name, listeners.filter((candidate) => candidate !== listener));
  }
  dispatchEvent(event) {
    for (const listener of this.listeners.get(event.type) ?? []) listener(event);
  }
  getElementById(id) { return this.querySelector(`#${id}`); }
}

function makeFixture() {
  const document = new FakeDocument();
  const window = {
    scrollY: 0,
    innerHeight: 800,
    innerWidth: 900,
    reduceMotion: false,
    listeners: new Map(),
    scrollCalls: [],
    timers: new Map(),
    nextTimerID: 1,
    addEventListener(name, listener) {
      const listeners = this.listeners.get(name) ?? [];
      listeners.push(listener);
      this.listeners.set(name, listeners);
    },
    removeEventListener(name, listener) {
      const listeners = this.listeners.get(name) ?? [];
      this.listeners.set(name, listeners.filter((candidate) => candidate !== listener));
    },
    dispatchEvent(event) {
      for (const listener of this.listeners.get(event.type) ?? []) listener(event);
    },
    scrollTo(options) {
      this.scrollCalls.push(options);
      this.scrollY = typeof options === 'number' ? options : options.top;
    },
    requestAnimationFrame(callback) { callback(); return 1; },
    matchMedia(query) {
      return { matches: this.reduceMotion && query === '(prefers-reduced-motion: reduce)' };
    },
    setTimeout(callback, delay = 0) {
      const id = this.nextTimerID++;
      this.timers.set(id, { callback, at: delay });
      return id;
    },
    clearTimeout(id) { this.timers.delete(id); },
    advanceTime(milliseconds) {
      for (const [id, timer] of [...this.timers]) {
        timer.at -= milliseconds;
        if (timer.at <= 0) {
          this.timers.delete(id);
          timer.callback();
        }
      }
    },
  };
  window.document = document;
  document.defaultView = window;
  document.body.ownerDocument = document;
  document.documentElement.ownerDocument = document;

  const title = new FakeElement('h1', '  A Title!  ');
  title.classList.add('paper-header-title');
  title.absoluteTop = 84;
  document.body.appendChild(title);
  const duplicate = new FakeElement('h2', 'A   Title');
  duplicate.absoluteTop = 300;
  document.body.appendChild(duplicate);
  const section = new FakeElement('h2', 'Second Section');
  section.absoluteTop = 1100;
  document.body.appendChild(section);
  const final = new FakeElement('h3', 'Final Section');
  final.absoluteTop = 2050;
  document.body.appendChild(final);

  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback;
      fixtureMutationObserver = this;
    }
    observe() {}
    disconnect() {}
    trigger(records = []) { this.callback(records); }
  }
  let fixtureMutationObserver;
  const context = vm.createContext({
    window,
    document,
    MutationObserver: FakeMutationObserver,
    ResizeObserver: class { observe() {} disconnect() {} },
    getComputedStyle: (node) => ({
      display: node.display ?? 'block',
      visibility: node.visibility ?? 'visible',
      lineHeight: `${node.lineHeight ?? 27}px`,
    }),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    setTimeout: window.setTimeout.bind(window),
    clearTimeout: window.clearTimeout.bind(window),
    console,
  });
  return { context, document, window, title, duplicate, section, final, get mutationObserver() { return fixtureMutationObserver; } };
}

function runRail(fixture) {
  const script = tocScript();
  assert.ok(script, 'macOS TOC rail script must be extractable from Swift source');
  vm.runInContext(script, fixture.context);
  return fixture.document.querySelector('#paper-rss-toc-rail');
}

const longParagraph = (label) => `${label}. ${'This is enough body copy to occupy many visible lines in the reader and provide a stable fallback chapter excerpt. '.repeat(3)}`;

function makeFallbackFixture() {
  const fixture = makeFixture();
  for (const child of [...fixture.document.body.children]) {
    if (child !== fixture.title) child.remove();
  }
  ['First fallback', 'Middle fallback', 'Last fallback'].forEach((label, index) => {
    const paragraph = new FakeElement('p', longParagraph(label));
    paragraph.absoluteTop = 700 + index * 900;
    paragraph.rectHeight = 180;
    paragraph.lineHeight = 27;
    fixture.document.body.appendChild(paragraph);
  });
  fixture.document.scrollHeight = 4200;
  fixture.document.documentElement.scrollHeight = 4200;
  fixture.document.body.scrollHeight = 4200;
  return fixture;
}

test('macOS injects the TOC rail script while iOS does not', () => {
  assert.match(source, /static let tocRailScript = WKUserScript/);
  const macOSStart = source.indexOf('private struct ArticleHTMLView: NSViewRepresentable');
  const iOSStart = source.indexOf('private struct ArticleHTMLView: UIViewRepresentable');
  const macOSBody = source.slice(macOSStart, iOSStart);
  const iOSBody = source.slice(iOSStart);
  assert.match(macOSBody, /addUserScript\(PaperReaderBridge\.tocRailScript\)/);
  assert.doesNotMatch(iOSBody, /addUserScript\(PaperReaderBridge\.tocRailScript\)/);
});

test('Swift multiline escaping preserves valid JavaScript Unicode regexes', () => {
  const swiftLiteral = tocSwiftLiteral();
  assert.ok(swiftLiteral.includes('\\\\s'), 'Swift source must escape the JS whitespace regex');
  assert.ok(swiftLiteral.includes('\\\\p{L}'), 'Swift source must escape the JS Unicode property regex');
  const script = tocScript();
  assert.ok(script.includes('.replace(/\\s+/g'), 'WKUserScript must receive a single JS whitespace escape');
  assert.ok(script.includes('.replace(/[^\\p{L}\\p{N}]+/gu'), 'WKUserScript must receive single JS Unicode escapes');
  assert.doesNotThrow(() => new vm.Script(script));
});

test('long articles expose synthetic title and ordered heading anchors without a duplicate first heading', () => {
  const fixture = makeFixture();
  const rail = runRail(fixture);
  assert.ok(rail, 'long article with three anchors should show a rail');
  const buttons = rail.querySelectorAll('[data-paper-toc-button]');
  assert.equal(buttons.length, 3);
  assert.deepEqual(buttons.map((button) => button.dataset.paperTocLabel), [
    'A Title!', 'Second Section', 'Final Section',
  ]);
});

test('scrolling updates the current anchor and clicking navigates with a 24px safe offset', () => {
  const fixture = makeFixture();
  const rail = runRail(fixture);
  const buttons = rail.querySelectorAll('[data-paper-toc-button]');
  assert.equal(buttons[0].getAttribute('aria-current'), 'true');
  fixture.window.scrollY = 1200;
  fixture.document.dispatchEvent({ type: 'scroll' });
  assert.equal(buttons[1].getAttribute('aria-current'), 'true');
  buttons[2].dispatchEvent({ type: 'click', preventDefault() {} });
  assert.equal(fixture.window.scrollCalls.at(-1).top, 2026);
  assert.equal(fixture.window.scrollCalls.at(-1).behavior, 'smooth');
});

test('short articles restore native scrolling and repeated installation leaves one rail', () => {
  const fixture = makeFixture();
  const first = runRail(fixture);
  assert.equal(fixture.document.documentElement.classList.contains('paper-toc-rail-active'), true);
  fixture.document.scrollHeight = 1200;
  fixture.document.documentElement.scrollHeight = 1200;
  fixture.document.body.scrollHeight = 1200;
  fixture.window.paperRssTOCRail.refresh();
  assert.equal(fixture.document.querySelector('#paper-rss-toc-rail'), null);
  assert.equal(fixture.document.documentElement.classList.contains('paper-toc-rail-active'), false);

  fixture.document.scrollHeight = 2400;
  fixture.document.documentElement.scrollHeight = 2400;
  fixture.document.body.scrollHeight = 2400;
  const second = runRail(fixture);
  assert.notEqual(first, second);
  assert.equal(fixture.document.querySelectorAll('#paper-rss-toc-rail').length, 1);
});

test('long leaf paragraphs supplement sparse headings with first-sentence labels and excerpts', () => {
  const fixture = makeFallbackFixture();
  const rail = runRail(fixture);
  assert.ok(rail, 'long article with enough fallback paragraphs should show a rail');
  const buttons = rail.querySelectorAll('[data-paper-toc-button]');
  assert.equal(buttons.length, 3);
  assert.equal(buttons[1].dataset.paperTocLabel, 'First fallback.');
  assert.match(buttons[1].dataset.paperTocExcerpt, /stable fallback chapter excerpt/);
  assert.equal(buttons[2].dataset.paperTocLabel, 'Last fallback.');
});

test('insufficient fallback candidates keep native scrolling and do not promote bold text to headings', () => {
  const fixture = makeFallbackFixture();
  for (const child of [...fixture.document.body.children]) {
    if (child !== fixture.title && child.tagName === 'P') child.remove();
  }
  const paragraph = new FakeElement('p', longParagraph('Only fallback'));
  paragraph.rectHeight = 180;
  paragraph.lineHeight = 27;
  fixture.document.body.appendChild(paragraph);
  const bold = new FakeElement('strong', longParagraph('Bold block'));
  fixture.document.body.appendChild(bold);
  const rail = runRail(fixture);
  assert.equal(rail, null);
  assert.equal(fixture.document.documentElement.classList.contains('paper-toc-rail-active'), false);
});

test('more than 18 anchors use deterministic position buckets while retaining first and last', () => {
  const fixture = makeFixture();
  for (const child of [...fixture.document.body.children]) {
    if (child !== fixture.title) child.remove();
  }
  for (let index = 0; index < 24; index += 1) {
    const heading = new FakeElement(index % 4 === 0 ? 'h2' : 'h4', `Section ${index + 1}`);
    heading.absoluteTop = 200 + index * 260;
    fixture.document.body.appendChild(heading);
  }
  fixture.document.scrollHeight = 8000;
  fixture.document.documentElement.scrollHeight = 8000;
  fixture.document.body.scrollHeight = 8000;
  const firstRail = runRail(fixture);
  const firstLabels = firstRail.querySelectorAll('[data-paper-toc-button]').map((button) => button.dataset.paperTocLabel);
  assert.equal(firstLabels.length, 18);
  assert.equal(firstRail.style.height, '324px');
  assert.equal(firstLabels[0], 'A Title!');
  assert.equal(firstLabels.at(-1), 'Section 24');
  fixture.window.paperRssTOCRail.refresh();
  const secondLabels = fixture.document.querySelector('#paper-rss-toc-rail')
    .querySelectorAll('[data-paper-toc-button]')
    .map((button) => button.dataset.paperTocLabel);
  assert.deepEqual(secondLabels, firstLabels);
  fixture.window.scrollY = 12000;
  fixture.window.paperRssTOCRail.refresh();
  const scrolledLabels = fixture.document.querySelector('#paper-rss-toc-rail')
    .querySelectorAll('[data-paper-toc-button]')
    .map((button) => button.dataset.paperTocLabel);
  assert.deepEqual(scrolledLabels, firstLabels, 'scroll position must not change location-based sampling');
});

test('dynamic mutations can disable and restore the rail without duplicate DOM or observer loops', () => {
  const fixture = makeFixture();
  const firstRail = runRail(fixture);
  fixture.mutationObserver.trigger([{ target: fixture.document.body }]);
  const rebuiltRail = fixture.document.querySelector('#paper-rss-toc-rail');
  assert.notEqual(rebuiltRail, firstRail);
  assert.equal(fixture.document.querySelectorAll('#paper-rss-toc-rail').length, 1);

  fixture.document.scrollHeight = 1000;
  fixture.document.documentElement.scrollHeight = 1000;
  fixture.document.body.scrollHeight = 1000;
  fixture.mutationObserver.trigger([{ target: fixture.document.body }]);
  assert.equal(fixture.document.querySelector('#paper-rss-toc-rail'), null);
  assert.equal(fixture.document.documentElement.classList.contains('paper-toc-rail-active'), false);

  fixture.document.scrollHeight = 2400;
  fixture.document.documentElement.scrollHeight = 2400;
  fixture.document.body.scrollHeight = 2400;
  fixture.mutationObserver.trigger([{ target: fixture.document.body }]);
  assert.equal(fixture.document.querySelectorAll('#paper-rss-toc-rail').length, 1);
  assert.ok(source.includes('root.appendChild(rail)'), 'rail must live outside the observed body subtree');
});

test('fallback supplementation uses document distance when candidates are heavily clustered', () => {
  const fixture = makeFixture();
  for (const child of [...fixture.document.body.children]) {
    if (child !== fixture.title) child.remove();
  }
  const heading = new FakeElement('h2', 'Only heading');
  heading.absoluteTop = 200;
  fixture.document.body.appendChild(heading);
  [100, 110, 120, 15000, 15010].forEach((top, index) => {
    const paragraph = new FakeElement('p', longParagraph(`Candidate ${index + 1}`));
    paragraph.absoluteTop = top;
    paragraph.rectHeight = 180;
    paragraph.lineHeight = 27;
    fixture.document.body.appendChild(paragraph);
  });
  fixture.document.scrollHeight = 18000;
  fixture.document.documentElement.scrollHeight = 18000;
  fixture.document.body.scrollHeight = 18000;
  const labels = runRail(fixture).querySelectorAll('[data-paper-toc-button]')
    .map((button) => button.dataset.paperTocLabel);
  assert.ok(labels.some((label) => label === 'Candidate 4.'), 'supplement should cover the distant document region');
});

test('compression partitions by document distance instead of candidate index', () => {
  const fixture = makeFixture();
  for (const child of [...fixture.document.body.children]) {
    if (child !== fixture.title) child.remove();
  }
  for (let index = 0; index < 20; index += 1) {
    const heading = new FakeElement('h4', `Cluster ${index + 1}`);
    heading.absoluteTop = 100 + index;
    fixture.document.body.appendChild(heading);
  }
  [5000, 10000, 15000, 20000].forEach((top, index) => {
    const heading = new FakeElement('h4', `Distant ${index + 1}`);
    heading.absoluteTop = top;
    fixture.document.body.appendChild(heading);
  });
  fixture.document.scrollHeight = 22000;
  fixture.document.documentElement.scrollHeight = 22000;
  fixture.document.body.scrollHeight = 22000;
  const labels = runRail(fixture).querySelectorAll('[data-paper-toc-button]')
    .map((button) => button.dataset.paperTocLabel);
  assert.ok(labels.includes('Distant 3'), 'position buckets should include a distant middle region');
});

function addPreviewParagraph(fixture, top, text = longParagraph('A readable preview sentence')) {
  const paragraph = new FakeElement('p', text);
  paragraph.absoluteTop = top;
  paragraph.rectHeight = 180;
  paragraph.lineHeight = 27;
  fixture.document.body.appendChild(paragraph);
  return paragraph;
}

test('heading preview skips wrapper containers and uses the first visible leaf block', () => {
  const fixture = makeFixture();
  const wrapper = new FakeElement('div', longParagraph('Wrapper text should not be used as the preview'));
  wrapper.absoluteTop = 180;
  const paragraph = new FakeElement('p', longParagraph('Actual leaf preview sentence'));
  paragraph.absoluteTop = 190;
  wrapper.appendChild(paragraph);
  fixture.document.body.appendChild(wrapper);
  const rail = runRail(fixture);
  const button = rail.querySelectorAll('[data-paper-toc-button]')[0];
  button.dispatchEvent({ type: 'mouseenter', relatedTarget: null });
  fixture.window.advanceTime(150);
  const excerpt = fixture.document.querySelector('.paper-toc-preview-excerpt').textContent;
  assert.match(excerpt, /Actual leaf preview sentence/);
  assert.doesNotMatch(excerpt, /Wrapper text should not be used/);
});

test('hover preview waits 150ms, shows current DOM title and excerpt, and stays within a narrow viewport', () => {
  const fixture = makeFixture();
  fixture.window.innerWidth = 400;
  const paragraph = addPreviewParagraph(fixture, 180);
  const rail = runRail(fixture);
  const button = rail.querySelectorAll('[data-paper-toc-button]')[0];
  button.dispatchEvent({ type: 'mouseenter', relatedTarget: null });
  assert.equal(fixture.document.querySelector('#paper-rss-toc-preview'), null);
  fixture.window.advanceTime(149);
  assert.equal(fixture.document.querySelector('#paper-rss-toc-preview'), null);
  fixture.window.advanceTime(1);
  const card = fixture.document.querySelector('#paper-rss-toc-preview');
  assert.ok(card);
  assert.equal(card.querySelector('.paper-toc-preview-title').textContent, 'A Title!');
  assert.match(card.querySelector('.paper-toc-preview-excerpt').textContent, /readable preview sentence/);
  assert.equal(card.style.width, '336px');
  assert.equal(card.style.right, '48px');
  assert.ok(paragraph);
});

test('moving from a button to its card does not flash closed, while leaving or Escape closes it', () => {
  const fixture = makeFixture();
  const rail = runRail(fixture);
  const button = rail.querySelectorAll('[data-paper-toc-button]')[1];
  button.dispatchEvent({ type: 'mouseenter', relatedTarget: null });
  fixture.window.advanceTime(150);
  const card = fixture.document.querySelector('#paper-rss-toc-preview');
  button.dispatchEvent({ type: 'mouseleave', relatedTarget: card });
  card.dispatchEvent({ type: 'mouseenter', relatedTarget: button });
  fixture.window.advanceTime(100);
  assert.ok(fixture.document.querySelector('#paper-rss-toc-preview'));
  card.dispatchEvent({ type: 'mouseleave', relatedTarget: null });
  fixture.window.advanceTime(100);
  assert.equal(fixture.document.querySelector('#paper-rss-toc-preview'), null);

  button.dispatchEvent({ type: 'mouseenter', relatedTarget: null });
  fixture.window.advanceTime(150);
  rail.dispatchEvent({ type: 'mouseleave', relatedTarget: null });
  fixture.window.advanceTime(100);
  assert.equal(fixture.document.querySelector('#paper-rss-toc-preview'), null);

  button.dispatchEvent({ type: 'mouseenter', relatedTarget: null });
  fixture.window.advanceTime(150);
  fixture.document.dispatchEvent({ type: 'keydown', key: 'Escape' });
  assert.equal(fixture.document.querySelector('#paper-rss-toc-preview'), null);
});

test('dynamic DOM changes update the open preview and pointerdown closes without blocking navigation', () => {
  const fixture = makeFixture();
  const paragraph = addPreviewParagraph(fixture, 180, longParagraph('Original preview text'));
  const rail = runRail(fixture);
  const button = rail.querySelectorAll('[data-paper-toc-button]')[0];
  button.dispatchEvent({ type: 'mouseenter', relatedTarget: null });
  fixture.window.advanceTime(150);
  assert.match(fixture.document.querySelector('.paper-toc-preview-excerpt').textContent, /Original preview text/);

  paragraph.textContent = longParagraph('Updated translated preview text');
  fixture.mutationObserver.trigger([{ target: fixture.document.body }]);
  assert.match(fixture.document.querySelector('.paper-toc-preview-excerpt').textContent, /Updated translated preview text/);

  let prevented = false;
  fixture.document.querySelector('#paper-rss-toc-rail').dispatchEvent({
    type: 'pointerdown',
    preventDefault() { prevented = true; },
  });
  assert.equal(prevented, false);
  assert.equal(fixture.document.querySelector('#paper-rss-toc-preview'), null);
});

test('keyboard activation honors Enter and Space and reduced motion uses an immediate jump', () => {
  const fixture = makeFixture();
  fixture.window.reduceMotion = true;
  const rail = runRail(fixture);
  const button = rail.querySelectorAll('[data-paper-toc-button]')[1];
  let prevented = false;
  let stopped = false;
  button.dispatchEvent({
    type: 'keydown',
    key: 'Enter',
    preventDefault() { prevented = true; },
    stopPropagation() { stopped = true; },
  });
  assert.equal(prevented, true);
  assert.equal(stopped, true);
  assert.equal(fixture.window.scrollCalls.at(-1).top, 1076);
  assert.equal(fixture.window.scrollCalls.at(-1).behavior, 'auto');

  button.dispatchEvent({
    type: 'keydown',
    key: ' ',
    preventDefault() { prevented = true; },
    stopPropagation() { stopped = true; },
  });
  assert.equal(stopped, true);
  assert.equal(fixture.window.scrollCalls.at(-1).top, 1076);
  assert.equal(fixture.window.scrollCalls.at(-1).behavior, 'auto');

  let bodyStopped = false;
  fixture.document.dispatchEvent({
    type: 'keydown',
    key: ' ',
    stopPropagation() { bodyStopped = true; },
  });
  assert.equal(bodyStopped, false, '正文 Space remains available to the existing reader shortcut');
});

test('only the current indicator captures drag, maps rail position continuously, and suppresses the follow-up click', () => {
  const fixture = makeFixture();
  const rail = runRail(fixture);
  rail.getBoundingClientRect = () => ({ top: 100, bottom: 500, height: 400 });
  const buttons = rail.querySelectorAll('[data-paper-toc-button]');
  const current = buttons[0];
  const other = buttons[1];
  other.dispatchEvent({ type: 'pointerdown', pointerId: 2, button: 0, clientY: 200 });
  assert.equal(other.capturedPointerId, null);

  let prevented = false;
  current.dispatchEvent({
    type: 'mouseenter',
    relatedTarget: null,
  });
  fixture.window.advanceTime(150);
  assert.ok(fixture.document.querySelector('#paper-rss-toc-preview'));
  current.dispatchEvent({
    type: 'pointerdown',
    pointerId: 7,
    button: 0,
    clientY: 100,
    preventDefault() { prevented = true; },
  });
  assert.equal(prevented, false);
  assert.equal(current.capturedPointerId, 7);
  assert.equal(fixture.document.querySelector('#paper-rss-toc-preview'), null);

  current.dispatchEvent({ type: 'pointermove', pointerId: 7, clientY: 100 });
  assert.equal(fixture.window.scrollCalls.at(-1).top, 0);
  current.dispatchEvent({ type: 'pointermove', pointerId: 7, clientY: 500 });
  assert.equal(fixture.window.scrollCalls.at(-1).top, 1600);
  assert.equal(buttons[1].getAttribute('aria-current'), 'true');
  current.dispatchEvent({ type: 'pointerup', pointerId: 7, clientY: 500 });
  assert.equal(current.capturedPointerId, null);
  const callsAfterDrag = fixture.window.scrollCalls.length;
  current.dispatchEvent({ type: 'click', preventDefault() {} });
  assert.equal(fixture.window.scrollCalls.length, callsAfterDrag);
});

test('TOC rail navigation label follows the current localized WebView options', () => {
  const fixture = makeFixture();
  fixture.window.paperRssSelectionOptions = {
    labels: { tocRailLabel: '章节导航' },
  };
  const rail = runRail(fixture);
  assert.equal(rail.getAttribute('aria-label'), '章节导航');

  fixture.window.paperRssSelectionOptions.labels.tocRailLabel = 'Article Navigation';
  const refreshedRail = runRail(fixture);
  assert.equal(refreshedRail.getAttribute('aria-label'), 'Article Navigation');
  assert.equal(fixture.document.querySelectorAll('#paper-rss-toc-rail').length, 1);
});
