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
    ['paper-rss-main.png', [2940, 1846]],
    ['paper-rss-second.png', [2940, 1846]],
    ['full-screen.png', [2940, 1846]],
    ['bilingual-translation.png', [1544, 1774]],
    ['ai-question-popover.png', [732, 216]],
    ['ai-translate-popover.png', [896, 852]],
    ['ai-explain-popover.png', [926, 836]],
  ]);
  const localePages = await Promise.all([
    readFile(new URL('../website/zh-CN/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../website/en/index.html', import.meta.url), 'utf8'),
  ]);

  for (const [filename, [expectedWidth, expectedHeight]] of expectedScreenshots) {
    for (const page of localePages) {
      assert.match(page, new RegExp(`assets/screenshots/${filename.replaceAll('.', '\\.')}`));
    }

    const png = await readFile(new URL(`../website/assets/screenshots/${filename}`, import.meta.url));
    assert.equal(png.toString('ascii', 1, 4), 'PNG');
    assert.equal(png.readUInt32BE(16), expectedWidth);
    assert.equal(png.readUInt32BE(20), expectedHeight);
  }

  for (const page of localePages) {
    assert.doesNotMatch(page, /class="deep-feature"/);
    assert.doesNotMatch(page, /class="hero-stamp"/);
    assert.match(page, /class="hero-content"/);
    assert.match(page, /class="hero-app-icon"><img src="\.\.\/assets\/app-icon\.png"/);
    assert.doesNotMatch(page, /stage-bar|window-dots|window-dot/);
    assert.match(page, /class="scramble-title"/);
    assert.match(page, /class="scramble-target"/);
    assert.match(page, /src="\.\.\/scramble-title\.js"/);
    assert.match(page, /id="ai-assistant"/);
    assert.match(page, /02 \/ EXPLAIN &amp; ASK|02 \/ EXPLAIN & ASK/);
    assert.match(page, /feature-card-gallery[\s\S]*ai-question-popover\.png[\s\S]*ai-explain-popover\.png/);
  }
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

