'use strict';

const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'codex-session.ps1'), 'utf8');

for (const required of [
  'function Get-LockGenerationNonce',
  'function Get-LockDirectoryIdentity',
  'function Get-LegacyLockOwner',
  'function Test-LegacyLockOwnerCurrent',
  'function Remove-LegacyLockGeneration',
  'function Remove-LegacyLockBarrier',
  'function Withdraw-LegacyLockGeneration',
  'function Withdraw-LegacyBarrierGeneration',
  'function Get-LockBarriers',
  'function Publish-LockFile',
  '[IO.FileMode]::CreateNew',
  'New-Item -ItemType HardLink',
  'function Remove-OwnedLockGeneration',
  'function Recover-OwnedLockGeneration',
  'function Test-OwnedLockOwnerCurrent',
  'StartTime.ToUniversalTime().Ticks',
  'GetFileInformationByHandle',
  'FileIndexHigh.ToString("x8")',
  '/d /s /v:off /c "call ',
  'pid=$PID`nidentity=$identity`nnonce=$nonce',
  "'.quarantine.'",
  "Invoke-LockTestPause 'AFTER_MKDIR'",
  "Invoke-LockTestPause 'BEFORE_RENAME'",
  "Invoke-LockTestPause 'AFTER_RENAME'",
  'Get-LockBarriers $LockDirectory).Count -gt 0',
  'Recover-LockBarriers $LockDirectory $LegacyOwnerlessSeconds $LegacyOwnerSeconds',
  'Acquire-OwnedLock $sessionSyncLock 250 20 2 60',
  "$createdDirectoryIdentity = Get-LockDirectoryIdentity $LockDirectory",
  "throw 'lock directory changed before generation publication'",
  "throw 'lock directory changed before owner publication'",
  'Recover-OwnedLockGeneration $LockDirectory $nonce $createdDirectoryIdentity',
  '$createdDirectoryIdentity -and (Get-LockDirectoryIdentity $LockDirectory) -eq $createdDirectoryIdentity',
  '$age -ge $LegacyOwnerSeconds -and -not (Test-LegacyLockOwnerCurrent $ownerFile)',
  'if ($movedNonce -or $movedLegacyOwner)',
  "Remove-Item -LiteralPath (Join-Path $quarantine 'generation')",
  'Withdraw-LegacyBarrierGeneration $barrier $legacyOwner $generationNonce',
  'Withdraw-LegacyLockGeneration $LockDirectory $legacyOwner $legacyGeneration',
  '[Claudex.CredentialSyncCleanup]::TrackLock($sessionSyncLock, $nonce)',
  'private static void ReleaseExactGeneration',
  'if (!String.Equals(ReadNonce(path), nonce, StringComparison.Ordinal)) return;',
  'if (String.Equals(movedNonce, nonce, StringComparison.Ordinal))',
  'if (!Directory.Exists(path)) Directory.Move(quarantine, path)',
]) assert(source.includes(required), `missing generation-lock contract: ${required}`);

assert(!source.includes('Directory.Delete(quarantine, true)'),
  'process-exit cleanup can recursively delete a replacement generation');
assert(!source.includes('owner.EndsWith(" " + lockToken'),
  'legacy PID/token suffix cleanup remains reachable');

const acquireSource = source.slice(
  source.indexOf('function Acquire-OwnedLock'),
  source.indexOf('function Release-OwnedLock'),
);
assert((acquireSource.match(/Get-LockDirectoryIdentity \$LockDirectory/g) || []).length >= 7,
  'PowerShell acquisition does not revalidate directory identity at every publication boundary');
for (const [before, after] of [
  ['$createdDirectoryIdentity = Get-LockDirectoryIdentity $LockDirectory', "Invoke-LockTestPause 'AFTER_MKDIR'"],
  ["throw 'lock directory changed before generation publication'", 'Publish-LockFile $generationTemporary'],
  ["throw 'lock directory changed before owner publication'", 'Publish-LockFile $ownerTemporary'],
  ['$currentDirectoryIdentity = Get-LockDirectoryIdentity $LockDirectory', 'Recover-OwnedLockGeneration $LockDirectory $nonce'],
]) assert(acquireSource.indexOf(before) < acquireSource.indexOf(after),
  `directory identity check is ordered incorrectly: ${before}`);

const parseLegacyOwner = text => {
  const owner = text.split(/\r?\n/, 1)[0].trim();
  return /^\d+\s+\S+$/.test(owner) ? owner : '';
};
const legacyOwnerIsCurrent = (text, livePids) => {
  const owner = parseLegacyOwner(text);
  return owner !== '' && livePids.has(Number(owner.split(/\s+/, 1)[0]));
};
assert.equal(parseLegacyOwner('123 old-token\n'), '123 old-token');
assert.equal(parseLegacyOwner('pid=123\nnonce=new'), '');
assert(legacyOwnerIsCurrent('123 old-token\n', new Set([123])),
  'live legacy PID/token owner was treated as ownerless');
assert(!legacyOwnerIsCurrent('999 old-token\n', new Set([123])),
  'dead legacy PID/token owner was treated as live');

// Stable directory identity closes the absent-owner mixed-version window. Keep
// A's original inode alive while old B installs an empty replacement, making
// the mismatch deterministic; A must neither publish into nor clean up B.
const identityTemp = fs.mkdtempSync(path.join(os.tmpdir(), 'claudex-ps-directory-identity-'));
const identityLock = path.join(identityTemp, 'lock');
const displacedA = path.join(identityTemp, 'displaced-a');
fs.mkdirSync(identityLock);
const directoryIdentity = directory => {
  const stat = fs.statSync(directory, { bigint: true });
  return `${stat.dev}:${stat.ino}`;
};
const createdAIdentity = directoryIdentity(identityLock);
fs.renameSync(identityLock, displacedA);
fs.mkdirSync(identityLock);
const replacementBIdentity = directoryIdentity(identityLock);
assert.notEqual(replacementBIdentity, createdAIdentity, 'test did not create a distinct B directory');
const aStillOwnsDirectory = directoryIdentity(identityLock) === createdAIdentity;
if (aStillOwnsDirectory) {
  fs.writeFileSync(path.join(identityLock, 'generation'), 'A\n');
} else {
  // Identity-gated catch cleanup deliberately leaves the empty replacement.
  assert.deepEqual(fs.readdirSync(identityLock), []);
}
assert.deepEqual(fs.readdirSync(identityLock), [], 'A published into or removed empty B replacement');
fs.writeFileSync(path.join(identityLock, 'owner'), '123 old-B\n');
assert.equal(parseLegacyOwner(fs.readFileSync(path.join(identityLock, 'owner'), 'utf8')), '123 old-B');
assert.equal(directoryIdentity(identityLock), replacementBIdentity, 'A cleanup replaced B directory identity');
fs.rmSync(identityTemp, { recursive: true, force: true });

// Executable model of the PowerShell/C# moved-generation validation: even when
// canonical ownership changes after the stale precheck, cleanup restores and
// never deletes the replacement it actually moved.
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'claudex-ps-lock-model-'));
const lock = path.join(temp, '.codex-session-sync.lock');
const writeGeneration = (directory, nonce) => {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'generation'), `${nonce}\n`);
  fs.writeFileSync(path.join(directory, 'owner'), `pid=1\nidentity=start\nnonce=${nonce}\n`);
};
const readNonce = directory => {
  try { return fs.readFileSync(path.join(directory, 'generation'), 'utf8').trim(); }
  catch { return ''; }
};
const releaseExact = (expected, beforeMove) => {
  if (readNonce(lock) !== expected) return;
  if (beforeMove) beforeMove();
  const quarantine = `${lock}.quarantine.exit.model`;
  fs.renameSync(lock, quarantine);
  if (readNonce(quarantine) === expected) {
    fs.rmSync(quarantine, { recursive: true });
  } else if (!fs.existsSync(lock)) {
    fs.renameSync(quarantine, lock);
  }
};

writeGeneration(lock, 'A');
releaseExact('A', () => {
  fs.rmSync(lock, { recursive: true });
  writeGeneration(lock, 'B');
});
assert.equal(readNonce(lock), 'B', 'exit cleanup deleted or failed to restore replacement B');

releaseExact('A');
assert.equal(readNonce(lock), 'B', 'obsolete A release deleted current B');

// The mixed-version remover also validates what it actually moved. A legacy
// owner replacement between the precheck and rename must be restored intact.
fs.rmSync(lock, { recursive: true, force: true });
const writeLegacy = (directory, owner) => {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'owner'), `${owner}\n`);
};
const readLegacy = directory => {
  try { return parseLegacyOwner(fs.readFileSync(path.join(directory, 'owner'), 'utf8')); }
  catch { return ''; }
};
const releaseLegacyExact = (expected, beforeMove) => {
  if (readLegacy(lock) !== expected) return;
  if (beforeMove) beforeMove();
  const quarantine = `${lock}.quarantine.legacy.model`;
  fs.renameSync(lock, quarantine);
  if (readLegacy(quarantine) === expected) fs.rmSync(quarantine, { recursive: true });
  else if (!fs.existsSync(lock)) fs.renameSync(quarantine, lock);
};
writeLegacy(lock, '123 old-A');
releaseLegacyExact('123 old-A', () => {
  fs.rmSync(lock, { recursive: true });
  writeLegacy(lock, '456 old-B');
});
assert.equal(readLegacy(lock), '456 old-B', 'legacy cleanup deleted replacement owner B');

// New A may successfully publish only its generation after old B replaces the
// mkdir result. Failure cleanup strips A's partial generation, but restores B.
fs.writeFileSync(path.join(lock, 'generation'), 'new-A\n');
const partialQuarantine = `${lock}.quarantine.partial.model`;
fs.renameSync(lock, partialQuarantine);
assert.equal(readNonce(partialQuarantine), 'new-A');
assert.equal(readLegacy(partialQuarantine), '456 old-B');
fs.rmSync(path.join(partialQuarantine, 'generation'));
fs.renameSync(partialQuarantine, lock);
assert.equal(readLegacy(lock), '456 old-B', 'partial publication cleanup deleted old B');
assert.equal(readNonce(lock), '', 'partial publication cleanup left A generation on old B');

// A quarantined old owner dominates a foreign injected generation. Sanitize
// it while the PID is live; once that PID is dead, ordinary stale recovery can
// remove the exact old owner instead of restoring the mixed barrier forever.
fs.rmSync(lock, { recursive: true, force: true });
writeLegacy(lock, '789 old-live-then-dead');
fs.writeFileSync(path.join(lock, 'generation'), 'foreign-new-A\n');
const mixedLivePids = new Set([789]);
assert(legacyOwnerIsCurrent(fs.readFileSync(path.join(lock, 'owner'), 'utf8'), mixedLivePids));
fs.rmSync(path.join(lock, 'generation'));
assert.equal(readLegacy(lock), '789 old-live-then-dead');
assert.equal(readNonce(lock), '');
mixedLivePids.delete(789);
assert(!legacyOwnerIsCurrent(fs.readFileSync(path.join(lock, 'owner'), 'utf8'), mixedLivePids));
fs.rmSync(lock, { recursive: true });
assert(!fs.existsSync(lock), 'dead sanitized legacy owner remained unreclaimable');
fs.rmSync(temp, { recursive: true, force: true });

console.log('PowerShell Codex session generation-lock source checks passed');
