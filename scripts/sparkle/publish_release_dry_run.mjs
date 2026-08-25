#!/usr/bin/env node

/**
 * Fixture-only release publication planner.
 *
 * The command is intentionally incapable of remote mutation. It validates all
 * local assets, records the immutable publication order, and writes one local
 * appcast with exclusive-create semantics. A real release publisher must be a
 * separately authorized tool; adding --execute/--publish is rejected.
 */
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import {
  generateAppcast,
  validateManifest,
} from './appcast.mjs';

const fail = (message) => { throw new Error(`immutable release dry-run failed: ${message}`); };

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

const rejectRemoteFlags = (args) => {
  for (const flag of ['--execute', '--publish', '--remote', '--clobber']) {
    if (args.includes(flag)) fail(`${flag} is not allowed; this command is local dry-run only`);
  }
};

const readJSON = (path, fallback = {}) => {
  if (!path) return fallback;
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch (error) { fail(`cannot read ${path}: ${error.message}`); }
};

const readManifests = (paths, directory) => {
  const allPaths = paths.length > 0
    ? paths
    : directory
      ? readdirSync(directory).filter((name) => /^manifest(?:[-.].*)?\.json$/i.test(name)).sort().map((name) => join(directory, name))
      : [];
  if (allPaths.length === 0) fail('at least one --manifest or --manifest-dir is required');
  return allPaths.map((path) => {
    const absolute = resolve(path);
    try { return { ...readJSON(absolute), __path: absolute }; } catch (error) { fail(error.message); }
  });
};

const stateSet = (state, ...keys) => {
  const values = [];
  const collect = (value) => {
    if (typeof value === 'string') {
      values.push(value);
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(collect);
      return;
    }
    if (value && typeof value === 'object') {
      Object.entries(value).forEach(([key, nested]) => {
        values.push(key);
        collect(nested);
      });
    }
  };
  for (const key of keys) {
    collect(state[key]);
  }
  return new Set(values.filter(Boolean));
};

const validateDMG = (manifest, manifestRoot) => {
  for (const key of ['dmgFilename', 'dmgByteLength', 'dmgSha256']) {
    if (!(key in manifest)) fail(`manifest is missing ${key}; upload requires the complete DMG + ZIP asset set`);
  }
  if (basename(manifest.dmgFilename) !== manifest.dmgFilename) fail('DMG filename must be a plain filename');
  if (!Number.isInteger(manifest.dmgByteLength) || manifest.dmgByteLength <= 0) fail('invalid DMG byte length');
  if (!/^[a-f0-9]{64}$/i.test(manifest.dmgSha256)) fail('invalid DMG SHA-256');
  const path = resolve(manifestRoot, manifest.dmgFilename);
  if (!existsSync(path)) fail(`DMG asset is missing: ${path}`);
  const bytes = readFileSync(path);
  if (bytes.byteLength !== manifest.dmgByteLength) fail(`DMG length mismatch for ${manifest.dmgFilename}`);
  if (createHash('sha256').update(bytes).digest('hex') !== manifest.dmgSha256.toLowerCase()) {
    fail(`DMG SHA-256 mismatch for ${manifest.dmgFilename}`);
  }
  return { path, filename: manifest.dmgFilename };
};

const validateImmutableState = (state, tag, assets) => {
  const existingTags = stateSet(state, 'tags', 'existingTags', 'releases', 'existingReleases');
  if (existingTags.has(tag)) fail(`tag/release already exists: ${tag}; published releases are immutable`);
  const existingAssets = stateSet(state, 'assets', 'existingAssets', 'releaseAssets');
  for (const asset of assets) if (existingAssets.has(asset)) fail(`release asset already exists: ${asset}; --clobber is forbidden`);
};

const main = () => {
  const args = process.argv.slice(2);
  try {
    rejectRemoteFlags(args);
    const channel = option(args, '--channel');
    if (!['stable', 'beta'].includes(channel)) fail('channel must be stable or beta');
    const tag = option(args, '--tag');
    if (!/^v\d+(?:\.\d+){1,3}(?:-(?:alpha|beta|rc)\.\d+)?$/i.test(tag)) fail(`invalid release tag ${tag}`);
    const manifests = readManifests(option(args, '--manifest', { required: false, multiple: true }), option(args, '--manifest-dir', { required: false }));
    const outputDir = resolve(option(args, '--output-dir'));
    const state = readJSON(option(args, '--state', { required: false }));
    const publicKeyPath = option(args, '--public-key', { required: false });
    const tracePath = option(args, '--trace', { required: false });
    if (existsSync(outputDir) && !statSync(outputDir).isDirectory()) fail(`output path already exists and is not a directory: ${outputDir}`);

    const firstVersion = manifests[0].displayVersion;
    if (tag.toLowerCase() !== `v${String(firstVersion).toLowerCase()}`) fail(`tag ${tag} does not match manifest version ${firstVersion}`);
    if (channel === 'stable' && manifests.some((manifest) => /-(?:alpha|beta|rc)\.\d+$/i.test(String(manifest.displayVersion)))) {
      fail('stable release cannot contain prerelease assets');
    }
    const validated = manifests.map((manifest) => {
      const root = dirname(manifest.__path);
      const archive = validateManifest(manifest, { channel, assetRoot: root, publicKeyPath, requireAsset: true });
      const dmg = validateDMG(manifest, root);
      return { manifest, archive, dmg };
    });
    const assets = validated.flatMap(({ manifest }) => [manifest.filename, manifest.dmgFilename]);
    if (new Set(assets).size !== assets.length) fail('release assets must have unique filenames');
    validateImmutableState(state, tag, assets);

    const trace = [];
    const event = (step, details = {}) => trace.push({ step, remoteMutation: false, ...details });
    event('build-validate', { tag, channel, assets: [...assets] });
    event('draft-create', { tag });
    event('upload-all', { tag, assets: [...assets], clobber: false });
    event('publish-release', { tag });

    mkdirSync(outputDir, { recursive: true });
    const xml = generateAppcast(manifests, {
      channel,
      publicKeyPath,
    });
    const appcastPath = join(outputDir, `${channel}.xml`);
    if (existsSync(appcastPath)) fail(`appcast output already exists: ${appcastPath}; refusing overwrite`);
    writeFileSync(appcastPath, xml, { flag: 'wx' });
    event('publish-appcast', { channel, path: appcastPath });
    if (tracePath) writeFileSync(tracePath, `${JSON.stringify(trace, null, 2)}\n`, { flag: 'wx' });
    console.log(`dry-run complete: ${trace.map((item) => item.step).join(' -> ')}`);
    console.log(`local appcast: ${appcastPath}`);
  } catch (error) {
    console.error(`immutable release dry-run failed: ${error.message}`);
    process.exitCode = 1;
  }
};

if (import.meta.url === `file://${process.argv[1]}`) main();
