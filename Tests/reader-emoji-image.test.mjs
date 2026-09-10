import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8',
);

function emojiScript() {
  // Swift 消耗一层反斜杠转义后再交给 WKUserScript。
  const literal = source.match(
    /static let imageEmojiScript = WKUserScript\(\n\s+source: """([\s\S]*?)""",\n\s+injectionTime:/,
  )?.[1];
  assert.ok(literal, 'imageEmojiScript 必须能从 Swift 源码中提取');
  return literal.replaceAll('\\\\', '\\');
}

class FakeElement {
  constructor(tagName, attributes = {}) {
    this.tagName = tagName.toUpperCase();
    this.attributes = attributes;
    this.classes = new Set();
    this.children = [];
    this.parentNode = null;
    this.listeners = new Map();
    this.complete = true;
    this.naturalWidth = 0;
    this.naturalHeight = 0;
    this.rect = null;
    const self = this;
    this.classList = {
      contains: value => self.classes.has(value),
      add: (...values) => values.forEach((value) => self.classes.add(value)),
      remove: (...values) => values.forEach((value) => self.classes.delete(value)),
    };
  }

  getAttribute(name) {
    const value = this.attributes[name];
    return value === undefined ? null : value;
  }

  get parentElement() {
    return this.parentNode;
  }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(listener);
  }

  dispatch(type) {
    (this.listeners.get(type) || []).forEach((listener) => listener());
  }

  getBoundingClientRect() {
    return this.rect || { width: 0, height: 0 };
  }

  matches(selector) {
    return selector.split(',').some((part) => {
      const token = part.trim();
      if (token.startsWith('.')) return this.classes.has(token.slice(1));
      if (token.startsWith('#')) return false;
      return this.tagName.toLowerCase() === token.toLowerCase();
    });
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

function runClassifier(images) {
  const body = new FakeElement('body');
  images.forEach(image => body.appendChild(image));
  const document = new FakeElement('#document');
  document.appendChild(body);
  const context = vm.createContext({ document, String, Number, parseInt });
  vm.runInContext(emojiScript(), context);
}

test('Discourse 论坛 emoji 小图（class=emoji + 20x20）标记为 paper-emoji', () => {
  const emoji = new FakeElement('img', {
    class: 'emoji',
    src: 'https://forum.example.com/images/emoji/apple/thinking.png?v=15',
    title: ':thinking:',
    alt: ':thinking:',
    width: '20',
    height: '20',
  });
  runClassifier([emoji]);
  assert.equal(emoji.classList.contains('paper-emoji'), true);
});

test('少数派表态图：仅声明 width=40 也标记为行内小图', () => {
  const reaction = new FakeElement('img', {
    src: 'https://cdnfile.sspai.com/2025/09/22/community/b3840c84-279c-d7ee-9af9-60da5a86fef7.png',
    alt: '鼓掌',
    width: '40',
  });
  runClassifier([reaction]);
  assert.equal(reaction.classList.contains('paper-emoji'), true);
});

test('少数派头像：URL 含 /avatar/ 或 avatar 占位图命名也标记', () => {
  const avatar = new FakeElement('img', {
    src: 'https://cdnfile.sspai.com/2023/07/19/avatar/f9c2d1d203dc09f5423cb0d5885d3b1d.png?imageMogr2/auto-orient/quality/90/ignore-error/1',
    alt: '张梦',
  });
  const placeholder = new FakeElement('img', {
    src: 'https://cdn-static.sspai.com/ui/otter_avatar_placeholder_240511.png',
    alt: 'Carl_Gu',
  });
  runClassifier([avatar, placeholder]);
  assert.equal(avatar.classList.contains('paper-emoji'), true);
  assert.equal(placeholder.classList.contains('paper-emoji'), true);
});

test('无任何声明与命名特征时，加载后实测渲染尺寸兜底标记', () => {
  const icon = new FakeElement('img', { src: 'https://example.com/assets/icon-1.png' });
  icon.complete = false;
  icon.naturalWidth = 32;
  icon.naturalHeight = 32;
  runClassifier([icon]);
  assert.equal(icon.classList.contains('paper-emoji'), false, '未加载前不做尺寸推断');
  icon.complete = true;
  icon.rect = { width: 32, height: 32 };
  icon.dispatch('load');
  assert.equal(icon.classList.contains('paper-emoji'), true, '加载后 32x32 小图必须行内化');
});

test('加载后实测大图不误判', () => {
  const large = new FakeElement('img', { src: 'https://example.com/assets/hero.png' });
  large.complete = false;
  runClassifier([large]);
  large.complete = true;
  large.naturalWidth = 1200;
  large.naturalHeight = 800;
  large.rect = { width: 1200, height: 800 };
  large.dispatch('load');
  assert.equal(large.classList.contains('paper-emoji'), false);
});

test('twemoji CDN 路径与 :shortcode: alt 都能识别', () => {
  const twemoji = new FakeElement('img', { src: 'https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/1f600.png' });
  const shortcodeAlt = new FakeElement('img', { src: 'https://cdn.example.com/a.png', alt: ':smile:' });
  runClassifier([twemoji, shortcodeAlt]);
  assert.equal(twemoji.classList.contains('paper-emoji'), true);
  assert.equal(shortcodeAlt.classList.contains('paper-emoji'), true);
});

test('正文照片（大图、无声明小尺寸、无 emoji 信号）不受影响', () => {
  const photo = new FakeElement('img', {
    src: 'https://example.com/photos/cover-hires.jpg',
    alt: 'Architecture diagram of the render engine',
    width: '1200',
    height: '800',
  });
  const undeclared = new FakeElement('img', { src: 'https://example.com/photos/cover.jpg' });
  undeclared.naturalWidth = 1600;
  undeclared.naturalHeight = 900;
  runClassifier([photo, undeclared]);
  assert.equal(photo.classList.contains('paper-emoji'), false);
  assert.equal(undeclared.classList.contains('paper-emoji'), false);
});

test('非方形小图（20x120 广告条）不当 emoji 处理', () => {
  const thumbnail = new FakeElement('img', { src: 'https://example.com/banner.png', width: '20', height: '120' });
  runClassifier([thumbnail]);
  assert.equal(thumbnail.classList.contains('paper-emoji'), false);
});

test('画廊行与正文说明卡内的图片不做尺寸推断', () => {
  const gallery = new FakeElement('div');
  gallery.classList.add('paper-img-row');
  const inGallery = new FakeElement('img', { src: 'https://example.com/assets/logo.png', width: '40' });
  gallery.appendChild(inGallery);
  runClassifier([gallery]);
  assert.equal(inGallery.classList.contains('paper-emoji'), false, '画廊成员由画廊布局管理');
});

test('少数派表态结构：仅含小图的 div 包装层回归行内，计数与图标同排', () => {
  // <span><div><img width=40></div><span>10</span></span>
  const outer = new FakeElement('span');
  const wrapper = new FakeElement('div');
  const image = new FakeElement('img', {
    src: 'https://cdnfile.sspai.com/2025/09/22/community/b3840c84-279c-d7ee-9af9-60da5a86fef7.png',
    alt: '鼓掌',
    width: '40',
  });
  const count = new FakeElement('span');
  wrapper.appendChild(image);
  outer.appendChild(wrapper);
  outer.appendChild(count);
  runClassifier([outer]);
  assert.equal(image.classList.contains('paper-emoji'), true);
  assert.equal(wrapper.classList.contains('paper-emoji-wrap'), true, '仅含小图的 div 必须取消块级布局');
  assert.equal(outer.classList.contains('paper-emoji-wrap'), false, '含其他内容的包装层不得收敛');
});

test('头像链接包装层收敛，图片容器不越界', () => {
  // <div><a href><img></a></div>
  const outer = new FakeElement('div');
  const link = new FakeElement('a', { href: 'https://sspai.com/u/x/updates' });
  const avatar = new FakeElement('img', {
    src: 'https://cdnfile.sspai.com/2023/07/19/avatar/f9c2.png?imageMogr2/auto-orient/quality/90/ignore-error/1',
    alt: '张梦',
  });
  link.appendChild(avatar);
  outer.appendChild(link);
  runClassifier([outer]);
  assert.equal(avatar.classList.contains('paper-emoji'), true);
  assert.equal(link.classList.contains('paper-emoji-wrap'), true);
  assert.equal(outer.classList.contains('paper-emoji-wrap'), true);
});

test('表格单元格中的小图不因包装收敛破坏表格结构', () => {
  const table = new FakeElement('table');
  const cell = new FakeElement('td');
  const image = new FakeElement('img', { src: 'https://example.com/assets/icon.png', width: '24' });
  cell.appendChild(image);
  table.appendChild(cell);
  runClassifier([table]);
  assert.equal(image.classList.contains('paper-emoji'), true);
  assert.equal(cell.classList.contains('paper-emoji-wrap'), false, 'td 不属于可收敛包装层');
});

test('emoji 脚本在画廊脚本之前注册，保证画廊排除依赖 class 就绪', () => {
  const install = source.match(
    /static func installStandardUserScripts\(in controller: WKUserContentController\) \{[\s\S]*?\n    \}/,
  )?.[0];
  assert.ok(install);
  const emojiIndex = install.indexOf('controller.addUserScript(imageEmojiScript)');
  const galleryIndex = install.indexOf('controller.addUserScript(imageGalleryScript)');
  assert.ok(emojiIndex >= 0 && galleryIndex > emojiIndex, 'emoji 分类必须先于画廊归一执行');
});

test('灯箱点击排除表情图，避免点击表情弹出全屏放大', () => {
  assert.match(
    source,
    /target\.classList\.contains\("paper-summary-icon"\).*target\.classList\.contains\("paper-emoji"\)/s,
    '表情图点击不应打开灯箱',
  );
});

test('表情图回归行内文字流的受控样式', () => {
  assert.match(source, /img\.paper-emoji \{[\s\S]*?display: inline-block;[\s\S]*?vertical-align: -0\.18em;[\s\S]*?cursor: default;/);
  assert.match(source, /\.paper-emoji-wrap \{\n  display: inline;\n\}/, '仅含小图的包装层必须收敛为行内');
});
