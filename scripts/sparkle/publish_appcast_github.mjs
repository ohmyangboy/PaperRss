#!/usr/bin/env node

/**
 * Audited GitHub Contents publisher for the two authoritative Sparkle feeds.
 *
 * This command only writes website/appcast/{stable,beta}.xml in an explicit
 * repository and branch. It validates before upload, reads the exact content
 * back through the GitHub API, compares bytes, and validates the readback.
 */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { validateAppcast } from './appcast.mjs';

const fail = (message) => { throw new Error(`appcast GitHub publish failed: ${message}`); };

const option = (args, name) => {
  const index = args.indexOf(name);
  if (index < 0) fail(`missing ${name}`);
  const value = args[index + 1];
  if (!value || value.startsWith('--')) fail(`${name} requires a value`);
  return value;
};

const gh = (args) => execFileSync('gh', args, {
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'pipe'],
}).trim();

const remoteFile = (endpoint, branch, { allowMissing = false } = {}) => {
  try {
    const response = JSON.parse(gh(['api', `${endpoint}?ref=${encodeURIComponent(branch)}`]));
    if (response.encoding !== 'base64' || typeof response.content !== 'string' || typeof response.sha !== 'string') {
      fail('GitHub readback response is missing base64 content or sha');
    }
    return {
      bytes: Buffer.from(response.content.replaceAll(/\s/g, ''), 'base64'),
      sha: response.sha,
    };
  } catch (error) {
    if (String(error.stderr || error.message).match(/404|not[ -]?found/i) && allowMissing) return null;
    throw error;
  }
};

const main = () => {
  const args = process.argv.slice(2);
  if (!args.includes('--execute')) fail('missing --execute; this publisher defaults to no remote mutation');
  const repo = option(args, '--repo');
  const branch = option(args, '--branch');
  const path = option(args, '--path');
  const channel = option(args, '--channel');
  const appcastPath = resolve(option(args, '--appcast'));
  const assetRoot = resolve(option(args, '--asset-root'));
  const publicKeyPath = resolve(option(args, '--public-key'));

  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) fail('invalid --repo');
  if (!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(branch) || branch.includes('..')) fail('invalid --branch');
  if (!['stable', 'beta'].includes(channel)) fail('channel must be stable or beta');
  const expectedPath = `website/appcast/${channel}.xml`;
  if (path !== expectedPath) fail(`--path must be ${expectedPath}`);

  const target = `${repo}:${branch}:${path}`;
  if (process.env.PAPERRSS_APPCAST_AUTHORIZED !== 'YES' ||
      process.env.PAPERRSS_APPCAST_CONFIRM !== `PUBLISH ${target}`) {
    fail(`authorization gate is incomplete for ${target}`);
  }

  const localBytes = readFileSync(appcastPath);
  validateAppcast(localBytes.toString('utf8'), { channel, assetRoot, publicKeyPath });

  const encodedPath = path.split('/').map(encodeURIComponent).join('/');
  const endpoint = `repos/${repo}/contents/${encodedPath}`;
  const existing = remoteFile(endpoint, branch, { allowMissing: true });
  if (!existing || !existing.bytes.equals(localBytes)) {
    const put = [
      'api', '--method', 'PUT', endpoint,
      '-f', `message=Publish PaperRss ${channel} appcast`,
      '-f', `content=${localBytes.toString('base64')}`,
      '-f', `branch=${branch}`,
    ];
    if (existing) put.push('-f', `sha=${existing.sha}`);
    gh(put);
  }

  const readback = remoteFile(endpoint, branch);
  if (!readback.bytes.equals(localBytes)) fail('GitHub API readback content does not match the local appcast');
  validateAppcast(readback.bytes.toString('utf8'), { channel, assetRoot, publicKeyPath });
  console.log(`appcast published and readback validated: ${target}`);
};

try {
  main();
} catch (error) {
  console.error(`appcast GitHub publish failed: ${error.message}`);
  process.exitCode = 1;
}
