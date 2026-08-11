import assert from 'node:assert/strict';
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
