$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) {
    $pipelineInput = @($input)
    if ($pipelineInput.Count -gt 0) { $raw = $pipelineInput -join "`n" }
}
$data = $null
try { $data = $raw | ConvertFrom-Json } catch { $data = $null }

$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$modelId = ''
$displayName = ''
$effort = ''
$contextPercent = $null
$sessionId = ''
$totalInputTokens = 0
$contextWindowSize = 0
$inputColumns = 0
$sessionPersistenceEnabled = $env:CLAUDEX_NO_SESSION_PERSISTENCE -ne '1'

function ConvertTo-TerminalSafeText([AllowNull()][string] $Value) {
    if ($null -eq $Value) { return '' }
    # Remove string-carrying protocols first so their payloads cannot become
    # visible spoofing text, then neutralize CSI, C0/C1, and bidi formatting.
    $safe = [regex]::Replace($Value, '(?:\x1B\]|\u009D)[^\x07\x1B\u009C]*(?:\x07|\x1B\\|\u009C)?', '')
    $safe = [regex]::Replace($safe, '(?:\x1B\[|\u009B)[0-?]*[ -/]*[@-~]', '')
    $safe = [regex]::Replace($safe, '(?:\x1B[P_^X]|[\u0090\u0098\u009E\u009F])[^\x1B\u009C]*(?:\x1B\\|\u009C)?', '')
    $safe = [regex]::Replace($safe, '\x1B.', '')
    return [regex]::Replace($safe, '[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]', '')
}

function ConvertTo-TerminalSafeLabel([AllowNull()][string] $Value) {
    if ($null -eq $Value) { return '' }
    # Model and effort fields are semantic labels rather than free-form text.
    # Keep only the prefix before the first terminal control or bidi formatter;
    # otherwise text following a removed protocol could join or spoof a label.
    # This script applies its owned SGR only after the label crosses this bound.
    $unsafe = [regex]::Match($Value, '[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]')
    if ($unsafe.Success) { return $Value.Substring(0, $unsafe.Index) }
    return $Value
}

function Start-UsageRefreshWithoutPrivateEnvironment([hashtable] $Parameters) {
    $privateNames = @(
        'CLAUDEX_PROXY_TOKEN', 'CLAUDEX_PROXY_URL', 'CLAUDEX_PROXY_CONFIG', 'CLAUDEX_PROXY_BIN',
        'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK',
        'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_BEDROCK_BASE_URL',
        'ANTHROPIC_BEDROCK_MANTLE_BASE_URL', 'ANTHROPIC_VERTEX_BASE_URL', 'ANTHROPIC_VERTEX_PROJECT_ID',
        'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_FOUNDRY_RESOURCE', 'ANTHROPIC_FOUNDRY_API_KEY', 'ANTHROPIC_API_KEY',
        'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_CUSTOM_HEADERS', 'ANTHROPIC_MODEL',
        'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION',
        'ANTHROPIC_CUSTOM_MODEL_OPTION', 'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME',
        'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION'
    )
    $saved = @{}
    foreach ($name in $privateNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    try { return Start-Process @Parameters }
    finally {
        foreach ($name in $saved.Keys) {
            $value = $saved[$name]
            if ($null -eq $value) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, [string] $value, 'Process') }
        }
    }
}

function Remove-StaleStatuslineCache([string] $CacheDirectory, [string] $ProtectedFile) {
    if (-not (Test-Path -LiteralPath $CacheDirectory -PathType Container)) { return }
    $cutoff = [DateTime]::UtcNow.AddDays(-7)
    $files = @(Get-ChildItem -LiteralPath $CacheDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Za-z0-9._-]+$' -and $_.Name -notlike '.context.tmp.*' })
    foreach ($file in @($files | Where-Object { $_.LastWriteTimeUtc -lt $cutoff -and $_.FullName -ne $ProtectedFile })) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
    $survivors = @(Get-ChildItem -LiteralPath $CacheDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Za-z0-9._-]+$' -and $_.Name -notlike '.context.tmp.*' } |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($file in @($survivors | Where-Object { $_.FullName -ne $ProtectedFile } | Select-Object -Skip 127)) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

if ($data) {
    if ($null -ne $data.PSObject.Properties['model'] -and $data.model) {
        if ($null -ne $data.model.PSObject.Properties['id']) { $modelId = [string] $data.model.id }
        if ($null -ne $data.model.PSObject.Properties['display_name']) { $displayName = [string] $data.model.display_name }
    }
    if ($null -ne $data.PSObject.Properties['effort'] -and $data.effort -and $null -ne $data.effort.PSObject.Properties['level']) { $effort = [string] $data.effort.level }
    if ($null -ne $data.PSObject.Properties['context_window'] -and $data.context_window -and $null -ne $data.context_window.PSObject.Properties['used_percentage'] -and $null -ne $data.context_window.used_percentage) {
        $contextPercent = [string] [math]::Floor([double] $data.context_window.used_percentage)
    }
    if ($null -ne $data.PSObject.Properties['session_id']) { $sessionId = [string] $data.session_id }
    if ($null -ne $data.PSObject.Properties['context_window'] -and $data.context_window) {
        if ($null -ne $data.context_window.PSObject.Properties['total_input_tokens'] -and $null -ne $data.context_window.total_input_tokens) {
            $totalInputTokens = [long] $data.context_window.total_input_tokens
        }
        if ($null -ne $data.context_window.PSObject.Properties['context_window_size'] -and $null -ne $data.context_window.context_window_size) {
            $contextWindowSize = [long] $data.context_window.context_window_size
        }
    }
    if ($null -ne $data.PSObject.Properties['columns']) { [int]::TryParse([string] $data.columns, [ref] $inputColumns) | Out-Null }
}

if (-not $contextPercent -or $contextPercent -eq '0') {
    if ($totalInputTokens -gt 0 -and $contextWindowSize -gt 0) {
        $computed = [math]::Floor(($totalInputTokens * 100.0) / $contextWindowSize)
        $contextPercent = if ($computed -gt 0) { [string] $computed } else { '<1' }
    } else {
        $contextPercent = $null
    }
}

if ($sessionPersistenceEnabled -and $sessionId -match '^[A-Za-z0-9._-]+$') {
    $cacheDir = Join-Path $configDir 'statusline-cache'
    $cacheFile = Join-Path $cacheDir $sessionId
    if ($contextPercent) {
        $temporaryCache = $null
        try {
            [IO.Directory]::CreateDirectory($cacheDir) | Out-Null
            $temporaryCache = Join-Path $cacheDir ('.context.tmp.' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($temporaryCache, "$contextPercent`n", $utf8)
            Move-Item -LiteralPath $temporaryCache -Destination $cacheFile -Force
            $temporaryCache = $null
            Remove-StaleStatuslineCache $cacheDir $cacheFile
        } catch { } finally {
            if ($temporaryCache) { Remove-Item -LiteralPath $temporaryCache -Force -ErrorAction SilentlyContinue }
        }
    } elseif (Test-Path -LiteralPath $cacheFile -PathType Leaf) {
        try {
            $cached = [IO.File]::ReadAllText($cacheFile).Trim()
            if ($cached -match '^([1-9][0-9]{0,2}|<1)$') { $contextPercent = $cached }
        } catch { }
    }
}

if (-not $effort) {
    $effort = if ($env:CLAUDE_CODE_EFFORT_LEVEL) { $env:CLAUDE_CODE_EFFORT_LEVEL } else { $env:CLAUDE_EFFORT }
}
if (-not $effort) {
    $settingsPath = Join-Path $configDir 'settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try { $effort = [string] ((Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).effortLevel) } catch { }
    }
}
if (-not $effort) { $effort = 'adaptive' }
if ($env:CLAUDEX_SESSION_MODE) { $effort = $env:CLAUDEX_SESSION_MODE }
$modelId = ConvertTo-TerminalSafeLabel $modelId
$displayName = ConvertTo-TerminalSafeLabel $displayName
$effort = ConvertTo-TerminalSafeLabel $effort
if (-not $effort) { $effort = 'adaptive' }

$usageSummary = ''
$usageDisplay = if ($env:CLAUDEX_USAGE_DISPLAY) { $env:CLAUDEX_USAGE_DISPLAY } else { 'on' }
$usageHelper = if ($env:CLAUDEX_USAGE_LIMIT_BIN) { $env:CLAUDEX_USAGE_LIMIT_BIN } else { Join-Path $configDir 'usage-limit.ps1' }
if ($usageDisplay -ne 'off' -and (Test-Path -LiteralPath $usageHelper -PathType Leaf)) {
    try {
        $refreshSeconds = 300
        $maxStaleSeconds = 86400
        if ($env:CLAUDEX_USAGE_REFRESH_SECONDS) {
            $candidate = 0
            if ([int]::TryParse($env:CLAUDEX_USAGE_REFRESH_SECONDS, [ref] $candidate) -and $candidate -ge 60 -and $candidate -le 3600) {
                $refreshSeconds = $candidate
            }
        }
        if ($env:CLAUDEX_USAGE_MAX_STALE_SECONDS) {
            $candidate = 0
            if ([int]::TryParse($env:CLAUDEX_USAGE_MAX_STALE_SECONDS, [ref] $candidate) -and $candidate -ge $refreshSeconds -and $candidate -le 604800) {
                $maxStaleSeconds = $candidate
            }
        }
        $usageCacheDir = Join-Path $configDir 'usage-cache'
        $summaryPath = Join-Path $usageCacheDir 'summary'
        $lastAttemptPath = Join-Path $usageCacheDir 'last-attempt'
        $lastSuccessPath = Join-Path $usageCacheDir 'last-success'
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $lastAttempt = 0L
        if (Test-Path -LiteralPath $lastAttemptPath -PathType Leaf) { [long]::TryParse(([IO.File]::ReadAllText($lastAttemptPath).Trim()), [ref] $lastAttempt) | Out-Null }
        if ($now - $lastAttempt -ge $refreshSeconds) {
            [IO.Directory]::CreateDirectory($usageCacheDir) | Out-Null
            [IO.File]::WriteAllText($lastAttemptPath, "$now`n", $utf8)
            # The helper owns the complete generation-safe lock protocol. A
            # losing helper exits quickly without touching the current owner.
            $powershell = (Get-Process -Id $PID).Path
            $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $usageHelper + '"'), '-RefreshCache')
            $refreshParameters = @{
                FilePath = $powershell
                ArgumentList = $arguments
                WindowStyle = 'Hidden'
                PassThru = $true
                RedirectStandardOutput = (Join-Path $usageCacheDir '.status-refresh.stdout.log')
                RedirectStandardError = (Join-Path $usageCacheDir '.status-refresh.stderr.log')
            }
            [void] (Start-UsageRefreshWithoutPrivateEnvironment $refreshParameters)
        }
        $lastSuccess = 0L
        if (Test-Path -LiteralPath $lastSuccessPath -PathType Leaf) { [long]::TryParse(([IO.File]::ReadAllText($lastSuccessPath).Trim()), [ref] $lastSuccess) | Out-Null }
        if ($now - $lastSuccess -le $maxStaleSeconds -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
            $usageSummary = [IO.File]::ReadAllText($summaryPath).Trim()
        }
    } catch { $usageSummary = '' }
}
$usageSummary = ConvertTo-TerminalSafeText $usageSummary

$modelName = switch -Wildcard ($modelId) {
    'gpt-5.6-sol' { 'GPT-5.6 Sol'; break }
    'gpt-5.6-terra' { 'GPT-5.6 Terra'; break }
    'gpt-5.6-luna' { 'GPT-5.6 Luna'; break }
    'claude-fable-*' { 'GPT-5.6 Sol'; break }
    'claude-opus-*' { 'GPT-5.6 Sol'; break }
    'claude-sonnet-*' { 'GPT-5.6 Terra'; break }
    'claude-haiku-*' { 'GPT-5.6 Luna'; break }
    default {
        switch -Wildcard ($displayName) {
            '*Fable*' { 'GPT-5.6 Sol'; break }
            '*Opus*' { 'GPT-5.6 Sol'; break }
            '*Sonnet*' { 'GPT-5.6 Terra'; break }
            '*Haiku*' { 'GPT-5.6 Luna'; break }
            default { if ($modelId) { $modelId } elseif ($displayName) { $displayName } else { 'Unknown model' } }
        }
    }
}
$selectedModelMode = $env:CLAUDEX_MODEL_MODE
if (-not $selectedModelMode) {
    $settingsPath = Join-Path $configDir 'settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $savedModel = [string] ((Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).model)
            if ($savedModel -eq 'opusplan') { $selectedModelMode = 'solplan' }
        } catch { }
    }
}
if ($selectedModelMode -eq 'solplan') { $modelName = 'GPT-5.6 Solplan' }
$modelName = ConvertTo-TerminalSafeLabel $modelName

$statuslineColumns = 0
foreach ($candidate in @($env:CLAUDEX_STATUSLINE_COLUMNS, $inputColumns, $env:COLUMNS)) {
    $parsedColumns = 0
    if ([int]::TryParse([string] $candidate, [ref] $parsedColumns) -and $parsedColumns -gt 0) {
        $statuslineColumns = $parsedColumns
        break
    }
}
if ($statuslineColumns -le 0) {
    try {
        if ([Console]::WindowWidth -gt 0) { $statuslineColumns = [Console]::WindowWidth }
    } catch { $statuslineColumns = 0 }
}

$separator = [char] 0x00B7
$escape = [char] 27
$brandPlain = 'Claudex'
$brandAnsi = "${escape}[38;5;81mClaudex${escape}[0m"
$modelAnsi = "${escape}[1m$modelName${escape}[0m"
$mandatoryPlain = "$brandPlain $separator $modelName"
$mandatoryAnsi = "$brandAnsi $separator $modelAnsi"
$corePlain = "$mandatoryPlain $separator $effort effort"
$coreAnsi = "$mandatoryAnsi $separator $effort effort"
if ($null -ne $contextPercent) {
    $corePlain += " $separator $contextPercent% context"
    $coreAnsi += " $separator $contextPercent% context"
}
$fullPlain = $corePlain
$fullAnsi = $coreAnsi
if ($usageSummary) {
    $fullPlain += " $separator $usageSummary"
    $fullAnsi += " $separator $usageSummary"
}

$renderedPlain = $fullPlain
$renderedAnsi = $fullAnsi
if ($statuslineColumns -gt 0 -and $renderedPlain.Length -gt $statuslineColumns) {
    $renderedPlain = $corePlain
    $renderedAnsi = $coreAnsi
}
if ($statuslineColumns -gt 0 -and $renderedPlain.Length -gt $statuslineColumns -and $null -ne $contextPercent) {
    $renderedPlain = "$mandatoryPlain $separator $contextPercent% context"
    $renderedAnsi = "$mandatoryAnsi $separator $contextPercent% context"
}
if ($statuslineColumns -gt 0 -and $renderedPlain.Length -gt $statuslineColumns) {
    $renderedPlain = $mandatoryPlain
    $renderedAnsi = $mandatoryAnsi
}
if ($statuslineColumns -gt 0 -and $renderedPlain.Length -gt $statuslineColumns) {
    $prefixPlain = "$brandPlain $separator "
    $availableModel = $statuslineColumns - $prefixPlain.Length
    if ($availableModel -ge 2) {
        $shortenedModel = $modelName.Substring(0, [Math]::Min($modelName.Length, $availableModel - 1)) + [char] 0x2026
        $renderedPlain = $prefixPlain + $shortenedModel
        $renderedAnsi = "$brandAnsi $separator ${escape}[1m$shortenedModel${escape}[0m"
    } else {
        $visibleBrandLength = [Math]::Min($brandPlain.Length, $statuslineColumns)
        $renderedPlain = $brandPlain.Substring(0, $visibleBrandLength)
        $renderedAnsi = "${escape}[38;5;81m$renderedPlain${escape}[0m"
    }
}

Write-Output $renderedAnsi
