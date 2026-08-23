import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(
  new URL('../PaperRss/Sources/App/ArticleReaderView.swift', import.meta.url),
  'utf8'
);

const storeSource = await readFile(
  new URL('../PaperRss/Sources/Core/AppStore.swift', import.meta.url),
  'utf8'
);

// 从 Swift 三引号模板中提取 summaryCardHTML 的 statusFooter 构建段。
// 锚点为 `var statusFooter = ""` 与紧随其后的预览注释。
const statusFooterBlock = source.match(
  /var statusFooter = ""([\s\S]*?)\/\/ 提取摘要第一句/
)?.[1] ?? '';

test('summary card footer renders the regenerate button while idle', () => {
  assert.ok(statusFooterBlock, 'expected a summary card status footer builder');
  assert.ok(
    /\} else \{[\s\S]*?data-paper-action="generateSummary"[\s\S]*?data-paper-force="true"/.test(statusFooterBlock),
    'the idle branch must always render the regenerate button'
  );
});

test('summary card footer keeps the spinner out of the idle branch', () => {
  const idleBranch = statusFooterBlock.match(/\} else \{([\s\S]*)$/)?.[1] ?? '';
  assert.ok(idleBranch, 'expected an idle branch after the generating branch');
  assert.ok(
    /!summary\.isComplete\s*\{/.test(idleBranch),
    'the incomplete notice must be a conditional, not a wrapper around the button'
  );
  assert.ok(
    !/paper-spinner/.test(idleBranch),
    'the spinner must only appear while generating'
  );
});

test('swiftui fallback summary card mirrors the html footer state machine', () => {
  const fallbackBlock = source.match(
    /if let summary = store\.summaryArtifact\(for: entry\), !summary\.content\.isEmpty \{([\s\S]*?)\} else if let status = activeAIStatus/
  )?.[1] ?? '';

  assert.ok(fallbackBlock, 'expected the swiftui fallback summary card body');
  assert.ok(
    /if activeAIStatus\(for: \.summary\) != nil \{/.test(fallbackBlock),
    'the swiftui card must keep a generating branch'
  );
  assert.ok(
    /\} else \{[\s\S]*?Button\(I18N\.localized\("重新生成"\)\)/.test(fallbackBlock),
    'the swiftui regenerate button must live outside the generating branch'
  );
  assert.ok(
    /if !summary\.isComplete \{/.test(fallbackBlock),
    'the incomplete notice must remain conditional'
  );
  assert.ok(
    !/if !summary\.isComplete \{[\s\S]*?if activeAIStatus\(for: \.summary\) != nil/.test(fallbackBlock),
    'the incomplete gate must not wrap the generating branch (old structure)'
  );
});

test('both platform coordinators route summary card updates through the shared builder', () => {
  const syncBodies = [...source.matchAll(
    /func synchronizeSummaryCard\(in webView: WKWebView\) \{([\s\S]*?)\n        \}\n/g
  )].map((match) => match[1]);

  assert.equal(syncBodies.length, 2, 'expected macOS and iOS summary card synchronizers');
  for (const body of syncBodies) {
    assert.ok(
      /PaperReaderHeaderBuilder\.summaryCardHTML\(/.test(body),
      'both platform synchronizers must render via the shared HTML builder'
    );
  }
});

test('summary render signature tracks completion on both platforms', () => {
  const sigStructs = [...source.matchAll(
    /private struct SummaryRenderSignature: Equatable \{([\s\S]*?)\n        \}/g
  )].map((match) => match[1]);

  assert.equal(sigStructs.length, 2, 'expected macOS and iOS render signatures');
  for (const body of sigStructs) {
    assert.ok(
      /let isComplete: Bool/.test(body),
      'completion must participate in the render signature or the stale incomplete footer is never repainted'
    );
  }

  const completionsFed = (source.match(
    /isComplete: parent\.summaryArtifact\?\.isComplete \?\? true/g
  ) ?? []).length;
  assert.equal(completionsFed, 2, 'both synchronizers must feed isComplete into the signature');
});

test('stale streaming source task must be awaited before summary completion', () => {
  const summaryCall = storeSource.match(
    /let result = try await llm\.summary\([\s\S]*?var finalArtifact = tracker\.currentArtifact/
  )?.[0] ?? '';

  assert.ok(summaryCall, 'expected the summary streaming call site');
  assert.ok(
    /if let onDelta \{\s*\n\s*await onDelta\(currentBuffer\)/.test(summaryCall),
    'summary deltas must be awaited so a late task cannot re-mark a completed summary as incomplete'
  );
  assert.ok(
    !/Task \{ await onDelta\(currentBuffer\) \}/.test(summaryCall),
    'no unstructured task may deliver summary deltas'
  );
});
