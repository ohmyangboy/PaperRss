#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const defaultChangelogPath = fileURLToPath(new URL('../../CHANGELOG.md', import.meta.url));

export const extractChangelog = (path, version) => {
  const tag = String(version).startsWith('v') ? String(version) : `v${version}`;
  const text = readFileSync(path, 'utf8').replaceAll('\r\n', '\n');
  // 精确匹配二级标题的版本 token（允许输入带/不带 v），不依赖 Build/日期；
  // 包含标题，直到下一个 ## v 标题或 EOF，保留 --- 分隔的中英文整节。
  const headings = [...text.matchAll(/^## (v\S+)(?:[ \t].*)?$/gm)];
  const matches = headings.filter((heading) => heading[1] === tag);
  if (matches.length !== 1) {
    throw new Error(`CHANGELOG ${path}: expected one section for ${tag}, found ${matches.length}`);
  }
  const heading = matches[0];
  const next = headings[headings.indexOf(heading) + 1];
  const section = text.slice(heading.index, next?.index ?? text.length).trim();
  if (!section.slice(heading[0].length).trim()) throw new Error(`CHANGELOG ${path}: empty section for ${tag}`);
  return section;
};

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    if (process.argv.length !== 4) throw new Error('usage: changelog.mjs <CHANGELOG path> <version/tag>');
    process.stdout.write(extractChangelog(process.argv[2], process.argv[3]));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
