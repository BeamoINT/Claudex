[CmdletBinding(DefaultParameterSetName = 'Check', PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Check')]
    [switch] $Check,

    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [switch] $Apply,

    [Parameter(Mandatory = $true, ParameterSetName = 'Status')]
    [switch] $Status,

    [Parameter(ParameterSetName = 'Check')]
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Status')]
    [switch] $Background
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Repository = 'BeamoINT/Claudex'
$script:ConfigDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$script:ReceiptPath = Join-Path $script:ConfigDir 'install.json'
$script:UpdateDir = Join-Path $script:ConfigDir 'update\claudex'
$script:StatePath = Join-Path $script:UpdateDir 'state.json'
$script:LockPath = Join-Path $script:UpdateDir 'lock'
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:LockToken = $null
$script:IsBackground = $Background -or $env:CLAUDEX_UPDATE_BACKGROUND -eq '1'
$script:AllowedDownloadHosts = @(
    'api.github.com',
    'github.com',
    'objects.githubusercontent.com',
    # GitHub currently serves release objects from this dedicated host. It is
    # kept exact (not a wildcard) for the same reason as the other allowlist
    # entries.
    'release-assets.githubusercontent.com'
)

function Write-Failure([string] $Message) {
    [Console]::Error.WriteLine("claudex self-update: $Message")
}

function Write-Notice([string] $Message) {
    if (-not $script:IsBackground) { [Console]::WriteLine($Message) }
}

function Get-UnixTime {
    return [long][Math]::Floor(([DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z').TotalSeconds)
}

function ConvertTo-StableVersion([string] $Value, [string] $Description) {
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "$Description is not a stable semantic version: $Value"
    }
    try {
        return [pscustomobject]@{
            Text = $Value
            Major = [uint64]::Parse($Matches[1])
            Minor = [uint64]::Parse($Matches[2])
            Patch = [uint64]::Parse($Matches[3])
        }
    } catch {
        throw "$Description contains an unsupported semantic-version component: $Value"
    }
}

function Compare-StableVersion($Left, $Right) {
    foreach ($field in @('Major', 'Minor', 'Patch')) {
        if ($Left.$field -lt $Right.$field) { return -1 }
        if ($Left.$field -gt $Right.$field) { return 1 }
    }
    return 0
}

function Read-JsonFile([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "invalid JSON in $Path"
    }
}

function Write-JsonAtomic([string] $Path, $Value) {
    $parent = Split-Path $Path -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = "$Path.tmp.$PID.$([guid]::NewGuid().ToString('N'))"
    $backup = "$Path.bak.$PID.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 20) + "`n"), $script:Utf8)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # Windows PowerShell 5.1 rejects a null backup path even though
            # newer .NET runtimes accept it. A same-directory backup keeps the
            # replace atomic across every supported PowerShell generation.
            [IO.File]::Replace($temporary, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Get-UpdateLockField([string] $OwnerFile, [string] $Field) {
    if (-not (Test-Path -LiteralPath $OwnerFile -PathType Leaf)) { return '' }
    try {
        foreach ($line in [IO.File]::ReadAllLines($OwnerFile)) {
            if ($line.StartsWith($Field + '=', [StringComparison]::Ordinal)) {
                return $line.Substring($Field.Length + 1)
            }
        }
    } catch { }
    return ''
}

function Get-UpdateLockGeneration([string] $Directory) {
    $path = Join-Path $Directory 'generation'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return [IO.File]::ReadAllText($path).Trim() } catch { return '' }
}

function Get-UpdateLockBarriers {
    if (-not (Test-Path -LiteralPath $script:UpdateDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:UpdateDir -Directory -Filter 'lock.quarantine.*' -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Get-UpdateLockAge([string] $Path) {
    try { return [Math]::Max(0, ([DateTime]::UtcNow - (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc).TotalSeconds) }
    catch { return 0 }
}

function Get-UpdateLockDirectoryIdentity([string] $Path) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if (-not ('Claudex.SelfUpdateDirectoryIdentity' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Claudex
{
    public static class SelfUpdateDirectoryIdentity
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public uint CreationTimeLow;
            public uint CreationTimeHigh;
            public uint LastAccessTimeLow;
            public uint LastAccessTimeHigh;
            public uint LastWriteTimeLow;
            public uint LastWriteTimeHigh;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
            uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file, out ByHandleFileInformation information);

        public static string GetIdentity(string path)
        {
            const uint OpenExisting = 3;
            const uint BackupSemantics = 0x02000000;
            const uint ShareReadWriteDelete = 0x00000001 | 0x00000002 | 0x00000004;
            try
            {
                using (SafeFileHandle handle = CreateFile(path, 0, ShareReadWriteDelete, IntPtr.Zero, OpenExisting, BackupSemantics, IntPtr.Zero))
                {
                    if (handle.IsInvalid) return "";
                    ByHandleFileInformation information;
                    if (!GetFileInformationByHandle(handle, out information)) return "";
                    return information.VolumeSerialNumber.ToString("x8") + ":" +
                        information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8");
                }
            }
            catch { return ""; }
        }
    }
}
'@
        }
        try { return [Claudex.SelfUpdateDirectoryIdentity]::GetIdentity($Path) }
        catch { return '' }
    }

    # PowerShell is also supported on Unix-like hosts. Use the filesystem object
    # identity there instead of a mutable timestamp when a native stat is present.
    $stat = Get-Command stat -ErrorAction SilentlyContinue
    if (-not $stat) { return '' }
    foreach ($arguments in @(@('-c', '%d:%i', '--', $Path), @('-f', '%d:%i', $Path))) {
        try {
            $result = @(& $stat.Source @arguments 2>$null)
            if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0 -and ([string] $result[0]).Trim() -match '^[0-9]+:[0-9]+$') {
                return ([string] $result[0]).Trim()
            }
        } catch { }
    }
    return ''
}

function Test-UpdateLockOwnerCurrent([string] $OwnerFile) {
    $ownerPid = 0
    if (-not [int]::TryParse((Get-UpdateLockField $OwnerFile 'pid'), [ref] $ownerPid) -or $ownerPid -le 0) { return $false }
    $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    $identity = Get-UpdateLockField $OwnerFile 'identity'
    if ([string]::IsNullOrWhiteSpace($identity)) { return $true }
    try { return $identity -eq [string] $process.StartTime.ToUniversalTime().Ticks }
    catch { return $true }
}

function Test-LegacyUpdateLockOwnerAlive([string] $Directory) {
    $legacyPath = Join-Path $Directory 'owner.json'
    if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { return $false }
    try {
        $legacy = Read-JsonFile $legacyPath
        $property = if ($null -ne $legacy) { $legacy.PSObject.Properties['pid'] } else { $null }
        $legacyPid = 0
        return $null -ne $property -and [int]::TryParse([string]$property.Value, [ref] $legacyPid) -and
            $legacyPid -gt 0 -and $null -ne (Get-Process -Id $legacyPid -ErrorAction SilentlyContinue)
    } catch { return $false }
}

function Test-LegacyUpdateLockOwnerValid([string] $Directory) {
    $legacyPath = Join-Path $Directory 'owner.json'
    if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { return $false }
    try {
        $legacy = Read-JsonFile $legacyPath
        $pidProperty = if ($null -ne $legacy) { $legacy.PSObject.Properties['pid'] } else { $null }
        $tokenProperty = if ($null -ne $legacy) { $legacy.PSObject.Properties['token'] } else { $null }
        $legacyPid = 0
        return $null -ne $pidProperty -and [int]::TryParse([string]$pidProperty.Value, [ref] $legacyPid) -and
            $legacyPid -gt 0 -and $null -ne $tokenProperty -and -not [string]::IsNullOrWhiteSpace([string]$tokenProperty.Value)
    } catch { return $false }
}

function Get-UpdateCompatibilityOwnerToken([string] $Directory) {
    $path = Join-Path $Directory 'owner.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try {
        $owner = Read-JsonFile $path
        $property = if ($null -ne $owner) { $owner.PSObject.Properties['token'] } else { $null }
        if ($null -ne $property) { return [string] $property.Value }
    } catch { }
    return ''
}

function Invoke-UpdateLockTestPause([string] $Stage) {
    if ($env:CLAUDEX_TEST_MODE -ne '1') { return }
    $ready = [Environment]::GetEnvironmentVariable("CLAUDEX_TEST_UPDATE_LOCK_${Stage}_READY", 'Process')
    $continue = [Environment]::GetEnvironmentVariable("CLAUDEX_TEST_UPDATE_LOCK_${Stage}_CONTINUE", 'Process')
    if (-not $ready -or -not $continue) { return }
    [IO.File]::WriteAllText($ready, "ready`n", $script:Utf8)
    while (-not (Test-Path -LiteralPath $continue -PathType Leaf)) { Start-Sleep -Milliseconds 20 }
}

function Remove-UpdateLockDirectory([string] $Directory) {
    Remove-Item -LiteralPath (Join-Path $Directory 'owner') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Directory 'owner.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Directory 'generation') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
}

function Publish-UpdateLockFile([string] $Source, [string] $Destination) {
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE -eq '1') {
        throw 'forced update lock publication failure'
    }
    if ($env:CLAUDEX_TEST_MODE -ne '1' -or $env:CLAUDEX_TEST_FORCE_HARDLINK_FAILURE -ne '1') {
        try {
            New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
            return
        } catch { }
    }
    $input = $null
    $output = $null
    try {
        $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $output = [IO.FileStream]::new($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $input.CopyTo($output)
        $output.Flush($true)
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
    }
}

function Restore-UpdateLockBarrier([string] $Barrier) {
    foreach ($attempt in 1..250) {
        if (-not (Test-Path -LiteralPath $script:LockPath)) {
            try { Move-Item -LiteralPath $Barrier -Destination $script:LockPath -ErrorAction Stop; return $true }
            catch { }
        }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

function Remove-IncompleteUpdateLock {
    if (-not (Test-Path -LiteralPath $script:LockPath -PathType Container)) { return $true }
    $quarantine = "$($script:LockPath).quarantine.incomplete.$PID.$([guid]::NewGuid().ToString('N'))"
    try { Move-Item -LiteralPath $script:LockPath -Destination $quarantine -ErrorAction Stop }
    catch { return $false }
    $generationNonce = Get-UpdateLockGeneration $quarantine
    $ownerNonce = Get-UpdateLockField (Join-Path $quarantine 'owner') 'nonce'
    if ($generationNonce -or $ownerNonce -or (Test-Path -LiteralPath (Join-Path $quarantine 'owner.json') -PathType Leaf)) {
        [void] (Restore-UpdateLockBarrier $quarantine)
        return $false
    }
    Remove-UpdateLockDirectory $quarantine
    return -not (Test-Path -LiteralPath $quarantine)
}

function Recover-UpdateLockBarriers {
    foreach ($barrierInfo in @(Get-UpdateLockBarriers)) {
        $barrier = $barrierInfo.FullName
        $ownerFile = Join-Path $barrier 'owner'
        $ownerNonce = Get-UpdateLockField $ownerFile 'nonce'
        $compatibilityToken = Get-UpdateCompatibilityOwnerToken $barrier
        $generationNonce = Get-UpdateLockGeneration $barrier
        $age = Get-UpdateLockAge $barrier
        if ($ownerNonce -and $compatibilityToken -eq $ownerNonce -and (Test-UpdateLockOwnerCurrent $ownerFile)) {
            if (-not (Test-Path -LiteralPath $script:LockPath)) {
                try { Move-Item -LiteralPath $barrier -Destination $script:LockPath -ErrorAction Stop } catch { }
            }
        } elseif (Test-LegacyUpdateLockOwnerAlive $barrier) {
            # A crashed new creator can leave its generation beside a live
            # prior owner.json record. Quarantine makes this exact cleanup safe.
            if ($generationNonce) { Remove-Item -LiteralPath (Join-Path $barrier 'generation') -Force -ErrorAction SilentlyContinue }
            if ($ownerNonce -and $ownerNonce -eq $generationNonce) {
                Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path -LiteralPath $script:LockPath)) {
                try { Move-Item -LiteralPath $barrier -Destination $script:LockPath -ErrorAction Stop } catch { }
            }
        } elseif ($ownerNonce -and (Test-UpdateLockOwnerCurrent $ownerFile)) {
            if (-not (Test-Path -LiteralPath $script:LockPath)) {
                try { Move-Item -LiteralPath $barrier -Destination $script:LockPath -ErrorAction Stop } catch { }
            }
        } elseif ($ownerNonce -and $age -ge 2) {
            Remove-UpdateLockDirectory $barrier
        } elseif ($generationNonce -and $age -ge 2) {
            Remove-UpdateLockDirectory $barrier
        } elseif (-not $generationNonce -and $age -ge 300 -and -not (Test-LegacyUpdateLockOwnerAlive $barrier)) {
            Remove-UpdateLockDirectory $barrier
        }
    }
}

function Remove-UpdateLockGeneration([string] $ExpectedNonce) {
    if ([string]::IsNullOrWhiteSpace($ExpectedNonce)) { return $false }
    $currentNonce = Get-UpdateLockGeneration $script:LockPath
    if (-not $currentNonce) { $currentNonce = Get-UpdateLockField (Join-Path $script:LockPath 'owner') 'nonce' }
    if ($currentNonce -ne $ExpectedNonce) { return $false }
    $quarantine = "$($script:LockPath).quarantine.$PID.$([guid]::NewGuid().ToString('N'))"
    Invoke-UpdateLockTestPause 'BEFORE_RENAME'
    try { Move-Item -LiteralPath $script:LockPath -Destination $quarantine -ErrorAction Stop }
    catch { return $false }
    Invoke-UpdateLockTestPause 'AFTER_RENAME'
    if (-not (Test-Path -LiteralPath $quarantine -PathType Container)) { return $false }
    $movedGeneration = Get-UpdateLockGeneration $quarantine
    $movedOwnerNonce = Get-UpdateLockField (Join-Path $quarantine 'owner') 'nonce'
    $compatibilityToken = Get-UpdateCompatibilityOwnerToken $quarantine
    if ($movedGeneration -eq $ExpectedNonce -and
            (Test-Path -LiteralPath (Join-Path $quarantine 'owner.json') -PathType Leaf) -and
            $compatibilityToken -ne $ExpectedNonce) {
        # A paused creator may resume in a replacement lock from the previous
        # release. Withdraw only A's injected generation and restore B intact.
        Remove-Item -LiteralPath (Join-Path $quarantine 'generation') -Force -ErrorAction SilentlyContinue
        if ($movedOwnerNonce -eq $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $quarantine 'owner') -Force -ErrorAction SilentlyContinue
        }
        [void] (Restore-UpdateLockBarrier $quarantine)
        return $false
    }
    if ($movedGeneration -eq $ExpectedNonce -and
            ([string]::IsNullOrWhiteSpace($movedOwnerNonce) -or $movedOwnerNonce -eq $ExpectedNonce) -and
            (-not $compatibilityToken -or $compatibilityToken -eq $ExpectedNonce)) {
        Remove-UpdateLockDirectory $quarantine
        return $true
    }
    [void] (Restore-UpdateLockBarrier $quarantine)
    return $false
}

function Recover-OwnedUpdateLock([string] $ExpectedNonce) {
    foreach ($barrierInfo in @(Get-UpdateLockBarriers)) {
        $barrier = $barrierInfo.FullName
        $movedNonce = Get-UpdateLockGeneration $barrier
        if (-not $movedNonce) { $movedNonce = Get-UpdateLockField (Join-Path $barrier 'owner') 'nonce' }
        if ($movedNonce -ne $ExpectedNonce) { continue }
        if ((Test-Path -LiteralPath (Join-Path $barrier 'owner.json') -PathType Leaf) -and
                (Get-UpdateCompatibilityOwnerToken $barrier) -ne $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $barrier 'generation') -Force -ErrorAction SilentlyContinue
            if ((Get-UpdateLockField (Join-Path $barrier 'owner') 'nonce') -eq $ExpectedNonce) {
                Remove-Item -LiteralPath (Join-Path $barrier 'owner') -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not (Test-Path -LiteralPath $script:LockPath)) {
            try { Move-Item -LiteralPath $barrier -Destination $script:LockPath -ErrorAction Stop } catch { }
        }
    }
    $currentNonce = Get-UpdateLockGeneration $script:LockPath
    if (-not $currentNonce) { $currentNonce = Get-UpdateLockField (Join-Path $script:LockPath 'owner') 'nonce' }
    if ((Test-Path -LiteralPath (Join-Path $script:LockPath 'owner.json') -PathType Leaf) -and
            (Get-UpdateCompatibilityOwnerToken $script:LockPath) -ne $ExpectedNonce) {
        if ($currentNonce -eq $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $script:LockPath 'generation') -Force -ErrorAction SilentlyContinue
            if ((Get-UpdateLockField (Join-Path $script:LockPath 'owner') 'nonce') -eq $ExpectedNonce) {
                Remove-Item -LiteralPath (Join-Path $script:LockPath 'owner') -Force -ErrorAction SilentlyContinue
            }
        }
        return $false
    }
    if ($currentNonce -eq $ExpectedNonce -and @(Get-UpdateLockBarriers).Count -eq 0) {
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_UPDATE_LOCK_SELF_RECOVERED_FILE) {
            [IO.File]::WriteAllText($env:CLAUDEX_TEST_UPDATE_LOCK_SELF_RECOVERED_FILE, "recovered`n", $script:Utf8)
        }
        return $true
    }
    if ($currentNonce -eq $ExpectedNonce) { [void] (Remove-UpdateLockGeneration $ExpectedNonce) }
    foreach ($barrierInfo in @(Get-UpdateLockBarriers)) {
        $barrier = $barrierInfo.FullName
        $movedNonce = Get-UpdateLockGeneration $barrier
        if (-not $movedNonce) { $movedNonce = Get-UpdateLockField (Join-Path $barrier 'owner') 'nonce' }
        if ($movedNonce -eq $ExpectedNonce) { Remove-UpdateLockDirectory $barrier }
    }
    return $false
}

function Acquire-UpdateLock {
    [IO.Directory]::CreateDirectory($script:UpdateDir) | Out-Null
    $ownerFile = Join-Path $script:LockPath 'owner'
    $attemptLimit = 100
    $testAttempts = 0
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and [int]::TryParse($env:CLAUDEX_TEST_UPDATE_LOCK_ATTEMPTS, [ref] $testAttempts) -and
            $testAttempts -ge 1 -and $testAttempts -le 100) { $attemptLimit = $testAttempts }
    for ($attempt = 0; $attempt -lt $attemptLimit; $attempt++) {
        Recover-UpdateLockBarriers
        if (@(Get-UpdateLockBarriers).Count -gt 0) { Start-Sleep -Milliseconds 20; continue }
        $created = $false
        $createdIdentity = ''
        $ownerTemporary = Join-Path $script:UpdateDir ('.lock-owner.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $generationTemporary = Join-Path $script:UpdateDir ('.lock-generation.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $compatibilityTemporary = Join-Path $script:UpdateDir ('.lock-compatibility-owner.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $nonce = [guid]::NewGuid().ToString('N')
        $identity = [string] (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
        [IO.File]::WriteAllText($ownerTemporary, "pid=$PID`nidentity=$identity`nnonce=$nonce`n", $script:Utf8)
        [IO.File]::WriteAllText($generationTemporary, "$nonce`n", $script:Utf8)
        $compatibilityOwner = [ordered]@{ pid = $PID; token = $nonce; startedAt = [DateTimeOffset]::UtcNow.ToString('o') }
        [IO.File]::WriteAllText($compatibilityTemporary, (($compatibilityOwner | ConvertTo-Json -Compress) + "`n"), $script:Utf8)
        try {
            New-Item -ItemType Directory -Path $script:LockPath -ErrorAction Stop | Out-Null
            $created = $true
            $createdIdentity = Get-UpdateLockDirectoryIdentity $script:LockPath
            Invoke-UpdateLockTestPause 'AFTER_MKDIR'
            if (-not $createdIdentity -or (Get-UpdateLockDirectoryIdentity $script:LockPath) -ne $createdIdentity) {
                throw 'update lock directory changed during publication'
            }
            if (Test-Path -LiteralPath (Join-Path $script:LockPath 'owner.json') -PathType Leaf) {
                throw 'legacy update lock owner appeared during publication'
            }
            Publish-UpdateLockFile $generationTemporary (Join-Path $script:LockPath 'generation')
            if ((Get-UpdateLockDirectoryIdentity $script:LockPath) -ne $createdIdentity -or
                    (Get-UpdateLockGeneration $script:LockPath) -ne $nonce) { throw 'update lock generation publication changed' }
            Publish-UpdateLockFile $ownerTemporary $ownerFile
            Publish-UpdateLockFile $compatibilityTemporary (Join-Path $script:LockPath 'owner.json')
            if ((Get-UpdateLockDirectoryIdentity $script:LockPath) -ne $createdIdentity -or
                    (Get-UpdateLockField $ownerFile 'nonce') -ne $nonce -or
                    (Get-UpdateCompatibilityOwnerToken $script:LockPath) -ne $nonce -or
                    @(Get-UpdateLockBarriers).Count -gt 0) {
                throw 'update lock ownership publication changed'
            }
            Remove-Item -LiteralPath $ownerTemporary, $generationTemporary, $compatibilityTemporary -Force -ErrorAction SilentlyContinue
            $script:LockToken = $nonce
            Invoke-UpdateLockTestPause 'AFTER_PUBLISH'
            if ((Get-UpdateLockDirectoryIdentity $script:LockPath) -ne $createdIdentity -or
                    (Get-UpdateLockGeneration $script:LockPath) -ne $nonce -or
                    (Get-UpdateCompatibilityOwnerToken $script:LockPath) -ne $nonce -or
                    @(Get-UpdateLockBarriers).Count -gt 0) {
                if (Recover-OwnedUpdateLock $nonce) { return }
                $script:LockToken = $null
                Start-Sleep -Milliseconds 20
                continue
            }
            return
        } catch {
            if ($created -and $createdIdentity -and
                    (Get-UpdateLockDirectoryIdentity $script:LockPath) -eq $createdIdentity) {
                if (-not (Remove-UpdateLockGeneration $nonce)) { [void] (Remove-IncompleteUpdateLock) }
            }
        } finally {
            Remove-Item -LiteralPath $ownerTemporary, $generationTemporary, $compatibilityTemporary -Force -ErrorAction SilentlyContinue
        }
        $age = Get-UpdateLockAge $script:LockPath
        $observedNonce = Get-UpdateLockField $ownerFile 'nonce'
        if ($observedNonce) {
            if ($age -ge 2 -and -not (Test-UpdateLockOwnerCurrent $ownerFile)) { [void] (Remove-UpdateLockGeneration $observedNonce) }
        } elseif ((Get-UpdateLockGeneration $script:LockPath) -and $age -ge 2) {
            [void] (Remove-UpdateLockGeneration (Get-UpdateLockGeneration $script:LockPath))
        } elseif ($age -ge 300 -and -not (Test-LegacyUpdateLockOwnerAlive $script:LockPath) -and
                (Test-Path -LiteralPath $script:LockPath -PathType Container)) {
            $legacy = "$($script:LockPath).quarantine.legacy.$PID.$([guid]::NewGuid().ToString('N'))"
            try { Move-Item -LiteralPath $script:LockPath -Destination $legacy -ErrorAction Stop }
            catch { $legacy = '' }
            if ($legacy) {
                if ((Get-UpdateLockGeneration $legacy) -or (Get-UpdateLockField (Join-Path $legacy 'owner') 'nonce')) {
                    [void] (Restore-UpdateLockBarrier $legacy)
                } else { Remove-UpdateLockDirectory $legacy }
            }
        }
        Start-Sleep -Milliseconds 20
    }
    throw 'timed out waiting for another Claudex update operation'
}

function Release-UpdateLock {
    $nonce = $script:LockToken
    if (-not $nonce) { return }
    [void] (Remove-UpdateLockGeneration $nonce)
    $script:LockToken = $null
}

function Assert-AllowedUri([Uri] $Uri) {
    if ($Uri.Scheme -ne 'https') { throw "refusing non-HTTPS update URL: $Uri" }
    if ($Uri.IsDefaultPort -eq $false -and $Uri.Port -ne 443) { throw "refusing non-standard update URL port: $Uri" }
    if ($Uri.UserInfo) { throw "refusing update URL containing credentials: $Uri" }
    if ($Uri.Host.ToLowerInvariant() -notin $script:AllowedDownloadHosts) {
        throw "refusing update URL outside the GitHub allowlist: $($Uri.Host)"
    }
}

function Receive-HttpsFile(
    [Uri] $Uri,
    [string] $Destination,
    [long] $MaximumBytes,
    [int] $TimeoutSeconds,
    [string] $Accept = 'application/octet-stream'
) {
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_UPDATE_FIXTURE_DIR) {
        Assert-AllowedUri $Uri
        $leaf = [IO.Path]::GetFileName($Uri.AbsolutePath)
        if ($leaf -eq 'latest') { $leaf = 'latest.json' }
        $source = Join-Path $env:CLAUDEX_TEST_UPDATE_FIXTURE_DIR $leaf
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "update test fixture is missing $leaf" }
        if ((Get-Item -LiteralPath $source).Length -gt $MaximumBytes) { throw "update download exceeds the $MaximumBytes byte limit" }
        Copy-Item -LiteralPath $source -Destination $Destination -ErrorAction Stop
        return
    }
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $current = $Uri
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        Assert-AllowedUri $current
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $client = New-Object Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $current)
        $cancellation = New-Object Threading.CancellationTokenSource
        $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
        [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'Claudex-Self-Updater/1')
        [void]$request.Headers.TryAddWithoutValidation('Accept', $Accept)
        # Never forward an API credential to a release-object redirect host.
        if ($env:GITHUB_TOKEN -and $current.Host -eq 'api.github.com') {
            [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($env:GITHUB_TOKEN)")
        }
        $response = $null
        try {
            $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -in @(301, 302, 303, 307, 308)) {
                if ($redirect -eq 5 -or $null -eq $response.Headers.Location) { throw 'too many or invalid update download redirects' }
                $current = [Uri]::new($current, $response.Headers.Location)
                continue
            }
            if (-not $response.IsSuccessStatusCode) { throw "GitHub returned HTTP $statusCode for $current" }
            if ($response.Content.Headers.ContentLength -and [long]$response.Content.Headers.ContentLength -gt $MaximumBytes) {
                throw "update download exceeds the $MaximumBytes byte limit"
            }
            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = $null
            try {
                $outputStream = New-Object IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $buffer = New-Object byte[] 65536
                [long]$total = 0
                while (($read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                    $total += $read
                    if ($total -gt $MaximumBytes) { throw "update download exceeds the $MaximumBytes byte limit" }
                    $outputStream.Write($buffer, 0, $read)
                }
                $outputStream.Flush()
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $inputStream) { $inputStream.Dispose() }
            }
            return
        } finally {
            if ($null -ne $response) { $response.Dispose() }
            $cancellation.Dispose()
            $request.Dispose()
            $client.Dispose()
            $handler.Dispose()
        }
    }
    throw 'too many update download redirects'
}

function Get-Receipt {
    $receipt = Read-JsonFile $script:ReceiptPath
    if ($null -eq $receipt) { throw "installation receipt is missing: $($script:ReceiptPath)" }
    $repository = Get-PropertyValue $receipt @('repository')
    if ([string]$repository -cne $script:Repository) { throw 'installation receipt names an untrusted release repository' }
    $binDir = Get-PropertyValue $receipt @('binDir')
    if ([string]::IsNullOrWhiteSpace([string]$binDir) -or -not [IO.Path]::IsPathRooted([string]$binDir)) {
        throw 'installation receipt does not contain a valid absolute launcher directory'
    }
    return $receipt
}

function Get-PropertyValue($Object, [string[]] $Names) {
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $property.Value }
    }
    return $null
}

function Get-InstalledVersion($Receipt) {
    $value = Get-PropertyValue $Receipt @('version', 'currentVersion', 'installedVersion')
    if ($null -eq $value) { throw 'installation receipt does not contain an installed version' }
    return ConvertTo-StableVersion ([string]$value) 'installed version'
}

function Get-ReceiptManager($Receipt) {
    $candidate = Get-PropertyValue $Receipt @('packageManager', 'manager', 'installMethod', 'method', 'distribution')
    if ($candidate -isnot [string]) {
        $candidate = Get-PropertyValue $candidate @('manager', 'type', 'name')
    }
    if ($null -eq $candidate) { throw 'installation receipt does not contain an install method' }
    switch -Regex (([string]$candidate).Trim().ToLowerInvariant()) {
        '^(brew|homebrew)$' { return 'homebrew' }
        '^scoop$' { return 'scoop' }
        '^(winget|windows-package-manager)$' { return 'winget' }
        '^(archive|git|source|direct|release)$' { return 'archive' }
        default { throw "unsupported install method in receipt: $candidate" }
    }
}

function Get-LatestRelease {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('claudex-release-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Receive-HttpsFile ([Uri]"https://api.github.com/repos/$($script:Repository)/releases/latest") $temporary 2097152 20 'application/vnd.github+json'
        $release = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $release -or $release.draft -eq $true -or $release.prerelease -eq $true) {
        throw 'GitHub latest release is not a published stable release'
    }
    $tag = [string]$release.tag_name
    if ($tag.StartsWith('v')) { $tag = $tag.Substring(1) }
    $version = ConvertTo-StableVersion $tag 'latest release tag'
    $zipName = "claudex-$($version.Text)-windows.zip"
    $requiredNames = @($zipName, 'SHA256SUMS')
    $assetMap = @{}
    foreach ($asset in @($release.assets)) {
        $name = [string]$asset.name
        if ($name -in $requiredNames) {
            if ($assetMap.ContainsKey($name)) { throw "release contains duplicate asset: $name" }
            $assetUri = [Uri]([string]$asset.url)
            Assert-AllowedUri $assetUri
            if ($assetUri.Host -ne 'api.github.com') { throw "release asset API URL has an unexpected host: $assetUri" }
            $assetMap[$name] = $assetUri
        }
    }
    foreach ($name in $requiredNames) {
        if (-not $assetMap.ContainsKey($name)) { throw "release is missing required asset: $name" }
    }
    return [pscustomobject]@{
        Version = $version
        ZipName = $zipName
        ZipUri = $assetMap[$zipName]
        ChecksumsUri = $assetMap['SHA256SUMS']
        PublishedAt = [string]$release.published_at
    }
}

function New-State($OldState, [hashtable] $Changes) {
    $result = [ordered]@{}
    if ($null -ne $OldState) {
        foreach ($property in $OldState.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    foreach ($name in $Changes.Keys) { $result[$name] = $Changes[$name] }
    return $result
}

function Record-CheckSuccess($State, $CurrentVersion, $Release) {
    $now = Get-UnixTime
    $interval = 86400
    if ($env:CLAUDEX_UPDATE_INTERVAL_SECONDS) {
        $parsed = 0
        if (-not [int]::TryParse($env:CLAUDEX_UPDATE_INTERVAL_SECONDS, [ref]$parsed) -or $parsed -lt 3600 -or $parsed -gt 2592000) {
            throw 'CLAUDEX_UPDATE_INTERVAL_SECONDS must be from 3600 to 2592000'
        }
        $interval = $parsed
    }
    Write-JsonAtomic $script:StatePath (New-State $State @{
        schemaVersion = 1
        currentVersion = $CurrentVersion.Text
        latestVersion = $Release.Version.Text
        lastCheckAt = $now
        nextCheckAt = $now + $interval
        consecutiveFailures = 0
        lastError = $null
    })
}

function Record-CheckFailure($State, [string] $Message) {
    $now = Get-UnixTime
    $failures = 1
    $failureProperty = if ($null -ne $State) { $State.PSObject.Properties['consecutiveFailures'] } else { $null }
    if ($null -ne $failureProperty) {
        [void][int]::TryParse([string]$failureProperty.Value, [ref]$failures)
        $failures = [Math]::Min(16, [Math]::Max(0, $failures) + 1)
    }
    $power = [Math]::Min(5, $failures - 1)
    $delay = [Math]::Min(86400, 3600 * [Math]::Pow(2, $power)) + (Get-Random -Minimum 0 -Maximum 301)
    Write-JsonAtomic $script:StatePath (New-State $State @{
        schemaVersion = 1
        lastCheckAt = $now
        nextCheckAt = $now + [int]$delay
        consecutiveFailures = $failures
        lastError = $Message
    })
}

function Test-BackgroundCheckDeferred($State) {
    if (-not $script:IsBackground -or $null -eq $State) { return $false }
    $nextProperty = $State.PSObject.Properties['nextCheckAt']
    if ($null -eq $nextProperty) { return $false }
    [long]$next = 0
    return [long]::TryParse([string]$nextProperty.Value, [ref]$next) -and $next -gt (Get-UnixTime)
}

function Get-ExpectedChecksum([string] $ChecksumPath, [string] $AssetName) {
    $escaped = [regex]::Escape($AssetName)
    $matches = [regex]::Matches([IO.File]::ReadAllText($ChecksumPath), "(?m)^([0-9A-Fa-f]{64})[ `t]+[*]?$escaped`r?$")
    if ($matches.Count -ne 1) { throw "SHA256SUMS must contain exactly one checksum for $AssetName" }
    return $matches[0].Groups[1].Value.ToLowerInvariant()
}

function Assert-SafeZip([string] $Archive, [string] $ExpectedRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -lt 1 -or $zip.Entries.Count -gt 10000) { throw 'release archive has an unsafe entry count' }
        [long]$expandedBytes = 0
        $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name -or $name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains([char]0) -or $name -match '^[A-Za-z]:' -or $name.Contains(':')) {
                throw "release archive contains an unsafe path: $name"
            }
            $segments = @($name.TrimEnd('/').Split('/'))
            if ($segments.Count -lt 1 -or $segments[0] -cne $ExpectedRoot -or $segments -contains '' -or $segments -contains '..' -or $segments -contains '.') {
                throw "release archive escapes its expected root: $name"
            }
            foreach ($segment in $segments) {
                if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) { throw "release archive contains a Windows-ambiguous path: $name" }
                $deviceStem = $segment.Split('.')[0]
                if ($deviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw "release archive contains a reserved Windows path: $name" }
            }
            $collisionKey = $name.TrimEnd('/')
            if (-not $seenPaths.Add($collisionKey)) { throw "release archive contains a duplicate or case-colliding path: $name" }
            [uint32]$attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            $unixType = (($attributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) { throw "release archive contains a symbolic link: $name" }
            if ($unixType -notin @(0, 0x4000, 0x8000)) { throw "release archive contains an unsupported Unix file type: $name" }
            $expandedBytes += [long]$entry.Length
            if ($expandedBytes -gt 1073741824) { throw 'release archive expands beyond the 1 GiB safety limit' }
        }
    } finally {
        $zip.Dispose()
    }
}

function ConvertTo-NativeArgument([string] $Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            if ($slashes) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-CmdArgument([string] $Value) {
    if ($null -eq $Value) { $Value = '' }
    # Preserve ordinary batch arguments exactly as direct invocation would;
    # some portable shims compare %1 rather than %~1. Values outside this
    # deliberately narrow safe alphabet remain quoted, with percent expansion
    # neutralized and delayed expansion disabled by the caller.
    if ($Value -match '^[A-Za-z0-9_@.+,=/:\-]+$') { return $Value }
    return '"' + $Value.Replace('%', '%%').Replace('"', '""') + '"'
}

function Invoke-BoundedProcess([string] $Executable, [string[]] $Arguments, [int] $TimeoutSeconds, [switch] $CaptureOutput) {
    $nativeArguments = @($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string] $_) })
    $argumentLine = $nativeArguments -join ' '
    $fileName = $Executable
    if ([IO.Path]::GetExtension($Executable) -in @('.cmd', '.bat')) {
        $fileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $cmdArguments = @($Arguments | ForEach-Object { ConvertTo-CmdArgument ([string] $_) }) -join ' '
        $inner = (ConvertTo-CmdArgument $Executable) + $(if ($cmdArguments) { " $cmdArguments" } else { '' })
        # cmd /S requires one additional pair of quotes around a command whose
        # executable path is itself quoted.
        $argumentLine = '/d /s /v:off /c "' + $inner + '"'
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $fileName
    $startInfo.Arguments = $argumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'update command could not be started' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            if ($env:OS -eq 'Windows_NT') {
                try { & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F *> $null } catch { }
            }
            try { $process.Kill() } catch { }
            throw "update command timed out after $TimeoutSeconds seconds"
        }
        $process.WaitForExit()
        $output = $stdoutTask.GetAwaiter().GetResult()
        $errorOutput = $stderrTask.GetAwaiter().GetResult()
        if (-not $CaptureOutput -and -not $script:IsBackground -and $output) { [Console]::Out.Write($output) }
        if (-not $CaptureOutput -and -not $script:IsBackground -and $errorOutput) { [Console]::Error.Write($errorOutput) }
        if ($process.ExitCode -ne 0) { throw "update command exited with code $($process.ExitCode)" }
        if ($CaptureOutput) { return $output.Trim() }
    } finally {
        $process.Dispose()
    }
}

function Test-PathWithin([string] $Path, [string] $Directory) {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    $comparison = if ($env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullDirectory, $comparison) -or
        $fullPath.StartsWith(($fullDirectory + [IO.Path]::DirectorySeparatorChar), $comparison)
}

function Find-ManagerWrapper($Receipt) {
    $excluded = @(
        [string](Get-PropertyValue $Receipt @('binDir')),
        (Join-Path $script:ConfigDir 'package-bin')
    )
    foreach ($command in @(Get-Command claudex -All -ErrorAction SilentlyContinue)) {
        $source = [string]$command.Source
        if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $isExcluded = $false
        foreach ($directory in $excluded) { if ($directory -and (Test-PathWithin $source $directory)) { $isExcluded = $true; break } }
        if (-not $isExcluded) { return $source }
    }
    throw 'the package manager completed but its public Claudex wrapper was not found in PATH'
}

function Invoke-PackageWrapper([string] $Wrapper, [string[]] $Arguments, [switch] $CaptureOutput) {
    if ([IO.Path]::GetExtension($Wrapper) -eq '.ps1') {
        $powerShell = if (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) { (Get-Command pwsh -CommandType Application).Source } else { (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source }
        $allArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Wrapper) + $Arguments
        return Invoke-BoundedProcess $powerShell $allArguments 600 -CaptureOutput:$CaptureOutput
    }
    return Invoke-BoundedProcess $Wrapper $Arguments 600 -CaptureOutput:$CaptureOutput
}

function Get-NativeCommand([string[]] $Names) {
    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    return $null
}

function Get-PowerShellScriptCommand([string] $Name) {
    $command = Get-Command $Name -CommandType ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and [IO.Path]::GetExtension($command.Source) -eq '.ps1') { return $command.Source }
    return $null
}

function Get-ManagerPackage($Receipt, [string] $Default) {
    $candidate = Get-PropertyValue $Receipt @('packageName', 'formula', 'bucketPackage', 'wingetId', 'id')
    $packageProperty = $Receipt.PSObject.Properties['package']
    if ($null -eq $candidate -and $null -ne $packageProperty) {
        if ($packageProperty.Value -is [string]) { $candidate = $packageProperty.Value }
        else { $candidate = Get-PropertyValue $packageProperty.Value @('name', 'id') }
    }
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { return $Default }
    $candidate = [string]$candidate
    if ($candidate -notmatch '^[A-Za-z0-9@._/+:-]+$') { throw 'installation receipt contains an unsafe package name' }
    return $candidate
}

function Invoke-ManagerUpdate([string] $Manager, $Receipt, $Release) {
    switch ($Manager) {
        'homebrew' {
            $command = Get-NativeCommand @('brew.exe', 'brew')
            if (-not $command) { throw 'Homebrew-managed install cannot update because brew is not in PATH' }
            $formula = Get-ManagerPackage $Receipt 'beamoint/tap/claudex'
            Invoke-BoundedProcess $command @('upgrade', $formula) 900
        }
        'scoop' {
            $command = Get-NativeCommand @('scoop.cmd', 'scoop.exe', 'scoop')
            $scriptCommand = if (-not $command) { Get-PowerShellScriptCommand 'scoop' } else { $null }
            if (-not $command -and -not $scriptCommand) { throw 'Scoop-managed install cannot update because scoop is not in PATH' }
            $package = Get-ManagerPackage $Receipt 'claudex'
            if ($command) { Invoke-BoundedProcess $command @('update', $package) 900 }
            else { Invoke-PackageWrapper $scriptCommand @('update', $package) }
        }
        'winget' {
            $command = Get-NativeCommand @('winget.exe', 'winget')
            if (-not $command) { throw 'WinGet-managed install cannot update because winget is not in PATH' }
            $identifier = Get-ManagerPackage $Receipt 'BeamoINT.Claudex'
            Invoke-BoundedProcess $command @('upgrade', '--id', $identifier, '--exact', '--version', $Release.Version.Text, '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity') 900
        }
        default { throw "unsupported package manager: $Manager" }
    }
    $wrapper = Find-ManagerWrapper $Receipt
    $installedText = Invoke-PackageWrapper $wrapper @('--package-version') -CaptureOutput
    $installedPackageVersion = ConvertTo-StableVersion $installedText 'package-manager wrapper version'
    if ((Compare-StableVersion $installedPackageVersion $Release.Version) -ne 0) {
        throw "package manager installed $($installedPackageVersion.Text), expected $($Release.Version.Text)"
    }
    Invoke-PackageWrapper $wrapper @('--package-setup')
    $updatedReceipt = Get-Receipt
    $installedReceiptVersion = Get-InstalledVersion $updatedReceipt
    if ((Compare-StableVersion $installedReceiptVersion $Release.Version) -ne 0) {
        throw "package setup receipt reports $($installedReceiptVersion.Text), expected $($Release.Version.Text)"
    }
}

function Invoke-ArchiveUpdate($Receipt, $Release) {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('claudex-update-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    try {
        $archive = Join-Path $temporary $Release.ZipName
        $checksums = Join-Path $temporary 'SHA256SUMS'
        Receive-HttpsFile $Release.ChecksumsUri $checksums 1048576 30
        Receive-HttpsFile $Release.ZipUri $archive 536870912 180
        $expected = Get-ExpectedChecksum $checksums $Release.ZipName
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "checksum mismatch for $($Release.ZipName)" }
        $rootName = "claudex-$($Release.Version.Text)"
        Assert-SafeZip $archive $rootName
        $stage = Join-Path $temporary 'stage'
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $stage
        $stagedRoot = Join-Path $stage $rootName
        $installer = Join-Path $stagedRoot 'install.ps1'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'verified release archive does not contain install.ps1' }
        if (-not (Test-Path -LiteralPath (Join-Path $stagedRoot 'skill-bridge.cjs') -PathType Leaf)) {
            throw 'verified release archive does not contain skill-bridge.cjs'
        }
        $children = @(Get-ChildItem -LiteralPath $stage -Force)
        if ($children.Count -ne 1 -or -not $children[0].PSIsContainer -or $children[0].Name -ne $rootName) {
            throw 'verified release archive has an unexpected top-level layout'
        }
        foreach ($stagedItem in @(Get-ChildItem -LiteralPath $stagedRoot -Recurse -Force)) {
            if (($stagedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "verified release archive created a reparse point: $($stagedItem.FullName)"
            }
        }
        $manifestPath = Join-Path $stagedRoot 'package.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'verified release archive does not contain package.json' }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ([string]$manifest.version -cne $Release.Version.Text) { throw 'release archive version does not match its release tag' }
        $powerShell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { (Get-Command powershell.exe -ErrorAction Stop).Source }
        $binDir = [string](Get-PropertyValue $Receipt @('binDir'))
        $managedPaths = @(
            (Join-Path $binDir 'claudex.ps1'),
            (Join-Path $binDir 'claudex.cmd'),
            (Join-Path $script:ConfigDir 'env'),
            (Join-Path $script:ConfigDir 'cliproxyapi.yaml'),
            (Join-Path $script:ConfigDir 'settings.json'),
            (Join-Path $script:ConfigDir 'statusline.ps1'),
            (Join-Path $script:ConfigDir 'usage-limit.ps1'),
            (Join-Path $script:ConfigDir 'codex-session.ps1'),
            (Join-Path $script:ConfigDir 'preload.cjs'),
            (Join-Path $script:ConfigDir 'skill-bridge.cjs'),
            (Join-Path $script:ConfigDir 'self-update.ps1'),
            (Join-Path $script:ConfigDir 'skills\usage-limit\SKILL.md'),
            $script:ReceiptPath
        )
        $rollbackRoot = Join-Path $temporary 'rollback'
        [IO.Directory]::CreateDirectory($rollbackRoot) | Out-Null
        $rollbackEntries = @()
        $rollbackIndex = 0
        foreach ($managedPath in $managedPaths) {
            $backupPath = Join-Path $rollbackRoot ([string]$rollbackIndex)
            $existed = Test-Path -LiteralPath $managedPath -PathType Leaf
            if ($existed) { Copy-Item -LiteralPath $managedPath -Destination $backupPath -Force }
            $rollbackEntries += [pscustomobject]@{ Path = $managedPath; Backup = $backupPath; Existed = $existed }
            $rollbackIndex++
        }
        # The child inherits every caller-provided variable; these scoped
        # overrides merely select the installer's noninteractive update path.
        # Archive updates remain barred from changing unrelated dependencies,
        # but may install or upgrade Node for the newly required skill bridge.
        $updateEnvironment = @{
            CLAUDEX_INSTALL_METHOD = 'archive'
            CLAUDEX_BIN_DIR = $binDir
            CLAUDEX_SKIP_DEPENDENCY_INSTALL = '1'
            CLAUDEX_ALLOW_NODE_INSTALL = '1'
            CLAUDEX_SKIP_SERVICE_START = '1'
            CLAUDEX_SKIP_CLAUDE_UPDATE = '1'
        }
        $savedEnvironment = @{}
        foreach ($name in $updateEnvironment.Keys) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $updateEnvironment[$name], 'Process')
        }
        try {
            try {
                Invoke-BoundedProcess $powerShell @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer) 1200
                $updatedReceipt = Get-Receipt
                $installedReceiptVersion = Get-InstalledVersion $updatedReceipt
                if ((Compare-StableVersion $installedReceiptVersion $Release.Version) -ne 0) {
                    throw "installer receipt reports $($installedReceiptVersion.Text), expected $($Release.Version.Text)"
                }
            } catch {
                $installError = $_.Exception.Message
                $rollbackErrors = @()
                foreach ($entry in $rollbackEntries) {
                    try {
                        if ($entry.Existed) {
                            [IO.Directory]::CreateDirectory((Split-Path $entry.Path -Parent)) | Out-Null
                            Copy-Item -LiteralPath $entry.Backup -Destination $entry.Path -Force
                        } else {
                            Remove-Item -LiteralPath $entry.Path -Force -ErrorAction SilentlyContinue
                        }
                    } catch { $rollbackErrors += $_.Exception.Message }
                }
                if ($rollbackErrors.Count -gt 0) { throw "$installError; rollback was incomplete: $($rollbackErrors -join '; ')" }
                throw "$installError; restored the previous managed installation"
            }
        } finally {
            foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Check {
    Acquire-UpdateLock
    try {
        $state = $null
        try { $state = Read-JsonFile $script:StatePath } catch { $state = $null }
        if (Test-BackgroundCheckDeferred $state) { return }
        try {
            $receipt = Get-Receipt
            $current = Get-InstalledVersion $receipt
            $release = Get-LatestRelease
            if ((Compare-StableVersion $release.Version $current) -lt 0) { throw 'latest release is older than the installed version; refusing downgrade' }
            Record-CheckSuccess $state $current $release
            if ((Compare-StableVersion $release.Version $current) -gt 0) {
                Write-Notice "Claudex $($release.Version.Text) is available (installed: $($current.Text))."
            }
        } catch {
            # Checks are deliberately quiet while offline or while GitHub is
            # unavailable. The diagnostic and retry deadline remain available
            # through --status without producing a recurring red startup error.
            try { Record-CheckFailure $state $_.Exception.Message } catch { }
            if (-not $script:IsBackground) { throw }
        }
    } finally {
        Release-UpdateLock
    }
}

function Invoke-Apply {
    Acquire-UpdateLock
    try {
        $state = $null
        try { $state = Read-JsonFile $script:StatePath } catch { $state = $null }
        if (Test-BackgroundCheckDeferred $state) { return }
        try {
            $receipt = Get-Receipt
            $current = Get-InstalledVersion $receipt
            $release = Get-LatestRelease
            $comparison = Compare-StableVersion $release.Version $current
            if ($comparison -lt 0) { throw 'latest release is older than the installed version; refusing downgrade' }
            if ($comparison -eq 0) {
                Record-CheckSuccess $state $current $release
                Write-Notice "Claudex $($current.Text) is already current."
                return
            }
            $manager = Get-ReceiptManager $receipt
            if ($manager -in @('homebrew', 'scoop', 'winget')) {
                Invoke-ManagerUpdate $manager $receipt $release
            } else {
                Invoke-ArchiveUpdate $receipt $release
            }
            Record-CheckSuccess $state $release.Version $release
            $newState = Read-JsonFile $script:StatePath
            Write-JsonAtomic $script:StatePath (New-State $newState @{
                lastAppliedAt = Get-UnixTime
                lastAppliedVersion = $release.Version.Text
            })
            Write-Notice "Updated Claudex to $($release.Version.Text)."
        } catch {
            try { Record-CheckFailure $state $_.Exception.Message } catch { }
            throw
        }
    } finally {
        Release-UpdateLock
    }
}

function Show-Status {
    $receipt = $null
    $state = $null
    try { $receipt = Read-JsonFile $script:ReceiptPath } catch { }
    try { $state = Read-JsonFile $script:StatePath } catch { }
    $installed = if ($null -ne $receipt) { Get-PropertyValue $receipt @('version', 'currentVersion', 'installedVersion') } else { $null }
    $manager = if ($null -ne $receipt) { Get-ReceiptManager $receipt } else { 'unknown' }
    $latest = Get-PropertyValue $state @('latestVersion')
    $lastCheck = Get-PropertyValue $state @('lastCheckAt')
    $nextCheck = Get-PropertyValue $state @('nextCheckAt')
    $lastError = Get-PropertyValue $state @('lastError')
    [Console]::WriteLine("Installed version: $(if ($installed) { $installed } else { 'unknown' })")
    [Console]::WriteLine("Install method: $manager")
    [Console]::WriteLine("Latest known version: $(if ($latest) { $latest } else { 'unknown' })")
    [Console]::WriteLine("Last check: $(if ($lastCheck) { $lastCheck } else { 'never' })")
    [Console]::WriteLine("Next check: $(if ($nextCheck) { $nextCheck } else { 'now' })")
    if ($lastError) { [Console]::WriteLine("Last check error: $lastError") }
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Check' { Invoke-Check }
        'Apply' { Invoke-Apply }
        'Status' { Show-Status }
        default { throw 'specify exactly one of --check, --apply, or --status' }
    }
} catch {
    if ($script:IsBackground) { exit 0 }
    Write-Failure $_.Exception.Message
    exit 1
}
