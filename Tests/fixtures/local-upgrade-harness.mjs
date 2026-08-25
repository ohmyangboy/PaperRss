import { execFile as execFileCallback, spawn } from 'node:child_process';
import { createHash, generateKeyPairSync, sign, verify, createPublicKey } from 'node:crypto';
import { chmod, cp, mkdtemp, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { createServer, get } from 'node:https';
import { tmpdir } from 'node:os';
import { dirname, basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const fixtureApp = fileURLToPath(new URL('./fixture-app.mjs', import.meta.url));
const nodePath = process.execPath;

const initialData = {
  feeds: [{ id: 'feed-1', title: 'Example Feed', url: 'https://feeds.example.test/feed.xml' }],
  articles: [
    { id: 'article-1', feedID: 'feed-1', title: 'Saved article', content: 'Local content' },
    { id: 'article-2', feedID: 'feed-1', title: 'Starred article', content: 'More local content' },
  ],
  readArticleIDs: ['article-1'],
  starredArticleIDs: ['article-2'],
  accounts: [{ id: 'account-1', credentialRef: 'keychain://PaperRss/account-1' }],
  aiConfiguration: { provider: 'openai', model: 'gpt-4o-mini' },
  articleCache: { 'article-1': 'cached-rendered-content' },
};

function plist({ displayVersion, build }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PaperRss</string>
<key>CFBundleIdentifier</key><string>com.example.PaperRss</string>
<key>CFBundleName</key><string>PaperRss</string>
<key>CFBundleShortVersionString</key><string>${displayVersion}</string>
<key>CFBundleVersion</key><string>${build}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
`;
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

async function makeApp(parent, displayVersion, build) {
  const app = join(parent, 'PaperRss.app');
  const executable = join(app, 'Contents', 'MacOS', 'PaperRss');
  await mkdir(dirname(executable), { recursive: true });
  await writeFile(join(app, 'Contents', 'Info.plist'), plist({ displayVersion, build }));
  await writeFile(
    executable,
    `#!/bin/sh\nset -eu\nexec ${shellQuote(nodePath)} ${shellQuote(fixtureApp)} "$1" ${shellQuote(displayVersion)}\n`,
  );
  await chmod(executable, 0o755);
  return app;
}

async function readVersion(appPath) {
  const info = await readFile(join(appPath, 'Contents', 'Info.plist'), 'utf8');
  const displayVersion = info.match(/CFBundleShortVersionString<\/key><string>([^<]+)/)?.[1];
  const build = info.match(/CFBundleVersion<\/key><string>([^<]+)/)?.[1];
  if (!displayVersion || !build) throw failure('VERSION_METADATA_INVALID', '版本元数据缺失');
  return { displayVersion, build };
}

function failure(code, message, fallbackURL = undefined) {
  const error = new Error(message);
  error.code = code;
  if (fallbackURL) error.fallbackURL = fallbackURL;
  return error;
}

async function launch(appPath, dataPath) {
  return new Promise((resolveLaunch, rejectLaunch) => {
    const executable = join(appPath, 'Contents', 'MacOS', 'PaperRss');
    const child = spawn(executable, [dataPath], { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    let errorOutput = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        child.kill('SIGTERM');
        rejectLaunch(new Error('fixture app did not become ready'));
      }
    }, 3000);
    child.stdout.on('data', (chunk) => {
      output += chunk;
      if (!settled && output.includes('READY version=')) {
        settled = true;
        clearTimeout(timer);
        const version = output.match(/READY version=([^\n]+)/)?.[1];
        child.kill('SIGTERM');
        resolveLaunch(version);
      }
    });
    child.stderr.on('data', (chunk) => { errorOutput += chunk; });
    child.once('error', (error) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        rejectLaunch(error);
      }
    });
    child.once('exit', (code) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        rejectLaunch(new Error(errorOutput || `fixture app exited with ${code}`));
      }
    });
  });
}

export async function createUpgradeFixture() {
  const root = await mkdtemp(join(tmpdir(), 'paperrss-upgrade-fixture-'));
  const candidates = join(root, 'candidates');
  const installRoot = join(root, 'installed');
  const dataPath = join(root, 'library.json');
  await mkdir(candidates, { recursive: true });
  await mkdir(installRoot, { recursive: true });
  await writeFile(dataPath, `${JSON.stringify(initialData, null, 2)}\n`);

  const currentCandidate = await makeApp(join(candidates, 'current'), '1.0.0', '10');
  const nextAppPath = await makeApp(join(candidates, 'next'), '2.0.0', '20');
  await cp(currentCandidate, join(installRoot, 'PaperRss.app'), { recursive: true });

  return {
    root,
    installRoot,
    dataPath,
    nextAppPath,
    initialData: structuredClone(initialData),
    async readData() { return JSON.parse(await readFile(dataPath, 'utf8')); },
    async runningVersion() { return launch(join(installRoot, 'PaperRss.app'), dataPath); },
    async launchable(path) {
      try {
        await launch(join(path, 'PaperRss.app'), dataPath);
        return true;
      } catch {
        return false;
      }
    },
    async cleanup() { await rm(root, { recursive: true, force: true }); },
  };
}

export async function createSignedArchive({ appPath, displayVersion, build }) {
  const archiveDir = await mkdtemp(join(tmpdir(), 'paperrss-signed-archive-'));
  const archivePath = join(archiveDir, `PaperRss-v${displayVersion}.zip`);
  await execFile('zip', ['-qr', archivePath, basename(appPath)], { cwd: dirname(appPath) });
  const bytes = await readFile(archivePath);
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const signature = sign(null, bytes, privateKey).toString('base64');
  return {
    archivePath,
    bytes,
    filename: basename(archivePath),
    displayVersion,
    build,
    length: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    signature,
    publicKey: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    privateKey,
    async cleanup() { await rm(archiveDir, { recursive: true, force: true }); },
  };
}

async function createTLSMaterial() {
  const directory = await mkdtemp(join(tmpdir(), 'paperrss-local-https-'));
  const keyPath = join(directory, 'key.pem');
  const certPath = join(directory, 'cert.pem');
  await execFile('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-subj', '/CN=PaperRss local update fixture', '-keyout', keyPath, '-out', certPath,
  ], { stdio: 'ignore' });
  return { directory, key: await readFile(keyPath), cert: await readFile(certPath) };
}

function xmlAttribute(attributes, name) {
  return attributes.match(new RegExp(`${name.replace(':', '\\:')}="([^"]*)"`))?.[1];
}

export async function startLocalHTTPSFixture({ release, failure: failureMode } = {}) {
  const tlsMaterial = await createTLSMaterial();
  const server = createServer({ key: tlsMaterial.key, cert: tlsMaterial.cert });
  let archiveRequests = 0;
  const payload = () => {
    let bytes = release.bytes;
    let sha256 = release.sha256;
    let signature = release.signature;
    let build = release.build;
    if (failureMode === 'corrupt-zip') {
      bytes = Buffer.from('not a zip archive');
      sha256 = createHash('sha256').update(bytes).digest('hex');
      signature = sign(null, bytes, release.privateKey).toString('base64');
    } else if (failureMode === 'invalid-signature') {
      signature = Buffer.alloc(64, 3).toString('base64');
    } else if (failureMode === 'version-mismatch') {
      build = '999';
    }
    const length = failureMode === 'length-mismatch' ? release.length + 1 : bytes.length;
    return { bytes, sha256, signature, build, length };
  };

  server.on('request', (request, response) => {
    const pathname = new URL(request.url, 'https://localhost').pathname;
    if (pathname === '/stable.xml') {
      const current = payload();
      const assetURL = `https://127.0.0.1:${server.address().port}/releases/${release.filename}`;
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:paperrss="https://paperrss.example/paperrss">
<channel><item><title>PaperRss ${release.displayVersion}</title>
<sparkle:version>${current.build}</sparkle:version><sparkle:shortVersionString>${release.displayVersion}</sparkle:shortVersionString>
<enclosure url="${assetURL}" length="${current.length}" type="application/octet-stream" sparkle:edSignature="${current.signature}" paperrss:sha256="${current.sha256}" />
</item></channel></rss>`;
      response.writeHead(200, { 'content-type': 'application/xml' });
      response.end(xml);
      return;
    }
    if (pathname === `/releases/${release.filename}`) {
      archiveRequests += 1;
      if (failureMode === 'missing-asset') {
        response.writeHead(404);
        response.end('missing');
        return;
      }
      const current = payload();
      response.writeHead(200, { 'content-type': 'application/zip' });
      if (failureMode === 'interrupted') {
        response.end(current.bytes.subarray(0, Math.max(1, Math.floor(current.bytes.length / 2))));
        return;
      }
      response.end(current.bytes);
      return;
    }
    response.writeHead(404);
    response.end('not found');
  });
  await new Promise((resolveListen) => server.listen(0, '127.0.0.1', resolveListen));
  return {
    appcastURL: `https://127.0.0.1:${server.address().port}/stable.xml`,
    get archiveRequests() { return archiveRequests; },
    async close() {
      await new Promise((resolveClose) => server.close(resolveClose));
      await rm(tlsMaterial.directory, { recursive: true, force: true });
    },
  };
}

function request(url) {
  return new Promise((resolveRequest, rejectRequest) => {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:') {
      rejectRequest(failure('INSECURE_FEED', '更新源必须使用 HTTPS'));
      return;
    }
    if (parsed.hostname !== '127.0.0.1' && parsed.hostname !== 'localhost') {
      rejectRequest(failure('NON_LOCAL_FEED', '本地 harness 拒绝连接非回环更新源'));
      return;
    }
    const requestHandle = get(url, { rejectUnauthorized: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        const body = Buffer.concat(chunks);
        if (response.statusCode !== 200) {
          rejectRequest(failure(`HTTP_${response.statusCode}`, `更新资产请求失败（HTTP ${response.statusCode}）`));
        } else {
          resolveRequest(body);
        }
      });
    });
    requestHandle.on('error', rejectRequest);
  });
}

function parseAppcast(xml) {
  const enclosure = xml.match(/<enclosure\b([^>]+?)\/>/)?.[1];
  if (!enclosure) throw failure('APPCAST_INVALID', 'appcast 缺少归档 enclosure');
  const displayVersion = xml.match(/<sparkle:shortVersionString>([^<]+)/)?.[1];
  const build = xml.match(/<sparkle:version>([^<]+)/)?.[1];
  const url = xmlAttribute(enclosure, 'url');
  const length = Number(xmlAttribute(enclosure, 'length'));
  const signature = xmlAttribute(enclosure, 'sparkle:edSignature');
  const sha256 = xmlAttribute(enclosure, 'paperrss:sha256');
  if (!displayVersion || !build || !url || !Number.isInteger(length) || !signature || !sha256) {
    throw failure('APPCAST_INVALID', 'appcast 元数据不完整');
  }
  return { displayVersion, build, url, length, signature, sha256 };
}

async function verifyArchive({ archivePath, metadata, publicKey }) {
  const bytes = await readFile(archivePath);
  if (bytes.length !== metadata.length) throw failure('LENGTH_MISMATCH', '归档长度与 appcast 不一致');
  const digest = createHash('sha256').update(bytes).digest('hex');
  if (digest !== metadata.sha256) throw failure('CHECKSUM_MISMATCH', '归档校验和不匹配');
  const key = createPublicKey(publicKey);
  const validSignature = verify(null, bytes, key, Buffer.from(metadata.signature, 'base64'));
  if (!validSignature) throw failure('INVALID_SIGNATURE', 'Sparkle 签名无效');
  await execFile('unzip', ['-tq', archivePath]);
}

export async function prepareLocalUpdate({ installRoot, dataPath, appcastURL, publicKey, fallbackURL }) {
  let preparedRoot;
  try {
    const currentAppPath = join(installRoot, 'PaperRss.app');
    const currentVersion = await readVersion(currentAppPath);
    const xml = (await request(appcastURL)).toString('utf8');
    const metadata = parseAppcast(xml);
    const archiveBytes = await request(metadata.url);
    preparedRoot = await mkdtemp(join(tmpdir(), 'paperrss-prepared-update-'));
    const archivePath = join(preparedRoot, 'update.zip');
    await writeFile(archivePath, archiveBytes);
    await verifyArchive({ archivePath, metadata, publicKey });
    const stage = join(preparedRoot, 'stage');
    await mkdir(stage, { recursive: true });
    await execFile('unzip', ['-q', archivePath, '-d', stage]);
    const stagedAppPath = join(stage, 'PaperRss.app');
    const stagedVersion = await readVersion(stagedAppPath);
    if (stagedVersion.build !== metadata.build || stagedVersion.displayVersion !== metadata.displayVersion) {
      throw failure('VERSION_MISMATCH', '归档版本与 appcast 元数据不一致');
    }
    return {
      status: 'ready',
      currentVersion: currentVersion.displayVersion,
      releaseVersion: stagedVersion.displayVersion,
      async install({ when, simulateFailure = false }) {
        if (when === 'deferred') return { status: 'deferred', currentVersion: currentVersion.displayVersion };
        if (when !== 'immediate' && when !== 'quit') {
          throw new Error('install timing must be immediate, deferred, or quit');
        }
        const backupPath = join(installRoot, 'PaperRss.app.previous');
        try {
          await rm(backupPath, { recursive: true, force: true });
          await rename(currentAppPath, backupPath);
          if (simulateFailure) throw failure('INSTALL_FAILED', '模拟安装替换失败');
          await cp(stagedAppPath, currentAppPath, { recursive: true });
          const runningVersion = await launch(currentAppPath, dataPath);
          return { status: 'installed', runningVersion };
        } catch (error) {
          await rm(currentAppPath, { recursive: true, force: true });
          try { await rename(backupPath, currentAppPath); } catch { /* preserve original error */ }
          return {
            status: 'failed',
            code: error.code || 'INSTALL_FAILED',
            message: error.message,
            fallbackURL,
          };
        } finally {
          await rm(preparedRoot, { recursive: true, force: true });
        }
      },
    };
  } catch (error) {
    if (preparedRoot) await rm(preparedRoot, { recursive: true, force: true });
    return {
      status: 'failed',
      code: error.code || 'UPDATE_FAILED',
      message: error.message,
      fallbackURL,
    };
  }
}
