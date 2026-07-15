param([switch] $Login)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = $PSScriptRoot
$binDir = if ($env:CLAUDEX_BIN_DIR) { $env:CLAUDEX_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$managedBinDir = Join-Path $configDir 'bin'
$managedProxy = Join-Path $managedBinDir 'cliproxyapi.exe'
$authDir = Join-Path $configDir 'codex-accounts'
$envFile = Join-Path $configDir 'env'
$settingsTarget = Join-Path $configDir 'settings.json'
$statuslineTarget = Join-Path $configDir 'statusline.ps1'
$usageLimitTarget = Join-Path $configDir 'usage-limit.ps1'
$codexSessionTarget = Join-Path $configDir 'codex-session.ps1'
$usageSkillTarget = Join-Path $configDir 'skills\usage-limit\SKILL.md'
$preloadTarget = Join-Path $configDir 'preload.cjs'
$proxyConfigTarget = Join-Path $configDir 'cliproxyapi.yaml'
$launcherTarget = Join-Path $binDir 'claudex.ps1'
$cmdTarget = Join-Path $binDir 'claudex.cmd'
$proxyVersion = '7.2.77'
$proxyPort = if ($env:CLAUDEX_PROXY_PORT) { [int] $env:CLAUDEX_PROXY_PORT } else { 8318 }
$skipDependencies = $env:CLAUDEX_SKIP_DEPENDENCY_INSTALL -eq '1'
$skipService = $env:CLAUDEX_SKIP_SERVICE_START -eq '1'
$utf8 = New-Object Text.UTF8Encoding($false)

function Fail([string] $Message) {
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

foreach ($sourceFile in @('claudex.ps1', 'claudex.cmd', 'codex-session.ps1', 'statusline.ps1', 'usage-limit.ps1', 'preload.cjs', 'settings.json', 'skills\usage-limit\SKILL.md')) {
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
        'x64' { $arch = 'amd64'; $expected = 'daa8277af35e2a5c7bbc9a71e768dceed5bdb31e66d48ac36be63b3d52338d1d' }
        'arm64' { $arch = 'aarch64'; $expected = 'cbef6ab244741a41ad9d278716bf37cac7a233b80063d22254df04132e0c39cc' }
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

if (-not $skipDependencies) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Fail "Codex CLI is required. Install Codex, run 'codex login', then rerun this installer." }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        [Console]::WriteLine("Installing Claude Code with Anthropic's native installer...")
        $installer = Join-Path ([IO.Path]::GetTempPath()) ('claude-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://claude.ai/install.ps1' -OutFile $installer
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
            if ($LASTEXITCODE -ne 0) { Fail "Claude Code's native installer failed with exit code $LASTEXITCODE" }
        } finally { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
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

if ($Login) {
    & $codexCommand.Source '-c' 'cli_auth_credentials_store="file"' 'login'
    if ($LASTEXITCODE -ne 0) { Fail "Codex login failed with exit code $LASTEXITCODE" }
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
$authPath = $authDir.Replace('\', '/')
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
request-retry: 1
max-retry-credentials: 1
"@
[IO.File]::WriteAllText($proxyConfigTarget, $proxyConfig, $utf8)
$managedProxyForEnv = if (Test-Path -LiteralPath $managedProxy -PathType Leaf) { $managedProxy } else { $proxyBinary }
$managedLines = @(
    "CLAUDEX_PROXY_TOKEN=$proxyToken",
    "CLAUDEX_PROXY_URL=http://127.0.0.1:$proxyPort",
    "CLAUDEX_PROXY_CONFIG=$proxyConfigTarget",
    "CLAUDEX_PROXY_BIN=$managedProxyForEnv",
    "CLAUDEX_CODEX_AUTH_DIR=$authDir"
)
[IO.File]::WriteAllLines($envFile, @($managedLines + $existingLines), $utf8)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $configDir "backups\install-$timestamp"
$backedUp = $false
foreach ($managedFile in @($launcherTarget, $cmdTarget, $settingsTarget, $statuslineTarget, $usageLimitTarget, $codexSessionTarget, $preloadTarget, $usageSkillTarget)) {
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
[IO.Directory]::CreateDirectory((Split-Path $usageSkillTarget -Parent)) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'skills\usage-limit\SKILL.md') -Destination $usageSkillTarget -Force

$settings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
$settings.statusLine.command = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $statuslineTarget + '"'
[IO.File]::WriteAllText($settingsTarget, ($settings | ConvertTo-Json -Depth 100), $utf8)

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$userEntries = if ($userPath) { @($userPath -split [regex]::Escape([string] $separator)) } else { @() }
if ($binDir -notin $userEntries) {
    [Environment]::SetEnvironmentVariable('Path', $(if ($userPath) { "$binDir$separator$userPath" } else { $binDir }), 'User')
    [Console]::WriteLine("Added to your user PATH: $binDir")
}

[Console]::WriteLine("Installed Claudex launcher: $cmdTarget")
[Console]::WriteLine("Installed isolated config: $configDir")

& $codexSessionTarget sync
$authReady = $LASTEXITCODE -eq 0
if (-not $authReady) { [Console]::Error.WriteLine("Claudex is installed. Sign in with 'claudex --login', then run 'claudex'.") }
if (-not $skipService -and $authReady) {
    & $launcherTarget --doctor
    if ($LASTEXITCODE -eq 0) { [Console]::WriteLine('Claudex is ready. Run: claudex') }
    else { Fail 'the live compatibility check did not pass; run `claudex --doctor` for details' }
}
