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
}

if (-not $contextPercent -or $contextPercent -eq '0') {
    if ($totalInputTokens -gt 0 -and $contextWindowSize -gt 0) {
        $computed = [math]::Floor(($totalInputTokens * 100.0) / $contextWindowSize)
        $contextPercent = if ($computed -gt 0) { [string] $computed } else { '<1' }
    } else {
        $contextPercent = $null
    }
}

if ($sessionId -match '^[A-Za-z0-9._-]+$') {
    $cacheDir = Join-Path $configDir 'statusline-cache'
    $cacheFile = Join-Path $cacheDir $sessionId
    if ($contextPercent) {
        try {
            [IO.Directory]::CreateDirectory($cacheDir) | Out-Null
            $temporaryCache = Join-Path $cacheDir ('.context.tmp.' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($temporaryCache, "$contextPercent`n", $utf8)
            Move-Item -LiteralPath $temporaryCache -Destination $cacheFile -Force
        } catch { }
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
        $refreshLock = Join-Path $usageCacheDir 'refresh.lock'
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $lastAttempt = 0L
        if (Test-Path -LiteralPath $lastAttemptPath -PathType Leaf) { [long]::TryParse(([IO.File]::ReadAllText($lastAttemptPath).Trim()), [ref] $lastAttempt) | Out-Null }
        if ($now - $lastAttempt -ge $refreshSeconds) {
            [IO.Directory]::CreateDirectory($usageCacheDir) | Out-Null
            $started = $false
            try {
                New-Item -Path $refreshLock -ItemType Directory -ErrorAction Stop | Out-Null
                [IO.File]::WriteAllText($lastAttemptPath, "$now`n", $utf8)
                $powershell = (Get-Process -Id $PID).Path
                $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $usageHelper + '"'), '-RefreshCache', '-LockHeld')
                Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden | Out-Null
                $started = $true
            } catch {
                if (-not $started -and $now - $lastAttempt -ge ($refreshSeconds * 2) -and (Test-Path -LiteralPath $refreshLock -PathType Container)) {
                    Remove-Item -LiteralPath $refreshLock -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $lastSuccess = 0L
        if (Test-Path -LiteralPath $lastSuccessPath -PathType Leaf) { [long]::TryParse(([IO.File]::ReadAllText($lastSuccessPath).Trim()), [ref] $lastSuccess) | Out-Null }
        if ($now - $lastSuccess -le $maxStaleSeconds -and (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
            $usageSummary = [IO.File]::ReadAllText($summaryPath).Trim()
        }
    } catch { $usageSummary = '' }
}

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

$escape = [char] 27
$separator = [char] 0x00B7
$title = "${escape}]0;Claudex $separator $modelName $separator $effort effort$([char]7)"
$line = "${escape}[38;5;81mClaudex${escape}[0m $separator ${escape}[1m$modelName${escape}[0m $separator $effort effort"
if ($null -ne $contextPercent) { $line += " $separator $contextPercent% context" }
if ($usageSummary) { $line += " $separator $usageSummary" }
Write-Output ($title + $line)
