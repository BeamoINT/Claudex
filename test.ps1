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
        function global:claude {
            if ($args.Count -gt 0 -and $args[0] -eq '--version') { Write-Output '2.1.210 (test)'; return }
            if ($args.Count -gt 0 -and $args[0] -eq '--help') { Write-Output '--model --agents --append-system-prompt --permission-mode --settings --effort'; return }
            if ($args.Count -gt 0 -and $args[0] -eq 'update') { return }
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
            Write-Output "CONFIG=$env:CLAUDE_CONFIG_DIR"
            Write-Output "ARGS=$($args -join ' ')"
        }
        [IO.File]::WriteAllText((Join-Path $fakeBin 'cliproxyapi.cmd'), @'
@echo off
echo CLIProxyAPI test
echo extra version detail
exit /b 1
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'codex.cmd'), @'
@echo off
if "%FAKE_CODEX_LOGGED_OUT%"=="1" exit /b 1
if "%1"=="login" if "%2"=="status" exit /b 0
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
printf '%s\n' "CONFIG=${CLAUDE_CONFIG_DIR:-}"
printf 'ARGS='; printf ' %s' "$@"; printf '\n'
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'codex'), @'
#!/bin/sh
if [ "${FAKE_CODEX_LOGGED_OUT:-0}" = 1 ]; then exit 1; fi
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = logout ]; then exit 0; fi
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
    Assert-True ($output.Contains('operate as a Codex coding agent inside Claude Code')) 'Codex tuning guard'
    Assert-True ($output.Contains('Do not call EnterPlanMode')) 'conservative plan mode guard'
    Assert-True ($output.Contains('"gpt-5-6-terra"')) 'transparent Terra agent name'
    Assert-True ($output.Contains('"gpt-5-6-luna"')) 'transparent Luna agent name'
    Assert-True (-not $output.Contains('"claudex-deep"')) 'legacy deep alias removed'
    Assert-True (-not $output.Contains('"claudex-builder"')) 'legacy builder alias removed'
    Assert-True (-not $output.Contains('"claudex-fast"')) 'legacy fast alias removed'
    Assert-True (-not $output.Contains('"model":"gpt-5.6-sol"')) 'leader model is not delegated'

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
    $automatic = (& (Join-Path $root 'claudex.ps1') --account auto | Out-String)
    Assert-True ($automatic.Contains('automatic')) 'usage account picker restores automatic mode'

    $statusJson = '{"session_id":"stable-session","model":{"id":"gpt-5.6-sol"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":42.9,"total_input_tokens":171600,"context_window_size":400000}}'
    $status = ($statusJson | & (Join-Path $root 'statusline.ps1') | Out-String)
    Assert-True ($status.Contains('GPT-5.6 Sol')) 'status model'
    Assert-True ($status.Contains('xhigh effort')) 'status effort'
    Assert-True ($status.Contains('42% context')) 'status context'
    Assert-True ($status.Contains('Codex 7d 18% left')) 'status usage limits'

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

    $billingFrame = "GPT-5.6 Sol with high effort$([char]27)[41G$([char]0x00B7)$([char]27)[43GAPI$([char]27)[47GUsage$([char]27)[53GBilling`r"
    $filteredFrame = $billingFrame | node --require (Join-Path $root 'preload.cjs') -e 'process.stdin.pipe(process.stdout)'
    Assert-True (($filteredFrame | Out-String).Contains('GPT-5.6 Sol with high effort')) 'banner retained'
    Assert-True (-not ($filteredFrame | Out-String).Contains('API Usage Billing')) 'billing label removed'
    $resumeFrame = 'Resume this session with: claude --resume 123e4567-e89b-12d3-a456-426614174000'
    $filteredResume = $resumeFrame | node --require (Join-Path $root 'preload.cjs') -e 'process.stdin.pipe(process.stdout)'
    Assert-True (($filteredResume | Out-String).Contains('claudex --resume 123e4567-e89b-12d3-a456-426614174000')) 'resume command rewritten'
    $strictErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 wraps intentional native stderr as a
        # NativeCommandError when the suite uses Stop globally.
        $ErrorActionPreference = 'Continue'
        $filteredResumeError = & node --require (Join-Path $root 'preload.cjs') -e 'process.stderr.write(process.argv[1])' $resumeFrame 2>&1
    } finally {
        $ErrorActionPreference = $strictErrorPreference
    }
    Assert-True (($filteredResumeError | Out-String).Contains('claudex --resume 123e4567-e89b-12d3-a456-426614174000')) 'stderr resume command rewritten'
    $solplanPicker = 'Opus Plan Mode - Use Opus in plan mode, Sonnet otherwise'
    $filteredSolplan = $solplanPicker | node --require (Join-Path $root 'preload.cjs') -e 'process.stdin.pipe(process.stdout)'
    Assert-True (($filteredSolplan | Out-String).Contains('GPT-5.6 Solplan')) 'Solplan picker label'
    Assert-True (($filteredSolplan | Out-String).Contains('GPT-5.6 Sol in plan mode, GPT-5.6 Terra otherwise')) 'Solplan picker description'
    $env:CLAUDEX_TEST_TTY_INPUT = '1'
    $inputAlias = "/model solplan`r" | node --require (Join-Path $root 'preload.cjs') -e 'process.stdin.pipe(process.stdout)'
    Remove-Item Env:CLAUDEX_TEST_TTY_INPUT
    Assert-True (($inputAlias | Out-String).Contains('/model opusplan')) 'Solplan slash-command alias'

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

    [Console]::WriteLine('all Claudex Windows tests passed')
} finally {
    if ($isWindowsPlatform) { Remove-Item Function:\global:claude -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
