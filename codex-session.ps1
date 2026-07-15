param(
    [ValidateSet('sync', 'watch', 'login', 'logout', 'status')]
    [string] $Action = 'sync',
    [int] $ParentProcessId = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$codexAuthFile = if ($env:CLAUDEX_CODEX_SOURCE_AUTH_FILE) { $env:CLAUDEX_CODEX_SOURCE_AUTH_FILE } else { Join-Path $codexHome 'auth.json' }
$bridgeAuthDir = if ($env:CLAUDEX_CODEX_AUTH_DIR) { $env:CLAUDEX_CODEX_AUTH_DIR } else { Join-Path $configDir 'codex-accounts' }
$bridgeAuthFile = Join-Path $bridgeAuthDir 'codex-claudex-managed.json'
$usageCacheDir = Join-Path $configDir 'usage-cache'
$usageAccountFile = Join-Path $configDir 'codex-usage-account'
$utf8 = New-Object Text.UTF8Encoding($false)

function Write-Failure([string] $Message) {
    [Console]::Error.WriteLine("claudex: $Message")
}

function Clear-BridgeSession {
    Remove-Item -LiteralPath $bridgeAuthFile -Force -ErrorAction SilentlyContinue
}

function Clear-AccountScopedState {
    Remove-Item -LiteralPath $usageAccountFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $usageCacheDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-CodexLogin {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) { return $false }
    & $codex.Source login status *> $null
    return $LASTEXITCODE -eq 0
}

function Sync-Session {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        Clear-BridgeSession
        Write-Failure 'Codex CLI was not found. Install Codex, run `codex login`, and retry.'
        return 10
    }
    if (-not (Test-CodexLogin)) {
        Clear-BridgeSession
        Write-Failure 'Codex is logged out. Run `codex login` (or `claudex --login`) and retry.'
        return 11
    }
    if (-not (Test-Path -LiteralPath $codexAuthFile -PathType Leaf)) {
        Clear-BridgeSession
        Write-Failure 'Codex is logged in, but its credentials are stored in the OS keyring.'
        Write-Failure 'Run `claudex --login` once so Codex can create a reusable file-backed local session.'
        return 13
    }
    try { $source = Get-Content -LiteralPath $codexAuthFile -Raw | ConvertFrom-Json } catch {
        Clear-BridgeSession
        Write-Failure 'Codex auth.json is not valid JSON. Run `claudex --login` to repair the session.'
        return 14
    }
    $tokens = $source.tokens
    if ($source.auth_mode -ne 'chatgpt' -or -not $tokens -or
        [string]::IsNullOrWhiteSpace([string] $tokens.access_token) -or
        [string]::IsNullOrWhiteSpace([string] $tokens.refresh_token) -or
        [string]::IsNullOrWhiteSpace([string] $tokens.account_id)) {
        Clear-BridgeSession
        Write-Failure 'Claudex requires Codex ChatGPT sign-in. Run `claudex --login` and choose ChatGPT.'
        return 14
    }

    [IO.Directory]::CreateDirectory($bridgeAuthDir) | Out-Null
    $previousAccount = ''
    $shouldWrite = $true
    if (Test-Path -LiteralPath $bridgeAuthFile -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $bridgeAuthFile -Raw | ConvertFrom-Json
            $previousAccount = [string] $existing.account_id
            $existingRefresh = [string] $existing.last_refresh
            $sourceRefresh = [string] $source.last_refresh
            $existingDisabled = $null -ne $existing.PSObject.Properties['disabled'] -and [bool] $existing.disabled
            $existingExpired = $null -ne $existing.PSObject.Properties['expired'] -and [bool] $existing.expired
            if ($existing.type -eq 'codex' -and $existing.access_token -and
                $existing.account_id -eq $tokens.account_id -and
                $existing.access_token -eq $tokens.access_token -and
                $existing.refresh_token -eq $tokens.refresh_token -and
                ([string] $existing.id_token) -eq ([string] $tokens.id_token) -and
                -not $existingDisabled -and -not $existingExpired -and
                [string]::CompareOrdinal($existingRefresh, $sourceRefresh) -ge 0) {
                $shouldWrite = $false
            }
        } catch { $shouldWrite = $true }
    }
    if ($shouldWrite) {
        $candidate = [ordered]@{
            type = 'codex'
            access_token = [string] $tokens.access_token
            refresh_token = [string] $tokens.refresh_token
            id_token = [string] $tokens.id_token
            account_id = [string] $tokens.account_id
            last_refresh = [string] $source.last_refresh
            disabled = $false
            expired = $false
        }
        $temporary = Join-Path $bridgeAuthDir ('.codex-session-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, (($candidate | ConvertTo-Json -Compress) + "`n"), $utf8)
        if ($previousAccount -and $previousAccount -ne [string] $tokens.account_id) {
            Clear-AccountScopedState
        }
        Move-Item -LiteralPath $temporary -Destination $bridgeAuthFile -Force
    }
    return 0
}

function Get-AuthFingerprint {
    if (-not (Test-Path -LiteralPath $codexAuthFile -PathType Leaf)) { return 'missing' }
    try { return (Get-FileHash -LiteralPath $codexAuthFile -Algorithm SHA256).Hash }
    catch { return 'unreadable' }
}

function Watch-Session {
    if ($ParentProcessId -le 1) { Write-Failure 'watch requires a valid parent process ID.'; return 2 }
    $interval = 2
    if ($env:CLAUDEX_AUTH_WATCH_SECONDS) {
        if (-not [int]::TryParse($env:CLAUDEX_AUTH_WATCH_SECONDS, [ref] $interval) -or $interval -lt 1 -or $interval -gt 60) {
            Write-Failure 'CLAUDEX_AUTH_WATCH_SECONDS must be an integer from 1 to 60.'
            return 2
        }
    }
    $fingerprint = Get-AuthFingerprint
    if ($env:CLAUDEX_AUTH_WATCH_READY_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_AUTH_WATCH_READY_FILE, "ready`n", $utf8)
    }
    while (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds $interval
        $next = Get-AuthFingerprint
        if ($next -eq $fingerprint) { continue }
        try {
            $result = Sync-Session
            if ($result -eq 0 -or $next -eq 'missing') { $fingerprint = $next }
        } catch {
            if ($next -eq 'missing') { $fingerprint = $next }
        }
    }
    return 0
}

switch ($Action) {
    'watch' {
        $result = Watch-Session
        exit $result
    }
    'login' {
        $codex = Get-Command codex -ErrorAction SilentlyContinue
        if (-not $codex) { Write-Failure 'Codex CLI was not found. Install Codex and retry.'; exit 10 }
        Write-Output 'Claudex is opening the official Codex sign-in flow...'
        & $codex.Source '-c' 'cli_auth_credentials_store="file"' 'login'
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        $result = Sync-Session
        if ($result -ne 0) { exit $result }
        Write-Output 'Codex authentication is ready for Claudex.'
    }
    'logout' {
        $codex = Get-Command codex -ErrorAction SilentlyContinue
        if ($codex) { & $codex.Source logout; $exitCode = $LASTEXITCODE } else { $exitCode = 10 }
        Clear-BridgeSession
        if ($exitCode -ne 0) {
            if ($codex) { Write-Failure 'Codex logout failed, but the local Claudex bridge session was cleared.' }
            else { Write-Failure 'Codex CLI was not found; the local Claudex bridge session was cleared.' }
            exit $exitCode
        }
        Write-Output 'Codex and Claudex are logged out.'
    }
    'status' {
        $result = Sync-Session
        if ($result -ne 0) { exit $result }
        Write-Output 'Codex authentication: ready (shared ChatGPT session)'
        Write-Output "Credential source: $codexAuthFile"
        Write-Output 'Credential handling: local synchronization only; secrets are never printed or committed'
    }
    default {
        $result = Sync-Session
        if ($result -ne 0) { exit $result }
    }
}
