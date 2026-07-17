param([switch] $Login)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-AbsoluteInstallDirectory([string] $Value, [string] $VariableName) {
    try {
        $location = Get-Location
        if ($location.Provider.Name -ne 'FileSystem') { throw 'the current PowerShell location is not a filesystem directory' }
        $candidate = if ([IO.Path]::IsPathRooted($Value)) { $Value } else { Join-Path $location.Path $Value }
        return [IO.Path]::GetFullPath($candidate)
    } catch {
        [Console]::Error.WriteLine("install.ps1: $VariableName could not be resolved to an absolute filesystem path: $($_.Exception.Message)")
        exit 1
    }
}

$root = $PSScriptRoot
$proxyVersion = '7.2.80'
$requestedBinDir = if ($env:CLAUDEX_BIN_DIR) { $env:CLAUDEX_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$requestedConfigDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$binDir = Get-AbsoluteInstallDirectory $requestedBinDir 'CLAUDEX_BIN_DIR'
$configDir = Get-AbsoluteInstallDirectory $requestedConfigDir 'CLAUDEX_CONFIG_DIR'
$managedBinDir = Join-Path $configDir 'bin'
$managedNodeDir = Join-Path $configDir 'node'
$managedProxy = Join-Path $managedBinDir "cliproxyapi-$proxyVersion.exe"
$authDir = Join-Path $configDir 'codex-accounts'
$envFile = Join-Path $configDir 'env'
$settingsTarget = Join-Path $configDir 'settings.json'
$statuslineTarget = Join-Path $configDir 'statusline.ps1'
$usageLimitTarget = Join-Path $configDir 'usage-limit.ps1'
$codexSessionTarget = Join-Path $configDir 'codex-session.ps1'
$usageSkillTarget = Join-Path $configDir 'skills\usage-limit\SKILL.md'
$preloadTarget = Join-Path $configDir 'preload.cjs'
$skillBridgeTarget = Join-Path $configDir 'skill-bridge.cjs'
$selfUpdateTarget = Join-Path $configDir 'self-update.ps1'
$installReceiptTarget = Join-Path $configDir 'install.json'
$proxyConfigTarget = Join-Path $configDir 'cliproxyapi.yaml'
$runDir = Join-Path $configDir 'run'
$usageCacheDir = Join-Path $configDir 'usage-cache'
$launcherTarget = Join-Path $binDir 'claudex.ps1'
$cmdTarget = Join-Path $binDir 'claudex.cmd'
$proxyPortText = if ($env:CLAUDEX_PROXY_PORT) { $env:CLAUDEX_PROXY_PORT } else { '8318' }
$skipDependencies = $env:CLAUDEX_SKIP_DEPENDENCY_INSTALL -eq '1'
$allowNodeMigration = -not $skipDependencies -or $env:CLAUDEX_ALLOW_NODE_INSTALL -eq '1'
$skipService = $env:CLAUDEX_SKIP_SERVICE_START -eq '1'
$utf8 = New-Object Text.UTF8Encoding($false)
$callerProxyUrlSet = Test-Path Env:CLAUDEX_PROXY_URL
$callerProxyUrl = [string] $env:CLAUDEX_PROXY_URL
$callerProxyPortSet = Test-Path Env:CLAUDEX_PROXY_PORT
$installLockOwned = $false
$installLockNonce = ''
$codexInstalledBinDir = ''
$claudeInstalledBinDir = ''
$packageManagedInstall = $env:CLAUDEX_PACKAGE_ROOT -or $env:CLAUDEX_INSTALL_METHOD -in @('homebrew', 'scoop', 'winget')
$installTransaction = $null
$userPathBeforeInstall = [Environment]::GetEnvironmentVariable('Path', 'User')
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

function Fail([string] $Message) {
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

function Protect-PrivatePath([string] $Path, [bool] $Directory) {
    if (-not $isWindowsPlatform) { return }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $security.SetOwner($currentSid)
    # A caller may deliberately place CLAUDEX_CONFIG_DIR below a directory with
    # broad inherited access. Do not carry any of those inherited entries into
    # secret state or executable/interpreted files managed by Claudex.
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

function Ensure-PrivateDirectory([string] $Path) {
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    Protect-PrivatePath $Path $true
}

function Test-TransientDownloadFailure($ErrorRecord) {
    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response) {
        try {
            $statusCode = [int] $response.StatusCode
            return $statusCode -in @(408, 425, 429) -or $statusCode -ge 500
        } catch { }
    }
    if ($ErrorRecord.Exception -is [Net.WebException]) {
        return $ErrorRecord.Exception.Status -in @(
            [Net.WebExceptionStatus]::ConnectFailure,
            [Net.WebExceptionStatus]::ConnectionClosed,
            [Net.WebExceptionStatus]::KeepAliveFailure,
            [Net.WebExceptionStatus]::NameResolutionFailure,
            [Net.WebExceptionStatus]::PipelineFailure,
            [Net.WebExceptionStatus]::ProxyNameResolutionFailure,
            [Net.WebExceptionStatus]::ReceiveFailure,
            [Net.WebExceptionStatus]::SendFailure,
            [Net.WebExceptionStatus]::Timeout
        )
    }
    return $null -eq $response
}

function Receive-FileWithRetry([string] $Uri, [string] $Destination, [int] $TimeoutSeconds = 180) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -TimeoutSec $TimeoutSeconds
            Protect-PrivatePath $Destination $false
            return
        } catch {
            $lastError = $_
            if ($attempt -eq 4 -or -not (Test-TransientDownloadFailure $_)) { throw }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
        }
    }
    throw $lastError
}

function Write-TextAtomic([string] $Path, [string] $Value) {
    $parent = Split-Path $Path -Parent
    Ensure-PrivateDirectory $parent
    $temporary = Join-Path $parent ('.' + (Split-Path $Path -Leaf) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $replacementBackup = Join-Path $parent ('.' + (Split-Path $Path -Leaf) + '.' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        [IO.File]::WriteAllText($temporary, $Value, $utf8)
        Protect-PrivatePath $temporary $false
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $replacementBackup)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
        Protect-PrivatePath $Path $false
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-ClaudexEnvValue([string] $Value) {
    $parsed = $Value.Trim()
    if ($parsed.Length -ge 2 -and (($parsed.StartsWith("'") -and $parsed.EndsWith("'")) -or ($parsed.StartsWith('"') -and $parsed.EndsWith('"')))) {
        $parsed = $parsed.Substring(1, $parsed.Length - 2)
    }
    return ($parsed -replace '\\ ', ' ')
}

function ConvertTo-ClaudexEnvLine([string] $Name, [string] $Value) {
    if ($Value.Contains("`r") -or $Value.Contains("`n")) { Fail "$Name contains an unsupported newline" }
    if ((ConvertFrom-ClaudexEnvValue $Value) -cne $Value) {
        Fail "$Name cannot be represented exactly in the cross-platform Claudex environment file"
    }
    return "$Name=$Value"
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

function Add-ProcessPathFirst([string] $Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $separator = [IO.Path]::PathSeparator
    $entries = @($env:PATH -split [regex]::Escape([string] $separator) | Where-Object { $_ -and $_ -ne $Directory })
    $env:PATH = (@($Directory) + $entries) -join $separator
}

function Install-ManagedNode {
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    switch ($architecture) {
        'x64' { $arch = 'x64' }
        'arm64' { $arch = 'arm64' }
        default { Fail "Node.js 18 or newer is unavailable for Windows/$architecture" }
    }
    $temporary = Join-Path $configDir ('.node-install-' + [guid]::NewGuid().ToString('N'))
    Ensure-PrivateDirectory $temporary
    try {
        if ($env:CLAUDEX_TEST_MODE -eq '1' -and $env:CLAUDEX_TEST_MANAGED_NODE_DIR) {
            $source = $env:CLAUDEX_TEST_MANAGED_NODE_DIR
            if (-not (Test-Path -LiteralPath (Join-Path $source 'node.exe') -PathType Leaf) -or
                -not (Test-Path -LiteralPath (Join-Path $source 'npm.cmd') -PathType Leaf)) {
                Fail 'managed Node test fixture is incomplete'
            }
            $extracted = Join-Path $temporary 'node-v22-test-win'
            Copy-Item -LiteralPath $source -Destination $extracted -Recurse
        } else {
            $baseUrl = 'https://nodejs.org/dist/latest-v22.x'
            $checksums = Join-Path $temporary 'SHASUMS256.txt'
            Receive-FileWithRetry "$baseUrl/SHASUMS256.txt" $checksums 180
            $archivePattern = '^([0-9A-Fa-f]{64})\s+(node-v\d+\.\d+\.\d+-win-' + [regex]::Escape($arch) + '\.zip)$'
            $archiveMatches = @([IO.File]::ReadAllLines($checksums) | ForEach-Object {
                if ($_ -match $archivePattern) {
                    [pscustomobject]@{ Digest = $Matches[1].ToLowerInvariant(); Name = $Matches[2] }
                }
            })
            if ($archiveMatches.Count -ne 1) { Fail 'official Node.js checksums did not contain one supported Windows archive' }
            $archiveName = $archiveMatches[0].Name
            $archive = Join-Path $temporary $archiveName
            Receive-FileWithRetry "$baseUrl/$archiveName" $archive 300
            $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -cne $archiveMatches[0].Digest) { Fail 'official Node.js archive checksum mismatch' }
            Expand-Archive -LiteralPath $archive -DestinationPath $temporary
            $extracted = Join-Path $temporary $archiveName.Substring(0, $archiveName.Length - 4)
        }
        if (-not (Test-Path -LiteralPath (Join-Path $extracted 'node.exe') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $extracted 'npm.cmd') -PathType Leaf)) {
            Fail 'official Node.js archive is incomplete'
        }
        $backup = "$managedNodeDir.backup.$PID.$([guid]::NewGuid().ToString('N'))"
        $hadExisting = Test-Path -LiteralPath $managedNodeDir
        if ($hadExisting) { Move-Item -LiteralPath $managedNodeDir -Destination $backup }
        try {
            Move-Item -LiteralPath $extracted -Destination $managedNodeDir
            Protect-PrivatePath $managedNodeDir $true
        } catch {
            if ($hadExisting -and -not (Test-Path -LiteralPath $managedNodeDir)) { Move-Item -LiteralPath $backup -Destination $managedNodeDir }
            throw
        }
        if ($hadExisting) { Remove-Item -LiteralPath $backup -Recurse -Force }
        Add-ProcessPathFirst $managedNodeDir
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Get-NodeMajorVersion) -lt 18 -or -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        Fail 'verified managed Node.js was installed but is not available in PATH'
    }
}

function Invoke-DependencyManager([string] $Executable, [string[]] $Arguments) {
    try {
        & $Executable @Arguments *> $null
        return $LASTEXITCODE -eq 0
    } catch { return $false }
}

function Install-NodeAndNpm {
    $existingMajor = Get-NodeMajorVersion
    if ($existingMajor -gt 0) {
        [Console]::WriteLine("Upgrading Node.js $existingMajor to Node.js 18 or newer for Claudex skill compatibility...")
    } else {
        [Console]::WriteLine('Installing Node.js 18 or newer for Claudex skill compatibility and the official Codex CLI package...')
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    $scoop = Get-Command scoop -ErrorAction SilentlyContinue
    $managerSucceeded = $false
    if ($winget) {
        if ($existingMajor -gt 0) {
            $managerSucceeded = Invoke-DependencyManager $winget.Source @('upgrade', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
            if (-not $managerSucceeded) { $managerSucceeded = Invoke-DependencyManager $winget.Source @('install', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
        } else {
            $managerSucceeded = Invoke-DependencyManager $winget.Source @('install', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        }
    } elseif ($choco) {
        $managerSucceeded = Invoke-DependencyManager $choco.Source @('upgrade', 'nodejs-lts', '-y')
    } elseif ($scoop) {
        if (Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'scoop\apps\nodejs-lts') -PathType Container) {
            $managerSucceeded = Invoke-DependencyManager $scoop.Source @('update', 'nodejs-lts')
        } else {
            $managerSucceeded = Invoke-DependencyManager $scoop.Source @('install', 'nodejs-lts')
        }
    }
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'nodejs'),
        (Join-Path $env:USERPROFILE 'scoop\apps\nodejs-lts\current'),
        (Join-Path $env:USERPROFILE 'scoop\shims')
    )) {
        Add-ProcessPathFirst $candidate
    }
    $installedMajor = Get-NodeMajorVersion
    if (-not $managerSucceeded -or $installedMajor -lt 18 -or -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { Install-ManagedNode }
}

function Install-CodexCli {
    if ((Get-NodeMajorVersion) -lt 18 -or -not (Get-Command npm -ErrorAction SilentlyContinue)) { Install-NodeAndNpm }
    # Prefer the native command shim. npm.ps1 reconstructs its arguments with
    # Invoke-Expression and can re-evaluate scope-qualified variables under
    # StrictMode instead of receiving their value.
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if ((Get-NodeMajorVersion) -lt 18 -or -not $npm) {
        Fail 'Node.js 18 or newer or npm was installed but is not available in PATH; open a new terminal and rerun the installer'
    }
    [Console]::WriteLine('Installing Codex CLI from the official @openai/codex npm package...')
    $installPrefix = Join-Path $env:USERPROFILE '.local\bin'
    $script:codexInstalledBinDir = $installPrefix
    [IO.Directory]::CreateDirectory($installPrefix) | Out-Null
    & $npm.Source install --global --prefix $installPrefix '@openai/codex'
    if ($LASTEXITCODE -ne 0) { Fail "Codex CLI installation failed with exit code $LASTEXITCODE" }
    if ($script:codexInstalledBinDir -notin @($env:PATH -split [regex]::Escape([string] [IO.Path]::PathSeparator))) {
        $env:PATH = "$($script:codexInstalledBinDir)$([IO.Path]::PathSeparator)$env:PATH"
    }
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Fail "Codex CLI was installed but 'codex' was not found in $($script:codexInstalledBinDir)" }
}

function Read-InstallLockOwner([string] $LockPath) {
    $ownerPath = Join-Path $LockPath 'owner.json'
    try { return Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json } catch { return $null }
}

function Acquire-InstallLock {
    $lockPath = Join-Path $configDir 'run\install.lock'
    Ensure-PrivateDirectory (Split-Path $lockPath -Parent)
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            [IO.Directory]::CreateDirectory($lockPath) | Out-Null
            Protect-PrivatePath $lockPath $true
            # CreateDirectory succeeds for an existing directory, so ownership is
            # acquired only when owner.json can be created atomically.
            $ownerPath = Join-Path $lockPath 'owner.json'
            $stream = New-Object IO.FileStream($ownerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $script:installLockNonce = [guid]::NewGuid().ToString('N')
                $bytes = $utf8.GetBytes((@{ pid = $PID; nonce = $script:installLockNonce; startedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress) + "`n")
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
            Protect-PrivatePath $ownerPath $false
            $script:installLockOwned = $true
            return
        } catch [IO.IOException] { }

        $owner = Read-InstallLockOwner $lockPath
        $age = try { [DateTime]::UtcNow - (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc } catch { [TimeSpan]::Zero }
        $alive = $false
        if ($owner -and [int] $owner.pid -gt 0) { $alive = $null -ne (Get-Process -Id ([int] $owner.pid) -ErrorAction SilentlyContinue) }
        if ($age.TotalSeconds -ge 2 -and -not $alive) {
            $quarantine = "$lockPath.stale.$PID.$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
            try { Move-Item -LiteralPath $lockPath -Destination $quarantine -ErrorAction Stop; Remove-Item -LiteralPath $quarantine -Recurse -Force; continue } catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    Fail 'timed out waiting for another Claudex installation; retry after it finishes'
}

function Release-InstallLock {
    if (-not $script:installLockOwned) { return }
    $lockPath = Join-Path $configDir 'run\install.lock'
    $owner = Read-InstallLockOwner $lockPath
    if ($owner -and [string] $owner.nonce -eq $script:installLockNonce -and [int] $owner.pid -eq $PID) {
        Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:installLockOwned = $false
}

function Start-InstallTransaction([string[]] $ManagedPaths) {
    foreach ($managedPath in $ManagedPaths) {
        if ((Test-Path -LiteralPath $managedPath) -and -not (Test-Path -LiteralPath $managedPath -PathType Leaf)) {
            Fail "managed install target is not a regular file: $managedPath"
        }
    }
    $rootPath = Join-Path $configDir ('.install-transaction-' + [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $rootPath 'backup'
    Ensure-PrivateDirectory $rootPath
    Ensure-PrivateDirectory $backupPath
    $entries = @()
    $index = 0
    $hasFiles = $false
    try {
        foreach ($managedPath in $ManagedPaths) {
            $existed = Test-Path -LiteralPath $managedPath -PathType Leaf
            $backup = Join-Path $backupPath ([string] $index)
            if ($existed) {
                Copy-Item -LiteralPath $managedPath -Destination $backup -Force
                Protect-PrivatePath $backup $false
                $hasFiles = $true
            }
            $entries += [pscustomobject]@{ Path = $managedPath; Backup = $backup; Existed = $existed }
            $index++
        }
    } catch {
        Remove-Item -LiteralPath $rootPath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-TextAtomic (Join-Path $rootPath 'manifest.json') (($entries | ConvertTo-Json -Depth 5) + "`n")
    Write-TextAtomic (Join-Path $rootPath 'state') "committing`n"
    $script:installTransaction = [pscustomobject]@{ Root = $rootPath; Entries = $entries; HasFiles = $hasFiles }
}

function Restore-InstallTransactionEntries([string] $RootPath, $Entries, [string[]] $ManagedPaths) {
    $restoreErrors = @()
    if (@($Entries).Count -ne $ManagedPaths.Count) { return @('transaction manifest target count is invalid') }
    for ($index = 0; $index -lt $ManagedPaths.Count; $index++) {
        $entry = @($Entries)[$index]
        $expectedPath = [IO.Path]::GetFullPath($ManagedPaths[$index])
        $recordedPath = [IO.Path]::GetFullPath([string] $entry.Path)
        if (-not $recordedPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $restoreErrors += "transaction manifest contains an unexpected target: $recordedPath"
            continue
        }
        try {
            if ($entry.Existed) {
                $bytes = [IO.File]::ReadAllBytes($entry.Backup)
                $parent = Split-Path $entry.Path -Parent
                [IO.Directory]::CreateDirectory($parent) | Out-Null
                $temporary = Join-Path $parent ('.rollback-' + [guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.File]::WriteAllBytes($temporary, $bytes)
                    Protect-PrivatePath $temporary $false
                    if (Test-Path -LiteralPath $entry.Path -PathType Leaf) {
                        $replacementBackup = Join-Path $parent ('.rollback-' + [guid]::NewGuid().ToString('N') + '.bak')
                        try { [IO.File]::Replace($temporary, $entry.Path, $replacementBackup) }
                        finally { Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue }
                    } else {
                        [IO.File]::Move($temporary, $entry.Path)
                    }
                    Protect-PrivatePath $entry.Path $false
                } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            } else {
                Remove-Item -LiteralPath $entry.Path -Force -ErrorAction SilentlyContinue
            }
        } catch { $restoreErrors += $_.Exception.Message }
    }
    if ($restoreErrors.Count -eq 0) { Remove-Item -LiteralPath $RootPath -Recurse -Force -ErrorAction SilentlyContinue }
    return $restoreErrors
}

function Restore-InstallTransaction([string[]] $ManagedPaths) {
    if ($null -eq $script:installTransaction) { return }
    $restoreErrors = @(Restore-InstallTransactionEntries $script:installTransaction.Root $script:installTransaction.Entries $ManagedPaths)
    $script:installTransaction = $null
    if ($restoreErrors.Count -gt 0) {
        [Console]::Error.WriteLine("install.ps1: installation failed and automatic rollback was incomplete: $($restoreErrors -join '; ')")
    } else {
        [Console]::Error.WriteLine('install.ps1: installation failed; restored the previous managed installation.')
    }
}

function Recover-IncompleteInstallTransactions([string[]] $ManagedPaths) {
    $recovered = $false
    foreach ($directory in @(Get-ChildItem -LiteralPath $configDir -Directory -Filter '.install-transaction-*' -ErrorAction SilentlyContinue)) {
        Protect-PrivatePath $directory.FullName $true
        $statePath = Join-Path $directory.FullName 'state'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }
        $state = ([IO.File]::ReadAllText($statePath)).Trim()
        if ($state -ne 'committing') { Fail "unrecognized interrupted installer transaction: $($directory.FullName)" }
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        try {
            # Windows PowerShell 5 can emit a top-level JSON array as one
            # non-enumerated pipeline object. Flatten it explicitly so a valid
            # transaction is not miscounted as a single manifest entry.
            $parsedEntries = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $entries = @()
            foreach ($entry in $parsedEntries) { $entries += $entry }
        }
        catch { Fail "invalid interrupted installer transaction manifest: $manifestPath" }
        $restoreErrors = @(Restore-InstallTransactionEntries $directory.FullName $entries $ManagedPaths)
        if ($restoreErrors.Count -gt 0) { Fail "could not recover interrupted installer transaction: $($restoreErrors -join '; ')" }
        $recovered = $true
    }
    if ($recovered) { [Console]::WriteLine('Recovered the previous interrupted Claudex installation before continuing.') }
}

function Complete-InstallTransaction {
    if ($null -eq $script:installTransaction) { return }
    $transaction = $script:installTransaction
    if ($transaction.HasFiles) {
        $backupDir = Join-Path $configDir ("backups\install-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
        Ensure-PrivateDirectory (Split-Path $backupDir -Parent)
        Move-Item -LiteralPath $transaction.Root -Destination $backupDir
        Protect-PrivatePath $backupDir $true
        [Console]::WriteLine("Backed up the previous managed files to $backupDir")
    } else {
        Remove-Item -LiteralPath $transaction.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:installTransaction = $null
}

function Test-InteractiveInstall {
    return $env:CLAUDEX_TEST_INTERACTIVE_INSTALL -eq '1' -or
        ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
}

$proxyPort = 0
if (-not [int]::TryParse($proxyPortText, [ref] $proxyPort) -or $proxyPort -lt 1 -or $proxyPort -gt 65535) {
    Fail 'CLAUDEX_PROXY_PORT must be an integer from 1 to 65535'
}

foreach ($sourceFile in @('claudex.ps1', 'claudex.cmd', 'codex-session.ps1', 'statusline.ps1', 'usage-limit.ps1', 'preload.cjs', 'skill-bridge.cjs', 'self-update.ps1', 'package.json', 'settings.json', 'skills\usage-limit\SKILL.md', 'skills\usage-limit\SKILL.windows.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $sourceFile) -PathType Leaf)) { Fail "missing repository file: $sourceFile" }
}

function Get-ProxyVersion([string] $Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try { return [string] ((& $Path -version 2>&1 | Select-Object -First 1)) } catch { return '' }
}

function Find-ProxyExecutable {
    if (Test-Path -LiteralPath $managedProxy -PathType Leaf) { return $managedProxy }
    foreach ($name in @('cliproxyapi.exe', 'cli-proxy-api.exe', 'cliproxyapi', 'cli-proxy-api')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

function Install-Proxy {
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    switch ($architecture) {
        'x64' { $arch = 'amd64'; $expected = 'a8e1a805bae83150d2e1c7e25b4c22714461d4536173f0bd93be8bbc1333be4c' }
        'arm64' { $arch = 'aarch64'; $expected = '01085cef19e880d8897a79f762a224735e768a11bda4a6a2f988db752b89777e' }
        default { Fail "unsupported Windows CPU architecture: $architecture" }
    }
    $asset = "CLIProxyAPI_${proxyVersion}_windows_${arch}.zip"
    $url = "https://github.com/router-for-me/CLIProxyAPI/releases/download/v${proxyVersion}/$asset"
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('claudex-proxy-' + [guid]::NewGuid().ToString('N'))
    Ensure-PrivateDirectory $temporary
    try {
        $archive = Join-Path $temporary $asset
        [Console]::WriteLine("Downloading verified internal compatibility service v$proxyVersion for Windows/$arch...")
        Receive-FileWithRetry $url $archive 300
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { Fail "compatibility service checksum mismatch for $asset" }
        Expand-Archive -LiteralPath $archive -DestinationPath $temporary -Force
        Copy-Item -LiteralPath (Join-Path $temporary 'cli-proxy-api.exe') -Destination $managedProxy -Force
        Protect-PrivatePath $managedProxy $false
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

if ($packageManagedInstall) {
    # Scoop/WinGet/Homebrew own their shim or package directories. Keep that
    # directory policy intact so their atomic upgrade/link management continues
    # to work; the installed Claudex files still receive explicit file ACLs.
    [IO.Directory]::CreateDirectory($binDir) | Out-Null
} else {
    # A file ACL alone cannot defend a launcher when a broadly writable parent
    # grants DeleteChild. Direct, git, and archive installs own their bin
    # directory, so make the directory private before publishing launchers.
    try { Ensure-PrivateDirectory $binDir }
    catch {
        Fail "direct/archive installs require a private launcher directory; could not protect ${binDir}: $($_.Exception.Message)"
    }
}
Ensure-PrivateDirectory $configDir
Ensure-PrivateDirectory $managedBinDir
Ensure-PrivateDirectory $authDir
# The launcher writes transient bearer headers below run\health-* and the usage
# helper writes them below usage-cache. Protect their inherited ACLs before any
# process can create the short-lived credential-bearing files.
Ensure-PrivateDirectory $runDir
Ensure-PrivateDirectory $usageCacheDir
if (Test-Path -LiteralPath $managedNodeDir -PathType Container) { Protect-PrivatePath $managedNodeDir $true }
if (Test-Path -LiteralPath $managedProxy -PathType Leaf) { Protect-PrivatePath $managedProxy $false }
if (Test-Path -LiteralPath (Join-Path $managedNodeDir 'node.exe') -PathType Leaf) {
    $env:PATH = "$managedNodeDir$([IO.Path]::PathSeparator)$env:PATH"
}
$separator = [IO.Path]::PathSeparator
if ($binDir -notin @($env:PATH -split [regex]::Escape([string] $separator))) { $env:PATH = "$binDir$separator$env:PATH" }

$installManagedPaths = @(
    $launcherTarget,
    $cmdTarget,
    $envFile,
    $proxyConfigTarget,
    $managedProxy,
    $settingsTarget,
    $statuslineTarget,
    $usageLimitTarget,
    $codexSessionTarget,
    $preloadTarget,
    $skillBridgeTarget,
    $selfUpdateTarget,
    $usageSkillTarget,
    $installReceiptTarget
)
# Repair ACLs from older installs before copying or reading any managed state.
# This matters when a custom config directory was originally created beneath a
# parent that granted broad inherited access.
foreach ($existingPrivateManagedPath in $installManagedPaths) {
    if (Test-Path -LiteralPath $existingPrivateManagedPath -PathType Leaf) {
        Protect-PrivatePath $existingPrivateManagedPath $false
    }
}
Acquire-InstallLock
try {
Recover-IncompleteInstallTransactions $installManagedPaths
Start-InstallTransaction $installManagedPaths

if (-not $skipDependencies) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Install-CodexCli }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        [Console]::WriteLine("Installing Claude Code with Anthropic's native installer...")
        $installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('claudex-claude-install-' + [guid]::NewGuid().ToString('N'))
        Ensure-PrivateDirectory $installerDirectory
        $installer = Join-Path $installerDirectory 'install.ps1'
        try {
            Receive-FileWithRetry 'https://claude.ai/install.ps1' $installer 180
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
            if ($LASTEXITCODE -ne 0) { Fail "Claude Code's native installer failed with exit code $LASTEXITCODE" }
        } finally { Remove-Item -LiteralPath $installerDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        $claudeInstalledBinDir = Join-Path $env:USERPROFILE '.local\bin'
        if ((Test-Path -LiteralPath $claudeInstalledBinDir -PathType Container) -and
            $claudeInstalledBinDir -notin @($env:PATH -split [regex]::Escape([string] $separator))) {
            $env:PATH = "$claudeInstalledBinDir$separator$env:PATH"
        }
    }
    if ((Get-ProxyVersion $managedProxy) -notlike "*Version: $proxyVersion*") { Install-Proxy }
}

$nodeMajor = Get-NodeMajorVersion
if ($nodeMajor -lt 18 -and $allowNodeMigration) { Install-NodeAndNpm; $nodeMajor = Get-NodeMajorVersion }
if ($nodeMajor -lt 18) {
    $detected = if ($nodeMajor -gt 0) { "found Node.js $nodeMajor" } else { 'Node.js was not found' }
    Fail "Node.js 18 or newer is required for Claude and Codex skill compatibility ($detected); rerun the installer with dependency installation enabled"
}

$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
$claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
$proxyBinary = Find-ProxyExecutable
if (-not $codexCommand) { Fail "'codex' is required but was not found in PATH" }
if (-not $claudeCommand) { Fail "'claude' is required but was not found in PATH" }
if (-not $proxyBinary) { Fail 'the internal compatibility service could not be installed' }

if (-not $skipDependencies -and $env:CLAUDEX_SKIP_CLAUDE_UPDATE -ne '1') {
    [Console]::WriteLine('Checking Claude Code for the latest compatible release...')
    $savedErrorPreference = $ErrorActionPreference
    $updateExitCode = 1
    try {
        # Windows PowerShell 5 promotes redirected native stderr to a
        # NativeCommandError under Stop. Capture the real exit code and keep
        # the documented best-effort update behavior.
        $ErrorActionPreference = 'Continue'
        & $claudeCommand.Source update *> (Join-Path $configDir 'claude-update-install.log')
        if (Test-Path -LiteralPath (Join-Path $configDir 'claude-update-install.log') -PathType Leaf) {
            Protect-PrivatePath (Join-Path $configDir 'claude-update-install.log') $false
        }
        $updateExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    if ($updateExitCode -eq 0) {
        $updateDir = Join-Path $configDir 'update'
        Ensure-PrivateDirectory $updateDir
        [IO.File]::WriteAllText((Join-Path $updateDir 'last-success'), ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString() + "`n"), $utf8)
        Protect-PrivatePath (Join-Path $updateDir 'last-success') $false
    } else { [Console]::Error.WriteLine('install.ps1: Claude Code update check failed; continuing with the installed version.') }
}

$existingVariables = [ordered]@{}
$existingLines = @()
if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($envFile)) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            $value = ConvertFrom-ClaudexEnvValue $Matches[2]
            $existingVariables[$name] = $value
        }
        if ($line -notmatch '^(CLAUDEX_PROXY_TOKEN|CLAUDEX_PROXY_URL|CLAUDEX_PROXY_CONFIG|CLAUDEX_PROXY_BIN|CLAUDEX_CODEX_AUTH_DIR)=') { $existingLines += $line }
    }
}
$proxyToken = if ($env:CLAUDEX_PROXY_TOKEN) { $env:CLAUDEX_PROXY_TOKEN } elseif ($existingVariables['CLAUDEX_PROXY_TOKEN']) { $existingVariables['CLAUDEX_PROXY_TOKEN'] } else { '' }
if (-not $proxyToken) {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    $proxyToken = -join ($bytes | ForEach-Object { $_.ToString('x2') })
}
if ($proxyToken.Contains("`r") -or $proxyToken.Contains("`n")) { Fail 'local compatibility key contains a newline' }

$jsonToken = $proxyToken | ConvertTo-Json -Compress
$runtimeAuthDir = if ($env:CLAUDEX_CODEX_AUTH_DIR) { $env:CLAUDEX_CODEX_AUTH_DIR } elseif ($existingVariables['CLAUDEX_CODEX_AUTH_DIR']) { $existingVariables['CLAUDEX_CODEX_AUTH_DIR'] } else { $authDir }
Ensure-PrivateDirectory $runtimeAuthDir
$authPath = $runtimeAuthDir.Replace('\', '/')
$proxyConfig = @"
host: "127.0.0.1"
port: $proxyPort
auth-dir: "$authPath"
api-keys:
  - $jsonToken
debug: false
logging-to-file: false
logs-max-total-size-mb: 100
usage-statistics-enabled: false
request-retry: 3
max-retry-credentials: 1
max-retry-interval: 5
transient-error-cooldown-seconds: 1
streaming:
  keepalive-seconds: 15
  bootstrap-retries: 2
"@
Write-TextAtomic $proxyConfigTarget $proxyConfig
$managedProxyForEnv = if (Test-Path -LiteralPath $managedProxy -PathType Leaf) { $managedProxy } else { $proxyBinary }
$existingProxyUrl = [string] $existingVariables['CLAUDEX_PROXY_URL']
$runtimeProxyUrl = if ($callerProxyUrlSet) {
    if ($callerProxyUrl) { $callerProxyUrl } else { "http://127.0.0.1:$proxyPort" }
} elseif ($callerProxyPortSet -and (-not $existingProxyUrl -or $existingProxyUrl -match '^http://127\.0\.0\.1:\d+/?$')) {
    "http://127.0.0.1:$proxyPort"
} elseif ($existingProxyUrl) { $existingProxyUrl } else { "http://127.0.0.1:$proxyPort" }
$runtimeProxyConfig = if ($env:CLAUDEX_PROXY_CONFIG) { $env:CLAUDEX_PROXY_CONFIG } elseif ($existingVariables['CLAUDEX_PROXY_CONFIG']) { $existingVariables['CLAUDEX_PROXY_CONFIG'] } else { $proxyConfigTarget }
$existingProxyBin = [string] $existingVariables['CLAUDEX_PROXY_BIN']
$existingProxyBinLeaf = if ($existingProxyBin) { Split-Path $existingProxyBin -Leaf } else { '' }
$existingProxyBinParent = if ($existingProxyBin) { Split-Path $existingProxyBin -Parent } else { '' }
$previousManagedProxy = $existingProxyBin -and
    ([IO.Path]::GetFullPath($existingProxyBinParent) -eq [IO.Path]::GetFullPath($managedBinDir)) -and
    ($existingProxyBinLeaf -eq 'cliproxyapi.exe' -or $existingProxyBinLeaf -match '^cliproxyapi-\d+\.\d+\.\d+\.exe$')
$runtimeProxyBin = if ($env:CLAUDEX_PROXY_BIN) { $env:CLAUDEX_PROXY_BIN } elseif ($existingProxyBin -and -not $previousManagedProxy) { $existingProxyBin } else { $managedProxyForEnv }
$managedLines = @(
    (ConvertTo-ClaudexEnvLine 'CLAUDEX_PROXY_TOKEN' $proxyToken),
    (ConvertTo-ClaudexEnvLine 'CLAUDEX_PROXY_URL' $runtimeProxyUrl),
    (ConvertTo-ClaudexEnvLine 'CLAUDEX_PROXY_CONFIG' $runtimeProxyConfig),
    (ConvertTo-ClaudexEnvLine 'CLAUDEX_PROXY_BIN' $runtimeProxyBin),
    (ConvertTo-ClaudexEnvLine 'CLAUDEX_CODEX_AUTH_DIR' $runtimeAuthDir)
)
$environmentText = (@($managedLines + $existingLines) -join [Environment]::NewLine) + [Environment]::NewLine
Write-TextAtomic $envFile $environmentText

Copy-Item -LiteralPath (Join-Path $root 'claudex.ps1') -Destination $launcherTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'claudex.cmd') -Destination $cmdTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'statusline.ps1') -Destination $statuslineTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'usage-limit.ps1') -Destination $usageLimitTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'codex-session.ps1') -Destination $codexSessionTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'preload.cjs') -Destination $preloadTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'skill-bridge.cjs') -Destination $skillBridgeTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'self-update.ps1') -Destination $selfUpdateTarget -Force
Ensure-PrivateDirectory (Split-Path $usageSkillTarget -Parent)
Copy-Item -LiteralPath (Join-Path $root 'skills\usage-limit\SKILL.windows.md') -Destination $usageSkillTarget -Force

foreach ($privateInstalledFile in @(
    $launcherTarget,
    $cmdTarget,
    $statuslineTarget,
    $usageLimitTarget,
    $codexSessionTarget,
    $preloadTarget,
    $skillBridgeTarget,
    $selfUpdateTarget,
    $usageSkillTarget
)) {
    Protect-PrivatePath $privateInstalledFile $false
}

$settings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
$settings.statusLine.command = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $statuslineTarget + '"'
Write-TextAtomic $settingsTarget ($settings | ConvertTo-Json -Depth 100)

$packageManifest = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
$installVersion = [string] $packageManifest.version
if ($installVersion -notmatch '^\d+\.\d+\.\d+$') { Fail 'package.json contains an invalid Claudex version' }
$installMethod = if ($env:CLAUDEX_INSTALL_METHOD) { $env:CLAUDEX_INSTALL_METHOD } elseif (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container) { 'git' } else { 'archive' }
if ($installMethod -notin @('homebrew', 'scoop', 'winget', 'archive', 'git')) { Fail "unsupported CLAUDEX_INSTALL_METHOD: $installMethod" }
$receipt = [ordered]@{ schema = 1; version = $installVersion; method = $installMethod; binDir = $binDir; repository = 'BeamoINT/Claudex' }
Write-TextAtomic $installReceiptTarget (($receipt | ConvertTo-Json -Compress) + "`n")

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$userEntries = if ($userPath) { @($userPath -split [regex]::Escape([string] $separator)) } else { @() }
foreach ($pathToAdd in @(
    $codexInstalledBinDir,
    $claudeInstalledBinDir,
    $(if (Test-Path -LiteralPath (Join-Path $managedNodeDir 'node.exe') -PathType Leaf) { $managedNodeDir } else { '' }),
    $(if (-not $packageManagedInstall) { $binDir } else { '' })
) | Where-Object { $_ }) {
    if ($pathToAdd -notin $userEntries) {
        $userPath = if ($userPath) { "$pathToAdd$separator$userPath" } else { $pathToAdd }
        $userEntries += $pathToAdd
        [Console]::WriteLine("Added to your user PATH: $pathToAdd")
    }
}
[Environment]::SetEnvironmentVariable('Path', $userPath, 'User')

[Console]::WriteLine("Installed Claudex launcher: $cmdTarget")
[Console]::WriteLine("Installed isolated config: $configDir")

$authReady = $false
if ($Login) {
    & $codexSessionTarget login
    if ($LASTEXITCODE -ne 0) { Fail "Codex login failed with exit code $LASTEXITCODE" }
    $authReady = $true
} else {
    & $codexSessionTarget sync *> $null
    $authReady = $LASTEXITCODE -eq 0
}
if (-not $authReady -and -not $skipDependencies -and (Test-InteractiveInstall)) {
    [Console]::WriteLine('Codex sign-in is required. Opening the official browser login now...')
    & $codexSessionTarget login
    $authReady = $LASTEXITCODE -eq 0
    if (-not $authReady) { [Console]::Error.WriteLine("Claudex is installed, but Codex sign-in did not finish. Run 'claudex --login' to retry.") }
} elseif (-not $authReady) { [Console]::Error.WriteLine("Claudex is installed. Sign in with 'claudex --login', then run 'claudex'.") }
if (-not $skipService -and $authReady) {
    & $launcherTarget --doctor
    if ($LASTEXITCODE -eq 0) { [Console]::WriteLine('Claudex is ready. Run: claudex') }
    else { Fail 'the live compatibility check did not pass; run `claudex --doctor` for details' }
}
Complete-InstallTransaction
} finally {
    if ($null -ne $script:installTransaction) {
        Restore-InstallTransaction $installManagedPaths
        [Environment]::SetEnvironmentVariable('Path', $userPathBeforeInstall, 'User')
    }
    Release-InstallLock
}
