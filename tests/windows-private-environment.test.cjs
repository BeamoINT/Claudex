'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.resolve(__dirname, '..', 'claudex.ps1'), 'utf8');

function section(start, end) {
  const first = source.indexOf(start);
  assert.notEqual(first, -1, `missing source section: ${start}`);
  const last = source.indexOf(end, first + start.length);
  assert.notEqual(last, -1, `missing source terminator: ${end}`);
  return source.slice(first, last);
}

const boundary = section('function Invoke-WithoutPrivateManagedEnvironment', 'function Resolve-HarnessCommand');
assert(boundary.includes('$sessionEnvironmentNames'), 'private child boundary must cover every managed session variable');
assert(boundary.includes('Remove-Item -LiteralPath "Env:$environmentName"'), 'private child boundary does not scrub inherited variables');
assert.match(boundary, /finally\s*\{/, 'private child boundary does not restore state in finally');

const restore = section('function Restore-ClaudexSessionEnvironment', '$utf8 =');
assert(restore.includes('$previousConfigEnvironment'), 'config-imported environment is not restored');
assert(source.includes('$previousConfigEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, \'Process\')'),
  'config import does not capture prior caller state');

for (const [start, end, label] of [
  ["if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq 'self-update')", "if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -in @('--login'", 'explicit self-update'],
  ["if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -in @('--login'", '$earlyRuntimeBypass =', 'authentication'],
  ["if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq 'skills')", '$stateFile =', 'skills'],
  ['function Start-ClaudeUpdateCheck', 'function Start-ClaudexUpdateCheck', 'native Claude update'],
  ['function Start-ClaudexUpdateCheck', 'function Model-Name', 'Claudex update'],
  ["if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--usage-limit')", '$startModel =', 'usage/account'],
]) {
  const route = section(start, end);
  assert(route.includes('Invoke-WithoutPrivateManagedEnvironment'), `${label} route bypasses the private environment boundary`);
}

for (const earlyExit of [
  'exit $LASTEXITCODE',
  'if ($?) { exit 0 }',
  'if ($?) { exit 0 } else { exit 1 }',
]) {
  assert(!source.includes(earlyExit), `early route can bypass parent restoration: ${earlyExit}`);
}

console.log('Windows private environment boundary source checks passed');
