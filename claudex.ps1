$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ClaudexInternalProxyWatchParentProcessId = 0
$ClaudexInternalProxyWatchParentIdentity = ''
$ClaudexInternalProxyWatchBackground = $false
$claudexInternalClaudeUpdate = $false
$internalClaudeUpdatePath = ''
$internalClaudeUpdateDirectory = ''
$internalClaudeUpdateInterval = 0L
$ClaudeArguments = @($args)
$hostArguments = [Environment]::GetCommandLineArgs()
for ($hostIndex = 0; $hostIndex + 1 -lt $hostArguments.Count; $hostIndex++) {
    if ($hostArguments[$hostIndex] -ine '-File') { continue }
    try {
        $hostScriptPath = [IO.Path]::GetFullPath([string] $hostArguments[$hostIndex + 1])
        $currentScriptPath = [IO.Path]::GetFullPath([string] $PSCommandPath)
    } catch { continue }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($hostScriptPath, $currentScriptPath)) { continue }
    $firstHostArgument = $hostIndex + 2
    $rawClaudeArguments = if ($firstHostArgument -lt $hostArguments.Count) {
        [string[]] $hostArguments[$firstHostArgument..($hostArguments.Count - 1)]
    } else { [string[]] @() }
    if ($rawClaudeArguments -contains '--') { $ClaudeArguments = $rawClaudeArguments }
    break
}
if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '-ClaudexInternalProxyWatchParentProcessId') {
    $parsedProxyWatchParent = 0
    if ($ClaudeArguments.Count -lt 2 -or -not [int]::TryParse($ClaudeArguments[1], [ref] $parsedProxyWatchParent)) {
        throw 'Claudex internal proxy watcher requires a numeric parent process ID.'
    }
    $ClaudexInternalProxyWatchParentProcessId = $parsedProxyWatchParent
    if ($ClaudeArguments.Count -ge 4) {
        $ClaudexInternalProxyWatchParentIdentity = [string] $ClaudeArguments[2]
        $parsedProxyWatchBackground = 0
        if (-not [int]::TryParse([string] $ClaudeArguments[3], [ref] $parsedProxyWatchBackground) -or $parsedProxyWatchBackground -notin @(0, 1)) {
            throw 'Claudex internal proxy watcher background mode must be 0 or 1.'
        }
        $ClaudexInternalProxyWatchBackground = $parsedProxyWatchBackground -eq 1
        if ($ClaudeArguments.Count -gt 4) { $ClaudeArguments = @($ClaudeArguments[4..($ClaudeArguments.Count - 1)]) }
        else { $ClaudeArguments = @() }
    } elseif ($ClaudeArguments.Count -gt 2) { $ClaudeArguments = @($ClaudeArguments[2..($ClaudeArguments.Count - 1)]) }
    else { $ClaudeArguments = @() }
}
if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '-ClaudexInternalClaudeUpdate') {
    $internalNonce = [Environment]::GetEnvironmentVariable('CLAUDEX_INTERNAL_UPDATE_NONCE', 'Process')
    $sentinelValid = $false
    if ($ClaudeArguments.Count -eq 5 -and -not [string]::IsNullOrWhiteSpace($internalNonce)) {
        try {
            $sentinelValid = [IO.File]::ReadAllText([string] $ClaudeArguments[4]).Trim() -eq $internalNonce
            if ($sentinelValid) { [IO.File]::Delete([string] $ClaudeArguments[4]) }
        } catch { $sentinelValid = $false }
    }
    if ($sentinelValid -and
        [long]::TryParse([string] $ClaudeArguments[3], [ref] $internalClaudeUpdateInterval) -and
        $internalClaudeUpdateInterval -ge 60) {
        $claudexInternalClaudeUpdate = $true
        $internalClaudeUpdatePath = [string] $ClaudeArguments[1]
        $internalClaudeUpdateDirectory = [string] $ClaudeArguments[2]
        $ClaudeArguments = @()
    }
}
$previousSessionMode = [Environment]::GetEnvironmentVariable('CLAUDEX_SESSION_MODE', 'Process')
$previousEffortLevel = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_EFFORT_LEVEL', 'Process')
$previousModelMode = [Environment]::GetEnvironmentVariable('CLAUDEX_MODEL_MODE', 'Process')
$previousInteractiveTui = [Environment]::GetEnvironmentVariable('CLAUDEX_INTERACTIVE_TUI', 'Process')
$competingProviderEnvironmentNames = @(
    'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
    'ANTHROPIC_BEDROCK_BASE_URL', 'ANTHROPIC_BEDROCK_MANTLE_BASE_URL',
    'ANTHROPIC_VERTEX_BASE_URL', 'ANTHROPIC_VERTEX_PROJECT_ID',
    'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_FOUNDRY_RESOURCE', 'ANTHROPIC_FOUNDRY_API_KEY',
    'ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_CUSTOM_HEADERS',
    'ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION',
    'ANTHROPIC_CUSTOM_MODEL_OPTION', 'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME', 'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION'
)
$sessionEnvironmentNames = @(
    'BUN_OPTIONS', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN',
    $competingProviderEnvironmentNames,
    'ANTHROPIC_DEFAULT_FABLE_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_DEFAULT_FABLE_MODEL_NAME', 'ANTHROPIC_DEFAULT_OPUS_MODEL_NAME', 'ANTHROPIC_DEFAULT_SONNET_MODEL_NAME', 'ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME',
    'ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION', 'ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION', 'ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION', 'ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION',
    'ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES', 'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES', 'ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES', 'CLAUDE_CODE_AUTO_MODE_MODEL',
    'CLAUDE_CODE_BG_CLASSIFIER_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT',
    'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY', 'CLAUDE_CODE_MAX_RETRIES', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
    'CLAUDE_CODE_AUTO_COMPACT_WINDOW', 'CLAUDE_CODE_DISABLE_1M_CONTEXT', 'CLAUDEX_CHATGPT_PLAN_LABEL',
    'CLAUDEX_NO_SESSION_PERSISTENCE', 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD', 'CLAUDEX_MANAGED_SESSION',
    'CLAUDEX_INSTRUCTION_BRIDGE', 'CLAUDEX_PROXY_TOKEN', 'CLAUDEX_PROXY_URL', 'CLAUDEX_PROXY_CONFIG',
    'CLAUDEX_PROXY_BIN', 'CLAUDEX_CODEX_AUTH_DIR', 'CLAUDEX_CODEX_AUTH_FILE', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE',
    'CLAUDEX_CONFIG_DIR', 'CLAUDEX_CLAUDE_CONFIG_DIR'
) | ForEach-Object { $_ }
$previousSessionEnvironment = @{}
foreach ($environmentName in $sessionEnvironmentNames) {
    $previousSessionEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
}
$previousConfigEnvironment = @{}

function Restore-ClaudexSessionEnvironment {
    foreach ($environmentName in $previousConfigEnvironment.Keys) {
        $previousValue = $previousConfigEnvironment[$environmentName]
        if ($null -eq $previousValue) { Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($environmentName, [string] $previousValue, 'Process') }
    }
    if ($null -eq $previousSessionMode) { Remove-Item Env:CLAUDEX_SESSION_MODE -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_SESSION_MODE = $previousSessionMode }
    if ($null -eq $previousEffortLevel) { Remove-Item Env:CLAUDE_CODE_EFFORT_LEVEL -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_CODE_EFFORT_LEVEL = $previousEffortLevel }
    if ($null -eq $previousModelMode) { Remove-Item Env:CLAUDEX_MODEL_MODE -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_MODEL_MODE = $previousModelMode }
    if ($null -eq $previousInteractiveTui) { Remove-Item Env:CLAUDEX_INTERACTIVE_TUI -ErrorAction SilentlyContinue }
    else { $env:CLAUDEX_INTERACTIVE_TUI = $previousInteractiveTui }
    foreach ($environmentName in $sessionEnvironmentNames) {
        $previousValue = $previousSessionEnvironment[$environmentName]
        if ($null -eq $previousValue) { Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($environmentName, [string] $previousValue, 'Process') }
    }
}
$utf8 = New-Object Text.UTF8Encoding($false)

$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$configFile = Join-Path $configDir 'env'
$settingsFile = if ($env:CLAUDEX_SETTINGS_FILE) { $env:CLAUDEX_SETTINGS_FILE } else { Join-Path $configDir 'settings.json' }
$curlCommand = if ($env:CLAUDEX_CURL_BIN) { $env:CLAUDEX_CURL_BIN } else { 'curl.exe' }

function Fail([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine("claudex: $Message")
    Restore-ClaudexSessionEnvironment
    exit $Code
}

function Exit-Claudex([int] $Code = 0) {
    Restore-ClaudexSessionEnvironment
    exit $Code
}

$script:lastPrivateBoundarySucceeded = $false
$script:lastPrivateBoundaryExitCode = 1
function Invoke-WithoutPrivateManagedEnvironment {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [string[]] $PreserveNames = @()
    )
    $savedEnvironment = @{}
    $privateEnvironmentNames = @($sessionEnvironmentNames + @(
        'CLAUDEX_SESSION_MODE', 'CLAUDEX_MODEL_MODE', 'CLAUDEX_INTERACTIVE_TUI',
        'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDEX_CODEX_AUTH_FILE', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE'
    ) | Select-Object -Unique)
    foreach ($environmentName in $privateEnvironmentNames) {
        if ($PreserveNames -contains $environmentName) { continue }
        $savedEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
        Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
    }
    try {
        $global:LASTEXITCODE = $null
        & $Action
        $script:lastPrivateBoundarySucceeded = $?
        $script:lastPrivateBoundaryExitCode = if ($null -ne $LASTEXITCODE) {
            [int] $LASTEXITCODE
        } elseif ($script:lastPrivateBoundarySucceeded) { 0 } else { 1 }
    } finally {
        foreach ($environmentName in $savedEnvironment.Keys) {
            $savedValue = $savedEnvironment[$environmentName]
            if ($null -eq $savedValue) { Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($environmentName, [string] $savedValue, 'Process') }
        }
    }
}

function Resolve-HarnessCommand([string] $Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command -or -not $command.Source) { return $command }
    $extension = [IO.Path]::GetExtension([string] $command.Source).ToLowerInvariant()
    if ($extension -notin @('.cmd', '.bat')) { return $command }
    $powerShellShim = [IO.Path]::ChangeExtension([string] $command.Source, '.ps1')
    if (-not (Test-Path -LiteralPath $powerShellShim -PathType Leaf)) { return $command }
    $shimCommand = Get-Command $powerShellShim -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shimCommand) { return $shimCommand }
    return $command
}

function Protect-PrivatePath([string] $Path, [bool] $Directory) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
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

# Options whose following token is data, even when that token resembles
# another option. Keep every launcher rescan on the same arity-aware grammar.
$claudeRequiredValueOptions = @(
    '--add-dir', '--agent', '--agents', '--allowedTools', '--allowed-tools',
    '--append-system-prompt', '--append-system-prompt-file', '--betas', '--debug-file',
    '--disallowedTools', '--disallowed-tools', '--effort', '--fallback-model', '--file',
    '--input-format', '--json-schema', '--max-budget-usd', '--mcp-config', '--model',
    '--name', '-n', '--output-format', '--permission-mode', '--plugin-dir', '--plugin-url',
    '--remote-control-session-name-prefix', '--session-id', '--setting-sources', '--settings',
    '--system-prompt', '--system-prompt-file', '--tools'
)
$claudeOptionalValueOptions = @(
    '--debug', '-d', '--from-pr', '--prompt-suggestions', '--remote-control', '--rc',
    '--resume', '-r', '--worktree', '-w'
)

function Remove-ProcessEnvironmentVariables([string[]] $Names) {
    foreach ($environmentName in @($Names | Select-Object -Unique)) {
        Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
    }
}

function Get-OwnedLockField([string] $OwnerFile, [string] $Field) {
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

function Get-LockGenerationNonce([string] $LockDirectory) {
    $generationFile = Join-Path $LockDirectory 'generation'
    if (-not (Test-Path -LiteralPath $generationFile -PathType Leaf)) { return '' }
    try { return [IO.File]::ReadAllText($generationFile).Trim() } catch { return '' }
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

function Get-LegacyLockPid([string] $Directory) {
    foreach ($name in @('owner', 'owner-pid')) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $first = ([IO.File]::ReadAllText($path).Trim() -split '\s+')[0]
            $legacyPid = 0
            if ([int]::TryParse($first, [ref] $legacyPid) -and $legacyPid -gt 0) { return $legacyPid }
        } catch { }
    }
    return 0
}

function Test-LockDirectoryLegacyOwner([string] $Directory) {
    $ownerPidPath = Join-Path $Directory 'owner-pid'
    if (Test-Path -LiteralPath $ownerPidPath -PathType Leaf) { return $true }
    $ownerPath = Join-Path $Directory 'owner'
    return (Test-Path -LiteralPath $ownerPath -PathType Leaf) -and (Get-Item -LiteralPath $ownerPath).Length -gt 0 -and
        -not (Get-OwnedLockField $ownerPath 'nonce')
}

function Test-LockDirectoryUnknownEntries([string] $Directory) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)) {
        if ($entry.Name -notin @('owner', 'owner-pid', 'generation')) { return $true }
    }
    return $false
}

function Get-LockDirectoryIdentity([string] $Directory) {
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
        try { return [ClaudexNativeDirectoryIdentity]::GetIdentity($Directory) }
        catch { return '' }
    }
    $stat = Get-Command stat -ErrorAction SilentlyContinue
    if (-not $stat) { return '' }
    try { $identity = (& $stat.Source -c '%d:%i' -- $Directory 2>$null | Select-Object -First 1).Trim() }
    catch { $identity = '' }
    if ($identity -notmatch '^[0-9]+:[0-9]+$') {
        try { $identity = (& $stat.Source -f '%d:%i' $Directory 2>$null | Select-Object -First 1).Trim() }
        catch { $identity = '' }
    }
    if ($identity -match '^[0-9]+:[0-9]+$') { return $identity }
    return ''
}

function Remove-LegacyLockDirectoryFiles([string] $Directory) {
    foreach ($name in @('owner', 'owner-pid', 'generation')) {
        Remove-Item -LiteralPath (Join-Path $Directory $name) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
}

function Publish-LockFile([string] $Source, [string] $Destination) {
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE -eq '1') {
        if (-not $env:CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE_MATCH -or
            $Destination.Contains($env:CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE_MATCH)) {
            throw 'forced lock publication failure'
        }
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

function Remove-IncompleteLockDirectory([string] $LockDirectory, [string] $ExpectedNonce = '', [bool] $PreserveDirectory = $false) {
    if (-not (Test-Path -LiteralPath $LockDirectory -PathType Container)) { return $true }
    $quarantine = $LockDirectory + '.quarantine.incomplete.' + $PID + '.' + [guid]::NewGuid().ToString('N')
    try { Move-Item -LiteralPath $LockDirectory -Destination $quarantine -ErrorAction Stop }
    catch { return $false }
    $movedNonce = Get-LockGenerationNonce $quarantine
    $ownerNonce = Get-OwnedLockField (Join-Path $quarantine 'owner') 'nonce'
    if (-not $movedNonce) { $movedNonce = $ownerNonce }
    $legacyPid = Get-LegacyLockPid $quarantine
    $legacyOwner = ((Test-Path -LiteralPath (Join-Path $quarantine 'owner') -PathType Leaf) -and
        (Get-Item -LiteralPath (Join-Path $quarantine 'owner')).Length -gt 0) -or
        ((Test-Path -LiteralPath (Join-Path $quarantine 'owner-pid') -PathType Leaf) -and
        (Get-Item -LiteralPath (Join-Path $quarantine 'owner-pid')).Length -gt 0)
    if ($PreserveDirectory) {
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_LOCK_PRESERVE_FILE) {
            [IO.File]::WriteAllText($env:CLAUDEX_TEST_LOCK_PRESERVE_FILE, "preserved`n", $utf8)
        }
        if ($ExpectedNonce -and $movedNonce -eq $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $quarantine 'generation') -Force -ErrorAction SilentlyContinue
        }
        if ($ExpectedNonce -and $ownerNonce -eq $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $quarantine 'owner') -Force -ErrorAction SilentlyContinue
        }
        [void] (Restore-LockBarrier $LockDirectory $quarantine)
        return $false
    }
    if ((Test-LockDirectoryLegacyOwner $quarantine) -or (Test-LockDirectoryUnknownEntries $quarantine)) {
        if ($ExpectedNonce -and $movedNonce -eq $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $quarantine 'generation') -Force -ErrorAction SilentlyContinue
        }
        if ($ExpectedNonce -and $ownerNonce -eq $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $quarantine 'owner') -Force -ErrorAction SilentlyContinue
        }
        [void] (Restore-LockBarrier $LockDirectory $quarantine)
        return $false
    }
    if ($ExpectedNonce -and $ownerNonce -eq $ExpectedNonce -and $movedNonce -eq $ExpectedNonce) {
        Remove-LockDirectoryFiles $quarantine
        return $true
    }
    if ($movedNonce -and $movedNonce -ne $ExpectedNonce) {
        [void] (Restore-LockBarrier $LockDirectory $quarantine)
        return $false
    }
    Remove-LockDirectoryFiles $quarantine
    return -not (Test-Path -LiteralPath $quarantine)
}

function Restore-LockBarrier([string] $LockDirectory, [string] $Barrier) {
    foreach ($attempt in 1..250) {
        if (-not (Test-Path -LiteralPath $LockDirectory)) {
            try { Move-Item -LiteralPath $Barrier -Destination $LockDirectory -ErrorAction Stop; return $true }
            catch { }
        }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

function Get-OwnedLockAgeSeconds([string] $LockDirectory) {
    try {
        return [math]::Max(0, ([DateTime]::UtcNow - (Get-Item -LiteralPath $LockDirectory -ErrorAction Stop).LastWriteTimeUtc).TotalSeconds)
    } catch { return 0 }
}

function Test-OwnedLockOwnerCurrent([string] $OwnerFile) {
    $ownerPid = 0
    if (-not [int]::TryParse((Get-OwnedLockField $OwnerFile 'pid'), [ref] $ownerPid) -or $ownerPid -le 0) { return $false }
    $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    $recordedIdentity = Get-OwnedLockField $OwnerFile 'identity'
    if ([string]::IsNullOrWhiteSpace($recordedIdentity)) { return $true }
    try { return $recordedIdentity -eq [string] $process.StartTime.ToUniversalTime().Ticks }
    catch { return $true }
}

function Recover-LockBarriers([string] $LockDirectory, [int] $LegacyOwnerlessSeconds) {
    foreach ($barrierInfo in @(Get-LockBarriers $LockDirectory)) {
        $barrier = $barrierInfo.FullName
        $ownerFile = Join-Path $barrier 'owner'
        $ownerNonce = Get-OwnedLockField $ownerFile 'nonce'
        $generationNonce = Get-LockGenerationNonce $barrier
        $legacyPid = Get-LegacyLockPid $barrier
        $legacyOwnerPresent = Test-LockDirectoryLegacyOwner $barrier
        $age = Get-OwnedLockAgeSeconds $barrier
        if ($legacyOwnerPresent) {
            # owner-pid is the prior-format source of truth. Sanitize any
            # interrupted structured publication before evaluating that owner.
            Remove-Item -LiteralPath (Join-Path $barrier 'generation') -Force -ErrorAction SilentlyContinue
            if ($ownerNonce) { Remove-Item -LiteralPath (Join-Path $barrier 'owner') -Force -ErrorAction SilentlyContinue }
            $legacyPid = Get-LegacyLockPid $barrier
            if ($legacyPid -gt 0 -and $null -ne (Get-Process -Id $legacyPid -ErrorAction SilentlyContinue)) {
                if (-not (Test-Path -LiteralPath $LockDirectory)) {
                    try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { }
                }
            } elseif ($legacyPid -gt 0 -and $age -ge $LegacyOwnerlessSeconds) {
                Remove-LegacyLockDirectoryFiles $barrier
            } elseif (-not (Test-Path -LiteralPath $LockDirectory)) {
                try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { }
            }
        } elseif ($ownerNonce -and (Test-OwnedLockOwnerCurrent $ownerFile)) {
            if (-not (Test-Path -LiteralPath $LockDirectory)) {
                try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { }
            }
        } elseif ($ownerNonce -and $age -ge 2) {
            Remove-LockDirectoryFiles $barrier
        } elseif ($legacyPid -gt 0 -and $age -ge $LegacyOwnerlessSeconds) {
            Remove-LegacyLockDirectoryFiles $barrier
        } elseif ($generationNonce -and $age -ge 2) {
            Remove-LockDirectoryFiles $barrier
        } elseif (-not $generationNonce -and $age -ge $LegacyOwnerlessSeconds) {
            Remove-LockDirectoryFiles $barrier
        }
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
    try { Move-Item -LiteralPath $LockDirectory -Destination $quarantine -ErrorAction Stop }
    catch { return $false }
    Invoke-LockTestPause 'AFTER_RENAME' $LockDirectory
    if (-not (Test-Path -LiteralPath $quarantine -PathType Container)) { return $false }
    $movedNonce = Get-LockGenerationNonce $quarantine
    if (-not $movedNonce) { $movedNonce = Get-OwnedLockField (Join-Path $quarantine 'owner') 'nonce' }
    if ((Test-LockDirectoryLegacyOwner $quarantine) -or (Test-LockDirectoryUnknownEntries $quarantine)) {
        if ($movedNonce -eq $ExpectedNonce) { Remove-Item -LiteralPath (Join-Path $quarantine 'generation') -Force -ErrorAction SilentlyContinue }
        if ((Get-OwnedLockField (Join-Path $quarantine 'owner') 'nonce') -eq $ExpectedNonce) {
            Remove-Item -LiteralPath (Join-Path $quarantine 'owner') -Force -ErrorAction SilentlyContinue
        }
        [void] (Restore-LockBarrier $LockDirectory $quarantine)
        return $false
    }
    if ($movedNonce -eq $ExpectedNonce) {
        Remove-LockDirectoryFiles $quarantine
        return $true
    }
    [void] (Restore-LockBarrier $LockDirectory $quarantine)
    return $false
}

function Recover-OwnedLockGeneration([string] $LockDirectory, [string] $ExpectedNonce) {
    foreach ($barrierInfo in @(Get-LockBarriers $LockDirectory)) {
        $barrier = $barrierInfo.FullName
        $movedNonce = Get-LockGenerationNonce $barrier
        if (-not $movedNonce) { $movedNonce = Get-OwnedLockField (Join-Path $barrier 'owner') 'nonce' }
        if ($movedNonce -ne $ExpectedNonce) { continue }
        if ((Test-LockDirectoryLegacyOwner $barrier) -or (Test-LockDirectoryUnknownEntries $barrier)) {
            Remove-Item -LiteralPath (Join-Path $barrier 'generation') -Force -ErrorAction SilentlyContinue
            if ((Get-OwnedLockField (Join-Path $barrier 'owner') 'nonce') -eq $ExpectedNonce) {
                Remove-Item -LiteralPath (Join-Path $barrier 'owner') -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path -LiteralPath $LockDirectory)) {
                try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { }
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $LockDirectory)) {
            try { Move-Item -LiteralPath $barrier -Destination $LockDirectory -ErrorAction Stop } catch { }
        }
    }
    $currentNonce = Get-LockGenerationNonce $LockDirectory
    if (-not $currentNonce) { $currentNonce = Get-OwnedLockField (Join-Path $LockDirectory 'owner') 'nonce' }
    if ($currentNonce -eq $ExpectedNonce -and @(Get-LockBarriers $LockDirectory).Count -eq 0) {
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE) {
            [IO.File]::WriteAllText($env:CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE, "recovered`n", $utf8)
        }
        return $true
    }
    if ($currentNonce -eq $ExpectedNonce) {
        [void] (Remove-OwnedLockGeneration $LockDirectory $ExpectedNonce)
    }
    foreach ($barrierInfo in @(Get-LockBarriers $LockDirectory)) {
        $barrier = $barrierInfo.FullName
        $movedNonce = Get-LockGenerationNonce $barrier
        if (-not $movedNonce) { $movedNonce = Get-OwnedLockField (Join-Path $barrier 'owner') 'nonce' }
        if ($movedNonce -eq $ExpectedNonce -and -not (Test-LockDirectoryLegacyOwner $barrier) -and
            -not (Test-LockDirectoryUnknownEntries $barrier)) { Remove-LockDirectoryFiles $barrier }
    }
    return $false
}

function Acquire-OwnedLock([string] $LockDirectory, [int] $Attempts = 100, [int] $DelayMilliseconds = 20, [int] $LegacyOwnerlessSeconds = 60) {
    $parent = Split-Path $LockDirectory -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $ownerFile = Join-Path $LockDirectory 'owner'
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        Recover-LockBarriers $LockDirectory $LegacyOwnerlessSeconds
        if (@(Get-LockBarriers $LockDirectory).Count -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds; continue }
        $created = $false
        $ownerPublished = $false
        $generationPublished = $false
        $ownerTemporary = ''
        $generationTemporary = ''
        $directoryIdentity = ''
        $directoryReplaced = $false
        $nonce = [guid]::NewGuid().ToString('N')
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        $identity = [string] $currentProcess.StartTime.ToUniversalTime().Ticks
        $ownerTemporary = Join-Path $parent ('.lock-owner.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $generationTemporary = Join-Path $parent ('.lock-generation.' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($ownerTemporary, "pid=$PID`nidentity=$identity`nnonce=$nonce`n", $utf8)
        [IO.File]::WriteAllText($generationTemporary, "$nonce`n", $utf8)
        Protect-PrivatePath $ownerTemporary $false
        Protect-PrivatePath $generationTemporary $false
        try {
            New-Item -Path $LockDirectory -ItemType Directory -ErrorAction Stop | Out-Null
            $created = $true
            $directoryIdentity = Get-LockDirectoryIdentity $LockDirectory
            Invoke-LockTestPause 'AFTER_MKDIR' $LockDirectory
            $directoryReplaced = -not $directoryIdentity -or (Get-LockDirectoryIdentity $LockDirectory) -ne $directoryIdentity
            if ($directoryReplaced) { throw 'lock directory identity changed' }
            Publish-LockFile $generationTemporary (Join-Path $LockDirectory 'generation')
            $generationPublished = $true
            if ((Get-LockDirectoryIdentity $LockDirectory) -ne $directoryIdentity) { throw 'lock directory identity changed' }
            if ((Get-LockGenerationNonce $LockDirectory) -ne $nonce) { throw 'lock generation publication changed' }
            Publish-LockFile $ownerTemporary $ownerFile
            $ownerPublished = $true
            if ((Get-LockDirectoryIdentity $LockDirectory) -ne $directoryIdentity) { throw 'lock directory identity changed' }
            if ((Get-OwnedLockField $ownerFile 'nonce') -ne $nonce) { throw 'lock ownership publication changed' }
            if (@(Get-LockBarriers $LockDirectory).Count -gt 0 -or (Test-LockDirectoryLegacyOwner $LockDirectory) -or
                (Test-LockDirectoryUnknownEntries $LockDirectory)) { throw 'lock ownership publication changed' }
            Protect-PrivatePath $ownerFile $false
            Protect-PrivatePath (Join-Path $LockDirectory 'generation') $false
            Remove-Item -LiteralPath $ownerTemporary, $generationTemporary -Force -ErrorAction SilentlyContinue
            Invoke-LockTestPause 'AFTER_PUBLISH' $LockDirectory
            if ((Get-LockDirectoryIdentity $LockDirectory) -ne $directoryIdentity) {
                if ((Recover-OwnedLockGeneration $LockDirectory $nonce) -and
                    (Get-LockDirectoryIdentity $LockDirectory) -eq $directoryIdentity) { return $nonce }
                if ((Get-LockGenerationNonce $LockDirectory) -eq $nonce -or
                    (Get-OwnedLockField (Join-Path $LockDirectory 'owner') 'nonce') -eq $nonce) {
                    [void] (Remove-IncompleteLockDirectory $LockDirectory $nonce $true)
                }
                Start-Sleep -Milliseconds $DelayMilliseconds
                continue
            }
            if ((Get-LockGenerationNonce $LockDirectory) -ne $nonce -or @(Get-LockBarriers $LockDirectory).Count -gt 0 -or
                (Test-LockDirectoryLegacyOwner $LockDirectory) -or (Test-LockDirectoryUnknownEntries $LockDirectory)) {
                if ((Test-LockDirectoryLegacyOwner $LockDirectory) -or (Test-LockDirectoryUnknownEntries $LockDirectory)) {
                    [void] (Remove-IncompleteLockDirectory $LockDirectory $nonce)
                    Start-Sleep -Milliseconds $DelayMilliseconds
                    continue
                }
                if (Recover-OwnedLockGeneration $LockDirectory $nonce) { return $nonce }
                Start-Sleep -Milliseconds $DelayMilliseconds
                continue
            }
            if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE) {
                [IO.File]::WriteAllText($env:CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE, "recovered`n", $utf8)
            }
            return $nonce
        } catch {
            if ($created) {
                if ($directoryReplaced -or ($directoryIdentity -and (Get-LockDirectoryIdentity $LockDirectory) -ne $directoryIdentity)) {
                    if ($generationPublished -or $ownerPublished) {
                        [void] (Remove-IncompleteLockDirectory $LockDirectory $nonce $true)
                    }
                } elseif ((Test-LockDirectoryLegacyOwner $LockDirectory) -or (Test-LockDirectoryUnknownEntries $LockDirectory)) {
                    [void] (Remove-IncompleteLockDirectory $LockDirectory $nonce)
                } elseif (-not $ownerPublished -or -not (Remove-OwnedLockGeneration $LockDirectory $nonce)) {
                    [void] (Remove-IncompleteLockDirectory $LockDirectory $nonce)
                }
            }
        }
        Remove-Item -LiteralPath $ownerTemporary, $generationTemporary -Force -ErrorAction SilentlyContinue

        $age = Get-OwnedLockAgeSeconds $LockDirectory
        $observedNonce = Get-OwnedLockField $ownerFile 'nonce'
        $legacyPid = Get-LegacyLockPid $LockDirectory
        $legacyOwnerPresent = Test-LockDirectoryLegacyOwner $LockDirectory
        if ($legacyOwnerPresent -and $observedNonce) {
            $legacyQuarantine = $LockDirectory + '.quarantine.legacy.' + $PID + '.' + [guid]::NewGuid().ToString('N')
            try { Move-Item -LiteralPath $LockDirectory -Destination $legacyQuarantine -ErrorAction Stop }
            catch { $legacyQuarantine = '' }
            if ($legacyQuarantine) {
                if (Test-LockDirectoryLegacyOwner $legacyQuarantine) {
                    if ((Get-LockGenerationNonce $legacyQuarantine) -eq $observedNonce) {
                        Remove-Item -LiteralPath (Join-Path $legacyQuarantine 'generation') -Force -ErrorAction SilentlyContinue
                    }
                    if ((Get-OwnedLockField (Join-Path $legacyQuarantine 'owner') 'nonce') -eq $observedNonce) {
                        Remove-Item -LiteralPath (Join-Path $legacyQuarantine 'owner') -Force -ErrorAction SilentlyContinue
                    }
                    $legacyPid = Get-LegacyLockPid $legacyQuarantine
                    if ($legacyPid -gt 0 -and $null -ne (Get-Process -Id $legacyPid -ErrorAction SilentlyContinue)) {
                        [void] (Restore-LockBarrier $LockDirectory $legacyQuarantine)
                    } elseif ($legacyPid -gt 0 -and $age -ge $LegacyOwnerlessSeconds) {
                        Remove-LegacyLockDirectoryFiles $legacyQuarantine
                    } else { [void] (Restore-LockBarrier $LockDirectory $legacyQuarantine) }
                } else { [void] (Restore-LockBarrier $LockDirectory $legacyQuarantine) }
            }
        } elseif ($legacyPid -gt 0 -and $null -ne (Get-Process -Id $legacyPid -ErrorAction SilentlyContinue)) {
            # Prior-format live owners are never reclaimed solely due to age.
        } elseif ($legacyOwnerPresent -and $legacyPid -gt 0 -and $age -ge $LegacyOwnerlessSeconds) {
            $legacyQuarantine = $LockDirectory + '.quarantine.legacy.' + $PID + '.' + [guid]::NewGuid().ToString('N')
            try { Move-Item -LiteralPath $LockDirectory -Destination $legacyQuarantine -ErrorAction Stop }
            catch { $legacyQuarantine = '' }
            if ($legacyQuarantine) {
                $movedLegacyPid = Get-LegacyLockPid $legacyQuarantine
                if ($movedLegacyPid -gt 0 -and $null -ne (Get-Process -Id $movedLegacyPid -ErrorAction SilentlyContinue)) {
                    [void] (Restore-LockBarrier $LockDirectory $legacyQuarantine)
                } else { Remove-LegacyLockDirectoryFiles $legacyQuarantine }
            }
        } elseif ($legacyOwnerPresent) {
            # Preserve unknown and recent prior formats conservatively.
        } elseif ($observedNonce) {
            if ($age -ge 2 -and -not (Test-OwnedLockOwnerCurrent $ownerFile)) {
                [void] (Remove-OwnedLockGeneration $LockDirectory $observedNonce)
            }
        } elseif ((Get-LockGenerationNonce $LockDirectory) -and $age -ge 2) {
            [void] (Remove-OwnedLockGeneration $LockDirectory (Get-LockGenerationNonce $LockDirectory))
        } elseif ($age -ge $LegacyOwnerlessSeconds -and (Test-Path -LiteralPath $LockDirectory -PathType Container)) {
            $legacyQuarantine = $LockDirectory + '.quarantine.legacy.' + $PID + '.' + [guid]::NewGuid().ToString('N')
            try { Move-Item -LiteralPath $LockDirectory -Destination $legacyQuarantine -ErrorAction Stop }
            catch { $legacyQuarantine = '' }
            if ($legacyQuarantine) {
                $legacyPid = Get-LegacyLockPid $legacyQuarantine
                if ((Get-LockGenerationNonce $legacyQuarantine) -or (Get-OwnedLockField (Join-Path $legacyQuarantine 'owner') 'nonce') -or
                    ($legacyPid -gt 0 -and $null -ne (Get-Process -Id $legacyPid -ErrorAction SilentlyContinue)) -or
                    (Test-LockDirectoryUnknownEntries $legacyQuarantine)) {
                    [void] (Restore-LockBarrier $LockDirectory $legacyQuarantine)
                } elseif ($legacyPid -gt 0) { Remove-LegacyLockDirectoryFiles $legacyQuarantine }
                else { Remove-LockDirectoryFiles $legacyQuarantine }
            }
        }
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
    return ''
}

function Release-OwnedLock([string] $LockDirectory, [string] $Nonce) {
    [void] (Remove-OwnedLockGeneration $LockDirectory $Nonce)
}

function Invoke-InternalClaudeUpdate {
    $stamp = Join-Path $internalClaudeUpdateDirectory 'last-success'
    $lock = Join-Path $internalClaudeUpdateDirectory 'lock'
    [IO.Directory]::CreateDirectory($internalClaudeUpdateDirectory) | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $last = 0L
    if (Test-Path -LiteralPath $stamp -PathType Leaf) {
        [long]::TryParse(([IO.File]::ReadAllText($stamp).Trim()), [ref] $last) | Out-Null
    }
    if ($now - $last -lt $internalClaudeUpdateInterval) { return }
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_UPDATE_WORKER_ATTEMPT_FILE) {
        Add-Content -LiteralPath $env:CLAUDEX_TEST_UPDATE_WORKER_ATTEMPT_FILE -Value "start $PID" -Encoding UTF8
    }
    $nonce = Acquire-OwnedLock $lock 5 20 3600
    if (-not $nonce) {
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_UPDATE_WORKER_ATTEMPT_FILE) {
            Add-Content -LiteralPath $env:CLAUDEX_TEST_UPDATE_WORKER_ATTEMPT_FILE -Value "blocked $PID" -Encoding UTF8
        }
        return
    }
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $last = 0L
        if (Test-Path -LiteralPath $stamp -PathType Leaf) {
            [long]::TryParse(([IO.File]::ReadAllText($stamp).Trim()), [ref] $last) | Out-Null
        }
        if ($now - $last -lt $internalClaudeUpdateInterval) { return }
        Remove-ProcessEnvironmentVariables @($sessionEnvironmentNames + @(
            'CLAUDEX_SESSION_MODE', 'CLAUDEX_MODEL_MODE', 'CLAUDEX_INTERACTIVE_TUI',
            'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_NO_FLICKER', 'CLAUDE_CODE_ACCESSIBILITY',
            'CLAUDEX_INTERNAL_UPDATE_NONCE'
        ))
        $log = Join-Path $internalClaudeUpdateDirectory 'claude-update.log'
        $global:LASTEXITCODE = $null
        & $internalClaudeUpdatePath update *> $log
        $updateSucceeded = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE -eq 0 } else { $? }
        if ($updateSucceeded) {
            $temporary = Join-Path $internalClaudeUpdateDirectory ('.last-success.' + [guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::WriteAllText($temporary, ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString() + "`n"), $utf8)
            Protect-PrivatePath $temporary $false
            Move-Item -LiteralPath $temporary -Destination $stamp -Force
            Protect-PrivatePath $stamp $false
        }
    } finally {
        Release-OwnedLock $lock $nonce
    }
}

if ($claudexInternalClaudeUpdate) {
    Invoke-InternalClaudeUpdate
    Exit-Claudex 0
}

# Route native harnesses and Anthropic-hosted features before reading the
# Claudex env file. This prevents managed credentials from entering a native
# child merely because they exist in Claudex's private configuration.
$nativeHarness = ''
$nativeArguments = @()
$forceFirstPartyClaude = $false
if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -in @('codex', 'claude')) {
    $nativeHarness = [string] $ClaudeArguments[0]
    if ($ClaudeArguments.Count -gt 1) { $nativeArguments = @($ClaudeArguments[1..($ClaudeArguments.Count - 1)]) }
    else { $nativeArguments = @() }
} elseif ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -in @('remote-control', 'ultrareview')) {
    $nativeHarness = 'claude'
    $nativeArguments = [string[]] @($ClaudeArguments)
    $forceFirstPartyClaude = $true
} else {
    for ($nativeScanIndex = 0; $nativeScanIndex -lt $ClaudeArguments.Count; $nativeScanIndex++) {
        $nativeScanArgument = [string] $ClaudeArguments[$nativeScanIndex]
        if ($nativeScanArgument -eq '--') { break }
        $nativeScanOption = $nativeScanArgument
        $nativeScanHasInlineValue = $false
        if ($nativeScanArgument -match '^(--[^=]+)=(.*)$') {
            $nativeScanOption = $Matches[1]
            $nativeScanHasInlineValue = $true
        } elseif ($nativeScanArgument -match '^(-[drw])=?.+$') {
            $nativeScanOption = $Matches[1]
            $nativeScanHasInlineValue = $true
        }
        if ($nativeScanOption -in @('--remote-control', '--rc')) {
            $nativeHarness = 'claude'
            $nativeArguments = [string[]] @($ClaudeArguments)
            $forceFirstPartyClaude = $true
            break
        }
        if (-not $nativeScanHasInlineValue -and $nativeScanOption -in $claudeRequiredValueOptions) { $nativeScanIndex++ }
        elseif (-not $nativeScanHasInlineValue -and $nativeScanOption -in $claudeOptionalValueOptions -and
            $nativeScanIndex + 1 -lt $ClaudeArguments.Count -and -not ([string] $ClaudeArguments[$nativeScanIndex + 1]).StartsWith('-')) {
            $nativeScanIndex++
        }
    }
}
if ($nativeHarness) {
    $nativeCommand = Resolve-HarnessCommand $nativeHarness
    if (-not $nativeCommand) {
        $nativeLabel = if ($nativeHarness -eq 'codex') { 'Codex CLI' } else { 'Claude Code' }
        Fail "$nativeLabel was not found. Install it and retry."
    }
    $managedParentSession = $env:CLAUDEX_MANAGED_SESSION -eq '1'
    $nativeClaudeProfile = [Environment]::GetEnvironmentVariable('CLAUDEX_CLAUDE_CONFIG_DIR', 'Process')
    $cleanBun = [string] $env:BUN_OPTIONS
    if ($managedParentSession) {
        $managedPreload = '--preload ' + (Join-Path $configDir 'preload.cjs').Replace('\', '/').Replace(' ', '\ ')
        while ($cleanBun -eq $managedPreload -or $cleanBun.StartsWith($managedPreload + ' ')) {
            $cleanBun = $cleanBun.Substring($managedPreload.Length).TrimStart()
        }
        foreach ($environmentName in $sessionEnvironmentNames) {
            Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
        }
        foreach ($environmentName in @(
            'CLAUDE_CODE_NO_FLICKER', 'CLAUDE_CODE_ACCESSIBILITY', 'CLAUDEX_MODEL_MODE',
            'CLAUDEX_SESSION_MODE', 'CLAUDEX_INTERACTIVE_TUI', 'CLAUDE_CODE_EFFORT_LEVEL'
        )) {
            Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
        }
    } elseif ($forceFirstPartyClaude) {
        foreach ($environmentName in $sessionEnvironmentNames | Where-Object {
            $_ -in @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDEX_CHATGPT_PLAN_LABEL', 'CLAUDEX_MANAGED_SESSION',
                'CLAUDEX_CODEX_AUTH_FILE', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE') -or
            $_ -in $competingProviderEnvironmentNames -or
            $_ -like 'ANTHROPIC_*_BASE_URL' -or
            $_ -like 'ANTHROPIC_DEFAULT_*' -or $_ -like 'CLAUDE_CODE_*MODEL*' -or
            $_ -in @('CLAUDE_CODE_ALWAYS_ENABLE_EFFORT', 'CLAUDE_CODE_DISABLE_1M_CONTEXT',
                'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY', 'CLAUDE_CODE_MAX_RETRIES', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
                'CLAUDE_CODE_AUTO_COMPACT_WINDOW', 'CLAUDEX_NO_SESSION_PERSISTENCE') -or
            $_ -like 'CLAUDEX_PROXY_*'
        }) {
            Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
        }
    }
    # The proxy bearer is Claudex-private even when the caller set it directly.
    Remove-Item Env:CLAUDEX_PROXY_TOKEN -ErrorAction SilentlyContinue
    if ($nativeHarness -eq 'claude') {
        if ($nativeClaudeProfile) { $env:CLAUDE_CONFIG_DIR = $nativeClaudeProfile }
        if ($managedParentSession) {
            if ($cleanBun) { $env:BUN_OPTIONS = $cleanBun } else { Remove-Item Env:BUN_OPTIONS -ErrorAction SilentlyContinue }
        }
    }
    $global:LASTEXITCODE = $null
    try {
        & $nativeCommand @nativeArguments
        $nativeSucceeded = $?
        $nativeExitCode = if ($null -ne $LASTEXITCODE) { [int] $LASTEXITCODE } elseif ($nativeSucceeded) { 0 } else { 1 }
    } finally {
        Restore-ClaudexSessionEnvironment
    }
    exit $nativeExitCode
}

function Get-NodeMajorVersion {
    $nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nodeCommand) { return 0 }
    try { $versionText = [string] ((& $nodeCommand.Source --version 2>$null | Select-Object -First 1)) }
    catch { return 0 }
    $major = 0
    if ($versionText -match '^v?(\d+)(?:\.|$)' -and [int]::TryParse($Matches[1], [ref] $major)) { return $major }
    return 0
}

function Assert-SkillBridgeNode {
    $nodeMajor = Get-NodeMajorVersion
    if ($nodeMajor -ge 18) { return }
    $detected = if ($nodeMajor -gt 0) { "found Node.js $nodeMajor" } else { 'Node.js was not found' }
    Fail "Node.js 18 or newer is required for skill compatibility ($detected); rerun the Claudex installer to install or upgrade Node.js."
}

if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($configFile)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2].Trim()
            if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
                ($value.StartsWith('"') -and $value.EndsWith('"'))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $value = $value -replace '\\ ', ' '
            if (-not $previousConfigEnvironment.ContainsKey($name)) {
                $previousConfigEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Env-OrDefault([string] $Name, [string] $Default) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

$proxyToken = Env-OrDefault 'CLAUDEX_PROXY_TOKEN' ''
$proxyUrl = Env-OrDefault 'CLAUDEX_PROXY_URL' 'http://127.0.0.1:8318'
$model = Env-OrDefault 'CLAUDEX_MODEL' 'gpt-5.6-sol'
$permissionMode = Env-OrDefault 'CLAUDEX_PERMISSION_MODE' 'auto'
$autoModeModel = Env-OrDefault 'CLAUDEX_AUTO_MODE_MODEL' 'gpt-5.6-terra'
$backgroundModel = Env-OrDefault 'CLAUDEX_BACKGROUND_MODEL' 'gpt-5.6-luna'
$toolConcurrency = Env-OrDefault 'CLAUDEX_MAX_TOOL_USE_CONCURRENCY' '3'
$agentConcurrency = Env-OrDefault 'CLAUDEX_MAX_AGENT_CONCURRENCY' '3'
$maxRetries = Env-OrDefault 'CLAUDEX_MAX_RETRIES' '15'
$contextWindow = Env-OrDefault 'CLAUDEX_CONTEXT_WINDOW' '400000'
$compactWindow = Env-OrDefault 'CLAUDEX_AUTO_COMPACT_WINDOW' '280000'
$mousePointer = Env-OrDefault 'CLAUDEX_MOUSE_POINTER_SHAPE' 'pointer'
$usageDisplay = Env-OrDefault 'CLAUDEX_USAGE_DISPLAY' 'on'
$usageRefresh = Env-OrDefault 'CLAUDEX_USAGE_REFRESH_SECONDS' '300'
$usageTimeout = Env-OrDefault 'CLAUDEX_USAGE_TIMEOUT_SECONDS' '8'
$usageMaxStale = Env-OrDefault 'CLAUDEX_USAGE_MAX_STALE_SECONDS' '86400'
$usageSource = Env-OrDefault 'CLAUDEX_USAGE_SOURCE' 'auto'
$usageAlert = Env-OrDefault 'CLAUDEX_USAGE_ALERT_PERCENT' '20'
$claudeAutoUpdate = Env-OrDefault 'CLAUDEX_CLAUDE_AUTO_UPDATE' 'on'
$claudeUpdateInterval = Env-OrDefault 'CLAUDEX_CLAUDE_UPDATE_INTERVAL_SECONDS' '86400'
$claudexAutoUpdate = Env-OrDefault 'CLAUDEX_AUTO_UPDATE' 'on'
$claudexUpdateInterval = Env-OrDefault 'CLAUDEX_UPDATE_INTERVAL_SECONDS' '86400'
$planModePolicy = Env-OrDefault 'CLAUDEX_PLAN_MODE_POLICY' 'conservative'
$skillBridgeMode = Env-OrDefault 'CLAUDEX_SKILL_BRIDGE' 'on'
$skillPluginMode = Env-OrDefault 'CLAUDEX_SKILL_PLUGINS' 'on'
$skillDollarReferenceMode = Env-OrDefault 'CLAUDEX_SKILL_DOLLAR_REFERENCES' 'on'
$instructionBridgeMode = Env-OrDefault 'CLAUDEX_INSTRUCTION_BRIDGE' 'on'
$codexSessionHelper = Env-OrDefault 'CLAUDEX_CODEX_SESSION_HELPER' (Join-Path $configDir 'codex-session.ps1')
$selfUpdateHelper = Env-OrDefault 'CLAUDEX_SELF_UPDATE_HELPER' (Join-Path $configDir 'self-update.ps1')
$skillBridgeHelper = Env-OrDefault 'CLAUDEX_SKILL_BRIDGE_HELPER' (Join-Path $configDir 'skill-bridge.cjs')

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq 'self-update') {
    if (-not (Test-Path -LiteralPath $selfUpdateHelper -PathType Leaf)) { Fail 'self-update helper is missing; rerun the installer.' }
    $selfUpdateOption = if ($ClaudeArguments.Count -ge 2) { [string]$ClaudeArguments[1] } else { '--status' }
    $selfUpdateSwitch = switch ($selfUpdateOption) {
        '--check' { '-Check' }
        '--apply' { '-Apply' }
        '--status' { '-Status' }
        default { Fail 'self-update accepts --check, --apply, or --status.' 2 }
    }
    if ($ClaudeArguments.Count -gt 2) { Fail 'self-update accepts exactly one action.' 2 }
    $powerShellHost = if (Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue) {
        (Get-Command powershell.exe -CommandType Application).Source
    } else { (Get-Process -Id $PID).Path }
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @('CLAUDEX_CONFIG_DIR') -Action {
        & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $selfUpdateHelper $selfUpdateSwitch
    }
    Exit-Claudex $script:lastPrivateBoundaryExitCode
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -in @('--login', '--logout', '--auth-status')) {
    if (-not (Test-Path -LiteralPath $codexSessionHelper -PathType Leaf)) { Fail 'authentication helper is missing; reinstall Claudex.' }
    $action = switch ($ClaudeArguments[0]) { '--login' { 'login' } '--logout' { 'logout' } default { 'status' } }
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @('CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE') -Action {
        & $codexSessionHelper $action
    }
    Exit-Claudex $script:lastPrivateBoundaryExitCode
}

$earlyRuntimeBypass = $false
$earlyGlobalMaintenanceOptions = @('--help', '-h', '--version', '-v')
$earlyMaintenanceCommands = @('agents', 'attach', 'auth', 'auto-mode', 'claude', 'codex', 'doctor', 'gateway', 'install', 'kill', 'logs', 'mcp', 'plugin', 'plugins', 'project', 'remote-control', 'respawn', 'rm', 'self-update', 'setup-token', 'skills', 'stop', 'ultrareview', 'update', 'upgrade')
$earlyPositionalSeen = $false
for ($earlyIndex = 0; $earlyIndex -lt $ClaudeArguments.Count; $earlyIndex++) {
    $earlyArgument = [string] $ClaudeArguments[$earlyIndex]
    if ($earlyArgument -eq '--') { break }
    if ($earlyArgument -eq '--claude-chrome') { $earlyRuntimeBypass = $true; break }
    if ($earlyArgument -in @('--sol', '--terra', '--luna', '--solplan', '--manual', '--auto', '--accept-edits', '--ultracode', '--max-effort')) { continue }
    $earlyOption = if ($earlyArgument -match '^(-{1,2}[^=]+)=') { $Matches[1] } elseif ($earlyArgument -match '^(-[drw])=?.+$') { $Matches[1] } else { $earlyArgument }
    if ($earlyOption -in $earlyGlobalMaintenanceOptions -or (-not $earlyPositionalSeen -and $earlyOption -in $earlyMaintenanceCommands)) {
        $earlyRuntimeBypass = $true
        break
    }
    if ($earlyArgument.StartsWith('-')) {
        if ($earlyArgument -notmatch '=' -and $earlyOption -in $claudeRequiredValueOptions) { $earlyIndex++ }
        elseif ($earlyArgument -eq $earlyOption -and $earlyOption -in $claudeOptionalValueOptions -and
            $earlyIndex + 1 -lt $ClaudeArguments.Count -and -not ([string] $ClaudeArguments[$earlyIndex + 1]).StartsWith('-')) { $earlyIndex++ }
        continue
    }
    $earlyPositionalSeen = $true
}

$managedCodexModelIds = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
function Get-ProxyEndpointPolicy {
    $uri = $null
    if (-not [Uri]::TryCreate($proxyUrl, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -notin @('', '/') -or $uri.Port -lt 1) {
        throw 'CLAUDEX_PROXY_URL must be an HTTP(S) origin without credentials, a path, a query, or a fragment.'
    }
    $isLoopback = $uri.Host.Equals('localhost', [StringComparison]::OrdinalIgnoreCase)
    $address = $null
    $addressHost = $uri.Host.Trim([char[]]'[]')
    if (-not $isLoopback -and [Net.IPAddress]::TryParse($addressHost, [ref] $address)) {
        $isLoopback = [Net.IPAddress]::IsLoopback($address)
    }
    if (-not $isLoopback) {
        if ($uri.Scheme -ne 'https') {
            throw 'Claudex refuses to send its proxy credential to a non-loopback HTTP endpoint; remote proxies must use HTTPS.'
        }
        if ((Env-OrDefault 'CLAUDEX_ALLOW_REMOTE_PROXY' '0') -ne '1') {
            throw 'Claudex refuses non-loopback proxy URLs by default. Set CLAUDEX_ALLOW_REMOTE_PROXY=1 only for an explicitly trusted HTTPS proxy.'
        }
    }
    return [pscustomobject]@{ Uri = $uri; IsLoopback = $isLoopback }
}

function Assert-ProxyConfiguration {
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        Fail "missing $configFile; reinstall or restore the Claudex configuration."
    }
    if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
        Fail "missing $settingsFile; reinstall or restore the Claudex settings."
    }
    if (-not $proxyToken) { Fail 'CLAUDEX_PROXY_TOKEN is not configured' }
    if ($proxyToken.Contains("`r") -or $proxyToken.Contains("`n")) { Fail 'CLAUDEX_PROXY_TOKEN contains an unsupported newline.' 2 }
    try { [void](Get-ProxyEndpointPolicy) } catch { Fail $_.Exception.Message 2 }
    if ($model -notin $managedCodexModelIds) {
        Fail "invalid CLAUDEX_MODEL '$model'; expected gpt-5.6-sol, gpt-5.6-terra, or gpt-5.6-luna." 2
    }
}
if (-not $earlyRuntimeBypass) {
    if ($permissionMode -notin @('manual', 'auto', 'acceptEdits', 'dontAsk', 'plan')) {
        Fail "invalid CLAUDEX_PERMISSION_MODE '$permissionMode'; expected manual, auto, acceptEdits, dontAsk, or plan." 2
    }
    foreach ($modelSetting in @(
        @{ Name = 'CLAUDEX_AUTO_MODE_MODEL'; Value = $autoModeModel },
        @{ Name = 'CLAUDEX_BACKGROUND_MODEL'; Value = $backgroundModel }
    )) {
        if ($modelSetting.Value -notin $managedCodexModelIds) {
            Fail "$($modelSetting.Name) must be a managed Codex model (gpt-5.6-sol, gpt-5.6-terra, or gpt-5.6-luna)." 2
        }
    }
}

function Require-Integer([string] $Name, [string] $Value, [int] $Minimum, [int] $Maximum) {
    $number = 0
    if (-not [int]::TryParse($Value, [ref] $number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        Fail "$Name must be an integer from $Minimum to $Maximum." 2
    }
    return $number
}

if (-not $earlyRuntimeBypass) {
    $toolConcurrencyNumber = Require-Integer 'CLAUDEX_MAX_TOOL_USE_CONCURRENCY' $toolConcurrency 1 2147483647
    $agentConcurrencyNumber = Require-Integer 'CLAUDEX_MAX_AGENT_CONCURRENCY' $agentConcurrency 1 2147483647
    $maxRetriesNumber = Require-Integer 'CLAUDEX_MAX_RETRIES' $maxRetries 0 15
    $contextWindowNumber = Require-Integer 'CLAUDEX_CONTEXT_WINDOW' $contextWindow 100000 1000000
    $compactWindowNumber = Require-Integer 'CLAUDEX_AUTO_COMPACT_WINDOW' $compactWindow 100000 $contextWindowNumber
    $usageRefreshNumber = Require-Integer 'CLAUDEX_USAGE_REFRESH_SECONDS' $usageRefresh 60 3600
    $usageTimeoutNumber = Require-Integer 'CLAUDEX_USAGE_TIMEOUT_SECONDS' $usageTimeout 1 30
    $usageMaxStaleNumber = Require-Integer 'CLAUDEX_USAGE_MAX_STALE_SECONDS' $usageMaxStale $usageRefreshNumber 604800
    $usageAlertNumber = Require-Integer 'CLAUDEX_USAGE_ALERT_PERCENT' $usageAlert 0 100
    $claudeUpdateIntervalNumber = Require-Integer 'CLAUDEX_CLAUDE_UPDATE_INTERVAL_SECONDS' $claudeUpdateInterval 3600 2592000
    $claudexUpdateIntervalNumber = Require-Integer 'CLAUDEX_UPDATE_INTERVAL_SECONDS' $claudexUpdateInterval 3600 2592000
    if ($mousePointer -notin @('pointer', 'default', 'off')) { Fail 'CLAUDEX_MOUSE_POINTER_SHAPE must be pointer, default, or off.' 2 }
    if ($usageDisplay -notin @('on', 'off')) { Fail 'CLAUDEX_USAGE_DISPLAY must be on or off.' 2 }
    if ($usageSource -notin @('auto', 'web', 'app-server')) { Fail 'CLAUDEX_USAGE_SOURCE must be auto, web, or app-server.' 2 }
    if ($claudeAutoUpdate -notin @('on', 'off')) { Fail 'CLAUDEX_CLAUDE_AUTO_UPDATE must be on or off.' 2 }
    if ($claudexAutoUpdate -notin @('on', 'notify', 'off')) { Fail 'CLAUDEX_AUTO_UPDATE must be on, notify, or off.' 2 }
    if ($planModePolicy -notin @('conservative', 'normal')) { Fail 'CLAUDEX_PLAN_MODE_POLICY must be conservative or normal.' 2 }
    if ($skillBridgeMode -notin @('on', 'off')) { Fail 'CLAUDEX_SKILL_BRIDGE must be on or off.' 2 }
    if ($skillPluginMode -notin @('on', 'off')) { Fail 'CLAUDEX_SKILL_PLUGINS must be on or off.' 2 }
    if ($skillDollarReferenceMode -notin @('on', 'off')) { Fail 'CLAUDEX_SKILL_DOLLAR_REFERENCES must be on or off.' 2 }
    if ($instructionBridgeMode -notin @('on', 'off')) { Fail 'CLAUDEX_INSTRUCTION_BRIDGE must be on or off.' 2 }
} else {
    $toolConcurrencyNumber = 3; $agentConcurrencyNumber = 3; $maxRetriesNumber = 4
    $contextWindowNumber = 400000; $compactWindowNumber = 280000
    $usageRefreshNumber = 300; $usageTimeoutNumber = 8; $usageMaxStaleNumber = 86400; $usageAlertNumber = 20
    $claudeUpdateIntervalNumber = 86400; $claudexUpdateIntervalNumber = 86400
    if ($mousePointer -notin @('pointer', 'default', 'off')) { $mousePointer = 'pointer' }
    if ($usageDisplay -notin @('on', 'off')) { $usageDisplay = 'on' }
    if ($usageSource -notin @('auto', 'web', 'app-server')) { $usageSource = 'auto' }
    if ($claudeAutoUpdate -notin @('on', 'off')) { $claudeAutoUpdate = 'on' }
    if ($claudexAutoUpdate -notin @('on', 'notify', 'off')) { $claudexAutoUpdate = 'on' }
    if ($planModePolicy -notin @('conservative', 'normal')) { $planModePolicy = 'conservative' }
    if ($permissionMode -notin @('manual', 'auto', 'acceptEdits', 'dontAsk', 'plan')) { $permissionMode = 'auto' }
    if ($autoModeModel -notin $managedCodexModelIds) { $autoModeModel = 'gpt-5.6-terra' }
    if ($backgroundModel -notin $managedCodexModelIds) { $backgroundModel = 'gpt-5.6-luna' }
}

$env:CLAUDE_CONFIG_DIR = $configDir

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq 'skills') {
    if ($ClaudeArguments.Count -ne 1) { Fail 'Usage: claudex skills' 2 }
    Assert-SkillBridgeNode
    if (-not (Test-Path -LiteralPath $skillBridgeHelper -PathType Leaf)) { Fail 'skill bridge helper is missing; reinstall Claudex.' }
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @(
        'CLAUDEX_CONFIG_DIR', 'CLAUDEX_CLAUDE_CONFIG_DIR', 'CLAUDEX_INSTRUCTION_BRIDGE'
    ) -Action { & node $skillBridgeHelper list --project (Get-Location).Path }
    Exit-Claudex $script:lastPrivateBoundaryExitCode
}
$stateFile = Join-Path $configDir '.claude.json'
$managedModels = @(
    [pscustomobject]@{ value = 'opusplan'; label = 'GPT-5.6 Solplan'; description = 'GPT-5.6 Sol in plan mode, GPT-5.6 Terra for implementation' },
    [pscustomobject]@{ value = 'gpt-5.6-sol'; label = 'GPT-5.6 Sol'; description = 'Frontier capability for planning and the hardest engineering work' },
    [pscustomobject]@{ value = 'gpt-5.6-terra'; label = 'GPT-5.6 Terra'; description = 'Balanced intelligence, speed, and cost for everyday coding' },
    [pscustomobject]@{ value = 'gpt-5.6-luna'; label = 'GPT-5.6 Luna'; description = 'Fast, efficient model for search, triage, and mechanical tasks' }
)

function Update-ModelCache {
    $lockDirectory = Join-Path (Join-Path $configDir 'run') 'model-display.lock'
    $lockNonce = Acquire-OwnedLock $lockDirectory 100 20
    if (-not $lockNonce) { return }

    $tempFile = $null
    try {
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
        [IO.File]::WriteAllText($tempFile, ($state | ConvertTo-Json -Depth 100), $utf8)
        Move-Item -LiteralPath $tempFile -Destination $stateFile -Force
        $tempFile = $null
    } finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile -PathType Leaf)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        Release-OwnedLock $lockDirectory $lockNonce
    }
}

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void] $builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void] $builder.Append(('\' * (($slashes * 2) + 1)))
            [void] $builder.Append('"')
        } else {
            if ($slashes -gt 0) { [void] $builder.Append(('\' * $slashes)) }
            [void] $builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void] $builder.Append(('\' * ($slashes * 2))) }
    [void] $builder.Append('"')
    return $builder.ToString()
}

function Join-WindowsCommandLine([string[]] $Arguments) {
    return (@($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument ([string] $_) }) -join ' ')
}

function Start-DiscardingProcess([string] $Executable, [string[]] $Arguments, [switch] $Hidden) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = Join-WindowsCommandLine $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = [bool] $Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'background process could not be started.' }
        # Drain directly to Stream.Null. ReadToEndAsync retains the complete
        # output in memory, while leaving either stream unread can deadlock a
        # noisy watcher after the OS pipe fills.
        $stdoutDrain = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        $stderrDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $process | Add-Member -NotePropertyName ClaudexStdoutDrain -NotePropertyValue $stdoutDrain
        $process | Add-Member -NotePropertyName ClaudexStderrDrain -NotePropertyValue $stderrDrain
        return $process
    } catch {
        $process.Dispose()
        throw
    }
}

function ConvertTo-CmdArgument([string] $Value) {
    if ($null -eq $Value) { $Value = '' }
    # Delayed expansion is disabled by the caller. Keep metacharacters inside a
    # quoted token and use cmd's doubled-quote representation for literal quotes.
    return '"' + $Value.Replace('%', '%%').Replace('"', '""') + '"'
}

function Invoke-CurlWithDeadline([string[]] $Arguments, [string] $StandardInput, [int] $TimeoutMilliseconds) {
    $command = Get-Command $curlCommand -ErrorAction SilentlyContinue
    if (-not $command) { throw "curl executable was not found: $curlCommand" }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $commandPath = [string] $command.Source
    $extension = [IO.Path]::GetExtension($commandPath).ToLowerInvariant()
    if ($extension -in @('.cmd', '.bat')) {
        $commandLine = (ConvertTo-CmdArgument $commandPath) + ' ' +
            (@($Arguments | ForEach-Object { ConvertTo-CmdArgument ([string] $_) }) -join ' ')
        $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        # cmd /s /c requires one outer quote pair around a command whose
        # executable path is itself quoted. Passing this through ordinary
        # CreateProcess argv quoting produces a malformed, never-run shim.
        $startInfo.Arguments = '/d /s /v:off /c "' + $commandLine + '"'
    } elseif ($command.CommandType -eq 'ExternalScript' -or $extension -eq '.ps1') {
        # ProcessStartInfo cannot CreateProcess a PowerShell script directly.
        # Run a fixed encoded bootstrap; proxy credentials live in the private
        # header file, never in this command line.
        $escapedPath = $commandPath.Replace("'", "''")
        $argumentLiteral = @($Arguments | ForEach-Object { "'" + ([string] $_).Replace("'", "''") + "'" }) -join ','
        $bootstrap = "& '$escapedPath' @($argumentLiteral); exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.Arguments = Join-WindowsCommandLine @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    } else {
        $startInfo.FileName = $commandPath
        $startInfo.Arguments = Join-WindowsCommandLine $Arguments
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'could not start curl.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit(1000) | Out-Null } catch { }
            throw 'proxy request exceeded its wall-clock deadline.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $safeError = ([string] $errorOutput).Replace($proxyToken, '[redacted]').Replace("`r", ' ').Replace("`n", ' ').Trim()
            $transport = "$($command.CommandType):$commandPath"
            if ($safeError) { throw "proxy request via $transport failed with exit code $($process.ExitCode): $safeError" }
            throw "proxy request via $transport failed with exit code $($process.ExitCode)."
        }
        return $output
    } finally {
        $process.Dispose()
    }
}

function Fetch-Models([int] $TimeoutMilliseconds = 5000) {
    # Validate the destination before creating the bearer header. Internal
    # watcher paths call this function without passing through normal startup.
    [void](Get-ProxyEndpointPolicy)
    $timeoutMilliseconds = [math]::Max(250, [math]::Min(5000, $TimeoutMilliseconds))
    $curlSeconds = [math]::Max(1, [int] [math]::Ceiling($timeoutMilliseconds / 1000.0))
    $healthRunDir = Join-Path $configDir 'run'
    [IO.Directory]::CreateDirectory($healthRunDir) | Out-Null
    $headerFile = Join-Path $healthRunDir ('.proxy-health-header-' + [guid]::NewGuid().ToString('N'))
    try {
        # PowerShell 5 can surface piped stdin in a .cmd invocation's command
        # context. Curl's @file syntax keeps the bearer value out of argv while
        # remaining compatible with native curl.exe and test/enterprise shims.
        [IO.File]::WriteAllText($headerFile, "Authorization: Bearer $proxyToken`n", $utf8)
        Protect-PrivatePath $headerFile $false
        $output = Invoke-CurlWithDeadline @('--silent', '--show-error', '--connect-timeout', '1',
            '--max-time', [string] $curlSeconds, '--write-out', "`n%{http_code}", '--header', "@$headerFile", "$proxyUrl/v1/models") `
            '' $timeoutMilliseconds
    } finally {
        Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue
    }
    $normalized = $output.Replace("`r`n", "`n").TrimEnd([char[]] "`r`n")
    $lastNewline = $normalized.LastIndexOf("`n")
    $status = 200
    $body = $normalized
    if ($lastNewline -ge 0 -and $normalized.Substring($lastNewline + 1) -match '^\d{3}$') {
        $status = [int] $Matches[0]
        $body = $normalized.Substring(0, $lastNewline)
    }
    if ($status -in @(401, 403)) {
        throw (New-Object UnauthorizedAccessException -ArgumentList 'the proxy rejected the configured local authentication token.')
    }
    if ($status -lt 200 -or $status -ge 300) { throw "proxy health endpoint returned HTTP $status." }
    return ($body | ConvertFrom-Json)
}

function Get-ProxyHealth([int] $TimeoutMilliseconds = 5000) {
    try {
        $models = Fetch-Models $TimeoutMilliseconds
        $script:lastProxyModelIds = @($models.data | ForEach-Object { [string] $_.id } | Where-Object { $_ })
        if ($script:lastProxyModelIds.Count -gt 0) { return 'healthy' }
        Write-ProxyRecoveryDiagnostic 'proxy health response contained no model identifiers'
        return 'unhealthy'
    } catch [UnauthorizedAccessException] {
        Write-ProxyRecoveryDiagnostic 'proxy health request was rejected by local authentication'
        return 'authentication-failed'
    } catch {
        Write-ProxyRecoveryDiagnostic ("proxy health request failed: " + $_.Exception.Message)
        return 'unhealthy'
    }
}

function Test-ProxyReady([int] $TimeoutMilliseconds = 5000) {
    return (Get-ProxyHealth $TimeoutMilliseconds) -eq 'healthy'
}

function Test-ProxyReachable {
    if ($env:CLAUDEX_TEST_PROXY_REACHABLE_FILE) {
        return (Test-Path -LiteralPath $env:CLAUDEX_TEST_PROXY_REACHABLE_FILE -PathType Leaf)
    }
    # A listening socket is not health: a wedged, unauthenticated, or unrelated
    # service can own the port. Require the authenticated models contract.
    return (Get-ProxyHealth 2000) -eq 'healthy'
}

function Find-ProxyExecutable {
    $configured = Env-OrDefault 'CLAUDEX_PROXY_BIN' ''
    if ($configured -and (Test-Path -LiteralPath $configured -PathType Leaf)) { return $configured }
    $managed = Join-Path $configDir 'bin\cliproxyapi.exe'
    if (Test-Path -LiteralPath $managed -PathType Leaf) { return $managed }
    foreach ($name in @('cliproxyapi.exe', 'cli-proxy-api.exe', 'cliproxyapi', 'cli-proxy-api')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

function Write-ProxyRecoveryDiagnostic([string] $Message) {
    try {
        $logDir = Join-Path $configDir 'logs'
        $logFile = Join-Path $logDir 'proxy-recovery.log'
        [IO.Directory]::CreateDirectory($logDir) | Out-Null
        $safeMessage = ([string] $Message).Replace("`r", ' ').Replace("`n", ' ')
        if ($proxyToken) { $safeMessage = $safeMessage.Replace($proxyToken, '[redacted]') }
        [IO.File]::AppendAllText($logFile,
            "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK') $safeMessage$([Environment]::NewLine)", $utf8)
        $item = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 131072) {
            $content = [IO.File]::ReadAllText($logFile)
            $keep = if ($content.Length -gt 65536) { $content.Substring($content.Length - 65536) } else { $content }
            $firstNewline = $keep.IndexOf("`n")
            if ($firstNewline -ge 0) { $keep = $keep.Substring($firstNewline + 1) }
            $temporary = "$logFile.tmp.$PID.$([guid]::NewGuid().ToString('N'))"
            [IO.File]::WriteAllText($temporary, $keep, $utf8)
            Move-Item -LiteralPath $temporary -Destination $logFile -Force
        }
    } catch { }
}

$script:ManagedProxyMetadataPath = Join-Path (Join-Path $configDir 'run') 'managed-proxy.json'

function Get-ManagedProxyMetadata {
    if (-not (Test-Path -LiteralPath $script:ManagedProxyMetadataPath -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $script:ManagedProxyMetadataPath -Raw | ConvertFrom-Json
        foreach ($name in @('pid', 'startedUtcTicks', 'executable')) {
            if ($null -eq $record.PSObject.Properties[$name]) { throw "missing $name" }
        }
        if ([int]$record.pid -le 0 -or [long]$record.startedUtcTicks -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$record.executable)) { throw 'invalid managed proxy metadata' }
        return $record
    } catch {
        Remove-Item -LiteralPath $script:ManagedProxyMetadataPath -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Test-ManagedProxyIdentity($Record, [Diagnostics.Process] $Process) {
    if ($null -eq $Record -or $null -eq $Process -or $Process.Id -ne [int]$Record.pid) { return $false }
    try {
        $startedUtcTicks = $Process.StartTime.ToUniversalTime().Ticks
        $processPath = [IO.Path]::GetFullPath($Process.MainModule.FileName)
        $recordPath = [IO.Path]::GetFullPath([string]$Record.executable)
        return $startedUtcTicks -eq [long]$Record.startedUtcTicks -and
            $processPath.Equals($recordPath, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Remove-ManagedProxyMetadata($ExpectedRecord) {
    if ($null -eq $ExpectedRecord) { return }
    try {
        $current = Get-ManagedProxyMetadata
        if ($null -ne $current -and [int]$current.pid -eq [int]$ExpectedRecord.pid -and
            [long]$current.startedUtcTicks -eq [long]$ExpectedRecord.startedUtcTicks) {
            Remove-Item -LiteralPath $script:ManagedProxyMetadataPath -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Write-ManagedProxyMetadata([Diagnostics.Process] $Process, [string] $Executable) {
    $processPath = [IO.Path]::GetFullPath($Process.MainModule.FileName)
    $record = [ordered]@{
        schema = 1
        pid = $Process.Id
        startedUtcTicks = $Process.StartTime.ToUniversalTime().Ticks
        executable = $processPath
        launcher = [IO.Path]::GetFullPath($Executable)
        recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $parent = Split-Path $script:ManagedProxyMetadataPath -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = "$($script:ManagedProxyMetadataPath).tmp.$PID.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, (($record | ConvertTo-Json -Compress) + "`n"), $utf8)
        Move-Item -LiteralPath $temporary -Destination $script:ManagedProxyMetadataPath -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]$record
}

function Test-RecordedManagedProxy {
    $record = Get-ManagedProxyMetadata
    if ($null -eq $record) { return $false }
    $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    try {
        if ($null -ne $process -and (Test-ManagedProxyIdentity $record $process)) { return $true }
        Remove-ManagedProxyMetadata $record
        return $false
    } finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
    }
}

function Stop-RecordedManagedProxy([string] $Reason) {
    $record = Get-ManagedProxyMetadata
    if ($null -eq $record) { return $false }
    $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    try {
        if ($null -eq $process -or -not (Test-ManagedProxyIdentity $record $process)) {
            Remove-ManagedProxyMetadata $record
            Write-ProxyRecoveryDiagnostic "ignored stale managed proxy metadata while handling $Reason"
            return $false
        }
        $stopped = $false
        if (-not $process.HasExited) { $process.Kill() }
        [void]$process.WaitForExit(5000)
        $process.Refresh()
        $stopped = $process.HasExited
        if (-not $stopped) {
            Write-ProxyRecoveryDiagnostic "could not stop verified Claudex-managed proxy pid=$($record.pid) after $Reason"
            return $false
        }
        Remove-ManagedProxyMetadata $record
        Write-ProxyRecoveryDiagnostic "stopped Claudex-managed proxy pid=$($record.pid) after $Reason"
        return $true
    } catch {
        Write-ProxyRecoveryDiagnostic "could not stop verified Claudex-managed proxy pid=$($record.pid) after $Reason"
        return $false
    } finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
    }
}

function Stop-NewlySpawnedProxy([Diagnostics.Process] $Process, $Record, [string] $Reason) {
    if ($null -eq $Process) { return }
    $stopped = $false
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) { $Process.Kill() }
        [void]$Process.WaitForExit(5000)
        $Process.Refresh()
        $stopped = $Process.HasExited
    } catch { }
    if ($stopped) {
        Remove-ManagedProxyMetadata $Record
        Write-ProxyRecoveryDiagnostic "cleaned up newly spawned proxy pid=$($Process.Id) after $Reason"
    } else {
        Write-ProxyRecoveryDiagnostic "newly spawned proxy pid=$($Process.Id) remained alive after cleanup for $Reason"
    }
}

function Get-ProxyStartupMutexName {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [IO.Path]::GetFullPath($configDir).ToLowerInvariant()
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))
        $suffix = -join ($hash[0..15] | ForEach-Object { $_.ToString('x2') })
        return "Local\Claudex.ProxyStart.$suffix"
    } finally { $sha.Dispose() }
}

function Assert-ProxyModelAvailable([string[]] $RequiredModels) {
    $routeCandidates = @($RequiredModels | Where-Object { $_ })
    if ($routeCandidates.Count -eq 0) { return }
    $unavailableRoutes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($routeCandidate in $routeCandidates) {
        # opusplan is Claude Code's virtual plan/implementation route. The proxy
        # advertises the two concrete Codex models that back it, not the alias.
        $concreteModels = if ($routeCandidate -eq 'opusplan') { @('gpt-5.6-sol', 'gpt-5.6-terra') } else { @($routeCandidate) }
        $missingModels = @($concreteModels | Where-Object { $script:lastProxyModelIds -notcontains $_ })
        if ($missingModels.Count -eq 0) { return }
        $unavailableRoutes.Add("$routeCandidate (missing: $($missingModels -join ', '))")
    }
    $routeSummary = $routeCandidates -join ', '
    Write-ProxyRecoveryDiagnostic "proxy is healthy but primary and fallback model routes are unavailable: $($unavailableRoutes -join '; ')"
    throw "the authenticated Codex account does not advertise any requested model route ($routeSummary). Run: claudex --doctor"
}

$script:lastProxyFailureWasAuthSync = $false
$script:lastProxyAuthSyncExitCode = 0
$script:interactiveLoginAttempted = $false

function Ensure-Proxy([string[]] $RequiredModels = @($model)) {
    $script:lastProxyFailureWasAuthSync = $false
    $script:lastProxyAuthSyncExitCode = 0
    $endpointPolicy = Get-ProxyEndpointPolicy
    Write-ProxyWatcherTestTrace 'recovery: begin'
    if (-not (Test-Path -LiteralPath $codexSessionHelper -PathType Leaf)) {
        throw "authentication helper is missing: $codexSessionHelper; reinstall Claudex."
    }
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_SKIP_AUTH_SYNC -eq '1') {
        $script:lastPrivateBoundaryExitCode = 0
    } else {
        Invoke-WithoutPrivateManagedEnvironment -PreserveNames @(
            'CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE'
        ) -Action { & $codexSessionHelper sync }
    }
    if ($script:lastPrivateBoundaryExitCode -ne 0) {
        $syncExitCode = $script:lastPrivateBoundaryExitCode
        $script:lastProxyFailureWasAuthSync = $true
        $script:lastProxyAuthSyncExitCode = $syncExitCode
        throw "authentication synchronization failed with exit code $syncExitCode."
    }
    Write-ProxyWatcherTestTrace 'recovery: authentication synchronized'
    $initialHealth = Get-ProxyHealth 3000
    if ($initialHealth -eq 'healthy') { Assert-ProxyModelAvailable $RequiredModels; return }
    if ($initialHealth -eq 'authentication-failed') {
        if (-not $endpointPolicy.IsLoopback) {
            Write-ProxyRecoveryDiagnostic 'trusted remote proxy rejected the configured authentication token'
            throw 'the trusted remote proxy rejected the configured authentication token; verify its Claudex credential without starting or stopping a local service.'
        }
        if (-not (Test-RecordedManagedProxy)) {
            Write-ProxyRecoveryDiagnostic 'proxy authentication failed but no matching Claudex-managed process could be proven'
            throw 'the loopback proxy rejected the configured authentication token, but Claudex will not stop an unverified process. Stop the conflicting service or rerun the installer.'
        }
        # Do not stop it until the startup lock is held: another Claudex tab may
        # already be replacing the same managed process.
        Write-ProxyRecoveryDiagnostic 'verified Claudex-managed proxy authentication rejection; entering serialized recovery'
    }
    if (-not $endpointPolicy.IsLoopback) {
        throw 'the trusted remote proxy is unavailable; Claudex will not start a local service for a remote endpoint.'
    }
    Write-ProxyWatcherTestTrace 'recovery: readiness check failed'
    Write-ProxyRecoveryDiagnostic 'authenticated proxy readiness failed; entering recovery'
    $runDir = Join-Path $configDir 'run'
    $lockDir = Join-Path $runDir 'proxy-start.lock'
    [IO.Directory]::CreateDirectory($runDir) | Out-Null
    $lockAcquired = $false
    $lockNonce = ''
    $startupMutex = $null
    $useNamedMutex = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $lockDeadline = [DateTime]::UtcNow.AddSeconds(30)
    if ($useNamedMutex) {
        $startupMutex = New-Object Threading.Mutex($false, (Get-ProxyStartupMutexName))
        while (-not $lockAcquired -and [DateTime]::UtcNow -lt $lockDeadline) {
            try { $lockAcquired = $startupMutex.WaitOne(100) }
            catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
            if (-not $lockAcquired -and (Test-ProxyReady 1000)) {
                Assert-ProxyModelAvailable $RequiredModels
                $startupMutex.Dispose()
                return
            }
        }
    }
    if ($useNamedMutex -and -not $lockAcquired) {
        if ($startupMutex) { $startupMutex.Dispose() }
        Write-ProxyRecoveryDiagnostic 'timed out waiting for the proxy startup mutex'
        throw 'timed out waiting for another session to start the local proxy.'
    }
    # The filesystem generation lock is required even on Windows. It provides
    # cross-session and mixed-version coordination that a Local named mutex
    # cannot provide on its own. Legacy ownerless directories receive the same
    # conservative two-minute transition window as the Unix launcher.
    $lockAcquired = $false
    while (-not $lockAcquired -and [DateTime]::UtcNow -lt $lockDeadline) {
        $lockNonce = Acquire-OwnedLock $lockDir 1 0 120
        if ($lockNonce) {
            $lockAcquired = $true
            if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE) {
                Add-Content -LiteralPath $env:CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE -Value "acquired $PID" -Encoding UTF8
            }
            break
        }
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE) {
            Add-Content -LiteralPath $env:CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE -Value "blocked $PID" -Encoding UTF8
        }
        if (Test-ProxyReady 1000) {
            Assert-ProxyModelAvailable $RequiredModels
            if ($useNamedMutex) { try { $startupMutex.ReleaseMutex() } catch { }; $startupMutex.Dispose() }
            return
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $lockAcquired) {
        if ($useNamedMutex) { try { $startupMutex.ReleaseMutex() } catch { }; $startupMutex.Dispose() }
        Write-ProxyRecoveryDiagnostic 'timed out after 30s waiting for the proxy startup filesystem lock'
        throw 'timed out waiting for another session to start the local proxy.'
    }
    Write-ProxyWatcherTestTrace 'recovery: startup lock acquired'
    Write-ProxyRecoveryDiagnostic 'proxy startup lock acquired'

    $becameReady = $false
    $spawnedProxy = $null
    $spawnedProxyRecord = $null
    try {
        $lockedHealth = Get-ProxyHealth 2000
        if ($lockedHealth -eq 'healthy') { Assert-ProxyModelAvailable $RequiredModels; $becameReady = $true; return }
        if ($lockedHealth -eq 'authentication-failed') {
            if (-not (Stop-RecordedManagedProxy 'an authenticated 401/403 response after acquiring the startup lock')) {
                throw 'the loopback proxy rejected the configured authentication token, but Claudex will not stop an unverified process. Stop the conflicting service or rerun the installer.'
            }
        } else {
            # A tracked process can also remain alive while failing readiness.
            # Stop only a strongly identified Claudex record; no record
            # simply means there is no process Claudex is authorized to kill.
            [void](Stop-RecordedManagedProxy 'authenticated readiness failure after acquiring the startup lock')
        }
        $proxyBinary = Find-ProxyExecutable
        if (-not $proxyBinary) { throw 'CLIProxyAPI is not reachable and no proxy executable was found.' }
        [Console]::Error.WriteLine('claudex: starting the local CLIProxyAPI service...')
        $proxyConfig = Env-OrDefault 'CLAUDEX_PROXY_CONFIG' (Join-Path $configDir 'cliproxyapi.yaml')
        $logDir = Join-Path $configDir 'logs'
        [IO.Directory]::CreateDirectory($logDir) | Out-Null
        $arguments = @()
        if (Test-Path -LiteralPath $proxyConfig -PathType Leaf) {
            $arguments = @('-config', ('"' + $proxyConfig + '"'))
        }
        $startParameters = @{
            FilePath = $proxyBinary
            WorkingDirectory = $configDir
            RedirectStandardOutput = (Join-Path $logDir 'cliproxyapi.stdout.log')
            RedirectStandardError = (Join-Path $logDir 'cliproxyapi.stderr.log')
            PassThru = $true
        }
        if ($arguments.Count -gt 0) { $startParameters.ArgumentList = $arguments }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $startParameters.WindowStyle = 'Hidden' }
        Write-ProxyWatcherTestTrace "recovery: starting $proxyBinary"
        Write-ProxyRecoveryDiagnostic "starting compatibility service: $proxyBinary"
        $spawnedProxy = Invoke-WithoutPrivateManagedEnvironment -Action { Start-Process @startParameters }
        try {
            $spawnedProxyRecord = Write-ManagedProxyMetadata $spawnedProxy $proxyBinary
        } catch {
            Stop-NewlySpawnedProxy $spawnedProxy $null 'managed process metadata could not be recorded'
            throw 'the local proxy started, but Claudex could not record safe process metadata; the process was stopped.'
        }
        Write-ProxyWatcherTestTrace 'recovery: process launched'
        $readinessDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $readinessDeadline) {
            $remaining = [int] [math]::Max(250, ($readinessDeadline - [DateTime]::UtcNow).TotalMilliseconds)
            $startupHealth = Get-ProxyHealth ([math]::Min(2000, $remaining))
            if ($startupHealth -eq 'healthy') {
                Assert-ProxyModelAvailable $RequiredModels
                $becameReady = $true
                try {
                    $spawnedProxy.Refresh()
                    if ($spawnedProxy.HasExited) { Remove-ManagedProxyMetadata $spawnedProxyRecord }
                } catch { }
                break
            }
            if ($startupHealth -eq 'authentication-failed') {
                throw 'the newly started local proxy rejected its configured authentication token; rerun the installer to repair matching credentials.'
            }
            try { $spawnedProxy.Refresh(); if ($spawnedProxy.HasExited) { break } } catch { }
            Start-Sleep -Milliseconds 100
        }
        Write-ProxyWatcherTestTrace "recovery: readiness loop completed; ready=$becameReady"
        Write-ProxyRecoveryDiagnostic "proxy readiness loop completed; ready=$becameReady"
    } finally {
        if ($spawnedProxy) {
            if (-not $becameReady) {
                Stop-NewlySpawnedProxy $spawnedProxy $spawnedProxyRecord 'it never became semantically healthy'
            }
            try { $spawnedProxy.Dispose() } catch { }
        }
        if ($lockNonce) { Release-OwnedLock $lockDir $lockNonce }
        if ($useNamedMutex) {
            if ($lockAcquired) { try { $startupMutex.ReleaseMutex() } catch { } }
            if ($startupMutex) { $startupMutex.Dispose() }
        }
    }
    if (-not $becameReady) {
        throw 'local proxy did not become healthy before the 15-second deadline. Run: claudex --doctor'
    }
}

function Test-InteractiveCodexLoginAllowed {
    if ($env:CLAUDEX_DISABLE_INTERACTIVE_LOGIN -eq '1') { return $false }
    if ($env:CI -and $env:CI -notin @('0', 'false', 'FALSE', 'no', 'NO')) { return $false }
    if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { return $true }
    return ($env:CLAUDEX_TEST_TTY_INPUT -eq '1' -and $env:CLAUDEX_TEST_TTY_OUTPUT -eq '1')
}

# Keep login browser launches exclusive to the foreground startup path. The
# proxy watcher deliberately calls Ensure-Proxy directly and therefore remains
# prompt-free even when its parent owns an interactive console.
function Ensure-ProxyForLaunch([string[]] $RequiredModels = @($model)) {
    try {
        Ensure-Proxy $RequiredModels
        return
    } catch {
        $initialFailure = $_
    }
    if (-not $script:lastProxyFailureWasAuthSync) { throw $initialFailure }
    if ($script:lastProxyAuthSyncExitCode -notin @(11, 13, 14)) { throw $initialFailure }

    if ($script:interactiveLoginAttempted) {
        [Console]::Error.WriteLine('claudex: Codex authentication is still unavailable after the sign-in attempt. Run `claudex --login` to retry.')
        throw $initialFailure
    }
    if (-not (Test-InteractiveCodexLoginAllowed)) {
        [Console]::Error.WriteLine('claudex: Codex sign-in is required. Run `claudex --login` in an interactive terminal, then retry.')
        throw $initialFailure
    }

    $script:interactiveLoginAttempted = $true
    [Console]::Error.WriteLine('claudex: Codex sign-in is required. Opening the official Codex browser login...')
    Write-ProxyRecoveryDiagnostic 'foreground startup requested official Codex browser login'
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @(
        'CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE'
    ) -Action { & $codexSessionHelper login }
    if ($script:lastPrivateBoundaryExitCode -ne 0) {
        Write-ProxyRecoveryDiagnostic "foreground Codex browser login failed with exit code $($script:lastPrivateBoundaryExitCode)"
        throw 'Codex sign-in did not complete. Run `claudex --login` to retry.'
    }

    try {
        Ensure-Proxy $RequiredModels
        Write-ProxyRecoveryDiagnostic 'foreground Codex browser login synchronized successfully'
    } catch {
        if ($script:lastProxyFailureWasAuthSync) {
            [Console]::Error.WriteLine('claudex: Codex authentication is still unavailable after sign-in. Run `claudex --login` to retry.')
        }
        throw
    }
}

function Start-AuthWatcher {
    if ($env:CLAUDEX_SKIP_AUTH_WATCHER -eq '1') { return $null }
    $hostExecutable = (Get-Process -Id $PID).Path
    $parentIdentity = [string] (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $codexSessionHelper,
        'watch', '-ParentProcessId', [string] $PID, '-ParentProcessIdentity', $parentIdentity)
    if ($backgroundLaunch) { $arguments += '-BackgroundWatch' }
    try {
        $watcher = Invoke-WithoutPrivateManagedEnvironment -PreserveNames @(
            'CLAUDEX_CONFIG_DIR', 'CLAUDE_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE'
        ) -Action {
            Start-DiscardingProcess $hostExecutable $arguments -Hidden:([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
        }
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_AUTH_WATCH_PID_FILE) {
            [IO.File]::WriteAllText($env:CLAUDEX_TEST_AUTH_WATCH_PID_FILE, "$($watcher.Id)`n", $utf8)
        }
        return $watcher
    } catch {
        [Console]::Error.WriteLine('claudex: warning: automatic Codex account switching could not be started for this session.')
        return $null
    }
}

function Write-ProxyWatcherTestTrace([string] $Message) {
    if (-not $env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE) { return }
    try { Add-Content -LiteralPath $env:CLAUDEX_TEST_PROXY_WATCH_ERROR_FILE -Value $Message } catch { }
}

function Test-WatchParentCurrent([int] $ParentProcessId, [string] $ParentIdentity) {
    $process = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ([string]::IsNullOrWhiteSpace($ParentIdentity)) { return $true }
    try { return ([string] $process.StartTime.ToUniversalTime().Ticks) -eq $ParentIdentity } catch { return $false }
}

function Get-ManagedBackgroundRegistryState {
    # Query only the managed Claude profile. A proxy watcher needs the private
    # session environment for health recovery, but none of it belongs in the
    # separate first-party `claude agents` process used for lifecycle discovery.
    $privateNames = @($sessionEnvironmentNames + @(
        'CLAUDEX_SESSION_MODE', 'CLAUDEX_MODEL_MODE', 'CLAUDEX_INTERACTIVE_TUI',
        'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_NO_FLICKER', 'CLAUDE_CODE_ACCESSIBILITY'
    ) | Where-Object { $_ -ne 'CLAUDE_CONFIG_DIR' } | Select-Object -Unique)
    $saved = @{}
    foreach ($name in $privateNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    try {
        $claude = Resolve-HarnessCommand 'claude'
        if (-not $claude -or -not $claude.Source) { return 'unknown' }
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

function Invoke-ProxyWatchLoop([int] $ParentProcessId, [string] $ParentIdentity, [bool] $BackgroundWatch) {
    Write-ProxyWatcherTestTrace "watcher entered for parent $ParentProcessId"
    $consecutiveFailures = 0
    $emptyPolls = 0
    while ($true) {
        if (Test-WatchParentCurrent $ParentProcessId $ParentIdentity) { $emptyPolls = 0 }
        elseif ($BackgroundWatch) {
            $registryState = Get-ManagedBackgroundRegistryState
            if ($registryState -eq 'active') { $emptyPolls = 0 }
            elseif ($registryState -eq 'empty') {
                $emptyPolls++
                if ($emptyPolls -ge 3) { break }
            } else { $emptyPolls = 0 }
        } else { break }
        Start-Sleep -Seconds 1
        if (Test-ProxyReachable) {
            $consecutiveFailures = 0
        } else {
            $consecutiveFailures++
        }
        if ($consecutiveFailures -ge 2) {
            Write-ProxyWatcherTestTrace 'proxy unreachable; starting recovery'
            try {
                Ensure-Proxy *> $null
                Write-ProxyWatcherTestTrace 'proxy recovery completed'
            } catch {
                Write-ProxyWatcherTestTrace ("proxy recovery failed: " + $_.Exception.Message)
                Write-ProxyRecoveryDiagnostic ("proxy recovery failed: " + $_.Exception.Message)
            }
            $consecutiveFailures = 0
        }
    }
    Write-ProxyWatcherTestTrace 'watcher exited'
    if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_PROXY_WATCH_EXIT_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_PROXY_WATCH_EXIT_FILE, "exited`n", $utf8)
    }
}

function Start-ProxyWatcher {
    if ($env:CLAUDEX_SKIP_PROXY_WATCHER -eq '1') { return $null }
    $hostExecutable = (Get-Process -Id $PID).Path
    $parentIdentity = [string] (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-ClaudexInternalProxyWatchParentProcessId', [string] $PID, $parentIdentity, $(if ($backgroundLaunch) { '1' } else { '0' }))
    try {
        $watcher = Start-DiscardingProcess $hostExecutable $arguments -Hidden:([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_PROXY_WATCH_PID_FILE) {
            [IO.File]::WriteAllText($env:CLAUDEX_TEST_PROXY_WATCH_PID_FILE, "$($watcher.Id)`n", $utf8)
        }
        return $watcher
    } catch {
        [Console]::Error.WriteLine('claudex: warning: local proxy recovery watcher could not be started for this session.')
        return $null
    }
}

if ($ClaudexInternalProxyWatchParentProcessId -gt 0) {
    Invoke-ProxyWatchLoop $ClaudexInternalProxyWatchParentProcessId $ClaudexInternalProxyWatchParentIdentity $ClaudexInternalProxyWatchBackground
    Exit-Claudex 0
}

# Internal watcher processes exit above before touching user-facing state.

function Resolve-ClaudeCommand {
    $claudeCommand = Resolve-HarnessCommand 'claude'
    if (-not $claudeCommand) { Fail 'Claude Code was not found. Install Claude Code and retry.' }
    $script:claudeCommand = $claudeCommand
    $script:claudeInvocation = if ($claudeCommand.CommandType -eq 'Function') { $claudeCommand.Name } else { $claudeCommand.Source }
}

function Test-ClaudeOption([string] $Option) {
    foreach ($line in @($script:claudeHelp -split "`r?`n")) {
        $fields = @($line.TrimStart() -split '\s+' | Where-Object { $_ })
        foreach ($field in $fields) {
            $candidate = ([string] $field).TrimEnd(',')
            if (-not $candidate.StartsWith('-')) { break }
            $candidate = ($candidate -split '=', 2)[0]
            if ($candidate -eq $Option) { return $true }
        }
    }
    return $false
}

function Load-ClaudeCapabilities {
    Resolve-ClaudeCommand
    $script:claudeHelp = (Invoke-WithoutPrivateManagedEnvironment -Action {
        & $script:claudeInvocation --help 2>$null
    } | Out-String)
    if ([string]::IsNullOrWhiteSpace($script:claudeHelp)) { Fail 'Claude Code did not return its capability list.' }
    if (-not (Test-ClaudeOption '--model')) {
        Fail 'this Claude Code build does not support custom models; run `claude update`.'
    }
}

function Update-AutoModeRules {
    $managedSettings = Join-Path $configDir 'settings.json'
    if ([IO.Path]::GetFullPath($settingsFile) -ne [IO.Path]::GetFullPath($managedSettings)) { return }
    $lockDirectory = Join-Path (Join-Path $configDir 'run') 'auto-mode.lock'
    $lockNonce = Acquire-OwnedLock $lockDirectory 100 20
    if (-not $lockNonce) { return }
    $tempFile = $null
    $snapshotTemp = $null
    try {
        $snapshotFile = Join-Path $configDir 'auto-mode-defaults.json'
        $previousSnapshot = $null
        if (Test-Path -LiteralPath $snapshotFile -PathType Leaf) {
            try {
                $candidateSnapshot = Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
                $snapshotValid = $true
                foreach ($property in @('allow', 'environment', 'soft_deny', 'hard_deny')) {
                    if ($null -eq $candidateSnapshot.PSObject.Properties[$property]) { $snapshotValid = $false; break }
                }
                if ($snapshotValid) { $previousSnapshot = $candidateSnapshot }
            } catch { }
        }
        $defaultsAreFresh = $false
        try {
            $defaults = (Invoke-WithoutPrivateManagedEnvironment -Action {
                & $script:claudeInvocation auto-mode defaults 2>$null
            } | Out-String) | ConvertFrom-Json
            foreach ($property in @('allow', 'environment', 'soft_deny', 'hard_deny')) {
                if ($null -eq $defaults.PSObject.Properties[$property]) { throw "missing auto mode default: $property" }
            }
            $defaultsAreFresh = $true
        } catch {
            if ($null -eq $previousSnapshot) {
                $fallbackSettings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
                if ($null -eq $fallbackSettings.PSObject.Properties['autoMode']) { return }
                $fallbackAutoMode = $fallbackSettings.autoMode
                $fallbackAllow = if ($null -ne $fallbackAutoMode.PSObject.Properties['allow']) { @($fallbackAutoMode.allow) } else { @() }
                $fallbackEnvironment = if ($null -ne $fallbackAutoMode.PSObject.Properties['environment']) { @($fallbackAutoMode.environment) } else { @() }
                $fallbackSoftDeny = if ($null -ne $fallbackAutoMode.PSObject.Properties['soft_deny']) { @($fallbackAutoMode.soft_deny) } else { @() }
                $fallbackHardDeny = if ($null -ne $fallbackAutoMode.PSObject.Properties['hard_deny']) { @($fallbackAutoMode.hard_deny) } else { @() }
                $managedAllowOnly = @($fallbackAllow | Where-Object {
                    -not ($_.StartsWith('Explicit Action Approval:') -or $_.StartsWith('Requested Agent Configuration:'))
                }).Count -eq 0
                $managedEnvironmentOnly = @($fallbackEnvironment | Where-Object {
                    -not ($_.StartsWith('User designated task boundary:') -or $_.StartsWith('Explicitly approved development transfer:'))
                }).Count -eq 0
                if ($managedAllowOnly -and $managedEnvironmentOnly -and
                    $fallbackSoftDeny.Count -eq 0 -and $fallbackHardDeny.Count -eq 0) {
                    $fallbackAutoMode.PSObject.Properties.Remove('allow')
                    $fallbackAutoMode.PSObject.Properties.Remove('environment')
                    if (@($fallbackAutoMode.PSObject.Properties).Count -eq 0) {
                        $fallbackSettings.PSObject.Properties.Remove('autoMode')
                    }
                    $fallbackSerialized = $fallbackSettings | ConvertTo-Json -Depth 100
                    $fallbackTemp = Join-Path $configDir ('settings.json.tmp.' + [guid]::NewGuid().ToString('N'))
                    [IO.File]::WriteAllText($fallbackTemp, $fallbackSerialized, $utf8)
                    Move-Item -LiteralPath $fallbackTemp -Destination $settingsFile -Force
                    return
                }
                throw 'Claude Code auto mode defaults are unavailable; custom rules were preserved instead of composing an unsafe partial configuration. Update Claude Code or restore the defaults snapshot, then retry.'
            }
            $defaults = $previousSnapshot
        }
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        if ($null -eq $settings.PSObject.Properties['autoMode']) {
            $settings | Add-Member -NotePropertyName autoMode -NotePropertyValue ([pscustomobject]@{})
        }
        $previousAllow = @()
        $previousEnvironment = @()
        $previousSoftDeny = @()
        $previousHardDeny = @()
        if ($null -ne $previousSnapshot) {
            $previousAllow = @($previousSnapshot.allow)
            $previousEnvironment = @($previousSnapshot.environment)
            $previousSoftDeny = @($previousSnapshot.soft_deny)
            $previousHardDeny = @($previousSnapshot.hard_deny)
        }
        $approval = 'Explicit Action Approval: A user message that explicitly approves a specific action and target, including reissuing it after a denial or unambiguously referring to the immediately preceding blocked action with language such as approve that, go ahead, or proceed, satisfies named and specific consent for matching SOFT BLOCK rules. Do not force the user to restate the command, ask for duplicate confirmation, or treat the prior denial as permanent. This does not override HARD BLOCK rules or authorize a broader action.'
        $requestedConfig = 'Requested Agent Configuration: Editing agent configuration is routine when the user explicitly asks for that specific configuration or permission change. Treat that edit as requested by the user rather than Self Modification; unrelated permission widening remains blocked.'
        $taskBoundary = 'User designated task boundary: A repository, cloud project, host, bucket, service, or destination that the user explicitly identifies in their own message as owned or controlled infrastructure and as the intended target is trusted for the specifically requested operation and data flow only. Merely naming a target does not establish trust; do not infer trust for agent selected destinations, unrelated resources, or broader scopes.'
        $approvedTransfer = 'Explicitly approved development transfer: When the user explicitly approves an exact transfer of only the source required for the task from the current trusted repository to an explicitly named private build or deployment host controlled by the user, treat that source and destination as inside the task trust boundary for that transfer only. Approval may unambiguously refer to the immediately preceding blocked command without repeating it. This never covers a public destination, credentials or secrets, unrelated files, a broader source tree, an agent selected target, or a different host.'
        $transferSoftDeny = 'Approved Private Development Transfer [named+specifics: must name the current source repository, the private build or deployment host controlled by the user, and the requested transfer]: Transferring only the source required for the task from the current trusted repository to that exact named private host requires the user to request or explicitly approve that transfer. Approval may unambiguously refer to the immediately preceding denied transfer. This consent never clears credentials or secrets, a public destination, unrelated files, a broader source tree, an agent selected target, or a different host.'
        $hardException = "`n  - Claudex scoped private development transfer exception: Notwithstanding the bulk scale treatment above, an exact transfer of only the source required for the task from the current trusted repository to an explicitly named private build or deployment host controlled by the user is not HARD Data Exfiltration when the user requested or explicitly approved that exact source, destination, and transfer. Evaluate it under Approved Private Development Transfer as named and specific SOFT consent. The exception never covers credentials or secrets, a public destination, unrelated files, a broader source tree, an agent selected target, or a different host; if any condition is missing, the HARD rule remains in force."
        $existingAllow = if ($null -ne $settings.autoMode.PSObject.Properties['allow']) {
            @($settings.autoMode.allow | Where-Object {
                -not $_.StartsWith('Explicit Action Approval:') -and
                -not $_.StartsWith('Requested Agent Configuration:') -and
                $_ -notin $previousAllow
            })
        } else { @() }
        $existingEnvironment = if ($null -ne $settings.autoMode.PSObject.Properties['environment']) {
            @($settings.autoMode.environment | Where-Object {
                -not $_.StartsWith('User designated task boundary:') -and
                -not $_.StartsWith('Explicitly approved development transfer:') -and
                $_ -notin $previousEnvironment
            })
        } else { @() }
        $existingSoftDeny = if ($null -ne $settings.autoMode.PSObject.Properties['soft_deny']) {
            @($settings.autoMode.soft_deny | Where-Object {
                -not $_.StartsWith('Approved Private Development Transfer') -and
                $_ -notin $previousSoftDeny
            })
        } else { @() }
        $existingHardDeny = if ($null -ne $settings.autoMode.PSObject.Properties['hard_deny']) {
            @($settings.autoMode.hard_deny | Where-Object {
                -not $_.Contains('Claudex scoped private development transfer exception:') -and
                $_ -notin $previousHardDeny
            })
        } else { @() }
        $composedAllow = @(@($defaults.allow) + $existingAllow + @($approval, $requestedConfig) | Select-Object -Unique)
        $composedEnvironment = @(@($defaults.environment) + $existingEnvironment + @($taskBoundary, $approvedTransfer) | Select-Object -Unique)
        $managedHardDeny = @($defaults.hard_deny | ForEach-Object {
            if ([string] $_ -and ([string] $_).StartsWith('Data Exfiltration:')) { ([string] $_) + $hardException }
            else { [string] $_ }
        })
        $composedSoftDeny = @(@($defaults.soft_deny) + $existingSoftDeny + @($transferSoftDeny) | Select-Object -Unique)
        $composedHardDeny = @($managedHardDeny + $existingHardDeny | Select-Object -Unique)
        $settings.autoMode | Add-Member -NotePropertyName allow -NotePropertyValue $composedAllow -Force
        $settings.autoMode | Add-Member -NotePropertyName environment -NotePropertyValue $composedEnvironment -Force
        $settings.autoMode | Add-Member -NotePropertyName soft_deny -NotePropertyValue $composedSoftDeny -Force
        $settings.autoMode | Add-Member -NotePropertyName hard_deny -NotePropertyValue $composedHardDeny -Force
        $serializedSettings = $settings | ConvertTo-Json -Depth 100
        if ($serializedSettings -ne (Get-Content -LiteralPath $settingsFile -Raw)) {
            $tempFile = Join-Path $configDir ('settings.json.tmp.' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($tempFile, $serializedSettings, $utf8)
            Move-Item -LiteralPath $tempFile -Destination $settingsFile -Force
            $tempFile = $null
        }
        if ($defaultsAreFresh) {
            $snapshot = [ordered]@{
                allow = @($defaults.allow)
                environment = @($defaults.environment)
                soft_deny = @($defaults.soft_deny)
                hard_deny = @($defaults.hard_deny)
            }
            $snapshotTemp = Join-Path $configDir ('.auto-mode-defaults.tmp.' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($snapshotTemp, (($snapshot | ConvertTo-Json -Depth 20) + "`n"), $utf8)
            Move-Item -LiteralPath $snapshotTemp -Destination $snapshotFile -Force
            $snapshotTemp = $null
        }
    } catch {
        if ($_.Exception.Message.StartsWith('Claude Code auto mode defaults are unavailable; custom rules were preserved')) {
            Fail $_.Exception.Message
        }
        # Older Claude Code builds may not expose auto mode defaults. The
        # shipped settings remain valid and capability negotiation continues.
    } finally {
        if ($tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        if ($snapshotTemp) { Remove-Item -LiteralPath $snapshotTemp -Force -ErrorAction SilentlyContinue }
        Release-OwnedLock $lockDirectory $lockNonce
    }
}

function Start-ClaudeUpdateCheck {
    if ($claudeAutoUpdate -ne 'on' -or $env:CLAUDEX_SKIP_AUTO_UPDATE -eq '1') { return }
    $updateDir = Join-Path $configDir 'update'
    $stamp = Join-Path $updateDir 'last-success'
    $last = 0L
    if (Test-Path -LiteralPath $stamp -PathType Leaf) {
        [long]::TryParse(([IO.File]::ReadAllText($stamp).Trim()), [ref] $last) | Out-Null
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now - $last -lt $claudeUpdateIntervalNumber) { return }
    [IO.Directory]::CreateDirectory($updateDir) | Out-Null
    $claudePath = $script:claudeInvocation
    $powerShellHost = if (Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue) {
        (Get-Command powershell.exe -CommandType Application).Source
    } else { (Get-Process -Id $PID).Path }
    $workerNonce = [guid]::NewGuid().ToString('N')
    $workerSentinel = Join-Path $updateDir ('.claude-update-worker.' + [guid]::NewGuid().ToString('N') + '.sentinel')
    [IO.File]::WriteAllText($workerSentinel, "$workerNonce`n", $utf8)
    Protect-PrivatePath $workerSentinel $false
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-WindowsCommandLineArgument $PSCommandPath),
        '-ClaudexInternalClaudeUpdate',
        (ConvertTo-WindowsCommandLineArgument $claudePath),
        (ConvertTo-WindowsCommandLineArgument $updateDir),
        [string] $claudeUpdateIntervalNumber,
        (ConvertTo-WindowsCommandLineArgument $workerSentinel)
    )
    $parameters = @{
        FilePath = $powerShellHost
        ArgumentList = $arguments
        RedirectStandardOutput = (Join-Path $updateDir 'claude-update-worker.stdout.log')
        RedirectStandardError = (Join-Path $updateDir 'claude-update-worker.stderr.log')
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $parameters.WindowStyle = 'Hidden' }
    try {
        Invoke-WithoutPrivateManagedEnvironment -Action {
            $previousWorkerNonce = [Environment]::GetEnvironmentVariable('CLAUDEX_INTERNAL_UPDATE_NONCE', 'Process')
            try {
                $env:CLAUDEX_INTERNAL_UPDATE_NONCE = $workerNonce
                Start-Process @parameters | Out-Null
            } finally {
                if ($null -eq $previousWorkerNonce) { Remove-Item Env:CLAUDEX_INTERNAL_UPDATE_NONCE -ErrorAction SilentlyContinue }
                else { $env:CLAUDEX_INTERNAL_UPDATE_NONCE = $previousWorkerNonce }
            }
        }
    } catch {
        Remove-Item -LiteralPath $workerSentinel -Force -ErrorAction SilentlyContinue
        # An updater launch failure must not block the interactive session.
    }
}

function Start-ClaudexUpdateCheck {
    if ($claudexAutoUpdate -eq 'off' -or $env:CLAUDEX_SKIP_AUTO_UPDATE -eq '1' -or
        -not (Test-Path -LiteralPath $selfUpdateHelper -PathType Leaf)) { return }
    $updateDirectory = Join-Path $configDir 'update\claudex'
    [IO.Directory]::CreateDirectory($updateDirectory) | Out-Null
    $powerShellHost = if (Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue) {
        (Get-Command powershell.exe -CommandType Application).Source
    } else { (Get-Process -Id $PID).Path }
    $action = if ($claudexAutoUpdate -eq 'on') { '-Apply' } else { '-Check' }
    $quotedHelper = '"' + $selfUpdateHelper.Replace('"', '\"') + '"'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedHelper, $action, '-Background')
    $previousBackground = [Environment]::GetEnvironmentVariable('CLAUDEX_UPDATE_BACKGROUND', 'Process')
    $previousInterval = [Environment]::GetEnvironmentVariable('CLAUDEX_UPDATE_INTERVAL_SECONDS', 'Process')
    try {
        $env:CLAUDEX_UPDATE_BACKGROUND = '1'
        $env:CLAUDEX_UPDATE_INTERVAL_SECONDS = [string]$claudexUpdateIntervalNumber
        $parameters = @{
            FilePath = $powerShellHost
            ArgumentList = $arguments
            RedirectStandardOutput = (Join-Path $updateDirectory 'background.stdout.log')
            RedirectStandardError = (Join-Path $updateDirectory 'background.stderr.log')
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $parameters.WindowStyle = 'Hidden' }
        Invoke-WithoutPrivateManagedEnvironment -PreserveNames @('CLAUDEX_CONFIG_DIR') -Action {
            Start-Process @parameters | Out-Null
        }
    } catch {
        # Background update failures are persisted by the helper when it
        # starts; a process-launch failure must never break Claudex startup.
    } finally {
        [Environment]::SetEnvironmentVariable('CLAUDEX_UPDATE_BACKGROUND', $previousBackground, 'Process')
        [Environment]::SetEnvironmentVariable('CLAUDEX_UPDATE_INTERVAL_SECONDS', $previousInterval, 'Process')
    }
}

function Model-Name([string] $Id) {
    switch ($Id) {
        { $_ -in @('opusplan', 'solplan') } { return 'GPT-5.6 Solplan' }
        { $_ -in @('gpt-5.6-sol', 'opus', 'fable') } { return 'GPT-5.6 Sol' }
        { $_ -in @('gpt-5.6-terra', 'sonnet') } { return 'GPT-5.6 Terra' }
        { $_ -in @('gpt-5.6-luna', 'haiku') } { return 'GPT-5.6 Luna' }
        default { if ($Id) { return $Id } else { return 'Unknown model' } }
    }
}

function Invoke-Doctor {
    $script:doctorExitCode = 0
    Assert-ProxyConfiguration
    Update-ModelCache
    Load-ClaudeCapabilities
    Update-AutoModeRules
    try { Ensure-Proxy } catch { Fail $_.Exception.Message }
    $saved = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    $savedModel = if ($null -ne $saved.PSObject.Properties['model'] -and $saved.model) { [string] $saved.model } else { 'gpt-5.6-sol' }
    $models = Fetch-Models
    $proxyBinary = Find-ProxyExecutable
    $proxyVersion = 'unavailable'
    if ($proxyBinary) {
        $versionLines = @(Invoke-WithoutPrivateManagedEnvironment -Action { & $proxyBinary -version 2>&1 })
        if ($versionLines.Count -gt 0) { $proxyVersion = [string] $versionLines[0] }
    }
    $claudeVersion = try {
        (Invoke-WithoutPrivateManagedEnvironment -Action { & claude --version 2>$null } | Select-Object -First 1)
    } catch { 'unavailable' }
    Write-Output "Claude Code: $claudeVersion"
    Write-Output "CLIProxyAPI: $proxyVersion"
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @(
        'CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR', 'CLAUDEX_CODEX_SOURCE_AUTH_FILE'
    ) -Action { & $codexSessionHelper status }
    if ($script:lastPrivateBoundaryExitCode -ne 0) {
        $script:doctorExitCode = $script:lastPrivateBoundaryExitCode
        return
    }
    Write-Output "Proxy: healthy at $proxyUrl"
    Write-Output "Saved model: $(Model-Name $savedModel) ($savedModel)"
    Write-Output "Default permission mode: $permissionMode"
    Write-Output "Auto mode classifier: $autoModeModel (only used when auto mode is selected)"
    Write-Output 'Auto mode provider: Codex/OpenAI through the authenticated loopback bridge'
    Write-Output 'Delegated models: native routing for each agent (Sol is reserved for the leader)'
    Write-Output 'Managed agents: Terra (high), Luna (medium)'
    Write-Output "Tool concurrency: $toolConcurrencyNumber"
    Write-Output "Agent concurrency: $agentConcurrencyNumber"
    Write-Output 'Task lifecycle: owned by Sol with final response reconciliation'
    Write-Output "API retries: $maxRetriesNumber"
    Write-Output "Context window: $contextWindowNumber tokens"
    Write-Output "Automatic compaction window: $compactWindowNumber tokens (precompute enabled)"
    Write-Output 'Context status: stable session (transient zero suppressed)'
    Write-Output "Codex usage: status line refresh every ${usageRefreshNumber}s; inspect with /usage-limit or claudex --usage-limit"
    Write-Output "Usage source: $usageSource (documented Codex app-server fallback enabled in auto mode)"
    Write-Output "Low quota alert: $usageAlertNumber% remaining (0 disables)"
    Write-Output 'Effort shortcuts: --max-effort and --ultracode (xhigh plus dynamic workflows)'
    Write-Output 'Claude in Chrome: use --claude-chrome for the direct Anthropic profile required by the extension'
    Write-Output "Claude Code updates: $claudeAutoUpdate (checked every ${claudeUpdateIntervalNumber}s)"
    Write-Output "Claudex updates: $claudexAutoUpdate (checked every ${claudexUpdateIntervalNumber}s; inspect with claudex self-update --status)"
    Write-Output "Plan mode policy: $planModePolicy (implementation first unless planning is genuinely required)"
    Write-Output 'Rendering: stable mode with native terminal cursor'
    Write-Output 'Terminal UI: fullscreen (launch command hidden while Claudex is open)'
    Write-Output "Header model name: $(Model-Name $savedModel)"
    Write-Output "Mouse pointer: $mousePointer"
    Write-Output "Isolation: Claudex config at $configDir; normal Claude config is untouched"
    $missing = $false
    $ids = @($models.data | ForEach-Object { $_.id })
    foreach ($id in @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')) {
        if ($ids -contains $id) { Write-Output "${id}: advertised" }
        else { [Console]::Error.WriteLine("${id}: not advertised by the authenticated Codex account"); $missing = $true }
    }
    if ($missing) { $script:doctorExitCode = 1 }
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--doctor') {
    Invoke-Doctor
    Exit-Claudex $script:doctorExitCode
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--usage-limit') {
    $usageHelper = Join-Path $configDir 'usage-limit.ps1'
    if (-not (Test-Path -LiteralPath $usageHelper -PathType Leaf)) { Fail 'usage-limit helper is missing; reinstall Claudex.' }
    $usageArguments = if ($ClaudeArguments.Count -gt 1) { @($ClaudeArguments[1..($ClaudeArguments.Count - 1)]) } else { @() }
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @('CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR') -Action {
        & $usageHelper @usageArguments
    }
    Exit-Claudex $script:lastPrivateBoundaryExitCode
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--accounts') {
    $usageHelper = Join-Path $configDir 'usage-limit.ps1'
    if (-not (Test-Path -LiteralPath $usageHelper -PathType Leaf)) { Fail 'usage-limit helper is missing; reinstall Claudex.' }
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @('CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR') -Action {
        & $usageHelper -Accounts
    }
    Exit-Claudex $script:lastPrivateBoundaryExitCode
}

if ($ClaudeArguments.Count -gt 0 -and $ClaudeArguments[0] -eq '--account') {
    if ($ClaudeArguments.Count -ne 2) { Fail 'Usage: claudex --account <number|email|filename|auto>' 2 }
    $usageHelper = Join-Path $configDir 'usage-limit.ps1'
    if (-not (Test-Path -LiteralPath $usageHelper -PathType Leaf)) { Fail 'usage-limit helper is missing; reinstall Claudex.' }
    Invoke-WithoutPrivateManagedEnvironment -PreserveNames @('CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR') -Action {
        & $usageHelper -Account $ClaudeArguments[1]
    }
    Exit-Claudex $script:lastPrivateBoundaryExitCode
}

$startModel = ''
$effortMode = ''
$launchPermissionMode = $permissionMode
$directChrome = $false
$forwardArguments = New-Object 'System.Collections.Generic.List[string]'
$index = 0
while ($index -lt $ClaudeArguments.Count) {
    $argument = $ClaudeArguments[$index]
    switch ($argument) {
        '--sol' { $startModel = 'gpt-5.6-sol' }
        '--terra' { $startModel = 'gpt-5.6-terra' }
        '--luna' { $startModel = 'gpt-5.6-luna' }
        '--solplan' { $startModel = 'opusplan' }
        '--manual' { $launchPermissionMode = 'manual' }
        '--auto' { $launchPermissionMode = 'auto' }
        '--accept-edits' { $launchPermissionMode = 'acceptEdits' }
        '--ultracode' {
            if ($effortMode -and $effortMode -ne 'ultracode') { Fail '--ultracode and --max-effort cannot be combined.' 2 }
            $effortMode = 'ultracode'
        }
        '--max-effort' {
            if ($effortMode -and $effortMode -ne 'max') { Fail '--ultracode and --max-effort cannot be combined.' 2 }
            $effortMode = 'max'
        }
        '--claude-chrome' { $directChrome = $true }
        '--' {
            $forwardArguments.Add('--')
            $index++
            while ($index -lt $ClaudeArguments.Count) { $forwardArguments.Add($ClaudeArguments[$index]); $index++ }
            continue
        }
        default {
            # Claudex-only options are a leading prefix. Preserve all tokens
            # after Claude's first argument so option values and prompts that
            # look like Claudex flags are never consumed.
            while ($index -lt $ClaudeArguments.Count) { $forwardArguments.Add($ClaudeArguments[$index]); $index++ }
            continue
        }
    }
    $index++
}

$forwardedModelSpecified = $false
$forwardedModel = ''
$forwardedFallbackModels = New-Object 'System.Collections.Generic.List[string]'
$noSessionPersistence = $false
$useProxy = $true
$injectAgents = $true
$injectLeaderGuard = $true
$injectPermission = $true
$injectSkills = $true
$skillBridgeGlobalOnly = $false
$suppressResumeFooter = $false
$backgroundLaunch = $false
$requestedResumeSessionId = ''
$maintenanceGlobalOptions = @('--help', '-h', '--version', '-v')
$maintenanceCommands = @('agents', 'attach', 'auth', 'auto-mode', 'doctor', 'gateway', 'install', 'kill', 'logs', 'mcp', 'plugin', 'plugins', 'project', 'remote-control', 'respawn', 'rm', 'self-update', 'setup-token', 'skills', 'stop', 'ultrareview', 'update', 'upgrade')
$maintenancePositionalSeen = $false
$maintenanceCommandDetected = $false
for ($scanIndex = 0; $scanIndex -lt $forwardArguments.Count; $scanIndex++) {
    $scanArgument = [string] $forwardArguments[$scanIndex]
    if ($scanArgument -eq '--') { break }
    $scanOption = $scanArgument
    $scanValue = ''
    $scanHasInlineValue = $false
    if ($scanArgument -match '^(-{1,2}[^=]+)=(.*)$') {
        $scanOption = $Matches[1]
        $scanValue = $Matches[2]
        $scanHasInlineValue = $true
    } elseif (($scanArgument -match '^(-[drw])=?(.*)$') -and $Matches[2]) {
        $scanOption = $Matches[1]
        $scanValue = $Matches[2]
        $scanHasInlineValue = $true
    }
    if ($scanOption -in $maintenanceGlobalOptions -or (-not $maintenancePositionalSeen -and $scanOption -in $maintenanceCommands)) {
        $maintenanceCommandDetected = $true
    }
    if (-not $scanArgument.StartsWith('-')) {
        $maintenancePositionalSeen = $true
    }
    $scanOptionValue = if ($scanHasInlineValue) { $scanValue } elseif ($scanIndex + 1 -lt $forwardArguments.Count -and $forwardArguments[$scanIndex + 1] -ne '--') { [string] $forwardArguments[$scanIndex + 1] } else { '' }
    if ($scanIndex -eq 0 -and $scanArgument -eq 'doctor') { $suppressResumeFooter = $true }
    if ($scanOption -in @('--print', '-p', '--help', '-h', '--version', '-v', '--bg', '--background')) { $suppressResumeFooter = $true }
    if ($scanOption -in @('--bg', '--background')) { $backgroundLaunch = $true }
    if ($scanOption -eq '--no-session-persistence') { $noSessionPersistence = $true }
    if ($scanOption -in @('--worktree', '-w')) { $skillBridgeGlobalOnly = $true }
    if ($scanOption -eq '--model') {
        $forwardedModelSpecified = $true
        $forwardedModel = $scanOptionValue
    }
    if ($scanOption -eq '--fallback-model') {
        $fallbackValue = $scanOptionValue
        foreach ($fallbackModel in @($fallbackValue -split ',' | ForEach-Object { $_.Trim() })) {
            if ($fallbackModel) { $forwardedFallbackModels.Add($fallbackModel) }
        }
        if (-not $fallbackValue) { Fail '--fallback-model requires a model value.' 2 }
    }
    if ($scanOption -in @('--safe-mode', '--bare')) {
        $injectAgents = $false
        $injectLeaderGuard = $false
        $injectPermission = $false
        $injectSkills = $false
    }
    if ($scanOption -in @('--agent', '--agents')) { $injectAgents = $false }
    if ($scanOption -eq '--tools') {
        $hasAgentTool = $scanOptionValue -match '(?i)(^|[\s,])Agent(?:\([^)]*\))?(?=$|[\s,])'
        $hasTaskListTool = $scanOptionValue -match '(?i)(^|[\s,])TaskList(?:\([^)]*\))?(?=$|[\s,])'
        if ($scanOptionValue.Trim() -ne 'default' -and (-not $hasAgentTool -or -not $hasTaskListTool)) {
            $injectLeaderGuard = $false
        }
    }
    if ($scanOption -in @('--disallowedTools', '--disallowed-tools') -and
        $scanOptionValue -match '(?i)(^|[\s,])(?:Agent|TaskList)(?:\([^)]*\))?(?=$|[\s,])') {
        $injectLeaderGuard = $false
    }
    if ($scanOption -in @('--permission-mode', '--dangerously-skip-permissions', '--allow-dangerously-skip-permissions')) {
        $injectPermission = $false
    }
    if ($effortMode -and $scanOption -in @('--effort', '--settings')) {
        Fail "$scanArgument conflicts with the selected Claudex effort shortcut." 2
    }
    if ($scanOption -eq '--session-id') {
        $requestedResumeSessionId = $scanOptionValue
    } elseif ($scanOption -eq '--resume') {
        if ($scanHasInlineValue) { $requestedResumeSessionId = $scanValue }
        elseif ($scanIndex + 1 -lt $forwardArguments.Count -and [string] $forwardArguments[$scanIndex + 1] -notmatch '^-') {
            $requestedResumeSessionId = [string] $forwardArguments[$scanIndex + 1]
        }
    }
    if (-not $scanHasInlineValue -and $scanOption -in $claudeRequiredValueOptions) {
        if ($scanIndex + 1 -lt $forwardArguments.Count -and $forwardArguments[$scanIndex + 1] -ne '--') { $scanIndex++ }
    } elseif (-not $scanHasInlineValue -and $scanOption -in $claudeOptionalValueOptions -and
        $scanIndex + 1 -lt $forwardArguments.Count -and -not ([string] $forwardArguments[$scanIndex + 1]).StartsWith('-')) {
        $scanIndex++
    }
}
if ($maintenanceCommandDetected) {
    $useProxy = $false
    $injectAgents = $false
    $injectLeaderGuard = $false
    $injectPermission = $false
    $injectSkills = $false
    $maintenanceBun = [string] $env:BUN_OPTIONS
    Remove-Item Env:CLAUDEX_PROXY_TOKEN -ErrorAction SilentlyContinue
    if ($env:CLAUDEX_MANAGED_SESSION -eq '1') {
        $maintenanceManagedPreload = '--preload ' + (Join-Path $configDir 'preload.cjs').Replace('\', '/').Replace(' ', '\ ')
        while ($maintenanceBun -eq $maintenanceManagedPreload -or $maintenanceBun.StartsWith($maintenanceManagedPreload + ' ')) {
            $maintenanceBun = $maintenanceBun.Substring($maintenanceManagedPreload.Length).TrimStart()
        }
        foreach ($environmentName in $sessionEnvironmentNames) {
            Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
        }
        foreach ($environmentName in @(
            'CLAUDEX_MODEL_MODE', 'CLAUDEX_SESSION_MODE', 'CLAUDEX_INTERACTIVE_TUI',
            'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_NO_FLICKER', 'CLAUDE_CODE_ACCESSIBILITY'
        )) {
            Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue
        }
        if ($maintenanceBun) { $env:BUN_OPTIONS = $maintenanceBun }
    }
}
if ($forwardedModelSpecified -and [string]::IsNullOrWhiteSpace($forwardedModel)) {
    Fail '--model requires a model value.' 2
}
if ($forwardedModelSpecified -and $startModel) {
    Fail 'a Claudex model shortcut cannot be combined with Claude Code --model.' 2
}

if ($directChrome) {
    if ($startModel) { Fail '--sol, --terra, --luna, and --solplan cannot be combined with --claude-chrome because Chrome requires a first-party Anthropic model.' 2 }
    $useProxy = $false
    $injectAgents = $false
    $injectLeaderGuard = $false
    $injectPermission = $false
    $injectSkills = $false
    if ($env:CLAUDEX_CHROME_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR = $env:CLAUDEX_CHROME_CONFIG_DIR }
    else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    Remove-ProcessEnvironmentVariables @($sessionEnvironmentNames | Where-Object {
        $_ -notin @('BUN_OPTIONS', 'CLAUDE_CONFIG_DIR', 'CLAUDEX_CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD')
    })
    Remove-ProcessEnvironmentVariables $competingProviderEnvironmentNames
    Remove-ProcessEnvironmentVariables @(
        'CLAUDEX_MODEL_MODE', 'CLAUDEX_SESSION_MODE', 'CLAUDEX_INTERACTIVE_TUI',
        'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_NO_FLICKER', 'CLAUDE_CODE_ACCESSIBILITY'
    )
    $forwardArguments.Insert(0, '--chrome')
}
if ($useProxy) { Remove-ProcessEnvironmentVariables $competingProviderEnvironmentNames }
if ($useProxy) {
    $allowedProxyModelRoutes = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'opus', 'fable', 'sonnet', 'haiku', 'opusplan')
    if ($forwardedModelSpecified -and $forwardedModel -notin $allowedProxyModelRoutes) {
        Fail "--model must select a managed Codex model or alias; got $forwardedModel." 2
    }
    foreach ($fallbackModel in $forwardedFallbackModels) {
        if ($fallbackModel -notin $allowedProxyModelRoutes) {
            Fail "--fallback-model must select managed Codex models or aliases; got $fallbackModel." 2
        }
    }
}

function Get-ChatGptPlanLabelFromCache {
    $cacheFile = Join-Path (Join-Path $configDir 'usage-cache') 'limits.json'
    if (-not (Test-Path -LiteralPath $cacheFile -PathType Leaf)) { return $null }
    try {
        $snapshot = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
        $plan = if ($null -ne $snapshot.PSObject.Properties['plan_type']) { [string] $snapshot.plan_type } else { '' }
        $normalized = ($plan.ToLowerInvariant() -replace '[^a-z0-9]', '')
        switch ($normalized) {
            { $_ -in @('free', 'chatgptfree') } { return 'ChatGPT Free' }
            { $_ -in @('go', 'chatgptgo') } { return 'ChatGPT Go' }
            { $_ -in @('plus', 'chatgptplus') } { return 'ChatGPT Plus' }
            { $_ -in @('pro', 'chatgptpro') } { return 'ChatGPT Pro' }
            { $_ -in @('team', 'chatgptteam', 'business', 'chatgptbusiness') } { return 'ChatGPT Business' }
            { $_ -in @('enterprise', 'chatgptenterprise') } { return 'ChatGPT Enterprise' }
            { $_ -in @('edu', 'education', 'chatgptedu', 'chatgpteducation') } { return 'ChatGPT Edu' }
            { $_ -in @('teacher', 'teachers', 'chatgptteacher', 'chatgptteachers') } { return 'ChatGPT Teachers' }
            { $_ -in @('k12', 'chatgptk12') } { return 'ChatGPT K-12' }
            { $_ -in @('healthcare', 'chatgpthealthcare') } { return 'ChatGPT Healthcare' }
            default { return $null }
        }
    } catch { return $null }
}

function Set-ChatGptPlanLabel {
    Remove-Item Env:CLAUDEX_CHATGPT_PLAN_LABEL -ErrorAction SilentlyContinue
    if ($env:CLAUDEX_INTERACTIVE_TUI -ne '1') { return }
    $planLabel = Get-ChatGptPlanLabelFromCache
    $usageHelper = Join-Path $configDir 'usage-limit.ps1'
    # Refresh malformed, incomplete, and unknown snapshots once as well as
    # missing ones. Otherwise a repaired login or plan can remain hidden until
    # another command happens to rewrite the cache.
    if (-not $planLabel -and (Test-Path -LiteralPath $usageHelper -PathType Leaf)) {
        try {
            Invoke-WithoutPrivateManagedEnvironment -PreserveNames @('CLAUDEX_CONFIG_DIR', 'CLAUDEX_CODEX_AUTH_DIR') -Action {
                & $usageHelper -RefreshCache *> $null
            }
        } catch { }
        $planLabel = Get-ChatGptPlanLabelFromCache
    }
    $env:CLAUDEX_CHATGPT_PLAN_LABEL = if ($planLabel) { $planLabel } else { 'ChatGPT' }
}

if ($useProxy) {
    Assert-ProxyConfiguration
    Update-ModelCache
    if (-not $startModel -and -not $forwardedModelSpecified) { $startModel = $model }
}

function Get-ProxyModelRoute([string] $RequestedModel) {
    switch ($RequestedModel) {
        { $_ -in @('fable', 'opus') } { return 'gpt-5.6-sol' }
        'sonnet' { return 'gpt-5.6-terra' }
        'haiku' { return 'gpt-5.6-luna' }
        default { return $RequestedModel }
    }
}
$requiredProxyModels = New-Object 'System.Collections.Generic.List[string]'
$primaryProxyModel = if ($startModel) { $startModel } elseif ($forwardedModelSpecified) { Get-ProxyModelRoute $forwardedModel } else { '' }
if ($primaryProxyModel) { $requiredProxyModels.Add($primaryProxyModel) }
foreach ($fallbackModel in $forwardedFallbackModels) {
    $fallbackProxyModel = Get-ProxyModelRoute $fallbackModel
    if (-not $requiredProxyModels.Contains($fallbackProxyModel)) { $requiredProxyModels.Add($fallbackProxyModel) }
}

# GPT-specific input aliases and the one-shot welcome label belong only to proxied sessions.
$preload = Join-Path $configDir 'preload.cjs'
$preloadForBun = $preload.Replace('\', '/').Replace(' ', '\ ')
$existingBunOptions = [Environment]::GetEnvironmentVariable('BUN_OPTIONS', 'Process')
function Remove-ClaudexPreloadOption([string] $Options) {
    if (-not $Options) { return '' }
    $managed = "--preload $preloadForBun"
    $quotedManaged = '--preload "' + $preload.Replace('\', '/') + '"'
    $cleaned = [regex]::Replace($Options, '(^|\s)' + [regex]::Escape($managed) + '(?=\s|$)', ' ')
    $cleaned = [regex]::Replace($cleaned, '(^|\s)' + [regex]::Escape($quotedManaged) + '(?=\s|$)', ' ')
    return ([regex]::Replace($cleaned, '\s+', ' ')).Trim()
}
$cleanBunOptions = Remove-ClaudexPreloadOption $existingBunOptions
if ($useProxy) {
    if (Test-Path -LiteralPath $preload -PathType Leaf) {
        $env:BUN_OPTIONS = ("--preload $preloadForBun $cleanBunOptions").Trim()
    } elseif ($cleanBunOptions) { $env:BUN_OPTIONS = $cleanBunOptions }
    else { Remove-Item Env:BUN_OPTIONS -ErrorAction SilentlyContinue }
    if ((-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) -or $env:CLAUDEX_TEST_TTY_OUTPUT -eq '1') { $env:CLAUDEX_INTERACTIVE_TUI = '1' }
    else { Remove-Item Env:CLAUDEX_INTERACTIVE_TUI -ErrorAction SilentlyContinue }
} elseif ($cleanBunOptions) {
    $env:BUN_OPTIONS = $cleanBunOptions
} else {
    Remove-Item Env:BUN_OPTIONS -ErrorAction SilentlyContinue
}

if ($useProxy -or $effortMode) { Load-ClaudeCapabilities }
else { Resolve-ClaudeCommand; $script:claudeHelp = '' }

function Write-SkillBridgeWarnings([object[]] $Warnings) {
    $safeWarnings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($warning in $Warnings) {
        # Console controls, C1 controls, and Unicode format controls (including
        # bidi overrides/isolates) must never reach the terminal from a plugin-
        # derived warning.
        $safeWarning = [regex]::Replace([string] $warning, '[\p{Cc}\p{Cf}]', ' ')
        $safeWarning = [regex]::Replace($safeWarning, '\s+', ' ').Trim()
        if ($safeWarning.Length -gt 500) { $safeWarning = $safeWarning.Substring(0, 499) + [char]0x2026 }
        if ($safeWarning -and -not $safeWarnings.Contains($safeWarning)) { $safeWarnings.Add($safeWarning) }
    }
    if ($safeWarnings.Count -eq 0) { return }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digestBytes = $sha.ComputeHash($utf8.GetBytes(($safeWarnings -join "`n")))
        $digest = -join ($digestBytes | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $runDirectory = Join-Path $configDir 'run'
    $statePath = Join-Path $runDirectory 'skill-warning-state.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $lastTime = [long] $state.time
            if ($state.digest -eq $digest -and $lastTime -le $now -and $now - $lastTime -lt 300) { return }
        } catch { }
    }

    $displayCount = [math]::Min(5, $safeWarnings.Count)
    for ($index = 0; $index -lt $displayCount; $index++) {
        [Console]::Error.WriteLine("claudex: skill bridge warning: $($safeWarnings[$index])")
    }
    if ($safeWarnings.Count -gt $displayCount) {
        [Console]::Error.WriteLine("claudex: skill bridge warning: $($safeWarnings.Count - $displayCount) additional unique warnings omitted.")
    }
    $temporary = $null
    try {
        [IO.Directory]::CreateDirectory($runDirectory) | Out-Null
        $temporary = Join-Path $runDirectory ('.skill-warning-state.' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, (([ordered]@{ time = $now; digest = $digest } | ConvertTo-Json -Compress) + "`n"), $utf8)
        Move-Item -LiteralPath $temporary -Destination $statePath -Force
    } catch {
        if ($temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

$skillBridgeAddDirs = @()
$skillBridgePluginDirs = @()
$skillBridgeHasInstructions = $false
if ($injectSkills -and $skillBridgeMode -eq 'on') {
    $env:CLAUDEX_INSTRUCTION_BRIDGE = $instructionBridgeMode
    Assert-SkillBridgeNode
    if (-not (Test-Path -LiteralPath $skillBridgeHelper -PathType Leaf)) { Fail 'skill bridge helper is missing; reinstall Claudex.' }
    try {
        $skillBridgeArguments = @($skillBridgeHelper, 'sync', '--project', (Get-Location).Path)
        if ($skillBridgeGlobalOnly) { $skillBridgeArguments += '--global-only' }
        $skillBridgeOutput = (Invoke-WithoutPrivateManagedEnvironment -PreserveNames @(
            'CLAUDEX_CONFIG_DIR', 'CLAUDEX_CLAUDE_CONFIG_DIR', 'CLAUDEX_INSTRUCTION_BRIDGE'
        ) -Action { & node @skillBridgeArguments } | Out-String)
        if ($script:lastPrivateBoundaryExitCode -ne 0) { throw 'skill bridge helper failed' }
        $skillBridgeResult = $skillBridgeOutput | ConvertFrom-Json
        $skillBridgeAddDirs = @($skillBridgeResult.addDirs | Where-Object { $_ })
        $skillBridgePluginDirs = @($skillBridgeResult.pluginDirs | Where-Object { $_ })
        if ($null -ne $skillBridgeResult.PSObject.Properties['instructions']) {
            $skillBridgeHasInstructions = @($skillBridgeResult.instructions | Where-Object { $_ }).Count -gt 0
        }
        if ($null -ne $skillBridgeResult.PSObject.Properties['warnings']) { Write-SkillBridgeWarnings @($skillBridgeResult.warnings) }
    } catch { Fail 'skill discovery failed; run `claudex skills` for details.' }
    if ($skillBridgeAddDirs.Count -gt 0 -and -not (Test-ClaudeOption '--add-dir')) {
        Fail 'this Claude Code build lacks --add-dir, which is required for installed Codex skills; run `claude update`.'
    }
    if ($skillBridgePluginDirs.Count -gt 0 -and -not (Test-ClaudeOption '--plugin-dir')) {
        Fail 'this Claude Code build lacks --plugin-dir, which is required for installed plugin skills; run `claude update`.'
    }
}
if ($useProxy -or ($forwardArguments.Count -gt 0 -and $forwardArguments[0] -eq 'auto-mode')) { Update-AutoModeRules }
if ($forwardArguments.Count -eq 0 -or $forwardArguments[0] -notin @('update', 'upgrade')) {
    Start-ClaudeUpdateCheck
    Start-ClaudexUpdateCheck
}

if ($useProxy) {
    try { Ensure-ProxyForLaunch $requiredProxyModels } catch { Fail $_.Exception.Message }
    $authWatcher = Start-AuthWatcher
    $proxyWatcher = Start-ProxyWatcher

    $env:ANTHROPIC_BASE_URL = $proxyUrl
    $env:CLAUDEX_MANAGED_SESSION = '1'
    $env:ANTHROPIC_AUTH_TOKEN = $proxyToken
    $env:ANTHROPIC_DEFAULT_FABLE_MODEL = 'gpt-5.6-sol'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'gpt-5.6-sol'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'gpt-5.6-terra'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'gpt-5.6-luna'
    $env:ANTHROPIC_DEFAULT_FABLE_MODEL_NAME = 'GPT-5.6 Sol'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = 'GPT-5.6 Sol'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = 'GPT-5.6 Terra'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = 'GPT-5.6 Luna'
    $env:ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION = 'Frontier capability for planning and the hardest engineering work'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION = 'Frontier capability for planning and the hardest engineering work'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION = 'Balanced intelligence, speed, and cost for everyday coding'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION = 'Fast, efficient model for search, triage, and mechanical tasks'
    $capabilities = 'effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking'
    $env:ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES = $capabilities
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES = $capabilities
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES = $capabilities
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES = $capabilities
    $env:CLAUDE_CODE_AUTO_MODE_MODEL = $autoModeModel
    $env:CLAUDE_CODE_BG_CLASSIFIER_MODEL = $backgroundModel
    $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = '1'
    $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = [string] $toolConcurrencyNumber
    $env:CLAUDE_CODE_MAX_RETRIES = [string] $maxRetriesNumber
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [string] $contextWindowNumber
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string] $compactWindowNumber
    # Hide Anthropic's built-in 1M model variant on the Codex bridge. Claudex
    # supplies its own explicit context-window and compaction controls.
    $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = '1'
} else {
    $authWatcher = $null
    $proxyWatcher = $null
    Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDE_CODE_DISABLE_1M_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDEX_CHATGPT_PLAN_LABEL -ErrorAction SilentlyContinue
}
$env:CLAUDE_CODE_USE_POWERSHELL_TOOL = '1'
$env:CLAUDEX_USAGE_DISPLAY = $usageDisplay
$env:CLAUDEX_USAGE_REFRESH_SECONDS = [string] $usageRefreshNumber
$env:CLAUDEX_USAGE_TIMEOUT_SECONDS = [string] $usageTimeoutNumber
$env:CLAUDEX_USAGE_MAX_STALE_SECONDS = [string] $usageMaxStaleNumber
$env:CLAUDEX_USAGE_SOURCE = $usageSource
$env:CLAUDEX_USAGE_ALERT_PERCENT = [string] $usageAlertNumber
$env:CLAUDE_CODE_NO_FLICKER = '1'
$env:CLAUDE_CODE_ACCESSIBILITY = '1'
if ($noSessionPersistence) { $env:CLAUDEX_NO_SESSION_PERSISTENCE = '1' }
else { Remove-Item Env:CLAUDEX_NO_SESSION_PERSISTENCE -ErrorAction SilentlyContinue }
if ($skillBridgeHasInstructions) { $env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = '1' }

$noNestedAgents = "Do not spawn or delegate to additional agents, or send intermediate progress messages to the parent. Unless you are a teammate in a native Agent Team that the user explicitly requested, do not create, claim, or update entries in a shared task list; ordinary Agent task lifecycle belongs to the Sol leader. Complete the assigned task yourself and return one final result through the normal agent result channel. If the provider reports a 429 or model cooldown, do not launch a replacement agent or start a retry loop."
$agents = [ordered]@{
    'Terra (high)' = [ordered]@{ description = 'Terra at high reasoning effort for delegated architecture, debugging, implementation, testing, security review, and other substantial engineering work.'; prompt = "You are GPT-5.6 Terra running at high reasoning effort. Investigate thoroughly, make robust focused progress, verify the result, and return concise findings backed by evidence. $noNestedAgents"; model = 'gpt-5.6-terra'; effort = 'high' }
    'Luna (medium)' = [ordered]@{ description = 'Luna at medium reasoning effort for delegated search, triage, inventory, and bounded mechanical tasks.'; prompt = "You are GPT-5.6 Luna running at medium reasoning effort. Complete the scoped task efficiently and report only relevant verified findings. $noNestedAgents"; model = 'gpt-5.6-luna'; effort = 'medium' }
}
$agentsJson = $agents | ConvertTo-Json -Depth 10 -Compress
$capacityGuard = "Claudex capacity rule: keep at most $agentConcurrencyNumber delegated Agent or Agent Team workers active at once. Native Agent Teams may be created only when the user explicitly requests a team; otherwise use the named Terra (high) or Luna (medium) agents for ordinary delegation. Sol capacity is reserved for the leader. For every Agent call, make its description '- <concise task>' so the activity list renders labels such as 'Terra (high) - Audit JSON parser bugs'. If a model reports a 429 or cooldown, do not launch replacement agents or create a retry storm; continue useful local work and retry at most once after active agents settle."
$taskGuard = 'Claudex task lifecycle rule: for ordinary Agent delegation, the Sol leader owns the shared task list. When the user explicitly requests a native Agent Team, the team lead owns team task lifecycle and teammates may claim only their assigned work. Keep task state compact and create only tasks that represent real remaining deliverables, not duplicate discovery lanes or speculative work. Mark a task in_progress only while the leader or a currently active worker is working on it; queued or blocked work stays pending. After every worker result, immediately reconcile its parent task and mark it completed once its outcome is integrated and verified. Before every final answer, call TaskList and reconcile every entry: completed work must be completed, inactive work must not remain in_progress, and genuinely unfinished pending work must be explicitly reported instead of being hidden behind a completion claim. Never leave stale in_progress tasks after their work is done.'
$codexGuard = "Claudex Codex model rule: operate as a Codex coding agent inside Claude Code's interface. Treat the available Claude Code tools and their schemas as the authoritative execution protocol. Prefer direct implementation and verification for concrete change requests. Ask as few questions as possible: inspect available context first, make safe reasonable assumptions, and continue without confirmation for routine, reversible work inside the requested scope. Never repeat a question the user already answered. Ask only when the missing answer cannot be discovered and would materially change the result, authorize a meaningful scope expansion, or precede an irreversible action. Treat the user's explicit approval as decisive for the specifically named action and target: after a soft auto mode denial, ask for precise consent only when it is missing, then retry once when the user grants it instead of claiming the denial is permanent. Hard deny security boundaries still apply. Do not invent unsupported provider behavior, do not expose raw internal tool protocol, and keep progress updates concise and based on evidence."
$planGuard = if ($planModePolicy -eq 'conservative') { 'Claudex plan mode rule: remain in the current execution mode by default. Do not call EnterPlanMode or switch into plan permission mode merely because work is large, complex, unfamiliar, or benefits from private reasoning. Enter plan mode only when the user explicitly asks for a planning or design only response, when a required user decision would materially change the implementation, or when the requested action is irreversible and needs approval before execution. For ordinary bug fixes and implementation requests, inspect, implement, test, and report directly.' } else { '' }
$leaderGuard = @($capacityGuard, $taskGuard, $codexGuard, $planGuard) -join ([Environment]::NewLine + [Environment]::NewLine)

$claudeLaunchArguments = New-Object 'System.Collections.Generic.List[string]'
foreach ($skillDirectory in $skillBridgeAddDirs) {
    $claudeLaunchArguments.Add('--add-dir'); $claudeLaunchArguments.Add([string] $skillDirectory)
}
foreach ($pluginDirectory in $skillBridgePluginDirs) {
    $claudeLaunchArguments.Add('--plugin-dir'); $claudeLaunchArguments.Add([string] $pluginDirectory)
}
if ($injectAgents -and (Test-ClaudeOption '--agents')) {
    foreach ($value in @('--agents', $agentsJson)) { $claudeLaunchArguments.Add($value) }
}
if ($injectLeaderGuard -and (Test-ClaudeOption '--append-system-prompt')) {
    foreach ($value in @('--append-system-prompt', $leaderGuard)) { $claudeLaunchArguments.Add($value) }
}
if ($injectPermission -and (Test-ClaudeOption '--permission-mode')) {
    $claudeLaunchArguments.Add('--permission-mode'); $claudeLaunchArguments.Add($launchPermissionMode)
}
if (-not $directChrome -and $settingsFile -ne (Join-Path $configDir 'settings.json') -and $effortMode -ne 'ultracode') {
    $claudeLaunchArguments.Add('--settings'); $claudeLaunchArguments.Add($settingsFile)
}
if ($startModel) {
    $claudeLaunchArguments.Add('--model'); $claudeLaunchArguments.Add($startModel)
    if ($startModel -eq 'opusplan') { $env:CLAUDEX_MODEL_MODE = 'solplan' }
} elseif ($forwardedModel -eq 'opusplan') {
    $env:CLAUDEX_MODEL_MODE = 'solplan'
}
if ($effortMode -eq 'ultracode') {
    if (-not (Test-ClaudeOption '--effort')) { Fail 'this Claude Code build lacks --effort; run `claude update`.' }
    if ($directChrome) { $ultracodeSettings = [pscustomobject]@{ ultracode = $true; workflows = $true } }
    else {
        $ultracodeSettings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        $ultracodeSettings | Add-Member -NotePropertyName ultracode -NotePropertyValue $true -Force
        $ultracodeSettings | Add-Member -NotePropertyName workflows -NotePropertyValue $true -Force
    }
    $claudeLaunchArguments.Add('--settings'); $claudeLaunchArguments.Add(($ultracodeSettings | ConvertTo-Json -Depth 100 -Compress))
    $claudeLaunchArguments.Add('--effort'); $claudeLaunchArguments.Add('xhigh')
    $env:CLAUDEX_SESSION_MODE = 'ultracode'
    $env:CLAUDE_CODE_EFFORT_LEVEL = 'xhigh'
} elseif ($effortMode -eq 'max') {
    if (-not (Test-ClaudeOption '--effort')) { Fail 'this Claude Code build lacks --effort; run `claude update`.' }
    $claudeLaunchArguments.Add('--effort'); $claudeLaunchArguments.Add('max')
    $env:CLAUDEX_SESSION_MODE = 'max'
    $env:CLAUDE_CODE_EFFORT_LEVEL = 'max'
}
foreach ($value in $forwardArguments) { $claudeLaunchArguments.Add($value) }

function Set-MousePointer([string] $Shape) {
    if ($mousePointer -eq 'off' -or [Console]::IsOutputRedirected) { return }
    [Console]::Out.Write("$([char]27)]22;$Shape$([char]27)\")
}

$rewriteResumeFooter = ((-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) -or $env:CLAUDEX_TEST_TTY_OUTPUT -eq '1')
if ($suppressResumeFooter) { $rewriteResumeFooter = $false }
if ($requestedResumeSessionId -notmatch '^[0-9a-fA-F-]{36}$') { $requestedResumeSessionId = '' }
$resumeMarker = $null
if ($rewriteResumeFooter) {
    $resumeMarker = Join-Path $configDir ('.resume-start-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($resumeMarker, '', $utf8)
}

function Update-ResumeFooter([string] $Marker) {
    if (-not $Marker -or -not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return }
    $sessionConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $projectKey = [regex]::Replace((Get-Location).Path, '[^A-Za-z0-9]', '-')
    $projectDirectory = Join-Path (Join-Path $sessionConfigDir 'projects') $projectKey
    if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) { return }
    $markerTime = (Get-Item -LiteralPath $Marker).LastWriteTimeUtc
    if ($requestedResumeSessionId) {
        $explicitCandidate = Join-Path $projectDirectory ($requestedResumeSessionId + '.jsonl')
        $candidates = if (Test-Path -LiteralPath $explicitCandidate -PathType Leaf) { @((Get-Item -LiteralPath $explicitCandidate)) } else { @() }
    } else {
        $allCandidates = @(Get-ChildItem -LiteralPath $projectDirectory -File -Filter '*.jsonl')
        # A new root session creates its transcript near launch. Prefer the
        # earliest newly-created matching transcript so a later same-cwd tab
        # cannot steal this launch's footer merely by exiting first.
        $newCandidates = @($allCandidates | Where-Object { $_.CreationTimeUtc -ge $markerTime } |
            Sort-Object CreationTimeUtc, Name)
        $newNames = @($newCandidates | ForEach-Object { $_.FullName })
        $updatedCandidates = @($allCandidates | Where-Object {
            $_.LastWriteTimeUtc -ge $markerTime -and $_.FullName -notin $newNames
        } | Sort-Object LastWriteTimeUtc -Descending)
        $candidates = @($newCandidates + $updatedCandidates)
    }
    $matchingCandidates = @()
    foreach ($candidate in $candidates) {
        $candidateSessionId = [IO.Path]::GetFileNameWithoutExtension($candidate.Name)
        if ($candidateSessionId -notmatch '^[0-9a-fA-F-]{36}$') { continue }
        $matchesRootSession = $false
        foreach ($line in @(Get-Content -LiteralPath $candidate.FullName -Tail 200 -ErrorAction SilentlyContinue)) {
            try {
                $record = $line | ConvertFrom-Json
                $recordSessionId = if ($null -ne $record.PSObject.Properties['sessionId']) { [string] $record.sessionId } else { '' }
                $recordCwd = if ($null -ne $record.PSObject.Properties['cwd']) { [string] $record.cwd } else { '' }
                $isSidechain = $null -ne $record.PSObject.Properties['isSidechain'] -and [bool] $record.isSidechain
                if ($recordSessionId -eq $candidateSessionId -and $recordCwd -eq (Get-Location).Path -and -not $isSidechain) {
                    $matchesRootSession = $true
                    break
                }
            } catch { }
        }
        if ($matchesRootSession) { $matchingCandidates += $candidate }
    }
    # Never guess between concurrent same-directory sessions. Claude's native
    # footer remains intact; correction is appended only when attribution is
    # unambiguous (or an explicit resume/session ID selected one transcript).
    if ($matchingCandidates.Count -ne 1) { return }
    $latest = $matchingCandidates[0]
    $sessionId = [IO.Path]::GetFileNameWithoutExtension($latest.Name)
    if ($sessionId -notmatch '^[0-9a-fA-F-]{36}$') { return }
    $resumeCommand = if ($directChrome) { 'claudex --claude-chrome --resume' } else { 'claudex --resume' }
    $footer = "Claudex resume: $resumeCommand $sessionId`n"
    if ($env:CLAUDEX_TEST_RESUME_CAPTURE_FILE) {
        [IO.File]::WriteAllText($env:CLAUDEX_TEST_RESUME_CAPTURE_FILE, $footer, $utf8)
    }
    [Console]::Out.Write($footer)
}

function Invoke-ClaudeProcess([Collections.Generic.List[string]] $Arguments) {
    if ($script:claudeCommand.CommandType -in @('Function', 'Filter', 'Cmdlet')) {
        & $script:claudeInvocation @Arguments
        $script:claudeProcessExitCode = if ($null -ne $LASTEXITCODE) { [int] $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        return
    }
    if ($script:claudeCommand.CommandType -eq 'ExternalScript') {
        & $script:claudeInvocation @Arguments
        $script:claudeProcessExitCode = if ($null -ne $LASTEXITCODE) { [int] $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        return
    }

    $commandPath = [string] $script:claudeCommand.Source
    $extension = [IO.Path]::GetExtension($commandPath).ToLowerInvariant()
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    if ($extension -in @('.cmd', '.bat')) {
        $commandLine = (ConvertTo-CmdArgument $commandPath) + ' ' +
            (@($Arguments | ForEach-Object { ConvertTo-CmdArgument ([string] $_) }) -join ' ')
        $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        # cmd /S removes the first and last quotes around its /C payload. Keep
        # that outer pair literal; ordinary argv quoting produces backslash-
        # escaped quotes that cmd treats as path characters.
        $startInfo.Arguments = '/d /s /v:off /c "' + $commandLine + '"'
    } else {
        $startInfo.FileName = $commandPath
        $startInfo.Arguments = Join-WindowsCommandLine @($Arguments)
    }
    $startInfo.UseShellExecute = $false
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Claude Code could not be started.' }
        $process.WaitForExit()
        $script:claudeProcessExitCode = $process.ExitCode
    } finally { $process.Dispose() }
}

try {
    # Delay the new session-only label until every argument/settings validation
    # step has completed, so a pre-launch error cannot leak it into an existing
    # PowerShell host. The finally block restores its original value.
    if ($useProxy) { Set-ChatGptPlanLabel }
    Set-MousePointer $mousePointer
    $script:claudeProcessExitCode = 1
    Invoke-ClaudeProcess $claudeLaunchArguments
    $exitCode = $script:claudeProcessExitCode
    if ($rewriteResumeFooter) { Update-ResumeFooter $resumeMarker }
} finally {
    if (-not $backgroundLaunch -and $authWatcher -and -not $authWatcher.HasExited) {
        Stop-Process -Id $authWatcher.Id -Force -ErrorAction SilentlyContinue
        $authWatcher.WaitForExit(2000) | Out-Null
    }
    if (-not $backgroundLaunch -and $proxyWatcher -and -not $proxyWatcher.HasExited) {
        Stop-Process -Id $proxyWatcher.Id -Force -ErrorAction SilentlyContinue
        $proxyWatcher.WaitForExit(2000) | Out-Null
    }
    if ($resumeMarker) { Remove-Item -LiteralPath $resumeMarker -Force -ErrorAction SilentlyContinue }
    Set-MousePointer 'default'
    Restore-ClaudexSessionEnvironment
}
exit $exitCode
