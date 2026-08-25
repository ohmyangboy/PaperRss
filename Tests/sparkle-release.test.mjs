import assert from 'node:assert/strict';
import { chmod, cp, mkdtemp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { generateKeyPairSync } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import test from 'node:test';

const exec = promisify(execFile);
const root = resolve(fileURLToPath(new URL('../', import.meta.url)));
const buildScript = join(root, 'scripts/sparkle/build_artifacts.sh');
const validateScript = join(root, 'scripts/sparkle/validate_artifacts.sh');

const fixtureInfo = (version = '9.8.7-beta.2', build = '42', publicKey, sourceCommit) => `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PaperRss</string>
<key>CFBundleIdentifier</key><string>com.example.PaperRss</string>
<key>CFBundleName</key><string>PaperRss</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>SUPublicEDKey</key><string>${publicKey}</string>
<key>PaperRssSourceCommit</key><string>${sourceCommit}</string>
</dict></plist>
`;

async function fixtureApp(parent, version = '9.8.7-beta.2', build = '42') {
  const app = join(parent, 'PaperRss.app');
  const { stdout: sourceCommitOutput } = await exec('git', ['rev-parse', 'HEAD'], { cwd: root });
  const sourceCommit = sourceCommitOutput.trim();
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const rawPublicKey = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
  const privateKeyPath = join(parent, `private-key-${build}.pem`);
  await writeFile(privateKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
  await writeFile(join(app, 'Contents/Info.plist'), fixtureInfo(version, build, rawPublicKey, sourceCommit));
  await cp('/bin/echo', join(app, 'Contents/MacOS/PaperRss'));
  return { app, privateKeyPath, sourceCommit };
}

async function fakeSigner(parent) {
const signer = join(parent, 'fake-sign-update.mjs');
  await writeFile(
    signer,
    `#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';
const archive = process.argv.at(-1);
const privateKey = createPrivateKey(readFileSync(process.env.SPARKLE_TEST_PRIVATE_KEY));
const delay = Number(process.env.SPARKLE_TEST_SIGN_DELAY_MS || 0);
if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
const readyFile = process.env.SPARKLE_TEST_SIGN_READY_FILE;
const continueFile = process.env.SPARKLE_TEST_SIGN_CONTINUE_FILE;
const secondaryFile = process.env.SPARKLE_TEST_SIGN_SECONDARY_FILE;
if (readyFile && secondaryFile && existsSync(readyFile)) {
  writeFileSync(secondaryFile, 'secondary signer reached');
}
if (readyFile && !existsSync(readyFile)) {
  writeFileSync(readyFile, 'ready');
  while (!continueFile || !existsSync(continueFile)) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
const signature = sign(null, readFileSync(archive), privateKey).toString('base64');
if (process.argv.includes('-p')) {
  console.log(signature);
} else {
  console.log(\`sparkle:edSignature="\${signature}" length="\${readFileSync(archive).byteLength}"\`);
}
`,
  );
  await chmod(signer, 0o755);
  return signer;
}

async function unavailableSigner(parent) {
  const signer = join(parent, 'unavailable-sign-update.sh');
  await writeFile(signer, '#!/bin/sh\necho "ERROR: signing key unavailable in Keychain" >&2\nexit 1\n');
  await chmod(signer, 0o755);
  return signer;
}

async function fakeHdiutil(parent) {
  const hdiutil = join(parent, 'fake-hdiutil.sh');
  await writeFile(
    hdiutil,
    `#!/bin/bash
set -eu
if [[ "\${1:-}" == imageinfo ]]; then
  /usr/bin/unzip -tqq "\${2:?}" >/dev/null
  exit 0
fi
if [[ "\${1:-}" == create ]]; then
  source=""
  for ((index=1; index<\$#; index++)); do
    if [[ "\${!index}" == -srcfolder ]]; then
      next=\$((index + 1))
      source="\${!next}"
    fi
  done
  output="\${!#}"
  /usr/bin/ditto -c -k --keepParent "\$source" "\$output"
  exit 0
fi
echo "unsupported hdiutil operation" >&2
exit 2
`,
  );
  await chmod(hdiutil, 0o755);
  return hdiutil;
}

async function waitForFile(path) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      await readFile(path);
      return;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for ${path}`);
}

async function fileExists(path) {
  try {
    await readFile(path);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

async function run(script, args, env = {}) {
  return exec(script, args, {
    cwd: root,
    env: { ...process.env, ...env },
    maxBuffer: 1024 * 1024,
  });
}

test('本地打包没有可用 Sparkle 私钥时 fail closed', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-missing-key-'));
  const { app } = await fixtureApp(parent);
  const signer = await unavailableSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');
  await assert.rejects(
    run(buildScript, ['--app', app, '--output-dir', output, '--channel', 'beta'], {
      SPARKLE_SIGN_UPDATE: signer,
      SPARKLE_HDIUTIL: hdiutil,
    }),
    /sign_update|EdDSA|Keychain|签名/i,
  );
  assert.deepEqual(await readdir(output), []);
});

test('从同一 app 生成可验证 ZIP、DMG 与发布 manifest', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-valid-'));
  const fixture = await fixtureApp(parent);
  const app = fixture.app;
  const signer = await fakeSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');

  await run(buildScript, ['--app', app, '--output-dir', output, '--channel', 'beta'], {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
  });

  const releaseDirectory = join(output, 'PaperRss-v9.8.7-beta.2');
  assert.deepEqual(await readdir(output), ['PaperRss-v9.8.7-beta.2']);
  const manifest = JSON.parse(await readFile(join(releaseDirectory, 'manifest.json'), 'utf8'));
  assert.equal(manifest.displayVersion, '9.8.7-beta.2');
  assert.equal(manifest.build, '42');
  assert.equal(manifest.channel, 'beta');
  assert.match(manifest.filename, /PaperRss-v9\.8\.7-beta\.2\.zip$/);
  assert.equal(manifest.byteLength > 0, true);
  assert.match(manifest.sha256, /^[a-f0-9]{64}$/);
  assert.match(manifest.edSignature, /^[A-Za-z0-9+/]{86}==$/);
  assert.equal(manifest.minimumMacOS, '14.0');
  assert.equal(manifest.downloadURL, 'https://github.com/ohmyangboy/PaperRss/releases/download/v9.8.7-beta.2/PaperRss-v9.8.7-beta.2.zip');
  assert.deepEqual(manifest.architectures, ['arm64', 'x86_64']);
  assert.equal(manifest.dmgFilename, 'PaperRss-v9.8.7-beta.2.dmg');
  assert.match(manifest.sourceCommit, /^[a-f0-9]{40}$/);

  await run(validateScript, ['--manifest', join(releaseDirectory, 'manifest.json')], {
    SPARKLE_HDIUTIL: hdiutil,
  });
});

test('真实 App 顶层包内允许 Sparkle Updater 辅助 App', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-nested-updater-'));
  const fixture = await fixtureApp(parent);
  const updater = join(
    fixture.app,
    'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents',
  );
  await mkdir(updater, { recursive: true });
  await writeFile(join(updater, 'Info.plist'), '<plist version="1.0"><dict/></plist>');
  const signer = await fakeSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');

  await run(buildScript, ['--app', fixture.app, '--output-dir', output, '--channel', 'beta'], {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
  });

  assert.equal(
    await fileExists(join(output, 'PaperRss-v9.8.7-beta.2/manifest.json')),
    true,
  );
});

test('产物校验拒绝损坏归档、版本元数据不一致和错误构架', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-invalid-'));
  const fixture = await fixtureApp(parent, '9.8.7', '42');
  const app = fixture.app;
  const signer = await fakeSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');
  await run(buildScript, ['--app', app, '--output-dir', output, '--channel', 'stable'], {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
  });
  const releaseDirectory = join(output, 'PaperRss-v9.8.7');
  const manifestPath = join(releaseDirectory, 'manifest.json');
  const original = JSON.parse(await readFile(manifestPath, 'utf8'));

  await writeFile(manifestPath, JSON.stringify({ ...original, displayVersion: '0.0.0' }));
  await assert.rejects(run(validateScript, ['--manifest', manifestPath], {
    SPARKLE_HDIUTIL: hdiutil,
  }), /version|版本/i);
  await writeFile(manifestPath, JSON.stringify({ ...original, architectures: ['mips64'] }));
  await assert.rejects(run(validateScript, ['--manifest', manifestPath], {
    SPARKLE_HDIUTIL: hdiutil,
  }), /architect|构架/i);
  await writeFile(manifestPath, JSON.stringify({ ...original, edSignature: '' }));
  await assert.rejects(run(validateScript, ['--manifest', manifestPath], {
    SPARKLE_HDIUTIL: hdiutil,
  }), /signature|签名/i);
  await writeFile(manifestPath, JSON.stringify({
    ...original,
    edSignature: Buffer.alloc(64, 7).toString('base64'),
  }));
  await assert.rejects(run(validateScript, ['--manifest', manifestPath], {
    SPARKLE_HDIUTIL: hdiutil,
  }), /EdDSA|signature|签名/i);
  await writeFile(manifestPath, JSON.stringify({ ...original, downloadURL: original.downloadURL.replace('https:', 'http:') }));
  await assert.rejects(run(validateScript, ['--manifest', manifestPath], {
    SPARKLE_HDIUTIL: hdiutil,
  }), /HTTPS|downloadURL/i);
  await writeFile(manifestPath, JSON.stringify(original));

  await writeFile(join(releaseDirectory, original.filename), Buffer.from('corrupt archive'));
  await assert.rejects(run(validateScript, ['--manifest', manifestPath], {
    SPARKLE_HDIUTIL: hdiutil,
  }), /hash|sha.?256|mismatch|损坏|完整/i);
});

test('本地产物拒绝覆盖同名 ZIP、DMG 或 manifest，并保留既有证据', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-no-overwrite-'));
  const fixture = await fixtureApp(parent);
  const signer = await fakeSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');
  await run(buildScript, ['--app', fixture.app, '--output-dir', output, '--channel', 'beta'], {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
  });
  const releaseDirectory = join(output, 'PaperRss-v9.8.7-beta.2');
  const archivePath = join(releaseDirectory, 'PaperRss-v9.8.7-beta.2.zip');
  await writeFile(archivePath, 'sentinel');
  await assert.rejects(run(buildScript, ['--app', fixture.app, '--output-dir', output, '--channel', 'beta'], {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
  }), /exists|已存在|覆盖|overwrite/i);
  assert.equal(await readFile(archivePath, 'utf8'), 'sentinel');
});

test('本地打包拒绝将 App provenance 伪造成另一 commit', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-provenance-'));
  const fixture = await fixtureApp(parent);
  const signer = await fakeSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');
  const mismatchedCommit = fixture.sourceCommit.replace(/^[0-9a-f]/, fixture.sourceCommit[0] === 'a' ? 'b' : 'a');

  await assert.rejects(run(buildScript, [
    '--app', fixture.app, '--output-dir', output, '--channel', 'beta',
    '--source-commit', mismatchedCommit,
  ], {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
  }), /provenance|source.?commit|构建来源|来源 commit/i);
  assert.equal(await fileExists(output), false);
});

test('本地打包拒绝缺少构建 provenance 标记的预构建 App', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-missing-provenance-'));
  const fixture = await fixtureApp(parent);
  const signer = await fakeSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');
  const infoPath = join(fixture.app, 'Contents', 'Info.plist');
  const info = await readFile(infoPath, 'utf8');
  await writeFile(infoPath, info.replace(/<key>PaperRssSourceCommit<\/key><string>[^<]+<\/string>\n?/, ''));

  await assert.rejects(run(buildScript, [
    '--app', fixture.app, '--output-dir', output, '--channel', 'beta',
  ], {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
  }), /PaperRssSourceCommit|provenance|构建来源/i);
  assert.equal(await fileExists(output), false);
});

test('同版本并发打包只有一个进程能原子发布，且最终目录不嵌套 staging', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'paperrss-sparkle-concurrent-'));
  const fixture = await fixtureApp(parent);
  const signer = await fakeSigner(parent);
  const hdiutil = await fakeHdiutil(parent);
  const output = join(parent, 'output');
  const signerReady = join(parent, 'first-signer-ready');
  const signerContinue = join(parent, 'first-signer-continue');
  const secondarySigner = join(parent, 'secondary-signer-reached');
  const environment = {
    SPARKLE_SIGN_UPDATE: signer,
    SPARKLE_HDIUTIL: hdiutil,
    SPARKLE_TEST_PRIVATE_KEY: fixture.privateKeyPath,
    SPARKLE_TEST_SIGN_READY_FILE: signerReady,
    SPARKLE_TEST_SIGN_CONTINUE_FILE: signerContinue,
    SPARKLE_TEST_SIGN_SECONDARY_FILE: secondarySigner,
  };
  const args = ['--app', fixture.app, '--output-dir', output, '--channel', 'beta'];

  const first = run(buildScript, args, environment);
  await waitForFile(signerReady);
  const second = run(buildScript, args, environment);
  void second.catch(() => {});
  let results;
  try {
    await new Promise((resolve) => setTimeout(resolve, 1000));
    assert.equal(await fileExists(secondarySigner), false, '未持有版本锁的第二个进程不应进入签名阶段');
  } finally {
    await writeFile(signerContinue, 'continue');
    results = await Promise.allSettled([first, second]);
  }

  assert.equal(results.filter(({ status }) => status === 'fulfilled').length, 1);
  assert.equal(results.filter(({ status }) => status === 'rejected').length, 1);
  assert.deepEqual(await readdir(output), ['PaperRss-v9.8.7-beta.2']);
  const releaseEntries = await readdir(join(output, 'PaperRss-v9.8.7-beta.2'));
  assert.equal(releaseEntries.some((entry) => entry.includes('.staging.')), false);
  assert.deepEqual(releaseEntries.sort(), [
    'PaperRss-v9.8.7-beta.2.dmg',
    'PaperRss-v9.8.7-beta.2.zip',
    'manifest.json',
  ]);
});
