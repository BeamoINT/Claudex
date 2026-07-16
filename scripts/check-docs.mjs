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
  'MAINTAINERS.md',
  'ROADMAP.md',
  'SECURITY.md',
  'SUPPORT.md',
  '.github/ISSUE_TEMPLATE/bug_report.yml',
  '.github/ISSUE_TEMPLATE/feature_request.yml',
  '.github/ISSUE_TEMPLATE/documentation.yml',
  '.github/ISSUE_TEMPLATE/config.yml',
  '.github/pull_request_template.md',
  '.github/CODEOWNERS',
  '.github/dependabot.yml',
  '.github/labeler.yml',
  '.github/workflows/codeql.yml',
  '.github/workflows/dependency-review.yml',
  '.github/workflows/labeler.yml',
  '.github/workflows/release-assets.yml',
  '.github/workflows/test.yml',
  '.github/workflows/verify-installers.yml',
];

const failures = [];

for (const file of requiredFiles) {
  if (!existsSync(join(root, file))) failures.push(`missing required file: ${file}`);
}

for (const file of [
  '.github/ISSUE_TEMPLATE/bug_report.yml',
  '.github/ISSUE_TEMPLATE/feature_request.yml',
  '.github/ISSUE_TEMPLATE/documentation.yml',
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

for (const file of readdirSync(join(root, '.github/workflows'))
  .filter((entry) => entry.endsWith('.yml'))
  .sort()) {
  const relativePath = `.github/workflows/${file}`;
  const source = readFileSync(join(root, relativePath), 'utf8');
  for (const match of source.matchAll(/^\s*-?\s*uses:\s*[^@\s]+@([^\s#]+)/gm)) {
    if (!/^[0-9a-f]{40}$/.test(match[1])) {
      failures.push(`${relativePath} has an action that is not pinned to a full commit SHA: ${match[0].trim()}`);
    }
  }
  if (/^\s*pull_request_target:/m.test(source)) {
    if (/uses:\s*actions\/checkout@/.test(source)) {
      failures.push(`${relativePath} checks out untrusted code from pull_request_target`);
    }
    if (/^\s*(?:-\s*)?run:/m.test(source)) {
      failures.push(`${relativePath} executes shell code from pull_request_target`);
    }
  }
}

const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const changelog = readFileSync(join(root, 'CHANGELOG.md'), 'utf8');
if (!changelog.includes(`## [${manifest.version}] - `)) {
  failures.push(`CHANGELOG is missing package version ${manifest.version}`);
}

const releaseHeadings = [...changelog.matchAll(/^## \[((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\] - \d{4}-\d{2}-\d{2}\s*$/gm)]
  .map((match) => match[1]);
const releaseLinks = new Map();
for (const match of changelog.matchAll(/^\[([^\]]+)\]:\s+(\S+)\s*$/gm)) {
  if (releaseLinks.has(match[1])) failures.push(`CHANGELOG has duplicate link definition: ${match[1]}`);
  releaseLinks.set(match[1], match[2]);
}

const uniqueReleaseHeadings = new Set(releaseHeadings);
if (uniqueReleaseHeadings.size !== releaseHeadings.length) {
  failures.push('CHANGELOG has duplicate released version headings');
}
if (releaseHeadings.length === 0) {
  failures.push('CHANGELOG has no released version headings');
} else {
  const compareVersions = (left, right) => {
    const leftParts = left.split('.').map(Number);
    const rightParts = right.split('.').map(Number);
    for (let index = 0; index < 3; index += 1) {
      if (leftParts[index] !== rightParts[index]) return leftParts[index] - rightParts[index];
    }
    return 0;
  };

  for (let index = 1; index < releaseHeadings.length; index += 1) {
    if (compareVersions(releaseHeadings[index - 1], releaseHeadings[index]) <= 0) {
      failures.push('CHANGELOG released version headings are not in descending SemVer order');
      break;
    }
  }

  const latestVersion = releaseHeadings[0];
  if (latestVersion !== manifest.version) {
    failures.push(`CHANGELOG latest released version ${latestVersion} does not match package version ${manifest.version}`);
  }
  const expectedUnreleased = `https://github.com/BeamoINT/Claudex/compare/v${latestVersion}...HEAD`;
  if (releaseLinks.get('Unreleased') !== expectedUnreleased) {
    failures.push(`CHANGELOG Unreleased link must compare v${latestVersion} to HEAD`);
  }

  for (let index = 0; index < releaseHeadings.length; index += 1) {
    const version = releaseHeadings[index];
    const previousVersion = releaseHeadings[index + 1];
    const expected = previousVersion
      ? `https://github.com/BeamoINT/Claudex/compare/v${previousVersion}...v${version}`
      : `https://github.com/BeamoINT/Claudex/releases/tag/v${version}`;
    if (releaseLinks.get(version) !== expected) {
      failures.push(`CHANGELOG link for ${version} must be ${expected}`);
    }
  }

  for (const label of releaseLinks.keys()) {
    if (/^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/.test(label) && !uniqueReleaseHeadings.has(label)) {
      failures.push(`CHANGELOG has a released version link without a heading: ${label}`);
    }
  }
}

function collectMarkdown(directory) {
  const files = [];
  for (const entry of readdirSync(directory)) {
    // dist/ is a generated release staging tree. It can coexist with a source
    // checkout after artifact verification and must not be treated as another
    // repository root when resolving relative documentation links.
    if (entry === '.git' || entry === 'node_modules' || (directory === root && entry === 'dist')) continue;
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

function proseSegments(source, relativePath) {
  const segments = [];
  let fenced = false;
  let frontmatter = /(?:^|\/)SKILL(?:\.windows)?\.md$/.test(relativePath);
  for (const [index, line] of source.split('\n').entries()) {
    if (frontmatter) {
      if (index > 0 && /^---\s*$/.test(line)) frontmatter = false;
      continue;
    }
    if (/^\s*```/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    const parts = line.split(/(`[^`\n]*`|\]\([^\n)]*\)|https?:\/\/[^\s)>]+)/g);
    for (let partIndex = 0; partIndex < parts.length; partIndex += 2) {
      segments.push({ line: index + 1, text: parts[partIndex] });
    }
  }
  return segments;
}

for (const path of collectMarkdown(root)) {
  const source = readFileSync(path, 'utf8');
  const relativePath = relative(root, path).split(sep).join('/');
  for (const segment of proseSegments(source, relativePath)) {
    if (/[—–‑‒―]/.test(segment.text)) {
      failures.push(`${relativePath}:${segment.line} contains a long dash in prose`);
    }
    const compound = segment.text.match(/\b[A-Za-z][A-Za-z']*-[A-Za-z][A-Za-z']*\b/);
    if (compound) {
      failures.push(`${relativePath}:${segment.line} contains a hyphenated prose word: ${compound[0]}`);
    }
  }
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
