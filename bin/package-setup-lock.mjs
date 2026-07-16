import { mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';

const setupWait = new Int32Array(new SharedArrayBuffer(4));

function defaultSleep(milliseconds) {
  Atomics.wait(setupWait, 0, 0, milliseconds);
}

function defaultProcessIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === 'EPERM';
  }
}

function readOwner(lockPath) {
  try {
    return JSON.parse(readFileSync(join(lockPath, 'owner.json'), 'utf8'));
  } catch {
    return null;
  }
}

function sameDirectory(left, right) {
  if (!left || !right) return false;
  if (left.ino && right.ino) return left.dev === right.dev && left.ino === right.ino;
  return left.birthtimeMs === right.birthtimeMs && left.mtimeMs === right.mtimeMs;
}

function ownerMatches(left, right) {
  if (!left || !right) return left === right;
  if (typeof left.generation === 'string' || typeof right.generation === 'string') {
    return Number(left.pid) === Number(right.pid) &&
      left.generation === right.generation;
  }
  // Locks from older Claudex releases had no generation. Include startedAt so
  // a recycled PID cannot make a changed legacy owner look identical.
  return Number(left.pid) === Number(right.pid) && left.startedAt === right.startedAt;
}

function restoreChangedLock(quarantine, lockPath) {
  try {
    renameSync(quarantine, lockPath);
    return true;
  } catch {
    // Another contender may already own the canonical path. Preserve the
    // quarantined generation instead of deleting a lock we did not observe.
    return false;
  }
}

function reclaimIntentDirectory(lockPath) {
  return `${lockPath}.reclaim-intents`;
}

function publishReclaimIntent(lockPath, generation, timestamp) {
  const directory = reclaimIntentDirectory(lockPath);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const intentPath = join(directory, `${process.pid}.${generation}.json`);
  const intent = { pid: process.pid, generation, startedAt: new Date(timestamp).toISOString() };
  writeFileSync(intentPath, `${JSON.stringify(intent)}\n`, { flag: 'wx', mode: 0o600 });
  return intentPath;
}

function activeReclaimIntentCount(lockPath, { isProcessAlive, now, staleGraceMs }) {
  const directory = reclaimIntentDirectory(lockPath);
  let entries;
  try {
    entries = readdirSync(directory);
  } catch {
    return 0;
  }

  let active = 0;
  for (const entry of entries) {
    const intentPath = join(directory, entry);
    let age;
    try {
      age = now() - statSync(intentPath).mtimeMs;
    } catch {
      // The entry disappeared while it was being listed.
      continue;
    }
    let intent;
    try { intent = JSON.parse(readFileSync(intentPath, 'utf8')); } catch {}
    // The PID prefix lets a later process recover an intent whose writer died
    // partway through publication. Until that PID is known dead, unreadable
    // state is active rather than being ignored.
    const filenamePid = Number(entry.split('.', 1)[0]);
    const intentPid = Number.isInteger(Number(intent?.pid)) ? Number(intent.pid) : filenamePid;
    if (age >= staleGraceMs && !isProcessAlive(intentPid)) {
      try { unlinkSync(intentPath); } catch { active += 1; }
    } else {
      active += 1;
    }
  }
  return active;
}

export function acquireSetupLock(lockPath, {
  timeoutMs = 120_000,
  staleGraceMs = 2_000,
  pollMs = 100,
  shouldContinue = () => true,
  isProcessAlive = defaultProcessIsAlive,
  sleep = defaultSleep,
  now = () => Date.now(),
  generation = randomBytes(16).toString('hex'),
  beforeOwnerWrite = () => {},
  beforeReclaimRename = () => {},
  whileWaitingForReclaimers = () => {},
} = {}) {
  const deadline = now() + timeoutMs;
  while (now() < deadline) {
    let created = false;
    try {
      mkdirSync(lockPath, { mode: 0o700 });
      created = true;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
    }
    if (created) {
      const owner = { pid: process.pid, generation, startedAt: new Date(now()).toISOString() };
      try {
        beforeOwnerWrite(owner);
        writeFileSync(join(lockPath, 'owner.json'), `${JSON.stringify(owner)}\n`, { flag: 'wx', mode: 0o600 });
      } catch (error) {
        // A stale observer can move a newly created directory before owner
        // publication. Never overwrite the generation another contender may
        // have published at the canonical path while it was absent.
        if (error?.code !== 'ENOENT' && error?.code !== 'EEXIST') throw error;
        continue;
      }
      // A stale observer can move the directory between mkdir and publication.
      // Only proceed when the generation is still visible at the canonical path
      // and every observer that started before this owner has withdrawn its
      // reclaim intent. An observer that starts after this check will see this
      // live PID and cannot classify the owner as stale.
      while (now() < deadline && ownerMatches(readOwner(lockPath), owner)) {
        const activeIntents = activeReclaimIntentCount(lockPath, {
          isProcessAlive,
          now,
          staleGraceMs,
        });
        if (activeIntents === 0) return generation;
        whileWaitingForReclaimers({ owner, activeIntents });
        if (!shouldContinue()) {
          releaseSetupLock(lockPath, generation, { now });
          return null;
        }
        sleep(pollMs);
      }
    }

    // Publish before observing the candidate. A replacement owner therefore
    // waits until this observation has either completed or been abandoned.
    // This closes the three-contender race where a delayed stale observer moves
    // a fresh owner and cannot restore it because another owner took canonical.
    let intentPath;
    try {
      intentPath = publishReclaimIntent(lockPath, generation, now());
      const observed = readOwner(lockPath);
      const observedStat = statSync(lockPath);
      const age = now() - observedStat.mtimeMs;
      if (age >= staleGraceMs && !isProcessAlive(Number(observed?.pid))) {
        const quarantine = `${lockPath}.stale.${process.pid}.${generation}.${now()}`;
        beforeReclaimRename(observed);
        renameSync(lockPath, quarantine);
        const moved = readOwner(quarantine);
        const movedStat = statSync(quarantine);
        if (sameDirectory(movedStat, observedStat) && ownerMatches(moved, observed)) {
          rmSync(quarantine, { recursive: true, force: true });
          continue;
        }
        restoreChangedLock(quarantine, lockPath);
      }
    } catch {
      // Another waiter changed the observed lock. Re-read it on the next pass.
    } finally {
      if (intentPath) {
        try { unlinkSync(intentPath); } catch {}
      }
    }
    if (!shouldContinue()) return null;
    sleep(pollMs);
  }
  return null;
}

export function releaseSetupLock(lockPath, generation, {
  now = () => Date.now(),
  beforeReleaseRename = () => {},
} = {}) {
  const observed = readOwner(lockPath);
  const expected = { pid: process.pid, generation };
  if (!ownerMatches(observed, expected)) return false;

  const quarantine = `${lockPath}.release.${process.pid}.${generation}.${now()}`;
  try {
    beforeReleaseRename(observed);
    renameSync(lockPath, quarantine);
    const moved = readOwner(quarantine);
    if (!ownerMatches(moved, expected)) {
      restoreChangedLock(quarantine, lockPath);
      return false;
    }
    rmSync(quarantine, { recursive: true, force: true });
    return true;
  } catch {
    return false;
  }
}
