'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'install.ps1'), 'utf8');

function includes(fragment, message) {
  assert(source.includes(fragment), message);
}

function section(start, end) {
  const startIndex = source.indexOf(start);
  assert.notEqual(startIndex, -1, `missing source section: ${start}`);
  const endIndex = source.indexOf(end, startIndex + start.length);
  assert.notEqual(endIndex, -1, `missing source section terminator: ${end}`);
  return source.slice(startIndex, endIndex);
}

const acl = section('function Protect-PrivatePath', 'function Ensure-PrivateDirectory');
assert.match(acl, /SetAccessRuleProtection\(\$true, \$false\)/,
  'private paths must discard inherited ACL entries');
for (const identity of ["'S-1-5-18'", "'S-1-5-32-544'", '$currentSid.Value']) {
  assert(acl.includes(identity), `private ACL is missing ${identity}`);
}
assert.match(acl, /FileSystemRights\]::FullControl/,
  'private ACL principals must retain full control');
assert.match(acl, /Set-Acl -LiteralPath \$Path -AclObject \$security/,
  'private ACL must be applied to the literal path');

for (const directory of [
  '$configDir',
  '$managedBinDir',
  '$authDir',
  '$runDir',
  '$usageCacheDir',
  '$runtimeAuthDir',
]) {
  includes(`Ensure-PrivateDirectory ${directory}`,
    `installer does not protect private directory ${directory}`);
}

const binPolicy = section('if ($packageManagedInstall) {', 'Ensure-PrivateDirectory $configDir');
assert(binPolicy.includes('[IO.Directory]::CreateDirectory($binDir) | Out-Null'),
  'package-managed installs no longer preserve package-manager bin-directory ACLs');
assert(binPolicy.includes('Ensure-PrivateDirectory $binDir'),
  'direct/archive installs leave the launcher parent vulnerable to DeleteChild replacement');
assert(binPolicy.includes('direct/archive installs require a private launcher directory'),
  'an unsafe custom direct-install bin directory does not fail with actionable guidance');
assert(binPolicy.indexOf('[IO.Directory]::CreateDirectory($binDir) | Out-Null') <
  binPolicy.indexOf('Ensure-PrivateDirectory $binDir'),
  'bin ACL branches are not ordered as package-managed preserve, direct-install protect');

const existingRepair = section('foreach ($existingPrivateManagedPath in $installManagedPaths)', 'Acquire-InstallLock');
assert(existingRepair.includes('Protect-PrivatePath $existingPrivateManagedPath $false'),
  'an upgrade does not repair ACLs on existing managed files before reading or backing them up');

const atomicWrite = section('function Write-TextAtomic', 'function ConvertFrom-ClaudexEnvValue');
for (const operation of [
  'Ensure-PrivateDirectory $parent',
  'Protect-PrivatePath $temporary $false',
  'Protect-PrivatePath $Path $false',
]) {
  assert(atomicWrite.includes(operation), `atomic publication is missing: ${operation}`);
}

for (const publication of [
  'Write-TextAtomic $proxyConfigTarget $proxyConfig',
  'Write-TextAtomic $envFile $environmentText',
  'Write-TextAtomic $settingsTarget',
  'Write-TextAtomic $installReceiptTarget',
]) {
  includes(publication, `private publication does not use the protected atomic writer: ${publication}`);
}

const installedFiles = section('foreach ($privateInstalledFile in @(', '$settings = Get-Content');
for (const target of [
  '$launcherTarget',
  '$cmdTarget',
  '$statuslineTarget',
  '$usageLimitTarget',
  '$codexSessionTarget',
  '$preloadTarget',
  '$skillBridgeTarget',
  '$selfUpdateTarget',
  '$usageSkillTarget',
]) {
  assert(installedFiles.includes(target), `installed interpreted/runtime file is not protected: ${target}`);
}
assert(installedFiles.includes('Protect-PrivatePath $privateInstalledFile $false'),
  'installed files are listed without applying the private ACL');

includes('Protect-PrivatePath $managedProxy $false',
  'managed proxy executable is not protected');
includes('Protect-PrivatePath $managedNodeDir $true',
  'managed Node runtime directory is not protected');
includes('Ensure-PrivateDirectory $temporary',
  'installer-owned download/extraction directories are not protected');
includes('Ensure-PrivateDirectory $installerDirectory',
  'downloaded Claude installer is not staged below a protected directory');

const download = section('function Receive-FileWithRetry', 'function Write-TextAtomic');
assert(download.includes('Protect-PrivatePath $Destination $false'),
  'downloaded code is not protected before validation or execution');

const transaction = section('function Start-InstallTransaction', 'function Restore-InstallTransactionEntries');
assert(transaction.includes('Ensure-PrivateDirectory $rootPath') &&
  transaction.includes('Ensure-PrivateDirectory $backupPath') &&
  transaction.includes('Protect-PrivatePath $backup $false'),
'installer rollback copies can inherit broad ACLs');

assert(!source.includes('$receiptTemporary'),
  'install receipt still uses an unprotected hand-written temporary');

console.log('Windows installer private-state source checks passed');
