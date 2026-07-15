param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ClaudeArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ClaudeArguments = @($ClaudeArguments)

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
$proxyUrl = Env-OrDefault 'CLAUDEX_PROXY_URL' 'http://127.0.0.1:8317'
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
if ($mousePointer -notin @('pointer', 'default', 'off')) {
    Fail 'CLAUDEX_MOUSE_POINTER_SHAPE must be pointer, default, or off.' 2
}

$env:CLAUDE_CONFIG_DIR = $configDir
$stateFile = Join-Path $configDir '.claude.json'
$managedModels = @(
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
    $output = & $curlCommand --silent --show-error --fail --max-time 5 `
        -H "Authorization: Bearer $proxyToken" "$proxyUrl/v1/models" 2>$null
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
    foreach ($name in @('cliproxyapi.exe', 'cli-proxy-api.exe', 'cliproxyapi', 'cli-proxy-api')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

function Ensure-Proxy {
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

function Model-Name([string] $Id) {
    switch ($Id) {
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

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--doctor') {
    Invoke-Doctor
    exit 0
}

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
$env:CLAUDE_CODE_USE_POWERSHELL_TOOL = '1'

$noNestedAgents = "Do not create a team, spawn or delegate to additional agents, or send intermediate progress messages to the parent. Do not create, claim, or update entries in the shared task list; the Sol leader owns task lifecycle. Complete the assigned task yourself and return one final result through the normal agent result channel. If the provider reports a 429 or model cooldown, do not launch a replacement agent or start a retry loop."
$agents = [ordered]@{
    'gpt-5-6-terra' = [ordered]@{ description = 'GPT-5.6 Terra for delegated architecture, debugging, implementation, testing, security review, and other substantial engineering work.'; prompt = "You are GPT-5.6 Terra. Investigate thoroughly, make robust focused progress, verify the result, and return concise evidence-backed findings. $noNestedAgents"; model = 'gpt-5.6-terra'; effort = 'high' }
    'gpt-5-6-luna' = [ordered]@{ description = 'GPT-5.6 Luna for delegated search, triage, inventory, and bounded mechanical tasks.'; prompt = "You are GPT-5.6 Luna. Complete the scoped task efficiently and report only relevant verified findings. $noNestedAgents"; model = 'gpt-5.6-luna'; effort = 'medium' }
}
$agentsJson = $agents | ConvertTo-Json -Depth 10 -Compress
$capacityGuard = "Claudex capacity rule: keep at most $agentConcurrencyNumber Agent tasks active at once. Launch no more than $agentConcurrencyNumber agents in a wave, wait for one to finish before starting another, and never create an agent team. Sol capacity is reserved for the leader; use the configured Terra or Luna agents for delegated work. If a model reports a 429 or cooldown, do not launch replacement agents or create a retry storm; continue useful local work and retry at most once after active agents settle."
$taskGuard = 'Claudex task lifecycle rule: the Sol leader is the sole owner of the shared task list. Keep it compact and create only tasks that represent real remaining deliverables, not duplicate discovery lanes or speculative work. Mark a task in_progress only while the leader or a currently active agent is working on it; queued or blocked work stays pending. After every agent result, immediately reconcile its parent task and mark it completed once its outcome is integrated and verified. Before every final answer, call TaskList and reconcile every entry: completed work must be completed, inactive work must not remain in_progress, and genuinely unfinished pending work must be explicitly reported instead of being hidden behind a completion claim. Never leave stale in_progress tasks after their work is done.'
$leaderGuard = $capacityGuard + [Environment]::NewLine + [Environment]::NewLine + $taskGuard

$startModel = ''
$launchPermissionMode = $permissionMode
$forwardArguments = New-Object 'System.Collections.Generic.List[string]'
$index = 0
while ($index -lt $ClaudeArguments.Count) {
    $argument = $ClaudeArguments[$index]
    $recognized = $true
    switch ($argument) {
        '--sol' { $startModel = 'gpt-5.6-sol' }
        '--terra' { $startModel = 'gpt-5.6-terra' }
        '--luna' { $startModel = 'gpt-5.6-luna' }
        '--manual' { $launchPermissionMode = 'manual' }
        '--auto' { $launchPermissionMode = 'auto' }
        '--accept-edits' { $launchPermissionMode = 'acceptEdits' }
        '--' { $index++; $recognized = $false }
        default { $recognized = $false }
    }
    if (-not $recognized) { break }
    $index++
}
while ($index -lt $ClaudeArguments.Count) { $forwardArguments.Add($ClaudeArguments[$index]); $index++ }

$claudeLaunchArguments = New-Object 'System.Collections.Generic.List[string]'
foreach ($value in @('--agents', $agentsJson, '--append-system-prompt', $leaderGuard, '--permission-mode', $launchPermissionMode)) {
    $claudeLaunchArguments.Add($value)
}
if ($settingsFile -ne (Join-Path $configDir 'settings.json')) {
    $claudeLaunchArguments.Add('--settings'); $claudeLaunchArguments.Add($settingsFile)
}
if ($startModel) { $claudeLaunchArguments.Add('--model'); $claudeLaunchArguments.Add($startModel) }
foreach ($value in $forwardArguments) { $claudeLaunchArguments.Add($value) }

function Set-MousePointer([string] $Shape) {
    if ($mousePointer -eq 'off' -or [Console]::IsOutputRedirected) { return }
    [Console]::Out.Write("$([char]27)]22;$Shape$([char]27)\")
}

try {
    Set-MousePointer $mousePointer
    & claude @claudeLaunchArguments
    $exitCode = $LASTEXITCODE
} finally {
    Set-MousePointer 'default'
}
exit $exitCode
