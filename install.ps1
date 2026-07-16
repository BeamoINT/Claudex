param([switch] $Login)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = $PSScriptRoot
$proxyVersion = '7.2.80'
$binDir = if ($env:CLAUDEX_BIN_DIR) { $env:CLAUDEX_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$managedBinDir = Join-Path $configDir 'bin'
$managedProxy = Join-Path $managedBinDir "cliproxyapi-$proxyVersion.exe"
$authDir = Join-Path $configDir 'codex-accounts'
$envFile = Join-Path $configDir 'env'
$settingsTarget = Join-Path $configDir 'settings.json'
$statuslineTarget = Join-Path $configDir 'statusline.ps1'
$usageLimitTarget = Join-Path $configDir 'usage-limit.ps1'
$codexSessionTarget = Join-Path $configDir 'codex-session.ps1'
$usageSkillTarget = Join-Path $configDir 'skills\usage-limit\SKILL.md'
$preloadTarget = Join-Path $configDir 'preload.cjs'
$selfUpdateTarget = Join-Path $configDir 'self-update.ps1'
$installReceiptTarget = Join-Path $configDir 'install.json'
$proxyConfigTarget = Join-Path $configDir 'cliproxyapi.yaml'
$launcherTarget = Join-Path $binDir 'claudex.ps1'
$cmdTarget = Join-Path $binDir 'claudex.cmd'
$proxyPortText = if ($env:CLAUDEX_PROXY_PORT) { $env:CLAUDEX_PROXY_PORT } else { '8318' }
$skipDependencies = $env:CLAUDEX_SKIP_DEPENDENCY_INSTALL -eq '1'
$skipService = $env:CLAUDEX_SKIP_SERVICE_START -eq '1'
$utf8 = New-Object Text.UTF8Encoding($false)
$callerProxyUrlSet = Test-Path Env:CLAUDEX_PROXY_URL
$callerProxyUrl = [string] $env:CLAUDEX_PROXY_URL
$callerProxyPortSet = Test-Path Env:CLAUDEX_PROXY_PORT
$installLockOwned = $false
$installLockNonce = ''
$codexInstalledBinDir = ''
$claudeInstalledBinDir = ''
$packageManagedInstall = $env:CLAUDEX_PACKAGE_ROOT -or $env:CLAUDEX_INSTALL_METHOD -in @('npm', 'homebrew', 'scoop', 'winget')

function Fail([string] $Message) {
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

function Install-NodeAndNpm {
    [Console]::WriteLine('Installing Node.js and npm for the official Codex CLI package...')
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    $scoop = Get-Command scoop -ErrorAction SilentlyContinue
    if ($winget) {
        & $winget.Source install --id OpenJS.NodeJS.LTS --exact --accept-package-agreements --accept-source-agreements
    } elseif ($choco) {
        & $choco.Source install nodejs-lts -y
    } elseif ($scoop) {
        & $scoop.Source install nodejs-lts
    } else { Fail 'Node.js and npm are required to install Codex CLI; install Node.js LTS or enable WinGet, Chocolatey, or Scoop, then retry' }
    if ($LASTEXITCODE -ne 0) { Fail "Node.js installation failed with exit code $LASTEXITCODE" }
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'nodejs'),
        (Join-Path $env:USERPROFILE 'scoop\apps\nodejs-lts\current'),
        (Join-Path $env:USERPROFILE 'scoop\shims')
    )) {
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and $candidate -notin @($env:PATH -split [regex]::Escape([string] [IO.Path]::PathSeparator))) {
            $env:PATH = "$candidate$([IO.Path]::PathSeparator)$env:PATH"
        }
    }
}

function Install-CodexCli {
    if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not (Get-Command npm -ErrorAction SilentlyContinue)) { Install-NodeAndNpm }
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not $npm) {
        Fail 'Node.js or npm was installed but is not available in PATH; open a new terminal and rerun the installer'
    }
    [Console]::WriteLine('Installing Codex CLI from the official @openai/codex npm package...')
    $script:codexInstalledBinDir = Join-Path $env:USERPROFILE '.local\bin'
    [IO.Directory]::CreateDirectory($script:codexInstalledBinDir) | Out-Null
    & $npm.Source install --global --prefix $script:codexInstalledBinDir '@openai/codex'
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
    [IO.Directory]::CreateDirectory((Split-Path $lockPath -Parent)) | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            [IO.Directory]::CreateDirectory($lockPath) | Out-Null
            # CreateDirectory succeeds for an existing directory, so ownership is
            # acquired only when owner.json can be created atomically.
            $ownerPath = Join-Path $lockPath 'owner.json'
            $stream = New-Object IO.FileStream($ownerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $script:installLockNonce = [guid]::NewGuid().ToString('N')
                $bytes = $utf8.GetBytes((@{ pid = $PID; nonce = $script:installLockNonce; startedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress) + "`n")
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
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

function Test-InteractiveInstall {
    return $env:CLAUDEX_TEST_INTERACTIVE_INSTALL -eq '1' -or
        ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
}

$proxyPort = 0
if (-not [int]::TryParse($proxyPortText, [ref] $proxyPort) -or $proxyPort -lt 1 -or $proxyPort -gt 65535) {
    Fail 'CLAUDEX_PROXY_PORT must be an integer from 1 to 65535'
}

foreach ($sourceFile in @('claudex.ps1', 'claudex.cmd', 'codex-session.ps1', 'statusline.ps1', 'usage-limit.ps1', 'preload.cjs', 'self-update.ps1', 'package.json', 'settings.json', 'skills\usage-limit\SKILL.md')) {
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
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    try {
        $archive = Join-Path $temporary $asset
        [Console]::WriteLine("Downloading verified internal compatibility service v$proxyVersion for Windows/$arch...")
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { Fail "compatibility service checksum mismatch for $asset" }
        Expand-Archive -LiteralPath $archive -DestinationPath $temporary -Force
        Copy-Item -LiteralPath (Join-Path $temporary 'cli-proxy-api.exe') -Destination $managedProxy -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

[IO.Directory]::CreateDirectory($binDir) | Out-Null
[IO.Directory]::CreateDirectory($configDir) | Out-Null
[IO.Directory]::CreateDirectory($managedBinDir) | Out-Null
[IO.Directory]::CreateDirectory($authDir) | Out-Null
$separator = [IO.Path]::PathSeparator
if ($binDir -notin @($env:PATH -split [regex]::Escape([string] $separator))) { $env:PATH = "$binDir$separator$env:PATH" }

Acquire-InstallLock
try {

if (-not $skipDependencies) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Install-CodexCli }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        [Console]::WriteLine("Installing Claude Code with Anthropic's native installer...")
        $installer = Join-Path ([IO.Path]::GetTempPath()) ('claude-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://claude.ai/install.ps1' -OutFile $installer
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
            if ($LASTEXITCODE -ne 0) { Fail "Claude Code's native installer failed with exit code $LASTEXITCODE" }
        } finally { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
        $claudeInstalledBinDir = Join-Path $env:USERPROFILE '.local\bin'
        if ((Test-Path -LiteralPath $claudeInstalledBinDir -PathType Container) -and
            $claudeInstalledBinDir -notin @($env:PATH -split [regex]::Escape([string] $separator))) {
            $env:PATH = "$claudeInstalledBinDir$separator$env:PATH"
        }
    }
    if ((Get-ProxyVersion $managedProxy) -notlike "*Version: $proxyVersion*") { Install-Proxy }
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
        $updateExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    if ($updateExitCode -eq 0) {
        $updateDir = Join-Path $configDir 'update'
        [IO.Directory]::CreateDirectory($updateDir) | Out-Null
        [IO.File]::WriteAllText((Join-Path $updateDir 'last-success'), ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString() + "`n"), $utf8)
    } else { [Console]::Error.WriteLine('install.ps1: Claude Code update check failed; continuing with the installed version.') }
}

$existingVariables = [ordered]@{}
$existingLines = @()
if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($envFile)) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"')))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $value = $value -replace '\\ ', ' '
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
[IO.Directory]::CreateDirectory($runtimeAuthDir) | Out-Null
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
[IO.File]::WriteAllText($proxyConfigTarget, $proxyConfig, $utf8)
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
    "CLAUDEX_PROXY_TOKEN=$proxyToken",
    "CLAUDEX_PROXY_URL=$runtimeProxyUrl",
    "CLAUDEX_PROXY_CONFIG=$runtimeProxyConfig",
    "CLAUDEX_PROXY_BIN=$runtimeProxyBin",
    "CLAUDEX_CODEX_AUTH_DIR=$runtimeAuthDir"
)
[IO.File]::WriteAllLines($envFile, @($managedLines + $existingLines), $utf8)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $configDir "backups\install-$timestamp"
$backedUp = $false
foreach ($managedFile in @($launcherTarget, $cmdTarget, $settingsTarget, $statuslineTarget, $usageLimitTarget, $codexSessionTarget, $preloadTarget, $selfUpdateTarget, $usageSkillTarget, $installReceiptTarget)) {
    if (Test-Path -LiteralPath $managedFile) {
        [IO.Directory]::CreateDirectory($backupDir) | Out-Null
        Copy-Item -LiteralPath $managedFile -Destination (Join-Path $backupDir (Split-Path $managedFile -Leaf)) -Force
        $backedUp = $true
    }
}
if ($backedUp) { [Console]::WriteLine("Backed up the previous managed files to $backupDir") }

Copy-Item -LiteralPath (Join-Path $root 'claudex.ps1') -Destination $launcherTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'claudex.cmd') -Destination $cmdTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'statusline.ps1') -Destination $statuslineTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'usage-limit.ps1') -Destination $usageLimitTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'codex-session.ps1') -Destination $codexSessionTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'preload.cjs') -Destination $preloadTarget -Force
Copy-Item -LiteralPath (Join-Path $root 'self-update.ps1') -Destination $selfUpdateTarget -Force
[IO.Directory]::CreateDirectory((Split-Path $usageSkillTarget -Parent)) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'skills\usage-limit\SKILL.md') -Destination $usageSkillTarget -Force

$settings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
$settings.statusLine.command = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $statuslineTarget + '"'
[IO.File]::WriteAllText($settingsTarget, ($settings | ConvertTo-Json -Depth 100), $utf8)

$packageManifest = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
$installVersion = [string] $packageManifest.version
if ($installVersion -notmatch '^\d+\.\d+\.\d+$') { Fail 'package.json contains an invalid Claudex version' }
$installMethod = if ($env:CLAUDEX_INSTALL_METHOD) { $env:CLAUDEX_INSTALL_METHOD } elseif (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container) { 'git' } else { 'archive' }
if ($installMethod -notin @('npm', 'homebrew', 'scoop', 'winget', 'archive', 'git')) { Fail "unsupported CLAUDEX_INSTALL_METHOD: $installMethod" }
$receipt = [ordered]@{ schema = 1; version = $installVersion; method = $installMethod; binDir = $binDir; repository = 'BeamoINT/Claudex' }
$receiptTemporary = Join-Path $configDir ('install-' + [guid]::NewGuid().ToString('N') + '.tmp')
[IO.File]::WriteAllText($receiptTemporary, (($receipt | ConvertTo-Json -Compress) + "`n"), $utf8)
Move-Item -LiteralPath $receiptTemporary -Destination $installReceiptTarget -Force

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$userEntries = if ($userPath) { @($userPath -split [regex]::Escape([string] $separator)) } else { @() }
foreach ($pathToAdd in @($codexInstalledBinDir, $claudeInstalledBinDir, $(if (-not $packageManagedInstall) { $binDir } else { '' })) | Where-Object { $_ }) {
    if ($pathToAdd -notin $userEntries) {
        $userPath = if ($userPath) { "$pathToAdd$separator$userPath" } else { $pathToAdd }
        $userEntries += $pathToAdd
        [Console]::WriteLine("Added to your user PATH: $pathToAdd")
    }
}
[Environment]::SetEnvironmentVariable('Path', $userPath, 'User')

[Console]::WriteLine("Installed Claudex launcher: $cmdTarget")
[Console]::WriteLine("Installed isolated config: $configDir")

& $codexSessionTarget sync *> $null
$authReady = $LASTEXITCODE -eq 0
if (-not $authReady -and $Login) {
    & $codexSessionTarget login
    if ($LASTEXITCODE -ne 0) { Fail "Codex login failed with exit code $LASTEXITCODE" }
    $authReady = $true
} elseif (-not $authReady -and -not $skipDependencies -and (Test-InteractiveInstall)) {
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
} finally {
    Release-InstallLock
}
