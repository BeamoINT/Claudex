#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
const unixUsage = read('usage-limit');
const windowsUsage = read('usage-limit.ps1');
const unixStatus = read('statusline');
const windowsStatus = read('statusline.ps1');

for (const [name, source] of [['Unix', unixUsage], ['Windows', windowsUsage]]) {
  assert.match(source, /generation/, `${name} usage lock records an independent generation nonce`);
  assert.match(source, /quarantine/, `${name} usage lock uses a quarantine acquisition barrier`);
  assert.match(source, /identity/, `${name} usage lock records process start identity`);
  assert.match(source, /HardLink|ln "\$source"/, `${name} usage lock attempts no-clobber hard-link publication`);
  assert.match(source, /CreateNew|set -C/, `${name} usage lock has an exclusive-create fallback`);
  assert.match(source, /Recover-OwnedRefreshGeneration|recover_owned_refresh_generation/, `${name} owner self-recovers its exact nonce`);
  assert.match(source, /Remove-OwnedRefreshGeneration|remove_owned_refresh_generation/, `${name} release removes only its exact nonce`);
  assert.match(source, /LegacyRefreshOwner|legacy_refresh_owner/, `${name} recognizes prior PID-token owners`);
  assert.match(source, /movedGeneration|moved_generation/, `${name} validates the moved generation after quarantine rename`);
  assert.match(source, /movedOwner|moved_owner_nonce/, `${name} validates the moved owner after quarantine rename`);
  assert.match(source, /RefreshLockDirectoryIdentity|refresh_lock_directory_identity/, `${name} validates stable directory identity during publication`);
  assert.match(source, /identity.*@.*nonce|owner_identity.*generation_nonce/, `${name} publishes a pre-generation compatible PID token owner`);
}

assert.doesNotMatch(unixStatus, /--lock-held|refresh\.lock\.quarantine/, 'Unix status line delegates all lock mutation');
assert.doesNotMatch(windowsStatus, /-LockHeld|refresh\.lock\.quarantine/, 'Windows status line delegates all lock mutation');
assert.match(unixStatus, /"\$helper" --refresh-cache/, 'Unix status line starts the self-locking helper');
assert.match(windowsStatus, /'-RefreshCache'/, 'Windows status line starts the self-locking helper');

console.log('usage lock parity tests passed');
