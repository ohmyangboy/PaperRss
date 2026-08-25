#!/usr/bin/env node

/**
 * Stable/Beta Sparkle appcast contract.
 *
 * This module deliberately only reads local manifests/assets and writes a local
 * appcast. It never fetches a URL and never invokes gh, git, or a signing tool.
 */
import { createHash, createPublicKey, verify as verifySignature } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';

const fail = (message) => { throw new Error(`appcast contract failed: ${message}`); };

const option = (args, name, { required = true, multiple = false } = {}) => {
  const values = [];
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] !== name) continue;
    const value = args[index + 1];
    if (!value || value.startsWith('--')) fail(`${name} requires a value`);
    values.push(value);
    index += 1;
  }
  if (required && values.length === 0) fail(`missing ${name}`);
  return multiple ? values : values[0];
};

const isPrerelease = (version) => /-(?:alpha|beta|rc)\.\d+$/i.test(String(version));

const xmlEscape = (value) => String(value)
  .replaceAll('&', '&amp;')
  .replaceAll('"', '&quot;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;');

const readManifest = (path) => {
  let manifest;
  try { manifest = JSON.parse(readFileSync(path, 'utf8')); } catch (error) {
    fail(`cannot read manifest ${path}: ${error.message}`);
  }
  return { ...manifest, __path: resolve(path) };
};

const readPublicKey = (path) => {
  const bytes = readFileSync(path);
  try {
    return createPublicKey(bytes);
  } catch {
    // Sparkle stores the raw 32-byte Ed25519 public key in Info.plist. Accept
    // that canonical base64 form as well as PEM/DER fixtures used by tests.
    const encoded = bytes.toString('utf8').trim();
    if (!/^[A-Za-z0-9+/]{43}=$/.test(encoded)) {
      fail(`invalid public key: ${path}`);
    }
    const raw = Buffer.from(encoded, 'base64');
    if (raw.length !== 32 || raw.toString('base64') !== encoded) {
      fail(`invalid public key: ${path}`);
    }
    try {
      const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
      return createPublicKey({
        key: Buffer.concat([spkiPrefix, raw]),
        format: 'der',
        type: 'spki',
      });
    } catch (error) {
      fail(`invalid public key: ${error.message}`);
    }
  }
};

const archivePath = (manifest, root = dirname(manifest.__path)) => {
  if (!manifest.filename || basename(manifest.filename) !== manifest.filename) {
    fail('manifest filename must be a plain filename');
  }
  return resolve(root, manifest.filename);
};

export const validateManifest = (manifest, { channel, assetRoot, publicKeyPath, requireAsset = true } = {}) => {
  for (const key of ['displayVersion', 'build', 'channel', 'filename', 'byteLength', 'sha256',
    'edSignature', 'minimumMacOS', 'downloadURL']) {
    if (!(key in manifest)) fail(`manifest is missing ${key}`);
  }
  if (!['stable', 'beta'].includes(manifest.channel)) fail(`invalid manifest channel ${manifest.channel}`);
  if (channel && !['stable', 'beta'].includes(channel)) fail(`invalid channel ${channel}`);
  if (!/^\d+(?:\.\d+){1,3}(?:-(?:alpha|beta|rc)\.\d+)?$/i.test(manifest.displayVersion)) {
    fail(`invalid display version ${manifest.displayVersion}`);
  }
  if (!/^\d+$/.test(String(manifest.build)) || Number(manifest.build) <= 0) fail(`invalid build ${manifest.build}`);
  if (!/^\d+(?:\.\d+){1,2}$/.test(String(manifest.minimumMacOS))) fail(`invalid minimum macOS ${manifest.minimumMacOS}`);
  if (manifest.channel === 'stable' && isPrerelease(manifest.displayVersion)) fail('stable manifest cannot carry a prerelease');
  let url;
  try { url = new URL(manifest.downloadURL); } catch { fail(`invalid downloadURL ${manifest.downloadURL}`); }
  if (url.protocol !== 'https:' || decodeURIComponent(url.pathname.split('/').pop()) !== manifest.filename) {
    fail('downloadURL must be HTTPS and point at the ZIP filename');
  }
  if (!Number.isInteger(manifest.byteLength) || manifest.byteLength <= 0) fail('invalid ZIP byte length');
  if (!/^[a-f0-9]{64}$/i.test(manifest.sha256)) fail('invalid ZIP SHA-256');
  let signature;
  try { signature = Buffer.from(manifest.edSignature, 'base64'); } catch { fail('invalid EdDSA signature'); }
  if (signature.length !== 64 || signature.toString('base64') !== manifest.edSignature) fail('invalid EdDSA signature');

  const path = archivePath(manifest, assetRoot || dirname(manifest.__path));
  if (requireAsset) {
    if (!existsSync(path)) fail(`ZIP asset is missing: ${path}`);
    const bytes = readFileSync(path);
    if (bytes.byteLength !== manifest.byteLength) fail(`ZIP length mismatch for ${manifest.filename}`);
    if (createHash('sha256').update(bytes).digest('hex') !== manifest.sha256.toLowerCase()) {
      fail(`ZIP SHA-256 mismatch for ${manifest.filename}`);
    }
    if (publicKeyPath) {
      let key;
      try { key = readPublicKey(publicKeyPath); } catch (error) { fail(`invalid public key: ${error.message}`); }
      if (!verifySignature(null, bytes, key, signature)) fail(`EdDSA signature mismatch for ${manifest.filename}`);
    }
  }
  return { ...manifest, buildNumber: Number(manifest.build), assetPath: path };
};

const orderedManifests = (manifests, options) => {
  // Stable deliberately ignores beta/rc inputs before validating their
  // signatures: a stable feed must not depend on a prerelease signing key.
  const candidates = options.channel === 'stable'
    ? manifests.filter((manifest) => !isPrerelease(manifest.displayVersion))
    : manifests;
  const selected = candidates.map((manifest) => validateManifest(manifest, options));
  let previous = 0;
  const seen = new Set();
  for (const manifest of selected) {
    if (seen.has(manifest.buildNumber)) fail(`duplicate build ${manifest.build}`);
    if (manifest.buildNumber <= previous) fail(`build order is not monotonic at ${manifest.build}`);
    seen.add(manifest.buildNumber);
    previous = manifest.buildNumber;
  }
  if (selected.length === 0) fail(`no ${options.channel} releases remain after filtering`);
  return selected;
};

export const generateAppcast = (manifests, { channel, assetRoot, publicKeyPath } = {}) => {
  if (!['stable', 'beta'].includes(channel)) fail('channel must be stable or beta');
  const selected = orderedManifests(manifests, { channel, assetRoot, publicKeyPath, requireAsset: true });
  const items = selected.map((manifest) => `    <item>
      <title>PaperRss ${xmlEscape(manifest.displayVersion)}</title>
      <sparkle:version>${xmlEscape(manifest.build)}</sparkle:version>
      <sparkle:shortVersionString>${xmlEscape(manifest.displayVersion)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${xmlEscape(manifest.minimumMacOS)}</sparkle:minimumSystemVersion>
      <enclosure url="${xmlEscape(manifest.downloadURL)}" length="${manifest.byteLength}" type="application/octet-stream" sparkle:edSignature="${xmlEscape(manifest.edSignature)}" paperrss:sha256="${manifest.sha256}" sparkle:minimumSystemVersion="${xmlEscape(manifest.minimumMacOS)}" />
    </item>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:paperrss="https://paperrss.example/paperrss">
  <channel>
    <title>PaperRss ${channel === 'stable' ? 'Stable' : 'Beta'}</title>
    <link>https://github.com/ohmyangboy/PaperRss/releases</link>
    <description>PaperRss ${channel} updates</description>
${items}
  </channel>
</rss>
`;
};

const attribute = (text, name) => text.match(new RegExp(`${name.replace(':', '\\:')}="([^"]*)"`))?.[1];

export const validateAppcast = (xml, { channel, assetRoot, publicKeyPath } = {}) => {
  if (!xml.includes('<rss') || !xml.includes('<channel>')) fail('appcast XML is incomplete');
  const itemTexts = [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((match) => match[1]);
  if (itemTexts.length === 0) fail('appcast has no items');
  let previous = 0;
  for (const item of itemTexts) {
    const version = item.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1];
    const build = item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1];
    const minimumMacOS = item.match(/<sparkle:minimumSystemVersion>([^<]+)<\/sparkle:minimumSystemVersion>/)?.[1]
      || item.match(/sparkle:minimumSystemVersion="([^"]+)"/)?.[1];
    const enclosure = item.match(/<enclosure\b([^>]+?)\/>/)?.[1];
    if (!version || !build || !minimumMacOS || !enclosure) fail('appcast item metadata is incomplete');
    if (channel === 'stable' && isPrerelease(version)) fail('stable appcast contains a prerelease');
    const buildNumber = Number(build);
    if (!/^\d+$/.test(build) || !Number.isInteger(buildNumber) || buildNumber <= previous) fail('appcast build order is not monotonic');
    previous = buildNumber;
    let url;
    try { url = new URL(attribute(enclosure, 'url') || ''); } catch { fail('appcast enclosure URL is invalid'); }
    if (url.protocol !== 'https:') fail('appcast enclosure URL must use HTTPS');
    const length = Number(attribute(enclosure, 'length'));
    const signatureText = attribute(enclosure, 'sparkle:edSignature');
    const sha256 = attribute(enclosure, 'paperrss:sha256');
    if (!Number.isInteger(length) || length <= 0) fail('appcast enclosure length is invalid');
    let signature;
    try { signature = Buffer.from(signatureText || '', 'base64'); } catch { fail('appcast signature is invalid'); }
    if (signature.length !== 64 || signature.toString('base64') !== signatureText) fail('appcast signature is invalid');
    if (!/^[a-f0-9]{64}$/i.test(sha256 || '')) fail('appcast SHA-256 is invalid');
    if (assetRoot) {
      const localPath = resolve(assetRoot, decodeURIComponent(url.pathname.split('/').pop() || ''));
      if (!existsSync(localPath)) fail(`appcast asset is not accessible: ${localPath}`);
      const bytes = readFileSync(localPath);
      if (bytes.byteLength !== length) fail('appcast asset length does not match');
      if (createHash('sha256').update(bytes).digest('hex') !== sha256.toLowerCase()) fail('appcast asset SHA-256 does not match');
      if (publicKeyPath && !verifySignature(null, bytes, readPublicKey(publicKeyPath), signature)) {
        fail('appcast EdDSA signature does not match');
      }
    }
  }
  return { channel, itemCount: itemTexts.length, highestBuild: previous };
};

const parseArgs = (args) => ({
  action: args[0],
  channel: option(args, '--channel'),
  manifests: option(args, '--manifest', { required: false, multiple: true }),
  appcast: option(args, '--appcast', { required: false }),
  output: option(args, '--output', { required: false }),
  assetRoot: option(args, '--asset-root', { required: false }),
  publicKeyPath: option(args, '--public-key', { required: false }),
});

const main = () => {
  try {
    const parsed = parseArgs(process.argv.slice(2));
    if (parsed.action === 'generate') {
      if (!parsed.output) fail('missing --output');
      const xml = generateAppcast(parsed.manifests.map(readManifest), parsed);
      writeFileSync(parsed.output, xml, { flag: 'wx' });
      validateAppcast(xml, parsed);
      console.log(`generated ${parsed.channel} appcast (local-only)`);
      return;
    }
    if (parsed.action === 'validate') {
      if (!parsed.appcast) fail('missing --appcast');
      const result = validateAppcast(readFileSync(parsed.appcast, 'utf8'), parsed);
      console.log(`validated ${parsed.channel} appcast (${result.itemCount} items, highest build ${result.highestBuild})`);
      return;
    }
    fail('usage: appcast.mjs <generate|validate> --channel <stable|beta> ...');
  } catch (error) {
    console.error(`appcast contract failed: ${error.message}`);
    process.exitCode = 1;
  }
};

if (import.meta.url === `file://${process.argv[1]}`) main();
