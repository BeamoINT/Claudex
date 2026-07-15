$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = $PSScriptRoot
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('claudex-tests-' + [guid]::NewGuid().ToString('N'))
$testHome = Join-Path $temporary 'home'
$testConfig = Join-Path $testHome '.config\claudex'
$fakeBin = Join-Path $temporary 'bin'
$utf8 = New-Object Text.UTF8Encoding($false)
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "assertion failed: $Message" }
}

try {
    [IO.Directory]::CreateDirectory($testConfig) | Out-Null
    [IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $testAuthDir = Join-Path $testHome '.cli-proxy-api'
    [IO.Directory]::CreateDirectory($testAuthDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $testConfig 'env'), "CLAUDEX_PROXY_TOKEN=test-token`nCLAUDEX_CODEX_AUTH_DIR=$testAuthDir`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $testAuthDir 'codex-test.json'), '{"type":"codex","access_token":"secret-access-token","refresh_token":"secret-refresh-token","account_id":"account-test","email":"private@example.com"}', $utf8)
    Copy-Item -LiteralPath (Join-Path $root 'settings.json') -Destination (Join-Path $testConfig 'settings.json')
    Copy-Item -LiteralPath (Join-Path $root 'preload.cjs') -Destination (Join-Path $testConfig 'preload.cjs')
    Copy-Item -LiteralPath (Join-Path $root 'usage-limit.ps1') -Destination (Join-Path $testConfig 'usage-limit.ps1')

    if ($isWindowsPlatform) {
        $fakeCurl = Join-Path $fakeBin 'curl.cmd'
        [IO.File]::WriteAllText($fakeCurl, @'
@echo off
echo %* | findstr /c:"test-token" /c:"secret-access-token" >nul
if not errorlevel 1 exit /b 90
echo %* | findstr /c:"/wham/usage" >nul
if not errorlevel 1 (
  if "%FAKE_USAGE_FAIL%"=="1" exit /b 22
  echo {"user_id":"private-user","account_id":"private-account","email":"private@example.com","plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":565127,"reset_at":1784666240},"secondary_window":null},"code_review_rate_limit":null,"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":1784705933},"secondary_window":null}}],"credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"rate_limit_reset_credits":{"available_count":1}}
  exit /b 0
)
echo {"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'claude.cmd'), @'
@echo off
if "%~1"=="--version" (
  echo 2.1.210 ^(test^)
  exit /b 0
)
echo AUTO=%CLAUDE_CODE_AUTO_MODE_MODEL%
echo BG=%CLAUDE_CODE_BG_CLASSIFIER_MODEL%
echo SUBAGENT=%CLAUDE_CODE_SUBAGENT_MODEL%
echo CONCURRENCY=%CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY%
echo RETRIES=%CLAUDE_CODE_MAX_RETRIES%
echo CONTEXT=%CLAUDE_CODE_MAX_CONTEXT_TOKENS%
echo COMPACT=%CLAUDE_CODE_AUTO_COMPACT_WINDOW%
echo NO_FLICKER=%CLAUDE_CODE_NO_FLICKER%
echo ACCESSIBILITY=%CLAUDE_CODE_ACCESSIBILITY%
echo OPUS=%ANTHROPIC_DEFAULT_OPUS_MODEL%
echo OPUS_NAME=%ANTHROPIC_DEFAULT_OPUS_MODEL_NAME%
echo POWERSHELL_TOOL=%CLAUDE_CODE_USE_POWERSHELL_TOOL%
echo ARGS=%*
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'cliproxyapi.cmd'), @'
@echo off
echo CLIProxyAPI test
echo extra version detail
exit /b 1
'@, $utf8)
    } else {
        $fakeCurl = Join-Path $fakeBin 'curl.exe'
        [IO.File]::WriteAllText($fakeCurl, @'
#!/bin/sh
for argument in "$@"; do
  case "$argument" in
    *test-token*|*secret-access-token*) printf '%s\n' 'credential leaked into curl arguments' >&2; exit 90 ;;
    */wham/usage*) [ "${FAKE_USAGE_FAIL:-0}" != 1 ] || exit 22; printf '%s\n' '{"user_id":"private-user","account_id":"private-account","email":"private@example.com","plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":565127,"reset_at":1784666240},"secondary_window":null},"code_review_rate_limit":null,"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":1784705933},"secondary_window":null}}],"credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"rate_limit_reset_credits":{"available_count":1}}'; exit 0 ;;
  esac
done
printf '%s\n' '{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}'
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'claude'), @'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' '2.1.210 (test)'
  exit 0
fi
printf '%s\n' "AUTO=${CLAUDE_CODE_AUTO_MODE_MODEL}"
printf '%s\n' "BG=${CLAUDE_CODE_BG_CLASSIFIER_MODEL}"
printf '%s\n' "SUBAGENT=${CLAUDE_CODE_SUBAGENT_MODEL}"
printf '%s\n' "CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY}"
printf '%s\n' "RETRIES=${CLAUDE_CODE_MAX_RETRIES}"
printf '%s\n' "CONTEXT=${CLAUDE_CODE_MAX_CONTEXT_TOKENS}"
printf '%s\n' "COMPACT=${CLAUDE_CODE_AUTO_COMPACT_WINDOW}"
printf '%s\n' "NO_FLICKER=${CLAUDE_CODE_NO_FLICKER}"
printf '%s\n' "ACCESSIBILITY=${CLAUDE_CODE_ACCESSIBILITY}"
printf '%s\n' "OPUS=${ANTHROPIC_DEFAULT_OPUS_MODEL}"
printf '%s\n' "OPUS_NAME=${ANTHROPIC_DEFAULT_OPUS_MODEL_NAME}"
printf '%s\n' "POWERSHELL_TOOL=${CLAUDE_CODE_USE_POWERSHELL_TOOL}"
printf 'ARGS='; printf ' %s' "$@"; printf '\n'
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'cliproxyapi'), @'
#!/bin/sh
printf '%s\n' 'CLIProxyAPI test'
printf '%s\n' 'extra version detail'
exit 1
'@, $utf8)
        & chmod +x $fakeCurl (Join-Path $fakeBin 'claude') (Join-Path $fakeBin 'cliproxyapi')
        if ($LASTEXITCODE -ne 0) { throw 'failed to make PowerShell test doubles executable' }
    }

    $env:USERPROFILE = $testHome
    $env:CLAUDEX_CONFIG_DIR = $testConfig
    $env:CLAUDEX_CURL_BIN = $fakeCurl
    $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$env:PATH"
    Remove-Item Env:CLAUDEX_PERMISSION_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDEX_AUTO_COMPACT_WINDOW -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDEX_MOUSE_POINTER_SHAPE -ErrorAction SilentlyContinue

    $output = (& (Join-Path $root 'claudex.ps1') --terra test-prompt | Out-String)
    Assert-True ($output.Contains('AUTO=gpt-5.6-luna')) 'auto classifier'
    Assert-True ($output.Contains('BG=gpt-5.6-luna')) 'background classifier'
    Assert-True ($output.Contains('SUBAGENT=gpt-5.6-terra')) 'subagent model'
    Assert-True ($output.Contains('CONCURRENCY=3')) 'tool concurrency'
    Assert-True ($output.Contains('RETRIES=2')) 'bounded retries'
    Assert-True ($output.Contains('CONTEXT=400000')) 'context window'
    Assert-True ($output.Contains('COMPACT=280000')) 'compaction window'
    Assert-True ($output.Contains('NO_FLICKER=1')) 'no-flicker rendering'
    Assert-True ($output.Contains('ACCESSIBILITY=1')) 'native terminal cursor'
    Assert-True ($output.Contains('OPUS=gpt-5.6-sol')) 'single Sol alias'
    Assert-True ($output.Contains('OPUS_NAME=GPT-5.6 Sol')) 'friendly name'
    Assert-True ($output.Contains('POWERSHELL_TOOL=1')) 'native PowerShell tool'
    Assert-True ($output.Contains('--permission-mode auto')) 'auto permissions'
    Assert-True ($output.Contains('--model gpt-5.6-terra')) 'startup model'
    Assert-True ($output.Contains('Do not create a team, spawn or delegate to additional agents')) 'nested agent guard'
    Assert-True ($output.Contains('Do not create, claim, or update entries in the shared task list')) 'subagent task ownership'
    Assert-True ($output.Contains('Before every final answer, call TaskList and reconcile every entry')) 'leader task reconciliation'
    Assert-True ($output.Contains('Never leave stale in_progress tasks after their work is done')) 'stale task guard'
    Assert-True ($output.Contains('"gpt-5-6-terra"')) 'transparent Terra agent name'
    Assert-True ($output.Contains('"gpt-5-6-luna"')) 'transparent Luna agent name'
    Assert-True (-not $output.Contains('"claudex-deep"')) 'legacy deep alias removed'
    Assert-True (-not $output.Contains('"claudex-builder"')) 'legacy builder alias removed'
    Assert-True (-not $output.Contains('"claudex-fast"')) 'legacy fast alias removed'
    Assert-True (-not $output.Contains('"model":"gpt-5.6-sol"')) 'leader model is not delegated'

    $state = Get-Content -LiteralPath (Join-Path $testConfig '.claude.json') -Raw | ConvertFrom-Json
    $stateIds = @($state.additionalModelOptionsCache | ForEach-Object { $_.value })
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-sol' }).Count -eq 1) 'one Sol cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-terra' }).Count -eq 1) 'one Terra cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-luna' }).Count -eq 1) 'one Luna cache entry'

    $doctor = (& (Join-Path $root 'claudex.ps1') --doctor | Out-String)
    Assert-True ($doctor.Contains('CLIProxyAPI: CLIProxyAPI test')) 'proxy version first line'
    Assert-True (-not $doctor.Contains('extra version detail')) 'proxy version extra lines hidden'
    Assert-True ($doctor.Contains('Auto-compact window: 280000 tokens')) 'doctor compaction'
    Assert-True ($doctor.Contains('Task lifecycle: Sol-owned with final-response reconciliation')) 'doctor task lifecycle'
    Assert-True ($doctor.Contains('Context status: session-stabilized')) 'doctor context stabilization'
    Assert-True ($doctor.Contains('Codex usage: status-line refresh every 300s')) 'doctor usage refresh'
    Assert-True ($doctor.Contains('Rendering: no-flicker mode with native terminal cursor')) 'doctor rendering hardening'
    Assert-True ($doctor.Contains('gpt-5.6-terra: advertised')) 'doctor models'

    $usage = (& (Join-Path $root 'claudex.ps1') --usage-limit | Out-String)
    Assert-True ($usage.Contains('Codex usage limits (Pro plan)')) 'usage plan'
    Assert-True ($usage.Contains('Codex 7-day: 18% remaining (82% used)')) 'usage main window'
    Assert-True ($usage.Contains('GPT-5.3-Codex-Spark 7-day: 100% remaining (0% used)')) 'usage additional window'
    Assert-True ($usage.Contains('Rate-limit reset credits: 1')) 'usage reset credits'
    Assert-True (-not $usage.Contains('secret-access-token')) 'usage token redaction'
    Assert-True (-not $usage.Contains('private@example.com')) 'usage identity redaction'
    $usageCache = Get-Content -LiteralPath (Join-Path $testConfig 'usage-cache\limits.json') -Raw | ConvertFrom-Json
    Assert-True ($usageCache.plan_type -eq 'pro') 'usage cache plan'
    Assert-True ($usageCache.rate_limit.primary_window.used_percent -eq 82) 'usage cache window'
    Assert-True ($null -eq $usageCache.PSObject.Properties['account_id']) 'usage cache account redaction'
    Assert-True ($null -eq $usageCache.PSObject.Properties['access_token']) 'usage cache token redaction'

    $env:FAKE_USAGE_FAIL = '1'
    $fallbackUsage = (& (Join-Path $root 'claudex.ps1') --usage-limit 2>&1 | Out-String)
    Remove-Item Env:FAKE_USAGE_FAIL
    Assert-True ($fallbackUsage.Contains('Codex 7-day: 18% remaining (82% used)')) 'usage outage cache fallback'

    $statusJson = '{"session_id":"stable-session","model":{"id":"gpt-5.6-sol"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":42.9,"total_input_tokens":171600,"context_window_size":400000}}'
    $status = ($statusJson | & (Join-Path $root 'statusline.ps1') | Out-String)
    Assert-True ($status.Contains('GPT-5.6 Sol')) 'status model'
    Assert-True ($status.Contains('xhigh effort')) 'status effort'
    Assert-True ($status.Contains('42% context')) 'status context'
    Assert-True ($status.Contains('Codex 7d 18% left')) 'status usage limits'

    $transientJson = '{"session_id":"stable-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":0,"context_window_size":400000,"current_usage":null}}'
    $transientStatus = ($transientJson | & (Join-Path $root 'statusline.ps1') | Out-String)
    Assert-True ($transientStatus.Contains('42% context')) 'transient zero uses session cache'
    Assert-True (-not $transientStatus.Contains('0% context')) 'transient zero is hidden'

    $freshJson = '{"session_id":"fresh-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":0,"context_window_size":400000,"current_usage":null}}'
    $freshStatus = ($freshJson | & (Join-Path $root 'statusline.ps1') | Out-String)
    Assert-True (-not $freshStatus.Contains('% context')) 'fresh zero is omitted'

    $smallJson = '{"session_id":"small-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":100,"context_window_size":400000}}'
    $smallStatus = ($smallJson | & (Join-Path $root 'statusline.ps1') | Out-String)
    Assert-True ($smallStatus.Contains('<1% context')) 'real sub-percent usage is labeled accurately'

    $billingFrame = "GPT-5.6 Sol with high effort$([char]27)[41G$([char]0x00B7)$([char]27)[43GAPI$([char]27)[47GUsage$([char]27)[53GBilling`r"
    $filteredFrame = $billingFrame | node --require (Join-Path $root 'preload.cjs') -e 'process.stdin.pipe(process.stdout)'
    Assert-True (($filteredFrame | Out-String).Contains('GPT-5.6 Sol with high effort')) 'banner retained'
    Assert-True (-not ($filteredFrame | Out-String).Contains('API Usage Billing')) 'billing label removed'

    $installHome = Join-Path $temporary 'install home'
    $env:USERPROFILE = $installHome
    $env:CLAUDEX_CONFIG_DIR = Join-Path $installHome '.config\claudex'
    $env:CLAUDEX_BIN_DIR = Join-Path $installHome '.local\bin'
    $env:CLAUDEX_PROXY_TOKEN = 'installer-test-token'
    $env:CLAUDEX_SKIP_DEPENDENCY_INSTALL = '1'
    $env:CLAUDEX_SKIP_SERVICE_START = '1'
    & (Join-Path $root 'install.ps1') | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_BIN_DIR 'claudex.cmd') -PathType Leaf) 'cmd launcher installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_BIN_DIR 'claudex.ps1') -PathType Leaf) 'PowerShell launcher installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'statusline.ps1') -PathType Leaf) 'statusline installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'usage-limit.ps1') -PathType Leaf) 'usage helper installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'preload.cjs') -PathType Leaf) 'preload installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skills\usage-limit\SKILL.md') -PathType Leaf) 'usage skill installed'
    $installedSettings = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'settings.json') -Raw | ConvertFrom-Json
    Assert-True ($installedSettings.statusLine.command.Contains('powershell.exe')) 'Windows status command'
    Assert-True ($installedSettings.tui -eq 'fullscreen') 'fullscreen TUI'
    $installedEnv = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'env') -Raw
    Assert-True ($installedEnv.Contains('CLAUDEX_PROXY_TOKEN=installer-test-token')) 'installer token'
    Assert-True ($installedEnv.Contains('CLAUDEX_PROXY_CONFIG=')) 'managed proxy config path'

    [Console]::WriteLine('all Claudex Windows tests passed')
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
