import { readFile } from 'node:fs/promises';

const [dataPath, version] = process.argv.slice(2);

if (!dataPath || !version) {
  process.stderr.write('fixture app requires data path and version\n');
  process.exit(2);
}

try {
  const data = JSON.parse(await readFile(dataPath, 'utf8'));
  if (!Array.isArray(data.feeds) || !Array.isArray(data.articles)) {
    throw new Error('library data is not readable');
  }
  process.stdout.write(`READY version=${version}\n`);
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(3);
}

setInterval(() => {}, 1000);
