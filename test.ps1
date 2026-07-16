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
    Copy-Item -LiteralPath (Join-Path $root 'skill-bridge.cjs') -Destination (Join-Path $testConfig 'skill-bridge.cjs')
    $existingClaudeSkill = Join-Path $testHome '.claude\skills\existing-claude'
    $existingCodexSkill = Join-Path $testHome '.agents\skills\existing-codex'
    [IO.Directory]::CreateDirectory($existingClaudeSkill) | Out-Null
    [IO.Directory]::CreateDirectory($existingCodexSkill) | Out-Null
    [IO.File]::WriteAllText((Join-Path $existingClaudeSkill 'SKILL.md'), "---`nname: existing-claude`ndescription: Existing Claude test skill`n---`n`nClaude instructions.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $existingCodexSkill 'SKILL.md'), "---`nname: existing-codex`ndescription: Existing Codex test skill`n---`n`nCodex instructions.`n", $utf8)
    Copy-Item -LiteralPath (Join-Path $root 'usage-limit.ps1') -Destination (Join-Path $testConfig 'usage-limit.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'codex-session.ps1') -Destination (Join-Path $testConfig 'codex-session.ps1')
    [IO.File]::WriteAllText((Join-Path $testCodexDir 'auth.json'), '{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T01:00:00Z","tokens":{"access_token":"codex-source-access","refresh_token":"codex-source-refresh","id_token":"codex-source-id","account_id":"account-test"}}', $utf8)

    if ($isWindowsPlatform) {
        $fakeCurl = Join-Path $fakeBin 'curl.exe'
        Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class ClaudexTestCurl
{
    public static int Main(string[] args)
    {
        string callLog = Environment.GetEnvironmentVariable("FAKE_CURL_CALL_LOG");
        if (!String.IsNullOrEmpty(callLog)) File.AppendAllText(callLog, String.Join(" ", args) + Environment.NewLine);
        string forcedStatus = Environment.GetEnvironmentVariable("FAKE_PROXY_HTTP_STATUS");
        if (!String.IsNullOrEmpty(forcedStatus))
        {
            Console.WriteLine("{}");
            Console.WriteLine(forcedStatus);
            return 0;
        }
        bool usage = false;
        string headerFile = null;
        foreach (string argument in args)
        {
            if (argument.Contains("test-token") || argument.Contains("secret-access-token")) return 90;
            if (argument.Contains("/wham/usage")) usage = true;
            if (argument.StartsWith("@") && argument.Length > 1) headerFile = argument.Substring(1);
        }
        if (usage)
        {
            if (Environment.GetEnvironmentVariable("FAKE_USAGE_FAIL") == "1") return 22;
            Console.WriteLine(@"{""user_id"":""private-user"",""account_id"":""private-account"",""email"":""private@example.com"",""plan_type"":""pro"",""rate_limit"":{""allowed"":true,""limit_reached"":false,""primary_window"":{""used_percent"":82,""limit_window_seconds"":604800,""reset_after_seconds"":565127,""reset_at"":1784666240},""secondary_window"":null},""code_review_rate_limit"":null,""additional_rate_limits"":[{""limit_name"":""GPT-5.3-Codex-Spark"",""metered_feature"":""codex_bengalfox"",""rate_limit"":{""allowed"":true,""limit_reached"":false,""primary_window"":{""used_percent"":0,""limit_window_seconds"":604800,""reset_after_seconds"":604800,""reset_at"":1784705933},""secondary_window"":null}}],""credits"":{""has_credits"":false,""unlimited"":false,""overage_limit_reached"":false,""balance"":""0""},""spend_control"":{""reached"":false,""individual_limit"":null},""rate_limit_reached_type"":null,""rate_limit_reset_credits"":{""available_count"":1}}");
            return 0;
        }
        string ready = Environment.GetEnvironmentVariable("FAKE_PROXY_READY_FILE");
        if (!String.IsNullOrEmpty(ready) && !File.Exists(ready)) return 7;
        if (String.IsNullOrEmpty(headerFile) || !File.Exists(headerFile) ||
            !File.ReadAllText(headerFile).Contains("Authorization: Bearer test-token")) return 91;
        string models = Environment.GetEnvironmentVariable("FAKE_PROXY_MODELS_JSON");
        Console.WriteLine(String.IsNullOrEmpty(models)
            ? @"{""data"":[{""id"":""gpt-5.6-sol""},{""id"":""gpt-5.6-terra""},{""id"":""gpt-5.6-luna""}]}"
            : models);
        return 0;
    }
}
'@ -OutputAssembly $fakeCurl -OutputType ConsoleApplication
        function global:claude {
            $firstArgument = if ($args) { [string] $args[0] } else { '' }
            if ($firstArgument -eq '--version') { Write-Output '2.1.210 (test)'; return }
            if ($firstArgument -eq '--help') { Write-Output '--model --agents --append-system-prompt --permission-mode --settings --effort --add-dir --plugin-dir'; return }
            if ($firstArgument -eq 'auto-mode' -and $args.Count -gt 1 -and $args[1] -eq 'defaults') {
                if ($env:FAKE_AUTO_MODE_DEFAULTS_FAIL -eq '1') { $global:LASTEXITCODE = 1; return }
                if ($env:FAKE_AUTO_MODE_DEFAULT_VERSION -eq '2') {
                    Write-Output '{"allow":["Updated default allow rule"],"environment":["Updated default environment rule"],"soft_deny":["Updated soft deny"],"hard_deny":["Data Exfiltration: updated hard deny"]}'
                } else {
                    Write-Output '{"allow":["Default allow rule"],"environment":["Default environment rule"],"soft_deny":["Default soft deny"],"hard_deny":["Data Exfiltration: default hard deny"]}'
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
            Write-Output "ADDITIONAL_DIR_MD=$env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"
            Write-Output "CONCURRENCY=$env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY"
            Write-Output "RETRIES=$env:CLAUDE_CODE_MAX_RETRIES"
            Write-Output "CONTEXT=$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS"
            Write-Output "COMPACT=$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW"
            Write-Output "NO_FLICKER=$env:CLAUDE_CODE_NO_FLICKER"
            Write-Output "ACCESSIBILITY=$env:CLAUDE_CODE_ACCESSIBILITY"
            Write-Output "DISABLE_1M=$env:CLAUDE_CODE_DISABLE_1M_CONTEXT"
            Write-Output "FABLE=$env:ANTHROPIC_DEFAULT_FABLE_MODEL"
            Write-Output "FABLE_NAME=$env:ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"
            Write-Output "OPUS=$env:ANTHROPIC_DEFAULT_OPUS_MODEL"
            Write-Output "OPUS_NAME=$env:ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"
            Write-Output "POWERSHELL_TOOL=$env:CLAUDE_CODE_USE_POWERSHELL_TOOL"
            Write-Output "MODE=$env:CLAUDEX_SESSION_MODE"
            Write-Output "MODEL_MODE=$env:CLAUDEX_MODEL_MODE"
            Write-Output "BASE=$env:ANTHROPIC_BASE_URL"
            Write-Output "AUTH_TOKEN=$env:ANTHROPIC_AUTH_TOKEN"
            Write-Output "PROXY_TOKEN=$env:CLAUDEX_PROXY_TOKEN"
            Write-Output "PROXY_URL=$env:CLAUDEX_PROXY_URL"
            Write-Output "PROXY_CONFIG=$env:CLAUDEX_PROXY_CONFIG"
            Write-Output "CODEX_AUTH_DIR=$env:CLAUDEX_CODEX_AUTH_DIR"
            Write-Output "PROVIDERS=$env:CLAUDE_CODE_USE_BEDROCK|$env:CLAUDE_CODE_USE_VERTEX|$env:CLAUDE_CODE_USE_FOUNDRY|$env:ANTHROPIC_BEDROCK_BASE_URL|$env:ANTHROPIC_VERTEX_BASE_URL|$env:ANTHROPIC_FOUNDRY_BASE_URL"
            Write-Output "BUN=$env:BUN_OPTIONS"
            Write-Output "INTERACTIVE=$env:CLAUDEX_INTERACTIVE_TUI"
            Write-Output "MANAGED=$env:CLAUDEX_MANAGED_SESSION"
            Write-Output "INSTRUCTION_BRIDGE=$env:CLAUDEX_INSTRUCTION_BRIDGE"
            Write-Output "CHATGPT_PLAN=$env:CLAUDEX_CHATGPT_PLAN_LABEL"
            Write-Output "CONFIG=$env:CLAUDE_CONFIG_DIR"
            Write-Output "ARGC=$($args.Count)"
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
            if (Environment.GetEnvironmentVariable("FAKE_PROXY_EXIT_BEFORE_READY") == "1")
            {
                string pidFile = Environment.GetEnvironmentVariable("FAKE_PROXY_PID_FILE");
                if (!String.IsNullOrEmpty(pidFile)) File.WriteAllText(pidFile, System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
                System.Threading.Thread.Sleep(500);
                return 12;
            }
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
if not "%FAKE_CODEX_NATIVE_LOG%"=="" (
  >"%FAKE_CODEX_NATIVE_LOG%" echo ARG1=%~1
  >>"%FAKE_CODEX_NATIVE_LOG%" echo ARG2=%~2
  >>"%FAKE_CODEX_NATIVE_LOG%" echo ARG3=%~3
  >>"%FAKE_CODEX_NATIVE_LOG%" echo BASE=%ANTHROPIC_BASE_URL%
  >>"%FAKE_CODEX_NATIVE_LOG%" echo AUTH_TOKEN=%ANTHROPIC_AUTH_TOKEN%
  >>"%FAKE_CODEX_NATIVE_LOG%" echo PROXY_TOKEN=%CLAUDEX_PROXY_TOKEN%
  >>"%FAKE_CODEX_NATIVE_LOG%" echo MANAGED=%CLAUDEX_MANAGED_SESSION%
  >>"%FAKE_CODEX_NATIVE_LOG%" echo BUN=%BUN_OPTIONS%
  if not "%FAKE_CODEX_NATIVE_EXIT%"=="" exit /b %FAKE_CODEX_NATIVE_EXIT%
)
if "%1"=="app-server" (
  echo {"id":1,"result":{}}
  echo {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":1784705933}},"rateLimitsByLimitId":{}}}
  exit /b 0
)
if "%FAKE_CODEX_LOGGED_OUT%"=="1" exit /b 1
if "%1"=="login" if "%2"=="status" exit /b 0
if "%1"=="logout" if not "%FAKE_CODEX_LOGOUT_EXIT%"=="" exit /b %FAKE_CODEX_LOGOUT_EXIT%
if "%1"=="logout" exit /b 0
if "%1"=="-c" (
  if not "%FAKE_CODEX_LOGIN_LOG%"=="" echo login>>"%FAKE_CODEX_LOGIN_LOG%"
  exit /b 0
)
exit /b 2
'@, $utf8)
        # Child PowerShell regressions cannot inherit the in-process `claude`
        # function above. Provide the same capability probe as an executable
        # fixture so those tests reach proxy recovery instead of exiting early.
        [IO.File]::WriteAllText((Join-Path $fakeBin 'claude.cmd'), @'
@echo off
if not "%FAKE_CLAUDE_NATIVE_LOG%"=="" (
  >"%FAKE_CLAUDE_NATIVE_LOG%" echo ARG1=%~1
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo ARG2=%~2
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo ARG3=%~3
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo BASE=%ANTHROPIC_BASE_URL%
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo AUTH_TOKEN=%ANTHROPIC_AUTH_TOKEN%
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo PROXY_TOKEN=%CLAUDEX_PROXY_TOKEN%
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo MANAGED=%CLAUDEX_MANAGED_SESSION%
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo BUN=%BUN_OPTIONS%
  >>"%FAKE_CLAUDE_NATIVE_LOG%" echo PROVIDERS=%CLAUDE_CODE_USE_BEDROCK%^|%CLAUDE_CODE_USE_VERTEX%^|%CLAUDE_CODE_USE_FOUNDRY%^|%ANTHROPIC_BEDROCK_BASE_URL%^|%ANTHROPIC_VERTEX_BASE_URL%^|%ANTHROPIC_FOUNDRY_BASE_URL%
  if not "%FAKE_CLAUDE_NATIVE_EXIT%"=="" exit /b %FAKE_CLAUDE_NATIVE_EXIT%
)
if "%~1"=="--version" (
  echo 2.1.210 ^(test^)
  exit /b 0
)
if "%~1"=="--help" (
  echo --model --agents --append-system-prompt --permission-mode --settings --effort --add-dir --plugin-dir
  exit /b 0
)
if "%~1"=="auto-mode" if "%~2"=="defaults" (
  echo {"allow":["Default allow rule"],"environment":["Default environment rule"],"soft_deny":["Default soft deny"],"hard_deny":["Data Exfiltration: default hard deny"]}
  exit /b 0
)
if "%~1"=="update" exit /b 0
if not "%FAKE_CLAUDE_MAINTENANCE_LOG%"=="" (
  >"%FAKE_CLAUDE_MAINTENANCE_LOG%" echo ARG1=%~1
  >>"%FAKE_CLAUDE_MAINTENANCE_LOG%" echo ARG2=%~2
  >>"%FAKE_CLAUDE_MAINTENANCE_LOG%" echo ARG3=%~3
  >>"%FAKE_CLAUDE_MAINTENANCE_LOG%" echo ARG4=%~4
  >>"%FAKE_CLAUDE_MAINTENANCE_LOG%" echo BUN=%BUN_OPTIONS%
  >>"%FAKE_CLAUDE_MAINTENANCE_LOG%" echo BASE=%ANTHROPIC_BASE_URL%
  >>"%FAKE_CLAUDE_MAINTENANCE_LOG%" echo MANAGED=%CLAUDEX_MANAGED_SESSION%
)
exit /b 0
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
  printf '%s\n' '--model --agents --append-system-prompt --permission-mode --settings --effort --add-dir --plugin-dir'
  exit 0
fi
if [ "${1:-}" = "auto-mode" ] && [ "${2:-}" = "defaults" ]; then
  printf '%s\n' '{"allow":["Default allow rule"],"environment":["Default environment rule"],"soft_deny":["Default soft deny"],"hard_deny":["Data Exfiltration: default hard deny"]}'
  exit 0
fi
if [ "${1:-}" = "update" ]; then exit 0; fi
printf '%s\n' "AUTO=${CLAUDE_CODE_AUTO_MODE_MODEL}"
printf '%s\n' "BG=${CLAUDE_CODE_BG_CLASSIFIER_MODEL}"
printf '%s\n' "SUBAGENT=${CLAUDE_CODE_SUBAGENT_MODEL}"
printf '%s\n' "ADDITIONAL_DIR_MD=${CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD}"
printf '%s\n' "CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY}"
printf '%s\n' "RETRIES=${CLAUDE_CODE_MAX_RETRIES}"
printf '%s\n' "CONTEXT=${CLAUDE_CODE_MAX_CONTEXT_TOKENS}"
printf '%s\n' "COMPACT=${CLAUDE_CODE_AUTO_COMPACT_WINDOW}"
printf '%s\n' "NO_FLICKER=${CLAUDE_CODE_NO_FLICKER}"
printf '%s\n' "ACCESSIBILITY=${CLAUDE_CODE_ACCESSIBILITY}"
printf '%s\n' "DISABLE_1M=${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}"
printf '%s\n' "OPUS=${ANTHROPIC_DEFAULT_OPUS_MODEL}"
printf '%s\n' "OPUS_NAME=${ANTHROPIC_DEFAULT_OPUS_MODEL_NAME}"
printf '%s\n' "POWERSHELL_TOOL=${CLAUDE_CODE_USE_POWERSHELL_TOOL}"
printf '%s\n' "MODE=${CLAUDEX_SESSION_MODE:-}"
printf '%s\n' "BASE=${ANTHROPIC_BASE_URL:-}"
printf '%s\n' "AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-}"
printf '%s\n' "PROXY_TOKEN=${CLAUDEX_PROXY_TOKEN:-}"
printf '%s\n' "BUN=${BUN_OPTIONS:-}"
printf '%s\n' "INTERACTIVE=${CLAUDEX_INTERACTIVE_TUI:-}"
printf '%s\n' "MANAGED=${CLAUDEX_MANAGED_SESSION:-}"
printf '%s\n' "INSTRUCTION_BRIDGE=${CLAUDEX_INSTRUCTION_BRIDGE:-}"
printf '%s\n' "CONFIG=${CLAUDE_CONFIG_DIR:-}"
printf 'ARGS='; printf ' %s' "$@"; printf '\n'
'@, $utf8)
        [IO.File]::WriteAllText((Join-Path $fakeBin 'codex'), @'
#!/bin/sh
if [ "${FAKE_CODEX_LOGGED_OUT:-0}" = 1 ]; then exit 1; fi
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = logout ]; then exit "${FAKE_CODEX_LOGOUT_EXIT:-0}"; fi
if [ "${1:-}" = -c ]; then
  [ -z "${FAKE_CODEX_LOGIN_LOG:-}" ] || printf '%s\n' login >> "$FAKE_CODEX_LOGIN_LOG"
  exit 0
fi
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

    if ($isWindowsPlatform) {
        $oldNodeBin = Join-Path $temporary 'old-node-bin'
        [IO.Directory]::CreateDirectory($oldNodeBin) | Out-Null
        [IO.File]::WriteAllText((Join-Path $oldNodeBin 'node.cmd'), "@echo off`r`nif `"%~1`"==`"--version`" (`r`n  echo v16.20.2`r`n  exit /b 0`r`n)`r`nexit /b 99`r`n", $utf8)
        $savedPath = $env:PATH
        $savedErrorPreference = $ErrorActionPreference
        try {
            $env:PATH = "$oldNodeBin$([IO.Path]::PathSeparator)$savedPath"
            $ErrorActionPreference = 'Continue'
            $shellPath = (Get-Process -Id $PID).Path
            $oldNodeOutput = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') skills 2>&1
            $oldNodeExit = $LASTEXITCODE
        } finally {
            $env:PATH = $savedPath
            $ErrorActionPreference = $savedErrorPreference
        }
        Assert-True ($oldNodeExit -eq 1) 'Node 16 is rejected before skill bridge startup'
        Assert-True (($oldNodeOutput | Out-String).Contains('Node.js 18 or newer is required for skill compatibility (found Node.js 16)')) 'old Node diagnostic is actionable'

        $missingMaintenanceConfig = Join-Path $temporary 'missing-maintenance-config'
        $maintenanceLog = Join-Path $temporary 'maintenance-command.log'
        $savedConfigDir = [Environment]::GetEnvironmentVariable('CLAUDEX_CONFIG_DIR', 'Process')
        $savedSettingsFile = [Environment]::GetEnvironmentVariable('CLAUDEX_SETTINGS_FILE', 'Process')
        $savedMaintenanceLog = [Environment]::GetEnvironmentVariable('FAKE_CLAUDE_MAINTENANCE_LOG', 'Process')
        $savedBaseUrl = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')
        $savedManagedSession = [Environment]::GetEnvironmentVariable('CLAUDEX_MANAGED_SESSION', 'Process')
        $savedMaintenanceBun = [Environment]::GetEnvironmentVariable('BUN_OPTIONS', 'Process')
        try {
            $env:CLAUDEX_CONFIG_DIR = $missingMaintenanceConfig
            Remove-Item Env:CLAUDEX_SETTINGS_FILE -ErrorAction SilentlyContinue
            $env:FAKE_CLAUDE_MAINTENANCE_LOG = $maintenanceLog
            $env:ANTHROPIC_BASE_URL = 'https://managed-parent.invalid'
            $env:CLAUDEX_MANAGED_SESSION = '1'
            $maintenanceManagedPreload = '--preload ' + (Join-Path $missingMaintenanceConfig 'preload.cjs').Replace('\', '/').Replace(' ', '\ ')
            $env:BUN_OPTIONS = "$maintenanceManagedPreload --preload C:/user/preload.cjs"
            foreach ($maintenanceCommand in @('doctor', 'attach', 'respawn', 'stop', 'kill', 'rm', 'logs')) {
                Remove-Item -LiteralPath $maintenanceLog -Force -ErrorAction SilentlyContinue
                $maintenanceOutput = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') $maintenanceCommand 'maintenance-sentinel' 2>&1
                $maintenanceExit = $LASTEXITCODE
                Assert-True ($maintenanceExit -eq 0) "Windows $maintenanceCommand bypasses missing Claudex configuration"
                Assert-True (Test-Path -LiteralPath $maintenanceLog -PathType Leaf) "Windows $maintenanceCommand reaches Claude"
                $maintenanceLines = @([IO.File]::ReadAllLines($maintenanceLog))
                Assert-True ($maintenanceLines.Count -eq 7) "Windows $maintenanceCommand writes one maintenance launch record"
                Assert-True ($maintenanceLines[0] -eq "ARG1=$maintenanceCommand" -and $maintenanceLines[1] -eq 'ARG2=maintenance-sentinel' -and $maintenanceLines[2] -eq 'ARG3=' -and $maintenanceLines[3] -eq 'ARG4=') "Windows $maintenanceCommand preserves exact Claude argv without managed flags"
                Assert-True ($maintenanceLines[4] -eq 'BUN=--preload C:/user/preload.cjs') "Windows $maintenanceCommand preserves caller owned Bun options"
                Assert-True ($maintenanceLines[5] -eq 'BASE=') "Windows $maintenanceCommand clears the managed proxy URL"
                Assert-True ($maintenanceLines[6] -eq 'MANAGED=') "Windows $maintenanceCommand clears the managed session marker"
            }
            Remove-Item -LiteralPath $maintenanceLog -Force -ErrorAction SilentlyContinue
            $maintenanceSavedPath = $env:PATH
            try {
                $env:PATH = "$oldNodeBin$([IO.Path]::PathSeparator)$maintenanceSavedPath"
                $verboseMaintenanceOutput = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') --verbose mcp list 2>&1
                $verboseMaintenanceExit = $LASTEXITCODE
            } finally { $env:PATH = $maintenanceSavedPath }
            Assert-True ($verboseMaintenanceExit -eq 0) 'global options before maintenance bypass missing configuration and stale Node'
            $verboseMaintenanceLines = @([IO.File]::ReadAllLines($maintenanceLog))
            Assert-True ($verboseMaintenanceLines[0] -eq 'ARG1=--verbose' -and $verboseMaintenanceLines[1] -eq 'ARG2=mcp' -and $verboseMaintenanceLines[2] -eq 'ARG3=list' -and $verboseMaintenanceLines[3] -eq 'ARG4=') 'global options preserve exact maintenance argv'
            Assert-True ($verboseMaintenanceLines[4] -eq 'BUN=--preload C:/user/preload.cjs' -and $verboseMaintenanceLines[5] -eq 'BASE=' -and $verboseMaintenanceLines[6] -eq 'MANAGED=') 'global option maintenance launch receives no proxy or managed session injection'
        } finally {
            if ($null -eq $savedConfigDir) { Remove-Item Env:CLAUDEX_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDEX_CONFIG_DIR = $savedConfigDir }
            if ($null -eq $savedSettingsFile) { Remove-Item Env:CLAUDEX_SETTINGS_FILE -ErrorAction SilentlyContinue } else { $env:CLAUDEX_SETTINGS_FILE = $savedSettingsFile }
            if ($null -eq $savedMaintenanceLog) { Remove-Item Env:FAKE_CLAUDE_MAINTENANCE_LOG -ErrorAction SilentlyContinue } else { $env:FAKE_CLAUDE_MAINTENANCE_LOG = $savedMaintenanceLog }
            if ($null -eq $savedBaseUrl) { Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue } else { $env:ANTHROPIC_BASE_URL = $savedBaseUrl }
            if ($null -eq $savedManagedSession) { Remove-Item Env:CLAUDEX_MANAGED_SESSION -ErrorAction SilentlyContinue } else { $env:CLAUDEX_MANAGED_SESSION = $savedManagedSession }
            if ($null -eq $savedMaintenanceBun) { Remove-Item Env:BUN_OPTIONS -ErrorAction SilentlyContinue } else { $env:BUN_OPTIONS = $savedMaintenanceBun }
        }

        $nativeBoundaryEnvironment = @{}
        foreach ($nativeBoundaryName in @(
            'CLAUDEX_CONFIG_DIR', 'CLAUDEX_MANAGED_SESSION', 'CLAUDEX_PROXY_TOKEN',
            'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'BUN_OPTIONS',
            'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
            'ANTHROPIC_BEDROCK_BASE_URL', 'ANTHROPIC_VERTEX_BASE_URL', 'ANTHROPIC_FOUNDRY_BASE_URL',
            'FAKE_CODEX_NATIVE_LOG', 'FAKE_CODEX_NATIVE_EXIT',
            'FAKE_CLAUDE_NATIVE_LOG', 'FAKE_CLAUDE_NATIVE_EXIT'
        )) {
            $nativeBoundaryEnvironment[$nativeBoundaryName] = [Environment]::GetEnvironmentVariable($nativeBoundaryName, 'Process')
        }
        try {
            $env:CLAUDEX_CONFIG_DIR = $missingMaintenanceConfig
            $env:CLAUDEX_MANAGED_SESSION = '1'
            $env:CLAUDEX_PROXY_TOKEN = 'managed-proxy-secret'
            $env:ANTHROPIC_BASE_URL = 'https://managed-provider.invalid'
            $env:ANTHROPIC_AUTH_TOKEN = 'managed-provider-secret'
            $boundaryManagedPreload = '--preload ' + (Join-Path $missingMaintenanceConfig 'preload.cjs').Replace('\', '/').Replace(' ', '\ ')
            $env:BUN_OPTIONS = "$boundaryManagedPreload --preload C:/user/preload.cjs"

            $nativeCodexLog = Join-Path $temporary 'native-codex.log'
            $env:FAKE_CODEX_NATIVE_LOG = $nativeCodexLog
            $env:FAKE_CODEX_NATIVE_EXIT = '37'
            & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') codex native-codex arg-two 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -eq 37) 'native Codex route preserves the child exit code'
            $nativeCodexLines = @([IO.File]::ReadAllLines($nativeCodexLog))
            Assert-True ($nativeCodexLines[0] -eq 'ARG1=native-codex' -and $nativeCodexLines[1] -eq 'ARG2=arg-two' -and $nativeCodexLines[2] -eq 'ARG3=') 'native Codex route preserves exact argv'
            Assert-True ($nativeCodexLines[3] -eq 'BASE=' -and $nativeCodexLines[4] -eq 'AUTH_TOKEN=') 'managed native Codex route clears provider credentials'
            Assert-True ($nativeCodexLines[5] -eq 'PROXY_TOKEN=' -and $nativeCodexLines[6] -eq 'MANAGED=' -and $nativeCodexLines[7] -eq 'BUN=') 'managed native Codex route clears proxy, session, and preload state'

            $nativeClaudeLog = Join-Path $temporary 'native-claude.log'
            $env:FAKE_CLAUDE_NATIVE_LOG = $nativeClaudeLog
            $env:FAKE_CLAUDE_NATIVE_EXIT = '29'
            & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') claude native-claude arg-two 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -eq 29) 'native Claude route preserves the child exit code'
            $nativeClaudeLines = @([IO.File]::ReadAllLines($nativeClaudeLog))
            Assert-True ($nativeClaudeLines[0] -eq 'ARG1=native-claude' -and $nativeClaudeLines[1] -eq 'ARG2=arg-two' -and $nativeClaudeLines[2] -eq 'ARG3=') 'native Claude route preserves exact argv'
            Assert-True ($nativeClaudeLines[3] -eq 'BASE=' -and $nativeClaudeLines[4] -eq 'AUTH_TOKEN=' -and $nativeClaudeLines[5] -eq 'PROXY_TOKEN=') 'managed native Claude route clears provider and proxy credentials'
            Assert-True ($nativeClaudeLines[6] -eq 'MANAGED=' -and $nativeClaudeLines[7] -eq 'BUN=--preload C:/user/preload.cjs') 'managed native Claude route clears its session marker and only its own preload'

            Remove-Item Env:CLAUDEX_MANAGED_SESSION -ErrorAction SilentlyContinue
            $env:ANTHROPIC_BASE_URL = 'https://caller-provider.invalid'
            $env:ANTHROPIC_AUTH_TOKEN = 'caller-provider-secret'
            $env:CLAUDEX_PROXY_TOKEN = 'must-never-reach-native'
            $env:BUN_OPTIONS = '--preload C:/user/native-preload.cjs'
            $env:CLAUDE_CODE_USE_BEDROCK = '1'
            $env:CLAUDE_CODE_USE_VERTEX = '1'
            $env:CLAUDE_CODE_USE_FOUNDRY = '1'
            $env:ANTHROPIC_BEDROCK_BASE_URL = 'https://bedrock.invalid'
            $env:ANTHROPIC_VERTEX_BASE_URL = 'https://vertex.invalid'
            $env:ANTHROPIC_FOUNDRY_BASE_URL = 'https://foundry.invalid'
            $env:FAKE_CLAUDE_NATIVE_EXIT = '23'
            & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') --remote-control hosted-session 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -eq 23) 'Remote Control route preserves the native Claude exit code'
            $remoteLines = @([IO.File]::ReadAllLines($nativeClaudeLog))
            Assert-True ($remoteLines[0] -eq 'ARG1=--remote-control' -and $remoteLines[1] -eq 'ARG2=hosted-session' -and $remoteLines[2] -eq 'ARG3=') 'Remote Control route preserves exact Claude argv'
            Assert-True ($remoteLines[3] -eq 'BASE=' -and $remoteLines[4] -eq 'AUTH_TOKEN=' -and $remoteLines[5] -eq 'PROXY_TOKEN=') 'Remote Control forces a first-party provider boundary'
            Assert-True ($remoteLines[7] -eq 'BUN=--preload C:/user/native-preload.cjs') 'Remote Control preserves caller-owned native Bun options'
            Assert-True ($remoteLines[8] -eq 'PROVIDERS=|||||') 'Remote Control clears alternate provider selectors and base URLs'

            $env:FAKE_CLAUDE_NATIVE_EXIT = '19'
            & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') ultrareview review-target 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -eq 19) 'Ultrareview route preserves the native Claude exit code'
            $ultrareviewLines = @([IO.File]::ReadAllLines($nativeClaudeLog))
            Assert-True ($ultrareviewLines[0] -eq 'ARG1=ultrareview' -and $ultrareviewLines[1] -eq 'ARG2=review-target' -and $ultrareviewLines[2] -eq 'ARG3=') 'Ultrareview route preserves exact Claude argv'
            Assert-True ($ultrareviewLines[3] -eq 'BASE=' -and $ultrareviewLines[4] -eq 'AUTH_TOKEN=' -and $ultrareviewLines[5] -eq 'PROXY_TOKEN=') 'Ultrareview forces a first-party provider boundary'
        } finally {
            foreach ($nativeBoundaryName in $nativeBoundaryEnvironment.Keys) {
                $nativeBoundaryValue = $nativeBoundaryEnvironment[$nativeBoundaryName]
                if ($null -eq $nativeBoundaryValue) { Remove-Item -LiteralPath "Env:$nativeBoundaryName" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($nativeBoundaryName, $nativeBoundaryValue, 'Process') }
            }
        }
    }

    $authRecoveryHelper = Join-Path $temporary 'auth-recovery-helper.ps1'
    [IO.File]::WriteAllText($authRecoveryHelper, @'
param(
    [Parameter(Position = 0)] [string] $Action,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Remaining
)
Add-Content -LiteralPath $env:CLAUDEX_TEST_AUTH_RECOVERY_LOG -Value $Action
switch ($Action) {
    'sync' {
        if (-not (Test-Path -LiteralPath $env:CLAUDEX_TEST_AUTH_RECOVERY_MARKER -PathType Leaf)) {
            New-Item -Path $env:CLAUDEX_TEST_AUTH_RECOVERY_MARKER -ItemType File | Out-Null
            exit 11
        }
        exit 0
    }
    'login' { exit 0 }
    'watch' { exit 0 }
    'status' { exit 0 }
    default { exit 2 }
}
'@, $utf8)

    $authRecoveryLog = Join-Path $temporary 'auth-recovery.log'
    $authRecoveryMarker = Join-Path $temporary 'auth-recovery.marker'
    $env:CLAUDEX_CODEX_SESSION_HELPER = $authRecoveryHelper
    $env:CLAUDEX_TEST_AUTH_RECOVERY_LOG = $authRecoveryLog
    $env:CLAUDEX_TEST_AUTH_RECOVERY_MARKER = $authRecoveryMarker
    $env:CLAUDEX_TEST_TTY_INPUT = '1'
    $env:CLAUDEX_TEST_TTY_OUTPUT = '1'
    $env:CLAUDEX_SKIP_AUTH_WATCHER = '1'
    $savedCi = [Environment]::GetEnvironmentVariable('CI', 'Process')
    $env:CI = '0'
    try {
        $interactiveAuthOutput = (& (Join-Path $root 'claudex.ps1') --terra auth-recovery-test 2>&1 | Out-String)
        $windowsLauncherSource = Get-Content -LiteralPath (Join-Path $root 'claudex.ps1') -Raw
        Assert-True ($windowsLauncherSource.Contains('Codex sign-in is required. Opening the official Codex browser login')) 'interactive startup explains official Codex login'
        Assert-True ($interactiveAuthOutput.Contains('AUTO=gpt-5.6-terra')) 'interactive startup retries after Codex login'
        $interactiveAuthActions = @(Get-Content -LiteralPath $authRecoveryLog)
        Assert-True (@($interactiveAuthActions | Where-Object { $_ -eq 'sync' }).Count -eq 2) 'interactive startup retries auth synchronization once'
        Assert-True (@($interactiveAuthActions | Where-Object { $_ -eq 'login' }).Count -eq 1) 'interactive startup opens one login flow'
    } finally {
        Remove-Item Env:CLAUDEX_TEST_TTY_INPUT -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_TEST_TTY_OUTPUT -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_SKIP_AUTH_WATCHER -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_CODEX_SESSION_HELPER -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_TEST_AUTH_RECOVERY_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_TEST_AUTH_RECOVERY_MARKER -ErrorAction SilentlyContinue
        if ($null -eq $savedCi) { Remove-Item Env:CI -ErrorAction SilentlyContinue }
        else { $env:CI = $savedCi }
    }

    $nativeProfile = Join-Path $temporary 'native-claude-profile'
    $nativeManagedPreload = '--preload ' + (Join-Path $testConfig 'preload.cjs').Replace('\', '/').Replace(' ', '\ ')
    $nativeSavedEnvironment = @{}
    foreach ($nativeName in @('CLAUDEX_NODE_BIN', 'CLAUDEX_CLAUDE_CONFIG_DIR', 'CLAUDE_CONFIG_DIR', 'CLAUDEX_PROXY_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'CLAUDE_CODE_AUTO_MODE_MODEL', 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD', 'CLAUDEX_INTERACTIVE_TUI', 'CLAUDEX_MANAGED_SESSION', 'BUN_OPTIONS')) {
        $nativeSavedEnvironment[$nativeName] = [Environment]::GetEnvironmentVariable($nativeName, 'Process')
    }
    try {
        $env:CLAUDEX_NODE_BIN = 'Z:\missing\node.exe'
        $env:CLAUDEX_CLAUDE_CONFIG_DIR = $nativeProfile
        $env:CLAUDE_CONFIG_DIR = 'Z:\managed-profile'
        $env:ANTHROPIC_BASE_URL = 'https://managed.invalid'
        $env:ANTHROPIC_AUTH_TOKEN = 'managed-secret'
        $env:CLAUDEX_PROXY_TOKEN = 'managed-proxy-secret'
        $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'gpt-5.6-sol'
        $env:CLAUDE_CODE_AUTO_MODE_MODEL = 'gpt-5.6-terra'
        $env:CLAUDEX_INTERACTIVE_TUI = '1'
        $env:CLAUDEX_MANAGED_SESSION = '1'
        $env:BUN_OPTIONS = "$nativeManagedPreload --preload C:/user/preload.cjs"
        $nativeClaudeOutput = (& (Join-Path $root 'claudex.ps1') claude native-test 'arg with spaces' | Out-String)
        Assert-True ($env:CLAUDE_CONFIG_DIR -eq 'Z:\managed-profile') 'native Claude route restores the caller Claude profile'
        Assert-True ($env:ANTHROPIC_BASE_URL -eq 'https://managed.invalid' -and $env:ANTHROPIC_AUTH_TOKEN -eq 'managed-secret') 'native Claude route restores caller provider state'
        Assert-True ($env:CLAUDEX_PROXY_TOKEN -eq 'managed-proxy-secret') 'native Claude route restores the caller proxy token after child exit'
        Assert-True ($env:ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'gpt-5.6-sol' -and $env:CLAUDE_CODE_AUTO_MODE_MODEL -eq 'gpt-5.6-terra') 'native Claude route restores caller model routing'
        Assert-True ($env:CLAUDEX_INTERACTIVE_TUI -eq '1' -and $env:CLAUDEX_MANAGED_SESSION -eq '1' -and $env:BUN_OPTIONS -eq "$nativeManagedPreload --preload C:/user/preload.cjs") 'native Claude route restores caller session and Bun state'
    } finally {
        foreach ($nativeName in $nativeSavedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($nativeName, $nativeSavedEnvironment[$nativeName], 'Process')
        }
    }
    Assert-True ($nativeClaudeOutput.Contains('ARGC=2') -and $nativeClaudeOutput.Contains('ARGS=native-test arg with spaces')) 'native Claude route preserves argument boundaries'
    Assert-True ($nativeClaudeOutput.Contains("CONFIG=$nativeProfile")) 'native Claude route selects the normal Claude profile'
    Assert-True ($nativeClaudeOutput.Contains('BASE=') -and -not $nativeClaudeOutput.Contains('BASE=https://managed.invalid')) 'native Claude route removes the compatibility provider'
    Assert-True ($nativeClaudeOutput.Contains('AUTH_TOKEN=') -and -not $nativeClaudeOutput.Contains('AUTH_TOKEN=managed-secret')) 'native Claude route removes the compatibility provider credential'
    Assert-True ($nativeClaudeOutput.Contains('PROXY_TOKEN=') -and -not $nativeClaudeOutput.Contains('PROXY_TOKEN=managed-proxy-secret')) 'native Claude route never exposes the Claudex proxy token'
    Assert-True ($nativeClaudeOutput.Contains('OPUS=') -and -not $nativeClaudeOutput.Contains('OPUS=gpt-5.6-sol')) 'native Claude route removes managed model aliases'
    Assert-True ($nativeClaudeOutput.Contains('AUTO=') -and -not $nativeClaudeOutput.Contains('AUTO=gpt-5.6-terra')) 'native Claude route removes managed classifier routing'
    Assert-True ($nativeClaudeOutput.Contains('BUN=--preload C:/user/preload.cjs')) 'native Claude route preserves non-Claudex Bun options'
    Assert-True ($nativeClaudeOutput.Contains('INTERACTIVE=') -and -not $nativeClaudeOutput.Contains('INTERACTIVE=1')) 'native Claude route removes Claudex session state'

    $nativeUserSavedEnvironment = @{}
    foreach ($nativeName in @('CLAUDEX_CLAUDE_CONFIG_DIR', 'CLAUDE_CONFIG_DIR', 'CLAUDEX_PROXY_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'CLAUDE_CODE_AUTO_MODE_MODEL', 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD', 'CLAUDEX_MANAGED_SESSION', 'BUN_OPTIONS')) {
        $nativeUserSavedEnvironment[$nativeName] = [Environment]::GetEnvironmentVariable($nativeName, 'Process')
    }
    try {
        Remove-Item Env:CLAUDEX_CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEX_MANAGED_SESSION -ErrorAction SilentlyContinue
        $env:CLAUDE_CONFIG_DIR = 'C:\user\claude-profile'
        $env:ANTHROPIC_BASE_URL = 'https://custom-provider.invalid'
        $env:ANTHROPIC_AUTH_TOKEN = 'custom-provider-secret'
        $env:CLAUDEX_PROXY_TOKEN = 'native-must-not-see-this'
        $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-custom'
        $env:CLAUDE_CODE_AUTO_MODE_MODEL = 'custom-auto'
        $env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = '1'
        $env:BUN_OPTIONS = '--preload C:/user/native-preload.cjs'
        $nativeUserOutput = (& (Join-Path $root 'claudex.ps1') claude native-user-settings | Out-String)
    } finally {
        foreach ($nativeName in $nativeUserSavedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($nativeName, $nativeUserSavedEnvironment[$nativeName], 'Process')
        }
    }
    Assert-True ($nativeUserOutput.Contains('CONFIG=C:\user\claude-profile')) 'native Claude route preserves an explicit user profile'
    Assert-True ($nativeUserOutput.Contains('OPUS=claude-custom') -and $nativeUserOutput.Contains('AUTO=custom-auto')) 'native Claude route preserves user model settings'
    Assert-True ($nativeUserOutput.Contains('ADDITIONAL_DIR_MD=1')) 'native Claude route preserves user additional-directory instructions'
    Assert-True ($nativeUserOutput.Contains('BUN=--preload C:/user/native-preload.cjs')) 'native Claude route preserves user Bun options'
    Assert-True ($nativeUserOutput.Contains('BASE=https://custom-provider.invalid') -and $nativeUserOutput.Contains('AUTH_TOKEN=custom-provider-secret')) 'explicit native Claude route preserves caller-owned gateway settings'
    Assert-True ($nativeUserOutput.Contains('PROXY_TOKEN=') -and -not $nativeUserOutput.Contains('PROXY_TOKEN=native-must-not-see-this')) 'explicit native Claude route never exposes the Claudex proxy token'

    $hostedProviderEnvironment = @{}
    foreach ($hostedProviderName in @('CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_BEDROCK_BASE_URL', 'ANTHROPIC_VERTEX_BASE_URL', 'ANTHROPIC_FOUNDRY_BASE_URL')) {
        $hostedProviderEnvironment[$hostedProviderName] = [Environment]::GetEnvironmentVariable($hostedProviderName, 'Process')
        [Environment]::SetEnvironmentVariable($hostedProviderName, 'caller-provider-setting', 'Process')
    }
    try {
        $hostedProviderOutput = (& (Join-Path $root 'claudex.ps1') --rc hosted-provider-restore-test | Out-String)
        foreach ($hostedProviderName in $hostedProviderEnvironment.Keys) {
            Assert-True ([Environment]::GetEnvironmentVariable($hostedProviderName, 'Process') -eq 'caller-provider-setting') "hosted route restores $hostedProviderName after child exit"
        }
    } finally {
        foreach ($hostedProviderName in $hostedProviderEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($hostedProviderName, $hostedProviderEnvironment[$hostedProviderName], 'Process')
        }
    }
    Assert-True ($hostedProviderOutput.Contains('PROVIDERS=|||||')) 'hosted route clears alternate provider selectors and base URLs in the child'

    $instructionBridgeProbe = Join-Path $temporary 'instruction-bridge-probe.cjs'
    $instructionBridgeLog = Join-Path $temporary 'instruction-bridge-probe.log'
    [IO.File]::WriteAllText($instructionBridgeProbe, @'
const fs = require('fs');
fs.writeFileSync(process.env.CLAUDEX_TEST_INSTRUCTION_BRIDGE_LOG, process.env.CLAUDEX_INSTRUCTION_BRIDGE || '<unset>');
process.stdout.write(JSON.stringify({ addDirs: [], pluginDirs: [], instructions: [], warnings: [] }) + '\n');
'@, $utf8)
    $savedInstructionBridgeEnvironment = @{}
    foreach ($instructionName in @('CLAUDEX_SKILL_BRIDGE_HELPER', 'CLAUDEX_INSTRUCTION_BRIDGE', 'CLAUDEX_TEST_INSTRUCTION_BRIDGE_LOG')) {
        $savedInstructionBridgeEnvironment[$instructionName] = [Environment]::GetEnvironmentVariable($instructionName, 'Process')
    }
    try {
        $env:CLAUDEX_SKILL_BRIDGE_HELPER = $instructionBridgeProbe
        $env:CLAUDEX_TEST_INSTRUCTION_BRIDGE_LOG = $instructionBridgeLog
        Remove-Item Env:CLAUDEX_INSTRUCTION_BRIDGE -ErrorAction SilentlyContinue
        & (Join-Path $root 'claudex.ps1') --terra instruction-default-test | Out-Null
        Assert-True ([IO.File]::ReadAllText($instructionBridgeLog) -eq 'on') 'instruction bridge defaults to on and is passed to the bridge child'
        $env:CLAUDEX_INSTRUCTION_BRIDGE = 'off'
        & (Join-Path $root 'claudex.ps1') --terra instruction-disabled-test | Out-Null
        Assert-True ([IO.File]::ReadAllText($instructionBridgeLog) -eq 'off') 'instruction bridge passes an explicit off value to the bridge child'
        if ($isWindowsPlatform) {
            $savedErrorPreference = $ErrorActionPreference
            try {
                $env:CLAUDEX_INSTRUCTION_BRIDGE = 'invalid'
                $ErrorActionPreference = 'Continue'
                & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') instruction-invalid-test 2>&1 | Out-Null
                $invalidInstructionBridgeExit = $LASTEXITCODE
            } finally { $ErrorActionPreference = $savedErrorPreference }
            Assert-True ($invalidInstructionBridgeExit -eq 2) 'invalid instruction bridge mode is rejected'
        }
    } finally {
        foreach ($instructionName in $savedInstructionBridgeEnvironment.Keys) {
            $instructionValue = $savedInstructionBridgeEnvironment[$instructionName]
            if ($null -eq $instructionValue) { Remove-Item -LiteralPath "Env:$instructionName" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($instructionName, $instructionValue, 'Process') }
        }
    }

    $sourceSettings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
    Assert-True ($null -eq $sourceSettings.PSObject.Properties['autoMode']) 'shipped settings defer to complete upstream auto-mode defaults'

    $seedSettings = Get-Content -LiteralPath (Join-Path $testConfig 'settings.json') -Raw | ConvertFrom-Json
    $seedSettings | Add-Member -NotePropertyName autoMode -NotePropertyValue ([pscustomobject]@{
        allow = @('User custom allow rule')
        environment = @('User custom environment rule')
        soft_deny = @('User custom soft deny rule')
        hard_deny = @('User custom hard deny rule')
    }) -Force
    [IO.File]::WriteAllText((Join-Path $testConfig 'settings.json'), ($seedSettings | ConvertTo-Json -Depth 100), $utf8)

    $skillsOutput = (& (Join-Path $root 'claudex.ps1') skills | Out-String)
    Assert-True ($skillsOutput.Contains('/existing-claude')) 'existing Claude skill discovered'
    Assert-True ($skillsOutput.Contains('/existing-codex')) 'existing Codex skill discovered'

    $output = (& (Join-Path $root 'claudex.ps1') --terra test-prompt | Out-String)
    if (-not $output.Contains('AUTO=gpt-5.6-terra')) {
        $proxyRecoveryLog = Join-Path $testConfig 'logs\proxy-recovery.log'
        $proxyRecoveryDetail = if (Test-Path -LiteralPath $proxyRecoveryLog -PathType Leaf) {
            Get-Content -LiteralPath $proxyRecoveryLog -Raw
        } else { 'proxy recovery log was not created' }
        throw "assertion failed: auto classifier; proxy diagnostics: $proxyRecoveryDetail"
    }
    Assert-True ($output.Contains('BG=gpt-5.6-luna')) 'background classifier'
    Assert-True ($output.Contains('SUBAGENT=') -and -not $output.Contains('SUBAGENT=gpt-5.6-terra')) 'native Claude subagent routing is not globally overridden'
    Assert-True ($output.Contains('ADDITIONAL_DIR_MD=1')) 'generated overlay CLAUDE.md files are enabled for additional directories'
    Assert-True ($output.Contains('CONCURRENCY=3')) 'tool concurrency'
    Assert-True ($output.Contains('RETRIES=15')) 'bounded retries cover bridge recovery'
    Assert-True ($output.Contains('CONTEXT=400000')) 'context window'
    Assert-True ($output.Contains('COMPACT=280000')) 'compaction window'
    Assert-True ($output.Contains('NO_FLICKER=1')) 'stable rendering'
    Assert-True ($output.Contains('ACCESSIBILITY=1')) 'native terminal cursor'
    Assert-True ($output.Contains('DISABLE_1M=1')) 'proxied sessions hide the unsupported Anthropic 1M selector'
    Assert-True ($output.Contains('FABLE=gpt-5.6-sol')) 'Fable selector routes to Sol'
    Assert-True ($output.Contains('FABLE_NAME=GPT-5.6 Sol')) 'Fable selector exposes the Sol display name'
    Assert-True ($output.Contains('OPUS=gpt-5.6-sol')) 'single Sol alias'
    Assert-True ($output.Contains('OPUS_NAME=GPT-5.6 Sol')) 'friendly name'
    Assert-True ($output.Contains('BUN=--preload')) 'proxied session preload'
    Assert-True ($output.Contains('INTERACTIVE=') -and -not $output.Contains('INTERACTIVE=1')) 'non-interactive output filter remains available'
    Assert-True ($output.Contains('POWERSHELL_TOOL=1')) 'native PowerShell tool'
    Assert-True ($output.Contains('--permission-mode auto')) 'auto permissions'
    Assert-True ($output.Contains('--model gpt-5.6-terra')) 'startup model'
    Assert-True ($output.Contains('--add-dir')) 'Claude and Codex skill overlay forwarded'
    Assert-True ($output.Contains('Do not spawn or delegate to additional agents')) 'nested agent guard'
    Assert-True ($output.Contains('Unless you are a teammate in a native Agent Team that the user explicitly requested')) 'team-compatible subagent task ownership'
    Assert-True ($output.Contains('Native Agent Teams may be created only when the user explicitly requests')) 'explicit Agent Teams remain available within the managed capacity'
    Assert-True ($output.Contains('for ordinary Agent delegation, the Sol leader owns')) 'ordinary delegation retains Sol task ownership'
    Assert-True ($output.Contains('Before every final answer, call TaskList and reconcile every entry')) 'leader task reconciliation'
    Assert-True ($output.Contains('Never leave stale in_progress tasks after their work is done')) 'stale task guard'
    Assert-True ($output.Contains('operate as a Codex coding agent inside Claude Code')) 'Codex tuning guard'
    Assert-True ($output.Contains('Ask as few questions as possible')) 'low-question autonomy guard'
    Assert-True ($output.Contains('Never repeat a question the user already answered')) 'no-repeat question guard'
    Assert-True ($output.Contains('claudex-codex-skill-references')) 'Codex skill reference compatibility plugin forwarded'
    Assert-True ($output.Contains('Do not call EnterPlanMode')) 'conservative plan mode guard'
    Assert-True ($output.Contains('"Terra (high)"')) 'Terra agent name includes its configured effort'
    Assert-True ($output.Contains('"Luna (medium)"')) 'Luna agent name includes its configured effort'
    Assert-True ($output.Contains('Terra (high) - Audit JSON parser bugs')) 'model, effort, and task activity label guidance'
    Assert-True (-not $output.Contains('"claudex-deep"')) 'legacy deep alias removed'
    Assert-True (-not $output.Contains('"claudex-builder"')) 'legacy builder alias removed'
    Assert-True (-not $output.Contains('"claudex-fast"')) 'legacy fast alias removed'
    Assert-True (-not $output.Contains('"model":"gpt-5.6-sol"')) 'leader model is not delegated'

    $savedUserSubagentModel = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_SUBAGENT_MODEL', 'Process')
    try {
        $env:CLAUDE_CODE_SUBAGENT_MODEL = 'caller-owned-subagent'
        $userSubagentOutput = (& (Join-Path $root 'claudex.ps1') --terra explicit-subagent-test | Out-String)
        Assert-True ($env:CLAUDE_CODE_SUBAGENT_MODEL -eq 'caller-owned-subagent') 'managed launch restores the caller subagent model'
    } finally {
        if ($null -eq $savedUserSubagentModel) { Remove-Item Env:CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue }
        else { $env:CLAUDE_CODE_SUBAGENT_MODEL = $savedUserSubagentModel }
    }
    Assert-True ($userSubagentOutput.Contains('SUBAGENT=caller-owned-subagent')) 'managed launch preserves an explicit caller subagent model'

    $delimiterCommandLine = '""' + (Join-Path $root 'claudex.cmd') + '" --terra -- --safe-mode --agents --permission-mode --model literal-prompt-token"'
    $delimiterOutput = (& $env:ComSpec /d /s /c $delimiterCommandLine 2>&1 | Out-String)
    $delimiterExit = $LASTEXITCODE
    Assert-True ($delimiterExit -eq 0) "installed Windows delimiter route exits successfully; output=$delimiterOutput"
    Assert-True ($delimiterOutput.Contains('"Terra (high)"')) "flag like prompt text after the delimiter does not disable managed agents; output=$delimiterOutput"
    Assert-True ($delimiterOutput.Contains('--permission-mode auto')) 'flag like prompt text after the delimiter does not disable managed permissions'
    Assert-True ($delimiterOutput.Contains('--model gpt-5.6-terra')) 'flag like model text after the delimiter does not replace the selected startup model'

    $restrictedToolsOutput = (& (Join-Path $root 'claudex.ps1') --tools '' --print restricted-tools-test | Out-String)
    Assert-True (-not $restrictedToolsOutput.Contains('Before every final answer, call TaskList')) 'restricted tool surfaces do not receive impossible task lifecycle requirements'
    $disallowedLifecycleOutput = (& (Join-Path $root 'claudex.ps1') --disallowedTools 'TaskList Agent' restricted-tools-test | Out-String)
    Assert-True (-not $disallowedLifecycleOutput.Contains('Before every final answer, call TaskList')) 'explicit TaskList and Agent denial suppresses lifecycle requirements'
    $kebabAllowedOutput = (& (Join-Path $root 'claudex.ps1') --allowed-tools=TaskList kebab-tools-test | Out-String)
    Assert-True ($kebabAllowedOutput.Contains('Before every final answer, call TaskList')) 'allowed-tools approval does not remove managed lifecycle tool availability'
    $kebabDisallowedOutput = (& (Join-Path $root 'claudex.ps1') --disallowed-tools=Agent kebab-deny-test | Out-String)
    Assert-True (-not $kebabDisallowedOutput.Contains('Before every final answer, call TaskList')) 'kebab-case disallowed-tools with inline value suppresses impossible lifecycle requirements'
    $unrelatedDisallowedOutput = (& (Join-Path $root 'claudex.ps1') --disallowed-tools=Bash unrelated-deny-test | Out-String)
    Assert-True ($unrelatedDisallowedOutput.Contains('Before every final answer, call TaskList')) 'unrelated Bash denial retains valid managed lifecycle requirements'
    $explicitLifecycleToolsOutput = (& (Join-Path $root 'claudex.ps1') --tools=Agent,TaskList explicit-tools-test | Out-String)
    Assert-True ($explicitLifecycleToolsOutput.Contains('Before every final answer, call TaskList')) 'explicit lifecycle tool availability retains managed lifecycle requirements'
    $inlinePermissionOutput = (& (Join-Path $root 'claudex.ps1') --permission-mode=manual inline-permission-test | Out-String)
    Assert-True ($inlinePermissionOutput.Contains('--permission-mode=manual') -and -not $inlinePermissionOutput.Contains('--permission-mode auto')) 'inline permission mode suppresses the managed permission override'
    $inlineAgentsOutput = (& (Join-Path $root 'claudex.ps1') --agents='{}' inline-agents-test | Out-String)
    Assert-True (-not $inlineAgentsOutput.Contains('"Terra (high)"')) 'inline agents definition suppresses managed agent definitions'
    $inlineAgentOutput = (& (Join-Path $root 'claudex.ps1') --agent=reviewer inline-agent-test | Out-String)
    Assert-True (-not $inlineAgentOutput.Contains('"Terra (high)"')) 'inline current-agent selection suppresses managed agent definitions'

    $arityAgentsOutput = (& (Join-Path $root 'claudex.ps1') --plugin-dir --agents arity-agent-value-test | Out-String)
    Assert-True ($arityAgentsOutput.Contains('"Terra (high)"')) 'an option value resembling --agents does not suppress managed agents'
    $arityPermissionOutput = (& (Join-Path $root 'claudex.ps1') --plugin-dir --permission-mode arity-permission-value-test | Out-String)
    Assert-True ($arityPermissionOutput.Contains('--permission-mode auto')) 'an option value resembling --permission-mode does not suppress managed permissions'
    $arityModelOutput = (& (Join-Path $root 'claudex.ps1') --settings --model arity-model-value-test | Out-String)
    Assert-True ($arityModelOutput.Contains('--model gpt-5.6-sol') -and $arityModelOutput.Contains('--settings --model')) 'an option value resembling --model does not replace the managed primary model'

    $forwardedModelOutput = (& (Join-Path $root 'claudex.ps1') --model gpt-5.6-luna explicit-model-test | Out-String)
    $forwardedModelArgs = @($forwardedModelOutput -split "`r?`n" | Where-Object { $_.StartsWith('ARGS=') })[-1]
    Assert-True ($forwardedModelArgs.Contains('--model gpt-5.6-luna')) 'explicit native --model reaches Claude unchanged'
    Assert-True (([regex]::Matches($forwardedModelArgs, '(?:^| )--model(?: |$)')).Count -eq 1) 'explicit native --model suppresses default model injection'
    $env:FAKE_PROXY_MODELS_JSON = '{"data":[{"id":"gpt-5.6-terra"}]}'
    try {
        $fallbackModelOutput = (& (Join-Path $root 'claudex.ps1') --model gpt-5.6-sol --fallback-model=gpt-5.6-terra fallback-model-test | Out-String)
    } finally { Remove-Item Env:FAKE_PROXY_MODELS_JSON -ErrorAction SilentlyContinue }
    Assert-True ($fallbackModelOutput.Contains('--model gpt-5.6-sol') -and $fallbackModelOutput.Contains('--fallback-model=gpt-5.6-terra')) 'available fallback model allows launch when the primary route is unavailable'
    $warningBridge = Join-Path $temporary 'warning-skill-bridge.cjs'
    [IO.File]::WriteAllText($warningBridge, @'
process.stdout.write(JSON.stringify({
  addDirs: [],
  pluginDirs: [],
  instructions: [],
  warnings: ['Skill refresh failed; using the last known good snapshot.\nReview the rejected skill.\u001b]0;owned\u0007\u202ereversed'],
}) + '\n');
'@, $utf8)
    $env:CLAUDEX_SKILL_BRIDGE_HELPER = $warningBridge
    $env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = 'inherited'
    $previousConsoleError = [Console]::Error
    $warningConsoleError = New-Object IO.StringWriter
    [Console]::SetError($warningConsoleError)
    try {
        $warningBridgeOutput = (& (Join-Path $root 'claudex.ps1') --terra warning-test | Out-String)
        $warningBridgeOutput += $warningConsoleError.ToString()
        $warningConsoleError.GetStringBuilder().Clear() | Out-Null
        $warningBridgeSecondOutput = (& (Join-Path $root 'claudex.ps1') --terra warning-test-two | Out-String)
        $warningBridgeSecondOutput += $warningConsoleError.ToString()
    } finally {
        [Console]::SetError($previousConsoleError)
        $warningConsoleError.Dispose()
        Remove-Item Env:CLAUDEX_SKILL_BRIDGE_HELPER -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD -ErrorAction SilentlyContinue
    }
    Assert-True ($warningBridgeOutput.Contains('claudex: skill bridge warning: Skill refresh failed; using the last known good snapshot. Review the rejected skill.')) 'ordinary Windows launch surfaces skill bridge warnings on one line'
    Assert-True (-not $warningBridgeOutput.Contains([string][char]27) -and -not $warningBridgeOutput.Contains([string][char]7) -and -not $warningBridgeOutput.Contains([string][char]0x202e)) 'skill bridge warnings strip terminal and bidi controls'
    Assert-True (-not $warningBridgeSecondOutput.Contains('claudex: skill bridge warning:')) 'identical skill bridge warnings are throttled'
    Assert-True ($warningBridgeOutput.Contains('AUTO=gpt-5.6-terra')) 'skill bridge warning does not prevent launch'
    Assert-True ($warningBridgeOutput.Contains('ADDITIONAL_DIR_MD=inherited')) 'launches without bridged instructions preserve the caller additional-directory setting'
    $env:CLAUDEX_MODEL = 'gpt-5.6-luna'
    try {
        $configuredModel = (& (Join-Path $root 'claudex.ps1') test-prompt | Out-String)
        Assert-True ($configuredModel.Contains('--model gpt-5.6-luna')) 'configured default model routes the launch'
        $configuredModelOverride = (& (Join-Path $root 'claudex.ps1') --terra test-prompt | Out-String)
        Assert-True ($configuredModelOverride.Contains('--model gpt-5.6-terra')) 'explicit model shortcut overrides configured default'
        $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = 'inherited'
        $env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = 'inherited'
        $directChromeSettings = Join-Path $temporary 'direct-chrome-settings.json'
        [IO.File]::WriteAllText($directChromeSettings, '{}', $utf8)
        $env:CLAUDEX_SETTINGS_FILE = $directChromeSettings
        try {
            $configuredChrome = (& (Join-Path $root 'claudex.ps1') --claude-chrome --print chrome-test | Out-String)
            Assert-True ($env:CLAUDE_CODE_DISABLE_1M_CONTEXT -eq 'inherited') 'direct Chrome restores inherited 1M override'
            Assert-True ($env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD -eq 'inherited') 'direct Chrome restores inherited additional-directory instruction setting'
        }
        finally {
            Remove-Item Env:CLAUDE_CODE_DISABLE_1M_CONTEXT -ErrorAction SilentlyContinue
            Remove-Item Env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD -ErrorAction SilentlyContinue
            Remove-Item Env:CLAUDEX_SETTINGS_FILE -ErrorAction SilentlyContinue
        }
        Assert-True (-not $configuredChrome.Contains('--model gpt-5.6-luna')) 'direct Chrome ignores managed default model'
        Assert-True (-not $configuredChrome.Contains('--settings') -and -not $configuredChrome.Contains($directChromeSettings)) 'direct Chrome ignores Claudex custom settings injection'
        Assert-True ($configuredChrome.Contains('ADDITIONAL_DIR_MD=inherited')) 'direct Chrome preserves the caller additional-directory instruction setting'
        Assert-True ($configuredChrome.Contains('DISABLE_1M=') -and -not $configuredChrome.Contains('DISABLE_1M=inherited')) 'direct Chrome clears managed 1M override'
    } finally { Remove-Item Env:CLAUDEX_MODEL -ErrorAction SilentlyContinue }
    $env:CLAUDEX_TEST_TTY_OUTPUT = '1'
    try { $interactiveWrapperOutput = (& (Join-Path $root 'claudex.ps1') --terra interactive-render-test | Out-String) }
    finally { Remove-Item Env:CLAUDEX_TEST_TTY_OUTPUT -ErrorAction SilentlyContinue }
    Assert-True ($interactiveWrapperOutput.Contains('INTERACTIVE=1')) 'interactive wrapper disables TUI output rewriting'
    Assert-True ($interactiveWrapperOutput.Contains('CHATGPT_PLAN=ChatGPT Pro')) 'interactive wrapper exposes the detected ChatGPT plan'
    [IO.File]::WriteAllText((Join-Path $testConfig 'usage-cache\limits.json'), '{malformed', $utf8)
    $env:CLAUDEX_TEST_TTY_OUTPUT = '1'
    try { $repairedPlanOutput = (& (Join-Path $root 'claudex.ps1') --terra repaired-plan-cache-test | Out-String) }
    finally { Remove-Item Env:CLAUDEX_TEST_TTY_OUTPUT -ErrorAction SilentlyContinue }
    Assert-True ($repairedPlanOutput.Contains('CHATGPT_PLAN=ChatGPT Pro')) 'interactive wrapper refreshes a malformed plan cache'
    $repairedPlanCache = Get-Content -LiteralPath (Join-Path $testConfig 'usage-cache\limits.json') -Raw | ConvertFrom-Json
    Assert-True ($repairedPlanCache.plan_type -eq 'pro') 'malformed plan cache is replaced by a valid snapshot'
    $composedSettings = Get-Content -LiteralPath (Join-Path $testConfig 'settings.json') -Raw | ConvertFrom-Json
    Assert-True (@($composedSettings.autoMode.allow | Where-Object { $_ -eq 'Default allow rule' }).Count -eq 1) 'upstream auto-mode allow rule preserved'
    Assert-True (@($composedSettings.autoMode.allow | Where-Object { $_ -eq 'User custom allow rule' }).Count -eq 1) 'user auto-mode allow rule preserved'
    Assert-True (@($composedSettings.autoMode.allow | Where-Object { $_.StartsWith('Explicit Action Approval:') }).Count -eq 1) 'Claudex auto-mode allow rule composed'
    Assert-True (@($composedSettings.autoMode.environment | Where-Object { $_ -eq 'Default environment rule' }).Count -eq 1) 'upstream auto-mode environment preserved'
    Assert-True (@($composedSettings.autoMode.environment | Where-Object { $_ -eq 'User custom environment rule' }).Count -eq 1) 'user auto-mode environment rule preserved'
    Assert-True (@($composedSettings.autoMode.environment | Where-Object { $_.StartsWith('Explicitly approved development transfer:') }).Count -eq 1) 'approved development transfer composed'
    Assert-True (@($composedSettings.autoMode.soft_deny | Where-Object { $_ -eq 'Default soft deny' }).Count -eq 1) 'upstream soft deny preserved'
    Assert-True (@($composedSettings.autoMode.soft_deny | Where-Object { $_ -eq 'User custom soft deny rule' }).Count -eq 1) 'user soft deny preserved'
    Assert-True (@($composedSettings.autoMode.soft_deny | Where-Object { $_.StartsWith('Approved Private Development Transfer') }).Count -eq 1) 'approved private transfer is named-specific soft consent'
    $managedHardDeny = @($composedSettings.autoMode.hard_deny | Where-Object { $_.StartsWith('Data Exfiltration:') -and $_.Contains('Claudex scoped private development transfer exception:') })
    Assert-True ($managedHardDeny.Count -eq 1) 'data exfiltration hard deny has one scoped exception'
    Assert-True ($managedHardDeny[0].Contains('public destination') -and $managedHardDeny[0].Contains('credentials or secrets') -and $managedHardDeny[0].Contains('different host')) 'hard-deny exception retains protected destinations and data'
    Assert-True (@($composedSettings.autoMode.hard_deny | Where-Object { $_ -eq 'User custom hard deny rule' }).Count -eq 1) 'user hard deny preserved'
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
    Assert-True (@($updatedSettings.autoMode.soft_deny | Where-Object { $_ -eq 'Default soft deny' }).Count -eq 0) 'removed upstream soft deny does not persist'
    Assert-True (@($updatedSettings.autoMode.soft_deny | Where-Object { $_ -eq 'Updated soft deny' }).Count -eq 1) 'updated upstream soft deny is active'
    Assert-True (@($updatedSettings.autoMode.soft_deny | Where-Object { $_ -eq 'User custom soft deny rule' }).Count -eq 1) 'custom soft deny survives upstream replacement'
    Assert-True (@($updatedSettings.autoMode.hard_deny | Where-Object { $_.StartsWith('Data Exfiltration: updated hard deny') -and $_.Contains('Claudex scoped private development transfer exception:') }).Count -eq 1) 'updated hard deny receives scoped exception once'
    Assert-True (@($updatedSettings.autoMode.hard_deny | Where-Object { $_ -eq 'User custom hard deny rule' }).Count -eq 1) 'custom hard deny survives upstream replacement'

    if ($isWindowsPlatform) {
        $remoteCurlLog = Join-Path $temporary 'remote-proxy-curl.log'
        $savedProxyUrl = [Environment]::GetEnvironmentVariable('CLAUDEX_PROXY_URL', 'Process')
        $savedRemoteOptIn = [Environment]::GetEnvironmentVariable('CLAUDEX_ALLOW_REMOTE_PROXY', 'Process')
        $env:CLAUDEX_PROXY_URL = 'https://proxy.example.test'
        Remove-Item Env:CLAUDEX_ALLOW_REMOTE_PROXY -ErrorAction SilentlyContinue
        $env:FAKE_CURL_CALL_LOG = $remoteCurlLog
        $shellPath = (Get-Process -Id $PID).Path
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $remoteRejectedOutput = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') --terra remote-rejection-test 2>&1
            $remoteRejectedExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorPreference
            if ($null -eq $savedProxyUrl) { Remove-Item Env:CLAUDEX_PROXY_URL -ErrorAction SilentlyContinue } else { $env:CLAUDEX_PROXY_URL = $savedProxyUrl }
            if ($null -eq $savedRemoteOptIn) { Remove-Item Env:CLAUDEX_ALLOW_REMOTE_PROXY -ErrorAction SilentlyContinue } else { $env:CLAUDEX_ALLOW_REMOTE_PROXY = $savedRemoteOptIn }
            Remove-Item Env:FAKE_CURL_CALL_LOG -ErrorAction SilentlyContinue
        }
        Assert-True ($remoteRejectedExit -eq 2) 'Windows launcher rejects a remote proxy without explicit opt-in'
        Assert-True (($remoteRejectedOutput | Out-String).Contains('CLAUDEX_ALLOW_REMOTE_PROXY=1')) 'remote proxy rejection explains the trusted HTTPS opt-in'
        Assert-True (-not (Test-Path -LiteralPath $remoteCurlLog -PathType Leaf)) 'remote proxy rejection occurs before the credential-bearing curl request'

        $unmanaged401StartLog = Join-Path $temporary 'unmanaged-401-proxy-start.log'
        $unmanaged401ErrorLog = Join-Path $temporary 'unmanaged-401-proxy-error.log'
        $env:FAKE_PROXY_HTTP_STATUS = '401'
        $env:FAKE_PROXY_START_LOG = $unmanaged401StartLog
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $unmanaged401Output = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') --terra unmanaged-401-test 2> $unmanaged401ErrorLog
            $unmanaged401Exit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorPreference
            Remove-Item Env:FAKE_PROXY_HTTP_STATUS -ErrorAction SilentlyContinue
            Remove-Item Env:FAKE_PROXY_START_LOG -ErrorAction SilentlyContinue
        }
        Assert-True ($unmanaged401Exit -ne 0) 'Windows launcher rejects an unverified loopback process after HTTP 401'
        $unmanaged401Stderr = if (Test-Path -LiteralPath $unmanaged401ErrorLog -PathType Leaf) { Get-Content -LiteralPath $unmanaged401ErrorLog -Raw } else { '' }
        $unmanaged401Text = ((($unmanaged401Output | Out-String) + $unmanaged401Stderr) -replace '\s+', ' ')
        Assert-True ($unmanaged401Text.Contains('will not stop an unverified process')) 'unverified loopback 401 explains the managed-process safety boundary'
        Assert-True (-not (Test-Path -LiteralPath $unmanaged401StartLog -PathType Leaf)) 'unverified loopback 401 never starts a replacement proxy'

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

        $neverReadyFile = Join-Path $temporary 'windows-proxy-never-ready'
        $neverReadyPidFile = Join-Path $temporary 'windows-proxy-never-ready.pid'
        $env:FAKE_PROXY_READY_FILE = $neverReadyFile
        $env:FAKE_PROXY_EXIT_BEFORE_READY = '1'
        $env:FAKE_PROXY_PID_FILE = $neverReadyPidFile
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'claudex.ps1') --terra never-ready-test 2>&1 | Out-Null
            $neverReadyExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorPreference
            Remove-Item Env:FAKE_PROXY_READY_FILE -ErrorAction SilentlyContinue
            Remove-Item Env:FAKE_PROXY_EXIT_BEFORE_READY -ErrorAction SilentlyContinue
            Remove-Item Env:FAKE_PROXY_PID_FILE -ErrorAction SilentlyContinue
        }
        Assert-True ($neverReadyExit -ne 0) 'Windows launcher reports a proxy process that exits before readiness'
        Assert-True (Test-Path -LiteralPath $neverReadyPidFile -PathType Leaf) 'never-ready proxy test process started'
        $neverReadyPid = [int]([IO.File]::ReadAllText($neverReadyPidFile).Trim())
        Assert-True ($null -eq (Get-Process -Id $neverReadyPid -ErrorAction SilentlyContinue)) 'never-ready proxy process is no longer running'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testConfig 'run\managed-proxy.json') -PathType Leaf)) 'never-ready proxy metadata is removed'
    }

    $chromeBoundaryEnvironment = @{}
    foreach ($chromeName in @(
        'BUN_OPTIONS', 'CLAUDEX_PROXY_TOKEN', 'CLAUDEX_PROXY_URL', 'CLAUDEX_PROXY_CONFIG',
        'CLAUDEX_CODEX_AUTH_DIR', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX',
        'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_BEDROCK_BASE_URL', 'ANTHROPIC_VERTEX_BASE_URL',
        'ANTHROPIC_FOUNDRY_BASE_URL'
    )) {
        $chromeBoundaryEnvironment[$chromeName] = [Environment]::GetEnvironmentVariable($chromeName, 'Process')
    }
    try {
        $env:BUN_OPTIONS = ''
        $env:CLAUDEX_PROXY_TOKEN = 'chrome-proxy-secret'
        $env:CLAUDEX_PROXY_URL = 'http://127.0.0.1:9999'
        $env:CLAUDEX_PROXY_CONFIG = 'C:\managed\proxy.yaml'
        $env:CLAUDEX_CODEX_AUTH_DIR = 'C:\managed\auth'
        $env:CLAUDE_CODE_USE_BEDROCK = '1'
        $env:CLAUDE_CODE_USE_VERTEX = '1'
        $env:CLAUDE_CODE_USE_FOUNDRY = '1'
        $env:ANTHROPIC_BEDROCK_BASE_URL = 'https://bedrock.invalid'
        $env:ANTHROPIC_VERTEX_BASE_URL = 'https://vertex.invalid'
        $env:ANTHROPIC_FOUNDRY_BASE_URL = 'https://foundry.invalid'
        $directChrome = (& (Join-Path $root 'claudex.ps1') --claude-chrome test-prompt | Out-String)
        Assert-True ($env:CLAUDEX_PROXY_TOKEN -eq 'chrome-proxy-secret' -and $env:CLAUDEX_PROXY_CONFIG -eq 'C:\managed\proxy.yaml') 'direct Chrome restores caller proxy state after child exit'
        Assert-True ($env:CLAUDE_CODE_USE_BEDROCK -eq '1' -and $env:ANTHROPIC_FOUNDRY_BASE_URL -eq 'https://foundry.invalid') 'direct Chrome restores caller provider selectors after child exit'
    } finally {
        foreach ($chromeName in $chromeBoundaryEnvironment.Keys) {
            $chromeValue = $chromeBoundaryEnvironment[$chromeName]
            if ($null -eq $chromeValue) { Remove-Item -LiteralPath "Env:$chromeName" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($chromeName, $chromeValue, 'Process') }
        }
    }
    Assert-True ($directChrome.Contains('ARGS=--chrome test-prompt')) 'direct Chrome arguments'
    Assert-True ($directChrome.Contains('BUN=')) 'direct Chrome BUN output'
    Assert-True (-not $directChrome.Contains('BUN=--preload')) 'direct Chrome preload isolation'
    Assert-True (-not $directChrome.Contains('BASE=http')) 'direct Chrome proxy isolation'
    Assert-True ($directChrome.Contains('PROXY_TOKEN=') -and -not $directChrome.Contains('PROXY_TOKEN=chrome-proxy-secret')) 'direct Chrome never exposes the Claudex proxy token'
    Assert-True ($directChrome.Contains('PROXY_URL=') -and -not $directChrome.Contains('PROXY_URL=http://127.0.0.1:9999')) 'direct Chrome clears the raw Claudex proxy URL'
    Assert-True ($directChrome.Contains('PROXY_CONFIG=') -and -not $directChrome.Contains('C:\managed\proxy.yaml') -and $directChrome.Contains('CODEX_AUTH_DIR=') -and -not $directChrome.Contains('C:\managed\auth')) 'direct Chrome clears proxy config and Codex auth paths'
    Assert-True ($directChrome.Contains('PROVIDERS=|||||')) 'direct Chrome clears alternate provider selectors and base URLs'

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
    Assert-True ($solplan.Contains('SUBAGENT=') -and -not $solplan.Contains('SUBAGENT=gpt-5.6-terra')) 'Solplan leaves native implementation-family routing available'

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
    Assert-True ($windowsLauncher.Contains('try { Ensure-ProxyForLaunch $requiredProxyModels }')) 'foreground startup owns interactive Codex login recovery for primary and fallback models'
    Assert-True ($windowsLauncher.Contains('if ($env:CI -and $env:CI -notin')) 'CI startup suppresses interactive Codex login'
    Assert-True ($windowsLauncher.Contains('Codex sign-in is required. Run `claudex --login` in an interactive terminal')) 'noninteractive startup gives prompt-free login guidance'
    $watchLoopStart = $windowsLauncher.IndexOf('function Invoke-ProxyWatchLoop')
    $watchLoopEnd = $windowsLauncher.IndexOf('function Start-ProxyWatcher', $watchLoopStart)
    $watchLoopSource = $windowsLauncher.Substring($watchLoopStart, $watchLoopEnd - $watchLoopStart)
    Assert-True ($watchLoopSource.Contains('Ensure-Proxy') -and -not $watchLoopSource.Contains('Ensure-ProxyForLaunch')) 'background proxy recovery remains prompt-free'
    Assert-True ($windowsLauncher.Contains("if (`$routeCandidate -eq 'opusplan') { @('gpt-5.6-sol', 'gpt-5.6-terra') }")) 'Solplan health checks its two concrete backing models'
    Assert-True ($windowsLauncher.Contains('ConvertTo-WindowsCommandLineArgument')) 'Windows native argv serializer is installed'
    Assert-True ($windowsLauncher.Contains('CopyToAsync([IO.Stream]::Null)')) 'Windows background watchers drain output without contaminating the Claude TUI'
    Assert-True ($windowsLauncher.Contains('if ($null -eq $Value -or $Value.Length -eq 0) { return ''""'' }')) 'Windows native argv serializer preserves empty arguments'
    Assert-True ($windowsLauncher.Contains('if ($character -eq ''"'')')) 'Windows native argv serializer escapes embedded quotes'
    Assert-True ($windowsLauncher.Contains("`$earlyRuntimeBypass = `$true")) 'maintenance and direct Chrome recovery bypass is installed'
    $earlyMaintenanceSource = [regex]::Match($windowsLauncher, '(?m)^\$earlyMaintenanceCommands = .+$').Value
    $maintenanceSource = [regex]::Match($windowsLauncher, '(?m)^\$maintenanceCommands = .+$').Value
    foreach ($maintenanceCommand in @('doctor', 'attach', 'respawn', 'stop', 'kill', 'rm', 'logs')) {
        Assert-True ($earlyMaintenanceSource.Contains("'$maintenanceCommand'")) "Windows $maintenanceCommand bypasses configuration validation"
        Assert-True ($maintenanceSource.Contains("'$maintenanceCommand'")) "Windows $maintenanceCommand suppresses managed launch injection"
    }
    $nativeRouteStart = $windowsLauncher.IndexOf('$nativeHarness = ''''')
    $configImportStart = $windowsLauncher.IndexOf('if (Test-Path -LiteralPath $configFile -PathType Leaf)')
    Assert-True ($nativeRouteStart -ge 0 -and $nativeRouteStart -lt $configImportStart) 'native and hosted routes are selected before Claudex config import'
    Assert-True ($windowsLauncher.Contains('Remove-Item Env:CLAUDEX_PROXY_TOKEN -ErrorAction SilentlyContinue')) 'native children always lose the Claudex proxy bearer'
    Assert-True ($windowsLauncher.Contains('$forceFirstPartyClaude = $true')) 'hosted Claude features force a first-party provider boundary'
    Assert-True ($windowsLauncher.Contains("`$nativeScanOption -in @('--remote-control', '--rc')")) 'Remote Control aliases use the native hosted route'
    Assert-True ($windowsLauncher.Contains('Protect-PrivatePath $headerFile $false')) 'proxy bearer header receives a private Windows DACL'
    Assert-True ($windowsLauncher.Contains("Env-OrDefault 'CLAUDEX_INSTRUCTION_BRIDGE' 'on'")) 'instruction bridge defaults to on'
    Assert-True ($windowsLauncher.Contains("CLAUDEX_INSTRUCTION_BRIDGE must be on or off")) 'instruction bridge mode is validated'
    Assert-True ($windowsLauncher.Contains('$env:CLAUDEX_INSTRUCTION_BRIDGE = $instructionBridgeMode')) 'validated instruction bridge mode is passed to the bridge child'
    Assert-True ($windowsLauncher.Contains("'--allowedTools', '--allowed-tools'")) 'forwarded scanner supports camel and kebab allowed-tools forms'
    Assert-True ($windowsLauncher.Contains("'--disallowedTools', '--disallowed-tools'")) 'forwarded scanner supports camel and kebab disallowed-tools forms'
    Assert-True ($windowsLauncher.Contains("`$scanOption -eq '--tools'")) 'tools override is evaluated against lifecycle tool availability'
    Assert-True ($windowsLauncher.Contains("`$scanOption -in @('--disallowedTools', '--disallowed-tools')")) 'disallowed-tools suppresses lifecycle guidance only through explicit denial parsing'
    Assert-True ($windowsLauncher.Contains("'--add-dir', '--agent', '--agents'")) 'forwarded scanner tracks required-value option arity'
    Assert-True (-not $windowsLauncher.Contains('Remove-Item Env:CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue')) 'managed launch preserves an explicit subagent model'
    Assert-True ($windowsLauncher.Contains("'--bg', '--background'")) 'background launches suppress synchronous resume footer attribution'
    Assert-True ($windowsLauncher.Contains('Ensure-ProxyForLaunch $requiredProxyModels')) 'primary and fallback model routes share preflight'
    Assert-True ($windowsLauncher.Contains('$earlyOption -in $claudeRequiredValueOptions')) 'early maintenance recognition uses the shared option arity table'
    Assert-True ($windowsLauncher.Contains('$maintenanceCommandDetected = $true')) 'maintenance commands can follow documented global options'
    Assert-True ($windowsLauncher.Contains("'CLAUDEX_PROXY_TOKEN', 'CLAUDEX_PROXY_URL', 'CLAUDEX_PROXY_CONFIG', 'CLAUDEX_PROXY_BIN'")) 'first-party Chrome route scrubs raw Claudex proxy state'
    Assert-True ($windowsLauncher.Contains("'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'")) 'first-party routes scrub alternate provider selectors'
    Assert-True ($windowsLauncher.Contains("CLAUDEX_ALLOW_REMOTE_PROXY=1")) 'Windows launcher documents the explicit trusted HTTPS proxy opt-in'
    Assert-True ($windowsLauncher.Contains('Stop-RecordedManagedProxy')) 'Windows launcher limits authentication recovery to recorded managed proxies'
    Assert-True ($windowsLauncher.Contains('Stop-NewlySpawnedProxy')) 'Windows launcher cleans up a proxy that never becomes ready'

    Remove-Item -LiteralPath $resumeCapture -Force
    $env:FAKE_CLAUDE_RESUME = '1'
    $env:CLAUDEX_TEST_TTY_OUTPUT = '1'
    $env:CLAUDEX_TEST_RESUME_CAPTURE_FILE = $resumeCapture
    & (Join-Path $root 'claudex.ps1') --bg background-resume-test | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $resumeCapture -PathType Leaf)) 'background launch does not claim a synchronous resume footer'

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
    Assert-True (-not $bare.Contains('--add-dir')) 'bare mode skill bridge suppressed'
    Assert-True (-not $bare.Contains('--append-system-prompt')) 'bare mode leader prompt suppressed'
    Assert-True (-not $bare.Contains('--permission-mode')) 'bare mode permission override suppressed'

    $explicitAgents = (& (Join-Path $root 'claudex.ps1') --agents '{}' test-prompt | Out-String)
    Assert-True ($explicitAgents.Contains('--agents {}')) 'explicit custom agents preserved'
    Assert-True (-not $explicitAgents.Contains('"Terra (high)"')) 'managed agents suppressed by explicit custom agents'
    Assert-True ($explicitAgents.Contains('Ask as few questions as possible')) 'custom agents retain low-question leader guard'
    Assert-True ($explicitAgents.Contains('Never repeat a question the user already answered')) 'custom agents retain no-repeat question guard'
    Assert-True ($explicitAgents.Contains("Treat the user's explicit approval as decisive")) 'custom agents retain explicit-approval guard'

    $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = 'inherited'
    try {
        $maintenance = (& (Join-Path $root 'claudex.ps1') mcp list | Out-String)
        Assert-True ($env:CLAUDE_CODE_DISABLE_1M_CONTEXT -eq 'inherited') 'maintenance command restores inherited 1M override'
    }
    finally { Remove-Item Env:CLAUDE_CODE_DISABLE_1M_CONTEXT -ErrorAction SilentlyContinue }
    Assert-True (-not $maintenance.Contains('BASE=http')) 'maintenance command bypasses model proxy'
    Assert-True (-not $maintenance.Contains('--agents')) 'maintenance command bypasses session injection'
    Assert-True ($maintenance.Contains('DISABLE_1M=') -and -not $maintenance.Contains('DISABLE_1M=inherited')) 'maintenance command clears managed 1M override'

    $state = Get-Content -LiteralPath (Join-Path $testConfig '.claude.json') -Raw | ConvertFrom-Json
    $stateIds = @($state.additionalModelOptionsCache | ForEach-Object { $_.value })
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-sol' }).Count -eq 1) 'one Sol cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-terra' }).Count -eq 1) 'one Terra cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'gpt-5.6-luna' }).Count -eq 1) 'one Luna cache entry'
    Assert-True (@($stateIds | Where-Object { $_ -eq 'opusplan' }).Count -eq 1) 'one Solplan cache entry'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $testConfig 'run') 'model-display.lock'))) 'model cache lock released'

    $doctor = (& (Join-Path $root 'claudex.ps1') --doctor | Out-String)
    Assert-True ($doctor.Contains('CLIProxyAPI: CLIProxyAPI test')) 'proxy version first line'
    Assert-True (-not $doctor.Contains('extra version detail')) 'proxy version extra lines hidden'
    Assert-True ($doctor.Contains('Automatic compaction window: 280000 tokens')) 'doctor compaction'
    Assert-True ($doctor.Contains('Task lifecycle: owned by Sol with final response reconciliation')) 'doctor task lifecycle'
    Assert-True ($doctor.Contains('Managed agents: Terra (high), Luna (medium)')) 'doctor managed agent efforts'
    Assert-True ($doctor.Contains('Context status: stable session')) 'doctor context stabilization'
    Assert-True ($doctor.Contains('Codex usage: status line refresh every 300s')) 'doctor usage refresh'
    Assert-True ($doctor.Contains('Rendering: stable mode with native terminal cursor')) 'doctor rendering hardening'
    Assert-True ($doctor.Contains('Codex authentication: ready (shared ChatGPT session)')) 'doctor shared Codex auth'
    Assert-True ($doctor.Contains('Claude Code updates: on')) 'doctor auto updates'
    Assert-True ($doctor.Contains('Claudex updates: on')) 'doctor Claudex self-updates'
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

    [IO.File]::WriteAllText((Join-Path $testCodexDir 'auth.json'), '{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","tokens":{"access_token":123,"refresh_token":"codex-source-refresh","account_id":"account-test"}}', $utf8)
    $strictAuthError = Join-Path $temporary 'strict-auth-error.log'
    $strictAuthProcess = Start-Process -FilePath $shellPath -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedSessionHelper, 'sync') -RedirectStandardError $strictAuthError -Wait -PassThru
    Assert-True ($strictAuthProcess.ExitCode -eq 14) 'non-string Codex credential JSON is rejected'
    Assert-True (-not (Test-Path -LiteralPath $bridgeAuthFile -PathType Leaf)) 'invalid typed Codex credentials clear the managed bridge session'
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

    if ($isWindowsPlatform) {
        $usageHelper = Join-Path $testConfig 'usage-limit.ps1'
        $blockedCurlLog = Join-Path $temporary 'blocked-usage-url-curl.log'
        $usageUrlRejected = $false
        $env:CLAUDEX_USAGE_SOURCE = 'auto'
        $env:CLAUDEX_USAGE_URL = 'http://127.0.0.1:8123/backend-api/wham/usage'
        $env:FAKE_CURL_CALL_LOG = $blockedCurlLog
        try {
            & $usageHelper -RefreshCache | Out-Null
        } catch {
            $usageUrlRejected = $_.Exception.Message.Contains('CLAUDEX_USAGE_URL must remain https://chatgpt.com/backend-api/wham/usage')
        } finally {
            Remove-Item Env:CLAUDEX_USAGE_URL -ErrorAction SilentlyContinue
            Remove-Item Env:FAKE_CURL_CALL_LOG -ErrorAction SilentlyContinue
        }
        Assert-True $usageUrlRejected 'non-official production usage URL rejected'
        Assert-True (-not (Test-Path -LiteralPath $blockedCurlLog)) 'rejected usage URL never invokes curl'

        $env:CLAUDEX_USAGE_SOURCE = 'web'
        $env:CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL = '1'
        $env:CLAUDEX_USAGE_URL = 'https://example.com/backend-api/wham/usage'
        $nonLoopbackRejected = $false
        try {
            & $usageHelper -RefreshCache | Out-Null
        } catch {
            $nonLoopbackRejected = $_.Exception.Message.Contains('permits only loopback HTTP(S) usage endpoints')
        }
        Assert-True $nonLoopbackRejected 'test usage URL remains loopback-only'

        $loopbackUsageUrl = 'http://127.0.0.1:8123/backend-api/wham/usage'
        $loopbackCurlLog = Join-Path $temporary 'loopback-usage-url-curl.log'
        $env:CLAUDEX_USAGE_URL = $loopbackUsageUrl
        $env:FAKE_CURL_CALL_LOG = $loopbackCurlLog
        try {
            & $usageHelper -RefreshCache | Out-Null
        } finally {
            Remove-Item Env:CLAUDEX_USAGE_SOURCE -ErrorAction SilentlyContinue
            Remove-Item Env:CLAUDEX_USAGE_URL -ErrorAction SilentlyContinue
            Remove-Item Env:CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL -ErrorAction SilentlyContinue
            Remove-Item Env:FAKE_CURL_CALL_LOG -ErrorAction SilentlyContinue
        }
        $loopbackCurlArguments = Get-Content -LiteralPath $loopbackCurlLog -Raw
        Assert-True ($loopbackCurlArguments.Contains("-- $loopbackUsageUrl")) 'loopback test usage URL follows curl argument terminator'
    }

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

    [IO.File]::WriteAllText((Join-Path $testConfig 'usage-cache\summary'), "Codex 7d 18% left $([char]0x00B7) Review 7d 9% left $([char]0x00B7) Extra-long-capacity-window 30d 8% left`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $testConfig 'usage-cache\last-success'), "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`n", $utf8)
    $env:CLAUDEX_STATUSLINE_COLUMNS = '40'
    try { $narrowStatus = ($statusJson | & (Join-Path $root 'statusline.ps1') | Out-String).TrimEnd() }
    finally { Remove-Item Env:CLAUDEX_STATUSLINE_COLUMNS -ErrorAction SilentlyContinue }
    $narrowPlain = [regex]::Replace($narrowStatus, "$([char]27)\[[0-9;]*m", '')
    Assert-True ($narrowPlain.Length -le 40) 'narrow status stays within the available columns'
    Assert-True ($narrowPlain.Contains('GPT-5.6 Sol') -and $narrowPlain.Contains('42% context')) 'narrow status preserves model and context'
    Assert-True (-not $narrowPlain.Contains('Extra-long-capacity-window')) 'narrow status drops the long usage tail'
    Assert-True ($narrowStatus.Contains("$([char]27)[38;5;81mClaudex$([char]27)[0m")) 'narrow status preserves ANSI boundaries'

    $env:CLAUDEX_STATUSLINE_COLUMNS = '18'
    try { $tinyStatus = ($statusJson | & (Join-Path $root 'statusline.ps1') | Out-String).TrimEnd() }
    finally { Remove-Item Env:CLAUDEX_STATUSLINE_COLUMNS -ErrorAction SilentlyContinue }
    $tinyPlain = [regex]::Replace($tinyStatus, "$([char]27)\[[0-9;]*m", '')
    Assert-True ($tinyPlain.Length -le 18 -and $tinyPlain.Contains([string][char]0x2026)) 'tiny status truncates without wrapping'

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
    & node (Join-Path $root 'tests\skill-bridge.test.cjs')
    Assert-True ($LASTEXITCODE -eq 0) 'skill bridge regressions'
    & node (Join-Path $root 'tests\skill-contract.test.cjs')
    Assert-True ($LASTEXITCODE -eq 0) 'skill contract regressions'
    & node (Join-Path $root 'tests\skill-security.test.cjs')
    Assert-True ($LASTEXITCODE -eq 0) 'skill security regressions'
    $env:CLAUDEX_TEST_TTY_INPUT = '1'
    $inputAlias = & node -e 'const p=require(process.argv[1]);process.stdout.write(Buffer.from(p.rewriteSolplanInput(process.argv[2]+String.fromCharCode(13))).toString(process.argv[3]))' (Join-Path $root 'preload.cjs') '/model solplan' hex
    Remove-Item Env:CLAUDEX_TEST_TTY_INPUT
    Assert-True (($inputAlias | Out-String).Contains('2f6d6f64656c206f707573706c616e0d')) 'Solplan slash-command alias'
    $packageVersion = (& node (Join-Path $root 'bin\claudex-package.mjs') --package-version | Out-String).Trim()
    $packageManifest = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
    Assert-True ($packageVersion -eq $packageManifest.version) 'package-manager wrapper version'

    $installScriptSource = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw
    Assert-True ($installScriptSource.Contains('Get-Command npm.cmd')) 'Codex install prefers the native npm command shim'
    Assert-True ($installScriptSource.Contains('--prefix $installPrefix')) 'Codex install passes a concrete local prefix to npm'
    Assert-True (-not $installScriptSource.Contains('--prefix $script:codexInstalledBinDir')) 'Codex install never exposes a scoped variable to npm.ps1 evaluation'
    Assert-True ($installScriptSource.Contains("`$claudeInstalledBinDir = Join-Path `$env:USERPROFILE '.local\bin'")) 'Claude installer discovers its first-run bin directory'
    Assert-True ($installScriptSource.Contains('$codexInstalledBinDir,') -and $installScriptSource.Contains('$claudeInstalledBinDir,')) 'CLI installers persist their first-run bin directories'
    Assert-True ($installScriptSource.Contains('function Get-NodeMajorVersion')) 'Windows installer parses the active Node major version'
    Assert-True ($installScriptSource.Contains('$nodeMajor -lt 18 -and $allowNodeMigration')) 'Windows installer upgrades Node below the supported minimum'
    Assert-True ($installScriptSource.Contains("`$env:CLAUDEX_ALLOW_NODE_INSTALL -eq '1'")) 'archive migration can authorize only the required Node installation'
    Assert-True ($installScriptSource.Contains('function Receive-FileWithRetry')) 'Windows installer has bounded transient download retries'
    Assert-True ($installScriptSource.Contains('function Start-InstallTransaction')) 'Windows direct reinstall stages a rollback generation'
    Assert-True ($installScriptSource.Contains('function Install-ManagedNode')) 'Windows installer has a verified user-local Node fallback'
    $selfUpdateScriptSource = Get-Content -LiteralPath (Join-Path $root 'self-update.ps1') -Raw
    Assert-True ($selfUpdateScriptSource.Contains("CLAUDEX_ALLOW_NODE_INSTALL = '1'")) 'archive updater authorizes the Node dependency migration'
    Assert-True ($selfUpdateScriptSource.Contains("CLAUDEX_SKIP_DEPENDENCY_INSTALL = '1'")) 'archive updater still blocks unrelated dependency changes'
    Assert-True ($selfUpdateScriptSource.Contains('function ConvertTo-CmdArgument')) 'Windows updater has a CMD-specific argument serializer'
    Assert-True ($selfUpdateScriptSource.Contains(".Replace('%', '%%')")) 'Windows updater neutralizes CMD percent expansion'
    Assert-True ($selfUpdateScriptSource.Contains("'/d /s /v:off /c `"'")) 'Windows updater disables delayed expansion for CMD shims'

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
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'self-update.ps1') -PathType Leaf) 'self-update helper installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'install.json') -PathType Leaf) 'install receipt written'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skills\usage-limit\SKILL.md') -PathType Leaf) 'usage skill installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skill-bridge.cjs') -PathType Leaf) 'skill bridge installed'
    $installedUsageSkill = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skills\usage-limit\SKILL.md') -Raw
    Assert-True ($installedUsageSkill.Contains('shell: powershell')) 'Windows usage skill selects PowerShell'
    Assert-True ($installedUsageSkill.Contains('allowed-tools: PowerShell(')) 'Windows usage skill grants only PowerShell helper invocation'
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

    $specialInstallerToken = 'installer token = 100% ! & "quotes" \path'
    $env:CLAUDEX_PROXY_TOKEN = $specialInstallerToken
    & (Join-Path $root 'install.ps1') | Out-Null
    $tokenLine = [IO.File]::ReadAllLines((Join-Path $env:CLAUDEX_CONFIG_DIR 'env')) | Where-Object { $_.StartsWith('CLAUDEX_PROXY_TOKEN=') } | Select-Object -First 1
    Assert-True ($tokenLine.Substring('CLAUDEX_PROXY_TOKEN='.Length) -ceq $specialInstallerToken) 'Windows installer token round-trips exactly through env serialization'

    $explicitLoginLog = Join-Path $temporary 'explicit-installer-login.log'
    $env:FAKE_CODEX_LOGIN_LOG = $explicitLoginLog
    & (Join-Path $root 'install.ps1') -Login | Out-Null
    Remove-Item Env:FAKE_CODEX_LOGIN_LOG
    Assert-True (@([IO.File]::ReadAllLines($explicitLoginLog)).Count -eq 1) 'explicit -Login runs even for an already-valid Codex session'

    $rollbackEnvBefore = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'env') -Raw
    $rollbackProxyBefore = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'cliproxyapi.yaml') -Raw
    [IO.File]::WriteAllText((Join-Path $env:CLAUDEX_CONFIG_DIR 'statusline.ps1'), 'rollback-statusline-sentinel', $utf8)
    $savedInstallMethod = $env:CLAUDEX_INSTALL_METHOD
    $env:CLAUDEX_INSTALL_METHOD = 'invalid'
    $env:CLAUDEX_PROXY_TOKEN = 'must-not-survive'
    $shellPath = (Get-Process -Id $PID).Path
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rollbackOutput = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') 2>&1
        $rollbackExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrorPreference }
    if ($null -eq $savedInstallMethod) { Remove-Item Env:CLAUDEX_INSTALL_METHOD -ErrorAction SilentlyContinue } else { $env:CLAUDEX_INSTALL_METHOD = $savedInstallMethod }
    Assert-True ($rollbackExit -eq 1) 'late Windows installer failure is reported'
    Assert-True (($rollbackOutput | Out-String).Contains('restored the previous managed installation')) 'late Windows installer failure reports rollback'
    Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'env') -Raw) -ceq $rollbackEnvBefore) 'Windows rollback restores env exactly'
    Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'cliproxyapi.yaml') -Raw) -ceq $rollbackProxyBefore) 'Windows rollback restores proxy config exactly'
    Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'statusline.ps1') -Raw) -ceq 'rollback-statusline-sentinel') 'Windows rollback restores prior managed files'
    Assert-True (@(Get-ChildItem -LiteralPath $env:CLAUDEX_CONFIG_DIR -Filter '.install-transaction-*' -ErrorAction SilentlyContinue).Count -eq 0) 'Windows rollback removes transaction scratch state'

    $crashTransaction = Join-Path $env:CLAUDEX_CONFIG_DIR '.install-transaction-crash-test'
    $crashBackup = Join-Path $crashTransaction 'backup'
    [IO.Directory]::CreateDirectory($crashBackup) | Out-Null
    $crashTargets = @(
        (Join-Path $env:CLAUDEX_BIN_DIR 'claudex.ps1'),
        (Join-Path $env:CLAUDEX_BIN_DIR 'claudex.cmd'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'env'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'cliproxyapi.yaml'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'bin\cliproxyapi-7.2.80.exe'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'settings.json'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'statusline.ps1'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'usage-limit.ps1'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'codex-session.ps1'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'preload.cjs'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'skill-bridge.cjs'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'self-update.ps1'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'skills\usage-limit\SKILL.md'),
        (Join-Path $env:CLAUDEX_CONFIG_DIR 'install.json')
    )
    $crashEntries = @()
    for ($crashIndex = 0; $crashIndex -lt $crashTargets.Count; $crashIndex++) {
        $crashTarget = $crashTargets[$crashIndex]
        $crashBackupPath = Join-Path $crashBackup ([string] $crashIndex)
        $crashExisted = Test-Path -LiteralPath $crashTarget -PathType Leaf
        if ($crashExisted) { Copy-Item -LiteralPath $crashTarget -Destination $crashBackupPath }
        $crashEntries += [pscustomobject]@{ Path = $crashTarget; Backup = $crashBackupPath; Existed = $crashExisted }
    }
    [IO.File]::WriteAllText((Join-Path $crashTransaction 'manifest.json'), (($crashEntries | ConvertTo-Json -Depth 5) + "`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $crashTransaction 'state'), "committing`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $env:CLAUDEX_CONFIG_DIR 'env'), "CLAUDEX_PROXY_TOKEN=corrupted-crash-token`n", $utf8)
    Remove-Item Env:CLAUDEX_PROXY_TOKEN
    $previousConsoleOut = [Console]::Out
    $recoveryConsoleOut = New-Object IO.StringWriter
    [Console]::SetOut($recoveryConsoleOut)
    try {
        $recoveryOutput = (& (Join-Path $root 'install.ps1') | Out-String)
        $recoveryOutput += $recoveryConsoleOut.ToString()
    } finally {
        [Console]::SetOut($previousConsoleOut)
        $recoveryConsoleOut.Dispose()
    }
    Assert-True ($recoveryOutput.Contains('Recovered the previous interrupted Claudex installation')) 'Windows installer recovers a durable interrupted transaction'
    $recoveredTokenLine = [IO.File]::ReadAllLines((Join-Path $env:CLAUDEX_CONFIG_DIR 'env')) | Where-Object { $_.StartsWith('CLAUDEX_PROXY_TOKEN=') } | Select-Object -First 1
    Assert-True ($recoveredTokenLine.Substring('CLAUDEX_PROXY_TOKEN='.Length) -ceq $specialInstallerToken) 'Windows interrupted-transaction recovery restores env before reinstall'
    Assert-True (-not (Test-Path -LiteralPath $crashTransaction)) 'Windows interrupted transaction is removed after recovery'
    $env:CLAUDEX_PROXY_TOKEN = $specialInstallerToken
    $selfUpdateStatus = (& (Join-Path $root 'claudex.ps1') self-update --status | Out-String)
    Assert-True ($selfUpdateStatus.Contains("Installed version: $($packageManifest.version)")) 'self-update status dispatch'
    Assert-True ($selfUpdateStatus.Contains('Install method: archive')) 'self-update normalizes source installs to archive provenance'

    if ($isWindowsPlatform) {
        function New-ArchiveUpdateFixture([string] $Fixture, [string] $Version, [string] $Mode, [bool] $BadChecksum = $false) {
            Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
            [IO.Directory]::CreateDirectory($Fixture) | Out-Null
            $source = Join-Path $Fixture 'source'
            $releaseRoot = Join-Path $source "claudex-$Version"
            [IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
            [IO.File]::WriteAllText((Join-Path $releaseRoot 'package.json'), "{`"version`":`"$Version`"}`n", $utf8)
            if ($Mode -ne 'missing-bridge') {
                [IO.File]::WriteAllText((Join-Path $releaseRoot 'skill-bridge.cjs'), "'use strict';`n", $utf8)
            }
            $installerMode = $Mode
            $installer = @"
`$ErrorActionPreference = 'Stop'
`$config = `$env:CLAUDEX_CONFIG_DIR
[IO.Directory]::CreateDirectory(`$config) | Out-Null
[IO.File]::WriteAllText((Join-Path `$config 'skill-bridge.cjs'), 'fixture bridge $Version')
if ('$installerMode' -eq 'rollback') { exit 23 }
[IO.File]::WriteAllText((Join-Path `$config 'node-migration.txt'), "`$(`$env:CLAUDEX_SKIP_DEPENDENCY_INSTALL):`$(`$env:CLAUDEX_ALLOW_NODE_INSTALL)")
`$receipt = [ordered]@{ schema = 1; version = '$Version'; method = 'archive'; binDir = `$env:CLAUDEX_BIN_DIR; repository = 'BeamoINT/Claudex' }
[IO.File]::WriteAllText((Join-Path `$config 'install.json'), ((`$receipt | ConvertTo-Json -Compress) + "`n"))
"@
            [IO.File]::WriteAllText((Join-Path $releaseRoot 'install.ps1'), $installer, $utf8)
            $zipName = "claudex-$Version-windows.zip"
            $zip = Join-Path $Fixture $zipName
            Compress-Archive -LiteralPath $releaseRoot -DestinationPath $zip
            $digest = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($BadChecksum) { $digest = ('0' * 64) }
            [IO.File]::WriteAllText((Join-Path $Fixture 'SHA256SUMS'), "$digest  $zipName`n", $utf8)
            $release = [ordered]@{
                tag_name = "v$Version"; draft = $false; prerelease = $false; published_at = '2026-07-16T00:00:00Z'
                assets = @(
                    [ordered]@{ name = $zipName; url = "https://api.github.com/assets/$zipName" },
                    [ordered]@{ name = 'SHA256SUMS'; url = 'https://api.github.com/assets/SHA256SUMS' }
                )
            }
            [IO.File]::WriteAllText((Join-Path $Fixture 'latest.json'), (($release | ConvertTo-Json -Depth 10) + "`n"), $utf8)
        }

        function Invoke-ArchiveUpdateFixture([string] $Fixture) {
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $shellPath = (Get-Process -Id $PID).Path
                $output = & $shellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'self-update.ps1') -Apply 2>&1
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
            } finally { $ErrorActionPreference = $savedPreference }
        }

        $fixture = Join-Path $temporary 'windows-update-fixture'
        $oldFixtureMode = $env:CLAUDEX_TEST_MODE
        $oldFixtureDirectory = $env:CLAUDEX_TEST_UPDATE_FIXTURE_DIR
        $env:CLAUDEX_TEST_MODE = '1'
        $env:CLAUDEX_TEST_UPDATE_FIXTURE_DIR = $fixture
        try {
            $originalBridge = Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skill-bridge.cjs') -Raw

            New-ArchiveUpdateFixture $fixture '9.9.6' 'success' $true
            $badChecksum = Invoke-ArchiveUpdateFixture $fixture
            Assert-True ($badChecksum.ExitCode -eq 1 -and $badChecksum.Output.Contains('checksum mismatch')) 'Windows archive updater rejects checksum mismatch'
            Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skill-bridge.cjs') -Raw) -eq $originalBridge) 'checksum failure leaves skill bridge unchanged'

            New-ArchiveUpdateFixture $fixture '9.9.7' 'missing-bridge'
            $missingBridge = Invoke-ArchiveUpdateFixture $fixture
            Assert-True ($missingBridge.ExitCode -eq 1 -and $missingBridge.Output.Contains('does not contain skill-bridge.cjs')) 'Windows archive updater rejects a missing bridge'

            New-ArchiveUpdateFixture $fixture '9.9.8' 'rollback'
            $rollback = Invoke-ArchiveUpdateFixture $fixture
            Assert-True ($rollback.ExitCode -eq 1 -and $rollback.Output.Contains('restored the previous managed installation')) 'Windows archive updater reports rollback'
            Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'skill-bridge.cjs') -Raw) -eq $originalBridge) 'Windows rollback restores the prior bridge'

            New-ArchiveUpdateFixture $fixture '9.9.9' 'success'
            $success = Invoke-ArchiveUpdateFixture $fixture
            Assert-True ($success.ExitCode -eq 0) "Windows archive updater applies a verified release: $($success.Output)"
            Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'node-migration.txt') -Raw) -eq '1:1') 'Windows archive updater authorizes only the Node migration path'
            Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'install.json') -Raw).Contains('9.9.9')) 'Windows archive updater validates the applied receipt'

            $metacharBin = Join-Path $temporary 'manager&wrappers'
            [IO.Directory]::CreateDirectory($metacharBin) | Out-Null
            $scoopLog = Join-Path $temporary 'scoop-metachar.log'
            [IO.File]::WriteAllText((Join-Path $metacharBin 'scoop.cmd'), @'
@echo off
echo %*>>"%FAKE_SCOOP_LOG%"
if "%1"=="update" exit /b 0
exit /b 9
'@, $utf8)
            [IO.File]::WriteAllText((Join-Path $metacharBin 'package-setup.ps1'), @'
$receipt = [ordered]@{ schema = 1; version = '9.9.10'; method = 'scoop'; binDir = $env:CLAUDEX_BIN_DIR; repository = 'BeamoINT/Claudex' }
[IO.File]::WriteAllText((Join-Path $env:CLAUDEX_CONFIG_DIR 'install.json'), (($receipt | ConvertTo-Json -Compress) + "`n"))
'@, $utf8)
            [IO.File]::WriteAllText((Join-Path $metacharBin 'claudex.cmd'), @'
@echo off
if "%1"=="--package-version" goto package_version
if "%1"=="--package-setup" goto package_setup
exit /b 9
:package_version
echo 9.9.10
exit /b 0
:package_setup
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0package-setup.ps1"
exit /b %ERRORLEVEL%
'@, $utf8)
            New-ArchiveUpdateFixture $fixture '9.9.10' 'success'
            $managerReceipt = [ordered]@{ schema = 1; version = '9.9.9'; method = 'scoop'; binDir = $env:CLAUDEX_BIN_DIR; repository = 'BeamoINT/Claudex' }
            [IO.File]::WriteAllText((Join-Path $env:CLAUDEX_CONFIG_DIR 'install.json'), (($managerReceipt | ConvertTo-Json -Compress) + "`n"), $utf8)
            $savedManagerPath = $env:PATH
            $env:PATH = "$metacharBin$([IO.Path]::PathSeparator)$env:PATH"
            $env:FAKE_SCOOP_LOG = $scoopLog
            try { $metacharUpdate = Invoke-ArchiveUpdateFixture $fixture }
            finally {
                $env:PATH = $savedManagerPath
                Remove-Item Env:FAKE_SCOOP_LOG -ErrorAction SilentlyContinue
            }
            Assert-True ($metacharUpdate.ExitCode -eq 0) "Windows updater safely invokes CMD shims beneath a metacharacter path: $($metacharUpdate.Output)"
            Assert-True ((Get-Content -LiteralPath $scoopLog -Raw).Contains('update claudex')) 'Scoop updater received intact arguments beneath a metacharacter path'
            Assert-True ((Get-Content -LiteralPath (Join-Path $env:CLAUDEX_CONFIG_DIR 'install.json') -Raw).Contains('9.9.10')) 'metacharacter-path package setup activated the expected release'
        } finally {
            if ($null -eq $oldFixtureMode) { Remove-Item Env:CLAUDEX_TEST_MODE -ErrorAction SilentlyContinue } else { $env:CLAUDEX_TEST_MODE = $oldFixtureMode }
            if ($null -eq $oldFixtureDirectory) { Remove-Item Env:CLAUDEX_TEST_UPDATE_FIXTURE_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDEX_TEST_UPDATE_FIXTURE_DIR = $oldFixtureDirectory }
        }
    }

    & node (Join-Path $root 'scripts\check-docs.mjs')
    Assert-True ($LASTEXITCODE -eq 0) 'community and documentation checks'

    [Console]::WriteLine('all Claudex Windows tests passed')
} finally {
    if ($isWindowsPlatform) { Remove-Item Function:\global:claude -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
