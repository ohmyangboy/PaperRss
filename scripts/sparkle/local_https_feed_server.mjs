#!/usr/bin/env node

/**
 * Local-only HTTPS server for the real Sparkle acceptance harness.
 *
 * It serves only stable.xml, beta.xml and files below <root>/releases. The
 * process never contacts the network and does not write outside the supplied
 * root or ready-file path.
 */
import { createServer } from 'node:https';
import { existsSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { basename, join, relative, resolve } from 'node:path';

const fail = (message) => {
  console.error(`local Sparkle HTTPS server failed: ${message}`);
  process.exit(2);
};

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

const args = process.argv.slice(2);
if (args.includes('--help') || args.includes('-h')) {
  console.log(`用法: local_https_feed_server.mjs --root <feed-root> --tls-key <key.pem> --tls-cert <cert.pem> --ready-file <ready.json> [--port <port>]`);
  process.exit(0);
}

const root = resolve(option(args, '--root'));
const tlsKey = resolve(option(args, '--tls-key'));
const tlsCert = resolve(option(args, '--tls-cert'));
const readyFile = resolve(option(args, '--ready-file'));
const host = option(args, '--bind', false) || '127.0.0.1';
const port = Number(option(args, '--port', false) || 0);
if (host !== '127.0.0.1') fail('bind address must remain 127.0.0.1');
if (!Number.isInteger(port) || port < 0 || port > 65535) fail('invalid port');
if (!existsSync(root) || !statSync(root).isDirectory()) fail(`feed root is not a directory: ${root}`);
if (!existsSync(tlsKey) || !existsSync(tlsCert)) fail('TLS key/certificate is missing');

const resolvedRoot = realpathSync(root);
const safeAssetPath = (pathname) => {
  if (!pathname.startsWith('/releases/')) return undefined;
  const encodedName = pathname.slice('/releases/'.length);
  if (!encodedName || encodedName.includes('/') || encodedName.includes('\\')) return undefined;
  let filename;
  try { filename = decodeURIComponent(encodedName); } catch { return undefined; }
  if (!filename || basename(filename) !== filename || filename.includes('\0')) return undefined;
  const path = resolve(resolvedRoot, 'releases', filename);
  const rel = relative(resolvedRoot, path);
  if (!rel || rel.startsWith('..') || rel.includes(`${requirePathSeparator()}..`)) return undefined;
  return path;
};

// Avoid importing platform-specific path separators into request handling.
const requirePathSeparator = () => process.platform === 'win32' ? '\\' : '/';

const response = (res, status, body, type = 'text/plain; charset=utf-8') => {
  res.writeHead(status, {
    'cache-control': 'no-store',
    'content-type': type,
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
};

const server = createServer({ key: readFileSync(tlsKey), cert: readFileSync(tlsCert) }, (req, res) => {
  let pathname;
  try { pathname = new URL(req.url || '/', `https://${host}`).pathname; } catch {
    response(res, 400, 'bad request');
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    response(res, 405, 'method not allowed');
    return;
  }
  let path;
  let type;
  if (pathname === '/stable.xml' || pathname === '/beta.xml') {
    path = join(resolvedRoot, pathname.slice(1));
    type = 'application/xml; charset=utf-8';
  } else {
    path = safeAssetPath(pathname);
    type = 'application/octet-stream';
  }
  if (!path || !existsSync(path) || !statSync(path).isFile()) {
    response(res, 404, 'not found');
    return;
  }
  const bytes = readFileSync(path);
  res.writeHead(200, {
    'cache-control': 'no-store',
    'content-type': type,
    'content-length': bytes.byteLength,
  });
  if (req.method === 'HEAD') res.end();
  else res.end(bytes);
});

const close = (signal) => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 2000).unref();
  if (signal) process.stdout.write(`LOCAL_FEED_STOPPING ${signal}\n`);
};
process.on('SIGTERM', () => close('SIGTERM'));
process.on('SIGINT', () => close('SIGINT'));

server.on('error', (error) => fail(error.message));
server.listen(port, host, () => {
  const actualPort = server.address().port;
  const baseURL = `https://${host}:${actualPort}`;
  const ready = {
    pid: process.pid,
    host,
    port: actualPort,
    baseURL,
    stableURL: `${baseURL}/stable.xml`,
    betaURL: `${baseURL}/beta.xml`,
    releasesURL: `${baseURL}/releases/`,
  };
  writeFileSync(readyFile, `${JSON.stringify(ready, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  console.log(`LOCAL_FEED_READY ${JSON.stringify(ready)}`);
});
