import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const script = readFileSync(fileURLToPath(new URL('../website/install.sh', import.meta.url)), 'utf8');
const bundle = 'com.yangbukun.PaperRss';

// 用假 Apple 工具链测试安装事务，所有目标都在临时目录，绝不触碰真实应用。
function fixture(options, check) {
  const root = mkdtempSync(join(tmpdir(), 'paperrss-installer-test-'));
  const bin = join(root, 'bin');
  const apps = join(root, 'Applications');
  const target = join(apps, 'PaperRss.app');
  mkdirSync(bin); mkdirSync(apps);
  const fake = (name, body) => writeFileSync(join(bin, name), `#!${process.execPath}\n${body}`, { mode: 0o755 });
  const bytes = Buffer.from('fixture-archive');
  writeFileSync(join(root, 'app.zip'), bytes);
  writeFileSync(join(root, 'release.json'), JSON.stringify({ tag_name: 'v1.3.2', draft: false,
    prerelease: options.prerelease ?? false, assets: [{ name: 'PaperRss-v1.3.2.zip', size: bytes.length,
      digest: `sha256:${options.badHash ? 'a'.repeat(64) : createHash('sha256').update(bytes).digest('hex')}`,
      browser_download_url: 'https://github.com/ohmyangboy/PaperRss/releases/download/v1.3.2/PaperRss-v1.3.2.zip' }] }));
  if (options.oldVersion) {
    mkdirSync(join(target, 'Contents'), { recursive: true });
    writeFileSync(join(target, 'Contents/Info.plist'), JSON.stringify({ CFBundleIdentifier: bundle, CFBundleShortVersionString: options.oldVersion }));
    writeFileSync(join(target, 'old-data'), '旧应用');
  }
  if (options.lock) mkdirSync(join(apps, '.paperrss-install.lock'));
  fake('uname', 'console.log("Darwin")');
  fake('sw_vers', 'console.log("14.0")');
  fake('pgrep', `process.exit(${options.running ? 0 : 1})`);
  fake('codesign', `process.exit(${options.badSignature ? 1 : 0})`);
  fake('spctl', `process.exit(${options.badGatekeeper ? 1 : 0})`);
  fake('curl', `const fs=require('fs'),path=require('path'),a=process.argv.slice(2); const url=a.find(v=>v.startsWith('https://')); if(!url)process.exit(2); fs.copyFileSync(path.join(process.env.FIXTURE_ROOT,url.includes('/releases/latest')?'release.json':'app.zip'),a[a.indexOf('-o')+1]);`);
  fake('plutil', `const fs=require('fs'),a=process.argv.slice(2); try { const value=a[1].split('.').reduce((v,k)=>v[k],JSON.parse(fs.readFileSync(a.at(-1)))); if(value===undefined)process.exit(1); console.log(String(value)); } catch {process.exit(1);}`);
  fake('ditto', `const fs=require('fs'),path=require('path'),a=process.argv.slice(2); if(a[0]==='-x') {const dest=path.join(a.at(-1),'PaperRss.app/Contents');fs.mkdirSync(dest,{recursive:true});fs.writeFileSync(path.join(dest,'Info.plist'),JSON.stringify({CFBundleIdentifier:'${bundle}',CFBundleShortVersionString:'1.3.2'}));} else {fs.cpSync(a[0],a[1],{recursive:true});}`);
  fake('mv', `const a=process.argv.slice(2); if(process.env.FAIL_MOVE==='1' && a[0].includes('/.paperrss-install.') && a[0].endsWith('/PaperRss.app'))process.exit(1); const r=require('child_process').spawnSync('/bin/mv',a,{stdio:'inherit'});process.exit(r.status);`);
  try {
    const result = spawnSync('/bin/bash', ['-s', '--', '--app-dir', apps, ...(options.dryRun ? ['--dry-run'] : [])], {
      input: script, encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, FIXTURE_ROOT: root, FAIL_MOVE: options.failMove ? '1' : '0' },
    });
    check({ result, target, apps });
  } finally { rmSync(root, { recursive: true, force: true }); }
}

test('curl 管道首次安装与重复更新均可完成', () => {
  for (const oldVersion of [undefined, '1.3.1', '1.3.2']) {
    fixture({ oldVersion }, ({ result, target }) => {
      assert.equal(result.status, 0, result.stderr);
      assert.equal(JSON.parse(readFileSync(join(target, 'Contents/Info.plist'))).CFBundleShortVersionString, '1.3.2');
      assert.match(result.stdout, /已安装 1.3.2/);
    });
  }
});

test('dry-run 不安装、不替换已有应用', () => {
  fixture({ dryRun: true, oldVersion: '1.3.1' }, ({ result, target }) => {
    assert.equal(result.status, 0, result.stderr);
    assert.ok(existsSync(join(target, 'old-data')));
  });
});

for (const option of ['badHash', 'badSignature', 'badGatekeeper', 'prerelease', 'running', 'lock', 'failMove']) {
  test(`安装失败保留原应用：${option}`, () => {
    fixture({ [option]: true, oldVersion: '1.3.1' }, ({ result, target }) => {
      assert.notEqual(result.status, 0, result.stdout);
      assert.equal(readFileSync(join(target, 'old-data'), 'utf8'), '旧应用');
    });
  });
}

test('拒绝覆盖版本号更高的应用', () => {
  fixture({ oldVersion: '1.4.0-beta.1' }, ({ result, target }) => {
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /拒绝降级/);
    assert.ok(existsSync(join(target, 'old-data')));
  });
});
