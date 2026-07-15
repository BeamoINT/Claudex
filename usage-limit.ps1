param(
    [switch] $Cached,
    [switch] $Json,
    [switch] $Statusline,
    [switch] $RefreshCache,
    [switch] $LockHeld,
    [switch] $NoColor,
    [switch] $Accounts,
    [string] $Account
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$utf8 = New-Object Text.UTF8Encoding($false)
$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$cacheDir = Join-Path $configDir 'usage-cache'
$cacheFile = Join-Path $cacheDir 'limits.json'
$summaryFile = Join-Path $cacheDir 'summary'
$lastAttemptFile = Join-Path $cacheDir 'last-attempt'
$lastSuccessFile = Join-Path $cacheDir 'last-success'
$refreshLock = Join-Path $cacheDir 'refresh.lock'
$accountSelectionFile = Join-Path $configDir 'codex-usage-account'
$curlCommand = if ($env:CLAUDEX_CURL_BIN) { $env:CLAUDEX_CURL_BIN } else { 'curl.exe' }
$usageUrl = if ($env:CLAUDEX_USAGE_URL) { $env:CLAUDEX_USAGE_URL } else { 'https://chatgpt.com/backend-api/wham/usage' }

function Get-IntegerSetting([string] $Name, [int] $Default, [int] $Minimum, [int] $Maximum) {
    $raw = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $raw) { return $Default }
    $number = 0
    if (-not [int]::TryParse($raw, [ref] $number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Name must be an integer from $Minimum to $Maximum."
    }
    return $number
}

$refreshSeconds = Get-IntegerSetting 'CLAUDEX_USAGE_REFRESH_SECONDS' 300 60 3600
$timeoutSeconds = Get-IntegerSetting 'CLAUDEX_USAGE_TIMEOUT_SECONDS' 8 1 30
$maxStaleSeconds = Get-IntegerSetting 'CLAUDEX_USAGE_MAX_STALE_SECONDS' 86400 $refreshSeconds 604800
$alertPercent = Get-IntegerSetting 'CLAUDEX_USAGE_ALERT_PERCENT' 20 0 100
$usageSource = if ($env:CLAUDEX_USAGE_SOURCE) { $env:CLAUDEX_USAGE_SOURCE } else { 'auto' }
if ($usageSource -notin @('auto', 'web', 'app-server')) { throw 'CLAUDEX_USAGE_SOURCE must be auto, web, or app-server.' }

function Get-Property($Object, [string] $Name, $Default = $null) {
    if ($Object -is [Collections.IDictionary]) {
        if (-not $Object.Contains($Name) -or $null -eq $Object[$Name]) { return $Default }
        return $Object[$Name]
    }
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function Get-ProxyAuthDirectory {
    if ($env:CLAUDEX_CODEX_AUTH_DIR) { return $env:CLAUDEX_CODEX_AUTH_DIR }
    $proxyConfig = if ($env:CLAUDEX_PROXY_CONFIG) { $env:CLAUDEX_PROXY_CONFIG } else { Join-Path $configDir 'cliproxyapi.yaml' }
    if (Test-Path -LiteralPath $proxyConfig -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($proxyConfig)) {
            if ($line -match '^\s*auth-dir:\s*["'']?(.+?)["'']?\s*$') { return $Matches[1] }
        }
    }
    return (Join-Path $env:USERPROFILE '.cli-proxy-api')
}

function Find-CodexAuthFile {
    if ($env:CLAUDEX_CODEX_AUTH_FILE) {
        if (-not (Test-Path -LiteralPath $env:CLAUDEX_CODEX_AUTH_FILE -PathType Leaf)) { throw 'CLAUDEX_CODEX_AUTH_FILE does not exist.' }
        return $env:CLAUDEX_CODEX_AUTH_FILE
    }
    $authDir = Get-ProxyAuthDirectory
    if (-not (Test-Path -LiteralPath $authDir -PathType Container)) { throw 'CLIProxyAPI Codex OAuth directory was not found.' }
    if (Test-Path -LiteralPath $accountSelectionFile -PathType Leaf) {
        $selectedName = [IO.File]::ReadAllText($accountSelectionFile).Trim()
        if (-not $selectedName -or $selectedName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $selectedName.Contains('/') -or $selectedName.Contains('\')) {
            throw 'the saved Codex usage account selection is invalid.'
        }
        $selectedPath = Join-Path $authDir $selectedName
        if (-not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) { throw 'the selected Codex usage account no longer exists.' }
        $selected = Get-Content -LiteralPath $selectedPath -Raw | ConvertFrom-Json
        if ((Get-Property $selected 'type' '') -ne 'codex' -or -not (Get-Property $selected 'access_token' '')) { throw 'the selected Codex usage account is invalid.' }
        return $selectedPath
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $authDir -File -Filter 'codex*.json' | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $candidate = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ((Get-Property $candidate 'type' '') -eq 'codex' -and (Get-Property $candidate 'access_token' '')) { return $file.FullName }
        } catch { }
    }
    throw 'no CLIProxyAPI Codex OAuth credential was found; run the installer with -Login.'
}

function Get-CodexAuthFiles {
    $authDir = Get-ProxyAuthDirectory
    if (-not (Test-Path -LiteralPath $authDir -PathType Container)) { throw 'CLIProxyAPI Codex OAuth directory was not found.' }
    $valid = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $authDir -File -Filter 'codex*.json' | Sort-Object Name)) {
        try {
            $candidate = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ((Get-Property $candidate 'type' '') -eq 'codex' -and (Get-Property $candidate 'access_token' '')) {
                $valid += [pscustomobject]@{ File = $file; Data = $candidate }
            }
        } catch { }
    }
    return @($valid)
}

function Show-CodexAccounts {
    $files = @(Get-CodexAuthFiles)
    if ($files.Count -eq 0) { throw 'no CLIProxyAPI Codex OAuth credentials were found.' }
    $active = try { Find-CodexAuthFile } catch { '' }
    Write-Output 'Codex usage accounts:'
    for ($index = 0; $index -lt $files.Count; $index++) {
        $entry = $files[$index]
        $marker = if ($entry.File.FullName -eq $active) { '*' } else { ' ' }
        $email = [string] (Get-Property $entry.Data 'email' 'unknown account')
        $suffix = if ([bool] (Get-Property $entry.Data 'disabled' $false)) { ' (disabled)' } else { '' }
        Write-Output "[$marker] $($index + 1). $email$suffix"
    }
    Write-Output 'Select one with: claudex --account <number|email|filename>; use auto to follow the newest credential.'
}

function Select-CodexAccount([string] $Selector) {
    if ($Selector -eq 'auto') {
        Remove-Item -LiteralPath $accountSelectionFile -Force -ErrorAction SilentlyContinue
        Write-Output 'Codex usage account selection: automatic (newest refreshed credential).'
        return
    }
    $files = @(Get-CodexAuthFiles)
    $selected = $null
    for ($index = 0; $index -lt $files.Count; $index++) {
        $entry = $files[$index]
        $email = [string] (Get-Property $entry.Data 'email' '')
        if ($Selector -eq [string] ($index + 1) -or $Selector -eq $email -or $Selector -eq $entry.File.Name) { $selected = $entry; break }
    }
    if ($null -eq $selected) { throw "no Codex account matched '$Selector'. Run: claudex --accounts" }
    Write-AtomicText $accountSelectionFile ($selected.File.Name + "`n")
    Write-Output "Selected Codex usage account: $([string] (Get-Property $selected.Data 'email' 'unknown account'))"
}

function Convert-Window($Window) {
    if ($null -eq $Window) { return $null }
    $windowMinutes = [double] (Get-Property $Window 'windowDurationMins' 0)
    return [ordered]@{
        used_percent = [double] (Get-Property $Window 'used_percent' (Get-Property $Window 'usedPercent' 0))
        limit_window_seconds = [long] (Get-Property $Window 'limit_window_seconds' ($windowMinutes * 60))
        reset_after_seconds = [long] (Get-Property $Window 'reset_after_seconds' 0)
        reset_at = [long] (Get-Property $Window 'reset_at' (Get-Property $Window 'resetsAt' 0))
    }
}

function Convert-Limit($Limit) {
    if ($null -eq $Limit) { return $null }
    return [ordered]@{
        allowed = [bool] (Get-Property $Limit 'allowed' $true)
        limit_reached = [bool] (Get-Property $Limit 'limit_reached' $false)
        primary_window = Convert-Window (Get-Property $Limit 'primary_window' (Get-Property $Limit 'primary' $null))
        secondary_window = Convert-Window (Get-Property $Limit 'secondary_window' (Get-Property $Limit 'secondary' $null))
    }
}

function Get-RemainingPercent($Window) {
    $remaining = 100 - [math]::Floor([double] $Window.used_percent)
    return [int] [math]::Max(0, [math]::Min(100, $remaining))
}

function Get-ShortWindowLabel([long] $Seconds) {
    if ($Seconds -gt 0 -and $Seconds % 86400 -eq 0) { return "$([int] ($Seconds / 86400))d" }
    if ($Seconds -gt 0 -and $Seconds % 3600 -eq 0) { return "$([int] ($Seconds / 3600))h" }
    if ($Seconds -gt 0 -and $Seconds % 60 -eq 0) { return "$([int] ($Seconds / 60))m" }
    return "${Seconds}s"
}

function Get-LongWindowLabel([long] $Seconds) {
    if ($Seconds -gt 0 -and $Seconds % 86400 -eq 0) { return "$([int] ($Seconds / 86400))-day" }
    if ($Seconds -gt 0 -and $Seconds % 3600 -eq 0) { return "$([int] ($Seconds / 3600))-hour" }
    if ($Seconds -gt 0 -and $Seconds % 60 -eq 0) { return "$([int] ($Seconds / 60))-minute" }
    return "${Seconds}-second"
}

function Format-Epoch([long] $Epoch) {
    return [DateTimeOffset]::FromUnixTimeSeconds($Epoch).ToLocalTime().ToString('MMM d, h:mm tt')
}

function Get-CompactSummary($Snapshot) {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $remainingValues = New-Object 'System.Collections.Generic.List[int]'
    $limit = Get-Property $Snapshot 'rate_limit' $null
    if ($limit) {
        foreach ($windowName in @('primary_window', 'secondary_window')) {
            $window = Get-Property $limit $windowName $null
            if ($window) {
                $remaining = Get-RemainingPercent $window
                $remainingValues.Add($remaining)
                $parts.Add("$(Get-ShortWindowLabel ([long] $window.limit_window_seconds)) $remaining% left")
            }
        }
    }
    if ($parts.Count -gt 0) {
        $prefix = if ($alertPercent -gt 0 -and ($remainingValues | Measure-Object -Minimum).Minimum -le $alertPercent) { '⚠ Codex ' } else { 'Codex ' }
        return $prefix + ($parts -join ' · ')
    }
    if ($limit -and [bool] (Get-Property $limit 'limit_reached' $false)) { return 'Codex limit reached' }
    if (Get-Property $Snapshot 'rate_limit_reached_type' $null) { return 'Codex limit reached' }
    return ''
}

function Write-AtomicText([string] $Path, [string] $Content) {
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $temporary = Join-Path (Split-Path $Path -Parent) ('.tmp.' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $Content, $utf8)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-WebUsageResponse {
    $authFile = Find-CodexAuthFile
    $auth = Get-Content -LiteralPath $authFile -Raw | ConvertFrom-Json
    $token = [string] (Get-Property $auth 'access_token' '')
    $account = [string] (Get-Property $auth 'account_id' '')
    if (-not $token) { throw 'the Codex OAuth credential has no access token.' }
    if ($token.Contains("`r") -or $token.Contains("`n") -or $token.Contains('"') -or
        $account.Contains("`r") -or $account.Contains("`n") -or $account.Contains('"')) {
        throw 'the Codex credential contains unsupported characters.'
    }

    $curlConfig = Join-Path $cacheDir ('.curl.tmp.' + [guid]::NewGuid().ToString('N'))
    try {
        $configLines = @("header = `"Authorization: Bearer $token`"")
        if ($account) { $configLines += "header = `"ChatGPT-Account-Id: $account`"" }
        $configLines += 'header = "Accept: application/json"'
        [IO.File]::WriteAllLines($curlConfig, $configLines, $utf8)
        $output = @(& $curlCommand --silent --show-error --fail --connect-timeout 3 --max-time $timeoutSeconds --config $curlConfig $usageUrl 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'OpenAI usage refresh failed.' }
        $raw = $output -join "`n"
    } finally {
        if (Test-Path -LiteralPath $curlConfig) { Remove-Item -LiteralPath $curlConfig -Force }
    }

    try { return ($raw | ConvertFrom-Json) } catch { throw 'OpenAI returned an unrecognized usage response.' }
}

function Read-AppServerResponse($Process, [int] $Id) {
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [math]::Max(1, [int] ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $readTask = $Process.StandardOutput.ReadLineAsync()
        $delayTask = [Threading.Tasks.Task]::Delay($remaining)
        $completed = [Threading.Tasks.Task]::WhenAny($readTask, $delayTask).GetAwaiter().GetResult()
        if (-not [object]::ReferenceEquals($completed, $readTask)) { throw 'Codex app-server response timed out.' }
        $line = $readTask.GetAwaiter().GetResult()
        if ($null -eq $line) { throw 'Codex app-server closed before returning rate limits.' }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ([int] (Get-Property $message 'id' -1) -eq $Id) {
            $result = Get-Property $message 'result' $null
            if ($null -eq $result) { throw "Codex app-server request $Id failed." }
            return $result
        }
    }
    throw 'Codex app-server response timed out.'
}

function Get-AppServerUsageResponse {
    if ($env:CLAUDEX_CODEX_AUTH_FILE -or (Test-Path -LiteralPath $accountSelectionFile -PathType Leaf)) {
        throw 'app-server fallback is disabled while an explicit usage account is selected.'
    }
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) { throw 'Codex CLI is unavailable for the app-server fallback.' }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $codex.Source
    $startInfo.Arguments = 'app-server'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'could not start Codex app-server.' }
        $process.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"Claudex","title":"Claudex usage fallback","version":"1.0.0"}}}')
        $process.StandardInput.Flush()
        Read-AppServerResponse $process 1 | Out-Null
        $process.StandardInput.WriteLine('{"method":"initialized"}')
        $process.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read","params":null}')
        $process.StandardInput.Flush()
        return (Read-AppServerResponse $process 2)
    } finally {
        try { $process.StandardInput.Close() } catch { }
        if (-not $process.HasExited) { try { $process.Kill() } catch { } }
        $process.Dispose()
    }
}

function Refresh-UsageCache {
    [IO.Directory]::CreateDirectory($cacheDir) | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-AtomicText $lastAttemptFile "$now`n"
    $source = ''
    if ($usageSource -eq 'web') {
        $response = Get-WebUsageResponse
        $source = 'web'
    } elseif ($usageSource -eq 'app-server') {
        $response = Get-AppServerUsageResponse
        $source = 'app-server'
    } else {
        try {
            $response = Get-WebUsageResponse
            $candidateLimit = Convert-Limit (Get-Property $response 'rate_limit' $null)
            if ($null -eq $candidateLimit -or ($null -eq $candidateLimit.primary_window -and $null -eq $candidateLimit.secondary_window)) {
                throw 'OpenAI returned no recognized Codex rate-limit window.'
            }
            $source = 'web'
        }
        catch { $response = Get-AppServerUsageResponse; $source = 'app-server' }
    }

    $additional = @()
    if ($source -eq 'app-server') {
        $mainSource = Get-Property $response 'rateLimits' $null
        $rateLimit = Convert-Limit $mainSource
        $limitsById = Get-Property $response 'rateLimitsByLimitId' $null
        if ($limitsById) {
            foreach ($property in $limitsById.PSObject.Properties) {
                $entry = $property.Value
                if ((Get-Property $entry 'limitId' '') -eq (Get-Property $mainSource 'limitId' '')) { continue }
                $additional += [ordered]@{
                    limit_name = [string] (Get-Property $entry 'limitName' $property.Name)
                    metered_feature = Get-Property $entry 'limitId' $property.Name
                    rate_limit = Convert-Limit $entry
                }
            }
        }
        $creditsSource = Get-Property $mainSource 'credits' $null
        $credits = if ($creditsSource) {
            [ordered]@{
                has_credits = [bool] (Get-Property $creditsSource 'hasCredits' $false)
                unlimited = [bool] (Get-Property $creditsSource 'unlimited' $false)
                overage_limit_reached = $false
                balance = Get-Property $creditsSource 'balance' $null
            }
        } else { $null }
        $planType = Get-Property $mainSource 'planType' $null
        $codeReviewLimit = $null
        $spendControlReached = $false
        $reachedType = Get-Property $mainSource 'rateLimitReachedType' $null
        $resetCredits = Get-Property (Get-Property $response 'rateLimitResetCredits' $null) 'availableCount' 0
    } else {
        $rateLimit = Convert-Limit (Get-Property $response 'rate_limit' $null)
        foreach ($entry in @(Get-Property $response 'additional_rate_limits' @())) {
            $additional += [ordered]@{
                limit_name = [string] (Get-Property $entry 'limit_name' 'Additional limit')
                metered_feature = Get-Property $entry 'metered_feature' $null
                rate_limit = Convert-Limit (Get-Property $entry 'rate_limit' $null)
            }
        }
        $creditsSource = Get-Property $response 'credits' $null
        $credits = if ($creditsSource) {
            [ordered]@{
                has_credits = [bool] (Get-Property $creditsSource 'has_credits' $false)
                unlimited = [bool] (Get-Property $creditsSource 'unlimited' $false)
                overage_limit_reached = [bool] (Get-Property $creditsSource 'overage_limit_reached' $false)
                balance = Get-Property $creditsSource 'balance' $null
            }
        } else { $null }
        $planType = Get-Property $response 'plan_type' $null
        $codeReviewLimit = Convert-Limit (Get-Property $response 'code_review_rate_limit' $null)
        $spendControlReached = [bool] (Get-Property (Get-Property $response 'spend_control' $null) 'reached' $false)
        $reachedType = Get-Property $response 'rate_limit_reached_type' $null
        $resetCredits = Get-Property (Get-Property $response 'rate_limit_reset_credits' $null) 'available_count' 0
    }
    if ($null -eq $rateLimit -or ($null -eq $rateLimit.primary_window -and $null -eq $rateLimit.secondary_window)) {
        throw 'OpenAI returned no Codex rate-limit window.'
    }
    $snapshot = [ordered]@{
        version = 1
        fetched_at = $now
        source = $source
        plan_type = $planType
        rate_limit = $rateLimit
        code_review_rate_limit = $codeReviewLimit
        additional_rate_limits = $additional
        credits = $credits
        spend_control_reached = $spendControlReached
        rate_limit_reached_type = $reachedType
        reset_credits_available = [int] $resetCredits
    }
    Write-AtomicText $cacheFile (($snapshot | ConvertTo-Json -Depth 20 -Compress) + "`n")
    Write-AtomicText $summaryFile ((Get-CompactSummary $snapshot) + "`n")
    Write-AtomicText $lastSuccessFile "$now`n"
}

function Read-Snapshot {
    if (-not (Test-Path -LiteralPath $cacheFile -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-LimitRows([string] $Name, $Limit) {
    if ($null -eq $Limit) { return }
    foreach ($windowName in @('primary_window', 'secondary_window')) {
        $window = Get-Property $Limit $windowName $null
        if ($null -eq $window) { continue }
        $used = [int] [math]::Floor([double] $window.used_percent)
        $reset = if ([long] $window.reset_at -gt 0) { " · resets $(Format-Epoch ([long] $window.reset_at))" } else { '' }
        Write-Output "$Name $(Get-LongWindowLabel ([long] $window.limit_window_seconds)): $(Get-RemainingPercent $window)% remaining ($used% used)$reset"
    }
}

function Write-Detail($Snapshot) {
    $plan = [string] (Get-Property $Snapshot 'plan_type' 'unknown')
    if ($plan.Length -gt 0) { $plan = $plan.Substring(0, 1).ToUpperInvariant() + $plan.Substring(1) }
    Write-Output "Codex usage limits ($plan plan)"
    Write-LimitRows 'Codex' (Get-Property $Snapshot 'rate_limit' $null)
    Write-LimitRows 'Code review' (Get-Property $Snapshot 'code_review_rate_limit' $null)
    foreach ($entry in @(Get-Property $Snapshot 'additional_rate_limits' @())) {
        Write-LimitRows ([string] $entry.limit_name) (Get-Property $entry 'rate_limit' $null)
    }
    $remainingValues = @()
    $mainForAlert = Get-Property $Snapshot 'rate_limit' $null
    if ($mainForAlert) {
        foreach ($windowName in @('primary_window', 'secondary_window')) {
            $window = Get-Property $mainForAlert $windowName $null
            if ($window) { $remainingValues += Get-RemainingPercent $window }
        }
    }
    if ($alertPercent -gt 0 -and $remainingValues.Count -gt 0 -and ($remainingValues | Measure-Object -Minimum).Minimum -le $alertPercent) {
        Write-Output "Warning: Codex capacity is at or below the configured $alertPercent% alert threshold."
    }
    $resetCredits = [int] (Get-Property $Snapshot 'reset_credits_available' 0)
    if ($resetCredits -gt 0) { Write-Output "Rate-limit reset credits: $resetCredits" }
    $mainLimit = Get-Property $Snapshot 'rate_limit' $null
    if (($mainLimit -and [bool] (Get-Property $mainLimit 'limit_reached' $false)) -or (Get-Property $Snapshot 'rate_limit_reached_type' $null)) {
        Write-Output 'Status: usage limit reached'
    }
    $fetched = [long] (Get-Property $Snapshot 'fetched_at' 0)
    if ($fetched -gt 0) { Write-Output "Updated: $(Format-Epoch $fetched)" }
    Write-Output "Source: $([string] (Get-Property $Snapshot 'source' 'web'))"
}

$accountMode = $Accounts -or -not [string]::IsNullOrWhiteSpace($Account)
if ($Accounts) { Show-CodexAccounts; exit 0 }
if (-not [string]::IsNullOrWhiteSpace($Account)) { Select-CodexAccount $Account; exit 0 }

$refreshFailed = $false
try {
    if (-not $Cached -and -not $Statusline) { Refresh-UsageCache }
} catch {
    $refreshFailed = $true
    if ($RefreshCache) { [Console]::Error.WriteLine("usage-limit: $($_.Exception.Message)") }
} finally {
    if ($LockHeld -and (Test-Path -LiteralPath $refreshLock -PathType Container)) {
        Remove-Item -LiteralPath $refreshLock -Force -ErrorAction SilentlyContinue
    }
}

if ($RefreshCache) { if ($refreshFailed) { exit 1 } else { exit 0 } }
$snapshot = Read-Snapshot
if ($null -eq $snapshot) {
    if ($refreshFailed) { [Console]::Error.WriteLine('usage-limit: live refresh failed and no cached snapshot is available.') }
    else { [Console]::Error.WriteLine('usage-limit: no cached usage snapshot is available.') }
    exit 1
}
if ($refreshFailed) { [Console]::Error.WriteLine('usage-limit: live refresh failed; showing the last cached snapshot.') }

if ($Json) {
    Get-Content -LiteralPath $cacheFile -Raw
} elseif ($Statusline) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lastSuccess = 0L
    if (Test-Path -LiteralPath $lastSuccessFile -PathType Leaf) { [long]::TryParse(([IO.File]::ReadAllText($lastSuccessFile).Trim()), [ref] $lastSuccess) | Out-Null }
    if ($now - $lastSuccess -le $maxStaleSeconds) { Write-Output (Get-CompactSummary $snapshot) }
} else {
    Write-Detail $snapshot
}
exit 0
