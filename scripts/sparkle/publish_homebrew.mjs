#!/usr/bin/env node

// 稳定版 Release 的 Homebrew 同步：默认只检查本地产物，远端写入复用发布授权。
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const TAP = 'ohmyangboy/homebrew-tap';
const ENDPOINT = `repos/${TAP}/contents/Casks/paperrss.rb`;
const fail = (message) => { throw new Error(message); };
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const gh = (args) => execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();

export function validateHomebrewManifest(manifest, tag, repo, bytes) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) fail('非法源仓库');
  if (!/^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(tag) ||
      tag !== `v${manifest.displayVersion}` || manifest.channel !== 'stable') fail('Homebrew 仅接受匹配 manifest 的稳定版 tag');
  if (manifest.dmgFilename !== `PaperRss-${tag}.dmg` ||
      manifest.downloadURL !== `https://github.com/${repo}/releases/download/${tag}/PaperRss-${tag}.zip`) fail('manifest 资产地址与发布仓库或 tag 不一致');
  if (!/^14\.0(?:\.0)?$/.test(manifest.minimumMacOS) ||
      !['arm64', 'x86_64'].every((arch) => manifest.architectures?.includes(arch))) fail('系统要求或架构已改变，请先调整 Cask');
  if (!/^[a-f0-9]{64}$/.test(manifest.dmgSha256) ||
      bytes.length !== manifest.dmgByteLength || hash(bytes) !== manifest.dmgSha256) fail('DMG 长度或 SHA-256 与 manifest 不一致');
}

export function updateCask(text, manifest, repo) {
  const versions = [...text.matchAll(/^  version "([^"]+)"$/gm)];
  const hashes = [...text.matchAll(/^  sha256 "([a-f0-9]{64})"$/gm)];
  if (!text.startsWith('cask "paperrss" do\n') || versions.length !== 1 || hashes.length !== 1 ||
      !text.includes(`  url "https://github.com/${repo}/releases/download/v#{version}/PaperRss-v#{version}.dmg"`)) fail('远程 Cask 结构或下载地址已改变，拒绝覆盖');
  const current = versions[0][1];
  if (!/^\d+\.\d+\.\d+$/.test(current)) fail('远程 Cask 版本格式不支持');
  const a = current.split('.').map(BigInt);
  const b = manifest.displayVersion.split('.').map(BigInt);
  const differing = a.findIndex((value, index) => value !== b[index]);
  if (differing >= 0 && a[differing] > b[differing]) fail('拒绝将 Homebrew 回退至旧版本');
  if (current === manifest.displayVersion && hashes[0][1] !== manifest.dmgSha256) fail('同版本 SHA-256 不同，拒绝替换不可变资产');
  return text.replace(versions[0][0], `  version "${manifest.displayVersion}"`)
    .replace(hashes[0][0], `  sha256 "${manifest.dmgSha256}"`);
}

export function syncHomebrew({ manifest, tag, repo, run = gh, download }) {
  const release = JSON.parse(run(['release', 'view', tag, '--repo', repo, '--json', 'isDraft,isPrerelease,tagName,assets']));
  const url = `https://github.com/${repo}/releases/download/${tag}/${manifest.dmgFilename}`;
  if (release.isDraft !== false || release.isPrerelease !== false || release.tagName !== tag ||
      !release.assets?.some((asset) => asset.name === manifest.dmgFilename && asset.url === url)) fail('远程 Release 尚未公开为稳定版或缺少预期 DMG');
  // 独立下载公开资产校验，不能只信任本地 manifest 或 GitHub 元数据。
  validateHomebrewManifest(manifest, tag, repo, download());
  const readRemote = () => {
    const file = JSON.parse(run(['api', `${ENDPOINT}?ref=main`]));
    if (file.encoding !== 'base64' || typeof file.content !== 'string' || !file.sha) fail('远端 Cask 缺少内容或 SHA');
    return { sha: file.sha, text: Buffer.from(file.content, 'base64').toString('utf8') };
  };
  const existing = readRemote();
  const next = updateCask(existing.text, manifest, repo);
  if (next !== existing.text) {
    run(['api', '--method', 'PUT', ENDPOINT, '-f', `message=更新 PaperRss 至 ${tag}`,
      '-f', 'branch=main', '-f', `sha=${existing.sha}`, '-f', `content=${Buffer.from(next).toString('base64')}`]);
  }
  if (readRemote().text !== next) fail('Homebrew 远端读回内容不匹配');
  return next !== existing.text;
}

function main() {
  const { values } = parseArgs({ options: {
    manifest: { type: 'string' }, tag: { type: 'string' }, repo: { type: 'string', default: 'ohmyangboy/PaperRss' },
    execute: { type: 'boolean', default: false },
  } });
  if (!values.manifest || !values.tag) fail('需要 --manifest 和 --tag');
  const path = resolve(values.manifest);
  const manifest = JSON.parse(readFileSync(path, 'utf8'));
  // 在任何远端操作前验证本地文件名，避免读入 manifest 所指的任意路径。
  if (manifest.dmgFilename !== `PaperRss-${values.tag}.dmg` || !/^v[0-9.]+$/.test(values.tag)) fail('非法 DMG 文件名或稳定版 tag');
  validateHomebrewManifest(manifest, values.tag, values.repo, readFileSync(join(dirname(path), manifest.dmgFilename)));
  if (!values.execute) {
    console.log(`Homebrew dry-run 校验通过：${values.tag} -> ${TAP}:main:Casks/paperrss.rb；未访问远端。`);
    return;
  }
  if (process.env.PAPERRSS_RELEASE_AUTHORIZED !== 'YES' || process.env.PAPERRSS_RELEASE_CONFIRM !== `PUBLISH ${values.tag}`) fail('Homebrew 同步需要完整 Release 授权门禁');
  const changed = syncHomebrew({ manifest, tag: values.tag, repo: values.repo, download() {
    const dir = mkdtempSync(join(tmpdir(), 'paperrss-homebrew-'));
    try {
      gh(['release', 'download', values.tag, '--repo', values.repo, '--pattern', manifest.dmgFilename, '--dir', dir]);
      return readFileSync(join(dir, manifest.dmgFilename));
    } finally { rmSync(dir, { recursive: true, force: true }); }
  } });
  console.log(`Homebrew ${changed ? '已同步' : '版本已一致，无需提交'}，远端读回校验通过：${values.tag}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) {
    console.error(`Homebrew 同步失败：${error.message}`);
    process.exitCode = 1;
  }
}
