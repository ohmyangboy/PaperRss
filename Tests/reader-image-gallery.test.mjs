import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8',
);

function gallerySwiftLiteral() {
  return source.match(
    /static let imageGalleryScript = WKUserScript\(\n\s+source: """([\s\S]*?)""",\n\s+injectionTime:/,
  )?.[1] ?? '';
}

function galleryScript() {
  // Swift consumes one layer of backslash escaping in a multiline literal
  // before WKUserScript receives the JavaScript source.
  return gallerySwiftLiteral().replaceAll('\\\\', '\\');
}

class FakeClassList {
  #values = new Set();

  add(...values) { values.forEach((value) => this.#values.add(value)); }
  remove(...values) { values.forEach((value) => this.#values.delete(value)); }
  contains(value) { return this.#values.has(value); }
}

class FakeElement {
  constructor(tagName, text = '') {
    this.tagName = tagName.toUpperCase();
    this.textContent = text;
    this.children = [];
    this.parentNode = null;
    this.classList = new FakeClassList();
  }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  matches(selector) {
    return selector
      .split(',')
      .map((part) => part.trim())
      .some((part) => this.tagName.toLowerCase() === part.toLowerCase());
  }

  closest(selector) {
    let node = this;
    while (node) {
      if (node.matches(selector)) return node;
      node = node.parentNode;
    }
    return null;
  }

  querySelectorAll(selector) {
    const matches = [];
    const visit = (node) => {
      if (node.matches(selector)) matches.push(node);
      node.children.forEach(visit);
    };
    this.children.forEach(visit);
    return matches;
  }
}

function makeFixture(tree) {
  const body = new FakeElement('body');
  tree.forEach((node) => body.appendChild(node));
  const document = new FakeElement('#document');
  document.appendChild(body);
  const context = vm.createContext({ document, Array, String });
  return { document, body, context };
}

function runGalleryScript(fixture) {
  const script = galleryScript();
  assert.ok(script, 'imageGalleryScript must be extractable from Swift source');
  assert.doesNotThrow(() => new vm.Script(script), 'gallery script must be valid JavaScript');
  vm.runInContext(script, fixture.context);
}

const image = (alt = '') => new FakeElement('img', alt);

test('div wrapping two or more imgs with no visible text is normalized into paper-img-row', () => {
  const gallery = new FakeElement('div', '  ');
  gallery.appendChild(image());
  gallery.appendChild(image());
  const { context } = makeFixture([gallery]);

  runGalleryScript({ context });

  assert.equal(gallery.classList.contains('paper-img-row'), true, 'img-only div must become a wrap row');
});

test('three-image gallery div is normalized as well', () => {
  const gallery = new FakeElement('div');
  for (let index = 0; index < 3; index += 1) gallery.appendChild(image());
  const { context } = makeFixture([gallery]);

  runGalleryScript({ context });

  assert.equal(gallery.classList.contains('paper-img-row'), true);
});

test('div mixing img and non-img children is left untouched', () => {
  const mixed = new FakeElement('div');
  mixed.appendChild(image());
  const caption = new FakeElement('span', '图注文字');
  mixed.appendChild(caption);
  const { context } = makeFixture([mixed]);

  runGalleryScript({ context });

  assert.equal(mixed.classList.contains('paper-img-row'), false, 'img+caption div must not become a row');
});

test('single-image div is left untouched so per-image alignment classes keep working', () => {
  const single = new FakeElement('div');
  single.appendChild(image());
  const { context } = makeFixture([single]);

  runGalleryScript({ context });

  assert.equal(single.classList.contains('paper-img-row'), false, 'single-image div must not become a row');
});

test('div with visible text between images is left untouched', () => {
  const mixed = new FakeElement('div', '说明文字');
  mixed.appendChild(image());
  mixed.appendChild(image());
  // textContent is static in the fake; emulate realistic mixed content via child text instead
  const withChildText = new FakeElement('div');
  withChildText.appendChild(image());
  withChildText.appendChild(new FakeElement('b', '加粗说明'));
  withChildText.appendChild(image());

  const { context } = makeFixture([mixed, withChildText]);
  runGalleryScript({ context });

  assert.equal(mixed.classList.contains('paper-img-row'), false);
  assert.equal(withChildText.classList.contains('paper-img-row'), false, 'text-bearing div must not become a row');
});

test('img-only div inside pre/code is left untouched', () => {
  const pre = new FakeElement('pre');
  const code = new FakeElement('code');
  const gallery = new FakeElement('div');
  gallery.appendChild(image());
  gallery.appendChild(image());
  code.appendChild(gallery);
  pre.appendChild(code);
  const { context } = makeFixture([pre]);

  runGalleryScript({ context });

  assert.equal(gallery.classList.contains('paper-img-row'), false, 'code sample markup must never be re-laid-out');
});

test('already-normalized row div is not reprocessed', () => {
  const gallery = new FakeElement('div');
  gallery.classList.add('paper-img-row');
  gallery.appendChild(image());
  gallery.appendChild(image());
  const { context } = makeFixture([gallery]);

  runGalleryScript({ context });

  assert.equal(gallery.classList.contains('paper-img-row'), true);
});

test('nested gallery inside a plain wrapper div is still detected', () => {
  const wrapper = new FakeElement('div');
  const gallery = new FakeElement('div');
  gallery.appendChild(image());
  gallery.appendChild(image());
  wrapper.appendChild(gallery);
  const { context } = makeFixture([wrapper]);

  runGalleryScript({ context });

  assert.equal(gallery.classList.contains('paper-img-row'), true, 'inner gallery must be detected');
  assert.equal(wrapper.classList.contains('paper-img-row'), false, 'wrapper div must stay untouched');
});
