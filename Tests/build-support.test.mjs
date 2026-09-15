import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { access, mkdir, mkdtemp, readdir, rm, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const SUPPORT = join(root, 'scripts', 'build-support.py');
const PYTHON = process.env.PYTHON ?? 'python3';

const BOOT = `
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('support', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.ROOT = pathlib.Path(sys.argv[2])
sys.exit(m.run([sys.executable, '-c', sys.argv[3]], temporary=True, lane=sys.argv[4], unlocked=sys.argv[5] == '1'))
`;

const COLLECT = `
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('support', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.ROOT = pathlib.Path(sys.argv[2])
lanes = tuple(a for a in sys.argv[4].split(',') if a)
print(json.dumps(sorted(str(p.relative_to(m.ROOT)) for p, _, _ in m.collect_reclaimable(m.ROOT, int(sys.argv[3]), lanes))))
`;

function py(code, args) {
  return new Promise((resolve, reject) => {
    execFile(PYTHON, ['-B', '-c', code, ...args], { encoding: 'utf8' }, (error, stdout, stderr) => {
      if (error) reject(new Error(stderr.trim() || error.message));
      else resolve(stdout);
    });
  });
}

function spawnEntry(work, code, { lane = 'all', unlocked = false } = {}) {
  return spawn(PYTHON, ['-B', '-c', BOOT, SUPPORT, work, code, lane, unlocked ? '1' : '0'], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });
}

const waitExit = (child) => new Promise((resolve) => child.on('exit', (code) => resolve(code)));

const holdCode = (marker, seconds = 0.6) =>
  `import os,time; p=${JSON.stringify(marker)}; `
  + `fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY); time.sleep(${seconds}); os.close(fd); os.unlink(p)`;

async function makeStale(target, days = 40) {
  const stamp = new Date(Date.now() - days * 86_400_000);
  for (const entry of await readdir(target, { withFileTypes: true })) {
    const child = join(target, entry.name);
    if (entry.isDirectory()) await makeStale(child, days);
    else if (!entry.isSymbolicLink()) await utimes(child, stamp, stamp);
  }
  await utimes(target, stamp, stamp);
}

async function makeDerivedData(target, days) {
  await mkdir(join(target, 'Build'), { recursive: true });
  await writeFile(join(target, 'info.plist'), '{}');
  await makeStale(target, days);
}

async function pathExists(target) {
  try {
    await access(target);
    return true;
  } catch {
    return false;
  }
}

async function waitForFile(target, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (!(await pathExists(target)) && Date.now() < deadline) await delay(20);
  return pathExists(target);
}

async function workdir(t) {
  const dir = await mkdtemp(join(tmpdir(), 'paperrss-support-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

test('cache retention splits ad hoc roots (1 day) from fixed roots (3 days)', async (t) => {
  const work = await workdir(t);
  await makeDerivedData(join(work, 'build', 'isolated-audio-wave'), 2);
  await makeDerivedData(join(work, 'build', 'isolated'), 2);
  await makeDerivedData(join(work, 'build', 'SourcePackages'), 4);

  const eligible = JSON.parse(await py(COLLECT, [SUPPORT, work, '3', 'app,tests']));
  assert.deepEqual(eligible, ['build/SourcePackages', 'build/isolated-audio-wave']);
});

test('--keep-days only moves the fixed tier, and 0 disables the time filter', async (t) => {
  const work = await workdir(t);
  await makeDerivedData(join(work, 'build', 'isolated-audio-wave'), 2);
  await makeDerivedData(join(work, 'build', 'SourcePackages'), 2);

  assert.deepEqual(
    JSON.parse(await py(COLLECT, [SUPPORT, work, '30', 'app,tests'])),
    ['build/isolated-audio-wave'],
  );
  assert.deepEqual(
    JSON.parse(await py(COLLECT, [SUPPORT, work, '0', 'app,tests'])),
    ['build/SourcePackages', 'build/isolated-audio-wave'],
  );
});

test('a build entry reclaims only the lane it holds', async (t) => {
  const work = await workdir(t);
  const adHoc = join(work, 'build', 'isolated-audio-wave');
  await makeDerivedData(adHoc, 2);

  const swiftpm = join(work, '.build');
  await mkdir(swiftpm, { recursive: true });
  await writeFile(join(swiftpm, 'workspace-state.json'), '{}');
  await makeStale(swiftpm, 5);

  assert.equal(await waitExit(spawnEntry(work, 'pass', { lane: 'app' })), 0);
  assert.equal(await pathExists(adHoc), false, 'app 泳道应回收 build/ 内的一次性根');
  assert.equal(await pathExists(swiftpm), true, 'app 泳道不应回收 tests 泳道的 .build');

  assert.equal(await waitExit(spawnEntry(work, 'pass', { lane: 'tests' })), 0);
  assert.equal(await pathExists(swiftpm), false, 'tests 泳道应回收 .build');
});

test('an unlocked entry reclaims nothing', async (t) => {
  const work = await workdir(t);
  const adHoc = join(work, 'build', 'isolated-audio-wave');
  await makeDerivedData(adHoc, 2);

  assert.equal(await waitExit(spawnEntry(work, 'pass', { lane: 'app', unlocked: true })), 0);
  assert.equal(await pathExists(adHoc), true);
});

test('same lane serializes while app and tests lanes run in parallel', async (t) => {
  const work = await workdir(t);
  const marker = join(work, 'hold');
  const first = spawnEntry(work, holdCode(marker), { lane: 'app' });
  const second = spawnEntry(work, holdCode(marker), { lane: 'app' });
  assert.deepEqual(await Promise.all([waitExit(first), waitExit(second)]), [0, 0]);

  const appMarker = join(work, 'app-hold');
  const testsMarker = join(work, 'tests-hold');
  const app = spawnEntry(work, holdCode(appMarker, 1), { lane: 'app' });
  assert.equal(await waitForFile(appMarker), true);
  const tests = spawnEntry(work, holdCode(testsMarker, 0.2), { lane: 'tests' });
  assert.equal(await waitForFile(testsMarker), true, 'tests 泳道应能与 app 泳道同时持锁');
  await Promise.all([waitExit(app), waitExit(tests)]);
});
