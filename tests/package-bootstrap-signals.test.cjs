const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

if (process.platform === 'win32') {
  process.stdout.write('package bootstrap Unix signal tests skipped on Windows\n');
  process.exit(0);
}

const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'claudex-package-signals-'));
const fixture = path.join(temporary, 'fixture');
const fixtureBin = path.join(fixture, 'bin');
const configDir = path.join(temporary, 'config');
const managedBin = path.join(configDir, 'package-bin');
const descendantScript = path.join(temporary, 'stubborn-descendant.cjs');
const activeProcesses = new Set();
const activeProcessGroups = new Set();
const ptyDriver = [
  'import os, pty, sys, time',
  'session_pid, fd = pty.fork()',
  'if session_pid == 0:',
  '    ready_read, ready_write = os.pipe()',
  '    wrapper_pid = os.fork()',
  '    if wrapper_pid == 0:',
  '        os.close(ready_read)',
  '        os.setpgid(0, 0)',
  "        os.write(ready_write, b'1')",
  '        os.close(ready_write)',
  '        os.execve(sys.argv[1], sys.argv[1:], os.environ)',
  '    os.close(ready_write)',
  '    os.read(ready_read, 1)',
  '    os.close(ready_read)',
  '    os.tcsetpgrp(0, wrapper_pid)',
  "    with open(os.environ['CLAUDEX_TEST_WRAPPER_PID_FILE'], 'w') as output:",
  "        output.write(str(wrapper_pid) + '\\n')",
  '    for _ in range(500):',
  "        if os.path.exists(os.environ['CLAUDEX_TEST_LAUNCHER_PID_FILE']) and os.path.exists(os.environ['CLAUDEX_TEST_DESCENDANT_PID_FILE']):",
  '            break',
  '        time.sleep(0.01)',
  '    else:',
  '        sys.exit(2)',
  "    with open(os.environ['CLAUDEX_TEST_LAUNCHER_PID_FILE']) as source:",
  '        launcher_pid = int(source.read().strip())',
  "    with open(os.environ['CLAUDEX_TEST_DESCENDANT_PID_FILE']) as source:",
  '        descendant_pid = int(source.read().strip())',
  "    with open(os.environ['CLAUDEX_TEST_GROUP_FILE'], 'w') as output:",
  "        output.write(f'{os.getpgid(wrapper_pid)} {os.getpgid(launcher_pid)} {os.getpgid(descendant_pid)}\\n')",
  '    while True:',
  '        _, wrapper_status = os.waitpid(wrapper_pid, os.WUNTRACED | os.WCONTINUED)',
  '        if os.WIFSTOPPED(wrapper_status):',
  "            with open(os.environ['CLAUDEX_TEST_JOB_STATUS_FILE'], 'a') as output:",
  "                output.write(f'STOP {os.WSTOPSIG(wrapper_status)}\\n')",
  '            continue',
  '        if os.WIFCONTINUED(wrapper_status):',
  "            with open(os.environ['CLAUDEX_TEST_JOB_STATUS_FILE'], 'a') as output:",
  "                output.write('CONT\\n')",
  '            continue',
  '        break',
  '    if os.WIFEXITED(wrapper_status):',
  '        sys.exit(os.WEXITSTATUS(wrapper_status))',
  '    if os.WIFSIGNALED(wrapper_status):',
  '        sys.exit(128 + os.WTERMSIG(wrapper_status))',
  '    sys.exit(1)',
  'while True:',
  '    try:',
  '        data = os.read(fd, 4096)',
  '    except OSError:',
  '        break',
  '    if not data:',
  '        break',
  '_, status = os.waitpid(session_pid, 0)',
  'if os.WIFEXITED(status):',
  '    sys.exit(os.WEXITSTATUS(status))',
  'if os.WIFSIGNALED(status):',
  '    sys.exit(128 + os.WTERMSIG(status))',
  'sys.exit(1)',
  '',
].join('\n');

function writeFile(file, contents, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents, { mode });
}

function waitForFile(file, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (fs.existsSync(file) && fs.statSync(file).size > 0) return resolve();
      if (Date.now() >= deadline) return reject(new Error(`timed out waiting for ${file}`));
      setTimeout(poll, 20);
    };
    poll();
  });
}

function waitForCondition(condition, description, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (condition()) return resolve();
      if (Date.now() >= deadline) return reject(new Error(`timed out waiting for ${description}`));
      setTimeout(poll, 20);
    };
    poll();
  });
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === 'ESRCH') return false;
    throw error;
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function waitForProcessExit(pid, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (!processIsAlive(pid)) return resolve();
      if (Date.now() >= deadline) return reject(new Error(`process ${pid} survived group cleanup`));
      setTimeout(poll, 20);
    };
    poll();
  });
}

function waitForExit(child, timeoutMs = 5_000) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`process ${child.pid} did not exit`)), timeoutMs);
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      resolve({ code, signal });
    });
  });
}

async function assertNormalExitStatus() {
  const wrapper = spawn(process.execPath, [path.join(fixtureBin, 'claudex-package.mjs'), '--exit-test'], {
    env: {
      ...process.env,
      CLAUDEX_CONFIG_DIR: configDir,
      CLAUDEX_INSTALL_METHOD: 'homebrew',
    },
    stdio: 'ignore',
  });
  activeProcesses.add(wrapper);
  const result = await waitForExit(wrapper);
  activeProcesses.delete(wrapper);
  assert.deepEqual(result, { code: 37, signal: null });
}

async function assertForwarded(signal, launcherIgnoresSignals = false) {
  const label = `${signal.toLowerCase()}${launcherIgnoresSignals ? '-ignored' : ''}`;
  const launcherPidFile = path.join(temporary, `${label}-launcher.pid`);
  const descendantPidFile = path.join(temporary, `${label}-descendant.pid`);
  const descendantReadyFile = path.join(temporary, `${label}-descendant.ready`);
  const wrapper = spawn(process.execPath, [path.join(fixtureBin, 'claudex-package.mjs'), '--signal-test'], {
    env: {
      ...process.env,
      CLAUDEX_CONFIG_DIR: configDir,
      CLAUDEX_INSTALL_METHOD: 'homebrew',
      CLAUDEX_TEST_DESCENDANT_SCRIPT: descendantScript,
      CLAUDEX_TEST_DESCENDANT_PID_FILE: descendantPidFile,
      CLAUDEX_TEST_DESCENDANT_READY_FILE: descendantReadyFile,
      CLAUDEX_TEST_DESCENDANT_IGNORES_SIGNALS: '1',
      CLAUDEX_TEST_LAUNCHER_PID_FILE: launcherPidFile,
      CLAUDEX_TEST_LAUNCHER_IGNORES_SIGNALS: launcherIgnoresSignals ? '1' : '0',
      CLAUDEX_TEST_SIGNAL_LOG: path.join(temporary, `${label}-signals.log`),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  wrapper.stderr.setEncoding('utf8');
  wrapper.stderr.on('data', (chunk) => { stderr += chunk; });
  activeProcesses.add(wrapper);
  await Promise.all([
    waitForFile(launcherPidFile),
    waitForFile(descendantPidFile),
    waitForFile(descendantReadyFile),
  ]);
  const launcherPid = Number(fs.readFileSync(launcherPidFile, 'utf8').trim());
  const descendantPid = Number(fs.readFileSync(descendantPidFile, 'utf8').trim());
  activeProcessGroups.add(launcherPid);
  assert.equal(wrapper.kill(signal), true);
  const result = await waitForExit(wrapper);
  activeProcesses.delete(wrapper);
  assert.deepEqual(result, {
    code: 128 + os.constants.signals[signal],
    signal: null,
  }, stderr);
  await Promise.all([waitForProcessExit(launcherPid), waitForProcessExit(descendantPid)]);
  activeProcessGroups.delete(launcherPid);
}

async function assertInteractiveTerminalSemantics() {
  const launcherPidFile = path.join(temporary, 'interactive-launcher.pid');
  const descendantPidFile = path.join(temporary, 'interactive-descendant.pid');
  const descendantReadyFile = path.join(temporary, 'interactive-descendant.ready');
  const signalLog = path.join(temporary, 'interactive-signals.log');
  const heartbeatFile = path.join(temporary, 'interactive-heartbeat.log');
  const groupFile = path.join(temporary, 'interactive-groups.log');
  const jobStatusFile = path.join(temporary, 'interactive-job-status.log');
  const wrapperPidFile = path.join(temporary, 'interactive-wrapper.pid');
  const pythonCheck = spawnSync('python3', ['--version'], { stdio: 'ignore' });
  assert.equal(pythonCheck.status, 0, 'python3 is required for the PTY regression');
  const driver = spawn('python3', [
    '-c',
    ptyDriver,
    process.execPath,
    path.join(fixtureBin, 'claudex-package.mjs'),
    '--signal-test',
  ], {
    env: {
      ...process.env,
      CLAUDEX_CONFIG_DIR: configDir,
      CLAUDEX_INSTALL_METHOD: 'homebrew',
      CLAUDEX_TEST_DESCENDANT_SCRIPT: descendantScript,
      CLAUDEX_TEST_DESCENDANT_PID_FILE: descendantPidFile,
      CLAUDEX_TEST_DESCENDANT_READY_FILE: descendantReadyFile,
      CLAUDEX_TEST_DESCENDANT_IGNORES_SIGNALS: '0',
      CLAUDEX_TEST_HEARTBEAT_FILE: heartbeatFile,
      CLAUDEX_TEST_GROUP_FILE: groupFile,
      CLAUDEX_TEST_JOB_STATUS_FILE: jobStatusFile,
      CLAUDEX_TEST_LAUNCHER_PID_FILE: launcherPidFile,
      CLAUDEX_TEST_LAUNCHER_IGNORES_SIGNALS: '0',
      CLAUDEX_TEST_SIGNAL_LOG: signalLog,
      CLAUDEX_TEST_WRAPPER_PID_FILE: wrapperPidFile,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  activeProcesses.add(driver);
  let stderr = '';
  driver.stderr.setEncoding('utf8');
  driver.stderr.on('data', (chunk) => { stderr += chunk; });
  try {
    await Promise.all([
      waitForFile(wrapperPidFile),
      waitForFile(launcherPidFile),
      waitForFile(descendantPidFile),
      waitForFile(descendantReadyFile),
      waitForFile(groupFile),
    ]);
  } catch (error) {
    throw new Error(`${error.message}${stderr ? `\nPTY stderr:\n${stderr}` : ''}`);
  }
  const wrapperPid = Number(fs.readFileSync(wrapperPidFile, 'utf8').trim());
  activeProcessGroups.add(wrapperPid);
  const launcherPid = Number(fs.readFileSync(launcherPidFile, 'utf8').trim());
  const descendantPid = Number(fs.readFileSync(descendantPidFile, 'utf8').trim());
  assert.deepEqual(fs.readFileSync(groupFile, 'utf8').trim().split(/\s+/),
    [String(wrapperPid), String(wrapperPid), String(wrapperPid)],
    'PTY wrapper, launcher, and descendant must share the foreground process group');

  process.kill(-wrapperPid, 'SIGWINCH');
  await waitForCondition(
    () => fs.existsSync(signalLog) && fs.readFileSync(signalLog, 'utf8').includes('WINCH'),
    'launcher WINCH delivery',
  );

  await waitForCondition(
    () => fs.existsSync(heartbeatFile) && fs.statSync(heartbeatFile).size >= 4,
    'interactive descendant heartbeat',
  );
  process.kill(-wrapperPid, 'SIGTSTP');
  await waitForCondition(
    () => fs.existsSync(jobStatusFile) && fs.readFileSync(jobStatusFile, 'utf8').includes('STOP '),
    'PTY supervisor to observe wrapper stop',
  );
  const stoppedHeartbeatSize = fs.statSync(heartbeatFile).size;
  await delay(300);
  assert.equal(fs.statSync(heartbeatFile).size, stoppedHeartbeatSize,
    'TSTP must suspend the complete interactive foreground process group');
  process.kill(-wrapperPid, 'SIGCONT');
  await waitForCondition(
    () => fs.existsSync(signalLog) && fs.readFileSync(signalLog, 'utf8').includes('CONT'),
    'launcher CONT delivery',
  );
  await waitForCondition(
    () => fs.statSync(heartbeatFile).size > stoppedHeartbeatSize,
    'interactive descendant heartbeat to resume',
  );

  process.kill(-wrapperPid, 'SIGQUIT');
  const result = await waitForExit(driver);
  activeProcesses.delete(driver);
  assert.deepEqual(result, { code: 128 + os.constants.signals.SIGQUIT, signal: null }, stderr);
  await Promise.all([waitForProcessExit(launcherPid), waitForProcessExit(descendantPid)]);
  activeProcessGroups.delete(wrapperPid);
}

async function assertInteractiveTargetedCleanup() {
  const launcherPidFile = path.join(temporary, 'interactive-targeted-launcher.pid');
  const descendantPidFile = path.join(temporary, 'interactive-targeted-descendant.pid');
  const descendantReadyFile = path.join(temporary, 'interactive-targeted-descendant.ready');
  const wrapperPidFile = path.join(temporary, 'interactive-targeted-wrapper.pid');
  const groupFile = path.join(temporary, 'interactive-targeted-groups.log');
  const jobStatusFile = path.join(temporary, 'interactive-targeted-job-status.log');
  const driver = spawn('python3', [
    '-c',
    ptyDriver,
    process.execPath,
    path.join(fixtureBin, 'claudex-package.mjs'),
    '--signal-test',
  ], {
    env: {
      ...process.env,
      CLAUDEX_CONFIG_DIR: configDir,
      CLAUDEX_INSTALL_METHOD: 'homebrew',
      CLAUDEX_TEST_DESCENDANT_SCRIPT: descendantScript,
      CLAUDEX_TEST_DESCENDANT_PID_FILE: descendantPidFile,
      CLAUDEX_TEST_DESCENDANT_READY_FILE: descendantReadyFile,
      CLAUDEX_TEST_DESCENDANT_IGNORES_SIGNALS: '1',
      CLAUDEX_TEST_LAUNCHER_PID_FILE: launcherPidFile,
      CLAUDEX_TEST_LAUNCHER_IGNORES_SIGNALS: '1',
      CLAUDEX_TEST_SIGNAL_LOG: path.join(temporary, 'interactive-targeted-signals.log'),
      CLAUDEX_TEST_WRAPPER_PID_FILE: wrapperPidFile,
      CLAUDEX_TEST_GROUP_FILE: groupFile,
      CLAUDEX_TEST_JOB_STATUS_FILE: jobStatusFile,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  activeProcesses.add(driver);
  let stderr = '';
  driver.stderr.setEncoding('utf8');
  driver.stderr.on('data', (chunk) => { stderr += chunk; });
  try {
    await Promise.all([
      waitForFile(wrapperPidFile),
      waitForFile(launcherPidFile),
      waitForFile(descendantPidFile),
      waitForFile(descendantReadyFile),
      waitForFile(groupFile),
    ]);
  } catch (error) {
    throw new Error(`${error.message}${stderr ? `\nPTY stderr:\n${stderr}` : ''}`);
  }
  const wrapperPid = Number(fs.readFileSync(wrapperPidFile, 'utf8').trim());
  const launcherPid = Number(fs.readFileSync(launcherPidFile, 'utf8').trim());
  const descendantPid = Number(fs.readFileSync(descendantPidFile, 'utf8').trim());
  activeProcessGroups.add(wrapperPid);
  assert.deepEqual(fs.readFileSync(groupFile, 'utf8').trim().split(/\s+/),
    [String(wrapperPid), String(wrapperPid), String(wrapperPid)],
    'targeted-signal PTY fixture must share one foreground process group');

  // Only the package shim receives TERM. It must relay TERM to the entire PTY
  // job and, because both fixtures ignore it, return 143 before its detached
  // watchdog removes the surviving launcher and descendant.
  process.kill(wrapperPid, 'SIGTERM');
  const result = await waitForExit(driver);
  activeProcesses.delete(driver);
  assert.deepEqual(result, { code: 128 + os.constants.signals.SIGTERM, signal: null }, stderr);
  await Promise.all([waitForProcessExit(launcherPid), waitForProcessExit(descendantPid)]);
  activeProcessGroups.delete(wrapperPid);
}

(async () => {
  fs.mkdirSync(fixtureBin, { recursive: true });
  fs.copyFileSync(path.join(root, 'bin', 'claudex-package.mjs'), path.join(fixtureBin, 'claudex-package.mjs'));
  fs.copyFileSync(path.join(root, 'bin', 'package-setup-lock.mjs'), path.join(fixtureBin, 'package-setup-lock.mjs'));
  writeFile(path.join(fixture, 'package.json'), `${JSON.stringify({
    name: 'claudex-package-signal-test',
    version: '9.9.9',
    type: 'module',
  })}\n`);

  writeFile(descendantScript, [
    "const fs = require('node:fs');",
    "if (process.env.CLAUDEX_TEST_DESCENDANT_IGNORES_SIGNALS === '1') {",
    "  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP', 'SIGQUIT']) process.on(signal, () => {});",
    '}',
    "fs.writeFileSync(process.env.CLAUDEX_TEST_DESCENDANT_READY_FILE, 'ready\\n');",
    "if (process.env.CLAUDEX_TEST_HEARTBEAT_FILE) {",
    "  setInterval(() => fs.appendFileSync(process.env.CLAUDEX_TEST_HEARTBEAT_FILE, 'beat\\n'), 50);",
    '} else {',
    '  setInterval(() => {}, 1_000);',
    '}',
    '',
  ].join('\n'));
  writeFile(path.join(managedBin, 'claudex'), [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'if [[ "${1:-}" == --exit-test ]]; then exit 37; fi',
    'printf \'%s\\n\' "$$" > "$CLAUDEX_TEST_LAUNCHER_PID_FILE"',
    'node "$CLAUDEX_TEST_DESCENDANT_SCRIPT" &',
    'descendant=$!',
    'printf \'%s\\n\' "$descendant" > "$CLAUDEX_TEST_DESCENDANT_PID_FILE"',
    "trap 'printf \'WINCH\\n\' >> \"$CLAUDEX_TEST_SIGNAL_LOG\"' WINCH",
    "trap 'printf \'CONT\\n\' >> \"$CLAUDEX_TEST_SIGNAL_LOG\"' CONT",
    'if [[ "$CLAUDEX_TEST_LAUNCHER_IGNORES_SIGNALS" == 1 ]]; then',
    "  trap '' TERM INT HUP QUIT",
    '  while kill -0 "$descendant" 2>/dev/null; do wait "$descendant" || true; done',
    'else',
    "  trap 'exit 0' TERM INT HUP QUIT",
    '  while kill -0 "$descendant" 2>/dev/null; do wait "$descendant" || true; done',
    'fi',
    '',
  ].join('\n'), 0o755);

  const managedFiles = [
    'env',
    'settings.json',
    'statusline',
    'usage-limit',
    'codex-session',
    'preload.cjs',
    'skill-bridge.cjs',
    'self-update',
    path.join('skills', 'usage-limit', 'SKILL.md'),
    'cliproxyapi.yaml',
  ];
  for (const managedFile of managedFiles) writeFile(path.join(configDir, managedFile), '\n');
  writeFile(path.join(configDir, 'package-manager.json'), `${JSON.stringify({
    package: 'claudex-package-signal-test',
    version: '9.9.9',
    method: 'homebrew',
  })}\n`);

  await assertNormalExitStatus();
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP', 'SIGQUIT']) await assertForwarded(signal);
  await assertForwarded('SIGTERM', true);
  await assertInteractiveTerminalSemantics();
  await assertInteractiveTargetedCleanup();

  fs.rmSync(temporary, { recursive: true, force: true });
  process.stdout.write('package bootstrap Unix signal tests passed\n');
})().catch((error) => {
  for (const child of activeProcesses) {
    try { child.kill('SIGKILL'); } catch {}
  }
  for (const groupId of activeProcessGroups) {
    try { process.kill(-groupId, 'SIGKILL'); } catch {}
  }
  fs.rmSync(temporary, { recursive: true, force: true });
  console.error(error);
  process.exitCode = 1;
});
