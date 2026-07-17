param(
    [switch] $Cached,
    [switch] $Json,
    [switch] $Statusline,
    [switch] $RefreshCache,
    [switch] $LockHeld,
    [string] $LockToken,
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
$refreshOwnerFile = Join-Path $refreshLock 'owner-pid'
$accountSelectionFile = Join-Path $configDir 'codex-usage-account'
$usageGenerationFile = Join-Path $configDir 'usage-generation'
$curlCommand = if ($env:CLAUDEX_CURL_BIN) { $env:CLAUDEX_CURL_BIN } else { 'curl.exe' }
$officialUsageUrl = 'https://chatgpt.com/backend-api/wham/usage'
$usageUrl = if ($env:CLAUDEX_USAGE_URL) { $env:CLAUDEX_USAGE_URL } else { $officialUsageUrl }

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
$ownsRefreshLock = $false
$ownedRefreshToken = ''
$legacyRefreshLockMaxAgeSeconds = [Math]::Max(30, ($timeoutSeconds * 3) + 10)
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($LockHeld -and ($LockToken -notmatch '^[A-Za-z0-9._-]{8,128}$')) {
    throw '-LockHeld requires a valid -LockToken generation.'
}

function Assert-SafeUsageUrl {
    if ([string]::Equals($usageUrl, $officialUsageUrl, [StringComparison]::Ordinal)) { return }
    if ($env:CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL -ne '1') {
        throw "CLAUDEX_USAGE_URL must remain $officialUsageUrl; only tests may enable a loopback override with CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL=1."
    }
    $parsed = $null
    $validAbsoluteUrl = [Uri]::TryCreate($usageUrl, [UriKind]::Absolute, [ref] $parsed)
    $validScheme = $validAbsoluteUrl -and ($parsed.Scheme -in @('http', 'https'))
    $validHost = $validAbsoluteUrl -and ($parsed.Host -in @('localhost', '127.0.0.1', '::1', '[::1]'))
    if (-not $validScheme -or -not $validHost -or $parsed.UserInfo) {
        throw 'CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL permits only loopback HTTP(S) usage endpoints.'
    }
}

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

function Clear-UsageCache {
    foreach ($path in @($cacheFile, $summaryFile, $lastAttemptFile, $lastSuccessFile)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    [IO.Directory]::CreateDirectory($configDir) | Out-Null
    Protect-PrivatePath $configDir $true
    $temporary = Join-Path $configDir ('.usage-generation-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ([guid]::NewGuid().ToString('N') + "`n"), $utf8)
        Protect-PrivatePath $temporary $false
        Move-Item -LiteralPath $temporary -Destination $usageGenerationFile -Force
        Protect-PrivatePath $usageGenerationFile $false
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-UsageGeneration {
    if (-not (Test-Path -LiteralPath $usageGenerationFile -PathType Leaf)) { return 'missing' }
    try { return [IO.File]::ReadAllText($usageGenerationFile).Trim() } catch { return 'missing' }
}

function Get-RefreshLockField([string] $OwnerFile, [string] $Field) {
    if (-not (Test-Path -LiteralPath $OwnerFile -PathType Leaf)) { return '' }
    try {
        $lines = [IO.File]::ReadAllLines($OwnerFile)
        foreach ($line in $lines) {
            if ($line.StartsWith($Field + '=', [StringComparison]::Ordinal)) { return $line.Substring($Field.Length + 1) }
        }
        if ($lines.Count -gt 0 -and $lines[0] -match '^(?<pid>\d+)\s+(?<identity>[^\s@]+)@(?<nonce>[^\s@]+)$') {
            if ($Field -eq 'identity' -and [string] $Matches.identity -eq '-') { return '' }
            if ($Field -in @('pid', 'identity', 'nonce')) { return [string] $Matches[$Field] }
        }
    } catch { }
    return ''
}

function Get-RefreshGenerationNonce([string] $Directory = $refreshLock) {
    $file = Join-Path $Directory 'generation'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    try { return [IO.File]::ReadAllText($file).Trim() } catch { return '' }
}

function Get-RefreshLockBarriers {
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $cacheDir -Directory -Filter 'refresh.lock.quarantine.*' -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Get-RefreshLockDirectoryIdentity([string] $Directory = $refreshLock) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return '' }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if (-not ('ClaudexNativeDirectoryIdentity' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ClaudexNativeDirectoryIdentity {
    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation {
        public uint Attributes;
        public FileTime CreationTime;
        public FileTime LastAccessTime;
        public FileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(IntPtr handle, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string GetIdentity(string path) {
        const uint ShareAll = 1u | 2u | 4u;
        const uint OpenExisting = 3u;
        const uint BackupSemantics = 0x02000000u;
        IntPtr handle = CreateFile(path, 0u, ShareAll, IntPtr.Zero, OpenExisting, BackupSemantics, IntPtr.Zero);
        if (handle == new IntPtr(-1)) return String.Empty;
        try {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) return String.Empty;
            ulong index = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            return information.VolumeSerialNumber.ToString("X8") + ":" + index.ToString("X16");
        } finally { CloseHandle(handle); }
    }
}
'@
        }
        try { return [ClaudexNativeDirectoryIdentity]::GetIdentity($Directory) } catch { return '' }
    }
    $stat = Get-Command stat -ErrorAction SilentlyContinue
    if (-not $stat) { return '' }
    try { $identity = (& $stat.Source -c '%d:%i' -- $Directory 2>$null | Select-Object -First 1).Trim() } catch { $identity = '' }
    if ($identity -notmatch '^[0-9]+:[0-9]+$') {
        try { $identity = (& $stat.Source -f '%d:%i' $Directory 2>$null | Select-Object -First 1).Trim() } catch { $identity = '' }
    }
    if ($identity -match '^[0-9]+:[0-9]+$') { return $identity }
    return ''
}

function Invoke-RefreshLockTestPause([string] $Stage) {
    if ($env:CLAUDEX_TEST_MODE -ne '1') { return }
    $ready = [Environment]::GetEnvironmentVariable("CLAUDEX_TEST_REFRESH_LOCK_${Stage}_READY_FILE", 'Process')
    $continue = [Environment]::GetEnvironmentVariable("CLAUDEX_TEST_REFRESH_LOCK_${Stage}_CONTINUE_FILE", 'Process')
    if (-not $ready -or -not $continue) { return }
    [IO.File]::WriteAllText($ready, "ready`n", $utf8)
    while (-not (Test-Path -LiteralPath $continue -PathType Leaf)) { Start-Sleep -Milliseconds 20 }
}

function Remove-RefreshLockFiles([string] $Directory) {
    Remove-Item -LiteralPath (Join-Path $Directory 'owner-pid') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Directory 'generation') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
}

function Publish-RefreshLockFile([string] $Source, [string] $Destination) {
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_FORCE_REFRESH_PUBLICATION_FAILURE -eq '1') { throw 'forced refresh lock publication failure' }
    if ($env:CLAUDEX_TEST_MODE -ne '1' -or $env:CLAUDEX_TEST_FORCE_REFRESH_HARDLINK_FAILURE -ne '1') {
        try { New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null; return } catch { }
    }
    $input = $null; $output = $null
    try {
        $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $output = [IO.FileStream]::new($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $input.CopyTo($output); $output.Flush($true)
    } finally { if ($output) { $output.Dispose() }; if ($input) { $input.Dispose() } }
}

function Restore-RefreshLockBarrier([string] $Barrier) {
    foreach ($attempt in 1..250) {
        if (-not (Test-Path -LiteralPath $refreshLock)) {
            try { Move-Item -LiteralPath $Barrier -Destination $refreshLock -ErrorAction Stop; return $true } catch { }
        }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

function Get-RefreshLockAgeSeconds([string] $Directory = $refreshLock) {
    try { return [Math]::Max(0, ([DateTime]::UtcNow - (Get-Item -LiteralPath $Directory -ErrorAction Stop).LastWriteTimeUtc).TotalSeconds) }
    catch { return 0 }
}

function Test-RefreshOwnerCurrent([string] $OwnerFile) {
    $ownerPid = 0
    if (-not [int]::TryParse((Get-RefreshLockField $OwnerFile 'pid'), [ref] $ownerPid) -or $ownerPid -le 0) { return $false }
    $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    $identity = Get-RefreshLockField $OwnerFile 'identity'
    if ([string]::IsNullOrWhiteSpace($identity)) { return $true }
    try { return $identity -eq [string] $process.StartTime.ToUniversalTime().Ticks } catch { return $true }
}

function Get-LegacyRefreshOwnerRecord([string] $Directory = $refreshLock) {
    $owner = Join-Path $Directory 'owner-pid'
    if (-not (Test-Path -LiteralPath $owner -PathType Leaf)) { return '' }
    try {
        $record = [IO.File]::ReadAllText($owner).Trim()
        if ($record -match '^\d+\s+\S+$') { return $record }
    } catch { }
    return ''
}

function Test-LegacyRefreshOwnerCurrent([string] $Record) {
    if ($Record -notmatch '^(?<pid>\d+)\s+(?<token>\S+)$') { return $false }
    try { return $null -ne (Get-Process -Id ([int] $Matches.pid) -ErrorAction Stop) } catch { return $false }
}

function Remove-LegacyRefreshLock([string] $ExpectedRecord) {
    $quarantine = $refreshLock + '.quarantine.legacy.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    try { Move-Item -LiteralPath $refreshLock -Destination $quarantine -ErrorAction Stop } catch { return $false }
    $moved = Get-LegacyRefreshOwnerRecord $quarantine
    if ($moved -eq $ExpectedRecord -and -not (Get-RefreshGenerationNonce $quarantine) -and
        -not (Get-RefreshLockField (Join-Path $quarantine 'owner-pid') 'nonce')) {
        Remove-RefreshLockFiles $quarantine
        return $true
    }
    [void] (Restore-RefreshLockBarrier $quarantine)
    return $false
}

function Recover-RefreshLockBarriers {
    foreach ($info in @(Get-RefreshLockBarriers)) {
        $barrier = $info.FullName; $owner = Join-Path $barrier 'owner-pid'
        $nonce = Get-RefreshLockField $owner 'nonce'; $generation = Get-RefreshGenerationNonce $barrier
        $legacy = Get-LegacyRefreshOwnerRecord $barrier
        $age = Get-RefreshLockAgeSeconds $barrier
        if ($nonce -and (Test-RefreshOwnerCurrent $owner)) {
            if (-not (Test-Path -LiteralPath $refreshLock)) { try { Move-Item -LiteralPath $barrier -Destination $refreshLock -ErrorAction Stop } catch { } }
        } elseif ($legacy -and (Test-LegacyRefreshOwnerCurrent $legacy)) {
            Remove-Item -LiteralPath (Join-Path $barrier 'generation') -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $refreshLock)) { try { Move-Item -LiteralPath $barrier -Destination $refreshLock -ErrorAction Stop } catch { } }
        } elseif (($nonce -or $generation) -and $age -ge 2) { Remove-RefreshLockFiles $barrier }
        else {
            if ($legacy -and $age -ge 2) { Remove-RefreshLockFiles $barrier }
            elseif (-not $legacy -and $age -ge $legacyRefreshLockMaxAgeSeconds) { Remove-RefreshLockFiles $barrier }
        }
    }
}

function Remove-OwnedRefreshGeneration([string] $ExpectedNonce) {
    if ([string]::IsNullOrWhiteSpace($ExpectedNonce)) { return $false }
    $currentGeneration = Get-RefreshGenerationNonce
    $currentOwner = Get-RefreshLockField $refreshOwnerFile 'nonce'
    if ($currentGeneration -ne $ExpectedNonce -and $currentOwner -ne $ExpectedNonce) { return $false }
    $quarantine = $refreshLock + '.quarantine.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    Invoke-RefreshLockTestPause 'BEFORE_RENAME'
    try { Move-Item -LiteralPath $refreshLock -Destination $quarantine -ErrorAction Stop } catch { return $false }
    Invoke-RefreshLockTestPause 'AFTER_RENAME'
    $movedGeneration = Get-RefreshGenerationNonce $quarantine
    $movedOwner = Get-RefreshLockField (Join-Path $quarantine 'owner-pid') 'nonce'
    if ($movedGeneration -eq $ExpectedNonce -and $movedOwner -eq $ExpectedNonce) { Remove-RefreshLockFiles $quarantine; return $true }
    if ($movedGeneration -eq $ExpectedNonce -and $movedOwner -ne $ExpectedNonce) {
        Remove-Item -LiteralPath (Join-Path $quarantine 'generation') -Force -ErrorAction SilentlyContinue
    }
    [void] (Restore-RefreshLockBarrier $quarantine)
    return $false
}

function Recover-OwnedRefreshGeneration([string] $ExpectedNonce) {
    foreach ($info in @(Get-RefreshLockBarriers)) {
        $moved = Get-RefreshGenerationNonce $info.FullName
        if (-not $moved) { $moved = Get-RefreshLockField (Join-Path $info.FullName 'owner-pid') 'nonce' }
        if ($moved -eq $ExpectedNonce -and -not (Test-Path -LiteralPath $refreshLock)) {
            try { Move-Item -LiteralPath $info.FullName -Destination $refreshLock -ErrorAction Stop } catch { }
        }
    }
    $current = Get-RefreshGenerationNonce
    if (-not $current) { $current = Get-RefreshLockField $refreshOwnerFile 'nonce' }
    return $current -eq $ExpectedNonce -and @(Get-RefreshLockBarriers).Count -eq 0
}

function Remove-IncompleteRefreshLock {
    if (-not (Test-Path -LiteralPath $refreshLock -PathType Container)) { return $true }
    $quarantine = $refreshLock + '.quarantine.incomplete.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    try { Move-Item -LiteralPath $refreshLock -Destination $quarantine -ErrorAction Stop } catch { return $false }
    $moved = Get-RefreshGenerationNonce $quarantine
    if (-not $moved) { $moved = Get-RefreshLockField (Join-Path $quarantine 'owner-pid') 'nonce' }
    $legacy = Get-LegacyRefreshOwnerRecord $quarantine
    if ($moved -or $legacy) { [void] (Restore-RefreshLockBarrier $quarantine); return $false }
    Remove-RefreshLockFiles $quarantine
    return $true
}

function Resolve-RefreshLockContention([int] $AcquisitionElapsedSeconds) {
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_REFRESH_LOCK_CONTENDED_READY_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_REFRESH_LOCK_CONTENDED_READY_FILE, "ready`n", $utf8)
    }
    $age = Get-RefreshLockAgeSeconds
    $observed = Get-RefreshLockField $refreshOwnerFile 'nonce'
    if ($observed -and $age -ge 2 -and -not (Test-RefreshOwnerCurrent $refreshOwnerFile)) {
        [void] (Remove-OwnedRefreshGeneration $observed)
    } elseif ((Get-RefreshGenerationNonce) -and $age -ge 2) {
        [void] (Remove-OwnedRefreshGeneration (Get-RefreshGenerationNonce))
    } else {
        $legacyRecord = Get-LegacyRefreshOwnerRecord
        if ($legacyRecord -and $age -ge 2 -and -not (Test-LegacyRefreshOwnerCurrent $legacyRecord)) {
            [void] (Remove-LegacyRefreshLock $legacyRecord)
        # Waiting in this contender cannot make a directory that was initially
        # inside its publication grace eligible for reclamation.
        } elseif (-not $legacyRecord -and (Test-Path -LiteralPath $refreshLock -PathType Container)) {
            if ($age -ge ($legacyRefreshLockMaxAgeSeconds + [Math]::Max(0, $AcquisitionElapsedSeconds))) {
                [void] (Remove-LegacyRefreshLock '')
            } else {
                return 'fresh-ownerless'
            }
        }
    }
    return 'contended'
}

function Acquire-RefreshLock {
    if ($LockHeld) {
        $current = Get-RefreshGenerationNonce
        if (-not $current) { $current = Get-RefreshLockField $refreshOwnerFile 'nonce' }
        if ($current -ne $LockToken -or @(Get-RefreshLockBarriers).Count -gt 0) { throw 'the inherited usage refresh lock is no longer owned by this generation.' }
        $script:ownsRefreshLock = $true; $script:ownedRefreshToken = $LockToken; return
    }
    [IO.Directory]::CreateDirectory($cacheDir) | Out-Null; Protect-PrivatePath $cacheDir $true
    $acquisitionTimer = [Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Recover-RefreshLockBarriers
        if (@(Get-RefreshLockBarriers).Count -gt 0) {
            if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_REFRESH_LOCK_CONTENDED_READY_FILE) {
                [IO.File]::WriteAllText($env:CLAUDEX_TEST_REFRESH_LOCK_CONTENDED_READY_FILE, "ready`n", $utf8)
            }
            if ($acquisitionTimer.Elapsed.TotalSeconds -ge 5) { break }
            Start-Sleep -Milliseconds 20
            continue
        }
        # Avoid process inspection and temporary publication files while a
        # contender is already present. Otherwise a slow retry loop can age a
        # newly ownerless directory into its own reclamation threshold.
        if (Test-Path -LiteralPath $refreshLock -PathType Container) {
            $contentionState = Resolve-RefreshLockContention ([int] [Math]::Floor($acquisitionTimer.Elapsed.TotalSeconds))
            if ($contentionState -eq 'fresh-ownerless') { break }
            if ($acquisitionTimer.Elapsed.TotalSeconds -ge 5) { break }
            Start-Sleep -Milliseconds 20
            continue
        }
        $nonce = [guid]::NewGuid().ToString('N'); $created = $false; $createdDirectoryIdentity = ''
        $ownerTemporary = Join-Path $cacheDir ('.refresh-owner.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $generationTemporary = Join-Path $cacheDir ('.refresh-generation.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $identity = [string] (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
        # The complete record remains a valid PID and token for pre-generation
        # releases while current readers decode identity and nonce from it.
        [IO.File]::WriteAllText($ownerTemporary, "${PID} ${identity}@${nonce}`n", $utf8)
        [IO.File]::WriteAllText($generationTemporary, "$nonce`n", $utf8)
        try {
            New-Item -Path $refreshLock -ItemType Directory -ErrorAction Stop | Out-Null; $created = $true
            $createdDirectoryIdentity = Get-RefreshLockDirectoryIdentity
            Invoke-RefreshLockTestPause 'AFTER_MKDIR'
            if (-not $createdDirectoryIdentity -or (Get-RefreshLockDirectoryIdentity) -ne $createdDirectoryIdentity) { throw 'refresh lock directory identity changed' }
            Publish-RefreshLockFile $generationTemporary (Join-Path $refreshLock 'generation')
            if ((Get-RefreshLockDirectoryIdentity) -ne $createdDirectoryIdentity -or (Get-RefreshGenerationNonce) -ne $nonce) { throw 'refresh lock generation publication changed' }
            Publish-RefreshLockFile $ownerTemporary $refreshOwnerFile
            if ((Get-RefreshLockDirectoryIdentity) -ne $createdDirectoryIdentity -or
                (Get-RefreshLockField $refreshOwnerFile 'nonce') -ne $nonce -or @(Get-RefreshLockBarriers).Count -gt 0) { throw 'refresh lock ownership publication changed' }
            Protect-PrivatePath $refreshOwnerFile $false; Protect-PrivatePath (Join-Path $refreshLock 'generation') $false
            Remove-Item -LiteralPath $ownerTemporary, $generationTemporary -Force -ErrorAction SilentlyContinue
            Invoke-RefreshLockTestPause 'AFTER_PUBLISH'
            if ((Get-RefreshLockDirectoryIdentity) -ne $createdDirectoryIdentity -or
                (Get-RefreshGenerationNonce) -ne $nonce -or @(Get-RefreshLockBarriers).Count -gt 0) {
                if (-not (Recover-OwnedRefreshGeneration $nonce)) { Start-Sleep -Milliseconds 20; continue }
                if ((Get-RefreshLockDirectoryIdentity) -ne $createdDirectoryIdentity) { Start-Sleep -Milliseconds 20; continue }
            }
            $script:ownsRefreshLock = $true; $script:ownedRefreshToken = $nonce; return
        } catch {
            if ($created -and $createdDirectoryIdentity -and (Get-RefreshLockDirectoryIdentity) -eq $createdDirectoryIdentity -and
                -not (Remove-OwnedRefreshGeneration $nonce)) { [void] (Remove-IncompleteRefreshLock) }
        } finally { Remove-Item -LiteralPath $ownerTemporary, $generationTemporary -Force -ErrorAction SilentlyContinue }
        $contentionState = Resolve-RefreshLockContention ([int] [Math]::Floor($acquisitionTimer.Elapsed.TotalSeconds))
        if ($contentionState -eq 'fresh-ownerless') { break }
        if ($acquisitionTimer.Elapsed.TotalSeconds -ge 5) { break }
        Start-Sleep -Milliseconds 20
    }
    throw 'another usage refresh is already in progress.'
}

function Test-UsableCodexCredential($Credential) {
    return (Get-Property $Credential 'type' '') -eq 'codex' -and
        -not [string]::IsNullOrWhiteSpace([string] (Get-Property $Credential 'access_token' '')) -and
        -not [bool] (Get-Property $Credential 'disabled' $false) -and
        -not [bool] (Get-Property $Credential 'expired' $false)
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
        $explicit = Get-Content -LiteralPath $env:CLAUDEX_CODEX_AUTH_FILE -Raw | ConvertFrom-Json
        if (-not (Test-UsableCodexCredential $explicit)) { throw 'CLAUDEX_CODEX_AUTH_FILE is disabled, expired, or invalid.' }
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
        if (-not (Test-UsableCodexCredential $selected)) { throw 'the selected Codex usage account is disabled, expired, or invalid.' }
        return $selectedPath
    }
    foreach ($entry in @(Get-CodexAuthFiles)) {
        if (Test-UsableCodexCredential $entry.Data) { return $entry.File.FullName }
    }
    throw 'no CLIProxyAPI Codex OAuth credential was found; run the installer with -Login.'
}

function Get-UsageAuthBinding {
    try {
        $path = Find-CodexAuthFile
        $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        return "$path`t$digest"
    } catch { return '' }
}

function Get-CodexAuthFiles {
    $authDir = Get-ProxyAuthDirectory
    if (-not (Test-Path -LiteralPath $authDir -PathType Container)) { throw 'CLIProxyAPI Codex OAuth directory was not found.' }
    $valid = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $authDir -File -Filter 'codex*.json')) {
        try {
            $candidate = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ((Get-Property $candidate 'type' '') -eq 'codex' -and (Get-Property $candidate 'access_token' '')) {
                $refreshText = [string] (Get-Property $candidate 'last_refresh' '')
                $refreshTicks = 0L
                $parsedRefresh = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse(
                    $refreshText,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
                    [ref] $parsedRefresh
                )) {
                    $refreshTicks = $parsedRefresh.UtcDateTime.Ticks
                } else {
                    [void][long]::TryParse($refreshText, [ref] $refreshTicks)
                }
                $valid += [pscustomobject]@{
                    File = $file
                    Data = $candidate
                    RefreshTicks = $refreshTicks
                    StableName = $file.Name.ToLowerInvariant()
                }
            }
        } catch { }
    }
    $sortProperties = @(
        @{ Expression = { $_.RefreshTicks }; Descending = $true }
        @{ Expression = { $_.StableName }; Descending = $false }
        @{ Expression = { $_.File.Name }; Descending = $false }
    )
    return @($valid | Sort-Object -Property $sortProperties)
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
        $suffix = if ([bool] (Get-Property $entry.Data 'disabled' $false)) { ' (disabled)' }
            elseif ([bool] (Get-Property $entry.Data 'expired' $false)) { ' (expired)' }
            else { '' }
        Write-Output "[$marker] $($index + 1). $email$suffix"
    }
    Write-Output 'Select one with: claudex --account <number|email|filename>; use auto to follow the newest credential.'
}

function Select-CodexAccount([string] $Selector) {
    if ($Selector -eq 'auto') {
        Remove-Item -LiteralPath $accountSelectionFile -Force -ErrorAction SilentlyContinue
        Clear-UsageCache
        Write-Output 'Codex usage account selection: automatic (newest refreshed credential).'
        return
    }
    $files = @(Get-CodexAuthFiles)
    $selected = $null
    for ($index = 0; $index -lt $files.Count; $index++) {
        $entry = $files[$index]
        $email = [string] (Get-Property $entry.Data 'email' '')
        if ($Selector -eq [string] ($index + 1) -or $Selector -eq $email -or $Selector -eq $entry.File.Name) {
            if (-not (Test-UsableCodexCredential $entry.Data)) { throw "Codex account '$Selector' is disabled or expired." }
            $selected = $entry
            break
        }
    }
    if ($null -eq $selected) { throw "no Codex account matched '$Selector'. Run: claudex --accounts" }
    Write-AtomicText $accountSelectionFile ($selected.File.Name + "`n")
    Clear-UsageCache
    Write-Output "Selected Codex usage account: $([string] (Get-Property $selected.Data 'email' 'unknown account'))"
}

function Convert-Window($Window) {
    if ($null -eq $Window) { return $null }
    $windowMinutes = [double] (Get-Property $Window 'windowDurationMins' 0)
    return [ordered]@{
        used_percent = [double] (Get-Property $Window 'used_percent' (Get-Property $Window 'usedPercent' ([double]::NaN)))
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

function Test-UsageWindow($Window) {
    if ($null -eq $Window) { return $false }
    try {
        $used = [double] (Get-Property $Window 'used_percent' ([double]::NaN))
        $duration = [long] (Get-Property $Window 'limit_window_seconds' 0)
        return -not [double]::IsNaN($used) -and -not [double]::IsInfinity($used) -and
            $used -ge 0 -and $used -le 100 -and $duration -gt 0
    } catch { return $false }
}

function Test-UsageLimit($Limit) {
    if ($null -eq $Limit) { return $false }
    $primary = Get-Property $Limit 'primary_window' $null
    $secondary = Get-Property $Limit 'secondary_window' $null
    if ($null -eq $primary -and $null -eq $secondary) { return $false }
    if ($null -ne $primary -and -not (Test-UsageWindow $primary)) { return $false }
    if ($null -ne $secondary -and -not (Test-UsageWindow $secondary)) { return $false }
    return $true
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
    $otherLimits = @()
    $codeReview = Get-Property $Snapshot 'code_review_rate_limit' $null
    if ($codeReview) { $otherLimits += [pscustomobject]@{ Name = 'Review'; Limit = $codeReview } }
    foreach ($entry in @(Get-Property $Snapshot 'additional_rate_limits' @())) {
        $otherLimits += [pscustomobject]@{ Name = [string] (Get-Property $entry 'limit_name' 'Additional'); Limit = Get-Property $entry 'rate_limit' $null }
    }
    foreach ($entry in $otherLimits) {
        if (-not $entry.Limit) { continue }
        $reached = [bool] (Get-Property $entry.Limit 'limit_reached' $false)
        foreach ($windowName in @('primary_window', 'secondary_window')) {
            $window = Get-Property $entry.Limit $windowName $null
            if (-not $window) { continue }
            $remaining = Get-RemainingPercent $window
            $remainingValues.Add($remaining)
            if ($reached -or ($alertPercent -gt 0 -and $remaining -le $alertPercent)) {
                $parts.Add("$($entry.Name) $(Get-ShortWindowLabel ([long] $window.limit_window_seconds)) $remaining% left")
            }
        }
    }
    $anyReached = ($limit -and [bool] (Get-Property $limit 'limit_reached' $false)) -or
        ($otherLimits | Where-Object { $_.Limit -and [bool] (Get-Property $_.Limit 'limit_reached' $false) } | Select-Object -First 1) -or
        (Get-Property $Snapshot 'rate_limit_reached_type' $null)
    if ($parts.Count -gt 0) {
        $prefix = if ($anyReached -or ($alertPercent -gt 0 -and ($remainingValues | Measure-Object -Minimum).Minimum -le $alertPercent)) { '⚠ Codex ' } else { 'Codex ' }
        return $prefix + ($parts -join ' · ')
    }
    if ($anyReached) { return 'Codex limit reached' }
    return ''
}

function Write-AtomicText([string] $Path, [string] $Content) {
    $parent = Split-Path $Path -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    Protect-PrivatePath $parent $true
    $temporary = Join-Path $parent ('.tmp.' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $Content, $utf8)
        Protect-PrivatePath $temporary $false
        Move-Item -LiteralPath $temporary -Destination $Path -Force
        Protect-PrivatePath $Path $false
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-WebUsageResponse {
    Assert-SafeUsageUrl
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
        Protect-PrivatePath $curlConfig $false
        $output = @(& $curlCommand --silent --show-error --fail --connect-timeout 3 --max-time $timeoutSeconds --config $curlConfig -- $usageUrl 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'OpenAI usage refresh failed.' }
        $raw = $output -join "`n"
    } finally {
        if (Test-Path -LiteralPath $curlConfig) { Remove-Item -LiteralPath $curlConfig -Force }
    }

    try { return ($raw | ConvertFrom-Json) } catch { throw 'OpenAI returned an unrecognized usage response.' }
}

function Initialize-CappedStreamReader {
    if ('Claudex.CappedTextReader' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
namespace Claudex {
    public sealed class CappedLine {
        public string Text { get; set; }
        public bool Truncated { get; set; }
        public bool EndOfStream { get; set; }
    }
    public static class CappedTextReader {
        public static async Task<CappedLine> ReadLineAsync(TextReader reader, int maximum) {
            var text = new StringBuilder(Math.Min(maximum, 4096));
            var one = new char[1];
            var truncated = false;
            while (true) {
                var read = await reader.ReadAsync(one, 0, 1).ConfigureAwait(false);
                if (read == 0) return new CappedLine { Text = text.ToString(), Truncated = truncated, EndOfStream = true };
                if (one[0] == '\n') return new CappedLine { Text = text.ToString(), Truncated = truncated, EndOfStream = false };
                if (one[0] == '\r') continue;
                if (text.Length < maximum) text.Append(one[0]); else truncated = true;
            }
        }
        public static async Task<string> DrainAsync(TextReader reader, int maximum) {
            var text = new StringBuilder(Math.Min(maximum, 4096));
            var buffer = new char[4096];
            int read;
            while ((read = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
                var remaining = maximum - text.Length;
                if (remaining > 0) text.Append(buffer, 0, Math.Min(remaining, read));
            }
            return text.ToString();
        }
    }
}
'@
}

function Stop-AppServerTree($Process) {
    try { $Process.StandardInput.Close() } catch { }
    if ($Process.HasExited) { try { $Process.WaitForExit() } catch { }; return }
    if ($isWindowsPlatform) {
        try { & taskkill.exe /PID ([string] $Process.Id) /T *> $null } catch { }
    } else {
        try { $Process.Kill() } catch { }
    }
    if (-not $Process.WaitForExit(500)) {
        if ($isWindowsPlatform) {
            try { & taskkill.exe /PID ([string] $Process.Id) /T /F *> $null } catch { }
        } else {
            try { $Process.Kill() } catch { }
        }
        [void] $Process.WaitForExit(1000)
    }
}

function Get-AppServerUsageResponse {
    if ($env:CLAUDEX_CODEX_AUTH_FILE -or (Test-Path -LiteralPath $accountSelectionFile -PathType Leaf)) {
        throw 'app-server fallback is disabled while an explicit usage account is selected.'
    }
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) { throw 'Codex CLI is unavailable for the app-server fallback.' }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $codexPath = [string] $codex.Source
    $codexExtension = [IO.Path]::GetExtension($codexPath).ToLowerInvariant()
    if ($codex.CommandType -eq 'ExternalScript' -or $codexExtension -in @('.ps1', '.cmd', '.bat')) {
        # npm installs command shims on Windows. ProcessStartInfo with shell
        # execution disabled cannot CreateProcess a .ps1/.cmd file directly,
        # so invoke that trusted local shim through the current PowerShell.
        $escapedCodexPath = $codexPath.Replace("'", "''")
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -Command `"& '$escapedCodexPath' app-server`""
    } else {
        $startInfo.FileName = $codexPath
        $startInfo.Arguments = 'app-server'
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stderrTask = $null
    $processStarted = $false
    try {
        if (-not $process.Start()) { throw 'could not start Codex app-server.' }
        $processStarted = $true
        Initialize-CappedStreamReader
        # Drain stderr independently and retain at most 64 KiB. The drain keeps
        # running after the cap so a noisy child cannot fill the OS pipe.
        $stderrTask = [Claudex.CappedTextReader]::DrainAsync($process.StandardError, 65536)
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
        $phase = 1
        $lineTask = [Claudex.CappedTextReader]::ReadLineAsync($process.StandardOutput, 1048576)
        $process.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"Claudex","title":"Claudex usage fallback","version":"1.0.0"}}}')
        $process.StandardInput.Flush()
        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = [math]::Max(1, [int] ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $delayTask = [Threading.Tasks.Task]::Delay($remaining)
            $completed = [Threading.Tasks.Task]::WhenAny($lineTask, $delayTask).GetAwaiter().GetResult()
            if (-not [object]::ReferenceEquals($completed, $lineTask)) { throw 'Codex app-server response timed out.' }
            $lineResult = $lineTask.GetAwaiter().GetResult()
            if ($lineResult.Truncated) { throw 'Codex app-server returned an oversized response line.' }
            if ($lineResult.EndOfStream -and -not $lineResult.Text) { throw 'Codex app-server closed before returning rate limits.' }
            $lineTask = [Claudex.CappedTextReader]::ReadLineAsync($process.StandardOutput, 1048576)
            try { $message = $lineResult.Text | ConvertFrom-Json } catch { continue }
            if ([int] (Get-Property $message 'id' -1) -ne $phase) { continue }
            $result = Get-Property $message 'result' $null
            if ($null -eq $result) { throw "Codex app-server request $phase failed." }
            if ($phase -eq 1) {
                $phase = 2
                $process.StandardInput.WriteLine('{"method":"initialized"}')
                $process.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read","params":null}')
                $process.StandardInput.Flush()
            } else {
                return $result
            }
        }
        throw 'Codex app-server response timed out.'
    } finally {
        if ($processStarted) { Stop-AppServerTree $process }
        if ($stderrTask) { try { [void] $stderrTask.Wait(1000) } catch { } }
        $process.Dispose()
    }
}

function Refresh-UsageCache {
    [IO.Directory]::CreateDirectory($cacheDir) | Out-Null
    if ($usageSource -ne 'app-server') { Assert-SafeUsageUrl }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $generationAtStart = Get-UsageGeneration
    $authBindingAtStart = Get-UsageAuthBinding
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
            if (-not (Test-UsageLimit $candidateLimit)) {
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
    if (-not (Test-UsageLimit $rateLimit)) {
        throw 'OpenAI returned no Codex rate-limit window.'
    }
    if ($codeReviewLimit -and -not (Test-UsageLimit $codeReviewLimit)) { throw 'OpenAI returned an invalid code-review rate-limit window.' }
    foreach ($entry in $additional) {
        if (-not (Test-UsageLimit (Get-Property $entry 'rate_limit' $null))) { throw 'OpenAI returned an invalid additional rate-limit window.' }
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
    if ((Get-UsageGeneration) -ne $generationAtStart) { throw 'the selected Codex usage account changed during refresh; discarded the obsolete snapshot.' }
    if ($source -eq 'web' -and (Get-UsageAuthBinding) -ne $authBindingAtStart) { throw 'the selected Codex usage credential changed during refresh; discarded the obsolete snapshot.' }
    Write-AtomicText $cacheFile (($snapshot | ConvertTo-Json -Depth 20 -Compress) + "`n")
    Write-AtomicText $summaryFile ((Get-CompactSummary $snapshot) + "`n")
    if ((Get-UsageGeneration) -ne $generationAtStart) {
        Remove-Item -LiteralPath $cacheFile, $summaryFile -Force -ErrorAction SilentlyContinue
        throw 'the selected Codex usage account changed during refresh; discarded the obsolete snapshot.'
    }
    if ($source -eq 'web' -and (Get-UsageAuthBinding) -ne $authBindingAtStart) {
        Remove-Item -LiteralPath $cacheFile, $summaryFile -Force -ErrorAction SilentlyContinue
        throw 'the selected Codex usage credential changed during refresh; discarded the obsolete snapshot.'
    }
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
    $limitsForAlert = @((Get-Property $Snapshot 'rate_limit' $null), (Get-Property $Snapshot 'code_review_rate_limit' $null))
    foreach ($entry in @(Get-Property $Snapshot 'additional_rate_limits' @())) { $limitsForAlert += Get-Property $entry 'rate_limit' $null }
    foreach ($limitForAlert in $limitsForAlert) {
        if ($limitForAlert) {
            foreach ($windowName in @('primary_window', 'secondary_window')) {
                $window = Get-Property $limitForAlert $windowName $null
                if ($window) { $remainingValues += Get-RemainingPercent $window }
            }
        }
    }
    if ($alertPercent -gt 0 -and $remainingValues.Count -gt 0 -and ($remainingValues | Measure-Object -Minimum).Minimum -le $alertPercent) {
        Write-Output "Warning: Codex capacity is at or below the configured $alertPercent% alert threshold."
    }
    $resetCredits = [int] (Get-Property $Snapshot 'reset_credits_available' 0)
    if ($resetCredits -gt 0) { Write-Output "Rate-limit reset credits: $resetCredits" }
    $anyLimitReached = $false
    foreach ($limitForAlert in $limitsForAlert) {
        if ($limitForAlert -and [bool] (Get-Property $limitForAlert 'limit_reached' $false)) { $anyLimitReached = $true; break }
    }
    if ($anyLimitReached -or (Get-Property $Snapshot 'rate_limit_reached_type' $null)) {
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
    if (-not $Cached -and -not $Statusline) {
        Acquire-RefreshLock
        Refresh-UsageCache
    }
} catch {
    $refreshFailed = $true
    if ($RefreshCache) { [Console]::Error.WriteLine("usage-limit: $($_.Exception.Message)") }
} finally {
    if ($ownsRefreshLock -and (Test-Path -LiteralPath $refreshLock -PathType Container)) {
        if ($ownedRefreshToken) { [void] (Remove-OwnedRefreshGeneration $ownedRefreshToken) }
    }
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_USAGE_REFRESH_EXIT_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_USAGE_REFRESH_EXIT_FILE, "exited`n", $utf8)
    }
}

if ($RefreshCache) { if ($refreshFailed) { exit 1 } else { exit 0 } }
$snapshot = Read-Snapshot
if ($null -eq $snapshot) {
    if ($refreshFailed) { [Console]::Error.WriteLine('usage-limit: live refresh failed and no cached snapshot is available.') }
    else { [Console]::Error.WriteLine('usage-limit: no cached usage snapshot is available.') }
    exit 1
}
if ($refreshFailed) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lastSuccess = 0L
    if (Test-Path -LiteralPath $lastSuccessFile -PathType Leaf) {
        [long]::TryParse(([IO.File]::ReadAllText($lastSuccessFile).Trim()), [ref] $lastSuccess) | Out-Null
    }
    if ($lastSuccess -le 0 -or $lastSuccess -gt $now -or $now - $lastSuccess -gt $maxStaleSeconds) {
        [Console]::Error.WriteLine('usage-limit: live refresh failed and the cached snapshot is older than the configured maximum age.')
        exit 1
    }
    [Console]::Error.WriteLine('usage-limit: live refresh failed; showing the last cached snapshot.')
}

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
