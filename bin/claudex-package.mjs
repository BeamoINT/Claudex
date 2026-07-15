#!/usr/bin/env node

import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { constants as osConstants, homedir } from 'node:os';
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
const requestedBinDir = process.env.CLAUDEX_BIN_DIR || join(home, '.local', 'bin');
const markerPath = join(configDir, 'package-manager.json');
const setupLockPath = join(configDir, 'package-setup.lock');
const envPath = join(configDir, 'env');
const packageEntrypoint = fileURLToPath(import.meta.url);

function sameFile(left, right) {
  try {
    return realpathSync(left) === realpathSync(right);
  } catch {
    return false;
  }
}

// Never let the bootstrap installer replace the package manager's own command
// shim when an npm/Homebrew/Scoop bin directory is supplied as CLAUDEX_BIN_DIR.
const requestedLauncher = join(requestedBinDir, isWindows ? 'claudex.ps1' : 'claudex');
const binDir = sameFile(requestedLauncher, packageEntrypoint)
  ? join(configDir, 'package-bin')
  : requestedBinDir;
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

const setupWait = new Int32Array(new SharedArrayBuffer(4));
function sleep(milliseconds) {
  Atomics.wait(setupWait, 0, 0, milliseconds);
}

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === 'EPERM';
  }
}

function readSetupOwner() {
  try {
    return JSON.parse(readFileSync(join(setupLockPath, 'owner.json'), 'utf8'));
  } catch {
    return null;
  }
}

function acquireSetupLock(force) {
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    try {
      mkdirSync(setupLockPath, { mode: 0o700 });
      writeFileSync(
        join(setupLockPath, 'owner.json'),
        `${JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() })}\n`,
        { mode: 0o600 },
      );
      return true;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
    }

    const owner = readSetupOwner();
    let age = 0;
    try { age = Date.now() - statSync(setupLockPath).mtimeMs; } catch { continue; }
    // A setup process can die immediately after mkdir, before owner.json is
    // durable. Give that handoff a short grace, then recover a lock that has no
    // live owner instead of making every future launch wait the full 2 minutes.
    if (age >= 2_000 && !processIsAlive(Number(owner?.pid))) {
      const quarantine = `${setupLockPath}.stale.${process.pid}.${Date.now()}`;
      try {
        renameSync(setupLockPath, quarantine);
        rmSync(quarantine, { recursive: true, force: true });
        continue;
      } catch {
        // Another waiter changed the observed lock. Re-read it on the next pass.
      }
    }
    if (!force && !needsSetup()) return false;
    sleep(100);
  }
  fail('timed out waiting for another package setup; retry or run claudex --package-setup');
}

function releaseSetupLock() {
  const owner = readSetupOwner();
  if (Number(owner?.pid) === process.pid) rmSync(setupLockPath, { recursive: true, force: true });
}

function ensurePackageSetup(login, force = false) {
  const acquired = acquireSetupLock(force);
  if (!acquired) return;
  try {
    if (force || needsSetup()) runInstaller(login);
  } finally {
    releaseSetupLock();
  }
}

function run(command, args, env = process.env) {
  const result = spawnSync(command, args, {
    env,
    stdio: 'inherit',
    windowsHide: true,
  });
  if (result.error) fail(`could not start ${command}: ${result.error.message}`);
  if (result.signal) {
    const signalNumber = osConstants.signals?.[result.signal];
    fail(`${command} was interrupted by ${result.signal}`, signalNumber ? 128 + signalNumber : 130);
  }
  return result.status ?? 1;
}

function runInstaller(login) {
  process.stderr.write(`claudex: preparing ${packageName} ${version}...\n`);
  const installerEnvironment = { ...process.env, CLAUDEX_BIN_DIR: binDir };
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
    status = run('powershell.exe', args, installerEnvironment);
  } else {
    const args = [join(packageRoot, 'install.sh')];
    if (login) args.push('--login');
    status = run('bash', args, installerEnvironment);
  }
  if (status !== 0) process.exit(status);
  writeMarker();
}

function needsSetup() {
  const marker = readMarker();
  const managedFiles = isWindows
    ? [
        launcherPath,
        join(binDir, 'claudex.cmd'),
        join(configDir, 'settings.json'),
        join(configDir, 'statusline.ps1'),
        join(configDir, 'usage-limit.ps1'),
        join(configDir, 'codex-session.ps1'),
        join(configDir, 'preload.cjs'),
        join(configDir, 'skills', 'usage-limit', 'SKILL.md'),
        join(configDir, 'cliproxyapi.yaml'),
      ]
    : [
        launcherPath,
        join(configDir, 'settings.json'),
        join(configDir, 'statusline'),
        join(configDir, 'usage-limit'),
        join(configDir, 'codex-session'),
        join(configDir, 'preload.cjs'),
        join(configDir, 'skills', 'usage-limit', 'SKILL.md'),
        join(configDir, 'cliproxyapi.yaml'),
      ];
  return (
    !existsSync(envPath) ||
    managedFiles.some((path) => !existsSync(path)) ||
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
  ensurePackageSetup(setupArgs.includes('--login'), true);
  process.stdout.write('Claudex package setup is complete. Run: claudex\n');
  process.exit(0);
}

if (needsSetup()) ensurePackageSetup(false);

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
