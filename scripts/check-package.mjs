#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

assert.equal(manifest.name, 'claudex-codex');
assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
assert.equal(manifest.license, 'MIT');
assert.equal(manifest.bin?.claudex, 'bin/claudex-package.mjs');
assert.equal(manifest.publishConfig?.access, 'public');

const versionResult = spawnSync(
  process.execPath,
  [join(root, 'bin', 'claudex-package.mjs'), '--package-version'],
  { encoding: 'utf8' },
);
assert.equal(versionResult.status, 0, versionResult.stderr);
assert.equal(versionResult.stdout.trim(), manifest.version);

const packResult = process.platform === 'win32'
  ? spawnSync(
      process.env.ComSpec || 'cmd.exe',
      ['/d', '/s', '/c', 'npm pack --dry-run --json --ignore-scripts'],
      { cwd: root, encoding: 'utf8' },
    )
  : spawnSync(
      'npm',
      ['pack', '--dry-run', '--json', '--ignore-scripts'],
      { cwd: root, encoding: 'utf8' },
    );
assert.equal(packResult.status, 0, packResult.error?.stack || packResult.stderr);
const packReport = JSON.parse(packResult.stdout);
assert.equal(packReport.length, 1);
const paths = new Set(packReport[0].files.map((file) => file.path));

for (const required of [
  'LICENSE',
  'README.md',
  'bin/claudex-package.mjs',
  'claudex-package.cmd',
  'install.sh',
  'install.ps1',
  'claudex',
  'claudex.ps1',
  'skills/usage-limit/SKILL.md',
]) {
  assert(paths.has(required), `npm package is missing ${required}`);
}

for (const path of paths) {
  assert(!/(^|\/)(?:auth\.json|history\.jsonl|cliproxyapi\.yaml)$/i.test(path), `private file included: ${path}`);
  assert(!/(^|\/)(?:\.env|env)$/i.test(path), `environment file included: ${path}`);
  assert(!/(^|\/)(?:node_modules|dist|coverage|\.claude|\.codex)(\/|$)/i.test(path), `generated state included: ${path}`);
}

assert(packReport[0].unpackedSize < 2_000_000, 'npm package unexpectedly exceeds 2 MB unpacked');
console.log(`npm package checks passed (${packReport[0].files.length} files)`);
