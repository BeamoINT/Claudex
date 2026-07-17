#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const launcher = fs.readFileSync(path.join(root, 'claudex.ps1'), 'utf8');
const auth = fs.readFileSync(path.join(root, 'codex-session.ps1'), 'utf8');
const suite = fs.readFileSync(path.join(root, 'test.ps1'), 'utf8');

assert.match(launcher, /ClaudexInternalProxyWatchParentIdentity/, 'proxy watcher receives launcher start identity');
assert.match(launcher, /Get-ManagedBackgroundRegistryState/, 'proxy watcher reads managed agent registry');
assert.match(launcher, /Test-WatchParentCurrent/, 'proxy watcher rejects reused parent PID');
assert.match(launcher, /-not \$backgroundLaunch -and \$authWatcher/, 'background launch does not stop auth watcher');
assert.match(launcher, /-not \$backgroundLaunch -and \$proxyWatcher/, 'background launch does not stop proxy watcher');
assert.match(auth, /\[string\] \$ParentProcessIdentity/, 'auth watcher receives launcher start identity');
assert.match(auth, /\[switch\] \$BackgroundWatch/, 'auth watcher receives background lifecycle mode');
assert.match(suite, /ParentProcessIdentity', '0'/, 'Windows behavior test forces auth parent identity mismatch');
assert.match(suite, /ClaudexInternalProxyWatchParentProcessId'[\s\S]*\$PID, '0', '1'/, 'Windows behavior test forces proxy parent identity mismatch');
assert.match(auth, /claude\.Source agents --json/, 'auth watcher reads managed agent registry');
for (const source of [launcher, auth]) {
  assert.match(source, /CLAUDEX_PROXY_TOKEN/, 'registry boundary explicitly handles proxy bearer');
  assert.match(source, /CLAUDE_CODE_OAUTH_TOKEN/, 'registry boundary explicitly handles OAuth bearer');
}
for (const [source, label] of [[launcher, 'proxy'], [auth, 'auth']]) {
  const registryStart = source.indexOf('function Get-ManagedBackgroundRegistryState');
  assert.notEqual(registryStart, -1, `${label} watcher is missing managed registry logic`);
  const registryEnd = source.indexOf('\n}', registryStart);
  assert.notEqual(registryEnd, -1, `${label} watcher registry function is unterminated`);
  const registry = source.slice(registryStart, registryEnd + 2);
  assert.doesNotMatch(registry, /\.kind|\['kind'\]/, `${label} registry must not require an undocumented kind field`);
  assert.match(registry, /Count -eq 0/, `${label} registry recognizes an empty array across PowerShell JSON versions`);
  assert.match(registry, /return 'active'/, `${label} registry treats a valid nonempty session array as active`);
  for (const family of [
    'CLAUDEX_PROXY_TOKEN', 'CLAUDEX_PROXY_URL', 'CLAUDEX_PROXY_CONFIG', 'CLAUDEX_PROXY_BIN',
    'ANTHROPIC_BEDROCK_MANTLE_BASE_URL', 'ANTHROPIC_VERTEX_PROJECT_ID',
    'ANTHROPIC_FOUNDRY_API_KEY', 'ANTHROPIC_CUSTOM_HEADERS', 'ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDEX_CODEX_AUTH_FILE',
  ]) {
    assert(registry.includes(family) || registry.includes('$sessionEnvironmentNames'),
      `${label} registry query does not scrub ${family}`);
  }
  assert.match(registry, /finally\s*\{/, `${label} registry environment is not restored in finally`);
}
assert.match(suite, /Windows detached auth watcher survives launcher exit/, 'Windows suite exercises detached auth lifecycle');
assert.match(suite, /Windows detached proxy watcher survives launcher exit/, 'Windows suite exercises detached proxy lifecycle');
assert.match(suite, /Windows detached watchers exit after registry is stably empty/, 'Windows suite exercises registry completion');
assert.match(suite, /\[\{\"id\":\"managed-bg-test\",\"state\":\"working\"\}\]/, 'Windows fixture uses the documented id and state schema without kind');
assert.match(suite, /Windows invalid registry root is not treated as empty/, 'Windows suite keeps watchers alive on an invalid registry root');
assert.match(suite, /direct watcher registry query also scrubs inherited private families/, 'Windows suite injects and rejects private watcher environment');
assert.match(suite, /testSuiteTimeoutSeconds = 600/, 'Windows CI suite has a bounded internal watchdog');
assert.match(suite, /test\.ps1 watchdog timed out after/, 'Windows CI watchdog reports the active test stage');
assert.match(suite, /Stop-Process -Id \$PID -Force/, 'Windows CI watchdog terminates a hung test host');
assert.match(suite, /testSuiteWatchdog\.Kill\(\)/, 'Windows CI suite cleans up its watchdog after success or failure');
const modelLockFixtureStart = suite.indexOf("Write-TestStage 'starting model lock regressions'");
const modelLockFixtureEnd = suite.indexOf("Write-TestStage 'model lock regressions passed'", modelLockFixtureStart);
assert.notEqual(modelLockFixtureStart, -1, 'Windows suite is missing model lock regressions');
assert.notEqual(modelLockFixtureEnd, -1, 'Windows model lock regressions are missing their completion boundary');
const modelLockFixture = suite.slice(modelLockFixtureStart, modelLockFixtureEnd);
assert.doesNotMatch(modelLockFixture, /\.WaitForExit\(10000\)/,
  'Windows model lock races must use the common bounded process wait instead of a shorter host timing threshold');
const updateFixtureStart = suite.indexOf("Write-TestStage 'starting automatic update regressions'");
const updateFixtureEnd = suite.indexOf("Write-TestStage 'automatic update regressions passed'", updateFixtureStart);
assert.notEqual(updateFixtureStart, -1, 'Windows suite is missing automatic update regressions');
assert.notEqual(updateFixtureEnd, -1, 'Windows automatic update regressions are missing their completion boundary');
const updateFixture = suite.slice(updateFixtureStart, updateFixtureEnd);
assert.doesNotMatch(updateFixture, /& \$shellPath[\s\S]*--version \| Out-Null/,
  'detached updater regressions must not wait on a native descendant output pipeline');
assert.equal((updateFixture.match(/Start-TrackedTestProcess \$shellPath \$updateLauncherArguments/g) || []).length, 4,
  'each detached updater launcher must use a bounded direct process handle');
assert.match(updateFixture, /WriteAllText\(\$updateRelease,[\s\S]*Join-Path \$updateDirectory 'last-success'[\s\S]*Remove-TestPathWithRetry \$updateDirectory/,
  'automatic update cleanup must release and drain a blocked detached worker before deleting its logs');
assert.match(suite, /Remove-TestPathWithRetry \$temporary/,
  'Windows suite cleanup must not mask a primary failure with a transient open file handle');

console.log('PowerShell background watcher contract passed');
