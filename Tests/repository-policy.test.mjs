import assert from 'node:assert/strict';
import { access, lstat, readFile, readdir } from 'node:fs/promises';
import { basename, dirname, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));

const fromRoot = (path) => resolve(root, path);
const readRepoFile = (path) => readFile(fromRoot(path), 'utf8');

async function markdownFiles(path) {
  const absolutePath = fromRoot(path);
  const stat = await lstat(absolutePath);
  if (stat.isFile()) return [absolutePath];

  const entries = await readdir(absolutePath, { withFileTypes: true });
  const nested = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory() || entry.name.endsWith('.md'))
      .map((entry) => markdownFiles(`${path}/${entry.name}`)),
  );
  return nested.flat();
}

test('all agents share one lightweight entry and exactly one principle document', async () => {
  const [agents, claude, principles, ruleFiles] = await Promise.all([
    readRepoFile('AGENTS.md'),
    readRepoFile('CLAUDE.md'),
    readRepoFile('.agents/rules/principle.md'),
    readdir(fromRoot('.agents/rules')),
  ]);

  const expectedPointer = '开始任何工作前，完整读取并遵循 [`.agents/rules/principle.md`](.agents/rules/principle.md)。';
  assert.equal(agents.trim(), expectedPointer);
  assert.equal(claude.trim(), expectedPointer);
  assert.deepEqual(ruleFiles.sort(), ['principle.md']);
  await assert.rejects(access(fromRoot('.agents/README.md')), { code: 'ENOENT' });
  assert.match(principles, /^---\ntrigger: always_on\n---/);
  assert.ok(principles.trim().length > 0);
  assert.match(
    principles,
    /\[Matt 开发工作流\]\(\.\.\/docs\/development-workflow\.md\)/,
  );
  for (const trigger of ['triage', 'research', 'to-spec', 'to-tickets', 'implement']) {
    assert.match(principles, new RegExp(`\\b${trigger}\\b`));
  }
  assert.doesNotMatch(
    principles,
    /engineering_standards|verification_workflow|privacy_and_docs_hygiene|prompt_design_language|DIRECTORY_SPEC/,
  );
});

test('repository layout keeps source, knowledge, local work, and generated output separate', async () => {
  const requiredPaths = [
    'PaperRss/Sources/Core',
    'PaperRss/Sources/App',
    'PaperRss/Resources',
    'Tests',
    'website',
    'assets',
    'scripts',
    'docs/README.md',
    'docs/drafts',
    'docs/research',
    'docs/features',
    'docs/technical',
    'docs/audits',
    '.agents/rules',
    '.agents/docs',
  ];

  await Promise.all(requiredPaths.map((path) => access(fromRoot(path))));
  for (const retiredPath of [
    'docs/specs',
    'docs/drafts/implemented',
    '.out-of-scope',
  ]) {
    await assert.rejects(access(fromRoot(retiredPath)), { code: 'ENOENT' });
  }

  const gitignore = await readRepoFile('.gitignore');
  for (const ignored of ['.scratch/', '.build/', 'build/', 'dist/']) {
    assert.match(gitignore, new RegExp(`^${ignored.replace('.', '\\.')}$$`, 'm'));
  }
});

test('public drafts contain only accepted issue-linked specifications', async () => {
  const draftFiles = (await markdownFiles('docs/drafts')).filter(
    (file) => basename(file) !== 'README.md',
  );

  for (const file of draftFiles) {
    assert.match(
      basename(file),
      /^issue-\d+-[a-z0-9]+(?:-[a-z0-9]+)*\.md$/,
      `${file} must use the issue-N-slug naming convention`,
    );

    const markdown = await readFile(file, 'utf8');
    assert.match(markdown, /^\s*- \*\*Status\*\*:\s*`?accepted`?\s*$/m);
    assert.match(markdown, /https:\/\/github\.com\/ohmyangboy\/PaperRss\/issues\/\d+/);
  }

  const index = await readRepoFile('docs/drafts/README.md');
  assert.match(index, /issue-<N>-<slug>\.md/);
  assert.match(index, /`- \*\*Status\*\*: accepted`/);
  assert.doesNotMatch(index, /Status:\s*draft|docs\/drafts\/implemented/);
});

test('governance markdown uses portable links that resolve inside the repository', async () => {
  const files = [
    fromRoot('AGENTS.md'),
    fromRoot('CLAUDE.md'),
    ...(await markdownFiles('.agents')),
    ...(await markdownFiles('docs')),
  ];

  for (const file of files) {
    const markdown = await readFile(file, 'utf8');
    assert.doesNotMatch(markdown, /\]\(file:\/\//, `${file} contains a file URL link`);

    const links = markdown.matchAll(/\[[^\]]*\]\(([^)]+)\)/g);
    for (const [, rawTarget] of links) {
      if (/^(https?:|mailto:|#)/.test(rawTarget)) continue;
      const target = decodeURIComponent(rawTarget.split('#')[0].split('?')[0]);
      if (!target) continue;
      await access(resolve(dirname(file), target));
    }
  }
});

test('test and deployment configuration follow the documented source roots', async () => {
  const [packageFile, pagesWorkflow] = await Promise.all([
    readRepoFile('Package.swift'),
    readRepoFile('.github/workflows/deploy-pages.yml'),
  ]);

  assert.match(packageFile, /"repository-policy\.test\.mjs"/);
  assert.match(pagesWorkflow, /path:\s*'website'/);
  assert.doesNotMatch(pagesWorkflow, /path:\s*'docs'/);
});

test('agent assets do not contain absolute user-directory symlinks', async () => {
  const entries = await readdir(fromRoot('.agents'), { recursive: true });

  for (const entry of entries) {
    const stat = await lstat(fromRoot(`.agents/${entry}`));
    if (stat.isSymbolicLink()) {
      assert.fail(`.agents/${entry} must be a portable repository file, not a symlink`);
    }
  }
});

test('release script generates version-focused notes without repetitive marketing copy', async () => {
  const releaseScript = await readRepoFile('scripts/release.sh');
  const publishScript = await readRepoFile('scripts/sparkle/publish_release.sh');

  assert.doesNotMatch(
    releaseScript,
    /原生 macOS 三栏布局 RSS 阅读器/,
    'scripts/release.sh must not contain hardcoded marketing slogans',
  );
  assert.doesNotMatch(
    releaseScript,
    /集成 DeepSeek \/ OpenAI 兼容 API/,
    'scripts/release.sh must not contain hardcoded marketing slogans',
  );
  assert.match(
    publishScript,
    /--notes-file|--title/,
    'publish chain must support custom release notes/title flags',
  );
  assert.match(
    releaseScript,
    /publish_release\.sh/,
    'release.sh publish 子命令必须委托受审计的发布编排器（默认 dry-run）',
  );
});

test('update pipeline keeps Sparkle as the single authority and bans legacy update paths', async () => {
  const sources = ['PaperRss/Sources/App', 'PaperRss/Sources/AppUpdateSupport'];
  for (const dir of sources) {
    const entries = [];
    async function walk(p) {
      for (const e of await readdir(fromRoot(p), { withFileTypes: true })) {
        const rel = `${p}/${e.name}`;
        if (e.isDirectory()) await walk(rel);
        else if (e.name.endsWith('.swift')) entries.push({ rel, text: await readRepoFile(rel) });
      }
    }
    await walk(dir);
    assert.ok(entries.length > 0);

    for (const { rel, text } of entries) {
      assert.doesNotMatch(
        text,
        /SPUStandardUpdaterController|SPUStandardUserDriver/,
        `${rel} 禁止绑定 Sparkle 标准 UI（ADR-0001：唯一入口是左下角胶囊）`,
      );
      assert.doesNotMatch(text, /UpdateCheckService/, `${rel} 旧 GitHub 检查器已由 Sparkle 取代`);
      assert.doesNotMatch(text, /ignoredVersion|ignoreVersion\(/, `${rel} 不允许永久忽略版本`);
      assert.doesNotMatch(text, /ScheduledUpdateReminder/, `${rel} 右上角通知条形态已被否决`);
    }
  }

  // 胶囊是唯一入口：RootView 只挂载一次
  const rootView = await readRepoFile('PaperRss/Sources/App/RootView.swift');
  assert.match(rootView, /UpdateCapsule\(/);
  assert.equal((rootView.match(/UpdateCapsule\(/g) || []).length, 1);

  // 生产 Info.plist 不允许硬编码 feed/公钥（构建期注入，缺键 fail-closed）
  for (const plist of ['PaperRss/Resources/macOS-Info.plist', 'PaperRss/Resources/iOS-Info.plist']) {
    const text = await readRepoFile(plist);
    assert.doesNotMatch(text, /SUFeedURL|SUBetaFeedURL|SUPublicEDKey/, `${plist} 更新配置必须构建期注入`);
  }

  // Package.swift 锁定 Sparkle 版本并排除 node 契约测试
  const packageSwift = await readRepoFile('Package.swift');
  assert.match(packageSwift, /sparkle-project\/Sparkle\.git", exact: "2\.\d+\.\d+"/);
  for (const t of ['sparkle-release.test.mjs','sparkle-release-gates.test.mjs','sparkle-publish-dry-run.test.mjs']) {
    assert.match(packageSwift, new RegExp(`"${t.replace(/\./g,'\\.')}"`));
  }

  // 凭据文件不入库
  const gitignore = await readRepoFile('.gitignore');
  assert.match(gitignore, /release\.env/);
});
