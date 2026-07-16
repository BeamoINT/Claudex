const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'claudex-package-lock-'));

function writeOwner(lockPath, owner, ageMs = 0) {
  fs.mkdirSync(lockPath, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(lockPath, 'owner.json'), `${JSON.stringify(owner)}\n`, { mode: 0o600 });
  if (ageMs > 0) {
    const timestamp = new Date(Date.now() - ageMs);
    fs.utimesSync(lockPath, timestamp, timestamp);
  }
}

function readOwner(lockPath) {
  return JSON.parse(fs.readFileSync(path.join(lockPath, 'owner.json'), 'utf8'));
}

function runPackageSetup(wrapper, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [wrapper, '--package-setup'], {
      env: { ...process.env, ...env },
      stdio: 'ignore',
      windowsHide: true,
    });
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (signal) reject(new Error(`package setup terminated by ${signal}`));
      else resolve(code);
    });
  });
}

(async () => {
  const modulePath = path.resolve(__dirname, '..', 'bin', 'package-setup-lock.mjs');
  const { acquireSetupLock, releaseSetupLock } = await import(pathToFileURL(modulePath));

  const normalLock = path.join(temporary, 'normal.lock');
  const normalGeneration = acquireSetupLock(normalLock, { generation: 'normal-generation' });
  assert.equal(normalGeneration, 'normal-generation');
  assert.deepEqual(readOwner(normalLock).generation, normalGeneration);
  assert.equal(releaseSetupLock(normalLock, normalGeneration), true);
  assert.equal(fs.existsSync(normalLock), false);

  const publicationLock = path.join(temporary, 'publication.lock');
  const displacedLock = path.join(temporary, 'publication.displaced');
  const publishedReplacement = {
    pid: process.pid,
    generation: 'published-replacement',
    startedAt: new Date().toISOString(),
  };
  let publicationRaceInjected = false;
  const lostPublication = acquireSetupLock(publicationLock, {
    generation: 'lost-publication',
    isProcessAlive: () => true,
    shouldContinue: () => false,
    sleep: () => {},
    beforeOwnerWrite: () => {
      if (publicationRaceInjected) return;
      fs.renameSync(publicationLock, displacedLock);
      writeOwner(publicationLock, publishedReplacement);
      publicationRaceInjected = true;
    },
  });
  assert.equal(lostPublication, null);
  assert.equal(readOwner(publicationLock).generation, publishedReplacement.generation,
    'owner publication must not overwrite a replacement generation');

  // Five-party schedule: an original stale owner is removed by one reclaimer;
  // a second, delayed observer has already published its intent; fresh owner B
  // creates canonical; that observer moves B; then contender C takes canonical
  // before B can be restored. B must wait on the intent and never proceed, so C
  // is the only generation that can own setup after the observer withdraws.
  const fencedLock = path.join(temporary, 'five-party.lock');
  const displacedFreshLock = path.join(temporary, 'five-party.displaced');
  const intentDirectory = `${fencedLock}.reclaim-intents`;
  const delayedIntent = path.join(intentDirectory, 'delayed-observer.json');
  const contenderC = {
    pid: process.pid,
    generation: 'contender-c',
    startedAt: new Date().toISOString(),
  };
  let fenceScheduleRan = false;
  const displacedGeneration = acquireSetupLock(fencedLock, {
    generation: 'fresh-owner-b',
    isProcessAlive: () => true,
    shouldContinue: () => false,
    sleep: () => {},
    beforeOwnerWrite: () => {
      fs.mkdirSync(intentDirectory, { recursive: true, mode: 0o700 });
      fs.writeFileSync(delayedIntent, `${JSON.stringify({
        pid: process.pid,
        generation: 'delayed-observer',
        startedAt: new Date().toISOString(),
      })}\n`);
    },
    whileWaitingForReclaimers: () => {
      if (fenceScheduleRan) return;
      fs.renameSync(fencedLock, displacedFreshLock);
      writeOwner(fencedLock, contenderC);
      fs.unlinkSync(delayedIntent);
      fenceScheduleRan = true;
    },
  });
  assert.equal(fenceScheduleRan, true);
  assert.equal(displacedGeneration, null,
    'a displaced fresh owner must not proceed after losing canonical');
  assert.equal(readOwner(fencedLock).generation, contenderC.generation,
    'the third contender must remain the sole canonical owner');

  const reclaimLock = path.join(temporary, 'reclaim.lock');
  const staleOwner = { pid: 99999999, generation: 'stale-generation', startedAt: '2020-01-01T00:00:00.000Z' };
  const freshOwner = { pid: process.pid, generation: 'fresh-generation', startedAt: new Date().toISOString() };
  writeOwner(reclaimLock, staleOwner, 10_000);
  let replacedDuringReclaim = false;
  const reclaimedGeneration = acquireSetupLock(reclaimLock, {
    generation: 'observer-generation',
    staleGraceMs: 1,
    isProcessAlive: () => false,
    shouldContinue: () => false,
    sleep: () => {},
    beforeReclaimRename: () => {
      fs.rmSync(reclaimLock, { recursive: true, force: true });
      writeOwner(reclaimLock, freshOwner);
      replacedDuringReclaim = true;
    },
  });
  assert.equal(replacedDuringReclaim, true);
  assert.equal(reclaimedGeneration, null);
  assert.equal(readOwner(reclaimLock).generation, freshOwner.generation,
    'a stale observer must restore rather than delete a newer generation');

  const releaseLock = path.join(temporary, 'release.lock');
  const ownedGeneration = 'owned-generation';
  writeOwner(releaseLock, { pid: process.pid, generation: ownedGeneration, startedAt: new Date().toISOString() });
  const replacementOwner = { pid: process.pid, generation: 'replacement-generation', startedAt: new Date().toISOString() };
  const released = releaseSetupLock(releaseLock, ownedGeneration, {
    beforeReleaseRename: () => {
      fs.rmSync(releaseLock, { recursive: true, force: true });
      writeOwner(releaseLock, replacementOwner);
    },
  });
  assert.equal(released, false);
  assert.equal(readOwner(releaseLock).generation, replacementOwner.generation,
    'a releasing process must not delete a replacement generation');

  const legacyLock = path.join(temporary, 'legacy.lock');
  writeOwner(legacyLock, { pid: 99999998, startedAt: '2020-01-01T00:00:00.000Z' }, 10_000);
  const migratedGeneration = acquireSetupLock(legacyLock, {
    generation: 'migrated-generation',
    staleGraceMs: 1,
    isProcessAlive: () => false,
    sleep: () => {},
  });
  assert.equal(migratedGeneration, 'migrated-generation');
  assert.equal(readOwner(legacyLock).generation, migratedGeneration);
  assert.equal(releaseSetupLock(legacyLock, migratedGeneration), true);

  const fixture = path.join(temporary, 'failure-wave-fixture');
  const fixtureBin = path.join(fixture, 'bin');
  const fixtureConfig = path.join(temporary, 'failure-wave-config');
  const attemptsPath = path.join(temporary, 'failure-wave-attempts.txt');
  fs.mkdirSync(fixtureBin, { recursive: true });
  fs.copyFileSync(path.resolve(__dirname, '..', 'bin', 'claudex-package.mjs'), path.join(fixtureBin, 'claudex-package.mjs'));
  fs.copyFileSync(modulePath, path.join(fixtureBin, 'package-setup-lock.mjs'));
  fs.writeFileSync(path.join(fixture, 'package.json'), JSON.stringify({
    name: 'claudex-lock-test',
    version: '9.9.9',
    type: 'module',
  }));
  if (process.platform === 'win32') {
    fs.writeFileSync(path.join(fixture, 'install.ps1'), [
      "Add-Content -LiteralPath $env:CLAUDEX_TEST_ATTEMPTS -Value 'attempt'",
      'Start-Sleep -Milliseconds 2000',
      'exit 23',
      '',
    ].join('\r\n'));
  } else {
    fs.writeFileSync(path.join(fixture, 'install.sh'), [
      '#!/usr/bin/env bash',
      'set -euo pipefail',
      "printf 'attempt\\n' >> \"$CLAUDEX_TEST_ATTEMPTS\"",
      'sleep 2',
      'exit 23',
      '',
    ].join('\n'));
  }
  const wrapper = path.join(fixtureBin, 'claudex-package.mjs');
  const failureEnvironment = {
    CLAUDEX_CONFIG_DIR: fixtureConfig,
    CLAUDEX_INSTALL_METHOD: 'homebrew',
    CLAUDEX_TEST_ATTEMPTS: attemptsPath,
  };
  const waveStatuses = await Promise.all(Array.from(
    { length: 5 },
    () => runPackageSetup(wrapper, failureEnvironment),
  ));
  assert.deepEqual(waveStatuses, [23, 23, 23, 23, 23]);
  assert.equal(fs.readFileSync(attemptsPath, 'utf8').trim().split(/\r?\n/).length, 1,
    'concurrent waiters must share one failed installer attempt');

  const retryStatus = await runPackageSetup(wrapper, failureEnvironment);
  assert.equal(retryStatus, 23);
  assert.equal(fs.readFileSync(attemptsPath, 'utf8').trim().split(/\r?\n/).length, 2,
    'a later invocation must be allowed to start a new failure wave');

  fs.rmSync(temporary, { recursive: true, force: true });
  process.stdout.write('package setup lock tests passed\n');
})().catch((error) => {
  fs.rmSync(temporary, { recursive: true, force: true });
  console.error(error);
  process.exitCode = 1;
});
