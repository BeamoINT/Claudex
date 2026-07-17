param(
    [ValidateSet('sync', 'watch', 'login', 'logout', 'status')]
    [string] $Action = 'sync',
    [int] $ParentProcessId = 0,
    [string] $ParentProcessIdentity = '',
    [switch] $BackgroundWatch
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
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

namespace Claudex
{
    public static class CredentialSyncCleanup
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

        public static string GetDirectoryIdentity(string path)
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

        private static string ReadNonce(string directory)
        {
            try
            {
                string generation = Path.Combine(directory, "generation");
                if (File.Exists(generation))
                {
                    string value = File.ReadAllText(generation).Trim();
                    if (!String.IsNullOrEmpty(value)) return value;
                }
                string owner = Path.Combine(directory, "owner");
                if (!File.Exists(owner)) return "";
                foreach (string line in File.ReadAllLines(owner))
                {
                    if (line.StartsWith("nonce=", StringComparison.Ordinal)) return line.Substring(6);
                }
            }
            catch { }
            return "";
        }

        private static void ReleaseExactGeneration(string path, string nonce)
        {
            if (String.IsNullOrEmpty(path) || String.IsNullOrEmpty(nonce)) return;
            if (!String.Equals(ReadNonce(path), nonce, StringComparison.Ordinal)) return;
            string quarantine = path + ".quarantine.exit." + Guid.NewGuid().ToString("N");
            try { Directory.Move(path, quarantine); } catch { return; }
            string movedNonce = ReadNonce(quarantine);
            if (String.Equals(movedNonce, nonce, StringComparison.Ordinal))
            {
                try { File.Delete(Path.Combine(quarantine, "owner")); } catch { }
                try { File.Delete(Path.Combine(quarantine, "generation")); } catch { }
                try { Directory.Delete(quarantine, false); } catch { }
                return;
            }
            // Never delete a generation that replaced the exiting process. The
            // quarantine sibling remains an acquisition barrier until the moved
            // generation is restored or recovered by a later contender.
            try { if (!Directory.Exists(path)) Directory.Move(quarantine, path); } catch { }
        }

        public static void Cleanup()
        {
            lock (Gate)
            {
                if (!String.IsNullOrEmpty(temporaryPath))
                {
                    try { File.Delete(temporaryPath); } catch { }
                    temporaryPath = "";
                }
                ReleaseExactGeneration(lockPath, lockToken);
                lockPath = "";
                lockToken = "";
            }
        }
    }
}
'@
}

function Get-LockDirectoryIdentity([string] $Path) {
    if ($isWindowsPlatform) { return [Claudex.CredentialSyncCleanup]::GetDirectoryIdentity($Path) }
    $stat = Get-Command stat -ErrorAction SilentlyContinue
    if (-not $stat) { return '' }
    foreach ($arguments in @(@('-f', '%d:%i', $Path), @('-c', '%d:%i', $Path))) {
        try {
            $result = @(& $stat.Source @arguments 2>$null)
            if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string] $result[0])) {
                return ([string] $result[0]).Trim()
            }
        } catch { }
    }
    return ''
}

function Get-TextFingerprint([string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8.GetBytes($Text)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function Get-OwnedLockField([string] $OwnerFile, [string] $Field) {
    if (-not (Test-Path -LiteralPath $OwnerFile -PathType Leaf)) { return '' }
    try {
        foreach ($line in [IO.File]::ReadAllLines($OwnerFile)) {
            if ($line.StartsWith($Field + '=', [StringComparison]::Ordinal)) { return $line.Substring($Field.Length + 1) }
        }
    } catch { }
    return ''
}

function Get-LockGenerationNonce([string] $LockDirectory) {
    $generationFile = Join-Path $LockDirectory 'generation'
    if (-not (Test-Path -LiteralPath $generationFile -PathType Leaf)) { return '' }
    try { return [IO.File]::ReadAllText($generationFile).Trim() } catch { return '' }
}

function Get-LegacyLockOwner([string] $OwnerFile) {
    if (-not (Test-Path -LiteralPath $OwnerFile -PathType Leaf)) { return '' }
    try {
        $owner = ([IO.File]::ReadAllText($OwnerFile) -split "`r?`n", 2)[0].Trim()
        if ($owner -match '^\d+\s+\S+$') { return $owner }
    } catch { }
    return ''
}

function Test-LegacyLockOwnerCurrent([string] $OwnerFile) {
    $owner = Get-LegacyLockOwner $OwnerFile
    if (-not $owner) { return $false }
    $ownerPid = 0
    if (-not [int]::TryParse(($owner -split '\s+', 2)[0], [ref] $ownerPid) -or $ownerPid -le 0) { return $false }
    return $null -ne (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
}

function Get-LockBarriers([string] $LockDirectory) {
    $parent = Split-Path $LockDirectory -Parent
    $leaf = Split-Path $LockDirectory -Leaf
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $parent -Directory -Filter ($leaf + '.quarantine.*') -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Invoke-LockTestPause([string] $Stage, [string] $LockDirectory) {
    if ($env:CLAUDEX_TEST_MODE -ne '1') { return }
    $match = [Environment]::GetEnvironmentVariable('CLAUDEX_TEST_LOCK_MATCH', 'Process')
    if ($match -and -not $LockDirectory.Contains($match)) { return }
    $ready = [Environment]::GetEnvironmentVariable("CLAUDEX_TEST_LOCK_${Stage}_READY", 'Process')
    $continue = [Environment]::GetEnvironmentVariable("CLAUDEX_TEST_LOCK_${Stage}_CONTINUE", 'Process')
    if (-not $ready -or -not $continue) { return }
    [IO.File]::WriteAllText($ready, "ready`n", $utf8)
    while (-not (Test-Path -LiteralPath $continue -PathType Leaf)) { Start-Sleep -Milliseconds 20 }
}

function Remove-LockDirectoryFiles([string] $Directory) {
    Remove-Item -LiteralPath (Join-Path $Directory 'owner') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Directory 'generation') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
}

function Publish-LockFile([string] $Source, [string] $Destination) {
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE -eq '1') { throw 'forced lock publication failure' }
    if ($env:CLAUDEX_TEST_MODE -ne '1' -or $env:CLAUDEX_TEST_FORCE_HARDLINK_FAILURE -ne '1') {
        try { New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null; return } catch { }
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

function Restore-LockBarrier([string] $LockDirectory, [string] $Barrier) {
    foreach ($attempt in 1..250) {
        if (-not (Test-Path -LiteralPath $LockDirectory)) {
            try { Move-Item -LiteralPath $Barrier -Destination $LockDirectory -ErrorAction Stop; return $true } catch { }
        }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

function Remove-LegacyLockGeneration([string] $LockDirectory, [string] $ExpectedOwner) {
    if ([string]::IsNullOrWhiteSpace($ExpectedOwner) -or (Get-LegacyLockOwner (Join-Path $LockDirectory 'owner')) -ne $ExpectedOwner) { return $false }
    $quarantine = $LockDirectory + '.quarantine.legacy.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    Invoke-LockTestPause 'BEFORE_RENAME' $LockDirectory
    try { Move-Item -LiteralPath $LockDirectory -Destination $quarantine -ErrorAction Stop } catch { return $false }
    Invoke-LockTestPause 'AFTER_RENAME' $LockDirectory
    $movedOwner = Get-LegacyLockOwner (Join-Path $quarantine 'owner')
    if ($movedOwner -eq $ExpectedOwner -and -not (Get-LockGenerationNonce $quarantine) -and -not (Get-OwnedLockField (Join-Path $quarantine 'owner') 'nonce')) {
        Remove-LockDirectoryFiles $quarantine
        return $true
    }
    [void] (Restore-LockBarrier $LockDirectory $quarantine)
    return $false
}

function Remove-LegacyLockBarrier([string] $Barrier, [string] $ExpectedOwner) {
    if ([string]::IsNullOrWhiteSpace($ExpectedOwner) -or (Get-LegacyLockOwner (Join-Path $Barrier 'owner')) -ne $ExpectedOwner) { return $false }
    $disposal = $Barrier + '.dispose.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    try { Move-Item -LiteralPath $Barrier -Destination $disposal -ErrorAction Stop } catch { return $false }
    $movedOwner = Get-LegacyLockOwner (Join-Path $disposal 'owner')
    if ($movedOwner -eq $ExpectedOwner -and -not (Get-LockGenerationNonce $disposal) -and -not (Get-OwnedLockField (Join-Path $disposal 'owner') 'nonce')) {
        Remove-LockDirectoryFiles $disposal
        return $true
    }
    [void] (Restore-LockBarrier $Barrier $disposal)
    return $false
}

function Withdraw-LegacyLockGeneration([string] $LockDirectory, [string] $ExpectedOwner, [string] $ExpectedGeneration) {
    if (-not $ExpectedOwner -or -not $ExpectedGeneration) { return $false }
    if ((Get-LegacyLockOwner (Join-Path $LockDirectory 'owner')) -ne $ExpectedOwner -or (Get-LockGenerationNonce $LockDirectory) -ne $ExpectedGeneration) { return $false }
    $quarantine = $LockDirectory + '.quarantine.legacy-generation.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    try { Move-Item -LiteralPath $LockDirectory -Destination $quarantine -ErrorAction Stop } catch { return $false }
    $movedOwner = Get-LegacyLockOwner (Join-Path $quarantine 'owner')
    $movedGeneration = Get-LockGenerationNonce $quarantine
    if ($movedOwner -eq $ExpectedOwner -and $movedGeneration -eq $ExpectedGeneration) {
        Remove-Item -LiteralPath (Join-Path $quarantine 'generation') -Force -ErrorAction SilentlyContinue
        [void] (Restore-LockBarrier $LockDirectory $quarantine)
        return $true
    }
    [void] (Restore-LockBarrier $LockDirectory $quarantine)
    return $false
}

function Withdraw-LegacyBarrierGeneration([string] $Barrier, [string] $ExpectedOwner, [string] $ExpectedGeneration) {
    if (-not $ExpectedOwner -or -not $ExpectedGeneration) { return $false }
    if ((Get-LegacyLockOwner (Join-Path $Barrier 'owner')) -ne $ExpectedOwner -or (Get-LockGenerationNonce $Barrier) -ne $ExpectedGeneration) { return $false }
    $disposal = $Barrier + '.withdraw.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    try { Move-Item -LiteralPath $Barrier -Destination $disposal -ErrorAction Stop } catch { return $false }
    $movedOwner = Get-LegacyLockOwner (Join-Path $disposal 'owner')
    $movedGeneration = Get-LockGenerationNonce $disposal
    if ($movedOwner -eq $ExpectedOwner -and $movedGeneration -eq $ExpectedGeneration) {
        Remove-Item -LiteralPath (Join-Path $disposal 'generation') -Force -ErrorAction SilentlyContinue
        [void] (Restore-LockBarrier $Barrier $disposal)
        return $true
    }
    [void] (Restore-LockBarrier $Barrier $disposal)
    return $false
}

function Remove-IncompleteLockDirectory([string] $LockDirectory) {
    if (-not (Test-Path -LiteralPath $LockDirectory -PathType Container)) { return $true }
    $quarantine = $LockDirectory + '.quarantine.incomplete.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    try { Move-Item -LiteralPath $LockDirectory -Destination $quarantine -ErrorAction Stop } catch { return $false }
    $movedNonce = Get-LockGenerationNonce $quarantine
    if (-not $movedNonce) { $movedNonce = Get-OwnedLockField (Join-Path $quarantine 'owner') 'nonce' }
    $movedLegacyOwner = Get-LegacyLockOwner (Join-Path $quarantine 'owner')
    if ($movedNonce -or $movedLegacyOwner) { [void] (Restore-LockBarrier $LockDirectory $quarantine); return $false }
    Remove-LockDirectoryFiles $quarantine
    return -not (Test-Path -LiteralPath $quarantine)
}

function Get-OwnedLockAgeSeconds([string] $LockDirectory) {
    try { return [math]::Max(0, ([DateTime]::UtcNow - (Get-Item -LiteralPath $LockDirectory -ErrorAction Stop).LastWriteTimeUtc).TotalSeconds) }
    catch { return 0 }
}

function Get-ProcessIdentity([int] $ProcessId) {
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_PROCESS_IDENTITY) { return $env:CLAUDEX_TEST_PROCESS_IDENTITY }
    try { return [string] (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { return '' }
}

function Test-OwnedLockOwnerCurrent([string] $OwnerFile) {
    $ownerPid = 0
    if (-not [int]::TryParse((Get-OwnedLockField $OwnerFile 'pid'), [ref] $ownerPid) -or $ownerPid -le 0) { return $false }
    $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    $recordedIdentity = Get-OwnedLockField $OwnerFile 'identity'
    if ([string]::IsNullOrWhiteSpace($recordedIdentity)) { return $true }
    $currentIdentity = Get-ProcessIdentity $ownerPid
    return -not $currentIdentity -or $recordedIdentity -eq $currentIdentity
}

function Recover-LockBarriers([string] $LockDirectory, [int] $LegacyOwnerlessSeconds, [int] $LegacyOwnerSeconds) {
    foreach ($barrierInfo in @(Get-LockBarriers $LockDirectory)) {
        $barrier = $barrierInfo.FullName
        $ownerFile = Join-Path $barrier 'owner'
        $ownerNonce = Get-OwnedLockField $ownerFile 'nonce'
        $legacyOwner = Get-LegacyLockOwner $ownerFile
        $generationNonce = Get-LockGenerationNonce $barrier
        $age = Get-OwnedLockAgeSeconds $barrier
        if ($legacyOwner -and $generationNonce) {
            if (-not (Withdraw-LegacyBarrierGeneration $barrier $legacyOwner $generationNonce)) { continue }
            $generationNonce = ''
        }
        if ($ownerNonce -and (Test-OwnedLockOwnerCurrent $ownerFile)) {
            if (-not (Test-Path -LiteralPath $LockDirectory)) { try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { } }
        } elseif ($ownerNonce -and $age -ge 2) { Remove-LockDirectoryFiles $barrier
        } elseif ($legacyOwner -and (Test-LegacyLockOwnerCurrent $ownerFile)) {
            if (-not (Test-Path -LiteralPath $LockDirectory)) { try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { } }
        } elseif ($legacyOwner -and $age -ge $LegacyOwnerSeconds) { [void] (Remove-LegacyLockBarrier $barrier $legacyOwner)
        } elseif ($generationNonce -and $age -ge 2) { Remove-LockDirectoryFiles $barrier
        } elseif (-not $generationNonce -and $age -ge $LegacyOwnerlessSeconds) { Remove-LockDirectoryFiles $barrier }
    }
}

function Remove-OwnedLockGeneration([string] $LockDirectory, [string] $ExpectedNonce) {
    if ([string]::IsNullOrWhiteSpace($ExpectedNonce)) { return $false }
    $ownerFile = Join-Path $LockDirectory 'owner'
    $currentNonce = Get-LockGenerationNonce $LockDirectory
    if (-not $currentNonce) { $currentNonce = Get-OwnedLockField $ownerFile 'nonce' }
    if ($currentNonce -ne $ExpectedNonce) { return $false }
    $quarantine = $LockDirectory + '.quarantine.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    Invoke-LockTestPause 'BEFORE_RENAME' $LockDirectory
    try { Move-Item -LiteralPath $LockDirectory -Destination $quarantine -ErrorAction Stop } catch { return $false }
    Invoke-LockTestPause 'AFTER_RENAME' $LockDirectory
    if (-not (Test-Path -LiteralPath $quarantine -PathType Container)) { return $false }
    $movedGeneration = Get-LockGenerationNonce $quarantine
    $movedOwnerNonce = Get-OwnedLockField (Join-Path $quarantine 'owner') 'nonce'
    $movedLegacyOwner = Get-LegacyLockOwner (Join-Path $quarantine 'owner')
    if ($movedGeneration -eq $ExpectedNonce) {
        if ($movedOwnerNonce -eq $ExpectedNonce -or (-not $movedOwnerNonce -and -not $movedLegacyOwner)) {
            Remove-LockDirectoryFiles $quarantine
            return $true
        }
        # A prior-version owner replaced the directory between mkdir and our
        # publication. Remove only our partial generation and restore it.
        Remove-Item -LiteralPath (Join-Path $quarantine 'generation') -Force -ErrorAction SilentlyContinue
        [void] (Restore-LockBarrier $LockDirectory $quarantine)
        return $false
    }
    if (-not $movedGeneration -and $movedOwnerNonce -eq $ExpectedNonce) { Remove-LockDirectoryFiles $quarantine; return $true }
    [void] (Restore-LockBarrier $LockDirectory $quarantine)
    return $false
}

function Recover-OwnedLockGeneration([string] $LockDirectory, [string] $ExpectedNonce, [string] $ExpectedDirectoryIdentity = '') {
    foreach ($barrierInfo in @(Get-LockBarriers $LockDirectory)) {
        $barrier = $barrierInfo.FullName
        $movedNonce = Get-LockGenerationNonce $barrier
        if (-not $movedNonce) { $movedNonce = Get-OwnedLockField (Join-Path $barrier 'owner') 'nonce' }
        if ($movedNonce -ne $ExpectedNonce) { continue }
        if ($ExpectedDirectoryIdentity -and (Get-LockDirectoryIdentity $barrier) -ne $ExpectedDirectoryIdentity) { continue }
        if (-not (Test-Path -LiteralPath $LockDirectory)) { try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { } }
    }
    $currentNonce = Get-LockGenerationNonce $LockDirectory
    if (-not $currentNonce) { $currentNonce = Get-OwnedLockField (Join-Path $LockDirectory 'owner') 'nonce' }
    $currentDirectoryIdentity = Get-LockDirectoryIdentity $LockDirectory
    if ($currentNonce -eq $ExpectedNonce -and (-not $ExpectedDirectoryIdentity -or $currentDirectoryIdentity -eq $ExpectedDirectoryIdentity) -and @(Get-LockBarriers $LockDirectory).Count -eq 0) {
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE) { [IO.File]::WriteAllText($env:CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE, "recovered`n", $utf8) }
        return $true
    }
    if ($currentNonce -eq $ExpectedNonce -and (-not $ExpectedDirectoryIdentity -or $currentDirectoryIdentity -eq $ExpectedDirectoryIdentity)) { [void] (Remove-OwnedLockGeneration $LockDirectory $ExpectedNonce) }
    foreach ($barrierInfo in @(Get-LockBarriers $LockDirectory)) {
        $barrier = $barrierInfo.FullName
        $movedNonce = Get-LockGenerationNonce $barrier
        if (-not $movedNonce) { $movedNonce = Get-OwnedLockField (Join-Path $barrier 'owner') 'nonce' }
        if ($movedNonce -eq $ExpectedNonce -and (-not $ExpectedDirectoryIdentity -or (Get-LockDirectoryIdentity $barrier) -eq $ExpectedDirectoryIdentity)) { Remove-LockDirectoryFiles $barrier }
    }
    return $false
}

function Acquire-OwnedLock([string] $LockDirectory, [int] $Attempts = 100, [int] $DelayMilliseconds = 20, [int] $LegacyOwnerlessSeconds = 60, [int] $LegacyOwnerSeconds = 60) {
    $parent = Split-Path $LockDirectory -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $ownerFile = Join-Path $LockDirectory 'owner'
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        Recover-LockBarriers $LockDirectory $LegacyOwnerlessSeconds $LegacyOwnerSeconds
        if (@(Get-LockBarriers $LockDirectory).Count -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds; continue }
        $created = $false
        $createdDirectoryIdentity = ''
        $ownerTemporary = Join-Path $parent ('.lock-owner.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $generationTemporary = Join-Path $parent ('.lock-generation.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $nonce = [guid]::NewGuid().ToString('N')
        $identity = Get-ProcessIdentity $PID
        [IO.File]::WriteAllText($ownerTemporary, "pid=$PID`nidentity=$identity`nnonce=$nonce`n", $utf8)
        [IO.File]::WriteAllText($generationTemporary, "$nonce`n", $utf8)
        Protect-PrivatePath $ownerTemporary $false
        Protect-PrivatePath $generationTemporary $false
        try {
            New-Item -Path $LockDirectory -ItemType Directory -ErrorAction Stop | Out-Null
            $created = $true
            $createdDirectoryIdentity = Get-LockDirectoryIdentity $LockDirectory
            if (-not $createdDirectoryIdentity) { throw 'could not identify created lock directory' }
            Invoke-LockTestPause 'AFTER_MKDIR' $LockDirectory
            if ((Get-LockDirectoryIdentity $LockDirectory) -ne $createdDirectoryIdentity) { throw 'lock directory changed before generation publication' }
            Publish-LockFile $generationTemporary (Join-Path $LockDirectory 'generation')
            if ((Get-LockDirectoryIdentity $LockDirectory) -ne $createdDirectoryIdentity -or (Get-LockGenerationNonce $LockDirectory) -ne $nonce) { throw 'lock generation publication changed' }
            if ((Get-LockDirectoryIdentity $LockDirectory) -ne $createdDirectoryIdentity) { throw 'lock directory changed before owner publication' }
            Publish-LockFile $ownerTemporary $ownerFile
            if ((Get-LockDirectoryIdentity $LockDirectory) -ne $createdDirectoryIdentity -or (Get-OwnedLockField $ownerFile 'nonce') -ne $nonce -or @(Get-LockBarriers $LockDirectory).Count -gt 0) { throw 'lock ownership publication changed' }
            Protect-PrivatePath $ownerFile $false
            Protect-PrivatePath (Join-Path $LockDirectory 'generation') $false
            Remove-Item -LiteralPath $ownerTemporary, $generationTemporary -Force -ErrorAction SilentlyContinue
            Invoke-LockTestPause 'AFTER_PUBLISH' $LockDirectory
            $currentDirectoryIdentity = Get-LockDirectoryIdentity $LockDirectory
            if ($currentDirectoryIdentity -ne $createdDirectoryIdentity -or (Get-LockGenerationNonce $LockDirectory) -ne $nonce -or @(Get-LockBarriers $LockDirectory).Count -gt 0) {
                if (Recover-OwnedLockGeneration $LockDirectory $nonce $createdDirectoryIdentity) { return $nonce }
                Start-Sleep -Milliseconds $DelayMilliseconds
                continue
            }
            return $nonce
        } catch {
            if ($created -and $createdDirectoryIdentity -and (Get-LockDirectoryIdentity $LockDirectory) -eq $createdDirectoryIdentity) {
                if (-not (Remove-OwnedLockGeneration $LockDirectory $nonce)) { [void] (Remove-IncompleteLockDirectory $LockDirectory) }
            }
        }
        Remove-Item -LiteralPath $ownerTemporary, $generationTemporary -Force -ErrorAction SilentlyContinue
        $age = Get-OwnedLockAgeSeconds $LockDirectory
        $observedNonce = Get-OwnedLockField $ownerFile 'nonce'
        $legacyOwner = Get-LegacyLockOwner $ownerFile
        if ($observedNonce) {
            if ($age -ge 2 -and -not (Test-OwnedLockOwnerCurrent $ownerFile)) { [void] (Remove-OwnedLockGeneration $LockDirectory $observedNonce) }
        } elseif ($legacyOwner) {
            $legacyGeneration = Get-LockGenerationNonce $LockDirectory
            if ($legacyGeneration) { [void] (Withdraw-LegacyLockGeneration $LockDirectory $legacyOwner $legacyGeneration) }
            if ($age -ge $LegacyOwnerSeconds -and -not (Test-LegacyLockOwnerCurrent $ownerFile)) { [void] (Remove-LegacyLockGeneration $LockDirectory $legacyOwner) }
        } elseif ((Get-LockGenerationNonce $LockDirectory) -and $age -ge 2) {
            [void] (Remove-OwnedLockGeneration $LockDirectory (Get-LockGenerationNonce $LockDirectory))
        } elseif ($age -ge $LegacyOwnerlessSeconds -and (Test-Path -LiteralPath $LockDirectory -PathType Container)) {
            $legacyQuarantine = $LockDirectory + '.quarantine.legacy.' + $PID + '.' + [guid]::NewGuid().ToString('N')
            try { Move-Item -LiteralPath $LockDirectory -Destination $legacyQuarantine -ErrorAction Stop } catch { $legacyQuarantine = '' }
            if ($legacyQuarantine) {
                if ((Get-LockGenerationNonce $legacyQuarantine) -or (Get-OwnedLockField (Join-Path $legacyQuarantine 'owner') 'nonce')) { [void] (Restore-LockBarrier $LockDirectory $legacyQuarantine) }
                else { Remove-LockDirectoryFiles $legacyQuarantine }
            }
        }
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
    return ''
}

function Release-OwnedLock([string] $LockDirectory, [string] $Nonce) { [void] (Remove-OwnedLockGeneration $LockDirectory $Nonce) }

function Release-SessionSyncLock {
    if (-not $script:sessionSyncOwned) { return }
    Release-OwnedLock $sessionSyncLock $script:sessionSyncToken
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
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_SESSION_SYNC_LOCK_WAIT_READY_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_SESSION_SYNC_LOCK_WAIT_READY_FILE, "ready`n", $utf8)
    }
    $nonce = Acquire-OwnedLock $sessionSyncLock 250 20 2 60
    if (-not $nonce) { throw 'timed out waiting for another Codex credential synchronization.' }
    $script:sessionSyncToken = $nonce
    $script:sessionSyncOwned = $true
    [Claudex.CredentialSyncCleanup]::TrackLock($sessionSyncLock, $nonce)
}

function Clear-BridgeSession {
    if (-not $script:sessionSyncOwned) { throw 'internal error: bridge mutation requires credential synchronization ownership.' }
    Remove-Item -LiteralPath $bridgeAuthFile -Force -ErrorAction SilentlyContinue
}

function Clear-AccountScopedState {
    if (-not $script:sessionSyncOwned) { throw 'internal error: account-state mutation requires credential synchronization ownership.' }
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

function Clear-OwnedSessionState {
    Clear-BridgeSession
    Clear-AccountScopedState
}

function Get-JsonProperty($Object, [string] $Name, $Default = $null) {
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function Get-SafeEmailFromIdToken($IdToken) {
    if ($IdToken -isnot [string] -or [string]::IsNullOrWhiteSpace($IdToken)) { return '' }
    try {
        $parts = $IdToken.Split('.')
        if ($parts.Count -lt 2) { return '' }
        $body = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($body.Length % 4) {
            0 { }
            2 { $body += '==' }
            3 { $body += '=' }
            default { return '' }
        }
        $payloadText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body))
        $payload = $payloadText | ConvertFrom-Json
        $emailValue = Get-JsonProperty $payload 'email' $null
        if ($emailValue -isnot [string]) { return '' }
        $email = [string] $emailValue
        if ($email.Length -eq 0 -or $email.Length -gt 320) { return '' }
        if ($email -notmatch '^[^@\s\x00-\x1F\x7F]+@[^@\s\x00-\x1F\x7F]+$') { return '' }
        return $email
    } catch {
        return ''
    }
}

function Get-CodexSourceSnapshot {
    try {
        $raw = [IO.File]::ReadAllText($codexAuthFile)
        $source = $raw | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ Valid = $false; Raw = ''; Source = $null }
    }
    $tokens = Get-JsonProperty $source 'tokens' $null
    $authMode = Get-JsonProperty $source 'auth_mode' $null
    $accessToken = Get-JsonProperty $tokens 'access_token' $null
    $refreshToken = Get-JsonProperty $tokens 'refresh_token' $null
    $accountId = Get-JsonProperty $tokens 'account_id' $null
    $valid = $authMode -is [string] -and $authMode -eq 'chatgpt' -and $tokens -and
        $accessToken -is [string] -and -not [string]::IsNullOrWhiteSpace($accessToken) -and
        $refreshToken -is [string] -and -not [string]::IsNullOrWhiteSpace($refreshToken) -and
        $accountId -is [string] -and -not [string]::IsNullOrWhiteSpace($accountId)
    return [pscustomobject]@{ Valid = [bool] $valid; Raw = $raw; Source = $source }
}

function ConvertTo-CodexCmdArgument([string] $Value) {
    if ($null -eq $Value) { $Value = '' }
    return '"' + $Value.Replace('%', '%%').Replace('"', '""') + '"'
}

$script:lastCodexCommandExitCode = 1
function Invoke-CodexCommand($Codex, [string[]] $Arguments, [switch] $DiscardOutput) {
    $commandPath = [string] $Codex.Source
    $extension = [IO.Path]::GetExtension($commandPath).ToLowerInvariant()
    if ($isWindowsPlatform -and $extension -in @('.cmd', '.bat')) {
        $commandLine = (ConvertTo-CodexCmdArgument $commandPath) + ' ' +
            (@($Arguments | ForEach-Object { ConvertTo-CodexCmdArgument ([string] $_) }) -join ' ')
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $startInfo.Arguments = '/d /s /v:off /c "' + $commandLine + '"'
        $startInfo.UseShellExecute = $false
        if ($DiscardOutput) {
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
        }
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { throw 'Codex command could not be started.' }
            if ($DiscardOutput) {
                $stdoutDrain = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
                $stderrDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            }
            $process.WaitForExit()
            if ($DiscardOutput) {
                $stdoutDrain.GetAwaiter().GetResult()
                $stderrDrain.GetAwaiter().GetResult()
            }
            $script:lastCodexCommandExitCode = [int] $process.ExitCode
        } finally {
            $process.Dispose()
        }
    } else {
        $global:LASTEXITCODE = $null
        if ($DiscardOutput) { & $commandPath @Arguments *> $null }
        else { & $commandPath @Arguments }
        $script:lastCodexCommandExitCode = if ($null -ne $LASTEXITCODE) { [int] $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    }
    $global:LASTEXITCODE = $script:lastCodexCommandExitCode
}

function Test-CodexLogin {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) { return $false }
    try {
        Invoke-CodexCommand -Codex $codex -Arguments @('-c', 'cli_auth_credentials_store="file"', 'login', 'status') -DiscardOutput
        return $script:lastCodexCommandExitCode -eq 0
    } catch {
        return $false
    }
}

function Sync-Session {
    [IO.Directory]::CreateDirectory($bridgeAuthDir) | Out-Null
    Protect-PrivatePath $bridgeAuthDir $true

    # A negative observation may race a valid publisher. Own the publication
    # boundary and repeat the observation before deleting any bridge or
    # account-scoped state.
    while ($true) {
        $codex = Get-Command codex -ErrorAction SilentlyContinue
        if (-not $codex) {
            Acquire-SessionSyncLock
            try {
                if (Get-Command codex -ErrorAction SilentlyContinue) { continue }
                Clear-OwnedSessionState
            } finally { Release-SessionSyncLock }
            Write-Failure 'Codex CLI was not found. Install Codex, run `codex login`, and retry.'
            return 10
        }
        if (-not (Test-CodexLogin)) {
            Acquire-SessionSyncLock
            try {
                if (Test-CodexLogin) { continue }
                Clear-OwnedSessionState
            } finally { Release-SessionSyncLock }
            Write-Failure 'Codex is logged out. Run `codex login` (or `claudex --login`) and retry.'
            return 11
        }
        if (-not (Test-Path -LiteralPath $codexAuthFile -PathType Leaf)) {
            Acquire-SessionSyncLock
            try {
                if (Test-Path -LiteralPath $codexAuthFile -PathType Leaf) { continue }
                Clear-OwnedSessionState
            } finally { Release-SessionSyncLock }
            Write-Failure 'Codex is logged in, but its credentials are stored in the OS keyring.'
            Write-Failure 'Run `claudex --login` once so Codex can create a reusable file-backed local session.'
            return 13
        }
        $snapshot = Get-CodexSourceSnapshot
        if (-not $snapshot.Valid) {
            Acquire-SessionSyncLock
            try {
                $currentSnapshot = Get-CodexSourceSnapshot
                if ($currentSnapshot.Valid) { continue }
                Clear-OwnedSessionState
            } finally { Release-SessionSyncLock }
            Write-Failure 'Codex auth.json is invalid or is not a ChatGPT session. Run `claudex --login` to repair it.'
            return 14
        }
        break
    }

    foreach ($attempt in 1..3) {
        $snapshot = Get-CodexSourceSnapshot
        if (-not $snapshot.Valid) {
            Acquire-SessionSyncLock
            try {
                $currentSnapshot = Get-CodexSourceSnapshot
                if ($currentSnapshot.Valid) { continue }
                Clear-OwnedSessionState
            } finally { Release-SessionSyncLock }
            Write-Failure 'Codex auth.json is invalid or is not a ChatGPT session. Run `claudex --login` to repair it.'
            return 14
        }
        $sourceRaw = [string] $snapshot.Raw
        $source = $snapshot.Source
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
        $email = Get-SafeEmailFromIdToken $idToken
        $sourceRefresh = [string] (Get-JsonProperty $source 'last_refresh' '')
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
        if ($email) { $candidate['email'] = $email }

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
                    $existingEmail = [string] (Get-JsonProperty $existing 'email' '')
                    if ($existing.type -eq 'codex' -and $existing.access_token -and
                        $existing.account_id -eq $accountId -and
                        $existing.access_token -eq $accessToken -and
                        $existing.refresh_token -eq $refreshToken -and
                        ([string] (Get-JsonProperty $existing 'id_token' '')) -eq $idToken -and
                        $existingEmail -eq $email -and
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

function Test-WatchParentCurrent {
    $process = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ([string]::IsNullOrWhiteSpace($ParentProcessIdentity)) { return $true }
    try { return ([string] $process.StartTime.ToUniversalTime().Ticks) -eq $ParentProcessIdentity }
    catch { return $false }
}

function Get-ManagedBackgroundRegistryState {
    $privateNames = @(
        'BUN_OPTIONS',
        'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY',
        'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_CUSTOM_HEADERS',
        'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
        'ANTHROPIC_BEDROCK_BASE_URL', 'ANTHROPIC_BEDROCK_MANTLE_BASE_URL',
        'ANTHROPIC_VERTEX_BASE_URL', 'ANTHROPIC_VERTEX_PROJECT_ID',
        'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_FOUNDRY_RESOURCE', 'ANTHROPIC_FOUNDRY_API_KEY',
        'ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION',
        'ANTHROPIC_CUSTOM_MODEL_OPTION', 'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME',
        'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION',
        'ANTHROPIC_DEFAULT_FABLE_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
        'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
        'ANTHROPIC_DEFAULT_FABLE_MODEL_NAME', 'ANTHROPIC_DEFAULT_OPUS_MODEL_NAME',
        'ANTHROPIC_DEFAULT_SONNET_MODEL_NAME', 'ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME',
        'ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION', 'ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION',
        'ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION', 'ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION',
        'ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES',
        'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES',
        'ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES',
        'ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES',
        'CLAUDE_CODE_AUTO_MODE_MODEL', 'CLAUDE_CODE_BG_CLASSIFIER_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL',
        'CLAUDEX_PROXY_TOKEN', 'CLAUDEX_PROXY_URL', 'CLAUDEX_PROXY_CONFIG', 'CLAUDEX_PROXY_BIN',
        'CLAUDEX_CODEX_AUTH_FILE', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE', 'CLAUDEX_MANAGED_SESSION',
        'CLAUDEX_CHATGPT_PLAN_LABEL', 'CLAUDEX_SESSION_MODE', 'CLAUDEX_MODEL_MODE',
        'CLAUDEX_INTERACTIVE_TUI', 'CLAUDE_CODE_EFFORT_LEVEL'
    )
    $saved = @{}
    foreach ($name in $privateNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    try {
        $claude = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $claude) { return 'unknown' }
        $global:LASTEXITCODE = $null
        $raw = (& $claude.Source agents --json 2>$null | Out-String)
        if (($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) -or -not $raw.TrimStart().StartsWith('[')) { return 'unknown' }
        try { $records = $raw | ConvertFrom-Json } catch { return 'unknown' }
        if ($null -eq $records) {
            if ($raw -match '^\s*\[\s*\]\s*$') { return 'empty' }
            return 'unknown'
        }
        if ($records -is [Array] -and $records.Count -eq 0) { return 'empty' }
        return 'active'
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, [string] $saved[$name], 'Process') }
        }
    }
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
    if ([string]::IsNullOrWhiteSpace($ParentProcessIdentity)) {
        $script:ParentProcessIdentity = Get-ProcessIdentity $ParentProcessId
    }
    try { Sync-Session | Out-Null } catch { }
    $fingerprint = Get-AuthFingerprint
    if ($env:CLAUDEX_AUTH_WATCH_READY_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_AUTH_WATCH_READY_FILE, "ready`n", $utf8)
    }
    $emptyPolls = 0
    while ($true) {
        if (Test-WatchParentCurrent) { $emptyPolls = 0 }
        elseif ($BackgroundWatch) {
            $registryState = Get-ManagedBackgroundRegistryState
            if ($registryState -eq 'active') { $emptyPolls = 0 }
            elseif ($registryState -eq 'empty') {
                $emptyPolls++
                if ($emptyPolls -ge 3) { break }
            } else { $emptyPolls = 0 }
        } else { break }
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
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_AUTH_WATCH_EXIT_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_AUTH_WATCH_EXIT_FILE, "exited`n", $utf8)
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
        Invoke-CodexCommand -Codex $codex -Arguments @('-c', 'cli_auth_credentials_store="file"', 'login')
        if ($script:lastCodexCommandExitCode -ne 0) { exit $script:lastCodexCommandExitCode }
        $result = Sync-Session
        if ($result -ne 0) { exit $result }
        Write-Output 'Codex authentication is ready for Claudex.'
    }
    'logout' {
        Acquire-SessionSyncLock
        try {
            $codex = Get-Command codex -ErrorAction SilentlyContinue
            if ($codex) {
                Invoke-CodexCommand -Codex $codex -Arguments @('-c', 'cli_auth_credentials_store="file"', 'logout')
                $exitCode = $script:lastCodexCommandExitCode
            } else { $exitCode = 10 }
            Clear-OwnedSessionState
        }
        finally { Release-SessionSyncLock }
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
