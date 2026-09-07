import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url), 'utf8');
const script = source.match(/static let documentReadyScript = WKUserScript\(\s*source: """([\s\S]*?)"""/)?.[1]
  ?.replace(/\\\(documentReadyMessageName\)/g, 'paperRssDocumentReady');

test('DOM 就绪发送当前加载批次，不等待媒体 load 事件', () => {
  assert.ok(script);
  for (const generation of ['1', '42', undefined]) {
    const messages = [];
    vm.runInNewContext(script, {
      document: { querySelector: () => generation ? { content: generation } : null },
      window: { webkit: { messageHandlers: { paperRssDocumentReady: {
        postMessage: message => messages.push(message.generation)
      } } } }
    });
    assert.deepEqual(messages, generation ? [generation] : []);
  }
});

test('双平台在交互门控之前接收 DOM 就绪并校验主框架与加载批次', () => {
  const handlers = [...source.matchAll(/func userContentController\(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage\) \{([\s\S]*?)if !parent.isInteractive/g)];
  assert.equal(handlers.length, 2);
  for (const [, body] of handlers) {
    assert.match(body, /message.frameInfo.isMainFrame/);
    assert.match(body, /generation == currentLoadGeneration/);
    assert.match(body, /completeDocumentLoad\(load, in: webView\)/);
  }
  assert.equal((source.match(/self.completedArticleKey != load.signature/g) ?? []).length, 2);
  assert.equal((source.match(/name: PaperReaderBridge.documentReadyMessageName/g) ?? []).length, 2);
  assert.equal((source.match(/forName: PaperReaderBridge.documentReadyMessageName/g) ?? []).length, 2);
});
