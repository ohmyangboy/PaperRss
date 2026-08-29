import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { resolveWebsiteLocale } from '../website/locale.mjs';

test('manual website language takes precedence over browser language', () => {
  assert.equal(resolveWebsiteLocale('zh-CN', ['en-US']), 'zh-CN');
  assert.equal(resolveWebsiteLocale('en', ['zh-CN']), 'en');
});

test('only English browser locales default to English', () => {
  assert.equal(resolveWebsiteLocale(null, ['en-GB']), 'en');
  assert.equal(resolveWebsiteLocale(null, ['zh-Hans']), 'zh-CN');
  assert.equal(resolveWebsiteLocale(null, ['ja-JP', 'en-US']), 'zh-CN');
  assert.equal(resolveWebsiteLocale(null, []), 'zh-CN');
});

test('invalid stored values are ignored', () => {
  assert.equal(resolveWebsiteLocale('fr', ['en-US']), 'en');
});

test('website showcases the supplied full-resolution product screenshots', async () => {
  const expectedScreenshots = new Map([
    ['paper-rss-main.webp', [2160, 1357]],
    ['paper-rss-second.webp', [2160, 1357]],
    ['full-screen.webp', [2160, 1357]],
    ['bilingual-translation.webp', [1344, 1545]],
    ['ai-question-popover.webp', [732, 216]],
    ['ai-translate-popover.webp', [896, 852]],
    ['ai-explain-popover.webp', [926, 836]],
  ]);
  const localePages = await Promise.all([
    readFile(new URL('../website/zh-CN/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/en/index.html', import.meta.url), 'utf8'),
  ]);

  for (const [filename, [expectedWidth, expectedHeight]] of expectedScreenshots) {
    for (const page of localePages) {
      assert.match(page, new RegExp(`assets/screenshots/${filename.replaceAll('.', '\\.')}`));
    }

    const img = await readFile(new URL(`../website/assets/screenshots/${filename}`, import.meta.url));
    assert.equal(img.toString('ascii', 0, 4), 'RIFF');
    assert.equal(img.toString('ascii', 8, 12), 'WEBP');
    assert.equal(img.readUInt16LE(26) & 0x3fff, expectedWidth);
    assert.equal(img.readUInt16LE(28) & 0x3fff, expectedHeight);
  }

  for (const page of localePages) {
    assert.doesNotMatch(page, /class="deep-feature"/);
    assert.doesNotMatch(page, /class="hero-stamp"/);
    assert.match(page, /class="hero-content"/);
    assert.match(page, /class="hero-app-icon"><img src="\.\.\/assets\/app-icon\.webp"/);
    assert.doesNotMatch(page, /stage-bar|window-dots|window-dot/);
    assert.match(page, /class="scramble-title"/);
    assert.match(page, /class="scramble-target"/);
    assert.match(page, /src="\.\.\/scramble-title\.js"/);
    assert.match(page, /id="ai-assistant"/);
    assert.match(page, /02 \/ EXPLAIN &amp; ASK|02 \/ EXPLAIN & ASK/);
    assert.match(page, /feature-card-gallery[\s\S]*ai-question-popover\.webp[\s\S]*ai-explain-popover\.webp/);
  }
});

test('download routing and options support dual-source smart download', async () => {
  const [zhHome, enHome, routerScript] = await Promise.all([
    readFile(new URL('../website/zh-CN/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/en/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/download-router.js', import.meta.url), 'utf8'),
  ]);

  for (const home of [zhHome, enHome]) {
    assert.match(home, /src="\.\.\/download-router\.js"/);
    assert.match(home, /class="dl-main"[^>]*data-smart-download/);
    assert.match(home, /href="https:\/\/download\.1leaf\.cc\/PaperRss-latest\.dmg"/);
    assert.match(home, /href="https:\/\/github\.com\/ohmyangboy\/PaperRss\/releases\/latest"/);
    assert.match(home, /href="https:\/\/github\.com\/ohmyangboy\/PaperRss\/releases"/);
  }

  assert.match(routerScript, /https:\/\/download\.1leaf\.cc\/PaperRss-latest\.dmg/);
  assert.match(routerScript, /https:\/\/api\.github\.com\/repos\/ohmyangboy\/PaperRss\/releases\/latest/);
  assert.match(routerScript, /https:\/\/github\.com\/ohmyangboy\/PaperRss\/releases\/latest/);
  assert.match(routerScript, /data-smart-download/);
  assert.match(routerScript, /aria-busy/);
});

test('title scramble animation is shared by both locales and respects reduced motion', async () => {
  const script = await readFile(new URL('../website/scramble-title.js', import.meta.url), 'utf8');

  assert.match(script, /class TextScramble/);
  assert.match(script, /requestAnimationFrame/);
  assert.match(script, /prefers-reduced-motion: reduce/);
  assert.match(script, /this\.weights = \[/);
  assert.match(script, /this\.fontFamilies = \[/);
  assert.match(script, /scrambleEnd/);
  assert.match(script, /settleEnd/);
  assert.match(script, /scramble-char/);
  assert.match(script, /\.scramble-title/);
  assert.match(script, /\.scramble-target/);
  assert.match(script, /document\.fonts\?\.ready/);
  assert.match(script, /target\.style\.width/);
  assert.match(script, /title\.style\.height/);
});

test('desktop header anchors stay centered independently of side content widths', async () => {
  const styles = await readFile(new URL('../website/styles.css', import.meta.url), 'utf8');

  assert.match(styles, /\.site-header\s*\{[\s\S]*?display:\s*grid;/);
  assert.match(styles, /grid-template-columns:\s*minmax\(0, 1fr\) auto minmax\(0, 1fr\)/);
  assert.match(styles, /\.site-nav\s*\{[\s\S]*?justify-self:\s*center;/);
  assert.match(styles, /\.header-actions\s*\{[\s\S]*?justify-self:\s*end;/);
});

test('hero elements share one visual alignment group', async () => {
  const styles = await readFile(new URL('../website/styles.css', import.meta.url), 'utf8');

  assert.match(styles, /\.hero-content\s*\{[\s\S]*?width:\s*min\(100%, 820px\);/);
  assert.match(styles, /\.hero-content\s*\{[\s\S]*?display:\s*flex;/);
  assert.match(styles, /\.hero-content\s*\{[\s\S]*?align-items:\s*center;/);
  assert.match(styles, /\.hero-app-icon\s*\{[\s\S]*?margin:\s*0 0 1\.15rem;/);
  assert.match(styles, /\.hero-ctas\s*\{[\s\S]*?width:\s*100%;/);
});

test('mobile header and animated title fit narrow screens', async () => {
  const styles = await readFile(new URL('../website/styles.css', import.meta.url), 'utf8');

  assert.match(styles, /@media \(max-width:\s*480px\)[\s\S]*?\.btn-github\s*>\s*span:first-child\s*\{\s*display:\s*none;/);
  assert.match(styles, /@media \(max-width:\s*480px\)[\s\S]*?\.brand-tag\s*\{\s*display:\s*none;/);
  assert.match(styles, /@media \(max-width:\s*480px\)[\s\S]*?\.hero h1\s*\{\s*font-size:\s*2rem;/);
});

test('stage card stacking parallax is shared by both locales and respects reduced motion', async () => {
  const localePages = await Promise.all([
    readFile(new URL('../website/zh-CN/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/en/index.html', import.meta.url), 'utf8'),
  ]);

  for (const page of localePages) {
    assert.match(page, /src="\.\.\/stage-parallax\.js"/);
    assert.match(page, /id="stage-showcase"/);
    assert.match(page, /class="stage-sticky-viewport"/);
    assert.match(page, /stage-card-base/);
    assert.match(page, /stage-card-mid/);
    assert.match(page, /stage-card-overlay|stage-card-top/);
  }

  const script = await readFile(new URL('../website/stage-parallax.js', import.meta.url), 'utf8');
  assert.match(script, /requestAnimationFrame/);
  assert.match(script, /prefers-reduced-motion: reduce/);
  assert.match(script, /getBoundingClientRect/);
  assert.match(script, /scale/);
  assert.match(script, /translate3d/);
});

test('localized legal pages disclose the real data and content boundaries', async () => {
  const [zhHome, enHome, zhLegal, enLegal, styles] = await Promise.all([
    readFile(new URL('../website/zh-CN/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/en/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/zh-CN/legal.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/en/legal.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/styles.css', import.meta.url), 'utf8'),
  ]);

  for (const home of [zhHome, enHome]) {
    assert.match(home, /legal\.html#privacy/);
    assert.match(home, /legal\.html#content/);
    assert.match(home, /legal\.html#third-party/);
  }

  assert.doesNotMatch(zhHome, /API Key 与数据仅存于本机设备/);
  assert.doesNotMatch(enHome, /API keys and reading data stay on your Mac/);

  assert.match(zhLegal, /id="privacy"/);
  assert.match(zhLegal, /AI API Key 当前保存在该 Mac 的 PaperRss 本地应用偏好/);
  assert.match(zhLegal, /全部或部分正文/);
  assert.match(zhLegal, /id="content"/);
  assert.match(zhLegal, /不要使用 PaperRss 绕过登录、付费墙、验证码或其他访问控制/);
  assert.match(zhLegal, /id="third-party"/);
  assert.match(zhLegal, /GRDB\.swift/);
  assert.match(zhLegal, /Sparkle/);
  assert.match(zhLegal, /swift-markdown/);
  assert.match(zhLegal, /MathJax runtime/);

  assert.match(enLegal, /href="\.\.\/zh-CN\/legal\.html"/);
  assert.match(enLegal, /user-configured AI API key is currently stored/);
  assert.match(enLegal, /all or part of the article text/);
  assert.match(enLegal, /does not currently operate a service that centrally extracts article bodies/);
  assert.match(enLegal, /Complete third-party notices|complete third-party notices/i);

  assert.match(styles, /\.legal-shell/);
  assert.match(styles, /\.legal-document/);
  assert.match(styles, /\.legal-callout/);
});
