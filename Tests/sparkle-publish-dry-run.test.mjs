import assert from 'node:assert/strict';
import { chmod, cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import test from 'node:test';

const exec = promisify(execFile);
const root = resolve(fileURLToPath(new URL('../', import.meta.url)));
const appcastScript = join(root, 'scripts/sparkle/appcast.mjs');
const appcastPublisher = join(root, 'scripts/sparkle/publish_appcast_github.mjs');
const publishScript = join(root, 'scripts/sparkle/publish_release_dry_run.mjs');
const releasePublisher = join(root, 'scripts/sparkle/publish_release.sh');

const plist = ({ version, build }) => `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>`;

async function manifestFixture(parent, { version, build, channel = 'stable', filename = `PaperRss-v${version}.zip` }) {
  const { stdout: sourceCommitOutput } = await exec('git', ['rev-parse', 'HEAD'], { cwd: root });
  const sourceCommit = sourceCommitOutput.trim();
  const bytes = Buffer.from(`fixture-${version}-${build}`);
  const archive = join(parent, filename);
  await writeFile(archive, bytes);
  const dmgBytes = Buffer.from(`dmg-${version}-${build}`);
  const dmgFilename = `PaperRss-v${version}.dmg`;
  await writeFile(join(parent, dmgFilename), dmgBytes);
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const signature = sign(null, bytes, privateKey).toString('base64');
  const publicKeyPath = join(parent, `public-key-${build}.pem`);
  await writeFile(publicKeyPath, publicKey.export({ type: 'spki', format: 'pem' }));
  const manifest = join(parent, `manifest-${build}.json`);
  await writeFile(manifest, `${JSON.stringify({
    displayVersion: version,
    build: String(build),
    channel,
    filename,
    byteLength: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    edSignature: signature,
    minimumMacOS: '14.0',
    architectures: ['arm64', 'x86_64'],
    downloadURL: `https://github.com/example/PaperRss/releases/download/v${version}/${filename}`,
    dmgFilename,
    dmgByteLength: dmgBytes.length,
    dmgSha256: createHash('sha256').update(dmgBytes).digest('hex'),
    publicKeyPath,
    sourceCommit,
  }, null, 2)}\n`);
  return { manifest, archive, publicKeyPath, sourceCommit };
}

async function run(script, args, env = {}) {
  return exec(process.execPath, [script, ...args], {
    cwd: root,
    env: { ...process.env, ...env },
    maxBuffer: 1024 * 1024,
  });
}

async function runShell(script, args, env = {}) {
  return exec('/bin/bash', [script, ...args], {
    cwd: root,
    env: { ...process.env, ...env },
    maxBuffer: 1024 * 1024,
  });
}

test('Stable appcast 过滤预发布版本并保留 HTTPS、版本、build、长度与签名', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-appcast-contract-'));
  const stable = await manifestFixture(parent, { version: '2.0.0', build: 20 });
  const beta = await manifestFixture(parent, { version: '2.1.0-beta.1', build: 21, channel: 'beta' });
  const output = join(parent, 'stable.xml');

  await run(appcastScript, [
    'generate', '--channel', 'stable', '--manifest', stable.manifest, '--manifest', beta.manifest,
    '--output', output, '--public-key', stable.publicKeyPath,
  ]);
  const xml = await readFile(output, 'utf8');
  assert.match(xml, /<sparkle:version>20<\/sparkle:version>/);
  assert.match(xml, /<sparkle:shortVersionString>2\.0\.0<\/sparkle:shortVersionString>/);
  assert.match(xml, /sparkle:minimumSystemVersion="14\.0"/);
  assert.match(xml, /url="https:\/\/github\.com\//);
  assert.match(xml, /length="\d+"/);
  assert.match(xml, /sparkle:edSignature="[A-Za-z0-9+/=]+"/);
  assert.doesNotMatch(xml, /2\.1\.0-beta\.1/);
  await run(appcastScript, [
    'validate', '--channel', 'stable', '--appcast', output, '--asset-root', parent,
    '--public-key', stable.publicKeyPath,
  ]);
});

test('appcast 拒绝缺失资产、错误长度、重复 build 和非单调顺序', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-appcast-invalid-'));
  const first = await manifestFixture(parent, { version: '2.0.0', build: 20 });
  const second = await manifestFixture(parent, { version: '2.0.1', build: 21 });
  const invalid = JSON.parse(await readFile(second.manifest, 'utf8'));
  invalid.byteLength += 1;
  const invalidPath = join(parent, 'manifest-invalid.json');
  await writeFile(invalidPath, JSON.stringify(invalid));
  await assert.rejects(run(appcastScript, [
    'generate', '--channel', 'stable', '--manifest', invalidPath, '--output', join(parent, 'bad.xml'),
  ]), /length|长度|mismatch/i);

  await assert.rejects(run(appcastScript, [
    'generate', '--channel', 'stable', '--manifest', second.manifest, '--manifest', first.manifest,
    '--output', join(parent, 'order.xml'),
  ]), /monotonic|单调|order|顺序/i);
});

test('Beta appcast 可包含预发布与后续稳定版本，并保持 build 单调', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-beta-appcast-'));
  const beta = await manifestFixture(parent, { version: '2.1.0-beta.1', build: 21, channel: 'beta' });
  const stable = await manifestFixture(parent, { version: '2.1.0', build: 22, channel: 'stable' });
  const output = join(parent, 'beta.xml');
  await run(appcastScript, [
    'generate', '--channel', 'beta', '--manifest', beta.manifest, '--manifest', stable.manifest,
    '--output', output,
  ]);
  const xml = await readFile(output, 'utf8');
  assert.match(xml, /2\.1\.0-beta\.1/);
  assert.match(xml, /2\.1\.0<\/sparkle:shortVersionString>/);
  assert.match(xml, /<sparkle:version>21<\/sparkle:version>[\s\S]*<sparkle:version>22<\/sparkle:version>/);
});

test('publish dry-run 只按 build-validate → draft → upload all → publish → appcast，且拒绝既有资产', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-publish-dry-run-'));
  const fixture = await manifestFixture(parent, { version: '2.0.0', build: 20 });
  const output = join(parent, 'published');
  const tracePath = join(parent, 'trace.json');
  const statePath = join(parent, 'state.json');
  await writeFile(statePath, JSON.stringify({ tags: [], releases: [], assets: [] }));

  const result = await run(publishScript, [
    '--dry-run', '--channel', 'stable', '--tag', 'v2.0.0', '--manifest', fixture.manifest,
    '--output-dir', output, '--state', statePath, '--trace', tracePath,
    '--public-key', fixture.publicKeyPath,
  ]);
  assert.match(result.stdout, /dry-run/i);
  const trace = JSON.parse(await readFile(tracePath, 'utf8'));
  assert.deepEqual(trace.map((event) => event.step), [
    'build-validate', 'draft-create', 'upload-all', 'publish-release', 'publish-appcast',
  ]);
  assert.equal(trace.every((event) => event.remoteMutation === false), true);
  const stableXML = await readFile(join(output, 'stable.xml'), 'utf8');
  assert.match(stableXML, /2\.0\.0/);

  await writeFile(statePath, JSON.stringify({ tags: ['v2.0.0'], releases: [], assets: [] }));
  await assert.rejects(run(publishScript, [
    '--dry-run', '--channel', 'stable', '--tag', 'v2.0.0', '--manifest', fixture.manifest,
    '--output-dir', join(parent, 'rejected'), '--state', statePath,
  ]), /existing|已存在|immutable|不可变/i);
});

test('publish dry-run 拒绝真实执行开关，不调用 gh/git，也不覆盖已有输出', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-publish-guard-'));
  const fixture = await manifestFixture(parent, { version: '2.0.0', build: 20 });
  await assert.rejects(run(publishScript, [
    '--execute', '--channel', 'stable', '--tag', 'v2.0.0', '--manifest', fixture.manifest,
    '--output-dir', join(parent, 'blocked'),
  ]), /dry-run|remote|远程|execute/i);
  const output = join(parent, 'existing');
  await writeFile(output, 'sentinel');
  await assert.rejects(run(publishScript, [
    '--dry-run', '--channel', 'stable', '--tag', 'v2.0.0', '--manifest', fixture.manifest,
    '--output-dir', output,
  ]), /exists|已存在|overwrite|覆盖/i);
  assert.equal(await readFile(output, 'utf8'), 'sentinel');
});

test('仓库内 appcast publisher 只写固定 docs 路径，并以 GitHub API 读回内容完成复验', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-appcast-publisher-'));
  const fixture = await manifestFixture(parent, { version: '2.0.0', build: 20 });
  const appcast = join(parent, 'stable.xml');
  await run(appcastScript, [
    'generate', '--channel', 'stable', '--manifest', fixture.manifest,
    '--output', appcast, '--public-key', fixture.publicKeyPath,
  ]);
  const fakeGh = join(parent, 'gh');
  const state = join(parent, 'remote-appcast.xml');
  const log = join(parent, 'gh.log');
  await writeFile(fakeGh, `#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$GH_LOG"
if [[ "${'${1:-}'}" != api ]]; then exit 8; fi
method=GET
content=""
for argument in "$@"; do
  [[ "$argument" == --method ]] && method_marker=1 && continue
  if [[ "${'${method_marker:-0}'}" == 1 ]]; then method="$argument"; method_marker=0; continue; fi
  [[ "$argument" == content=* ]] && content="${'${argument#content=}'}"
done
if [[ "$method" == PUT ]]; then
  printf '%s' "$content" | /usr/bin/base64 -D > "$GH_STATE"
  printf '{"content":{"sha":"updated"}}\\n'
  exit 0
fi
if [[ ! -f "$GH_STATE" ]]; then echo '404 Not Found' >&2; exit 1; fi
if [[ "${'${GH_CORRUPT_READBACK:-0}'}" == 1 ]]; then
  encoded=$(printf wrong | /usr/bin/base64 | tr -d '\\n')
else
  encoded=$(/usr/bin/base64 < "$GH_STATE" | tr -d '\\n')
fi
printf '{"sha":"remote-sha","encoding":"base64","content":"%s"}\\n' "$encoded"
`);
  await chmod(fakeGh, 0o755);
  const environment = {
    PATH: `${parent}:${process.env.PATH}`,
    GH_LOG: log,
    GH_STATE: state,
    PAPERRSS_APPCAST_AUTHORIZED: 'YES',
    PAPERRSS_APPCAST_CONFIRM: 'PUBLISH example/PaperRss:main:website/appcast/stable.xml',
  };

  const result = await run(appcastPublisher, [
    '--execute', '--repo', 'example/PaperRss', '--branch', 'main',
    '--path', 'website/appcast/stable.xml', '--channel', 'stable', '--appcast', appcast,
    '--asset-root', parent, '--public-key', fixture.publicKeyPath,
  ], environment);
  assert.match(result.stdout, /read.?back|读回|validated|已验证/i);
  assert.equal(await readFile(state, 'utf8'), await readFile(appcast, 'utf8'));
  const commands = (await readFile(log, 'utf8')).trim().split('\n');
  assert.equal(commands.length, 3);
  assert.match(commands[0], /api repos\/example\/PaperRss\/contents\/website\/appcast\/stable\.xml\?ref=main/);
  assert.match(commands[1], /api --method PUT repos\/example\/PaperRss\/contents\/website\/appcast\/stable\.xml/);
  assert.match(commands[2], /api repos\/example\/PaperRss\/contents\/website\/appcast\/stable\.xml\?ref=main/);

  await assert.rejects(run(appcastPublisher, [
    '--execute', '--repo', 'example/PaperRss', '--branch', 'main',
    '--path', 'website/appcast/stable.xml', '--channel', 'stable', '--appcast', appcast,
    '--asset-root', parent, '--public-key', fixture.publicKeyPath,
  ], { ...environment, GH_CORRUPT_READBACK: '1' }), /read.?back|读回|mismatch|不一致/i);
  await assert.rejects(run(appcastPublisher, [
    '--execute', '--repo', 'example/PaperRss', '--branch', 'main',
    '--path', 'stable.xml', '--channel', 'stable', '--appcast', appcast,
    '--asset-root', parent, '--public-key', fixture.publicKeyPath,
  ], environment), /website\/appcast|path|路径/i);
});

test('正式发布绑定 target commit，并支持只核验资产后恢复 appcast', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-publish-entrypoint-'));
  const fixture = await manifestFixture(parent, { version: '2.0.0', build: 20 });
  const output = join(parent, 'output');
  const log = join(parent, 'gh.log');
  const fakeGh = join(parent, 'gh');
  const releaseState = join(parent, 'release-state');
  const appcastState = join(parent, 'remote-appcast.xml');
  const caskState = join(parent, 'remote-cask.rb');
  await writeFile(caskState, 'cask "paperrss" do\n  version "1.9.0"\n  sha256 "' + 'a'.repeat(64) + '"\n  url "https://github.com/example/PaperRss/releases/download/v#{version}/PaperRss-v#{version}.dmg"\nend\n');
  await writeFile(fakeGh, `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.GH_LOG, args.join(' ') + '\\n');
const releaseState = process.env.GH_RELEASE_STATE;
const state = fs.existsSync(releaseState) ? fs.readFileSync(releaseState, 'utf8').trim() : 'absent';
const target = process.env.GH_TARGET_COMMIT;
const fail404 = () => { process.stderr.write('404 Not Found\\n'); process.exit(1); };
if (args[0] === 'api') {
  const endpoint = args.find((arg) => arg.startsWith('repos/')) || '';
  if (endpoint.includes('/commits/')) { process.stdout.write(target + '\\n'); process.exit(0); }
  if (endpoint.includes('/git/ref/tags/')) {
    if (state === 'absent') fail404();
    process.stdout.write(args.includes('--jq') ? target + '\\n' : JSON.stringify({ object: { sha: target } }) + '\\n');
    process.exit(0);
  }
  if (endpoint.includes('/contents/Casks/paperrss.rb')) {
    if (args.includes('PUT')) {
      const content = args.find((arg) => arg.startsWith('content=')).slice(8);
      fs.writeFileSync(process.env.GH_CASK_STATE, Buffer.from(content, 'base64'));
      process.stdout.write('{}'); process.exit(0);
    }
    process.stdout.write(JSON.stringify({sha: 'cask-sha', encoding: 'base64', content: fs.readFileSync(process.env.GH_CASK_STATE).toString('base64')}));
    process.exit(0);
  }
  if (endpoint.includes('/contents/website/appcast/')) {
    const methodIndex = args.indexOf('--method');
    const method = methodIndex >= 0 ? args[methodIndex + 1] : 'GET';
    if (method === 'PUT') {
      const fields = args.filter((arg, index) => args[index - 1] === '-f');
      const content = fields.find((field) => field.startsWith('content='))?.slice('content='.length);
      if (!content) process.exit(7);
      fs.writeFileSync(process.env.GH_APPCAST_STATE, Buffer.from(content, 'base64'));
      process.stdout.write('{"content":{"sha":"updated"}}\\n');
      process.exit(0);
    }
    if (!fs.existsSync(process.env.GH_APPCAST_STATE)) fail404();
    const bytes = fs.readFileSync(process.env.GH_APPCAST_STATE);
    process.stdout.write(JSON.stringify({ sha: 'feed-sha', encoding: 'base64', content: bytes.toString('base64') }) + '\\n');
    process.exit(0);
  }
}
if (args[0] === 'release' && args[1] === 'view') {
  if (state === 'absent') fail404();
  process.stdout.write(JSON.stringify({
    isDraft: state === 'draft', isPrerelease: false, tagName: 'v2.0.0', targetCommitish: target,
    assets: [{ name: 'PaperRss-v2.0.0.zip' }, { name: 'PaperRss-v2.0.0.dmg', url: 'https://github.com/example/PaperRss/releases/download/v2.0.0/PaperRss-v2.0.0.dmg' }],
  }) + '\\n');
  process.exit(0);
}
if (args[0] === 'release' && args[1] === 'create') {
  fs.writeFileSync(releaseState, 'draft'); process.exit(0);
}
if (args[0] === 'release' && args[1] === 'edit') {
  fs.writeFileSync(releaseState, 'published'); process.exit(0);
}
if (args[0] === 'release' && args[1] === 'download') {
  const destination = args[args.indexOf('--dir') + 1];
  const patterns = args.flatMap((arg, index) => args[index - 1] === '--pattern' ? [arg] : []);
  fs.mkdirSync(destination, { recursive: true });
  for (const name of patterns) fs.copyFileSync(path.join(process.env.GH_ASSET_ROOT, name), path.join(destination, name));
  process.exit(0);
}
if (args[0] === 'release' && args[1] === 'upload') process.exit(0);
process.exit(9);
`);
  await chmod(fakeGh, 0o755);

  const noRemoteMutationGh = join(parent, 'gh-must-not-run');
  await writeFile(noRemoteMutationGh, '#!/bin/sh\necho remote mutation >&2\nexit 9\n');
  await chmod(noRemoteMutationGh, 0o755);
  const dryRun = await runShell(releasePublisher, [
    '--repo', 'example/PaperRss',
    '--channel', 'stable', '--tag', 'v2.0.0', '--manifest', fixture.manifest,
    '--output-dir', output, '--public-key', fixture.publicKeyPath,
  ], { PATH: `${parent}:${process.env.PATH}`, GH_LOG: log });
  assert.match(dryRun.stdout, /dry-run/i);
  await assert.rejects(readFile(log), { code: 'ENOENT' });

  const environment = {
    PATH: `${parent}:${process.env.PATH}`,
    GH_LOG: log,
    GH_RELEASE_STATE: releaseState,
    GH_APPCAST_STATE: appcastState,
    GH_CASK_STATE: caskState,
    GH_ASSET_ROOT: parent,
    GH_TARGET_COMMIT: fixture.sourceCommit,
    PAPERRSS_RELEASE_AUTHORIZED: 'YES',
    PAPERRSS_RELEASE_CONFIRM: 'PUBLISH v2.0.0',
  };
  const formalArgs = [
    '--execute', '--repo', 'example/PaperRss', '--channel', 'stable', '--tag', 'v2.0.0',
    '--manifest', fixture.manifest, '--public-key', fixture.publicKeyPath,
    '--target-commit', fixture.sourceCommit, '--appcast-repo', 'example/PaperRss',
    '--appcast-branch', 'main', '--appcast-path', 'website/appcast/stable.xml',
  ];

  const oldFixture = await manifestFixture(parent, { version: '1.9.0', build: 19 });
  const staleOutput = join(parent, 'stale-output');
  await run(appcastScript, [
    'generate', '--channel', 'stable', '--manifest', oldFixture.manifest,
    '--output', join(parent, 'old-stable.xml'), '--public-key', oldFixture.publicKeyPath,
  ]);
  await mkdir(staleOutput);
  await cp(join(parent, 'old-stable.xml'), join(staleOutput, 'stable.xml'));
  await assert.rejects(runShell(releasePublisher, [
    ...formalArgs, '--output-dir', staleOutput,
  ], environment), /当前 manifest|旧版|不匹配|does not match/i);
  assert.doesNotMatch(await readFile(log, 'utf8'), /release create/);
  await writeFile(log, '');

  const executeOutput = join(parent, 'execute-output');
  const execute = await runShell(releasePublisher, [...formalArgs, '--output-dir', executeOutput], environment);
  assert.match(execute.stdout, /draft.*upload-all.*publish.*appcast|正式发布顺序/i);
  const commands = (await readFile(log, 'utf8')).trim().split('\n');
  assert.match(commands[0], new RegExp(`api repos/example/PaperRss/commits/${fixture.sourceCommit}`));
  assert.match(commands[1], /api repos\/example\/PaperRss\/git\/ref\/tags\/v2\.0\.0/);
  assert.match(commands[2], /release view v2\.0\.0/);
  assert.match(commands[3], new RegExp(`release create v2.0.0.*--target ${fixture.sourceCommit}`));
  assert.match(commands[4], /release upload v2\.0\.0.*PaperRss-v2\.0\.0\.zip.*PaperRss-v2\.0\.0\.dmg/);
  assert.match(commands[5], /release edit v2\.0\.0.*--draft=false/);
  assert.match(commands.slice(6).join('\n'), /contents\/website\/appcast\/stable\.xml/);

  const caskPut = commands.findIndex((command) => /PUT.*contents\/Casks\/paperrss.rb/.test(command));
  const appcastPut = commands.findIndex((command) => /PUT.*contents\/website\/appcast/.test(command));
  assert.ok(caskPut > appcastPut, 'Homebrew 必须在 appcast 发布成功后执行');
  assert.match(await readFile(caskState, 'utf8'), /version "2\.0\.0"/);
  await writeFile(log, '');
  await writeFile(appcastState, 'stale remote appcast');
  const resumed = await runShell(releasePublisher, [
    ...formalArgs, '--resume-appcast', '--output-dir', executeOutput,
  ], environment);
  assert.match(resumed.stdout, /恢复完成|resume/i);
  const resumeCommands = (await readFile(log, 'utf8')).trim().split('\n');
  assert.match(resumeCommands[0], new RegExp(`api repos/example/PaperRss/commits/${fixture.sourceCommit}`));
  assert.match(resumeCommands[1], /api repos\/example\/PaperRss\/git\/ref\/tags\/v2\.0\.0/);
  assert.match(resumeCommands[2], /release view v2\.0\.0/);
  assert.match(resumeCommands[3], /release download v2\.0\.0/);
  assert.equal(resumeCommands.some((command) => /release (create|upload|edit)/.test(command)), false);
  assert.match(resumeCommands.slice(4).join('\n'), /api --method PUT repos\/example\/PaperRss\/contents\/website\/appcast\/stable\.xml/);

  assert.doesNotMatch(resumeCommands.join('\n'), /PUT.*contents\/Casks\/paperrss.rb/);

  // beta 必须在首次公开前标记为预发布，不能触发稳定版镜像同步。
  const beta = await manifestFixture(parent, { version: '2.1.0-beta.1', build: 21, channel: 'beta' });
  await writeFile(releaseState, 'absent');
  await writeFile(log, '');
  await runShell(releasePublisher, [
    '--execute', '--repo', 'example/PaperRss', '--channel', 'beta', '--tag', 'v2.1.0-beta.1',
    '--manifest', beta.manifest, '--public-key', beta.publicKeyPath,
    '--target-commit', beta.sourceCommit, '--appcast-repo', 'example/PaperRss',
    '--appcast-branch', 'main', '--appcast-path', 'website/appcast/beta.xml',
    '--output-dir', join(parent, 'beta-output'),
  ], { ...environment, PAPERRSS_RELEASE_CONFIRM: 'PUBLISH v2.1.0-beta.1' });
  const betaCommands = (await readFile(log, 'utf8')).trim().split('\n');
  assert.doesNotMatch(betaCommands.join('\n'), /homebrew-tap|Casks/);
  const createBeta = betaCommands.find((command) => command.startsWith('release create '));
  assert.match(createBeta, /--prerelease(?:\s|$)/);
  assert.match(createBeta, /--latest=false(?:\s|$)/);
  assert.match(betaCommands.find((command) => command.startsWith('release edit ')), /--latest=false/);
  assert.doesNotMatch(betaCommands.join('\n'), /contents\/website\/appcast\/stable\.xml/);
});
