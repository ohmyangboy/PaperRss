import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8',
);

const script = source.match(
  /static let imageRecoveryScript = WKUserScript\(\n\s+source: """([\s\S]*?)""",\n\s+injectionTime:/,
)?.[1];
assert.ok(script, 'imageRecoveryScript must be present');

function runRecovery(images) {
  const timers = [];
  const document = {
    baseURI: 'https://example.com/article',
    querySelectorAll: selector => selector === 'img' ? images : [],
  };
  const window = { setTimeout: callback => timers.push(callback) };
  vm.runInNewContext(script, { document, window, URL, Number, String });
  return () => { while (timers.length) timers.shift()(); };
}

function image({ src, complete, naturalWidth }) {
  const listeners = new Map();
  return {
    src,
    currentSrc: src,
    complete,
    naturalWidth,
    dataset: {},
    getAttribute: name => name === 'src' ? src : null,
    addEventListener: (name, callback) => listeners.set(name, callback),
    dispatch: name => listeners.get(name)?.(),
  };
}

test('recovers a remote image that failed before the document-end script ran', () => {
  const failed = image({ src: 'https://example.com/photo.jpg', complete: true, naturalWidth: 0 });
  const flush = runRecovery([failed]);
  flush();
  assert.equal(failed.dataset.paperRssRetry, '1');
  assert.equal(failed.src, 'https://example.com/photo.jpg?_paper_rss_retry=1');
});

test('does not restart healthy or pending images and keeps later errors bounded', () => {
  const healthy = image({ src: 'https://example.com/ok.jpg', complete: true, naturalWidth: 1200 });
  const pending = image({ src: 'https://example.com/slow.jpg', complete: false, naturalWidth: 0 });
  const inline = image({ src: 'data:image/png;base64,broken', complete: true, naturalWidth: 0 });
  const flush = runRecovery([healthy, pending, inline]);
  flush();
  assert.equal(healthy.dataset.paperRssRetry, undefined);
  assert.equal(pending.dataset.paperRssRetry, undefined);
  assert.equal(inline.dataset.paperRssRetry, undefined);
  pending.dispatch('error');
  flush();
  pending.dispatch('error');
  flush();
  pending.dispatch('error');
  flush();
  assert.equal(pending.dataset.paperRssRetry, '2');
});
