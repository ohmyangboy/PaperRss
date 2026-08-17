import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

import worker from '../workers/github-stars/index.js';

test('website/github-stars.js does not fetch GitHub API directly', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  assert.doesNotMatch(scriptContent, /api\.github\.com/);
  assert.match(scriptContent, /WORKER_URL/);
  assert.match(scriptContent, /paperrss_gh_stars/);
  assert.match(scriptContent, /10\s*\*\s*60\s*\*\s*1000/);
  assert.match(scriptContent, /visibilitychange/);
  assert.match(scriptContent, /\.gh-star-count/);
});

test('website/github-stars.js formats stars count correctly', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  // Create isolated DOM simulation
  const elements = [
    { textContent: '16' },
    { textContent: '16' },
  ];
  const storage = new Map();
  let fetchCallCount = 0;

  const mockContext = {
    document: {
      querySelectorAll: (selector) => {
        if (selector === '.gh-star-count') return elements;
        return [];
      },
      addEventListener: () => {},
      visibilityState: 'visible',
    },
    localStorage: {
      getItem: (key) => storage.get(key) || null,
      setItem: (key, val) => storage.set(key, String(val)),
    },
    fetch: async () => {
      fetchCallCount++;
      return {
        ok: true,
        json: async () => ({ stars: 1540 }),
      };
    },
    Date: {
      now: () => 1700000000000,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);

  // Allow Promise queue to resolve
  await new Promise((r) => setTimeout(r, 20));

  assert.equal(fetchCallCount, 1);
  assert.equal(elements[0].textContent, '1.5k');
  assert.equal(elements[1].textContent, '1.5k');

  const saved = JSON.parse(storage.get('paperrss_gh_stars'));
  assert.equal(saved.stars, 1540);
  assert.equal(saved.updatedAt, 1700000000000);
});

test('website/github-stars.js uses fresh localStorage cache without fetching', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];
  const storage = new Map([
    ['paperrss_gh_stars', JSON.stringify({ stars: 42, updatedAt: 1700000000000 })],
  ]);
  let fetchCallCount = 0;

  const mockContext = {
    document: {
      querySelectorAll: (selector) => {
        if (selector === '.gh-star-count') return elements;
        return [];
      },
      addEventListener: () => {},
      visibilityState: 'visible',
    },
    localStorage: {
      getItem: (key) => storage.get(key) || null,
      setItem: (key, val) => storage.set(key, String(val)),
    },
    fetch: async () => {
      fetchCallCount++;
      return { ok: true, json: async () => ({ stars: 100 }) };
    },
    Date: {
      // 5 minutes after cached time (< 10 minutes TTL)
      now: () => 1700000000000 + 5 * 60 * 1000,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);
  await new Promise((r) => setTimeout(r, 20));

  assert.equal(elements[0].textContent, '42');
  assert.equal(fetchCallCount, 0); // No network request made
});

test('website/github-stars.js refreshes when cache exceeds 10 minutes', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];
  const storage = new Map([
    ['paperrss_gh_stars', JSON.stringify({ stars: 42, updatedAt: 1700000000000 })],
  ]);
  let fetchCallCount = 0;

  const mockContext = {
    document: {
      querySelectorAll: (selector) => {
        if (selector === '.gh-star-count') return elements;
        return [];
      },
      addEventListener: () => {},
      visibilityState: 'visible',
    },
    localStorage: {
      getItem: (key) => storage.get(key) || null,
      setItem: (key, val) => storage.set(key, String(val)),
    },
    fetch: async () => {
      fetchCallCount++;
      return { ok: true, json: async () => ({ stars: 88 }) };
    },
    Date: {
      // 11 minutes after cached time (> 10 minutes TTL)
      now: () => 1700000000000 + 11 * 60 * 1000,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);
  // Before fetch resolves, should immediately display cached 42
  assert.equal(elements[0].textContent, '42');

  await new Promise((r) => setTimeout(r, 20));
  // After fetch resolves, should update to 88
  assert.equal(fetchCallCount, 1);
  assert.equal(elements[0].textContent, '88');
});

test('website/github-stars.js listens to visibilitychange and refreshes stale cache', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];
  const storage = new Map([
    ['paperrss_gh_stars', JSON.stringify({ stars: 20, updatedAt: 1700000000000 })],
  ]);
  let fetchCallCount = 0;
  let visibilityListener = null;

  let simulatedNow = 1700000000000 + 2 * 60 * 1000; // 2 min (fresh)

  const doc = {
    querySelectorAll: (selector) => {
      if (selector === '.gh-star-count') return elements;
      return [];
    },
    addEventListener: (type, fn) => {
      if (type === 'visibilitychange') visibilityListener = fn;
    },
    visibilityState: 'hidden',
  };

  const mockContext = {
    document: doc,
    localStorage: {
      getItem: (key) => storage.get(key) || null,
      setItem: (key, val) => storage.set(key, String(val)),
    },
    fetch: async () => {
      fetchCallCount++;
      return { ok: true, json: async () => ({ stars: 35 }) };
    },
    Date: {
      now: () => simulatedNow,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fetchCallCount, 0);

  // Now time passes: 15 minutes later and page becomes visible
  simulatedNow += 15 * 60 * 1000;
  doc.visibilityState = 'visible';
  assert.ok(typeof visibilityListener === 'function');
  visibilityListener();

  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fetchCallCount, 1);
  assert.equal(elements[0].textContent, '35');
});

test('website/github-stars.js preserves fallback when fetch fails', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];
  const storage = new Map();

  const mockContext = {
    document: {
      querySelectorAll: (selector) => {
        if (selector === '.gh-star-count') return elements;
        return [];
      },
      addEventListener: () => {},
      visibilityState: 'visible',
    },
    localStorage: {
      getItem: () => null,
      setItem: () => {},
    },
    fetch: async () => {
      throw new Error('Network error');
    },
    Date: {
      now: () => 1700000000000,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);
  await new Promise((r) => setTimeout(r, 20));

  // Should retain static fallback '16' without clearing or throwing
  assert.equal(elements[0].textContent, '16');
});

test('workers/github-stars Worker handles OPTIONS, routing, upstream response, and fallbacks', async () => {
  // 1. OPTIONS request
  const optionsReq = new Request('https://paperrss.com/github-stars', { method: 'OPTIONS' });
  const optionsRes = await worker.fetch(optionsReq, {}, {});
  assert.equal(optionsRes.status, 204);
  assert.equal(optionsRes.headers.get('Access-Control-Allow-Origin'), '*');

  // 2. Disallowed method
  const postReq = new Request('https://paperrss.com/github-stars', { method: 'POST' });
  const postRes = await worker.fetch(postReq, {}, {});
  assert.equal(postRes.status, 405);

  // 3. Not found path
  const notFoundReq = new Request('https://paperrss.com/unknown', { method: 'GET' });
  const notFoundRes = await worker.fetch(notFoundReq, {}, {});
  assert.equal(notFoundRes.status, 404);

  // 4. Successful GET with mock global fetch
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async () => new Response(JSON.stringify({ stargazers_count: 24 }), { status: 200 });
    const getReq = new Request('https://paperrss.com/github-stars', { method: 'GET' });
    const getRes = await worker.fetch(getReq, {}, {});
    assert.equal(getRes.status, 200);
    assert.equal(getRes.headers.get('Access-Control-Allow-Origin'), '*');
    assert.match(getRes.headers.get('Cache-Control'), /max-age=600/);

    const body = await getRes.json();
    assert.equal(body.stars, 24);
    assert.ok(typeof body.updatedAt === 'string');

    // 5. Fallback on GitHub API failure
    globalThis.fetch = async () => new Response('Rate limited', { status: 403 });
    const fallbackRes = await worker.fetch(getReq, {}, {});
    assert.equal(fallbackRes.status, 200);
    const fallbackBody = await fallbackRes.json();
    assert.equal(fallbackBody.stars, 0);
    assert.equal(fallbackBody.fallback, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
