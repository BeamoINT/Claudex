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
$usageGenerationFile = Join-Path $configDir 'usage-generation'
$sessionSyncLock = Join-Path $bridgeAuthDir '.codex-session-sync.lock'
$utf8 = New-Object Text.UTF8Encoding($false)
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:sessionTemporary = ''
$script:sessionSyncToken = ''
$script:sessionSyncOwned = $false

function Protect-PrivatePath([string] $Path, [bool] $Directory) {
    if (-not $isWindowsPlatform) { return }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sidValue in @($currentSid.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void] $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Write-Failure([string] $Message) {
    [Console]::Error.WriteLine("claudex: $Message")
}

# PowerShell finally blocks cover ordinary failures and Ctrl+C unwinding. A
# process-exit hook also removes the tracked secret temp and owned lock when the
# host receives a terminating console/POSIX signal before script cleanup runs.
if (-not ('Claudex.CredentialSyncCleanup' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

namespace Claudex
{
    public static class CredentialSyncCleanup
    {
        private static readonly object Gate = new object();
        private static string temporaryPath = "";
        private static string lockPath = "";
        private static string lockToken = "";

        static CredentialSyncCleanup()
        {
            AppDomain.CurrentDomain.ProcessExit += delegate { Cleanup(); };
            Console.CancelKeyPress += delegate { Cleanup(); };
        }

        public static void TrackTemporary(string path) { lock (Gate) { temporaryPath = path ?? ""; } }
        public static void ClearTemporaryTracking() { lock (Gate) { temporaryPath = ""; } }
        public static void TrackLock(string path, string token) { lock (Gate) { lockPath = path ?? ""; lockToken = token ?? ""; } }
        public static void ClearLockTracking() { lock (Gate) { lockPath = ""; lockToken = ""; } }

        public static void Cleanup()
        {
            lock (Gate)
            {
                if (!String.IsNullOrEmpty(temporaryPath))
                {
                    try { File.Delete(temporaryPath); } catch { }
                    temporaryPath = "";
                }
                if (!String.IsNullOrEmpty(lockPath) && !String.IsNullOrEmpty(lockToken))
                {
                    try
                    {
                        string ownerPath = Path.Combine(lockPath, "owner");
                        string owner = File.Exists(ownerPath) ? File.ReadAllText(ownerPath).Trim() : "";
                        if (owner.EndsWith(" " + lockToken, StringComparison.Ordinal))
                        {
                            string quarantine = lockPath + ".exit." + Guid.NewGuid().ToString("N");
                            Directory.Move(lockPath, quarantine);
                            Directory.Delete(quarantine, true);
                        }
                    }
                    catch { }
                    lockPath = "";
                    lockToken = "";
                }
            }
        }
    }
}
'@
}

function Get-TextFingerprint([string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8.GetBytes($Text)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function Read-SessionSyncOwner([string] $Directory = $sessionSyncLock) {
    $ownerPath = Join-Path $Directory 'owner'
    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return '' }
    try { return [IO.File]::ReadAllText($ownerPath).Trim() } catch { return '' }
}

function Move-SessionSyncLockToQuarantine([string] $ExpectedOwner) {
    $quarantine = Join-Path $bridgeAuthDir ('.codex-session-sync.lock.quarantine.' + $PID + '.' + [guid]::NewGuid().ToString('N'))
    try { Move-Item -LiteralPath $sessionSyncLock -Destination $quarantine -ErrorAction Stop } catch { return $false }
    $movedOwner = Read-SessionSyncOwner $quarantine
    if ($movedOwner -eq $ExpectedOwner) {
        Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not (Test-Path -LiteralPath $sessionSyncLock)) {
        try { Move-Item -LiteralPath $quarantine -Destination $sessionSyncLock -ErrorAction Stop } catch { }
    }
    return $false
}

function Release-SessionSyncLock {
    if (-not $script:sessionSyncOwned) { return }
    $current = Read-SessionSyncOwner
    $parts = @($current -split ' ', 2)
    if ($parts.Count -eq 2 -and $parts[1] -eq $script:sessionSyncToken) {
        [void] (Move-SessionSyncLockToQuarantine $current)
    }
    $script:sessionSyncOwned = $false
    $script:sessionSyncToken = ''
    [Claudex.CredentialSyncCleanup]::ClearLockTracking()
}

function Clear-SensitiveSessionState {
    if ($script:sessionTemporary) {
        Remove-Item -LiteralPath $script:sessionTemporary -Force -ErrorAction SilentlyContinue
        $script:sessionTemporary = ''
        [Claudex.CredentialSyncCleanup]::ClearTemporaryTracking()
    }
    Release-SessionSyncLock
}

function Acquire-SessionSyncLock {
    [IO.Directory]::CreateDirectory($bridgeAuthDir) | Out-Null
    Protect-PrivatePath $bridgeAuthDir $true
    foreach ($attempt in 1..100) {
        $created = $false
        try {
            New-Item -Path $sessionSyncLock -ItemType Directory -ErrorAction Stop | Out-Null
            $created = $true
            $script:sessionSyncToken = [guid]::NewGuid().ToString('N')
            $ownerPath = Join-Path $sessionSyncLock 'owner'
            [IO.File]::WriteAllText($ownerPath, "$PID $($script:sessionSyncToken)`n", $utf8)
            Protect-PrivatePath $ownerPath $false
            $script:sessionSyncOwned = $true
            [Claudex.CredentialSyncCleanup]::TrackLock($sessionSyncLock, $script:sessionSyncToken)
            return
        } catch {
            if ($created) {
                Remove-Item -LiteralPath $sessionSyncLock -Recurse -Force -ErrorAction SilentlyContinue
                $script:sessionSyncToken = ''
                [Claudex.CredentialSyncCleanup]::ClearLockTracking()
                throw
            }
            $owner = Read-SessionSyncOwner
            $parts = @($owner -split ' ', 2)
            $ownerIsDead = $false
            if ($parts.Count -eq 2 -and $parts[0] -match '^\d+$') {
                $ownerIsDead = $null -eq (Get-Process -Id ([int] $parts[0]) -ErrorAction SilentlyContinue)
            }
            $ownerlessIsStale = $false
            if (-not $owner -and (Test-Path -LiteralPath $sessionSyncLock -PathType Container)) {
                try {
                    $lockAge = ([DateTime]::UtcNow - (Get-Item -LiteralPath $sessionSyncLock).LastWriteTimeUtc).TotalSeconds
                    $ownerlessIsStale = $lockAge -ge 2
                } catch { }
            }
            if (($ownerIsDead -or $ownerlessIsStale) -and (Read-SessionSyncOwner) -eq $owner) {
                [void] (Move-SessionSyncLockToQuarantine $owner)
                continue
            }
            Start-Sleep -Milliseconds 50
        }
    }
    throw 'timed out waiting for another Codex credential synchronization.'
}

function Clear-BridgeSession {
    Remove-Item -LiteralPath $bridgeAuthFile -Force -ErrorAction SilentlyContinue
}

function Clear-AccountScopedState {
    Remove-Item -LiteralPath $usageAccountFile -Force -ErrorAction SilentlyContinue
    foreach ($name in @('limits.json', 'summary', 'last-attempt', 'last-success')) {
        Remove-Item -LiteralPath (Join-Path $usageCacheDir $name) -Force -ErrorAction SilentlyContinue
    }
    [IO.Directory]::CreateDirectory($configDir) | Out-Null
    Protect-PrivatePath $configDir $true
    $generationTemporary = Join-Path $configDir ('.usage-generation-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($generationTemporary, ([guid]::NewGuid().ToString('N') + "`n"), $utf8)
        Protect-PrivatePath $generationTemporary $false
        Move-Item -LiteralPath $generationTemporary -Destination $usageGenerationFile -Force
        Protect-PrivatePath $usageGenerationFile $false
    } finally {
        Remove-Item -LiteralPath $generationTemporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-JsonProperty($Object, [string] $Name, $Default = $null) {
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function Test-CodexLogin {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) { return $false }
    try {
        & $codex.Source login status *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Sync-Session {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        Clear-BridgeSession
        Clear-AccountScopedState
        Write-Failure 'Codex CLI was not found. Install Codex, run `codex login`, and retry.'
        return 10
    }
    if (-not (Test-CodexLogin)) {
        Clear-BridgeSession
        Clear-AccountScopedState
        Write-Failure 'Codex is logged out. Run `codex login` (or `claudex --login`) and retry.'
        return 11
    }
    if (-not (Test-Path -LiteralPath $codexAuthFile -PathType Leaf)) {
        Clear-BridgeSession
        Clear-AccountScopedState
        Write-Failure 'Codex is logged in, but its credentials are stored in the OS keyring.'
        Write-Failure 'Run `claudex --login` once so Codex can create a reusable file-backed local session.'
        return 13
    }
    [IO.Directory]::CreateDirectory($bridgeAuthDir) | Out-Null
    Protect-PrivatePath $bridgeAuthDir $true

    foreach ($attempt in 1..3) {
        try {
            $sourceRaw = [IO.File]::ReadAllText($codexAuthFile)
            $source = $sourceRaw | ConvertFrom-Json
        } catch {
            Clear-BridgeSession
            Clear-AccountScopedState
            Write-Failure 'Codex auth.json is not valid JSON. Run `claudex --login` to repair the session.'
            return 14
        }
        $tokens = Get-JsonProperty $source 'tokens' $null
        $authModeValue = Get-JsonProperty $source 'auth_mode' $null
        $accessTokenValue = Get-JsonProperty $tokens 'access_token' $null
        $refreshTokenValue = Get-JsonProperty $tokens 'refresh_token' $null
        $accountIdValue = Get-JsonProperty $tokens 'account_id' $null
        $authMode = if ($authModeValue -is [string]) { $authModeValue } else { '' }
        $accessToken = if ($accessTokenValue -is [string]) { $accessTokenValue } else { '' }
        $refreshToken = if ($refreshTokenValue -is [string]) { $refreshTokenValue } else { '' }
        $accountId = if ($accountIdValue -is [string]) { $accountIdValue } else { '' }
        $idToken = [string] (Get-JsonProperty $tokens 'id_token' '')
        $sourceRefresh = [string] (Get-JsonProperty $source 'last_refresh' '')
        if ($authModeValue -isnot [string] -or $authMode -ne 'chatgpt' -or -not $tokens -or
            $accessTokenValue -isnot [string] -or $refreshTokenValue -isnot [string] -or $accountIdValue -isnot [string] -or
            [string]::IsNullOrWhiteSpace($accessToken) -or
            [string]::IsNullOrWhiteSpace($refreshToken) -or
            [string]::IsNullOrWhiteSpace($accountId)) {
            Clear-BridgeSession
            Clear-AccountScopedState
            Write-Failure 'Claudex requires Codex ChatGPT sign-in. Run `claudex --login` and choose ChatGPT.'
            return 14
        }

        $sourceFingerprint = Get-TextFingerprint $sourceRaw
        $candidate = [ordered]@{
            type = 'codex'
            access_token = $accessToken
            refresh_token = $refreshToken
            id_token = $idToken
            account_id = $accountId
            last_refresh = $sourceRefresh
            disabled = $false
            expired = $false
        }

        try {
            Acquire-SessionSyncLock
            try { $currentFingerprint = Get-TextFingerprint ([IO.File]::ReadAllText($codexAuthFile)) }
            catch { $currentFingerprint = 'unreadable' }
            if ($currentFingerprint -ne $sourceFingerprint) { continue }

            $previousAccount = ''
            $shouldWrite = $true
            if (Test-Path -LiteralPath $bridgeAuthFile -PathType Leaf) {
                try {
                    $existing = Get-Content -LiteralPath $bridgeAuthFile -Raw | ConvertFrom-Json
                    $previousAccount = [string] $existing.account_id
                    $existingRefresh = [string] $existing.last_refresh
                    $existingDisabled = $null -ne $existing.PSObject.Properties['disabled'] -and [bool] $existing.disabled
                    $existingExpired = $null -ne $existing.PSObject.Properties['expired'] -and [bool] $existing.expired
                    if ($existing.type -eq 'codex' -and $existing.access_token -and
                        $existing.account_id -eq $accountId -and
                        $existing.access_token -eq $accessToken -and
                        $existing.refresh_token -eq $refreshToken -and
                        ([string] (Get-JsonProperty $existing 'id_token' '')) -eq $idToken -and
                        -not $existingDisabled -and -not $existingExpired -and
                        [string]::CompareOrdinal($existingRefresh, $sourceRefresh) -ge 0) {
                        $shouldWrite = $false
                    }
                } catch { $shouldWrite = $true }
            }
            if ($shouldWrite) {
                $script:sessionTemporary = Join-Path $bridgeAuthDir ('.codex-session-' + [guid]::NewGuid().ToString('N') + '.tmp')
                [Claudex.CredentialSyncCleanup]::TrackTemporary($script:sessionTemporary)
                [IO.File]::WriteAllText($script:sessionTemporary, (($candidate | ConvertTo-Json -Compress) + "`n"), $utf8)
                Protect-PrivatePath $script:sessionTemporary $false
                if (-not $previousAccount -or $previousAccount -ne $accountId) { Clear-AccountScopedState }
                Move-Item -LiteralPath $script:sessionTemporary -Destination $bridgeAuthFile -Force
                $script:sessionTemporary = ''
                [Claudex.CredentialSyncCleanup]::ClearTemporaryTracking()
                Protect-PrivatePath $bridgeAuthFile $false
            }
            return 0
        } finally {
            Clear-SensitiveSessionState
        }
    }

    Write-Failure 'Codex credentials changed repeatedly during synchronization; retry.'
    return 15
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
    try { Sync-Session | Out-Null } catch { }
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
        Clear-AccountScopedState
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
