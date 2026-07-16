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

function Move-StatuslineRefreshLockToQuarantine([string] $CacheDirectory, [string] $LockPath, [string] $ExpectedRecord) {
    $quarantine = Join-Path $CacheDirectory ('.refresh.lock.quarantine.' + $PID + '.' + [guid]::NewGuid().ToString('N'))
    try { Move-Item -LiteralPath $LockPath -Destination $quarantine -ErrorAction Stop } catch { return $false }
    $movedOwnerPath = Join-Path $quarantine 'owner-pid'
    $movedRecord = ''
    if (Test-Path -LiteralPath $movedOwnerPath -PathType Leaf) {
        try { $movedRecord = [IO.File]::ReadAllText($movedOwnerPath).Trim() } catch { $movedRecord = '' }
    }
    if ($movedRecord -eq $ExpectedRecord) {
        Remove-Item -LiteralPath $movedOwnerPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not (Test-Path -LiteralPath $LockPath)) {
        try { Move-Item -LiteralPath $quarantine -Destination $LockPath -ErrorAction Stop } catch { }
    }
    return $false
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

if ($sessionId -match '^[A-Za-z0-9._-]+$') {
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
        $refreshOwnerPath = Join-Path $refreshLock 'owner-pid'
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $lastAttempt = 0L
        if (Test-Path -LiteralPath $lastAttemptPath -PathType Leaf) { [long]::TryParse(([IO.File]::ReadAllText($lastAttemptPath).Trim()), [ref] $lastAttempt) | Out-Null }
        if ($now - $lastAttempt -ge $refreshSeconds) {
            [IO.Directory]::CreateDirectory($usageCacheDir) | Out-Null
            $started = $false
            $ownerTemporary = $null
            try {
                New-Item -Path $refreshLock -ItemType Directory -ErrorAction Stop | Out-Null
                $refreshToken = [guid]::NewGuid().ToString('N')
                [IO.File]::WriteAllText($refreshOwnerPath, "$PID $refreshToken`n", $utf8)
                [IO.File]::WriteAllText($lastAttemptPath, "$now`n", $utf8)
                $powershell = (Get-Process -Id $PID).Path
                $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $usageHelper + '"'), '-RefreshCache', '-LockHeld', '-LockToken', $refreshToken)
                $refreshProcess = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
                $ownerTemporary = Join-Path $refreshLock ('.owner.' + [guid]::NewGuid().ToString('N'))
                [IO.File]::WriteAllText($ownerTemporary, "$($refreshProcess.Id) $refreshToken`n", $utf8)
                $currentRecord = [IO.File]::ReadAllText($refreshOwnerPath).Trim()
                $currentParts = @($currentRecord -split ' ', 2)
                if ($currentParts.Count -eq 2 -and $currentParts[1] -eq $refreshToken) {
                    Move-Item -LiteralPath $ownerTemporary -Destination $refreshOwnerPath -Force
                    $ownerTemporary = $null
                } else {
                    Remove-Item -LiteralPath $ownerTemporary -Force -ErrorAction SilentlyContinue
                    $ownerTemporary = $null
                }
                $started = $true
            } catch {
                if ($ownerTemporary) { Remove-Item -LiteralPath $ownerTemporary -Force -ErrorAction SilentlyContinue }
                if (-not $started -and $now - $lastAttempt -ge ($refreshSeconds * 2) -and (Test-Path -LiteralPath $refreshLock -PathType Container)) {
                    $observedRecord = ''
                    if (Test-Path -LiteralPath $refreshOwnerPath -PathType Leaf) {
                        $observedRecord = [IO.File]::ReadAllText($refreshOwnerPath).Trim()
                    }
                    $ownerParts = @($observedRecord -split ' ', 2)
                    $refreshOwner = 0
                    if ($ownerParts.Count -gt 0) { [int]::TryParse($ownerParts[0], [ref] $refreshOwner) | Out-Null }
                    $ownerIsDead = $refreshOwner -gt 0 -and -not (Get-Process -Id $refreshOwner -ErrorAction SilentlyContinue)
                    $ownerlessIsStale = $false
                    if ($refreshOwner -le 0) {
                        try {
                            $lockAge = ([DateTime]::UtcNow - (Get-Item -LiteralPath $refreshLock).LastWriteTimeUtc).TotalSeconds
                            $ownerlessIsStale = $lockAge -ge 2
                        } catch { $ownerlessIsStale = $false }
                    }
                    if ($ownerIsDead -or $ownerlessIsStale) {
                        $currentRecord = ''
                        if (Test-Path -LiteralPath $refreshOwnerPath -PathType Leaf) {
                            $currentRecord = [IO.File]::ReadAllText($refreshOwnerPath).Trim()
                        }
                        if ($currentRecord -eq $observedRecord) {
                            [void] (Move-StatuslineRefreshLockToQuarantine $usageCacheDir $refreshLock $observedRecord)
                        }
                    }
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
