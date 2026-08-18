import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

test('website/github-stars.js removes client-side GitHub API, localStorage, and visibilitychange', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  assert.doesNotMatch(scriptContent, /api\.github\.com/);
  assert.doesNotMatch(scriptContent, /localStorage/);
  assert.doesNotMatch(scriptContent, /sessionStorage/);
  assert.doesNotMatch(scriptContent, /visibilitychange/);
  assert.doesNotMatch(scriptContent, /CACHE_TTL/);
  assert.doesNotMatch(scriptContent, /WORKER_URL/);

  assert.match(scriptContent, /github-stars\.json/);
  assert.match(scriptContent, /\.gh-star-count/);
});

test('website/github-stars.js fetches local github-stars.json and updates UI elements', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [
    { textContent: '16' },
    { textContent: '16' },
  ];
  let requestedUrl = null;

  const mockContext = {
    document: {
      querySelectorAll: (selector) => {
        if (selector === '.gh-star-count') return elements;
        return [];
      },
      currentScript: {
        src: 'https://paperrss.com/github-stars.js',
      },
    },
    window: {
      location: {
        href: 'https://paperrss.com/zh-CN/',
      },
    },
    fetch: async (url) => {
      requestedUrl = url;
      return {
        ok: true,
        json: async () => ({ stars: 1540, fetchedAt: '2026-08-18T00:00:00Z' }),
      };
    },
    URL,
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);

  await new Promise((r) => setTimeout(r, 20));

  assert.equal(requestedUrl, 'https://paperrss.com/github-stars.json');
  assert.equal(elements[0].textContent, '1.5k');
  assert.equal(elements[1].textContent, '1.5k');
});

test('website/github-stars.js keeps static fallback when JSON fetch fails', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];

  const mockContext = {
    document: {
      querySelectorAll: (selector) => {
        if (selector === '.gh-star-count') return elements;
        return [];
      },
      currentScript: {
        src: 'https://paperrss.com/github-stars.js',
      },
    },
    window: {
      location: {
        href: 'https://paperrss.com/zh-CN/',
      },
    },
    fetch: async () => {
      throw new Error('Network offline or 404');
    },
    URL,
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);

  await new Promise((r) => setTimeout(r, 20));

  // Must retain static HTML fallback '16' and never overwrite with 0 or empty
  assert.equal(elements[0].textContent, '16');
});

test('website/github-stars.json contains valid build-time data structure', async () => {
  const jsonContent = await readFile(new URL('../website/github-stars.json', import.meta.url), 'utf8');
  const data = JSON.parse(jsonContent);

  assert.equal(typeof data.stars, 'number');
  assert.ok(data.stars >= 0);
  assert.equal(typeof data.fetchedAt, 'string');
  assert.ok(data.fetchedAt.length > 0);
});

test('.github/workflows/deploy-pages.yml configures push, schedule, workflow_dispatch and build-time sync', async () => {
  const workflowContent = await readFile(new URL('../.github/workflows/deploy-pages.yml', import.meta.url), 'utf8');

  // Trigger verifications
  assert.match(workflowContent, /push:/);
  assert.match(workflowContent, /branches:\s*\n\s*-\s*main/);
  assert.match(workflowContent, /schedule:\s*\n\s*-\s*cron:\s*['"]17 \* \* \* \*['"]/);
  assert.match(workflowContent, /workflow_dispatch:/);

  // GitHub stars fetch step verifications
  assert.match(workflowContent, /gh api repos\/ohmyangboy\/PaperRss/);
  assert.match(workflowContent, /stargazers_count/);
  assert.match(workflowContent, /GH_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}/);
  assert.match(workflowContent, /website\/github-stars\.json/);
  assert.match(workflowContent, /fetchedAt/);
});
