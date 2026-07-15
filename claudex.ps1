param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ClaudeArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ClaudeArguments = @($ClaudeArguments)
$previousSessionMode = [Environment]::GetEnvironmentVariable('CLAUDEX_SESSION_MODE', 'Process')
$previousEffortLevel = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'Process')
$previousModelMode = [Environment]::GetEnvironmentVariable('CLAUDEX_MODEL_MODE', 'Process')

$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$configFile = Join-Path $configDir 'env'
$settingsFile = if ($env:CLAUDEX_SETTINGS_FILE) { $env:CLAUDEX_SETTINGS_FILE } else { Join-Path $configDir 'settings.json' }
$curlCommand = if ($env:CLAUDEX_CURL_BIN) { $env:CLAUDEX_CURL_BIN } else { 'curl.exe' }

function Fail([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine("claudex: $Message")
    exit $Code
}

if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    Fail "missing $configFile; reinstall or restore the Claudex configuration."
}
if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
    Fail "missing $settingsFile; reinstall or restore the Claudex settings."
}

foreach ($line in [IO.File]::ReadAllLines($configFile)) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
            ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $value = $value -replace '\\ ', ' '
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Env-OrDefault([string] $Name, [string] $Default) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

$proxyToken = Env-OrDefault 'CLAUDEX_PROXY_TOKEN' ''
if (-not $proxyToken) { Fail 'CLAUDEX_PROXY_TOKEN is not configured' }
if ($proxyToken.Contains("`r") -or $proxyToken.Contains("`n")) { Fail 'CLAUDEX_PROXY_TOKEN contains an unsupported newline.' 2 }
$proxyUrl = Env-OrDefault 'CLAUDEX_PROXY_URL' 'http://127.0.0.1:8318'
$model = Env-OrDefault 'CLAUDEX_MODEL' 'gpt-5.6-sol'
$permissionMode = Env-OrDefault 'CLAUDEX_PERMISSION_MODE' 'auto'
$autoModeModel = Env-OrDefault 'CLAUDEX_AUTO_MODE_MODEL' 'gpt-5.6-luna'
$backgroundModel = Env-OrDefault 'CLAUDEX_BACKGROUND_MODEL' 'gpt-5.6-luna'
$subagentModel = Env-OrDefault 'CLAUDEX_SUBAGENT_MODEL' 'gpt-5.6-terra'
$toolConcurrency = Env-OrDefault 'CLAUDEX_MAX_TOOL_USE_CONCURRENCY' '3'
$agentConcurrency = Env-OrDefault 'CLAUDEX_MAX_AGENT_CONCURRENCY' '3'
$maxRetries = Env-OrDefault 'CLAUDEX_MAX_RETRIES' '2'
$contextWindow = Env-OrDefault 'CLAUDEX_CONTEXT_WINDOW' '400000'
$compactWindow = Env-OrDefault 'CLAUDEX_AUTO_COMPACT_WINDOW' '280000'
$mousePointer = Env-OrDefault 'CLAUDEX_MOUSE_POINTER_SHAPE' 'pointer'
$usageDisplay = Env-OrDefault 'CLAUDEX_USAGE_DISPLAY' 'on'
$usageRefresh = Env-OrDefault 'CLAUDEX_USAGE_REFRESH_SECONDS' '300'
$usageTimeout = Env-OrDefault 'CLAUDEX_USAGE_TIMEOUT_SECONDS' '8'
$usageMaxStale = Env-OrDefault 'CLAUDEX_USAGE_MAX_STALE_SECONDS' '86400'
$usageSource = Env-OrDefault 'CLAUDEX_USAGE_SOURCE' 'auto'
$usageAlert = Env-OrDefault 'CLAUDEX_USAGE_ALERT_PERCENT' '20'
$claudeAutoUpdate = Env-OrDefault 'CLAUDEX_CLAUDE_AUTO_UPDATE' 'on'
$claudeUpdateInterval = Env-OrDefault 'CLAUDEX_CLAUDE_UPDATE_INTERVAL_SECONDS' '86400'
$planModePolicy = Env-OrDefault 'CLAUDEX_PLAN_MODE_POLICY' 'conservative'
$codexSessionHelper = Env-OrDefault 'CLAUDEX_CODEX_SESSION_HELPER' (Join-Path $configDir 'codex-session.ps1')

if ($permissionMode -notin @('manual', 'auto', 'acceptEdits', 'dontAsk', 'plan')) {
    Fail "invalid CLAUDEX_PERMISSION_MODE '$permissionMode'; expected manual, auto, acceptEdits, dontAsk, or plan." 2
}

function Require-Integer([string] $Name, [string] $Value, [int] $Minimum, [int] $Maximum) {
    $number = 0
    if (-not [int]::TryParse($Value, [ref] $number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        Fail "$Name must be an integer from $Minimum to $Maximum." 2
    }
    return $number
}

$toolConcurrencyNumber = Require-Integer 'CLAUDEX_MAX_TOOL_USE_CONCURRENCY' $toolConcurrency 1 2147483647
$agentConcurrencyNumber = Require-Integer 'CLAUDEX_MAX_AGENT_CONCURRENCY' $agentConcurrency 1 2147483647
$maxRetriesNumber = Require-Integer 'CLAUDEX_MAX_RETRIES' $maxRetries 0 15
$contextWindowNumber = Require-Integer 'CLAUDEX_CONTEXT_WINDOW' $contextWindow 100000 1000000
$compactWindowNumber = Require-Integer 'CLAUDEX_AUTO_COMPACT_WINDOW' $compactWindow 100000 $contextWindowNumber
$usageRefreshNumber = Require-Integer 'CLAUDEX_USAGE_REFRESH_SECONDS' $usageRefresh 60 3600
$usageTimeoutNumber = Require-Integer 'CLAUDEX_USAGE_TIMEOUT_SECONDS' $usageTimeout 1 30
$usageMaxStaleNumber = Require-Integer 'CLAUDEX_USAGE_MAX_STALE_SECONDS' $usageMaxStale $usageRefreshNumber 604800
$usageAlertNumber = Require-Integer 'CLAUDEX_USAGE_ALERT_PERCENT' $usageAlert 0 100
$claudeUpdateIntervalNumber = Require-Integer 'CLAUDEX_CLAUDE_UPDATE_INTERVAL_SECONDS' $claudeUpdateInterval 3600 2592000
if ($mousePointer -notin @('pointer', 'default', 'off')) {
    Fail 'CLAUDEX_MOUSE_POINTER_SHAPE must be pointer, default, or off.' 2
}
if ($usageDisplay -notin @('on', 'off')) { Fail 'CLAUDEX_USAGE_DISPLAY must be on or off.' 2 }
if ($usageSource -notin @('auto', 'web', 'app-server')) { Fail 'CLAUDEX_USAGE_SOURCE must be auto, web, or app-server.' 2 }
if ($claudeAutoUpdate -notin @('on', 'off')) { Fail 'CLAUDEX_CLAUDE_AUTO_UPDATE must be on or off.' 2 }
if ($planModePolicy -notin @('conservative', 'normal')) { Fail 'CLAUDEX_PLAN_MODE_POLICY must be conservative or normal.' 2 }

$env:CLAUDE_CONFIG_DIR = $configDir
$stateFile = Join-Path $configDir '.claude.json'
$managedModels = @(
    [pscustomobject]@{ value = 'opusplan'; label = 'GPT-5.6 Solplan'; description = 'GPT-5.6 Sol in plan mode, GPT-5.6 Terra for implementation' },
    [pscustomobject]@{ value = 'gpt-5.6-sol'; label = 'GPT-5.6 Sol'; description = 'Frontier capability for planning and the hardest engineering work' },
    [pscustomobject]@{ value = 'gpt-5.6-terra'; label = 'GPT-5.6 Terra'; description = 'Balanced intelligence, speed, and cost for everyday coding' },
    [pscustomobject]@{ value = 'gpt-5.6-luna'; label = 'GPT-5.6 Luna'; description = 'Fast, efficient model for search, triage, and mechanical tasks' }
)

function Update-ModelCache {
    $state = $null
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { $state = $null }
    }
    if ($null -eq $state) { $state = [pscustomobject]@{} }
    $managedIds = @($managedModels | ForEach-Object { $_.value })
    $preserved = @()
    if ($null -ne $state.PSObject.Properties['additionalModelOptionsCache']) {
        $preserved = @($state.additionalModelOptionsCache | Where-Object { $_.value -notin $managedIds })
    }
    $state | Add-Member -NotePropertyName additionalModelOptionsCache -NotePropertyValue @($preserved + $managedModels) -Force
    [IO.Directory]::CreateDirectory($configDir) | Out-Null
    $tempFile = Join-Path $configDir ('.claude.json.tmp.' + [guid]::NewGuid().ToString('N'))
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tempFile, ($state | ConvertTo-Json -Depth 100), $utf8)
    Move-Item -LiteralPath $tempFile -Destination $stateFile -Force
}

Update-ModelCache

$preload = Join-Path $configDir 'preload.cjs'
if (Test-Path -LiteralPath $preload -PathType Leaf) {
    $preloadForBun = $preload.Replace('\', '/').Replace(' ', '\ ')
    $existingBunOptions = [Environment]::GetEnvironmentVariable('BUN_OPTIONS', 'Process')
    $env:BUN_OPTIONS = ("--preload $preloadForBun $existingBunOptions").Trim()
}

function Fetch-Models {
    $output = "Authorization: Bearer $proxyToken" | & $curlCommand --silent --show-error --fail --max-time 5 `
        --header '@-' "$proxyUrl/v1/models" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'proxy request failed' }
    return ($output | Out-String | ConvertFrom-Json)
}

function Test-ProxyReady {
    try {
        $models = Fetch-Models
        return @($models.data | ForEach-Object { $_.id }) -contains $model
    } catch { return $false }
}

function Find-ProxyExecutable {
    $configured = Env-OrDefault 'CLAUDEX_PROXY_BIN' ''
    if ($configured -and (Test-Path -LiteralPath $configured -PathType Leaf)) { return $configured }
    $managed = Join-Path $configDir 'bin\cliproxyapi.exe'
    if (Test-Path -LiteralPath $managed -PathType Leaf) { return $managed }
    foreach ($name in @('cliproxyapi.exe', 'cli-proxy-api.exe', 'cliproxyapi', 'cli-proxy-api')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

function Ensure-Proxy {
    if (-not (Test-Path -LiteralPath $codexSessionHelper -PathType Leaf)) {
        Fail "authentication helper is missing: $codexSessionHelper; reinstall Claudex."
    }
    & $codexSessionHelper sync
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (Test-ProxyReady) { return }
    $proxyBinary = Find-ProxyExecutable
    if (-not $proxyBinary) { Fail 'CLIProxyAPI is not reachable and no proxy executable was found.' }
    [Console]::Error.WriteLine('claudex: starting the local CLIProxyAPI service...')
    $proxyConfig = Env-OrDefault 'CLAUDEX_PROXY_CONFIG' (Join-Path $configDir 'cliproxyapi.yaml')
    $logDir = Join-Path $configDir 'logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $arguments = @()
    if (Test-Path -LiteralPath $proxyConfig -PathType Leaf) {
        $arguments = @('-config', ('"' + $proxyConfig + '"'))
    }
    Start-Process -FilePath $proxyBinary -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $configDir `
        -RedirectStandardOutput (Join-Path $logDir 'cliproxyapi.stdout.log') `
        -RedirectStandardError (Join-Path $logDir 'cliproxyapi.stderr.log') | Out-Null
    foreach ($attempt in 1..50) {
        if (Test-ProxyReady) { return }
        Start-Sleep -Milliseconds 100
    }
    Fail 'local proxy did not become healthy. Run: claudex --doctor'
}

function Load-ClaudeCapabilities {
    $claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCommand) { Fail 'Claude Code was not found. Install Claude Code and retry.' }
    $script:claudeInvocation = if ($claudeCommand.CommandType -eq 'Function') { $claudeCommand.Name } else { $claudeCommand.Source }
    $script:claudeHelp = (& $script:claudeInvocation --help 2>$null | Out-String)
    if ([string]::IsNullOrWhiteSpace($script:claudeHelp)) { Fail 'Claude Code did not return its capability list.' }
    if (-not $script:claudeHelp.Contains('--model')) {
        Fail 'this Claude Code build does not support custom models; run `claude update`.'
    }
}

function Test-ClaudeOption([string] $Option) {
    return $script:claudeHelp.Contains($Option)
}

function Start-ClaudeUpdateCheck {
    if ($claudeAutoUpdate -ne 'on' -or $env:CLAUDEX_SKIP_AUTO_UPDATE -eq '1') { return }
    $updateDir = Join-Path $configDir 'update'
    $stamp = Join-Path $updateDir 'last-success'
    $last = 0L
    if (Test-Path -LiteralPath $stamp -PathType Leaf) {
        [long]::TryParse(([IO.File]::ReadAllText($stamp).Trim()), [ref] $last) | Out-Null
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now - $last -lt $claudeUpdateIntervalNumber) { return }
    [IO.Directory]::CreateDirectory($updateDir) | Out-Null
    $lock = Join-Path $updateDir 'lock'
    try { New-Item -LiteralPath $lock -ItemType Directory -ErrorAction Stop | Out-Null } catch { return }
    $claudePath = $script:claudeInvocation
    $log = Join-Path $updateDir 'claude-update.log'
    Start-Job -ScriptBlock {
        param($ClaudePath, $Log, $Stamp, $Lock)
        try {
            & $ClaudePath update *> $Log
            if ($LASTEXITCODE -eq 0) {
                [IO.File]::WriteAllText($Stamp, ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString() + "`n"))
            }
        } finally { Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue }
    } -ArgumentList $claudePath, $log, $stamp, $lock | Out-Null
}

function Model-Name([string] $Id) {
    switch ($Id) {
        { $_ -in @('opusplan', 'solplan') } { return 'GPT-5.6 Solplan' }
        { $_ -in @('gpt-5.6-terra', 'sonnet') } { return 'GPT-5.6 Terra' }
        { $_ -in @('gpt-5.6-luna', 'haiku') } { return 'GPT-5.6 Luna' }
        default { return 'GPT-5.6 Sol' }
    }
}

function Invoke-Doctor {
    Ensure-Proxy
    $saved = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    $savedModel = if ($null -ne $saved.PSObject.Properties['model'] -and $saved.model) { [string] $saved.model } else { 'gpt-5.6-sol' }
    $models = Fetch-Models
    $proxyBinary = Find-ProxyExecutable
    $proxyVersion = 'unavailable'
    if ($proxyBinary) {
        $versionLines = @(& $proxyBinary -version 2>&1)
        if ($versionLines.Count -gt 0) { $proxyVersion = [string] $versionLines[0] }
    }
    $claudeVersion = try { (& claude --version 2>$null | Select-Object -First 1) } catch { 'unavailable' }
    Write-Output "Claude Code: $claudeVersion"
    Write-Output "CLIProxyAPI: $proxyVersion"
    & $codexSessionHelper status
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Output "Proxy: healthy at $proxyUrl"
    Write-Output "Saved model: $(Model-Name $savedModel) ($savedModel)"
    Write-Output "Default permission mode: $permissionMode"
    Write-Output "Auto-mode classifier: $autoModeModel (only used when auto mode is selected)"
    Write-Output "Subagent model: $subagentModel (Sol is reserved for the leader)"
    Write-Output "Tool concurrency: $toolConcurrencyNumber"
    Write-Output "Agent concurrency: $agentConcurrencyNumber"
    Write-Output 'Task lifecycle: Sol-owned with final-response reconciliation'
    Write-Output "API retries: $maxRetriesNumber"
    Write-Output "Context window: $contextWindowNumber tokens"
    Write-Output "Auto-compact window: $compactWindowNumber tokens (precompute enabled)"
    Write-Output 'Context status: session-stabilized (transient zero suppressed)'
    Write-Output "Codex usage: status-line refresh every ${usageRefreshNumber}s; inspect with /usage-limit or claudex --usage-limit"
    Write-Output "Usage source: $usageSource (documented Codex app-server fallback enabled in auto mode)"
    Write-Output "Low-quota alert: $usageAlertNumber% remaining (0 disables)"
    Write-Output 'Effort shortcuts: --max-effort and --ultracode (xhigh plus dynamic workflows)'
    Write-Output 'Claude in Chrome: use --claude-chrome for the direct Anthropic profile required by the extension'
    Write-Output "Claude Code updates: $claudeAutoUpdate (checked every ${claudeUpdateIntervalNumber}s)"
    Write-Output "Plan mode policy: $planModePolicy (implementation-first unless planning is genuinely required)"
    Write-Output 'Rendering: no-flicker mode with native terminal cursor'
    Write-Output 'Terminal UI: fullscreen (launch command hidden while Claudex is open)'
    Write-Output 'Header model name: GPT-5.6 Sol'
    Write-Output "Mouse pointer: $mousePointer"
    Write-Output "Isolation: Claudex config at $configDir; normal Claude config is untouched"
    $missing = $false
    $ids = @($models.data | ForEach-Object { $_.id })
    foreach ($id in @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')) {
        if ($ids -contains $id) { Write-Output "${id}: advertised" }
        else { [Console]::Error.WriteLine("${id}: not advertised by the authenticated Codex account"); $missing = $true }
    }
    if ($missing) { exit 1 }
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -in @('--login', '--logout', '--auth-status')) {
    if (-not (Test-Path -LiteralPath $codexSessionHelper -PathType Leaf)) { Fail 'authentication helper is missing; reinstall Claudex.' }
    $action = switch ($ClaudeArguments[0]) { '--login' { 'login' } '--logout' { 'logout' } default { 'status' } }
    & $codexSessionHelper $action
    exit $LASTEXITCODE
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--doctor') {
    Invoke-Doctor
    exit 0
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--usage-limit') {
    $usageHelper = Join-Path $configDir 'usage-limit.ps1'
    if (-not (Test-Path -LiteralPath $usageHelper -PathType Leaf)) { Fail 'usage-limit helper is missing; reinstall Claudex.' }
    $usageArguments = if ($ClaudeArguments.Count -gt 1) { @($ClaudeArguments[1..($ClaudeArguments.Count - 1)]) } else { @() }
    & $usageHelper @usageArguments
    if ($?) { exit 0 }
    exit 1
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--accounts') {
    $usageHelper = Join-Path $configDir 'usage-limit.ps1'
    if (-not (Test-Path -LiteralPath $usageHelper -PathType Leaf)) { Fail 'usage-limit helper is missing; reinstall Claudex.' }
    & $usageHelper -Accounts
    if ($?) { exit 0 } else { exit 1 }
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--account') {
    if ($ClaudeArguments.Count -ne 2) { Fail 'Usage: claudex --account <number|email|filename|auto>' 2 }
    $usageHelper = Join-Path $configDir 'usage-limit.ps1'
    if (-not (Test-Path -LiteralPath $usageHelper -PathType Leaf)) { Fail 'usage-limit helper is missing; reinstall Claudex.' }
    & $usageHelper -Account $ClaudeArguments[1]
    if ($?) { exit 0 } else { exit 1 }
}

$startModel = ''
$effortMode = ''
$launchPermissionMode = $permissionMode
$directChrome = $false
$forwardArguments = New-Object 'System.Collections.Generic.List[string]'
$index = 0
while ($index -lt $ClaudeArguments.Count) {
    $argument = $ClaudeArguments[$index]
    switch ($argument) {
        '--sol' { $startModel = 'gpt-5.6-sol' }
        '--terra' { $startModel = 'gpt-5.6-terra' }
        '--luna' { $startModel = 'gpt-5.6-luna' }
        '--solplan' { $startModel = 'opusplan' }
        '--manual' { $launchPermissionMode = 'manual' }
        '--auto' { $launchPermissionMode = 'auto' }
        '--accept-edits' { $launchPermissionMode = 'acceptEdits' }
        '--ultracode' {
            if ($effortMode -and $effortMode -ne 'ultracode') { Fail '--ultracode and --max-effort cannot be combined.' 2 }
            $effortMode = 'ultracode'
        }
        '--max-effort' {
            if ($effortMode -and $effortMode -ne 'max') { Fail '--ultracode and --max-effort cannot be combined.' 2 }
            $effortMode = 'max'
        }
        '--claude-chrome' { $directChrome = $true }
        '--' {
            $forwardArguments.Add('--')
            $index++
            while ($index -lt $ClaudeArguments.Count) { $forwardArguments.Add($ClaudeArguments[$index]); $index++ }
            continue
        }
        default { $forwardArguments.Add($argument) }
    }
    $index++
}

$useProxy = $true
$injectSessionCustomizations = $true
$injectPermission = $true
$maintenanceCommands = @('--help', '-h', '--version', '-v', 'agents', 'auth', 'auto-mode', 'doctor', 'gateway', 'install', 'mcp', 'plugin', 'plugins', 'project', 'setup-token', 'ultrareview', 'update', 'upgrade')
if ($forwardArguments.Count -gt 0 -and $forwardArguments[0] -in $maintenanceCommands) {
    $useProxy = $false
    $injectSessionCustomizations = $false
    $injectPermission = $false
}
foreach ($argument in $forwardArguments) {
    if ($argument -in @('--safe-mode', '--bare')) {
        $injectSessionCustomizations = $false
        $injectPermission = $false
    }
    if ($argument -eq '--agents') { $injectSessionCustomizations = $false }
    if ($argument -in @('--permission-mode', '--dangerously-skip-permissions', '--allow-dangerously-skip-permissions')) { $injectPermission = $false }
    if ($effortMode -and ($argument -in @('--effort', '--settings') -or $argument.StartsWith('--effort=') -or $argument.StartsWith('--settings='))) {
        Fail "$argument conflicts with the selected Claudex effort shortcut." 2
    }
}

if ($directChrome) {
    if ($startModel) { Fail '--sol, --terra, --luna, and --solplan cannot be combined with --claude-chrome because Chrome requires a first-party Anthropic model.' 2 }
    $useProxy = $false
    $injectSessionCustomizations = $false
    $injectPermission = $false
    if ($env:CLAUDEX_CHROME_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR = $env:CLAUDEX_CHROME_CONFIG_DIR }
    else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    $forwardArguments.Insert(0, '--chrome')
}

Load-ClaudeCapabilities
Start-ClaudeUpdateCheck

if ($useProxy) {
    Ensure-Proxy

    $env:ANTHROPIC_BASE_URL = $proxyUrl
    $env:ANTHROPIC_AUTH_TOKEN = $proxyToken
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'gpt-5.6-sol'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'gpt-5.6-terra'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'gpt-5.6-luna'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = 'GPT-5.6 Sol'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = 'GPT-5.6 Terra'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = 'GPT-5.6 Luna'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION = 'Frontier capability for planning and the hardest engineering work'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION = 'Balanced intelligence, speed, and cost for everyday coding'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION = 'Fast, efficient model for search, triage, and mechanical tasks'
    $capabilities = 'effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES = $capabilities
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES = $capabilities
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES = $capabilities
    $env:CLAUDE_CODE_AUTO_MODE_MODEL = $autoModeModel
    $env:CLAUDE_CODE_BG_CLASSIFIER_MODEL = $backgroundModel
    $env:CLAUDE_CODE_SUBAGENT_MODEL = $subagentModel
    $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = '1'
    $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = [string] $toolConcurrencyNumber
    $env:CLAUDE_CODE_MAX_RETRIES = [string] $maxRetriesNumber
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [string] $contextWindowNumber
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string] $compactWindowNumber
} else {
    Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
}
$env:CLAUDE_CODE_USE_POWERSHELL_TOOL = '1'
$env:CLAUDEX_USAGE_DISPLAY = $usageDisplay
$env:CLAUDEX_USAGE_REFRESH_SECONDS = [string] $usageRefreshNumber
$env:CLAUDEX_USAGE_TIMEOUT_SECONDS = [string] $usageTimeoutNumber
$env:CLAUDEX_USAGE_MAX_STALE_SECONDS = [string] $usageMaxStaleNumber
$env:CLAUDEX_USAGE_SOURCE = $usageSource
$env:CLAUDEX_USAGE_ALERT_PERCENT = [string] $usageAlertNumber
$env:CLAUDE_CODE_NO_FLICKER = '1'
$env:CLAUDE_CODE_ACCESSIBILITY = '1'

$noNestedAgents = "Do not create a team, spawn or delegate to additional agents, or send intermediate progress messages to the parent. Do not create, claim, or update entries in the shared task list; the Sol leader owns task lifecycle. Complete the assigned task yourself and return one final result through the normal agent result channel. If the provider reports a 429 or model cooldown, do not launch a replacement agent or start a retry loop."
$agents = [ordered]@{
    'gpt-5-6-terra' = [ordered]@{ description = 'GPT-5.6 Terra for delegated architecture, debugging, implementation, testing, security review, and other substantial engineering work.'; prompt = "You are GPT-5.6 Terra. Investigate thoroughly, make robust focused progress, verify the result, and return concise evidence-backed findings. $noNestedAgents"; model = 'gpt-5.6-terra'; effort = 'high' }
    'gpt-5-6-luna' = [ordered]@{ description = 'GPT-5.6 Luna for delegated search, triage, inventory, and bounded mechanical tasks.'; prompt = "You are GPT-5.6 Luna. Complete the scoped task efficiently and report only relevant verified findings. $noNestedAgents"; model = 'gpt-5.6-luna'; effort = 'medium' }
}
$agentsJson = $agents | ConvertTo-Json -Depth 10 -Compress
$capacityGuard = "Claudex capacity rule: keep at most $agentConcurrencyNumber Agent tasks active at once. Launch no more than $agentConcurrencyNumber agents in a wave, wait for one to finish before starting another, and never create an agent team. Sol capacity is reserved for the leader; use the configured Terra or Luna agents for delegated work. If a model reports a 429 or cooldown, do not launch replacement agents or create a retry storm; continue useful local work and retry at most once after active agents settle."
$taskGuard = 'Claudex task lifecycle rule: the Sol leader is the sole owner of the shared task list. Keep it compact and create only tasks that represent real remaining deliverables, not duplicate discovery lanes or speculative work. Mark a task in_progress only while the leader or a currently active agent is working on it; queued or blocked work stays pending. After every agent result, immediately reconcile its parent task and mark it completed once its outcome is integrated and verified. Before every final answer, call TaskList and reconcile every entry: completed work must be completed, inactive work must not remain in_progress, and genuinely unfinished pending work must be explicitly reported instead of being hidden behind a completion claim. Never leave stale in_progress tasks after their work is done.'
$codexGuard = "Claudex Codex-model rule: operate as a Codex coding agent inside Claude Code's interface. Treat the available Claude Code tools and their schemas as the authoritative execution protocol. Prefer direct implementation and verification for concrete change requests. Do not invent unsupported provider behavior, do not expose raw internal tool protocol, and keep progress updates concise and evidence-based."
$planGuard = if ($planModePolicy -eq 'conservative') { 'Claudex plan-mode rule: remain in the current execution mode by default. Do not call EnterPlanMode or switch into plan permission mode merely because work is large, multi-step, unfamiliar, or benefits from private reasoning. Enter plan mode only when the user explicitly asks for a plan/design-only response, when a required user decision would materially change the implementation, or when the requested action is irreversible and needs approval before execution. For ordinary bug fixes and implementation requests, inspect, implement, test, and report directly.' } else { '' }
$leaderGuard = @($capacityGuard, $taskGuard, $codexGuard, $planGuard) -join ([Environment]::NewLine + [Environment]::NewLine)

$claudeLaunchArguments = New-Object 'System.Collections.Generic.List[string]'
if ($injectSessionCustomizations) {
    if (Test-ClaudeOption '--agents') { foreach ($value in @('--agents', $agentsJson)) { $claudeLaunchArguments.Add($value) } }
    if (Test-ClaudeOption '--append-system-prompt') { foreach ($value in @('--append-system-prompt', $leaderGuard)) { $claudeLaunchArguments.Add($value) } }
}
if ($injectPermission -and (Test-ClaudeOption '--permission-mode')) {
    $claudeLaunchArguments.Add('--permission-mode'); $claudeLaunchArguments.Add($launchPermissionMode)
}
if ($settingsFile -ne (Join-Path $configDir 'settings.json') -and $effortMode -ne 'ultracode') {
    $claudeLaunchArguments.Add('--settings'); $claudeLaunchArguments.Add($settingsFile)
}
if ($startModel) {
    $claudeLaunchArguments.Add('--model'); $claudeLaunchArguments.Add($startModel)
    if ($startModel -eq 'opusplan') { $env:CLAUDEX_MODEL_MODE = 'solplan' }
}
if ($effortMode -eq 'ultracode') {
    if (-not (Test-ClaudeOption '--effort')) { Fail 'this Claude Code build lacks --effort; run `claude update`.' }
    if ($directChrome) { $ultracodeSettings = [pscustomobject]@{ ultracode = $true; workflows = $true } }
    else {
        $ultracodeSettings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        $ultracodeSettings | Add-Member -NotePropertyName ultracode -NotePropertyValue $true -Force
        $ultracodeSettings | Add-Member -NotePropertyName workflows -NotePropertyValue $true -Force
    }
    $claudeLaunchArguments.Add('--settings'); $claudeLaunchArguments.Add(($ultracodeSettings | ConvertTo-Json -Depth 100 -Compress))
    $claudeLaunchArguments.Add('--effort'); $claudeLaunchArguments.Add('xhigh')
    $env:CLAUDEX_SESSION_MODE = 'ultracode'
    $env:CLAUDE_CODE_EFFORT_LEVEL = 'xhigh'
} elseif ($effortMode -eq 'max') {
    if (-not (Test-ClaudeOption '--effort')) { Fail 'this Claude Code build lacks --effort; run `claude update`.' }
    $claudeLaunchArguments.Add('--effort'); $claudeLaunchArguments.Add('max')
    $env:CLAUDEX_SESSION_MODE = 'max'
    $env:CLAUDE_CODE_EFFORT_LEVEL = 'max'
}
foreach ($value in $forwardArguments) { $claudeLaunchArguments.Add($value) }

function Set-MousePointer([string] $Shape) {
    if ($mousePointer -eq 'off' -or [Console]::IsOutputRedirected) { return }
    [Console]::Out.Write("$([char]27)]22;$Shape$([char]27)\")
}

$rewriteResumeFooter = ((-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) -or $env:CLAUDEX_TEST_TTY_OUTPUT -eq '1')
foreach ($argument in $forwardArguments) {
    if ($argument -in @('--print', '-p', '--help', '-h', '--version', '-v', 'doctor')) { $rewriteResumeFooter = $false }
}
$resumeMarker = $null
if ($rewriteResumeFooter) {
    $resumeMarker = Join-Path $configDir ('.resume-start-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($resumeMarker, '', $utf8)
}

function Update-ResumeFooter([string] $Marker) {
    if (-not $Marker -or -not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return }
    $sessionConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $projectKey = [regex]::Replace((Get-Location).Path, '[^A-Za-z0-9]', '-')
    $projectDirectory = Join-Path (Join-Path $sessionConfigDir 'projects') $projectKey
    if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) { return }
    $markerTime = (Get-Item -LiteralPath $Marker).LastWriteTimeUtc
    $latest = Get-ChildItem -LiteralPath $projectDirectory -File -Filter '*.jsonl' |
        Where-Object { $_.LastWriteTimeUtc -gt $markerTime } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $latest) { return }
    $sessionId = [IO.Path]::GetFileNameWithoutExtension($latest.Name)
    if ($sessionId -notmatch '^[0-9a-fA-F-]{36}$') { return }
    $escape = [char]27
    [Console]::Out.Write("$escape[2A$escape[JResume this session with:`nclaudex --resume $sessionId`n")
}

try {
    Set-MousePointer $mousePointer
    & claude @claudeLaunchArguments
    $exitCode = $LASTEXITCODE
    if ($rewriteResumeFooter -and $exitCode -eq 0) { Update-ResumeFooter $resumeMarker }
} finally {
    if ($resumeMarker) { Remove-Item -LiteralPath $resumeMarker -Force -ErrorAction SilentlyContinue }
    Set-MousePointer 'default'
    if ($null -eq $previousSessionMode) { Remove-Item Env:CLAUDEX_SESSION_MODE -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_SESSION_MODE = $previousSessionMode }
    if ($null -eq $previousEffortLevel) { Remove-Item Env:CLAUDE_CODE_EFFORT_LEVEL -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_CODE_EFFORT_LEVEL = $previousEffortLevel }
    if ($null -eq $previousModelMode) { Remove-Item Env:CLAUDEX_MODEL_MODE -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_MODEL_MODE = $previousModelMode }
}
exit $exitCode
