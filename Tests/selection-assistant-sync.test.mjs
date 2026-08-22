import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8'
);

test('selection options are restored after every WebView navigation', () => {
  const didFinishBodies = [...source.matchAll(
    /func webView\(_ webView: WKWebView, didFinish navigation: WKNavigation!\) \{([\s\S]*?)\n        \}\n\n        (?:private )?func restoreSelectionAnnotations/g
  )].map((match) => match[1]);

  assert.equal(didFinishBodies.length, 2, 'expected macOS and iOS navigation callbacks');
  for (const body of didFinishBodies) {
    assert.ok(
      /synchronizeSelectionOptions\(in: webView\)/.test(body),
      'selection options must be restored after navigation finishes'
    );
  }
});

test('selection options are sent into the selection script content world', () => {
  const syncBodies = [...source.matchAll(
    /func synchronizeSelectionOptions\(in webView: WKWebView\) \{([\s\S]*?)\n        \}\n/g
  )].map((match) => match[1]);

  assert.equal(syncBodies.length, 2, 'expected macOS and iOS option synchronizers');
  for (const body of syncBodies) {
    assert.ok(
      /(?:contentWorld:|in:) \.defaultClient/.test(body),
      'options must be evaluated in the same isolated world as the selection script'
    );
  }
});

test('updating options dismisses stale selection UI', () => {
  const selectionScript = source.match(
    /static let selectionScript = WKUserScript\(\n        source: """([\s\S]*?)""",\n        injectionTime:/
  )?.[1] ?? '';

  assert.ok(/updateOptions\(options\)/.test(selectionScript), 'the WebView bridge must accept live option updates');
  assert.ok(/removeAction\(\)/.test(selectionScript), 'live updates must remove a stale action bar');
  assert.ok(
    /if \(!hasEnabledAction\(options\)\) dismissPopover\(\)/.test(selectionScript),
    'disabling every action must also dismiss an open result popover'
  );
});

test('reader toolbar keeps the character bubble translation icon', () => {
  assert.ok(
    /toolbarSymbol\([\s\S]*?"character\.bubble\.fill" : "character\.bubble"/.test(source),
    'the toolbar must keep the original character bubble icon'
  );
});
