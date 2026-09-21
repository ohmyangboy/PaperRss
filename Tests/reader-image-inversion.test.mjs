import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8',
);

function inversionScript() {
  // Swift 消耗一层反斜杠转义后再交给 WKUserScript。
  const literal = source.match(
    /static let imageInversionScript = WKUserScript\(\n\s+source: """([\s\S]*?)""",\n\s+injectionTime:/,
  )?.[1];
  assert.ok(literal, 'imageInversionScript 必须能从 Swift 源码中提取');
  return literal.replaceAll('\\\\', '\\');
}

class FakeImage {
  constructor(src, options = {}) {
    this.attributes = { src };
    this.classes = new Set(options.classes || []);
    this.currentSrc = options.currentSrc ?? src;
    const self = this;
    this.classList = {
      contains: value => self.classes.has(value),
      add: value => self.classes.add(value),
    };
  }

  getAttribute(name) {
    return this.attributes[name] ?? null;
  }
}

function createReader(images, baseURI = 'https://reader.example/articles/1') {
  const document = {
    baseURI,
    querySelectorAll: selector => (selector === 'img' ? images : []),
  };
  const window = {};
  const context = vm.createContext({ document, window, URL, Map, String });
  vm.runInContext(inversionScript(), context);
  return window.paperRssImageInversion;
}

test('原生判定命中的绝对 URL 给对应 img 打上 paper-img-invert', () => {
  const image = new FakeImage('https://cdn.example.com/line.png');
  const reader = createReader([image]);
  assert.equal(reader.apply(['https://cdn.example.com/line.png']), 1);
  assert.equal(image.classes.has('paper-img-invert'), true);
});

test('相对 src 按 baseURI 解析后同样命中', () => {
  const image = new FakeImage('/assets/formula.png');
  const reader = createReader([image], 'https://example.com/articles/1');
  assert.equal(reader.apply(['https://example.com/assets/formula.png']), 1);
  assert.equal(image.classes.has('paper-img-invert'), true);
});

test('行内公式小图已被 emoji 分类器标记，也必须反相（issue #41 行内场景）', () => {
  const inline = new FakeImage('https://cdn.example.com/inline.png', { classes: ['paper-emoji'] });
  const reader = createReader([inline]);
  assert.equal(reader.apply(['https://cdn.example.com/inline.png']), 1);
  assert.equal(inline.classes.has('paper-img-invert'), true, '小图不得被排除在反相之外');
  assert.equal(inline.classes.has('paper-emoji'), true, '行内布局标记必须保留');
});

test('未命中的图片保持原样', () => {
  const photo = new FakeImage('https://cdn.example.com/photo.png');
  const reader = createReader([photo]);
  assert.equal(reader.apply(['https://cdn.example.com/line.png']), 0);
  assert.equal(photo.classes.has('paper-img-invert'), false);
});

test('重复 apply 幂等：第二次返回 0 且不重复加类', () => {
  const image = new FakeImage('https://cdn.example.com/line.png');
  const reader = createReader([image]);
  assert.equal(reader.apply(['https://cdn.example.com/line.png']), 1);
  assert.equal(reader.apply(['https://cdn.example.com/line.png']), 0);
  assert.equal(image.classes.size, 1);
});

test('返回值是实际加类数量，同一 URL 的多张图片分别计数', () => {
  const first = new FakeImage('https://cdn.example.com/same.png');
  const second = new FakeImage('https://cdn.example.com/same.png', { classes: ['paper-emoji'] });
  const reader = createReader([first, second]);
  assert.equal(reader.apply(['https://cdn.example.com/same.png']), 2);
});

test('currentSrc 优先于 src 属性（懒加载站点改写 src 后仍能命中）', () => {
  const image = new FakeImage('data:image/gif;base64,R0lGOD', {
    currentSrc: 'https://cdn.example.com/real.png',
  });
  const reader = createReader([image]);
  assert.equal(reader.apply(['data:image/gif;base64,R0lGOD']), 0, '占位 src 不参与匹配');
  assert.equal(reader.apply(['https://cdn.example.com/real.png']), 1);
  assert.equal(image.classes.has('paper-img-invert'), true);
});

test('反相样式挂在深色纸面根类上，且只作用于受控类', () => {
  assert.match(
    source,
    /\.paper-scheme-dark img\.paper-img-invert \{\n  filter: invert\(1\) hue-rotate\(180deg\);/,
    '深色纸面下才反相，且必须保留色相',
  );
});

test('反相脚本在标准用户脚本安装表中注册', () => {
  const install = source.match(
    /static func installStandardUserScripts\(in controller: WKUserContentController\) \{[\s\S]*?\n    \}/,
  )?.[0];
  assert.ok(install);
  const galleryIndex = install.indexOf('controller.addUserScript(imageGalleryScript)');
  const inversionIndex = install.indexOf('controller.addUserScript(imageInversionScript)');
  assert.ok(galleryIndex >= 0 && inversionIndex > galleryIndex);
});
