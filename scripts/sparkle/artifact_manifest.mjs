#!/usr/bin/env node

import { createHash, createPublicKey, verify as verifySignature } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, basename, dirname, resolve } from 'node:path';

const fail = (message) => {
  console.error(`sparkle artifact validation failed: ${message}`);
  process.exit(1);
};

const tool = (name, fallback) => process.env[name] || fallback;

const option = (args, name, required = true) => {
  const index = args.indexOf(name);
  if (index < 0) {
    if (required) fail(`missing ${name}`);
    return undefined;
  }
  const value = args[index + 1];
  if (!value || value.startsWith('--')) fail(`${name} requires a value`);
  return value;
};

const plistValue = (plist, key) => {
  try {
    return execFileSync('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', plist], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch {
    fail(`Info.plist is missing ${key}`);
  }
};

const executableArchitectures = (app) => {
  const info = join(app, 'Contents', 'Info.plist');
  const executable = plistValue(info, 'CFBundleExecutable');
  const executablePath = join(app, 'Contents', 'MacOS', executable);
  let output;
  try {
    output = execFileSync('/usr/bin/lipo', ['-archs', executablePath], { encoding: 'utf8' }).trim();
  } catch {
    fail(`cannot read architectures from ${executablePath}`);
  }
  if (!output) fail(`no architectures found in ${executablePath}`);
  return [...new Set(output.split(/\s+/).map((arch) => arch === 'arm64e' ? 'arm64' : arch))]
    .sort((left, right) => left.localeCompare(right));
};

const sha256 = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
const byteLength = (path) => readFileSync(path).byteLength;

const publicKeyFromPlist = (plist) => {
  const encoded = plistValue(plist, 'SUPublicEDKey');
  let raw;
  try { raw = Buffer.from(encoded, 'base64'); } catch { fail('SUPublicEDKey is not valid base64'); }
  if (raw.length !== 32 || raw.toString('base64') !== encoded) {
    fail('SUPublicEDKey must be the canonical base64 encoding of a 32-byte Ed25519 key');
  }
  try {
    // Sparkle stores the raw Ed25519 public key. Node's crypto API consumes
    // the equivalent RFC 8410 SubjectPublicKeyInfo wrapper.
    const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
    return createPublicKey({
      key: Buffer.concat([spkiPrefix, raw]),
      format: 'der',
      type: 'spki',
    });
  } catch (error) {
    fail(`invalid SUPublicEDKey: ${error.message}`);
  }
};

const sourceCommitFromPlist = (plist) => {
  const sourceCommit = plistValue(plist, 'PaperRssSourceCommit');
  if (!/^[a-f0-9]{40}$/.test(sourceCommit)) {
    fail('PaperRssSourceCommit must be a lowercase 40-character commit SHA');
  }
  return sourceCommit;
};

const zipEntries = (zip) => {
  try {
    execFileSync('/usr/bin/unzip', ['-tqq', zip], { stdio: ['ignore', 'pipe', 'pipe'] });
    return execFileSync('/usr/bin/unzip', ['-Z1', zip], { encoding: 'utf8' })
      .split(/\r?\n/).filter(Boolean);
  } catch {
    fail(`ZIP is missing, unreadable, or corrupt: ${zip}`);
  }
};

const appRootFromEntries = (entries) => {
  const roots = [...new Set(entries
    .map((entry) => entry.split('/')[0])
    .filter((entry) => entry.endsWith('.app')))].sort();
  if (roots.length !== 1) fail(`ZIP must contain exactly one top-level .app (found ${roots.length})`);
  if (entries.some((entry) => entry.split('/')[0] !== roots[0])) {
    fail('ZIP contains files outside its single top-level .app');
  }
  // Frameworks such as Sparkle legitimately embed signed helper apps (for
  // example Contents/Frameworks/Sparkle.framework/.../Updater.app). The
  // archive boundary is the single top-level app; everything below it is part
  // of that bundle and is covered by the ZIP signature.
  return roots[0];
};

const inspectZipApp = (zip, manifest) => {
  const entries = zipEntries(zip);
  const root = appRootFromEntries(entries);
  const temp = mkdtempSync(join(tmpdir(), 'paperrss-sparkle-zip-'));
  try {
    execFileSync('/usr/bin/unzip', ['-q', zip, '-d', temp]);
    const app = join(temp, root);
    const info = join(app, 'Contents', 'Info.plist');
    const values = {
      displayVersion: plistValue(info, 'CFBundleShortVersionString'),
      build: plistValue(info, 'CFBundleVersion'),
      minimumMacOS: plistValue(info, 'LSMinimumSystemVersion'),
      sourceCommit: sourceCommitFromPlist(info),
    };
    const publicKey = publicKeyFromPlist(info);
    const architectures = executableArchitectures(app);
    for (const key of ['displayVersion', 'build', 'minimumMacOS', 'sourceCommit']) {
      if (values[key] !== manifest[key]) fail(`ZIP ${key} does not match manifest`);
    }
    if (JSON.stringify(architectures) !== JSON.stringify(manifest.architectures)) {
      fail('ZIP architectures do not match manifest');
    }
    const signature = Buffer.from(manifest.edSignature, 'base64');
    if (!verifySignature(null, readFileSync(zip), publicKey, signature)) {
      fail('ZIP EdDSA signature does not match the SUPublicEDKey embedded in the app');
    }
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
};

const inspectDmg = (dmg) => {
  try {
    execFileSync(tool('SPARKLE_HDIUTIL', '/usr/bin/hdiutil'), ['imageinfo', dmg], { stdio: ['ignore', 'pipe', 'pipe'] });
  } catch {
    fail(`DMG is missing, unreadable, or corrupt: ${dmg}`);
  }
};

const validateCommon = (manifest) => {
  const required = ['displayVersion', 'build', 'channel', 'filename', 'byteLength', 'sha256',
    'edSignature', 'minimumMacOS', 'architectures', 'downloadURL', 'dmgFilename', 'dmgByteLength', 'dmgSha256',
    'sourceCommit'];
  for (const key of required) if (!(key in manifest)) fail(`manifest is missing ${key}`);
  if (!['stable', 'beta'].includes(manifest.channel)) fail(`invalid channel ${manifest.channel}`);
  if (!/^\d+(?:\.\d+){1,3}(?:-(?:alpha|beta|rc)\.\d+)?$/.test(manifest.displayVersion)) {
    fail(`invalid display version ${manifest.displayVersion}`);
  }
  if (!/^\d+$/.test(String(manifest.build))) fail(`invalid build ${manifest.build}`);
  if (!/^[a-f0-9]{40}$/.test(manifest.sourceCommit)) fail('invalid source commit');
  if (!/^\d+(?:\.\d+){1,2}$/.test(manifest.minimumMacOS)) fail(`invalid minimum macOS ${manifest.minimumMacOS}`);
  if (manifest.channel === 'stable' && /-(?:alpha|beta|rc)\./.test(manifest.displayVersion)) {
    fail('stable artifact cannot carry a prerelease display version');
  }
  for (const key of ['filename', 'dmgFilename']) {
    if (basename(manifest[key]) !== manifest[key] || !manifest[key]) fail(`${key} must be a filename`);
  }
  let downloadURL;
  try { downloadURL = new URL(manifest.downloadURL); } catch { fail('invalid downloadURL'); }
  if (downloadURL.protocol !== 'https:' || decodeURIComponent(downloadURL.pathname.split('/').pop()) !== manifest.filename) {
    fail('downloadURL must be HTTPS and point at the ZIP filename');
  }
  if (!Number.isInteger(manifest.byteLength) || manifest.byteLength <= 0) fail('invalid ZIP byte length');
  if (!Number.isInteger(manifest.dmgByteLength) || manifest.dmgByteLength <= 0) fail('invalid DMG byte length');
  if (!/^[a-f0-9]{64}$/.test(manifest.sha256) || !/^[a-f0-9]{64}$/.test(manifest.dmgSha256)) {
    fail('invalid SHA-256 digest');
  }
  let decoded;
  try { decoded = Buffer.from(manifest.edSignature, 'base64'); } catch { fail('invalid EdDSA signature'); }
  if (decoded.length !== 64 || decoded.toString('base64') !== manifest.edSignature) fail('invalid EdDSA signature');
  if (!Array.isArray(manifest.architectures) || manifest.architectures.length === 0 ||
      manifest.architectures.some((arch) => typeof arch !== 'string' || !/^[A-Za-z0-9_]+$/.test(arch))) {
    fail('invalid architectures');
  }
};

const validate = (manifestPath, requiredArchitectures = []) => {
  let manifest;
  try { manifest = JSON.parse(readFileSync(manifestPath, 'utf8')); } catch { fail(`cannot read manifest ${manifestPath}`); }
  validateCommon(manifest);
  const root = dirname(resolve(manifestPath));
  const zip = join(root, manifest.filename);
  const dmg = join(root, manifest.dmgFilename);
  try { readFileSync(zip); } catch { fail(`ZIP is missing: ${zip}`); }
  try { readFileSync(dmg); } catch { fail(`DMG is missing: ${dmg}`); }
  if (byteLength(zip) !== manifest.byteLength || sha256(zip) !== manifest.sha256) fail('ZIP length or SHA-256 mismatch');
  if (byteLength(dmg) !== manifest.dmgByteLength || sha256(dmg) !== manifest.dmgSha256) fail('DMG length or SHA-256 mismatch');
  inspectZipApp(zip, manifest);
  inspectDmg(dmg);
  for (const architecture of requiredArchitectures) {
    if (!manifest.architectures.includes(architecture)) fail(`required architecture ${architecture} is absent`);
  }
  console.log(`validated ${manifest.filename} and ${manifest.dmgFilename}`);
};

const create = (args) => {
  const app = resolve(option(args, '--app'));
  const zip = resolve(option(args, '--zip'));
  const dmg = resolve(option(args, '--dmg'));
  const manifestPath = resolve(option(args, '--manifest'));
  const channel = option(args, '--channel');
  const signature = option(args, '--signature');
  const downloadURL = option(args, '--download-url');
  const signedLength = Number(option(args, '--signed-length'));
  const sourceCommit = option(args, '--source-commit').toLowerCase();
  if (!app.endsWith('.app')) fail('invalid app input');
  const info = join(app, 'Contents', 'Info.plist');
  try { readFileSync(info); } catch { fail('invalid app input'); }
  const appSourceCommit = sourceCommitFromPlist(info);
  if (appSourceCommit !== sourceCommit) {
    fail('app PaperRssSourceCommit does not match --source-commit');
  }
  validateCommon({
    displayVersion: plistValue(info, 'CFBundleShortVersionString'),
    build: plistValue(info, 'CFBundleVersion'),
    channel,
    filename: basename(zip),
    byteLength: byteLength(zip),
    sha256: sha256(zip),
    edSignature: signature,
    minimumMacOS: plistValue(info, 'LSMinimumSystemVersion'),
    architectures: executableArchitectures(app),
    downloadURL,
    dmgFilename: basename(dmg),
    dmgByteLength: byteLength(dmg),
    dmgSha256: sha256(dmg),
    sourceCommit,
  });
  if (signedLength !== byteLength(zip)) fail('sign_update length does not match ZIP');
  const manifest = {
    displayVersion: plistValue(info, 'CFBundleShortVersionString'),
    build: plistValue(info, 'CFBundleVersion'),
    channel,
    filename: basename(zip),
    byteLength: byteLength(zip),
    sha256: sha256(zip),
    edSignature: signature,
    minimumMacOS: plistValue(info, 'LSMinimumSystemVersion'),
    architectures: executableArchitectures(app),
    downloadURL,
    dmgFilename: basename(dmg),
    dmgByteLength: byteLength(dmg),
    dmgSha256: sha256(dmg),
    sourceCommit,
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 });
};

const args = process.argv.slice(2);
if (args[0] === 'create') create(args.slice(1));
else if (args[0] === 'validate') {
  const required = option(args, '--require-architectures', false);
  validate(option(args, '--manifest'), required ? required.split(',').filter(Boolean) : []);
} else fail('usage: artifact_manifest.mjs <create|validate> ...');
