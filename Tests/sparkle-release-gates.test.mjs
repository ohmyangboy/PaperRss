import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, readFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SPARKLE = join(ROOT, 'scripts', 'sparkle');

/**
 * 假二进制契约测试：用受控 fake 替换 Apple 工具链，逐个触发失败点，断言：
 *  1) 脚本立即非零退出并输出 [FAIL]；
 *  2) 失败之后的步骤不再执行（调用序列截断）；
 *  3) skip-notarization 模式绝不调用公证/Staple 工具。
 */

function writeFake(bin, name, body) {
  const p = join(bin, name);
  // 先记录调用序列，再执行受控行为；失败也留痕。
  writeFileSync(p, `#!/bin/sh\n[ -n "$FAKE_CALLS" ] && printf '%s\\n' "${name} $*" >> "$FAKE_CALLS"\n${body}\n`);
  chmodSync(p, 0o755);
}

const CODESIGN_OK = `
case "\$1" in
  --verify) exit 0 ;;
  -dv|-dvv)
    echo "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+0 location=embedded"
    echo "Authority=Developer ID Application: Test (TEAM)"
    echo "TeamIdentifier=TEAM";;
  --entitlements) echo "{}";;
esac
exit 0`;

const EXPORT_MKAPP = `
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-exportPath" ]; then mkdir -p "\$a/PaperRss.app/Contents/MacOS"; fi
  prev="\$a"
done
exit 0`;

const CREATE_DMG_TOUCH = `
for a in "\$@"; do case "\$a" in *.dmg) : > "\$a";; esac; done
exit 0`;

function makeFakeBin(behavior = {}) {
  const bin = mkdtempSync(join(tmpdir(), 'fakebin-'));
  const defaults = {
    xcodebuild: EXPORT_MKAPP,
    codesign: CODESIGN_OK,
    spctl: 'echo "accepted"\necho "source=Notarized Developer ID"',
    security: 'echo \'1) AAAA1111 "Developer ID Application: Test (TEAM)"\'',
    stapler: ':;',
    hdiutil: ':;',
    ditto: ':;',
    'create-dmg': CREATE_DMG_TOUCH,
    notarytool: 'echo "Inserted distribution ID: 11111111-2222-3333-4444-555555555555"\necho "status: Accepted"',
  };
  // 脚本通过 `xcrun notarytool|stapler …` 调用：shim 路由回同目录 fake
  writeFake(bin, 'xcrun', `
tool="$1"; shift
case "$tool" in
  notarytool|stapler|hdiutil|codesign) exec "$(dirname "$0")/$tool" "$@" ;;
esac
echo "unexpected xcrun $tool" >&2; exit 127
`);  for (const [name, body] of Object.entries({ ...defaults, ...behavior })) {
    if (body === false) continue;
    writeFake(bin, name, body);
  }
  return bin;
}

function run(script, args, extraEnv = {}) {
  return execFileSync('bash', [script, ...args], {
    cwd: ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, FAKE_CALLS: extraEnv.FAKE_CALLS ?? '', ...extraEnv },
  });
}

function runExpectFailure(script, args, extraEnv = {}) {
  let out = '';
  try {
    run(script, args, extraEnv);
  } catch (error) {
    out = `${error.stdout || ''}\n${error.stderr || ''}`;
    assert.match(out, /\[FAIL\]/, '失败输出必须包含 [FAIL]');
    return out;
  }
  assert.fail('脚本应当失败退出');
}

function withSandbox(callback) {
  const dir = mkdtempSync(join(tmpdir(), 'gates-'));
  const calls = join(dir, 'calls.log');
  writeFileSync(calls, '');
  const app = join(dir, 'PaperRss.app');
  mkdirSync(join(app, 'Contents', 'MacOS'), { recursive: true });
  writeFileSync(join(app, 'Contents', 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict/></plist>');
  const archive = join(dir, 'PaperRss.xcarchive');
  const bins = [];
  try {
    callback({
      dir, calls, app, archive,
      makeBin(behavior) { const b = makeFakeBin(behavior); bins.push(b); return b; },
      newCalls(name) {
        const p = join(dir, name);
        writeFileSync(p, '');
        return p;
      },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
    for (const b of bins) rmSync(b, { recursive: true, force: true });
  }
}

const NOTARIZE_ARGS = (dir, archive) => [
  '--archive', archive,
  '--output-dir', join(dir, 'out'),
  '--team-id', 'TEAM',
  '--notary-profile', 'prof',
];

test('export_and_notarize 全链路：导出→签名门禁→公证→Staple 依次 PASS', () => {
  withSandbox(({ dir, archive, makeBin }) => {
    const bin = makeBin({});
    const out = run(join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive), {
      PATH: `${bin}:${process.env.PATH}`,
    });
    assert.match(out, /\[PASS 3\]/);
    assert.match(out, /\[PASS 4\][^\n]*Developer ID[^\n]*Hardened Runtime/);
    assert.match(out, /\[PASS 5\][^\n]*Accepted/);
    assert.match(out, /\[PASS 6\]/);
    assert.equal(out.trim().split('\n').pop(), join(dir, 'out', 'PaperRss.app'));
  });
});

test('codesign 校验失败 → 立即终止，且不进入公证与 Staple', () => {
  withSandbox(({ dir, archive, makeBin }) => {
    const bin = makeBin({
      codesign: 'if [ "$1" = "--verify" ]; then echo invalid >&2; exit 1; fi\nexit 0',
      notarytool: false,
    });
    const out = runExpectFailure(
      join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin}:${process.env.PATH}` });
    assert.match(out, /\[PASS 3\]/, '导出应已成功');
    assert.doesNotMatch(out, /\[PASS 5\]|\[PASS 6\]/);
  });
});

test('公证前不做 spctl 评估（未公证 Developer ID 被拒是预期），Staple 后必须复验', () => {
  withSandbox(({ dir, archive, makeBin, newCalls }) => {
    // stapler validate 失败 → FAIL（此时公证已完成，资产不得流出）
    const bin = makeBin({
      stapler: 'if [ "$1" = "validate" ]; then echo "invalid staple" >&2; exit 1; fi',
    });
    runExpectFailure(
      join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin}:${process.env.PATH}` });

    // happy path 中 spctl 只应在公证/Staple 之后被调用（调用序列断言）
    const calls2 = newCalls('calls-order.log');
    const bin2 = makeBin({});
    run(join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin2}:${process.env.PATH}`, FAKE_CALLS: calls2 });
    const log = readFileSync(calls2, 'utf8').trim().split('\n');
    const firstSpctl = log.findIndex((l) => l.startsWith('spctl'));
    const notaryIdx = log.findIndex((l) => l.startsWith('notarytool'));
    const stapleIdx = log.findIndex((l) => l.startsWith('stapler'));
    assert.ok(notaryIdx > -1 && stapleIdx > -1);
    assert.ok(firstSpctl > stapleIdx, 'spctl 只允许在 Staple 之后做 Gatekeeper 复验');
  });
});

test('公证 Rejected → FAIL；skip 模式则完全绕开公证与 Staple', () => {
  withSandbox(({ dir, archive, makeBin, newCalls }) => {
    const bin = makeBin({ notarytool: 'echo "status: Rejected"\nexit 1' });
    runExpectFailure(
      join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin}:${process.env.PATH}` });

    const calls2 = newCalls('calls2.log');
    const bin2 = makeBin({});
    // 重建 bin2 但去掉 notarytool/stapler，验证 skip 模式零调用
    rmSync(join(bin2, 'notarytool'), { force: true });
    rmSync(join(bin2, 'stapler'), { force: true });
    const out = run(join(SPARKLE, 'export_and_notarize.sh'),
      ['--archive', archive, '--output-dir', join(dir, 'out2'), '--team-id', 'T', '--skip-notarization'],
      { PATH: `${bin2}:${process.env.PATH}`, FAKE_CALLS: calls2 });
    assert.match(out, /\[SKIP\] \[PASS 5\]/);
    assert.match(out, /\[SKIP\] \[PASS 6\]/);
    const log = readFileSync(calls2, 'utf8');
    assert.doesNotMatch(log, /notarytool/);
    assert.doesNotMatch(log, /stapler/);
  });
});

test('make_release_dmg：skip 模式产出 DMG；hdiutil verify 失败则 FAIL', () => {
  withSandbox(({ dir, app, makeBin, newCalls }) => {
    const dmg = join(dir, 'PaperRss-v9.9.9.dmg');
    const bin = makeBin({ notarytool: false });
    const out = run(join(SPARKLE, 'make_release_dmg.sh'), [
      '--app', app, '--output', dmg, '--version', '9.9.9', '--skip-notarization',
    ], { PATH: `${bin}:${process.env.PATH}` });
    assert.match(out, /\[PASS 7\]/);
    assert.match(out, /\[SKIP\] \[PASS 8\]/);
    assert.equal(existsSync(dmg), true);

    const calls2 = newCalls('calls-dmg.log');
    const bin2 = makeBin({
      hdiutil: 'if [ "$1" = "verify" ]; then exit 1; fi',
      'create-dmg': CREATE_DMG_TOUCH,
    });
    runExpectFailure(join(SPARKLE, 'make_release_dmg.sh'), [
      '--app', app, '--output', join(dir, 'b.dmg'), '--version', '9.9.9',
      '--notary-profile', 'p',
    ], { PATH: `${bin2}:${process.env.PATH}` });
  });
});

test('build_with_provenance：缺参 fail-fast；版本不一致拒绝出归档', () => {
  withSandbox(({ dir, archive, makeBin }) => {
    const bin = makeBin({ xcodebuild: ':;' });
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim();
    runExpectFailure(join(SPARKLE, 'build_with_provenance.sh'), [
      '--archive-path', archive,
    ], { PATH: `${bin}:${process.env.PATH}` });

    // 预置错误版本的 Info.plist，验证回读校验 fail-closed
    const infoDir = join(archive, 'Products', 'Applications', 'PaperRss.app', 'Contents');
    mkdirSync(infoDir, { recursive: true });
    writeFileSync(join(infoDir, 'Info.plist'),
      '<?xml version="1.0"?><plist version="1.0"><dict>' +
      '<key>CFBundleShortVersionString</key><string>0.0.0</string>' +
      '<key>CFBundleVersion</key><string>7</string>' +
      '<key>SUFeedURL</key><string>https://feed.example/stable.xml</string>' +
      '<key>SUPublicEDKey</key><string>PUBKEY</string>' +
      `<key>PaperRssSourceCommit</key><string>${head}</string>` +
      '</dict></plist>');
    const out = runExpectFailure(join(SPARKLE, 'build_with_provenance.sh'), [
      '--archive-path', archive,
      '--version', '9.9.9', '--build', '7',
      '--feed-url-stable', 'https://feed.example/stable.xml',
      '--public-ed-key', 'PUBKEY',
      '--source-commit', head,
    ], { PATH: `${bin}:${process.env.PATH}`, PAPERRSS_ALLOW_DIRTY: '1' });
    assert.match(out, /版本不一致/);
  });
});
