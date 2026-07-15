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
    $testCodexDir = Join-Path $testHome '.codex'
    [IO.Directory]::CreateDirectory($testCodexDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $testConfig 'env'), "CLAUDEX_PROXY_TOKEN=test-token`nCLAUDEX_CODEX_AUTH_DIR=$testAuthDir`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $testAuthDir 'codex-test.json'), '{"type":"codex","access_token":"secret-access-token","refresh_token":"secret-refresh-token","account_id":"account-test","email":"private@example.com"}', $utf8)
    Copy-Item -LiteralPath (Join-Path $root 'settings.json') -Destination (Join-Path $testConfig 'settings.json')
    Copy-Item -LiteralPath (Join-Path $root 'preload.cjs') -Destination (Join-Path $testConfig 'preload.cjs')
    Copy-Item -LiteralPath (Join-Path $root 'usage-limit.ps1') -Destination (Join-Path $testConfig 'usage-limit.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'codex-session.ps1') -Destination (Join-Path $testConfig 'codex-session.ps1')
    [IO.File]::WriteAllText((Join-Path $testCodexDir 'auth.json'), '{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T01:00:00Z","tokens":{"access_token":"codex-source-access","refresh_token":"codex-source-refresh","id_token":"codex-source-id","account_id":"account-test"}}', $utf8)

    if ($isWindowsPlatform) {
        $fakeCurl = Join-Path $fakeBin 'curl.cmd'
        [IO.File]::WriteAllText($fakeCurl, @'
@echo off
if not "%CLAUDEX_TEST_CURL_ARGUMENT_FILE%"=="" echo %*>>"%CLAUDEX_TEST_CURL_ARGUMENT_FILE%"
echo CLAUDEX_TEST_CURL_ARGS=%* 1>&2
echo %* | findstr /c:"test-token" /c:"secret-access-token" >nul
if not errorlevel 1 exit /b 90
echo %* | findstr /c:"/wham/usage" >nul
if not errorlevel 1 (
  if "%FAKE_USAGE_FAIL%"=="1" exit /b 22
  echo {"user_id":"private-user","account_id":"private-account","email":"private@example.com","plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":565127,"reset_at":1784666240},"secondary_window":null},"code_review_rate_limit":null,"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":1784705933},"secondary_window":null}}],"credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"rate_limit_reset_credits":{"available_count":1}}
  exit /b 0
)
if not "%FAKE_PROXY_READY_FILE%"=="" if not exist "%FAKE_PROXY_READY_FILE%" exit /b 7
echo {"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}
exit /b 0
'@, $utf8)
        function global:claude {
            $firstArgument = if ($args) { [string] $args[0] } else { '' }
            if ($firstArgument -eq '--version') { Write-Output '2.1.210 (test)'; return }
            if ($firstArgument -eq '--help') { Write-Output '--model --agents --append-system-prompt --permission-mode --settings --effort'; return }
            if ($firstArgument -eq 'auto-mode' -and $args.Count -gt 1 -and $args[1] -eq 'defaults') {
                if ($env:FAKE_AUTO_MODE_DEFAULT_VERSION -eq '2') {
                    Write-Output '{"allow":["Updated default allow rule"],"environment":["Updated default environment rule"],"soft_deny":["Updated soft deny"],"hard_deny":["Updated hard deny"]}'
                } else {
                    Write-Output '{"allow":["Default allow rule"],"environment":["Default environment rule"],"soft_deny":["Default soft deny"],"hard_deny":["Default hard deny"]}'
                }
                return
            }
            if ($firstArgument -eq 'update') { return }
            if ($env:FAKE_CLAUDE_RESUME -eq '1') {
                $projectKey = [regex]::Replace((Get-Location).Path, '[^A-Za-z0-9]', '-')
                $sessionConfig = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
                $projectDirectory = Join-Path (Join-Path $sessionConfig 'projects') $projectKey
                [IO.Directory]::CreateDirectory($projectDirectory) | Out-Null
                $rootRecord = @{ sessionId = '123e4567-e89b-12d3-a456-426614174000'; cwd = (Get-Location).Path; isSidechain = $false } | ConvertTo-Json -Compress
                [IO.File]::WriteAllText((Join-Path $projectDirectory '123e4567-e89b-12d3-a456-426614174000.jsonl'), "$rootRecord`n", $utf8)
                if ($env:FAKE_FOREIGN_RESUME -eq '1') {
                    $foreignRecord = @{ sessionId = '223e4567-e89b-12d3-a456-426614174001'; cwd = 'C:\foreign'; isSidechain = $false } | ConvertTo-Json -Compress
                    [IO.File]::WriteAllText((Join-Path $projectDirectory '223e4567-e89b-12d3-a456-426614174001.jsonl'), "$foreignRecord`n", $utf8)
                }
                if ($env:FAKE_SAME_CWD_RESUME -eq '1') {
                    $sameCwdRecord = @{ sessionId = '323e4567-e89b-12d3-a456-426614174002'; cwd = (Get-Location).Path; isSidechain = $false } | ConvertTo-Json -Compress
                    [IO.File]::WriteAllText((Join-Path $projectDirectory '323e4567-e89b-12d3-a456-426614174002.jsonl'), "$sameCwdRecord`n", $utf8)
                }
                Write-Output 'Resume this session with:'
                Write-Output 'claude --resume 123e4567-e89b-12d3-a456-426614174000'
                $global:LASTEXITCODE = 0
                return
            }
            Write-Output "AUTO=$env:CLAUDE_CODE_AUTO_MODE_MODEL"
            Write-Output "BG=$env:CLAUDE_CODE_BG_CLASSIFIER_MODEL"
            Write-Output "SUBAGENT=$env:CLAUDE_CODE_SUBAGENT_MODEL"
            Write-Output "CONCURRENCY=$env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY"
            Write-Output "RETRIES=$env:CLAUDE_CODE_MAX_RETRIES"
            Write-Output "CONTEXT=$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS"
            Write-Output "COMPACT=$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW"
            Write-Output "NO_FLICKER=$env:CLAUDE_CODE_NO_FLICKER"
            Write-Output "ACCESSIBILITY=$env:CLAUDE_CODE_ACCESSIBILITY"
            Write-Output "OPUS=$env:ANTHROPIC_DEFAULT_OPUS_MODEL"
            Write-Output "OPUS_NAME=$env:ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"
            Write-Output "POWERSHELL_TOOL=$env:CLAUDE_CODE_USE_POWERSHELL_TOOL"
            Write-Output "MODE=$env:CLAUDEX_SESSION_MODE"
            Write-Output "BASE=$env:ANTHROPIC_BASE_URL"
            Write-Output "BUN=$env:BUN_OPTIONS"
            Write-Output "INTERACTIVE=$env:CLAUDEX_INTERACTIVE_TUI"
            Write-Output "CONFIG=$env:CLAUDE_CONFIG_DIR"
            Write-Output "ARGS=$($args -join ' ')"
        }
        Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class ClaudexTestProxy
{
    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "-version")
        {
            Console.WriteLine("CLIProxyAPI test");
            Console.WriteLine("extra version detail");
            return 1;
        }
        string ready = Environment.GetEnvironmentVariable("FAKE_PROXY_READY_FILE");
        if (!String.IsNullOrEmpty(ready))
        {
            File.WriteAllText(ready, String.Empty);
            string log = Environment.GetEnvironmentVariable("FAKE_PROXY_START_LOG");
            if (!String.IsNullOrEmpty(log)) File.AppendAllText(log, "started" + Environment.NewLine);
            return 0;
        }
        Console.WriteLine("CLIProxyAPI test");
        Console.WriteLine("extra version detail");
        return 1;
    }
}
'@ -OutputAssembly (Join-Path $fakeBin 'cliproxyapi.exe') -OutputType ConsoleApplication
        [IO.File]::WriteAllText((Join-Path $fakeBin 'codex.cmd'), @'
@echo off
if "%1"=="app-server" (
  echo {"id":1,"result":{}}
  echo {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":1784705933}},"rateLimitsByLimitId":{}}}
  exit /b 0
)
if "%FAKE_CODEX_LOGGED_OUT%"=="1" exit /b 1
if "%1"=="login" if "%2"=="status" exit /b 0
if "%1"=="logout" if not "%FAKE_CODEX_LOGOUT_EXIT%"=="" exit /b %FAKE_CODEX_LOGOUT_EXIT%
if "%1"=="logout" exit /b 0
if "%1"=="-c" exit /b 0
exit /b 2
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
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--model --agents --append-system-prompt --permission-mode --settings --effort'
  exit 0
fi
if [ "${1:-}" = "auto-mode" ] && [ "${2:-}" = "defaults" ]; then
  printf '%s\n' '{"allow":["Default allow rule"],"environment":["Default environment rule"],"soft_deny":["Default soft deny"],"hard_deny":["Default hard deny"]}'
  exit 0
fi
if [ "${1:-}" = "update" ]; then exit 0; fi
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
printf '%s\n' "MODE=${CLAUDEX_SESSION_MODE:-}"
printf '%s\n' "BASE=${ANTHROPIC_BASE_URL:-}"
printf '%s\n' "BUN=${BUN_OPTIONS:-}"
printf '%s\n' "INTERACTIVE=${CLAUDEX_INTERACTIVE_TUI:-}"
printf '%s\n' "CONFIG=${CLAUDE_CONFIG_DIR:-}"
printf 'ARGS='; printf ' %s' "$@"; printf '\n'
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'codex'), @'
#!/bin/sh
if [ "${FAKE_CODEX_LOGGED_OUT:-0}" = 1 ]; then exit 1; fi
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = logout ]; then exit "${FAKE_CODEX_LOGOUT_EXIT:-0}"; fi
if [ "${1:-}" = -c ]; then exit 0; fi
exit 2
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'cliproxyapi'), @'
#!/bin/sh
printf '%s\n' 'CLIProxyAPI test'
printf '%s\n' 'extra version detail'
exit 1
'@, $utf8)
        & chmod +x $fakeCurl (Join-Path $fakeBin 'claude') (Join-Path $fakeBin 'codex') (Join-Path $fakeBin 'cliproxyapi')
        if ($LASTEXITCODE -ne 0) { throw 'failed to make PowerShell test doubles executable' }
    }

    $env:USERPROFILE = $testHome
    $env:CLAUDEX_CONFIG_DIR = $testConfig
    $env:CLAUDEX_CURL_BIN = $fakeCurl
    $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$env:PATH"
    $env:CLAUDEX_SKIP_AUTO_UPDATE = '1'
    $env:CLAUDEX_SKIP_PROXY_WATCHER = '1'
    Remove-Item Env:CLAUDEX_PERMISSION_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDEX_AUTO_COMPACT_WINDOW -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDEX_MOUSE_POINTER_SHAPE -ErrorAction SilentlyContinue

    $sourceSettings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
    Assert-True (@($sourceSettings.autoMode.environment | Where-Object { $_.StartsWith('User-designated task boundary:') }).Count -eq 1) 'auto-mode task boundary'
    Assert-True (@($sourceSettings.autoMode.environment | Where-Object { $_.StartsWith('Explicitly approved development transfer:') }).Count -eq 1) 'auto-mode approved development transfer'
    Assert-True (@($sourceSettings.autoMode.allow | Where-Object { $_.StartsWith('Explicit Action Approval:') }).Count -eq 1) 'auto-mode explicit approval'
    Assert-True (@($sourceSettings.autoMode.allow | Where-Object { $_.Contains('approve that') }).Count -eq 1) 'auto-mode approval by reference'
    Assert-True (@($sourceSettings.autoMode.allow | Where-Object { $_.StartsWith('Requested Agent Configuration:') }).Count -eq 1) 'auto-mode requested configuration'

    $seedSettings = Get-Content -LiteralPath (Join-Path $testConfig 'settings.json') -Raw | ConvertFrom-Json
    $seedSettings.autoMode.allow = @($seedSettings.autoMode.allow) + @('User custom allow rule')
    $seedSettings.autoMode.environment = @($seedSettings.autoMode.environment) + @('User custom environment rule')
    [IO.File]::WriteAllText((Join-Path $testConfig 'settings.json'), ($seedSettings | ConvertTo-Json -Depth 100), $utf8)

    $proxyCurlArgumentLog = Join-Path $temporary 'proxy-curl-arguments.log'
    $env:CLAUDEX_TEST_CURL_ARGUMENT_FILE = $proxyCurlArgumentLog
    $output = (& (Join-Path $root 'claudex.ps1') --terra test-prompt | Out-String)
    if (-not $output.Contains('AUTO=gpt-5.6-terra')) {
        $proxyRecoveryLog = Join-Path $testConfig 'logs\proxy-recovery.log'
        $proxyRecoveryDetail = if (Test-Path -LiteralPath $proxyRecoveryLog -PathType Leaf) {
            Get-Content -LiteralPath $proxyRecoveryLog -Raw
        } else { 'proxy recovery log was not created' }
        $proxyCurlArguments = if (Test-Path -LiteralPath $proxyCurlArgumentLog -PathType Leaf) {
            (Get-Content -LiteralPath $proxyCurlArgumentLog -Raw).Replace('test-token', '[redacted]').Replace('secret-access-token', '[redacted]')
        } else { 'curl argument log was not created' }
        throw "assertion failed: auto classifier; proxy diagnostics: $proxyRecoveryDetail; redacted curl argv: $proxyCurlArguments"
    }
    Remove-Item Env:CLAUDEX_TEST_CURL_ARGUMENT_FILE -ErrorAction SilentlyContinue
    Assert-True ($output.Contains('BG=gpt-5.6-luna')) 'background classifier'
    Assert-True ($output.Contains('SUBAGENT=gpt-5.6-terra')) 'subagent model'
    Assert-True ($output.Contains('CONCURRENCY=3')) 'tool concurrency'
    Assert-True ($output.Contains('RETRIES=4')) 'bounded retries'
    Assert-True ($output.Contains('CONTEXT=400000')) 'context window'
    Assert-True ($output.Contains('COMPACT=280000')) 'compaction window'
    Assert-True ($output.Contains('NO_FLICKER=1')) 'no-flicker rendering'
    Assert-True ($output.Contains('ACCESSIBILITY=1')) 'native terminal cursor'
    Assert-True ($output.Contains('OPUS=gpt-5.6-sol')) 'single Sol alias'
    Assert-True ($output.Contains('OPUS_NAME=GPT-5.6 Sol')) 'friendly name'
    Assert-True ($output.Contains('BUN=--preload')) 'proxied session preload'
    Assert-True ($output.Contains('INTERACTIVE=') -and -not $output.Contains('INTERACTIVE=1')) 'non-interactive output filter remains available'
    Assert-True ($output.Contains('POWERSHELL_TOOL=1')) 'native PowerShell tool'
    Assert-True ($output.Contains('--permission-mode auto')) 'auto permissions'
    Assert-True ($output.Contains('--model gpt-5.6-terra')) 'startup model'
    Assert-True ($output.Contains('Do not create a team, spawn or delegate to additional agents')) 'nested agent guard'
    Assert-True ($output.Contains('Do not create, claim, or update entries in the shared task list')) 'subagent task ownership'
    Assert-True ($output.Contains('Before every final answer, call TaskList and reconcile every entry')) 'leader task reconciliation'
    Assert-True ($output.Contains('Never leave stale in_progress tasks after their work is done')) 'stale task guard'
    Assert-True ($output.Contains('operate as a Codex coding agent inside Claude Code')) 'Codex tuning guard'
    Assert-True ($output.Contains('Ask as few questions as possible')) 'low-question autonomy guard'
    Assert-True ($output.Contains('Never repeat a question the user already answered')) 'no-repeat question guard'
    Assert-True ($output.Contains('Do not call EnterPlanMode')) 'conservative plan mode guard'
    Assert-True ($output.Contains('"gpt-5-6-terra"')) 'transparent Terra agent name'
    Assert-True ($output.Contains('"gpt-5-6-luna"')) 'transparent Luna agent name'
    Assert-True (-not $output.Contains('"claudex-deep"')) 'legacy deep alias removed'
    Assert-True (-not $output.Contains('"claudex-builder"')) 'legacy builder alias removed'
    Assert-True (-not $output.Contains('"claudex-fast"')) 'legacy fast alias removed'
    Assert-True (-not $output.Contains('"model":"gpt-5.6-sol"')) 'leader model is not delegated'
    $env:CLAUDEX_MODEL = 'gpt-5.6-luna'
    try {
        $configuredModel = (& (Join-Path $root 'claudex.ps1') test-prompt | Out-String)
        Assert-True ($configuredModel.Contains('--model gpt-5.6-luna')) 'configured default model routes the launch'
        $configuredModelOverride = (& (Join-Path $root 'claudex.ps1') --terra test-prompt | Out-String)
        Assert-True ($configuredModelOverride.Contains('--model gpt-5.6-terra')) 'explicit model shortcut overrides configured default'
        $configuredChrome = (& (Join-Path $root 'claudex.ps1') --claude-chrome --print chrome-test | Out-String)
        Assert-True (-not $configuredChrome.Contains('--model gpt-5.6-luna')) 'direct Chrome ignores managed default model'
    } finally { Remove-Item Env:CLAUDEX_MODEL -ErrorAction SilentlyContinue }
    $env:CLAUDEX_TEST_TTY_OUTPUT = '1'
    try { $interactiveWrapperOutput = (& (Join-Path $root 'claudex.ps1') --terra interactive-render-test | Out-String) }
    finally { Remove-Item Env:CLAUDEX_TEST_TTY_OUTPUT -ErrorAction SilentlyContinue }
    Assert-True ($interactiveWrapperOutput.Contains('INTERACTIVE=1')) 'interactive wrapper disables TUI output rewriting'
    $composedSettings = Get-Content -LiteralPath (Join-Path $testConfig 'settings.json') -Raw | ConvertFrom-Json
    Assert-True (@($composedSettings.autoMode.allow | Where-Object { $_ -eq 'Default allow rule' }).Count -eq 1) 'upstream auto-mode allow rule preserved'
    Assert-True (@($composedSettings.autoMode.allow | Where-Object { $_ -eq 'User custom allow rule' }).Count -eq 1) 'user auto-mode allow rule preserved'
    Assert-True (@($composedSettings.autoMode.allow | Where-Object { $_.StartsWith('Explicit Action Approval:') }).Count -eq 1) 'Claudex auto-mode allow rule composed'
    Assert-True (@($composedSettings.autoMode.environment | Where-Object { $_ -eq 'Default environment rule' }).Count -eq 1) 'upstream auto-mode environment preserved'
    Assert-True (@($composedSettings.autoMode.environment | Where-Object { $_ -eq 'User custom environment rule' }).Count -eq 1) 'user auto-mode environment rule preserved'
    Assert-True (@($composedSettings.autoMode.environment | Where-Object { $_.StartsWith('Explicitly approved development transfer:') }).Count -eq 1) 'approved development transfer composed'
    $env:FAKE_AUTO_MODE_DEFAULT_VERSION = '2'
    try { & (Join-Path $root 'claudex.ps1') --terra test-prompt | Out-Null }
    finally { Remove-Item Env:FAKE_AUTO_MODE_DEFAULT_VERSION -ErrorAction SilentlyContinue }
    $updatedSettings = Get-Content -LiteralPath (Join-Path $testConfig 'settings.json') -Raw | ConvertFrom-Json
    Assert-True (@($updatedSettings.autoMode.allow | Where-Object { $_ -eq 'Default allow rule' }).Count -eq 0) 'removed upstream allow default does not persist'
    Assert-True (@($updatedSettings.autoMode.allow | Where-Object { $_ -eq 'Updated default allow rule' }).Count -eq 1) 'updated upstream allow default is active'
    Assert-True (@($updatedSettings.autoMode.allow | Where-Object { $_ -eq 'User custom allow rule' }).Count -eq 1) 'custom allow survives upstream replacement'
    Assert-True (@($updatedSettings.autoMode.environment | Where-Object { $_ -eq 'Default environment rule' }).Count -eq 0) 'removed upstream environment default does not persist'
    Assert-True (@($updatedSettings.autoMode.environment | Where-Object { $_ -eq 'Updated default environment rule' }).Count -eq 1) 'updated upstream environment default is active'
    Assert-True (@($updatedSettings.autoMode.environment | Where-Object { $_ -eq 'User custom environment rule' }).Count -eq 1) 'custom environment survives upstream replacement'

    if ($isWindowsPlatform) {
        $proxyReady = Join-Path $temporary 'windows-proxy-ready'
        $proxyStartLog = Join-Path $temporary 'windows-proxy-start.log'
        $env:FAKE_PROXY_READY_FILE = $proxyReady
        $env:FAKE_PROXY_START_LOG = $proxyStartLog
        $env:CLAUDEX_TEST_PROXY_REACHABLE_FILE = $proxyReady
        $watcherErrorLog = Join-Path $temporary 'windows-proxy-watcher-errors.log'
        $env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE = $watcherErrorLog
        $stateHashBefore = (Get-FileHash -LiteralPath (Join-Path $testConfig '.claude.json') -Algorithm SHA256).Hash
        $shellPath = (Get-Process -Id $PID).Path
        $parentCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 15'))
        $dummyParent = Start-Process -FilePath $shellPath -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $parentCommand) -PassThru
        $quotedLauncher = '"' + (Join-Path $root 'claudex.ps1') + '"'
        $watchArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedLauncher,
            '-ClaudexInternalProxyWatchParentProcessId', [string] $dummyParent.Id)
        $watcher = Start-Process -FilePath $shellPath -ArgumentList $watchArguments -PassThru -WindowStyle Hidden
        try {
            foreach ($attempt in 1..100) {
                if (Test-Path -LiteralPath $proxyReady -PathType Leaf) { break }
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $proxyReady -PathType Leaf)) {
                $watcher.Refresh()
                $watchErrors = if (Test-Path -LiteralPath $watcherErrorLog) { Get-Content -LiteralPath $watcherErrorLog -Raw } else { '' }
                throw "assertion failed: Windows proxy watcher recovered a refused connection; watcherExited=$($watcher.HasExited); watcherErrors=$watchErrors"
            }
            Start-Sleep -Milliseconds 300
            $watcher.Refresh()
            Assert-True (-not $watcher.HasExited) 'Windows proxy watcher survives after recovery'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $testConfig 'run\proxy-start.lock'))) 'Windows proxy recovery lock released'
            $stateHashAfter = (Get-FileHash -LiteralPath (Join-Path $testConfig '.claude.json') -Algorithm SHA256).Hash
            Assert-True ($stateHashAfter -eq $stateHashBefore) 'internal proxy watcher does not mutate model state'
            Assert-True (@(Get-Content -LiteralPath $proxyStartLog).Count -eq 1) 'Windows proxy watcher starts one recovery process'
            Stop-Process -Id $dummyParent.Id -Force -ErrorAction SilentlyContinue
            $dummyParent = $null
            Assert-True ($watcher.WaitForExit(5000)) 'Windows proxy watcher exits after its parent'
        } finally {
            if ($dummyParent) { Stop-Process -Id $dummyParent.Id -Force -ErrorAction SilentlyContinue }
            if (-not $watcher.HasExited -and -not $watcher.WaitForExit(5000)) { Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item Env:FAKE_PROXY_READY_FILE -ErrorAction SilentlyContinue
            Remove-Item Env:FAKE_PROXY_START_LOG -ErrorAction SilentlyContinue
            Remove-Item Env:CLAUDEX_TEST_PROXY_REACHABLE_FILE -ErrorAction SilentlyContinue
            Remove-Item Env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE -ErrorAction SilentlyContinue
        }
    }

    $env:BUN_OPTIONS = ''
    $directChrome = (& (Join-Path $root 'claudex.ps1') --claude-chrome test-prompt | Out-String)
    Assert-True ($directChrome.Contains('ARGS=--chrome test-prompt')) 'direct Chrome arguments'
    Assert-True ($directChrome.Contains('BUN=')) 'direct Chrome BUN output'
    Assert-True (-not $directChrome.Contains('BUN=--preload')) 'direct Chrome preload isolation'
    Assert-True (-not $directChrome.Contains('BASE=http')) 'direct Chrome proxy isolation'

    $flagPrompt = (& (Join-Path $root 'claudex.ps1') --print --terra | Out-String)
    Assert-True ($flagPrompt.Contains('--print --terra')) 'flag-shaped prompt preserved'
    Assert-True (-not $flagPrompt.Contains('--model gpt-5.6-terra')) 'flag-shaped prompt not consumed'
    $flagValue = (& (Join-Path $root 'claudex.ps1') --permission-mode --manual | Out-String)
    Assert-True ($flagValue.Contains('--permission-mode --manual')) 'flag-shaped option value preserved'

    $ultracode = (& (Join-Path $root 'claudex.ps1') --ultracode --sol test-prompt | Out-String)
    Assert-True ($ultracode.Contains('MODE=ultracode')) 'ultracode session label'
    Assert-True ($ultracode.Contains('--effort xhigh')) 'ultracode xhigh effort'
    Assert-True ($ultracode.Contains('"ultracode":true')) 'ultracode setting'
    Assert-True ($ultracode.Contains('"workflows":true')) 'ultracode workflows'

    $maxEffort = (& (Join-Path $root 'claudex.ps1') --max-effort test-prompt | Out-String)
    Assert-True ($maxEffort.Contains('MODE=max')) 'max effort session label'
    Assert-True ($maxEffort.Contains('--effort max')) 'max effort flag'

    $solplan = (& (Join-Path $root 'claudex.ps1') --solplan test-prompt | Out-String)
    Assert-True ($solplan.Contains('--model opusplan')) 'Solplan built-in selector'
    Assert-True ($solplan.Contains('OPUS=gpt-5.6-sol')) 'Solplan planning model'
    Assert-True ($solplan.Contains('SUBAGENT=gpt-5.6-terra')) 'Solplan implementation family'

    $env:FAKE_CLAUDE_RESUME = '1'
    $env:CLAUDEX_TEST_TTY_OUTPUT = '1'
    $resumeCapture = Join-Path $temporary 'resume-footer.txt'
    $env:CLAUDEX_TEST_RESUME_CAPTURE_FILE = $resumeCapture
    & (Join-Path $root 'claudex.ps1') | Out-Null
    $resumeFooter = [IO.File]::ReadAllText($resumeCapture)
    Remove-Item Env:FAKE_CLAUDE_RESUME
    Remove-Item Env:CLAUDEX_TEST_TTY_OUTPUT
    Remove-Item Env:CLAUDEX_TEST_RESUME_CAPTURE_FILE
    Assert-True (-not $resumeFooter.Contains("$([char]27)[2A")) 'resume correction never moves or erases terminal rows'
    Assert-True ($resumeFooter.Contains('Claudex resume: claudex --resume 123e4567-e89b-12d3-a456-426614174000')) 'Claudex resume command appended'
    $windowsLauncher = [IO.File]::ReadAllText((Join-Path $root 'claudex.ps1'))
    Assert-True ($windowsLauncher.Contains('if ($rewriteResumeFooter) { Update-ResumeFooter $resumeMarker }')) 'resume footer is rewritten independently of exit status'
    Assert-True ($windowsLauncher.Contains("Join-Path `$configDir 'auto-mode-defaults.json'")) 'Windows uses the shared auto-mode defaults snapshot schema'
    Assert-True ($windowsLauncher.Contains('try { Ensure-Proxy $startModel }')) 'selected launch model is checked without driving proxy health'
    Assert-True ($windowsLauncher.Contains("if (`$RequiredModel -eq 'opusplan') { @('gpt-5.6-sol', 'gpt-5.6-terra') }")) 'Solplan health checks its two concrete backing models'
    Assert-True ($windowsLauncher.Contains('ConvertTo-WindowsCommandLineArgument')) 'Windows native argv serializer is installed'
    Assert-True ($windowsLauncher.Contains('if ($null -eq $Value -or $Value.Length -eq 0) { return ''""'' }')) 'Windows native argv serializer preserves empty arguments'
    Assert-True ($windowsLauncher.Contains('if ($character -eq ''"'')')) 'Windows native argv serializer escapes embedded quotes'
    Assert-True ($windowsLauncher.Contains("`$earlyRuntimeBypass = `$true")) 'maintenance and direct Chrome recovery bypass is installed'

    Remove-Item -LiteralPath $resumeCapture -Force
    $env:FAKE_CLAUDE_RESUME = '1'
    $env:CLAUDEX_TEST_TTY_OUTPUT = '1'
    $env:CLAUDEX_TEST_RESUME_CAPTURE_FILE = $resumeCapture
    & (Join-Path $root 'claudex.ps1') --claude-chrome | Out-Null
    $directResumeFooter = [IO.File]::ReadAllText($resumeCapture)
    Assert-True ($directResumeFooter.Contains('claudex --claude-chrome --resume 123e4567-e89b-12d3-a456-426614174000')) 'direct Chrome resume command'
    Remove-Item -LiteralPath $resumeCapture -Force
    $env:FAKE_FOREIGN_RESUME = '1'
    & (Join-Path $root 'claudex.ps1') | Out-Null
    $concurrentResumeFooter = [IO.File]::ReadAllText($resumeCapture)
    Assert-True ($concurrentResumeFooter.Contains('claudex --resume 123e4567-e89b-12d3-a456-426614174000')) 'root resume survives concurrent foreign session'
    Assert-True (-not $concurrentResumeFooter.Contains('223e4567-e89b-12d3-a456-426614174001')) 'foreign session is not selected for resume'
    Remove-Item -LiteralPath $resumeCapture -Force
    $env:FAKE_SAME_CWD_RESUME = '1'
    & (Join-Path $root 'claudex.ps1') | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $resumeCapture -PathType Leaf)) 'ambiguous same-directory resume is never guessed'
    Remove-Item Env:FAKE_CLAUDE_RESUME
    Remove-Item Env:FAKE_FOREIGN_RESUME
    Remove-Item Env:FAKE_SAME_CWD_RESUME
    Remove-Item Env:CLAUDEX_TEST_TTY_OUTPUT
    Remove-Item Env:CLAUDEX_TEST_RESUME_CAPTURE_FILE

    $bare = (& (Join-Path $root 'claudex.ps1') --bare --print test-prompt | Out-String)
    Assert-True (-not $bare.Contains('--agents')) 'bare mode custom agents suppressed'
    Assert-True (-not $bare.Contains('--append-system-prompt')) 'bare mode leader prompt suppressed'
    Assert-True (-not $bare.Contains('--permission-mode')) 'bare mode permission override suppressed'

    $maintenance = (& (Join-Path $root 'claudex.ps1') mcp list | Out-String)
    Assert-True (-not $maintenance.Contains('BASE=http')) 'maintenance command bypasses model proxy'
    Assert-True (-not $maintenance.Contains('--agents')) 'maintenance command bypasses session injection'

    $state = Get-Content -LiteralPath (Join-Path $testConfig '.claude.json') -Raw | ConvertFrom-Json
    $stateIds = @($state.additionalModelOptionsCache | ForEach-Object { $_.value })
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-sol' }).Count -eq 1) 'one Sol cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-terra' }).Count -eq 1) 'one Terra cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-luna' }).Count -eq 1) 'one Luna cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'opusplan' }).Count -eq 1) 'one Solplan cache entry'

    $doctor = (& (Join-Path $root 'claudex.ps1') --doctor | Out-String)
    Assert-True ($doctor.Contains('CLIProxyAPI: CLIProxyAPI test')) 'proxy version first line'
    Assert-True (-not $doctor.Contains('extra version detail')) 'proxy version extra lines hidden'
    Assert-True ($doctor.Contains('Auto-compact window: 280000 tokens')) 'doctor compaction'
    Assert-True ($doctor.Contains('Task lifecycle: Sol-owned with final-response reconciliation')) 'doctor task lifecycle'
    Assert-True ($doctor.Contains('Context status: session-stabilized')) 'doctor context stabilization'
    Assert-True ($doctor.Contains('Codex usage: status-line refresh every 300s')) 'doctor usage refresh'
    Assert-True ($doctor.Contains('Rendering: no-flicker mode with native terminal cursor')) 'doctor rendering hardening'
    Assert-True ($doctor.Contains('Codex authentication: ready (shared ChatGPT session)')) 'doctor shared Codex auth'
    Assert-True ($doctor.Contains('Claude Code updates: on')) 'doctor auto updates'
    Assert-True ($doctor.Contains('Plan mode policy: conservative')) 'doctor plan policy'
    Assert-True ($doctor.Contains('gpt-5.6-terra: advertised')) 'doctor models'

    $bridgeAuthFile = Join-Path $testAuthDir 'codex-claudex-managed.json'
    [IO.Directory]::CreateDirectory((Join-Path $testConfig 'usage-cache')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $testConfig 'usage-cache\limits.json'), "old`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $testConfig 'codex-usage-account'), "codex-test.json`n", $utf8)
    $env:CLAUDEX_AUTH_WATCH_SECONDS = '1'
    $authWatchReady = Join-Path $temporary 'auth-watch-ready'
    $env:CLAUDEX_AUTH_WATCH_READY_FILE = $authWatchReady
    $shellPath = (Get-Process -Id $PID).Path
    $quotedSessionHelper = '"' + (Join-Path $root 'codex-session.ps1') + '"'
    $watchArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedSessionHelper,
        'watch', '-ParentProcessId', [string] $PID)
    $watchParameters = @{ FilePath = $shellPath; ArgumentList = $watchArguments; PassThru = $true }
    if ($isWindowsPlatform) { $watchParameters.WindowStyle = 'Hidden' }
    $accountWatcher = Start-Process @watchParameters
    try {
        foreach ($attempt in 1..50) {
            if (Test-Path -LiteralPath $authWatchReady -PathType Leaf) { break }
            Start-Sleep -Milliseconds 20
        }
        Assert-True (Test-Path -LiteralPath $authWatchReady -PathType Leaf) 'account watcher initialized'
        [IO.File]::WriteAllText((Join-Path $testCodexDir 'auth.json'), '{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T02:00:00Z","tokens":{"access_token":"codex-switched-access","refresh_token":"codex-switched-refresh","id_token":"codex-switched-id","account_id":"account-switched"}}', $utf8)
        foreach ($attempt in 1..50) {
            Start-Sleep -Milliseconds 50
            try {
                $switchedBridge = Get-Content -LiteralPath $bridgeAuthFile -Raw | ConvertFrom-Json
                if ($switchedBridge.account_id -eq 'account-switched') { break }
            } catch { }
        }
        $switchedBridge = Get-Content -LiteralPath $bridgeAuthFile -Raw | ConvertFrom-Json
        Assert-True ($switchedBridge.account_id -eq 'account-switched' -and $switchedBridge.access_token -eq 'codex-switched-access') 'live Codex account switch synchronized'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testConfig 'codex-usage-account'))) 'account switch resets explicit usage selection'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testConfig 'usage-cache\limits.json'))) 'account switch invalidates usage cache'
    } finally {
        Stop-Process -Id $accountWatcher.Id -Force -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_AUTH_WATCH_SECONDS -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_AUTH_WATCH_READY_FILE -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText((Join-Path $testCodexDir 'auth.json'), '{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T03:00:00Z","tokens":{"access_token":"codex-source-access","refresh_token":"codex-source-refresh","id_token":"codex-source-id","account_id":"account-test"}}', $utf8)
    & (Join-Path $root 'codex-session.ps1') sync

    [IO.File]::WriteAllText($bridgeAuthFile, '{"type":"codex","access_token":"disabled-access","refresh_token":"disabled-refresh","account_id":"account-test","last_refresh":"2099-01-01T00:00:00Z","disabled":true,"expired":true}', $utf8)
    & (Join-Path $root 'codex-session.ps1') status | Out-Null
    $repairedBridge = Get-Content -LiteralPath $bridgeAuthFile -Raw | ConvertFrom-Json
    Assert-True ($repairedBridge.access_token -eq 'codex-source-access') 'disabled bridge credential repaired'
    Assert-True (-not [bool] $repairedBridge.disabled -and -not [bool] $repairedBridge.expired) 'repaired bridge credential enabled'

    $env:FAKE_CODEX_LOGOUT_EXIT = '9'
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $shellPath = (Get-Process -Id $PID).Path
        $logoutOutput = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'codex-session.ps1') logout 2>&1
        $logoutExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorPreference
        Remove-Item Env:FAKE_CODEX_LOGOUT_EXIT -ErrorAction SilentlyContinue
    }
    Assert-True ($logoutExit -eq 9) 'failed Codex logout exit propagated'
    Assert-True (-not (Test-Path -LiteralPath $bridgeAuthFile)) 'failed Codex logout clears bridge credential'
    Assert-True (($logoutOutput | Out-String).Contains('Codex logout failed, but the local Claudex bridge session was cleared.')) 'failed logout diagnostic'

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
    $env:CLAUDEX_USAGE_SOURCE = 'web'
    $fallbackUsage = (& (Join-Path $root 'claudex.ps1') --usage-limit 2>&1 | Out-String)
    Remove-Item Env:FAKE_USAGE_FAIL
    Remove-Item Env:CLAUDEX_USAGE_SOURCE
    Assert-True ($fallbackUsage.Contains('Codex 7-day: 18% remaining (82% used)')) 'usage outage cache fallback'

    $accounts = (& (Join-Path $root 'claudex.ps1') --accounts | Out-String)
    Assert-True ($accounts.Contains('private@example.com')) 'usage account picker lists account'
    $selection = (& (Join-Path $root 'claudex.ps1') --account private@example.com | Out-String)
    Assert-True ($selection.Contains('Selected Codex usage account: private@example.com')) 'usage account picker selects account'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testConfig 'usage-cache\limits.json'))) 'usage cache invalidated on account selection'
    $automatic = (& (Join-Path $root 'claudex.ps1') --account auto | Out-String)
    Assert-True ($automatic.Contains('automatic')) 'usage account picker restores automatic mode'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testConfig 'usage-cache\limits.json'))) 'usage cache invalidated on automatic selection'

    [IO.File]::WriteAllText((Join-Path $testAuthDir 'codex-disabled.json'), '{"type":"codex","access_token":"disabled","account_id":"disabled-account","email":"disabled@example.com","disabled":true}', $utf8)
    $disabledAccounts = (& (Join-Path $root 'claudex.ps1') --accounts | Out-String)
    Assert-True ($disabledAccounts.Contains('disabled@example.com (disabled)')) 'disabled usage account is labeled'
    $disabledRejected = $false
    try { & (Join-Path $root 'claudex.ps1') --account disabled@example.com | Out-Null } catch { $disabledRejected = $true }
    Assert-True $disabledRejected 'disabled usage account is rejected'

    & (Join-Path $root 'claudex.ps1') --usage-limit | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $testConfig 'usage-cache\limits.json') -PathType Leaf) 'usage cache repopulated after account change'

    if ($isWindowsPlatform) {
        $env:CLAUDEX_USAGE_SOURCE = 'app-server'
        try {
            $appServerUsage = (& (Join-Path $root 'claudex.ps1') --usage-limit | Out-String)
        } finally { Remove-Item Env:CLAUDEX_USAGE_SOURCE -ErrorAction SilentlyContinue }
        Assert-True ($appServerUsage.Contains('Codex 7-day: 37% remaining (63% used)')) 'Windows Codex command shim app-server usage'
        Assert-True ($appServerUsage.Contains('Source: app-server')) 'Windows app-server usage source'
        $env:CLAUDEX_USAGE_SOURCE = 'web'
        try { & (Join-Path $root 'claudex.ps1') --usage-limit | Out-Null }
        finally { Remove-Item Env:CLAUDEX_USAGE_SOURCE -ErrorAction SilentlyContinue }
    }

    $statusJson = '{"session_id":"stable-session","model":{"id":"gpt-5.6-sol"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":42.9,"total_input_tokens":171600,"context_window_size":400000}}'
    $status = ($statusJson | & (Join-Path $root 'statusline.ps1') | Out-String)
    Assert-True ($status.Contains('GPT-5.6 Sol')) 'status model'
    Assert-True ($status.Contains('xhigh effort')) 'status effort'
    Assert-True ($status.Contains('42% context')) 'status context'
    Assert-True ($status.Contains('Codex 7d 18% left')) 'status usage limits'
    Assert-True (-not $status.Contains("$([char]27)]0;")) 'status line excludes terminal-title control sequence'

    $env:CLAUDEX_MODEL_MODE = 'solplan'
    $solplanStatus = ($statusJson | & (Join-Path $root 'statusline.ps1') | Out-String)
    Remove-Item Env:CLAUDEX_MODEL_MODE
    Assert-True ($solplanStatus.Contains('GPT-5.6 Solplan')) 'Solplan status model'

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

    & node (Join-Path $root 'scripts\check-preload.mjs')
    Assert-True ($LASTEXITCODE -eq 0) 'preload terminal regressions'
    $env:CLAUDEX_TEST_TTY_INPUT = '1'
    $inputAlias = & node -e 'const p=require(process.argv[1]);process.stdout.write(Buffer.from(p.rewriteSolplanInput(process.argv[2]+String.fromCharCode(13))).toString(process.argv[3]))' (Join-Path $root 'preload.cjs') '/model solplan' hex
    Remove-Item Env:CLAUDEX_TEST_TTY_INPUT
    Assert-True (($inputAlias | Out-String).Contains('2f6d6f64656c206f707573706c616e0d')) 'Solplan slash-command alias'
    $packageVersion = (& node (Join-Path $root 'bin\claudex-package.mjs') --package-version | Out-String).Trim()
    $packageManifest = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
    Assert-True ($packageVersion -eq $packageManifest.version) 'package-manager wrapper version'

    $installHome = Join-Path $temporary 'install home'
    [IO.Directory]::CreateDirectory((Join-Path $installHome '.codex')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $testCodexDir 'auth.json') -Destination (Join-Path $installHome '.codex\auth.json')
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
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'codex-session.ps1') -PathType Leaf) 'Codex session helper installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'preload.cjs') -PathType Leaf) 'preload installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skills\usage-limit\SKILL.md') -PathType Leaf) 'usage skill installed'
    $installedSettings = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'settings.json') -Raw | ConvertFrom-Json
    Assert-True ($installedSettings.statusLine.command.Contains('powershell.exe')) 'Windows status command'
    Assert-True ($installedSettings.tui -eq 'fullscreen') 'fullscreen TUI'
    $installedEnv = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'env') -Raw
    Assert-True ($installedEnv.Contains('CLAUDEX_PROXY_TOKEN=installer-test-token')) 'installer token'
    Assert-True ($installedEnv.Contains('CLAUDEX_PROXY_CONFIG=')) 'managed proxy config path'
    Assert-True ($installedEnv.Contains('CLAUDEX_PROXY_URL=http://127.0.0.1:8318')) 'dedicated proxy port'
    Assert-True ($installedEnv.Contains('CLAUDEX_CODEX_AUTH_DIR=')) 'managed Codex auth directory'
    $installedProxyConfig = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'cliproxyapi.yaml') -Raw
    Assert-True ($installedProxyConfig.Contains('request-retry: 3')) 'proxy retries transient upstream failures before surfacing an API error'
    Assert-True ($installedProxyConfig.Contains('transient-error-cooldown-seconds: 1')) 'proxy transient cooldown stays bounded'
    Assert-True ($installedProxyConfig.Contains('bootstrap-retries: 2')) 'proxy retries pre-stream failures'

    & node (Join-Path $root 'scripts\check-docs.mjs')
    Assert-True ($LASTEXITCODE -eq 0) 'community and documentation checks'
    & node (Join-Path $root 'scripts\check-package.mjs')
    Assert-True ($LASTEXITCODE -eq 0) 'npm package checks'

    [Console]::WriteLine('all Claudex Windows tests passed')
} finally {
    if ($isWindowsPlatform) { Remove-Item Function:\global:claude -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
