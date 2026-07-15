#!/usr/bin/env node

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const requiredFiles = [
  'README.md',
  'LICENSE',
  'NOTICE.md',
  'CHANGELOG.md',
  'CODE_OF_CONDUCT.md',
  'CONTRIBUTING.md',
  'GOVERNANCE.md',
  'SECURITY.md',
  'SUPPORT.md',
  '.github/ISSUE_TEMPLATE/bug_report.yml',
  '.github/ISSUE_TEMPLATE/feature_request.yml',
  '.github/ISSUE_TEMPLATE/config.yml',
  '.github/pull_request_template.md',
];

const failures = [];

for (const file of requiredFiles) {
  if (!existsSync(join(root, file))) failures.push(`missing required file: ${file}`);
}

for (const file of [
  '.github/ISSUE_TEMPLATE/bug_report.yml',
  '.github/ISSUE_TEMPLATE/feature_request.yml',
]) {
  const path = join(root, file);
  if (!existsSync(path)) continue;
  const source = readFileSync(path, 'utf8');
  for (const key of ['name', 'description', 'body']) {
    if (!new RegExp(`^${key}:`, 'm').test(source)) {
      failures.push(`${file} is missing top-level ${key}`);
    }
  }
}

function collectMarkdown(directory) {
  const files = [];
  for (const entry of readdirSync(directory)) {
    if (entry === '.git' || entry === 'node_modules') continue;
    const path = join(directory, entry);
    if (statSync(path).isDirectory()) files.push(...collectMarkdown(path));
    else if (entry.endsWith('.md')) files.push(path);
  }
  return files;
}

function cleanTarget(rawTarget) {
  let target = rawTarget.trim();
  if (target.startsWith('<') && target.endsWith('>')) target = target.slice(1, -1);
  const titleStart = target.match(/\s+["']/);
  if (titleStart) target = target.slice(0, titleStart.index);
  return target.split('#', 1)[0].split('?', 1)[0];
}

for (const path of collectMarkdown(root)) {
  const source = readFileSync(path, 'utf8');
  const relativePath = relative(root, path);
  const linkPattern = /!?\[[^\]]*\]\(([^)]+)\)/g;
  for (const match of source.matchAll(linkPattern)) {
    const rawTarget = match[1];
    if (/^(?:https?:|mailto:|#)/i.test(rawTarget.trim())) continue;
    const target = cleanTarget(rawTarget);
    if (!target) continue;
    let decoded;
    try {
      decoded = decodeURIComponent(target);
    } catch {
      failures.push(`${relativePath} has an invalid encoded link: ${rawTarget}`);
      continue;
    }
    const destination = resolve(dirname(path), decoded);
    const repositoryRelativePath = relative(root, destination);
    const insideRepository =
      repositoryRelativePath === '' ||
      (!repositoryRelativePath.startsWith(`..${sep}`) &&
        repositoryRelativePath !== '..' &&
        !isAbsolute(repositoryRelativePath));
    if (!insideRepository || !existsSync(destination)) {
      failures.push(`${relativePath} has a broken relative link: ${rawTarget}`);
    }
  }
}

const readme = readFileSync(join(root, 'README.md'), 'utf8');
if (/private portable backup/i.test(readme)) {
  failures.push('README still describes Claudex as a private backup');
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log('community and documentation checks passed');
