#!/usr/bin/env node

import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { constants as osConstants, homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  acquireSetupLock as acquireGenerationLock,
  releaseSetupLock as releaseGenerationLock,
} from './package-setup-lock.mjs';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));
const version = manifest.version;
const packageName = manifest.name;
const isWindows = process.platform === 'win32';
const isInteractive = [process.stdin, process.stdout, process.stderr].some((stream) => stream.isTTY);
const usesIsolatedProcessGroup = !isWindows && !isInteractive;
const ownsInteractiveProcessGroup = !isWindows && isInteractive && (() => {
  try {
    process.kill(-process.pid, 0);
    return true;
  } catch {
    return false;
  }
})();
const home = isWindows ? process.env.USERPROFILE || homedir() : process.env.HOME || homedir();
const configDir = process.env.CLAUDEX_CONFIG_DIR || join(home, '.config', 'claudex');
const markerPath = join(configDir, 'package-manager.json');
const setupLockPath = join(configDir, 'package-setup.lock');
const setupResultPath = join(configDir, 'package-setup-result.json');
const envPath = join(configDir, 'env');

// A package manager owns the public `claudex` shim. Keep the managed launcher
// private so it cannot shadow or overwrite Homebrew, Scoop, or WinGet's
// command and prevent a later package version from running this bootstrap.
const binDir = join(configDir, 'package-bin');
const launcherPath = join(binDir, isWindows ? 'claudex.ps1' : 'claudex');

function detectedInstallMethod() {
  const explicit = process.env.CLAUDEX_INSTALL_METHOD;
  if (['homebrew', 'scoop', 'winget'].includes(explicit)) return explicit;
  const normalizedRoot = packageRoot.replaceAll('\\', '/').toLowerCase();
  // Only a Cellar path proves that Homebrew owns this shim.
  if (normalizedRoot.includes('/cellar/')) return 'homebrew';
  if (normalizedRoot.includes('/scoop/apps/')) return 'scoop';
  if (normalizedRoot.includes('/microsoft/winget/packages/') || normalizedRoot.includes('/winget/packages/')) return 'winget';
  return null;
}

const installMethod = detectedInstallMethod();

function requireInstallMethod() {
  if (!installMethod) {
    fail('this bootstrap only supports Homebrew, Scoop, or WinGet installations; use the source installer at https://claudex.work instead');
  }
}

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
    method: installMethod,
    installedAt: new Date().toISOString(),
  };
  writeFileSync(temporary, `${JSON.stringify(marker, null, 2)}\n`, { mode: 0o600 });
  if (!isWindows) chmodSync(temporary, 0o600);
  renameSync(temporary, markerPath);
}

function readSetupResult() {
  try {
    const result = JSON.parse(readFileSync(setupResultPath, 'utf8'));
    return result && typeof result === 'object' ? result : null;
  } catch {
    return null;
  }
}

function readActiveSetupGeneration() {
  try {
    const owner = JSON.parse(readFileSync(join(setupLockPath, 'owner.json'), 'utf8'));
    return typeof owner?.generation === 'string' ? owner.generation : null;
  } catch {
    return null;
  }
}

function writeSetupResult(generation, status) {
  const temporary = `${setupResultPath}.tmp.${process.pid}.${generation}`;
  const result = {
    package: packageName,
    version,
    method: installMethod,
    generation,
    status,
    finishedAt: new Date().toISOString(),
  };
  writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  if (!isWindows) chmodSync(temporary, 0o600);
  renameSync(temporary, setupResultPath);
}

function isFailureForWave(result, baseline, joinedGeneration) {
  return (
    result?.package === packageName &&
    result?.version === version &&
    result?.method === installMethod &&
    typeof result.generation === 'string' &&
    Number.isInteger(result.status) &&
    result.status !== 0 &&
    (result.generation !== baseline?.generation || result.generation === joinedGeneration)
  );
}

function acquireSetupLock(force) {
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  const generation = acquireGenerationLock(setupLockPath, {
    shouldContinue: () => force || needsSetup(),
  });
  if (!generation && (force || needsSetup())) {
    fail('timed out waiting for another package setup; retry or run claudex --package-setup');
  }
  return generation;
}

async function ensurePackageSetup(login, force = false) {
  // Every caller records the last completed attempt before it joins the lock
  // queue. If that generation changes to a failure while it waits, this caller
  // belongs to the same failure wave and must propagate the result instead of
  // serially rerunning the installer.
  const baselineResult = readSetupResult();
  const joinedGeneration = readActiveSetupGeneration();
  const generation = acquireSetupLock(force);
  if (!generation) return;
  let status = 0;
  try {
    const completedWhileWaiting = readSetupResult();
    if (isFailureForWave(completedWhileWaiting, baselineResult, joinedGeneration)) {
      status = completedWhileWaiting.status;
    } else if (force || needsSetup()) {
      status = await runInstaller(login);
      writeSetupResult(generation, status);
    }
  } finally {
    releaseGenerationLock(setupLockPath, generation);
  }
  if (status !== 0) process.exit(status);
}

function signalExitCode(signal) {
  const signalNumber = osConstants.signals?.[signal];
  return signalNumber ? 128 + signalNumber : 130;
}

function startProcessGroupCleanupWatchdog(groupId, ownerPid) {
  const watchdogSource = [
    'const groupId = Number(process.argv[1]);',
    'const ownerPid = Number(process.argv[2]);',
    'const deadline = Date.now() + 10_000;',
    'const timer = setInterval(() => {',
    '  try { process.kill(ownerPid, 0); }',
    '  catch (error) {',
    "    if (error?.code !== 'ESRCH') process.exit(1);",
    "    try { process.kill(-groupId, 'SIGKILL'); } catch (killError) {",
    "      if (killError?.code !== 'ESRCH' && killError?.code !== 'EPERM') process.exit(1);",
    '    }',
    '    process.exit(0);',
    '  }',
    '  if (Date.now() >= deadline) process.exit(1);',
    '}, 20);',
  ].join('\n');
  const watchdog = spawn(process.execPath, ['-e', watchdogSource, String(groupId), String(ownerPid)], {
    detached: true,
    env: { PATH: process.env.PATH || '' },
    stdio: 'ignore',
    windowsHide: true,
  });
  watchdog.unref();
}

function run(command, args, env = process.env) {
  return new Promise((resolveStatus) => {
    const child = spawn(command, args, {
      // Interactive children must remain in the terminal's foreground process
      // group so resize and job-control signals retain their native semantics.
      // Non-interactive children get an isolated group that can be cleaned up
      // without signaling the shell or automation process that launched us.
      detached: usesIsolatedProcessGroup,
      env,
      stdio: 'inherit',
      windowsHide: true,
    });
    let forwardedSignal = null;
    let forceKillTimer = null;
    let cleanupWatchdogStarted = false;
    const signalHandlers = new Map();
    const relayedSignals = new Set();

    const signalChild = (signal) => {
      try {
        const target = usesIsolatedProcessGroup
          ? -child.pid
          : ownsInteractiveProcessGroup
            ? -process.pid
            : child.pid;
        process.kill(target, signal);
      } catch (error) {
        if (error?.code !== 'ESRCH') throw error;
      }
    };
    const cleanupSignalHandlers = () => {
      for (const [signal, handler] of signalHandlers) process.off(signal, handler);
      signalHandlers.clear();
      if (forceKillTimer) clearTimeout(forceKillTimer);
      forceKillTimer = null;
    };

    if (!isWindows) {
      for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP', 'SIGQUIT']) {
        const handler = () => {
          if (relayedSignals.has(signal)) return;
          if (!forwardedSignal) forwardedSignal = signal;
          if (ownsInteractiveProcessGroup) {
            relayedSignals.add(signal);
            if (!cleanupWatchdogStarted) {
              startProcessGroupCleanupWatchdog(process.pid, process.pid);
              cleanupWatchdogStarted = true;
            }
          }
          signalChild(signal);
          if (!forceKillTimer) {
            forceKillTimer = setTimeout(() => {
              if (ownsInteractiveProcessGroup) process.exit(signalExitCode(forwardedSignal));
              else signalChild('SIGKILL');
            }, 2_000);
          }
        };
        signalHandlers.set(signal, handler);
        process.on(signal, handler);
      }
    }

    child.once('error', (error) => {
      cleanupSignalHandlers();
      fail(`could not start ${command}: ${error.message}`);
    });
    const settleChildExit = (status, childSignal) => {
      cleanupSignalHandlers();
      if (forwardedSignal) {
        // The launcher may trap the forwarded signal and exit before one of
        // its descendants. Remove anything still in its isolated group before
        // this bootstrap returns the conventional 128+signal status.
        if (usesIsolatedProcessGroup) {
          try {
            process.kill(-child.pid, 'SIGKILL');
          } catch (error) {
            // macOS may report EPERM while a just-killed process group contains
            // only unreaped members. The original group signal already won.
            if (error?.code !== 'ESRCH' && error?.code !== 'EPERM') throw error;
          }
        }
        resolveStatus(signalExitCode(forwardedSignal));
      } else if (childSignal) {
        process.stderr.write(`claudex: ${command} was interrupted by ${childSignal}\n`);
        resolveStatus(signalExitCode(childSignal));
      } else {
        resolveStatus(status ?? 1);
      }
    };
    child.once('exit', (status, childSignal) => {
      if (!isWindows && ownsInteractiveProcessGroup && status === 0 && !childSignal && !forwardedSignal) {
        // A foreground-group signal reaches the wrapper and launcher at the
        // same time. A launcher trap can exit cleanly before Node dispatches
        // the wrapper's already queued signal callback. Keep the handlers for
        // one short reconciliation window so that signal controls the public
        // exit status instead of racing with the child's clean exit event.
        setTimeout(() => settleChildExit(status, childSignal), 25);
        return;
      }
      settleChildExit(status, childSignal);
    });
  });
}

async function runInstaller(login) {
  process.stderr.write(`claudex: preparing ${packageName} ${version}...\n`);
  const installerEnvironment = {
    ...process.env,
    CLAUDEX_BIN_DIR: binDir,
    CLAUDEX_INSTALL_METHOD: installMethod,
    CLAUDEX_PACKAGE_ROOT: packageRoot,
  };
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
    status = await run('powershell.exe', args, installerEnvironment);
  } else {
    const args = [join(packageRoot, 'install.sh')];
    if (login) args.push('--login');
    status = await run('bash', args, installerEnvironment);
  }
  if (status !== 0) return status;
  writeMarker();
  return 0;
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
        join(configDir, 'skill-bridge.cjs'),
        join(configDir, 'self-update.ps1'),
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
        join(configDir, 'skill-bridge.cjs'),
        join(configDir, 'self-update'),
        join(configDir, 'skills', 'usage-limit', 'SKILL.md'),
        join(configDir, 'cliproxyapi.yaml'),
      ];
  return (
    !existsSync(envPath) ||
    managedFiles.some((path) => !existsSync(path)) ||
    marker?.package !== packageName ||
    marker?.version !== version ||
    marker?.method !== installMethod
  );
}

const args = process.argv.slice(2);

if (args.length === 1 && args[0] === '--package-version') {
  process.stdout.write(`${version}\n`);
  process.exit(0);
}

requireInstallMethod();

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
  await ensurePackageSetup(setupArgs.includes('--login'), true);
  process.stdout.write('Claudex package setup is complete. Run: claudex\n');
  process.exit(0);
}

if (needsSetup()) await ensurePackageSetup(false);

let status;
if (isWindows) {
  status = await run('powershell.exe', [
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    launcherPath,
    ...args,
  ]);
} else {
  status = await run(launcherPath, args);
}
process.exit(status);
