#!/usr/bin/env node

import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));
const version = manifest.version;
const packageName = manifest.name;
const isWindows = process.platform === 'win32';
const home = isWindows ? process.env.USERPROFILE || homedir() : process.env.HOME || homedir();
const configDir = process.env.CLAUDEX_CONFIG_DIR || join(home, '.config', 'claudex');
const binDir = process.env.CLAUDEX_BIN_DIR || join(home, '.local', 'bin');
const markerPath = join(configDir, 'package-manager.json');
const envPath = join(configDir, 'env');
const launcherPath = join(binDir, isWindows ? 'claudex.ps1' : 'claudex');

function fail(message, code = 1) {
  process.stderr.write(`claudex: ${message}\n`);
  process.exit(code);
}

function readMarker() {
  try {
    const marker = JSON.parse(readFileSync(markerPath, 'utf8'));
    return marker && typeof marker === 'object' ? marker : null;
  } catch {
    return null;
  }
}

function writeMarker() {
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  const temporary = `${markerPath}.tmp.${process.pid}`;
  const marker = {
    package: packageName,
    version,
    installedAt: new Date().toISOString(),
  };
  writeFileSync(temporary, `${JSON.stringify(marker, null, 2)}\n`, { mode: 0o600 });
  if (!isWindows) chmodSync(temporary, 0o600);
  renameSync(temporary, markerPath);
}

function run(command, args) {
  const result = spawnSync(command, args, {
    env: process.env,
    stdio: 'inherit',
    windowsHide: true,
  });
  if (result.error) fail(`could not start ${command}: ${result.error.message}`);
  if (result.signal) fail(`${command} was interrupted by ${result.signal}`, 130);
  return result.status ?? 1;
}

function runInstaller(login) {
  process.stderr.write(`claudex: preparing ${packageName} ${version}...\n`);
  let status;
  if (isWindows) {
    const args = [
      '-NoLogo',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      join(packageRoot, 'install.ps1'),
    ];
    if (login) args.push('-Login');
    status = run('powershell.exe', args);
  } else {
    const args = [join(packageRoot, 'install.sh')];
    if (login) args.push('--login');
    status = run('bash', args);
  }
  if (status !== 0) process.exit(status);
  writeMarker();
}

function needsSetup() {
  const marker = readMarker();
  return (
    !existsSync(envPath) ||
    !existsSync(launcherPath) ||
    marker?.package !== packageName ||
    marker?.version !== version
  );
}

const args = process.argv.slice(2);

if (args.length === 1 && args[0] === '--package-version') {
  process.stdout.write(`${version}\n`);
  process.exit(0);
}

if (args[0] === '--package-setup') {
  const setupArgs = args.slice(1);
  if (setupArgs.includes('--help') || setupArgs.includes('-h')) {
    process.stdout.write('Usage: claudex --package-setup [--login]\n');
    process.stdout.write('  --login  Open the official Codex login during setup.\n');
    process.exit(0);
  }
  if (setupArgs.some((argument) => argument !== '--login')) {
    fail('--package-setup accepts only --login', 2);
  }
  runInstaller(setupArgs.includes('--login'));
  process.stdout.write('Claudex package setup is complete. Run: claudex\n');
  process.exit(0);
}

if (needsSetup()) runInstaller(false);

let status;
if (isWindows) {
  status = run('powershell.exe', [
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    launcherPath,
    ...args,
  ]);
} else {
  status = run(launcherPath, args);
}
process.exit(status);
