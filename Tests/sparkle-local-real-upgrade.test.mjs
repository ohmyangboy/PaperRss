import assert from 'node:assert/strict';
import { execFile as execFileCallback, spawn } from 'node:child_process';
import { chmod, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { get } from 'node:https';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

const execFile = promisify(execFileCallback);
const root = resolve(fileURLToPath(new URL('../', import.meta.url)));
const serverScript = join(root, 'scripts/sparkle/local_https_feed_server.mjs');
const prepareScript = join(root, 'scripts/sparkle/prepare_local_real_upgrade.sh');
const appcastScript = join(root, 'scripts/sparkle/appcast.mjs');

async function run(command, args, options = {}) {
  return execFile(command, args, {
    cwd: root,
    env: { ...process.env, ...options.env },
    maxBuffer: 1024 * 1024,
    ...options,
  });
}

async function runShell(args, options = {}) {
  return run('/bin/bash', [prepareScript, ...args], options);
}

async function makeTLSFixture(parent) {
  const tls = join(parent, 'tls');
  await run('mkdir', ['-p', tls]);
  const caKey = join(tls, 'ca-key.pem');
  const caCert = join(tls, 'ca.pem');
  const leafKey = join(tls, 'leaf-key.pem');
  const leafCSR = join(tls, 'leaf.csr');
  const leafCert = join(tls, 'leaf.pem');
  await run('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
    '-subj', '/CN=PaperRss local test CA', '-keyout', caKey, '-out', caCert,
  ], { stdio: 'ignore' });
  await run('openssl', [
    'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256',
    '-subj', '/CN=localhost', '-keyout', leafKey, '-out', leafCSR,
  ], { stdio: 'ignore' });
  const extensions = join(tls, 'leaf.ext');
  await writeFile(extensions, 'subjectAltName=DNS:localhost,IP:127.0.0.1\n');
  await run('openssl', [
    'x509', '-req', '-in', leafCSR, '-CA', caCert, '-CAkey', caKey,
    '-CAcreateserial', '-out', leafCert, '-days', '1', '-sha256', '-extfile', extensions,
  ], { stdio: 'ignore' });
  return { caCert, leafKey, leafCert };
}

async function waitForReady(path, child) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try { return JSON.parse(await readFile(path, 'utf8')); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (child.exitCode !== null) throw new Error(`local feed server exited with ${child.exitCode}`);
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(`timed out waiting for local feed server ${path}`);
}

function httpsGet(url, ca) {
  return new Promise((resolveGet, rejectGet) => {
    const request = get(url, { ca }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolveGet({ status: response.statusCode, body: Buffer.concat(chunks) }));
    });
    request.on('error', rejectGet);
  });
}

test('本地 HTTPS feed server 只服务临时目录内的 appcast 与 ZIP，并支持 CA 验证', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-local-real-server-'));
  const tls = await makeTLSFixture(parent);
  const feedRoot = join(parent, 'feed');
  await run('mkdir', ['-p', join(feedRoot, 'releases')]);
  const archive = Buffer.from('PaperRss local N+1 archive');
  const filename = 'PaperRss-v1.3.0-beta.2.zip';
  await writeFile(join(feedRoot, 'releases', filename), archive);
  await writeFile(join(feedRoot, 'beta.xml'), '<rss><channel><item>beta</item></channel></rss>\n');
  const ready = join(parent, 'ready.json');
  const child = spawn(process.execPath, [
    serverScript, '--root', feedRoot, '--tls-key', tls.leafKey,
    '--tls-cert', tls.leafCert, '--ready-file', ready,
  ], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  try {
    const info = await waitForReady(ready, child);
    assert.equal(info.host, '127.0.0.1');
    assert.match(info.baseURL, /^https:\/\/127\.0\.0\.1:\d+$/);
    const appcast = await httpsGet(`${info.baseURL}/beta.xml`, await readFile(tls.caCert));
    assert.equal(appcast.status, 200);
    assert.match(appcast.body.toString(), /<item>beta<\/item>/);
    const asset = await httpsGet(`${info.baseURL}/releases/${filename}`, await readFile(tls.caCert));
    assert.equal(asset.status, 200);
    assert.equal(createHash('sha256').update(asset.body).digest('hex'), createHash('sha256').update(archive).digest('hex'));
    const traversal = await httpsGet(`${info.baseURL}/../leaf-key.pem`, await readFile(tls.caCert));
    assert.equal(traversal.status, 404);
  } finally {
    child.kill('SIGTERM');
    if (child.exitCode === null) await new Promise((resolveExit) => child.once('exit', resolveExit));
  }
});

test('本地真实升级准备命令的 plan 注入 HTTPS feed、公钥和 N/N+1 参数，默认不修改 Keychain', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-local-real-plan-'));
  const workspace = join(parent, 'workspace');
  const publicKey = join(parent, 'public-key.txt');
  const securityTrace = join(parent, 'security.trace');
  await writeFile(publicKey, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n');
  const fakeSecurity = join(parent, 'security');
  await writeFile(fakeSecurity, `#!/bin/sh\nprintf '%s\\n' "$*" >> "$SECURITY_TRACE"\nexit 99\n`);
  await chmod(fakeSecurity, 0o755);
  const result = await runShell([
    '--plan-only', '--keep-workspace', '--workspace', workspace,
    '--account', 'paperrss-issue11-local', '--public-key-file', publicKey,
    '--security-bin', fakeSecurity, '--no-server',
  ], { env: { SECURITY_TRACE: securityTrace } });
  assert.match(result.stdout, /计划|plan/i);
  assert.match(result.stdout, /SUFeedURL=https:\/\/127\.0\.0\.1:/);
  assert.match(result.stdout, /SUBetaFeedURL=https:\/\/127\.0\.0\.1:/);
  assert.match(result.stdout, /SUPublicEDKey=AAAAAAAA/);
  assert.doesNotMatch(result.stdout, /INFOPLIST_KEY_/);
  assert.match(result.stdout, /N\/N\+1|N\s*到\s*N\+1/i);
  await assert.rejects(stat(securityTrace), { code: 'ENOENT' });
  assert.ok(await stat(join(workspace, 'tls', 'ca.pem')));
  assert.ok(await stat(join(workspace, 'tls', 'leaf.pem')));
});

test('复用工作目录时会刷新本地 HTTPS server ready 状态', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-local-real-reuse-'));
  const workspace = join(parent, 'workspace');
  const publicKey = join(parent, 'public-key.txt');
  await writeFile(publicKey, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n');

  await runShell([
    '--plan-only', '--keep-workspace', '--workspace', workspace,
    '--public-key-file', publicKey,
  ]);
  const firstReady = JSON.parse(await readFile(join(workspace, 'server-ready.json'), 'utf8'));

  await runShell([
    '--plan-only', '--keep-workspace', '--workspace', workspace,
    '--public-key-file', publicKey,
  ]);
  const secondReady = JSON.parse(await readFile(join(workspace, 'server-ready.json'), 'utf8'));

  assert.notEqual(secondReady.pid, firstReady.pid);
});

test('缺少 Sparkle 公钥时准备命令 fail closed，且不会继续生成或调用远程发布工具', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-local-real-missing-key-'));
  const workspace = join(parent, 'workspace');
  const generator = join(parent, 'generate-keys');
  const trace = join(parent, 'remote.trace');
  await writeFile(generator, '#!/bin/sh\nprintf "missing key" >&2\nexit 1\n');
  await chmod(generator, 0o755);
  const fakeRemote = join(parent, 'gh');
  await writeFile(fakeRemote, `#!/bin/sh\nprintf '%s\\n' "$*" >> "$REMOTE_TRACE"\nexit 88\n`);
  await chmod(fakeRemote, 0o755);
  await assert.rejects(runShell([
    '--plan-only', '--keep-workspace', '--workspace', workspace,
    '--generate-keys-bin', generator, '--account', 'missing-account', '--no-server',
  ], { env: { PATH: `${parent}:${process.env.PATH}`, REMOTE_TRACE: trace } }), /公钥|Keychain|key|fail/i);
  await assert.rejects(stat(join(workspace, 'tls', 'ca.pem')), { code: 'ENOENT' });
  await assert.rejects(stat(trace), { code: 'ENOENT' });
});

test('appcast 生成器接受 Sparkle Info.plist 使用的 raw base64 公钥', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-local-real-raw-key-'));
  const archive = join(parent, 'PaperRss-v1.3.0-beta.2.zip');
  const bytes = Buffer.from('raw-key-appcast-fixture');
  await writeFile(archive, bytes);
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const rawPublicKey = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
  const publicKeyPath = join(parent, 'sparkle-public-key.txt');
  await writeFile(publicKeyPath, `${rawPublicKey}\n`);
  const manifestPath = join(parent, 'manifest.json');
  await writeFile(manifestPath, `${JSON.stringify({
    displayVersion: '1.3.0-beta.2',
    build: '11',
    channel: 'beta',
    filename: archive.split('/').pop(),
    byteLength: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    edSignature: sign(null, bytes, privateKey).toString('base64'),
    minimumMacOS: '14.0',
    downloadURL: `https://127.0.0.1:12345/releases/${archive.split('/').pop()}`,
  }, null, 2)}\n`);
  const output = join(parent, 'beta.xml');
  await run(process.execPath, [appcastScript, 'generate', '--channel', 'beta', '--manifest', manifestPath,
    '--output', output, '--public-key', publicKeyPath]);
  assert.match(await readFile(output, 'utf8'), /1\.3\.0-beta\.2/);
});

test('只有显式 --install-ca 才调用 security 安装临时根证书', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-local-real-install-ca-'));
  const workspace = join(parent, 'workspace');
  const publicKey = join(parent, 'public-key.txt');
  const securityTrace = join(parent, 'security.trace');
  const fakeSecurity = join(parent, 'security');
  await writeFile(publicKey, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n');
  await writeFile(fakeSecurity, `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$SECURITY_TRACE"
if [ "\${1:-}" = default-keychain ]; then printf '%s\\n' '  "login keychain-db"  '; fi
`);
  await chmod(fakeSecurity, 0o755);
  await runShell([
    '--plan-only', '--keep-workspace', '--workspace', workspace,
    '--public-key-file', publicKey, '--security-bin', fakeSecurity,
    '--install-ca', '--no-server',
  ], { env: { SECURITY_TRACE: securityTrace } });
  const trace = await readFile(securityTrace, 'utf8');
  assert.match(trace, /default-keychain/);
  assert.match(trace, /add-trusted-cert/);
  assert.match(trace, /trustRoot/);
  assert.match(trace, /login keychain-db/);
});
