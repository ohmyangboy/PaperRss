import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

test('website/github-stars.js fetches GitHub API directly and defines TTL', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  assert.match(scriptContent, /api\.github\.com/);
  assert.match(scriptContent, /paperrss_gh_stars/);
  assert.match(scriptContent, /10\s*\*\s*60\s*\*\s*1000/);
  assert.match(scriptContent, /visibilitychange/);
  assert.match(scriptContent, /\.gh-star-count/);
});

test('website/github-stars.js formats stars count correctly', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

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
        json: async () => ({ stargazers_count: 1540 }),
      };
    },
    Date: {
      now: () => 1700000000000,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);

  await new Promise((r) => setTimeout(r, 20));

  assert.equal(fetchCallCount, 1);
  assert.equal(elements[0].textContent, '1.5k');
  assert.equal(elements[1].textContent, '1.5k');

  const saved = JSON.parse(storage.get('paperrss_gh_stars'));
  assert.equal(saved.count, '1.5k');
  assert.equal(saved.timestamp, 1700000000000);
});

test('website/github-stars.js uses fresh localStorage cache without fetching', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];
  const storage = new Map([
    ['paperrss_gh_stars', JSON.stringify({ count: '42', timestamp: 1700000000000 })],
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
      return { ok: true, json: async () => ({ stargazers_count: 100 }) };
    },
    Date: {
      now: () => 1700000000000 + 5 * 60 * 1000,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);
  await new Promise((r) => setTimeout(r, 20));

  assert.equal(elements[0].textContent, '42');
  assert.equal(fetchCallCount, 0); 
});

test('website/github-stars.js refreshes when cache exceeds 10 minutes', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];
  const storage = new Map([
    ['paperrss_gh_stars', JSON.stringify({ count: '42', timestamp: 1700000000000 })],
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
      return { ok: true, json: async () => ({ stargazers_count: 88 }) };
    },
    Date: {
      now: () => 1700000000000 + 11 * 60 * 1000,
    },
    setTimeout,
    clearTimeout,
  };

  vm.runInNewContext(scriptContent, mockContext);
  assert.equal(elements[0].textContent, '42');

  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fetchCallCount, 1);
  assert.equal(elements[0].textContent, '88');
});

test('website/github-stars.js listens to visibilitychange and refreshes stale cache', async () => {
  const scriptContent = await readFile(new URL('../website/github-stars.js', import.meta.url), 'utf8');

  const elements = [{ textContent: '16' }];
  const storage = new Map([
    ['paperrss_gh_stars', JSON.stringify({ count: '20', timestamp: 1700000000000 })],
  ]);
  let fetchCallCount = 0;
  let visibilityListener = null;

  let simulatedNow = 1700000000000 + 2 * 60 * 1000;

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
      return { ok: true, json: async () => ({ stargazers_count: 35 }) };
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

  assert.equal(elements[0].textContent, '16');
});
