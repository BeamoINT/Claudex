param(
    [int] $ClaudexInternalProxyWatchParentProcessId = 0,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ClaudeArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($null -eq $ClaudeArguments) { $ClaudeArguments = [string[]] @() }
else { $ClaudeArguments = [string[]] @($ClaudeArguments) }
$previousSessionMode = [Environment]::GetEnvironmentVariable('CLAUDEX_SESSION_MODE', 'Process')
$previousEffortLevel = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'Process')
$previousModelMode = [Environment]::GetEnvironmentVariable('CLAUDEX_MODEL_MODE', 'Process')
$previousInteractiveTui = [Environment]::GetEnvironmentVariable('CLAUDEX_INTERACTIVE_TUI', 'Process')
$utf8 = New-Object Text.UTF8Encoding($false)

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
$autoModeModel = Env-OrDefault 'CLAUDEX_AUTO_MODE_MODEL' 'gpt-5.6-terra'
$backgroundModel = Env-OrDefault 'CLAUDEX_BACKGROUND_MODEL' 'gpt-5.6-luna'
$subagentModel = Env-OrDefault 'CLAUDEX_SUBAGENT_MODEL' 'gpt-5.6-terra'
$toolConcurrency = Env-OrDefault 'CLAUDEX_MAX_TOOL_USE_CONCURRENCY' '3'
$agentConcurrency = Env-OrDefault 'CLAUDEX_MAX_AGENT_CONCURRENCY' '3'
$maxRetries = Env-OrDefault 'CLAUDEX_MAX_RETRIES' '4'
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

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -in @('--login', '--logout', '--auth-status')) {
    if (-not (Test-Path -LiteralPath $codexSessionHelper -PathType Leaf)) { Fail 'authentication helper is missing; reinstall Claudex.' }
    $action = switch ($ClaudeArguments[0]) { '--login' { 'login' } '--logout' { 'logout' } default { 'status' } }
    & $codexSessionHelper $action
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
    Fail "missing $settingsFile; reinstall or restore the Claudex settings."
}

if ($permissionMode -notin @('manual', 'auto', 'acceptEdits', 'dontAsk', 'plan')) {
    Fail "invalid CLAUDEX_PERMISSION_MODE '$permissionMode'; expected manual, auto, acceptEdits, dontAsk, or plan." 2
}
$managedCodexModelIds = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
foreach ($modelSetting in @(
    @{ Name = 'CLAUDEX_AUTO_MODE_MODEL'; Value = $autoModeModel },
    @{ Name = 'CLAUDEX_BACKGROUND_MODEL'; Value = $backgroundModel },
    @{ Name = 'CLAUDEX_SUBAGENT_MODEL'; Value = $subagentModel }
)) {
    if ($modelSetting.Value -notin $managedCodexModelIds) {
        Fail "$($modelSetting.Name) must be a managed Codex model (gpt-5.6-sol, gpt-5.6-terra, or gpt-5.6-luna)." 2
    }
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
    [IO.File]::WriteAllText($tempFile, ($state | ConvertTo-Json -Depth 100), $utf8)
    Move-Item -LiteralPath $tempFile -Destination $stateFile -Force
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

function Test-ProxyReachable {
    if ($env:CLAUDEX_TEST_PROXY_REACHABLE_FILE) {
        return (Test-Path -LiteralPath $env:CLAUDEX_TEST_PROXY_REACHABLE_FILE -PathType Leaf)
    }
    $client = $null
    try {
        $uri = [Uri] $proxyUrl
        if ($uri.Host -notin @('127.0.0.1', 'localhost', '::1')) { return (Test-ProxyReady) }
        $client = New-Object Net.Sockets.TcpClient
        $connection = $client.ConnectAsync($uri.Host, $uri.Port)
        return $connection.Wait(500) -and $client.Connected
    } catch { return $false }
    finally { if ($client) { $client.Dispose() } }
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
        throw "authentication helper is missing: $codexSessionHelper; reinstall Claudex."
    }
    & $codexSessionHelper sync
    if ($LASTEXITCODE -ne 0) { throw "authentication synchronization failed with exit code $LASTEXITCODE." }
    if (Test-ProxyReady) { return }
    $runDir = Join-Path $configDir 'run'
    $lockDir = Join-Path $runDir 'proxy-start.lock'
    $ownerFile = Join-Path $lockDir 'owner-pid'
    [IO.Directory]::CreateDirectory($runDir) | Out-Null
    $lockAcquired = $false
    foreach ($attempt in 1..300) {
        try {
            New-Item -LiteralPath $lockDir -ItemType Directory -ErrorAction Stop | Out-Null
            [IO.File]::WriteAllText($ownerFile, "$PID`n", $utf8)
            $lockAcquired = $true
            break
        } catch {
            if (Test-ProxyReady) { return }
            try {
                $lockOwner = 0
                $ownerAlive = (Test-Path -LiteralPath $ownerFile -PathType Leaf) -and
                    [int]::TryParse(([IO.File]::ReadAllText($ownerFile).Trim()), [ref] $lockOwner) -and
                    $null -ne (Get-Process -Id $lockOwner -ErrorAction SilentlyContinue)
                if ($lockOwner -gt 0 -and -not $ownerAlive) {
                    Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $lockDir -Force -ErrorAction SilentlyContinue
                } elseif ($lockOwner -le 0 -and (Test-Path -LiteralPath $lockDir -PathType Container)) {
                    # The creator writes owner-pid immediately after creating
                    # the directory. Only recover a missing-owner lock after a
                    # short grace period so another live starter is not evicted.
                    $ownerlessAge = [DateTime]::UtcNow - (Get-Item -LiteralPath $lockDir).LastWriteTimeUtc
                    if ($ownerlessAge.TotalSeconds -ge 2) {
                        Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $lockDir -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch { }
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $lockAcquired) { throw 'timed out waiting for another session to start the local proxy.' }

    $becameReady = $false
    try {
        if (Test-ProxyReady) { $becameReady = $true; return }
        $proxyBinary = Find-ProxyExecutable
        if (-not $proxyBinary) { throw 'CLIProxyAPI is not reachable and no proxy executable was found.' }
        [Console]::Error.WriteLine('claudex: starting the local CLIProxyAPI service...')
        $proxyConfig = Env-OrDefault 'CLAUDEX_PROXY_CONFIG' (Join-Path $configDir 'cliproxyapi.yaml')
        $logDir = Join-Path $configDir 'logs'
        [IO.Directory]::CreateDirectory($logDir) | Out-Null
        $arguments = @()
        if (Test-Path -LiteralPath $proxyConfig -PathType Leaf) {
            $arguments = @('-config', ('"' + $proxyConfig + '"'))
        }
        $startParameters = @{
            FilePath = $proxyBinary
            ArgumentList = $arguments
            WorkingDirectory = $configDir
            RedirectStandardOutput = (Join-Path $logDir 'cliproxyapi.stdout.log')
            RedirectStandardError = (Join-Path $logDir 'cliproxyapi.stderr.log')
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $startParameters.WindowStyle = 'Hidden' }
        Start-Process @startParameters | Out-Null
        foreach ($attempt in 1..100) {
            if (Test-ProxyReady) { $becameReady = $true; break }
            Start-Sleep -Milliseconds 100
        }
    } finally {
        Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lockDir -Force -ErrorAction SilentlyContinue
    }
    if (-not $becameReady) { throw 'local proxy did not become healthy. Run: claudex --doctor' }
}

function Start-AuthWatcher {
    if ($env:CLAUDEX_SKIP_AUTH_WATCHER -eq '1') { return $null }
    $hostExecutable = (Get-Process -Id $PID).Path
    $quotedHelper = '"' + $codexSessionHelper.Replace('"', '\"') + '"'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedHelper,
        'watch', '-ParentProcessId', [string] $PID)
    try {
        $parameters = @{ FilePath = $hostExecutable; ArgumentList = $arguments; PassThru = $true }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $parameters.WindowStyle = 'Hidden' }
        return Start-Process @parameters
    } catch {
        [Console]::Error.WriteLine('claudex: warning: automatic Codex account switching could not be started for this session.')
        return $null
    }
}

function Invoke-ProxyWatchLoop([int] $ParentProcessId) {
    while (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) { break }
        if (-not (Test-ProxyReachable)) {
            try { Ensure-Proxy } catch {
                if ($env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE) {
                    try { Add-Content -LiteralPath $env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE -Value $_.Exception.Message } catch { }
                }
            }
        }
    }
}

function Start-ProxyWatcher {
    if ($env:CLAUDEX_SKIP_PROXY_WATCHER -eq '1') { return $null }
    $hostExecutable = (Get-Process -Id $PID).Path
    $quotedScript = '"' + $PSCommandPath.Replace('"', '\"') + '"'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedScript,
        '-ClaudexInternalProxyWatchParentProcessId', [string] $PID)
    try {
        $parameters = @{ FilePath = $hostExecutable; ArgumentList = $arguments; PassThru = $true }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $parameters.WindowStyle = 'Hidden' }
        return Start-Process @parameters
    } catch {
        [Console]::Error.WriteLine('claudex: warning: local proxy recovery watcher could not be started for this session.')
        return $null
    }
}

if ($ClaudexInternalProxyWatchParentProcessId -gt 0) {
    Invoke-ProxyWatchLoop $ClaudexInternalProxyWatchParentProcessId
    exit 0
}

# Internal watcher processes exit above before touching the user-facing state.
Update-ModelCache

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

function Update-AutoModeRules {
    $managedSettings = Join-Path $configDir 'settings.json'
    if ([IO.Path]::GetFullPath($settingsFile) -ne [IO.Path]::GetFullPath($managedSettings)) { return }
    $tempFile = $null
    try {
        $defaults = (& $script:claudeInvocation auto-mode defaults 2>$null | Out-String) | ConvertFrom-Json
        foreach ($property in @('allow', 'environment', 'soft_deny', 'hard_deny')) {
            if ($null -eq $defaults.PSObject.Properties[$property]) { return }
        }
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        if ($null -eq $settings.PSObject.Properties['autoMode']) {
            $settings | Add-Member -NotePropertyName autoMode -NotePropertyValue ([pscustomobject]@{})
        }
        $approval = 'Explicit Action Approval: A user message that explicitly approves a specific action and target, including reissuing it after a denial or unambiguously referring to the immediately preceding blocked action with language such as approve that, go ahead, or proceed, satisfies named-and-specific consent for matching SOFT BLOCK rules. Do not force the user to restate the command, ask for duplicate confirmation, or treat the prior denial as permanent. This does not override HARD BLOCK rules or authorize a broader action.'
        $requestedConfig = 'Requested Agent Configuration: Editing agent configuration is routine when the user explicitly asks for that specific configuration or permission change. Treat that edit as user-requested rather than Self-Modification; unrelated permission widening remains blocked.'
        $taskBoundary = 'User-designated task boundary: A repository, cloud project, host, bucket, service, or destination that the user explicitly identifies in their own message as owned or controlled infrastructure and as the intended target is trusted for the specifically requested operation and data flow only. Merely naming a target does not establish trust; do not infer trust for agent-selected destinations, unrelated resources, or broader scopes.'
        $approvedTransfer = 'Explicitly approved development transfer: When the user explicitly approves an exact source transfer between a named repository and a named build, deployment, or cloud host, treat that named source and destination as inside the task trust boundary for that transfer. Approval may unambiguously refer to the immediately preceding blocked command without repeating it. This never covers a public destination, credentials or secrets, unrelated files, a broader source tree, or a different host.'
        $existingAllow = if ($null -ne $settings.autoMode.PSObject.Properties['allow']) {
            @($settings.autoMode.allow | Where-Object {
                -not $_.StartsWith('Explicit Action Approval:') -and
                -not $_.StartsWith('Requested Agent Configuration:')
            })
        } else { @() }
        $existingEnvironment = if ($null -ne $settings.autoMode.PSObject.Properties['environment']) {
            @($settings.autoMode.environment | Where-Object {
                -not $_.StartsWith('User-designated task boundary:') -and
                -not $_.StartsWith('Explicitly approved development transfer:')
            })
        } else { @() }
        $composedAllow = @(@($defaults.allow) + $existingAllow + @($approval, $requestedConfig) | Select-Object -Unique)
        $composedEnvironment = @(@($defaults.environment) + $existingEnvironment + @($taskBoundary, $approvedTransfer) | Select-Object -Unique)
        $settings.autoMode | Add-Member -NotePropertyName allow -NotePropertyValue $composedAllow -Force
        $settings.autoMode | Add-Member -NotePropertyName environment -NotePropertyValue $composedEnvironment -Force
        $serializedSettings = $settings | ConvertTo-Json -Depth 100
        if ($serializedSettings -eq (Get-Content -LiteralPath $settingsFile -Raw)) { return }
        $tempFile = Join-Path $configDir ('settings.json.tmp.' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tempFile, $serializedSettings, $utf8)
        Move-Item -LiteralPath $tempFile -Destination $settingsFile -Force
        $tempFile = $null
    } catch {
        # Older Claude Code builds may not expose auto-mode defaults. The
        # shipped settings remain valid and capability negotiation continues.
    } finally {
        if ($tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
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
    if (Test-Path -LiteralPath $lock -PathType Container) {
        try {
            $lockAge = [DateTime]::UtcNow - (Get-Item -LiteralPath $lock).LastWriteTimeUtc
            if ($lockAge.TotalHours -ge 1) { Remove-Item -LiteralPath $lock -Recurse -Force }
        } catch { return }
    }
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
        { $_ -in @('gpt-5.6-sol', 'opus', 'fable') } { return 'GPT-5.6 Sol' }
        { $_ -in @('gpt-5.6-terra', 'sonnet') } { return 'GPT-5.6 Terra' }
        { $_ -in @('gpt-5.6-luna', 'haiku') } { return 'GPT-5.6 Luna' }
        default { if ($Id) { return $Id } else { return 'Unknown model' } }
    }
}

function Invoke-Doctor {
    Load-ClaudeCapabilities
    Update-AutoModeRules
    try { Ensure-Proxy } catch { Fail $_.Exception.Message }
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
    Write-Output 'Auto-mode provider: Codex/OpenAI through the authenticated loopback bridge'
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
    Write-Output "Header model name: $(Model-Name $savedModel)"
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
        default {
            # Claudex-only options are a leading prefix. Preserve all tokens
            # after Claude's first argument so option values and prompts that
            # look like Claudex flags are never consumed.
            while ($index -lt $ClaudeArguments.Count) { $forwardArguments.Add($ClaudeArguments[$index]); $index++ }
            continue
        }
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

# GPT-specific input aliases and non-interactive cleanup belong only to proxied sessions.
if ($useProxy) {
    $preload = Join-Path $configDir 'preload.cjs'
    if (Test-Path -LiteralPath $preload -PathType Leaf) {
        $preloadForBun = $preload.Replace('\', '/').Replace(' ', '\ ')
        $existingBunOptions = [Environment]::GetEnvironmentVariable('BUN_OPTIONS', 'Process')
        $env:BUN_OPTIONS = ("--preload $preloadForBun $existingBunOptions").Trim()
    }
    if ((-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) -or $env:CLAUDEX_TEST_TTY_OUTPUT -eq '1') { $env:CLAUDEX_INTERACTIVE_TUI = '1' }
    else { Remove-Item Env:CLAUDEX_INTERACTIVE_TUI -ErrorAction SilentlyContinue }
}

Load-ClaudeCapabilities
if ($useProxy -or ($forwardArguments.Count -gt 0 -and $forwardArguments[0] -eq 'auto-mode')) { Update-AutoModeRules }
if ($forwardArguments.Count -eq 0 -or $forwardArguments[0] -notin @('update', 'upgrade')) { Start-ClaudeUpdateCheck }

if ($useProxy) {
    try { Ensure-Proxy } catch { Fail $_.Exception.Message }
    $authWatcher = Start-AuthWatcher
    $proxyWatcher = Start-ProxyWatcher

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
    $authWatcher = $null
    $proxyWatcher = $null
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
$codexGuard = "Claudex Codex-model rule: operate as a Codex coding agent inside Claude Code's interface. Treat the available Claude Code tools and their schemas as the authoritative execution protocol. Prefer direct implementation and verification for concrete change requests. Ask as few questions as possible: inspect available context first, make safe reasonable assumptions, and continue without confirmation for routine, reversible, in-scope work. Never repeat a question the user already answered. Ask only when the missing answer cannot be discovered and would materially change the result, authorize a meaningful scope expansion, or precede an irreversible action. Treat the user's explicit approval as decisive for the specifically named action and target: after a soft auto-mode denial, ask for precise consent only when it is missing, then retry once when the user grants it instead of claiming the denial is permanent. Hard-deny security boundaries still apply. Do not invent unsupported provider behavior, do not expose raw internal tool protocol, and keep progress updates concise and evidence-based."
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
    $candidates = @(Get-ChildItem -LiteralPath $projectDirectory -File -Filter '*.jsonl' |
        Where-Object { $_.LastWriteTimeUtc -ge $markerTime } |
        Sort-Object LastWriteTimeUtc -Descending)
    $latest = $null
    foreach ($candidate in $candidates) {
        $candidateSessionId = [IO.Path]::GetFileNameWithoutExtension($candidate.Name)
        if ($candidateSessionId -notmatch '^[0-9a-fA-F-]{36}$') { continue }
        $matchesRootSession = $false
        foreach ($line in @(Get-Content -LiteralPath $candidate.FullName -Tail 200 -ErrorAction SilentlyContinue)) {
            try {
                $record = $line | ConvertFrom-Json
                $recordSessionId = if ($null -ne $record.PSObject.Properties['sessionId']) { [string] $record.sessionId } else { '' }
                $recordCwd = if ($null -ne $record.PSObject.Properties['cwd']) { [string] $record.cwd } else { '' }
                $isSidechain = $null -ne $record.PSObject.Properties['isSidechain'] -and [bool] $record.isSidechain
                if ($recordSessionId -eq $candidateSessionId -and $recordCwd -eq (Get-Location).Path -and -not $isSidechain) {
                    $matchesRootSession = $true
                    break
                }
            } catch { }
        }
        if ($matchesRootSession) { $latest = $candidate; break }
    }
    if ($null -eq $latest) { return }
    $sessionId = [IO.Path]::GetFileNameWithoutExtension($latest.Name)
    if ($sessionId -notmatch '^[0-9a-fA-F-]{36}$') { return }
    $escape = [char]27
    $resumeCommand = if ($directChrome) { 'claudex --claude-chrome --resume' } else { 'claudex --resume' }
    $footer = "$escape[2A$escape[JResume this session with:`n$resumeCommand $sessionId`n"
    if ($env:CLAUDEX_TEST_RESUME_CAPTURE_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_RESUME_CAPTURE_FILE, $footer, $utf8)
    }
    [Console]::Out.Write($footer)
}

try {
    Set-MousePointer $mousePointer
    & claude @claudeLaunchArguments
    $exitCode = $LASTEXITCODE
    if ($rewriteResumeFooter) { Update-ResumeFooter $resumeMarker }
} finally {
    if ($authWatcher -and -not $authWatcher.HasExited) {
        Stop-Process -Id $authWatcher.Id -Force -ErrorAction SilentlyContinue
        $authWatcher.WaitForExit(2000) | Out-Null
    }
    if ($proxyWatcher -and -not $proxyWatcher.HasExited) {
        Stop-Process -Id $proxyWatcher.Id -Force -ErrorAction SilentlyContinue
        $proxyWatcher.WaitForExit(2000) | Out-Null
    }
    if ($resumeMarker) { Remove-Item -LiteralPath $resumeMarker -Force -ErrorAction SilentlyContinue }
    Set-MousePointer 'default'
    if ($null -eq $previousSessionMode) { Remove-Item Env:CLAUDEX_SESSION_MODE -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_SESSION_MODE = $previousSessionMode }
    if ($null -eq $previousEffortLevel) { Remove-Item Env:CLAUDE_CODE_EFFORT_LEVEL -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_CODE_EFFORT_LEVEL = $previousEffortLevel }
    if ($null -eq $previousModelMode) { Remove-Item Env:CLAUDEX_MODEL_MODE -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_MODEL_MODE = $previousModelMode }
    if ($null -eq $previousInteractiveTui) { Remove-Item Env:CLAUDEX_INTERACTIVE_TUI -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_INTERACTIVE_TUI = $previousInteractiveTui }
}
exit $exitCode
