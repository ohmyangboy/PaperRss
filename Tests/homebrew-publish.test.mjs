import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateHomebrewManifest, updateCask, syncHomebrew } from '../scripts/sparkle/publish_homebrew.mjs';

const bytes = Buffer.from('已签名的 DMG 测试替身');
const repo = 'ohmyangboy/PaperRss';
const tag = 'v1.3.2';
const manifest = {
  displayVersion: '1.3.2', channel: 'stable', minimumMacOS: '14.0', architectures: ['arm64', 'x86_64'],
  dmgFilename: 'PaperRss-v1.3.2.dmg', dmgByteLength: bytes.length,
  dmgSha256: createHash('sha256').update(bytes).digest('hex'),
  downloadURL: `https://github.com/${repo}/releases/download/${tag}/PaperRss-${tag}.zip`,
};
const cask = (version, sha = 'a'.repeat(64)) => `cask "paperrss" do
  version "${version}"
  sha256 "${sha}"
  url "https://github.com/${repo}/releases/download/v#{version}/PaperRss-v#{version}.dmg"
  auto_updates true
  app "PaperRss.app"
end
`;

test('manifest 拒绝错误散列、预发布、仓库混用和系统/架构变化', () => {
  validateHomebrewManifest(manifest, tag, repo, bytes);
  for (const patch of [{ channel: 'beta' }, { displayVersion: '1.3.2-beta.1' },
    { dmgSha256: 'b'.repeat(64) }, { dmgByteLength: 1 }, { architectures: ['arm64'] },
    { minimumMacOS: '15.0' }, { downloadURL: 'https://example.com/app.zip' }]) {
    assert.throws(() => validateHomebrewManifest({ ...manifest, ...patch }, tag, repo, bytes));
  }
});

test('只修改版本与散列，拒绝倒退、同版本替换和 Cask 结构变化', () => {
  assert.equal(updateCask(cask('1.3.1'), manifest, repo), cask('1.3.2', manifest.dmgSha256));
  for (const value of [cask('1.3.3'), cask('1.3.2'), cask('1.3.1').replace('PaperRss-v', 'Other-v')]) {
    assert.throws(() => updateCask(value, manifest, repo));
  }
});

function remote({ prerelease = false, draft = false, badDownload = false, conflict = false, badReadback = false } = {}) {
  let content = cask('1.3.1');
  let writes = 0;
  const release = { tagName: tag, isDraft: draft, isPrerelease: prerelease,
    assets: [{ name: manifest.dmgFilename, url: manifest.downloadURL.replace(/\.zip$/, '.dmg') }] };
  const run = (args) => {
    if (args[0] === 'release') return JSON.stringify(release);
    if (args.includes('PUT')) {
      assert.ok(args.includes('sha=old-sha'));
      if (conflict) throw new Error('409 conflict');
      writes++;
      content = Buffer.from(args.find((v) => v.startsWith('content=')).slice(8), 'base64').toString();
      return '{}';
    }
    return JSON.stringify({ sha: 'old-sha', encoding: 'base64', content: Buffer.from(badReadback && writes ? '错误读回' : content).toString('base64') });
  };
  return { run, download: () => badDownload ? Buffer.from('损坏') : bytes, writes: () => writes };
}

test('成功同步可重复执行，读回一致时第二次不产生提交', () => {
  const state = remote();
  assert.equal(syncHomebrew({ manifest, tag, repo, ...state }), true);
  assert.equal(syncHomebrew({ manifest, tag, repo, ...state }), false);
  assert.equal(state.writes(), 1);
});

for (const mode of ['prerelease', 'draft', 'badDownload', 'conflict', 'badReadback']) {
  test(`远端异常必须报错：${mode}`, () => {
    const state = remote({ [mode]: true });
    assert.throws(() => syncHomebrew({ manifest, tag, repo, ...state }));
    assert.equal(state.writes(), mode === 'badReadback' ? 1 : 0);
  });
}

test('CLI 默认仅本地校验，未授权执行在访问 gh 前失败', () => {
  const dir = mkdtempSync(join(tmpdir(), 'homebrew-gates-'));
  try {
    const path = join(dir, 'manifest.json');
    writeFileSync(path, JSON.stringify(manifest));
    writeFileSync(join(dir, manifest.dmgFilename), bytes);
    const script = fileURLToPath(new URL('../scripts/sparkle/publish_homebrew.mjs', import.meta.url));
    const args = [script, '--manifest', path, '--tag', tag];
    const env = { ...process.env, PATH: dir, PAPERRSS_RELEASE_AUTHORIZED: '', PAPERRSS_RELEASE_CONFIRM: '' };
    const dry = spawnSync(process.execPath, args, { env, encoding: 'utf8' });
    assert.equal(dry.status, 0, dry.stderr);
    assert.match(dry.stdout, /未访问远端/);
    const denied = spawnSync(process.execPath, [...args, '--execute'], { env, encoding: 'utf8' });
    assert.equal(denied.status, 1);
    assert.match(denied.stderr, /授权门禁/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
