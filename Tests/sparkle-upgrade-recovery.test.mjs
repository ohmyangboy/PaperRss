import assert from 'node:assert/strict';
import test from 'node:test';

import {
  createSignedArchive,
  createUpgradeFixture,
  prepareLocalUpdate,
  startLocalHTTPSFixture,
} from './fixtures/local-upgrade-harness.mjs';

async function withFixture(callback) {
  const fixture = await createUpgradeFixture();
  try {
    await callback(fixture);
  } finally {
    await fixture.cleanup();
  }
}

test('本地 HTTPS 的 N 到 N+1 升级保留资料，并支持延后退出安装', async () => {
  await withFixture(async (fixture) => {
    const release = await createSignedArchive({
      appPath: fixture.nextAppPath,
      displayVersion: '2.0.0',
      build: '20',
    });
    const server = await startLocalHTTPSFixture({ release });
    try {
      const session = await prepareLocalUpdate({
        installRoot: fixture.installRoot,
        dataPath: fixture.dataPath,
        appcastURL: server.appcastURL,
        publicKey: release.publicKey,
        fallbackURL: 'https://github.com/example/PaperRss/releases',
      });

      assert.equal(session.status, 'ready');
      const deferred = await session.install({ when: 'deferred' });
      assert.equal(deferred.status, 'deferred');
      assert.equal(await fixture.runningVersion(), '1.0.0');

      const installed = await session.install({ when: 'quit' });
      assert.equal(installed.status, 'installed');
      assert.equal(installed.runningVersion, '2.0.0');
      assert.deepEqual(await fixture.readData(), fixture.initialData);
      assert.equal(await fixture.launchable(fixture.installRoot), true);
    } finally {
      await server.close();
    }
  });
});

test('立即安装复用已准备的归档，不要求重新下载', async () => {
  await withFixture(async (fixture) => {
    const release = await createSignedArchive({
      appPath: fixture.nextAppPath,
      displayVersion: '2.0.0',
      build: '20',
    });
    const server = await startLocalHTTPSFixture({ release });
    try {
      const session = await prepareLocalUpdate({
        installRoot: fixture.installRoot,
        dataPath: fixture.dataPath,
        appcastURL: server.appcastURL,
        publicKey: release.publicKey,
        fallbackURL: 'https://github.com/example/PaperRss/releases',
      });
      const archiveRequestsBeforeInstall = server.archiveRequests;
      const result = await session.install({ when: 'immediate' });

      assert.equal(result.status, 'installed');
      assert.equal(result.runningVersion, '2.0.0');
      assert.equal(server.archiveRequests, archiveRequestsBeforeInstall);
      assert.deepEqual(await fixture.readData(), fixture.initialData);
    } finally {
      await server.close();
    }
  });
});

test('中断下载失败后重新检查可以恢复，而不是卡在失败状态', async () => {
  await withFixture(async (fixture) => {
    const release = await createSignedArchive({
      appPath: fixture.nextAppPath,
      displayVersion: '2.0.0',
      build: '20',
    });
    const fallbackURL = 'https://github.com/example/PaperRss/releases';
    const interruptedServer = await startLocalHTTPSFixture({ release, failure: 'interrupted' });
    try {
      const failed = await prepareLocalUpdate({
        installRoot: fixture.installRoot,
        dataPath: fixture.dataPath,
        appcastURL: interruptedServer.appcastURL,
        publicKey: release.publicKey,
        fallbackURL,
      });
      assert.equal(failed.status, 'failed');
      assert.equal(failed.code, 'LENGTH_MISMATCH');
    } finally {
      await interruptedServer.close();
    }

    const healthyServer = await startLocalHTTPSFixture({ release });
    try {
      const retry = await prepareLocalUpdate({
        installRoot: fixture.installRoot,
        dataPath: fixture.dataPath,
        appcastURL: healthyServer.appcastURL,
        publicKey: release.publicKey,
        fallbackURL,
      });
      const installed = await retry.install({ when: 'immediate' });
      assert.equal(installed.status, 'installed');
      assert.equal(installed.runningVersion, '2.0.0');
      assert.deepEqual(await fixture.readData(), fixture.initialData);
    } finally {
      await healthyServer.close();
    }
  });
});

test('缺失资产、长度损坏和无效签名均 fail closed，并保留旧版本可启动', async () => {
  await withFixture(async (fixture) => {
    const release = await createSignedArchive({
      appPath: fixture.nextAppPath,
      displayVersion: '2.0.0',
      build: '20',
    });
    const fallbackURL = 'https://github.com/example/PaperRss/releases';

    for (const failure of ['missing-asset', 'interrupted', 'length-mismatch', 'invalid-signature']) {
      const server = await startLocalHTTPSFixture({ release, failure });
      try {
        const outcome = await prepareLocalUpdate({
          installRoot: fixture.installRoot,
          dataPath: fixture.dataPath,
          appcastURL: server.appcastURL,
          publicKey: release.publicKey,
          fallbackURL,
        }).catch((error) => error);

        assert.equal(outcome.status, 'failed');
        const expectedCode = failure === 'missing-asset'
          ? 'HTTP_404'
          : failure === 'invalid-signature'
            ? 'INVALID_SIGNATURE'
            : 'LENGTH_MISMATCH';
        assert.equal(outcome.code, expectedCode);
        assert.equal(outcome.fallbackURL, fallbackURL);
        assert.equal(await fixture.launchable(fixture.installRoot), true);
        assert.deepEqual(await fixture.readData(), fixture.initialData);
      } finally {
        await server.close();
      }
    }
  });
});

test('损坏 ZIP、版本元数据错误和安装失败提供可重试恢复结果', async () => {
  await withFixture(async (fixture) => {
    const release = await createSignedArchive({
      appPath: fixture.nextAppPath,
      displayVersion: '2.0.0',
      build: '20',
    });
    const fallbackURL = 'https://github.com/example/PaperRss/releases';

    for (const failure of ['corrupt-zip', 'version-mismatch']) {
      const server = await startLocalHTTPSFixture({ release, failure });
      try {
        const outcome = await prepareLocalUpdate({
          installRoot: fixture.installRoot,
          dataPath: fixture.dataPath,
          appcastURL: server.appcastURL,
          publicKey: release.publicKey,
          fallbackURL,
        }).catch((error) => error);
        assert.equal(outcome.status, 'failed');
        assert.equal(await fixture.launchable(fixture.installRoot), true);
        assert.deepEqual(await fixture.readData(), fixture.initialData);
      } finally {
        await server.close();
      }
    }

    const validServer = await startLocalHTTPSFixture({ release });
    try {
      const session = await prepareLocalUpdate({
        installRoot: fixture.installRoot,
        dataPath: fixture.dataPath,
        appcastURL: validServer.appcastURL,
        publicKey: release.publicKey,
        fallbackURL,
      });
      const outcome = await session.install({ when: 'quit', simulateFailure: true });
      assert.equal(outcome.status, 'failed');
      assert.equal(outcome.fallbackURL, fallbackURL);
      assert.equal(await fixture.launchable(fixture.installRoot), true);
      assert.deepEqual(await fixture.readData(), fixture.initialData);

      const retry = await prepareLocalUpdate({
        installRoot: fixture.installRoot,
        dataPath: fixture.dataPath,
        appcastURL: validServer.appcastURL,
        publicKey: release.publicKey,
        fallbackURL,
      });
      const recovered = await retry.install({ when: 'immediate' });
      assert.equal(recovered.status, 'installed');
      assert.equal(recovered.runningVersion, '2.0.0');
      assert.deepEqual(await fixture.readData(), fixture.initialData);
    } finally {
      await validServer.close();
    }
  });
});
