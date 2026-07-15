[CmdletBinding(PositionalBinding = $false)]
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
$sessionEnvironmentNames = @(
    'BUN_OPTIONS', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL_NAME', 'ANTHROPIC_DEFAULT_SONNET_MODEL_NAME', 'ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME',
    'ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION', 'ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION', 'ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION',
    'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES', 'ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES', 'CLAUDE_CODE_AUTO_MODE_MODEL',
    'CLAUDE_CODE_BG_CLASSIFIER_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT',
    'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY', 'CLAUDE_CODE_MAX_RETRIES', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
    'CLAUDE_CODE_AUTO_COMPACT_WINDOW'
)
$previousSessionEnvironment = @{}
foreach ($environmentName in $sessionEnvironmentNames) {
    $previousSessionEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
}
$utf8 = New-Object Text.UTF8Encoding($false)

$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$configFile = Join-Path $configDir 'env'
$settingsFile = if ($env:CLAUDEX_SETTINGS_FILE) { $env:CLAUDEX_SETTINGS_FILE } else { Join-Path $configDir 'settings.json' }
$curlCommand = if ($env:CLAUDEX_CURL_BIN) { $env:CLAUDEX_CURL_BIN } else { 'curl.exe' }

function Fail([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine("claudex: $Message")
    exit $Code
}

if (Test-Path -LiteralPath $configFile -PathType Leaf) {
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
}

function Env-OrDefault([string] $Name, [string] $Default) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

$proxyToken = Env-OrDefault 'CLAUDEX_PROXY_TOKEN' ''
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

$earlyRuntimeBypass = $false
$earlyMaintenanceCommands = @('--help', '-h', '--version', '-v', 'agents', 'auth', 'gateway', 'install', 'mcp', 'plugin', 'plugins', 'project', 'setup-token', 'ultrareview', 'update', 'upgrade')
foreach ($earlyArgument in $ClaudeArguments) {
    if ($earlyArgument -eq '--claude-chrome') { $earlyRuntimeBypass = $true; break }
    if ($earlyArgument -in @('--sol', '--terra', '--luna', '--solplan', '--manual', '--auto', '--accept-edits', '--ultracode', '--max-effort')) { continue }
    if ($earlyArgument -in $earlyMaintenanceCommands) { $earlyRuntimeBypass = $true }
    break
}

$managedCodexModelIds = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
function Assert-ProxyConfiguration {
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        Fail "missing $configFile; reinstall or restore the Claudex configuration."
    }
    if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
        Fail "missing $settingsFile; reinstall or restore the Claudex settings."
    }
    if (-not $proxyToken) { Fail 'CLAUDEX_PROXY_TOKEN is not configured' }
    if ($proxyToken.Contains("`r") -or $proxyToken.Contains("`n")) { Fail 'CLAUDEX_PROXY_TOKEN contains an unsupported newline.' 2 }
    if ($model -notin $managedCodexModelIds) {
        Fail "invalid CLAUDEX_MODEL '$model'; expected gpt-5.6-sol, gpt-5.6-terra, or gpt-5.6-luna." 2
    }
}
if (-not $earlyRuntimeBypass) {
    if ($permissionMode -notin @('manual', 'auto', 'acceptEdits', 'dontAsk', 'plan')) {
        Fail "invalid CLAUDEX_PERMISSION_MODE '$permissionMode'; expected manual, auto, acceptEdits, dontAsk, or plan." 2
    }
    foreach ($modelSetting in @(
        @{ Name = 'CLAUDEX_AUTO_MODE_MODEL'; Value = $autoModeModel },
        @{ Name = 'CLAUDEX_BACKGROUND_MODEL'; Value = $backgroundModel },
        @{ Name = 'CLAUDEX_SUBAGENT_MODEL'; Value = $subagentModel }
    )) {
        if ($modelSetting.Value -notin $managedCodexModelIds) {
            Fail "$($modelSetting.Name) must be a managed Codex model (gpt-5.6-sol, gpt-5.6-terra, or gpt-5.6-luna)." 2
        }
    }
}

function Require-Integer([string] $Name, [string] $Value, [int] $Minimum, [int] $Maximum) {
    $number = 0
    if (-not [int]::TryParse($Value, [ref] $number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        Fail "$Name must be an integer from $Minimum to $Maximum." 2
    }
    return $number
}

if (-not $earlyRuntimeBypass) {
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
    if ($mousePointer -notin @('pointer', 'default', 'off')) { Fail 'CLAUDEX_MOUSE_POINTER_SHAPE must be pointer, default, or off.' 2 }
    if ($usageDisplay -notin @('on', 'off')) { Fail 'CLAUDEX_USAGE_DISPLAY must be on or off.' 2 }
    if ($usageSource -notin @('auto', 'web', 'app-server')) { Fail 'CLAUDEX_USAGE_SOURCE must be auto, web, or app-server.' 2 }
    if ($claudeAutoUpdate -notin @('on', 'off')) { Fail 'CLAUDEX_CLAUDE_AUTO_UPDATE must be on or off.' 2 }
    if ($planModePolicy -notin @('conservative', 'normal')) { Fail 'CLAUDEX_PLAN_MODE_POLICY must be conservative or normal.' 2 }
} else {
    $toolConcurrencyNumber = 3; $agentConcurrencyNumber = 3; $maxRetriesNumber = 4
    $contextWindowNumber = 400000; $compactWindowNumber = 280000
    $usageRefreshNumber = 300; $usageTimeoutNumber = 8; $usageMaxStaleNumber = 86400; $usageAlertNumber = 20
    $claudeUpdateIntervalNumber = 86400
    if ($mousePointer -notin @('pointer', 'default', 'off')) { $mousePointer = 'pointer' }
    if ($usageDisplay -notin @('on', 'off')) { $usageDisplay = 'on' }
    if ($usageSource -notin @('auto', 'web', 'app-server')) { $usageSource = 'auto' }
    if ($claudeAutoUpdate -notin @('on', 'off')) { $claudeAutoUpdate = 'on' }
    if ($planModePolicy -notin @('conservative', 'normal')) { $planModePolicy = 'conservative' }
    if ($permissionMode -notin @('manual', 'auto', 'acceptEdits', 'dontAsk', 'plan')) { $permissionMode = 'auto' }
    if ($autoModeModel -notin $managedCodexModelIds) { $autoModeModel = 'gpt-5.6-terra' }
    if ($backgroundModel -notin $managedCodexModelIds) { $backgroundModel = 'gpt-5.6-luna' }
    if ($subagentModel -notin $managedCodexModelIds) { $subagentModel = 'gpt-5.6-terra' }
}

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

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void] $builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void] $builder.Append(('\' * (($slashes * 2) + 1)))
            [void] $builder.Append('"')
        } else {
            if ($slashes -gt 0) { [void] $builder.Append(('\' * $slashes)) }
            [void] $builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void] $builder.Append(('\' * ($slashes * 2))) }
    [void] $builder.Append('"')
    return $builder.ToString()
}

function Join-WindowsCommandLine([string[]] $Arguments) {
    return (@($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument ([string] $_) }) -join ' ')
}

function Invoke-CurlWithDeadline([string[]] $Arguments, [string] $StandardInput, [int] $TimeoutMilliseconds) {
    $command = Get-Command $curlCommand -ErrorAction SilentlyContinue
    if (-not $command) { throw "curl executable was not found: $curlCommand" }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $commandPath = [string] $command.Source
    $extension = [IO.Path]::GetExtension($commandPath).ToLowerInvariant()
    if ($command.CommandType -eq 'ExternalScript' -or $extension -in @('.ps1', '.cmd', '.bat')) {
        # ProcessStartInfo cannot CreateProcess a command shim directly. Run a
        # fixed, encoded bootstrap and keep credentials on stdin, never argv.
        $escapedPath = $commandPath.Replace("'", "''")
        $argumentLiteral = @($Arguments | ForEach-Object { "'" + ([string] $_).Replace("'", "''") + "'" }) -join ','
        $bootstrap = "`$payload=[Console]::In.ReadToEnd(); `$payload | & '$escapedPath' @($argumentLiteral); exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.Arguments = Join-WindowsCommandLine @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    } else {
        $startInfo.FileName = $commandPath
        $startInfo.Arguments = Join-WindowsCommandLine $Arguments
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'could not start curl.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit(1000) | Out-Null } catch { }
            throw 'proxy request exceeded its wall-clock deadline.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        [void] $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "proxy request failed with exit code $($process.ExitCode)." }
        return $output
    } finally {
        $process.Dispose()
    }
}

function Fetch-Models([int] $TimeoutMilliseconds = 5000) {
    $timeoutMilliseconds = [math]::Max(250, [math]::Min(5000, $TimeoutMilliseconds))
    $curlSeconds = [math]::Max(1, [int] [math]::Ceiling($timeoutMilliseconds / 1000.0))
    $healthRunDir = Join-Path $configDir 'run'
    [IO.Directory]::CreateDirectory($healthRunDir) | Out-Null
    $headerFile = Join-Path $healthRunDir ('.proxy-health-header-' + [guid]::NewGuid().ToString('N'))
    try {
        # PowerShell 5 can surface piped stdin in a .cmd invocation's command
        # context. Curl's @file syntax keeps the bearer value out of argv while
        # remaining compatible with native curl.exe and test/enterprise shims.
        [IO.File]::WriteAllText($headerFile, "Authorization: Bearer $proxyToken`n", $utf8)
        $output = Invoke-CurlWithDeadline @('--silent', '--show-error', '--connect-timeout', '1',
            '--max-time', [string] $curlSeconds, '--write-out', "`n%{http_code}", '--header', "@$headerFile", "$proxyUrl/v1/models") `
            '' $timeoutMilliseconds
    } finally {
        Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue
    }
    $normalized = $output.Replace("`r`n", "`n").TrimEnd([char[]] "`r`n")
    $lastNewline = $normalized.LastIndexOf("`n")
    $status = 200
    $body = $normalized
    if ($lastNewline -ge 0 -and $normalized.Substring($lastNewline + 1) -match '^\d{3}$') {
        $status = [int] $Matches[0]
        $body = $normalized.Substring(0, $lastNewline)
    }
    if ($status -in @(401, 403)) {
        throw (New-Object UnauthorizedAccessException -ArgumentList 'the proxy rejected the configured local authentication token.')
    }
    if ($status -lt 200 -or $status -ge 300) { throw "proxy health endpoint returned HTTP $status." }
    return ($body | ConvertFrom-Json)
}

function Get-ProxyHealth([int] $TimeoutMilliseconds = 5000) {
    try {
        $models = Fetch-Models $TimeoutMilliseconds
        $script:lastProxyModelIds = @($models.data | ForEach-Object { [string] $_.id } | Where-Object { $_ })
        if ($script:lastProxyModelIds.Count -gt 0) { return 'healthy' }
        Write-ProxyRecoveryDiagnostic 'proxy health response contained no model identifiers'
        return 'unhealthy'
    } catch [UnauthorizedAccessException] {
        Write-ProxyRecoveryDiagnostic 'proxy health request was rejected by local authentication'
        return 'authentication-failed'
    } catch {
        Write-ProxyRecoveryDiagnostic ("proxy health request failed: " + $_.Exception.Message)
        return 'unhealthy'
    }
}

function Test-ProxyReady([int] $TimeoutMilliseconds = 5000) {
    return (Get-ProxyHealth $TimeoutMilliseconds) -eq 'healthy'
}

function Test-ProxyReachable {
    if ($env:CLAUDEX_TEST_PROXY_REACHABLE_FILE) {
        return (Test-Path -LiteralPath $env:CLAUDEX_TEST_PROXY_REACHABLE_FILE -PathType Leaf)
    }
    # A listening socket is not health: a wedged, unauthenticated, or unrelated
    # service can own the port. Require the authenticated models contract.
    return (Get-ProxyHealth 2000) -eq 'healthy'
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

function Write-ProxyRecoveryDiagnostic([string] $Message) {
    try {
        $logDir = Join-Path $configDir 'logs'
        $logFile = Join-Path $logDir 'proxy-recovery.log'
        [IO.Directory]::CreateDirectory($logDir) | Out-Null
        $safeMessage = ([string] $Message).Replace("`r", ' ').Replace("`n", ' ')
        if ($proxyToken) { $safeMessage = $safeMessage.Replace($proxyToken, '[redacted]') }
        [IO.File]::AppendAllText($logFile,
            "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK') $safeMessage$([Environment]::NewLine)", $utf8)
        $item = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 131072) {
            $content = [IO.File]::ReadAllText($logFile)
            $keep = if ($content.Length -gt 65536) { $content.Substring($content.Length - 65536) } else { $content }
            $firstNewline = $keep.IndexOf("`n")
            if ($firstNewline -ge 0) { $keep = $keep.Substring($firstNewline + 1) }
            $temporary = "$logFile.tmp.$PID.$([guid]::NewGuid().ToString('N'))"
            [IO.File]::WriteAllText($temporary, $keep, $utf8)
            Move-Item -LiteralPath $temporary -Destination $logFile -Force
        }
    } catch { }
}

function Get-ProxyStartupMutexName {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [IO.Path]::GetFullPath($configDir).ToLowerInvariant()
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))
        $suffix = -join ($hash[0..15] | ForEach-Object { $_.ToString('x2') })
        return "Local\Claudex.ProxyStart.$suffix"
    } finally { $sha.Dispose() }
}

function Assert-ProxyModelAvailable([string] $RequiredModel) {
    if (-not $RequiredModel) { return }
    # opusplan is Claude Code's virtual plan/implementation route. The proxy
    # advertises the two concrete Codex models that back it, not the alias.
    $requiredModels = if ($RequiredModel -eq 'opusplan') { @('gpt-5.6-sol', 'gpt-5.6-terra') } else { @($RequiredModel) }
    $missingModels = @($requiredModels | Where-Object { $script:lastProxyModelIds -notcontains $_ })
    if ($missingModels.Count -gt 0) {
        Write-ProxyRecoveryDiagnostic "proxy is healthy but selected model route is unavailable: $RequiredModel (missing: $($missingModels -join ', '))"
        throw "the authenticated Codex account does not advertise the model route required by '$RequiredModel'. Run: claudex --doctor"
    }
}

function Ensure-Proxy([string] $RequiredModel = $model) {
    Write-ProxyWatcherTestTrace 'recovery: begin'
    if (-not (Test-Path -LiteralPath $codexSessionHelper -PathType Leaf)) {
        throw "authentication helper is missing: $codexSessionHelper; reinstall Claudex."
    }
    & $codexSessionHelper sync
    if ($LASTEXITCODE -ne 0) { throw "authentication synchronization failed with exit code $LASTEXITCODE." }
    Write-ProxyWatcherTestTrace 'recovery: authentication synchronized'
    $initialHealth = Get-ProxyHealth 3000
    if ($initialHealth -eq 'healthy') { Assert-ProxyModelAvailable $RequiredModel; return }
    if ($initialHealth -eq 'authentication-failed') {
        Write-ProxyRecoveryDiagnostic 'proxy authentication failed; startup was not attempted'
        throw 'the running local proxy rejected the configured authentication token; reinstall Claudex or restore its managed env and proxy config.'
    }
    Write-ProxyWatcherTestTrace 'recovery: readiness check failed'
    Write-ProxyRecoveryDiagnostic 'authenticated proxy readiness failed; entering recovery'
    $runDir = Join-Path $configDir 'run'
    $lockDir = Join-Path $runDir 'proxy-start.lock'
    $ownerFile = Join-Path $lockDir 'owner-pid'
    [IO.Directory]::CreateDirectory($runDir) | Out-Null
    $lockAcquired = $false
    $legacyLockOwned = $false
    $startupMutex = $null
    $useNamedMutex = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    if ($useNamedMutex) {
        $lockDeadline = [DateTime]::UtcNow.AddSeconds(30)
        $startupMutex = New-Object Threading.Mutex($false, (Get-ProxyStartupMutexName))
        try { $lockAcquired = $startupMutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
        if ($lockAcquired) {
            try {
                # Keep interoperating with an older launcher that only knows
                # the directory lock. A recent legacy owner gets a bounded
                # chance to finish; an old/PID-reused record is reclaimed.
                if (Test-Path -LiteralPath $lockDir -PathType Container) {
                    $legacyAge = [DateTime]::UtcNow - (Get-Item -LiteralPath $lockDir).LastWriteTimeUtc
                    if ($legacyAge.TotalMinutes -lt 2) {
                        while ([DateTime]::UtcNow -lt $lockDeadline) {
                            if (Test-ProxyReady 1000) {
                                Assert-ProxyModelAvailable $RequiredModel
                                $startupMutex.ReleaseMutex()
                                $startupMutex.Dispose()
                                return
                            }
                            Start-Sleep -Milliseconds 100
                        }
                    }
                    Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -Path $lockDir -ItemType Directory -ErrorAction Stop | Out-Null
                [IO.File]::WriteAllText($ownerFile, "$PID`n", $utf8)
                $legacyLockOwned = $true
            } catch {
                try { $startupMutex.ReleaseMutex() } catch { }
                $startupMutex.Dispose()
                throw
            }
        }
    } else {
        foreach ($attempt in 1..300) {
            try {
                New-Item -Path $lockDir -ItemType Directory -ErrorAction Stop | Out-Null
                [IO.File]::WriteAllText($ownerFile, "$PID`n", $utf8)
                $lockAcquired = $true
                break
            } catch {
                if (Test-ProxyReady 1000) { Assert-ProxyModelAvailable $RequiredModel; return }
                try {
                    $lockOwner = 0
                    $ownerAlive = (Test-Path -LiteralPath $ownerFile -PathType Leaf) -and
                        [int]::TryParse(([IO.File]::ReadAllText($ownerFile).Trim()), [ref] $lockOwner) -and
                        $null -ne (Get-Process -Id $lockOwner -ErrorAction SilentlyContinue)
                    if ($lockOwner -gt 0 -and -not $ownerAlive) {
                        Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $lockDir -Force -ErrorAction SilentlyContinue
                    } elseif ($lockOwner -le 0 -and (Test-Path -LiteralPath $lockDir -PathType Container)) {
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
    }
    if (-not $lockAcquired) {
        if ($startupMutex) { $startupMutex.Dispose() }
        Write-ProxyRecoveryDiagnostic 'timed out waiting for the proxy startup mutex'
        throw 'timed out waiting for another session to start the local proxy.'
    }
    Write-ProxyWatcherTestTrace 'recovery: startup lock acquired'
    Write-ProxyRecoveryDiagnostic 'proxy startup lock acquired'

    $becameReady = $false
    try {
        if (Test-ProxyReady 2000) { Assert-ProxyModelAvailable $RequiredModel; $becameReady = $true; return }
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
            WorkingDirectory = $configDir
            RedirectStandardOutput = (Join-Path $logDir 'cliproxyapi.stdout.log')
            RedirectStandardError = (Join-Path $logDir 'cliproxyapi.stderr.log')
        }
        if ($arguments.Count -gt 0) { $startParameters.ArgumentList = $arguments }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $startParameters.WindowStyle = 'Hidden' }
        Write-ProxyWatcherTestTrace "recovery: starting $proxyBinary"
        Write-ProxyRecoveryDiagnostic "starting compatibility service: $proxyBinary"
        Start-Process @startParameters | Out-Null
        Write-ProxyWatcherTestTrace 'recovery: process launched'
        $readinessDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $readinessDeadline) {
            $remaining = [int] [math]::Max(250, ($readinessDeadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (Test-ProxyReady ([math]::Min(2000, $remaining))) {
                Assert-ProxyModelAvailable $RequiredModel
                $becameReady = $true
                break
            }
            Start-Sleep -Milliseconds 100
        }
        Write-ProxyWatcherTestTrace "recovery: readiness loop completed; ready=$becameReady"
        Write-ProxyRecoveryDiagnostic "proxy readiness loop completed; ready=$becameReady"
    } finally {
        if ($useNamedMutex) {
            if ($legacyLockOwned) {
                Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($lockAcquired) { try { $startupMutex.ReleaseMutex() } catch { } }
            if ($startupMutex) { $startupMutex.Dispose() }
        } else {
            Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $lockDir -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $becameReady) {
        throw 'local proxy did not become healthy before the 15-second deadline. Run: claudex --doctor'
    }
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

function Write-ProxyWatcherTestTrace([string] $Message) {
    if (-not $env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE) { return }
    try { Add-Content -LiteralPath $env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE -Value $Message } catch { }
}

function Invoke-ProxyWatchLoop([int] $ParentProcessId) {
    Write-ProxyWatcherTestTrace "watcher entered for parent $ParentProcessId"
    while (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) { break }
        if (-not (Test-ProxyReachable)) {
            Write-ProxyWatcherTestTrace 'proxy unreachable; starting recovery'
            try {
                Ensure-Proxy
                Write-ProxyWatcherTestTrace 'proxy recovery completed'
            } catch {
                Write-ProxyWatcherTestTrace ("proxy recovery failed: " + $_.Exception.Message)
                Write-ProxyRecoveryDiagnostic ("proxy recovery failed: " + $_.Exception.Message)
            }
        }
    }
    Write-ProxyWatcherTestTrace 'watcher exited'
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

# Internal watcher processes exit above before touching user-facing state.

function Resolve-ClaudeCommand {
    $claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCommand) { Fail 'Claude Code was not found. Install Claude Code and retry.' }
    $script:claudeCommand = $claudeCommand
    $script:claudeInvocation = if ($claudeCommand.CommandType -eq 'Function') { $claudeCommand.Name } else { $claudeCommand.Source }
}

function Load-ClaudeCapabilities {
    Resolve-ClaudeCommand
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
    $snapshotTemp = $null
    try {
        $snapshotFile = Join-Path $configDir 'auto-mode-defaults.json'
        $previousSnapshot = $null
        if (Test-Path -LiteralPath $snapshotFile -PathType Leaf) {
            try {
                $candidateSnapshot = Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
                $snapshotValid = $true
                foreach ($property in @('allow', 'environment', 'soft_deny', 'hard_deny')) {
                    if ($null -eq $candidateSnapshot.PSObject.Properties[$property]) { $snapshotValid = $false; break }
                }
                if ($snapshotValid) { $previousSnapshot = $candidateSnapshot }
            } catch { }
        }
        $defaultsAreFresh = $false
        try {
            $defaults = (& $script:claudeInvocation auto-mode defaults 2>$null | Out-String) | ConvertFrom-Json
            foreach ($property in @('allow', 'environment', 'soft_deny', 'hard_deny')) {
                if ($null -eq $defaults.PSObject.Properties[$property]) { throw "missing auto-mode default: $property" }
            }
            $defaultsAreFresh = $true
        } catch {
            if ($null -eq $previousSnapshot) { return }
            $defaults = $previousSnapshot
        }
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        if ($null -eq $settings.PSObject.Properties['autoMode']) {
            $settings | Add-Member -NotePropertyName autoMode -NotePropertyValue ([pscustomobject]@{})
        }
        $previousAllow = @()
        $previousEnvironment = @()
        if ($null -ne $previousSnapshot) {
            $previousAllow = @($previousSnapshot.allow)
            $previousEnvironment = @($previousSnapshot.environment)
        }
        $approval = 'Explicit Action Approval: A user message that explicitly approves a specific action and target, including reissuing it after a denial or unambiguously referring to the immediately preceding blocked action with language such as approve that, go ahead, or proceed, satisfies named-and-specific consent for matching SOFT BLOCK rules. Do not force the user to restate the command, ask for duplicate confirmation, or treat the prior denial as permanent. This does not override HARD BLOCK rules or authorize a broader action.'
        $requestedConfig = 'Requested Agent Configuration: Editing agent configuration is routine when the user explicitly asks for that specific configuration or permission change. Treat that edit as user-requested rather than Self-Modification; unrelated permission widening remains blocked.'
        $taskBoundary = 'User-designated task boundary: A repository, cloud project, host, bucket, service, or destination that the user explicitly identifies in their own message as owned or controlled infrastructure and as the intended target is trusted for the specifically requested operation and data flow only. Merely naming a target does not establish trust; do not infer trust for agent-selected destinations, unrelated resources, or broader scopes.'
        $approvedTransfer = 'Explicitly approved development transfer: When the user explicitly approves an exact source transfer between a named repository and a named build, deployment, or cloud host, treat that named source and destination as inside the task trust boundary for that transfer. Approval may unambiguously refer to the immediately preceding blocked command without repeating it. This never covers a public destination, credentials or secrets, unrelated files, a broader source tree, or a different host.'
        $existingAllow = if ($null -ne $settings.autoMode.PSObject.Properties['allow']) {
            @($settings.autoMode.allow | Where-Object {
                -not $_.StartsWith('Explicit Action Approval:') -and
                -not $_.StartsWith('Requested Agent Configuration:') -and
                $_ -notin $previousAllow
            })
        } else { @() }
        $existingEnvironment = if ($null -ne $settings.autoMode.PSObject.Properties['environment']) {
            @($settings.autoMode.environment | Where-Object {
                -not $_.StartsWith('User-designated task boundary:') -and
                -not $_.StartsWith('Explicitly approved development transfer:') -and
                $_ -notin $previousEnvironment
            })
        } else { @() }
        $composedAllow = @(@($defaults.allow) + $existingAllow + @($approval, $requestedConfig) | Select-Object -Unique)
        $composedEnvironment = @(@($defaults.environment) + $existingEnvironment + @($taskBoundary, $approvedTransfer) | Select-Object -Unique)
        $settings.autoMode | Add-Member -NotePropertyName allow -NotePropertyValue $composedAllow -Force
        $settings.autoMode | Add-Member -NotePropertyName environment -NotePropertyValue $composedEnvironment -Force
        $serializedSettings = $settings | ConvertTo-Json -Depth 100
        if ($serializedSettings -ne (Get-Content -LiteralPath $settingsFile -Raw)) {
            $tempFile = Join-Path $configDir ('settings.json.tmp.' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($tempFile, $serializedSettings, $utf8)
            Move-Item -LiteralPath $tempFile -Destination $settingsFile -Force
            $tempFile = $null
        }
        if ($defaultsAreFresh) {
            $snapshot = [ordered]@{
                allow = @($defaults.allow)
                environment = @($defaults.environment)
                soft_deny = @($defaults.soft_deny)
                hard_deny = @($defaults.hard_deny)
            }
            $snapshotTemp = Join-Path $configDir ('.auto-mode-defaults.tmp.' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($snapshotTemp, (($snapshot | ConvertTo-Json -Depth 20) + "`n"), $utf8)
            Move-Item -LiteralPath $snapshotTemp -Destination $snapshotFile -Force
            $snapshotTemp = $null
        }
    } catch {
        # Older Claude Code builds may not expose auto-mode defaults. The
        # shipped settings remain valid and capability negotiation continues.
    } finally {
        if ($tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        if ($snapshotTemp) { Remove-Item -LiteralPath $snapshotTemp -Force -ErrorAction SilentlyContinue }
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
    try { New-Item -Path $lock -ItemType Directory -ErrorAction Stop | Out-Null } catch { return }
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
    Assert-ProxyConfiguration
    Update-ModelCache
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
    foreach ($environmentName in $sessionEnvironmentNames | Where-Object {
        $_ -like 'ANTHROPIC_DEFAULT_*' -or $_ -like 'CLAUDE_CODE_*MODEL*' -or $_ -eq 'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT'
    }) {
        Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
    }
    $forwardArguments.Insert(0, '--chrome')
}

if ($useProxy) {
    Assert-ProxyConfiguration
    Update-ModelCache
    if (-not $startModel) { $startModel = $model }
}

# GPT-specific input aliases and non-interactive cleanup belong only to proxied sessions.
$preload = Join-Path $configDir 'preload.cjs'
$preloadForBun = $preload.Replace('\', '/').Replace(' ', '\ ')
$existingBunOptions = [Environment]::GetEnvironmentVariable('BUN_OPTIONS', 'Process')
function Remove-ClaudexPreloadOption([string] $Options) {
    if (-not $Options) { return '' }
    $managed = "--preload $preloadForBun"
    $quotedManaged = '--preload "' + $preload.Replace('\', '/') + '"'
    $cleaned = [regex]::Replace($Options, '(^|\s)' + [regex]::Escape($managed) + '(?=\s|$)', ' ')
    $cleaned = [regex]::Replace($cleaned, '(^|\s)' + [regex]::Escape($quotedManaged) + '(?=\s|$)', ' ')
    return ([regex]::Replace($cleaned, '\s+', ' ')).Trim()
}
$cleanBunOptions = Remove-ClaudexPreloadOption $existingBunOptions
if ($useProxy) {
    if (Test-Path -LiteralPath $preload -PathType Leaf) {
        $env:BUN_OPTIONS = ("--preload $preloadForBun $cleanBunOptions").Trim()
    } elseif ($cleanBunOptions) { $env:BUN_OPTIONS = $cleanBunOptions }
    else { Remove-Item Env:BUN_OPTIONS -ErrorAction SilentlyContinue }
    if ((-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) -or $env:CLAUDEX_TEST_TTY_OUTPUT -eq '1') { $env:CLAUDEX_INTERACTIVE_TUI = '1' }
    else { Remove-Item Env:CLAUDEX_INTERACTIVE_TUI -ErrorAction SilentlyContinue }
} elseif ($cleanBunOptions) {
    $env:BUN_OPTIONS = $cleanBunOptions
} else {
    Remove-Item Env:BUN_OPTIONS -ErrorAction SilentlyContinue
}

if ($useProxy -or $effortMode) { Load-ClaudeCapabilities }
else { Resolve-ClaudeCommand; $script:claudeHelp = '' }
if ($useProxy -or ($forwardArguments.Count -gt 0 -and $forwardArguments[0] -eq 'auto-mode')) { Update-AutoModeRules }
if ($forwardArguments.Count -eq 0 -or $forwardArguments[0] -notin @('update', 'upgrade')) { Start-ClaudeUpdateCheck }

if ($useProxy) {
    try { Ensure-Proxy $startModel } catch { Fail $_.Exception.Message }
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
$requestedResumeSessionId = ''
for ($resumeIndex = 0; $resumeIndex -lt $forwardArguments.Count; $resumeIndex++) {
    $resumeArgument = [string] $forwardArguments[$resumeIndex]
    if ($resumeArgument -in @('--resume', '--session-id') -and $resumeIndex + 1 -lt $forwardArguments.Count) {
        $requestedResumeSessionId = [string] $forwardArguments[$resumeIndex + 1]
        break
    }
    if ($resumeArgument -match '^--(?:resume|session-id)=(.+)$') {
        $requestedResumeSessionId = $Matches[1]
        break
    }
}
if ($requestedResumeSessionId -notmatch '^[0-9a-fA-F-]{36}$') { $requestedResumeSessionId = '' }
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
    if ($requestedResumeSessionId) {
        $explicitCandidate = Join-Path $projectDirectory ($requestedResumeSessionId + '.jsonl')
        $candidates = if (Test-Path -LiteralPath $explicitCandidate -PathType Leaf) { @((Get-Item -LiteralPath $explicitCandidate)) } else { @() }
    } else {
        $allCandidates = @(Get-ChildItem -LiteralPath $projectDirectory -File -Filter '*.jsonl')
        # A new root session creates its transcript near launch. Prefer the
        # earliest newly-created matching transcript so a later same-cwd tab
        # cannot steal this launch's footer merely by exiting first.
        $newCandidates = @($allCandidates | Where-Object { $_.CreationTimeUtc -ge $markerTime } |
            Sort-Object CreationTimeUtc, Name)
        $newNames = @($newCandidates | ForEach-Object { $_.FullName })
        $updatedCandidates = @($allCandidates | Where-Object {
            $_.LastWriteTimeUtc -ge $markerTime -and $_.FullName -notin $newNames
        } | Sort-Object LastWriteTimeUtc -Descending)
        $candidates = @($newCandidates + $updatedCandidates)
    }
    $matchingCandidates = @()
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
        if ($matchesRootSession) { $matchingCandidates += $candidate }
    }
    # Never guess between concurrent same-directory sessions. Claude's native
    # footer remains intact; correction is appended only when attribution is
    # unambiguous (or an explicit resume/session ID selected one transcript).
    if ($matchingCandidates.Count -ne 1) { return }
    $latest = $matchingCandidates[0]
    $sessionId = [IO.Path]::GetFileNameWithoutExtension($latest.Name)
    if ($sessionId -notmatch '^[0-9a-fA-F-]{36}$') { return }
    $resumeCommand = if ($directChrome) { 'claudex --claude-chrome --resume' } else { 'claudex --resume' }
    $footer = "Claudex resume: $resumeCommand $sessionId`n"
    if ($env:CLAUDEX_TEST_RESUME_CAPTURE_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_RESUME_CAPTURE_FILE, $footer, $utf8)
    }
    [Console]::Out.Write($footer)
}

function ConvertTo-CmdArgument([string] $Value) {
    if ($null -eq $Value) { $Value = '' }
    # Delayed expansion is disabled by the caller. Keep metacharacters inside a
    # quoted token and use cmd's doubled-quote representation for literal quotes.
    return '"' + $Value.Replace('%', '%%').Replace('"', '""') + '"'
}

function Invoke-ClaudeProcess([Collections.Generic.List[string]] $Arguments) {
    if ($script:claudeCommand.CommandType -in @('Function', 'Filter', 'Cmdlet')) {
        & $script:claudeInvocation @Arguments
        $script:claudeProcessExitCode = if ($null -ne $LASTEXITCODE) { [int] $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        return
    }
    if ($script:claudeCommand.CommandType -eq 'ExternalScript') {
        & $script:claudeInvocation @Arguments
        $script:claudeProcessExitCode = if ($null -ne $LASTEXITCODE) { [int] $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        return
    }

    $commandPath = [string] $script:claudeCommand.Source
    $extension = [IO.Path]::GetExtension($commandPath).ToLowerInvariant()
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    if ($extension -in @('.cmd', '.bat')) {
        $commandLine = (ConvertTo-CmdArgument $commandPath) + ' ' +
            (@($Arguments | ForEach-Object { ConvertTo-CmdArgument ([string] $_) }) -join ' ')
        $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $startInfo.Arguments = Join-WindowsCommandLine @('/d', '/s', '/v:off', '/c', $commandLine)
    } else {
        $startInfo.FileName = $commandPath
        $startInfo.Arguments = Join-WindowsCommandLine @($Arguments)
    }
    $startInfo.UseShellExecute = $false
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Claude Code could not be started.' }
        $process.WaitForExit()
        $script:claudeProcessExitCode = $process.ExitCode
    } finally { $process.Dispose() }
}

try {
    Set-MousePointer $mousePointer
    $script:claudeProcessExitCode = 1
    Invoke-ClaudeProcess $claudeLaunchArguments
    $exitCode = $script:claudeProcessExitCode
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
    foreach ($environmentName in $sessionEnvironmentNames) {
        $previousValue = $previousSessionEnvironment[$environmentName]
        if ($null -eq $previousValue) { Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($environmentName, [string] $previousValue, 'Process') }
    }
}
exit $exitCode
