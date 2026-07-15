param(
    [switch] $Login
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = $PSScriptRoot
$binDir = if ($env:CLAUDEX_BIN_DIR) { $env:CLAUDEX_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$configDir = if ($env:CLAUDEX_CONFIG_DIR) { $env:CLAUDEX_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
$envFile = Join-Path $configDir 'env'
$settingsTarget = Join-Path $configDir 'settings.json'
$statuslineTarget = Join-Path $configDir 'statusline.ps1'
$usageLimitTarget = Join-Path $configDir 'usage-limit.ps1'
$usageSkillTarget = Join-Path $configDir 'skills\usage-limit\SKILL.md'
$preloadTarget = Join-Path $configDir 'preload.cjs'
$proxyConfigTarget = Join-Path $configDir 'cliproxyapi.yaml'
$selectedProxyConfig = if ($env:CLAUDEX_PROXY_CONFIG -and (Test-Path -LiteralPath $env:CLAUDEX_PROXY_CONFIG -PathType Leaf)) { $env:CLAUDEX_PROXY_CONFIG } else { $proxyConfigTarget }
$launcherTarget = Join-Path $binDir 'claudex.ps1'
$cmdTarget = Join-Path $binDir 'claudex.cmd'
$proxyVersion = '7.2.77'
$skipDependencies = $env:CLAUDEX_SKIP_DEPENDENCY_INSTALL -eq '1'
$skipService = $env:CLAUDEX_SKIP_SERVICE_START -eq '1'
$utf8 = New-Object Text.UTF8Encoding($false)

function Fail([string] $Message) {
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

foreach ($sourceFile in @('claudex.ps1', 'claudex.cmd', 'statusline.ps1', 'usage-limit.ps1', 'preload.cjs', 'settings.json', 'skills\usage-limit\SKILL.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $sourceFile) -PathType Leaf)) {
        Fail "missing repository file: $sourceFile"
    }
}

function Find-ProxyExecutable {
    foreach ($name in @('cliproxyapi.exe', 'cli-proxy-api.exe', 'cliproxyapi', 'cli-proxy-api')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    $managed = Join-Path $binDir 'cliproxyapi.exe'
    if (Test-Path -LiteralPath $managed -PathType Leaf) { return $managed }
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
        [Console]::WriteLine("Downloading verified CLIProxyAPI v$proxyVersion for Windows/$arch...")
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { Fail "CLIProxyAPI checksum mismatch for $asset" }
        Expand-Archive -LiteralPath $archive -DestinationPath $temporary -Force
        Copy-Item -LiteralPath (Join-Path $temporary 'cli-proxy-api.exe') -Destination (Join-Path $binDir 'cliproxyapi.exe') -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

[IO.Directory]::CreateDirectory($binDir) | Out-Null
[IO.Directory]::CreateDirectory($configDir) | Out-Null
$pathSeparator = [IO.Path]::PathSeparator
$processEntries = @($env:PATH -split [regex]::Escape([string] $pathSeparator))
if ($binDir -notin $processEntries) { $env:PATH = "$binDir$pathSeparator$env:PATH" }

if (-not $skipDependencies) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Find-ProxyExecutable)) { Install-Proxy }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        [Console]::WriteLine("Installing Claude Code with Anthropic's native installer...")
        $installer = Join-Path ([IO.Path]::GetTempPath()) ('claude-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://claude.ai/install.ps1' -OutFile $installer
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
            if ($LASTEXITCODE -ne 0) { Fail "Claude Code's native installer failed with exit code $LASTEXITCODE" }
        } finally {
            if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
        }
    }
}

$proxyBinary = Find-ProxyExecutable
if (-not $proxyBinary) { Fail 'CLIProxyAPI is required but was not found in PATH' }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Fail "'claude' is required but was not found in PATH" }

function Get-FirstProxyKey([string] $Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $insideKeys = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^api-keys:\s*$') { $insideKeys = $true; continue }
        if ($insideKeys -and $line -match '^\s*-\s*["'']?([^"'']+?)["'']?\s*$') { return $Matches[1] }
        if ($insideKeys -and $line -match '^\S') { break }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $envFile -PathType Leaf) -or (Get-Item -LiteralPath $envFile).Length -eq 0) {
    $proxyToken = $env:CLAUDEX_PROXY_TOKEN
    if (-not $proxyToken) { $proxyToken = Get-FirstProxyKey $selectedProxyConfig }
    if (-not $proxyToken) {
        $secure = Read-Host 'CLIProxyAPI API key (leave empty to generate one)' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $proxyToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    if (-not $proxyToken) {
        $bytes = New-Object byte[] 32
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($bytes) } finally { $random.Dispose() }
        $proxyToken = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    }
    if ($proxyToken.Contains("`r") -or $proxyToken.Contains("`n")) { Fail 'proxy API key contains a newline' }

    if (-not (Test-Path -LiteralPath $selectedProxyConfig -PathType Leaf)) {
        $jsonToken = $proxyToken | ConvertTo-Json -Compress
        $authDirectory = (Join-Path $env:USERPROFILE '.cli-proxy-api').Replace('\', '/')
        $proxyConfig = @"
host: "127.0.0.1"
port: 8317
auth-dir: "$authDirectory"
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
        $selectedProxyConfig = $proxyConfigTarget
    }
    $environmentContent = "CLAUDEX_PROXY_TOKEN=$proxyToken`nCLAUDEX_PROXY_CONFIG=$selectedProxyConfig`n"
    [IO.File]::WriteAllText($envFile, $environmentContent, $utf8)
} else {
    [Console]::WriteLine("Preserving existing private config: $envFile")
}

if ($Login) {
    [Console]::WriteLine('Starting CLIProxyAPI Codex login...')
    if (Test-Path -LiteralPath $selectedProxyConfig -PathType Leaf) {
        & $proxyBinary -config $selectedProxyConfig -codex-login
    } else {
        & $proxyBinary -codex-login
    }
    if ($LASTEXITCODE -ne 0) { Fail "CLIProxyAPI login failed with exit code $LASTEXITCODE" }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $configDir "backups\install-$timestamp"
$backedUp = $false
foreach ($managedFile in @($launcherTarget, $cmdTarget, $settingsTarget, $statuslineTarget, $usageLimitTarget, $preloadTarget, $usageSkillTarget)) {
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
Copy-Item -LiteralPath (Join-Path $root 'preload.cjs') -Destination $preloadTarget -Force
[IO.Directory]::CreateDirectory((Split-Path $usageSkillTarget -Parent)) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'skills\usage-limit\SKILL.md') -Destination $usageSkillTarget -Force

$settings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
$statuslineCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $statuslineTarget + '"'
$settings.statusLine.command = $statuslineCommand
[IO.File]::WriteAllText($settingsTarget, ($settings | ConvertTo-Json -Depth 100), $utf8)

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$userEntries = if ($userPath) { @($userPath -split [regex]::Escape([string] $pathSeparator)) } else { @() }
if ($binDir -notin $userEntries) {
    $newUserPath = if ($userPath) { "$binDir$pathSeparator$userPath" } else { $binDir }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    [Console]::WriteLine("Added to your user PATH: $binDir")
}

[Console]::WriteLine("Installed Claudex launcher: $cmdTarget")
[Console]::WriteLine("Installed isolated config: $configDir")

if (-not $skipService) {
    & $launcherTarget --doctor
    if ($LASTEXITCODE -eq 0) { [Console]::WriteLine('Claudex is ready. Run: claudex') }
    else {
        [Console]::Error.WriteLine('Claudex was installed, but the live model check did not pass.')
        [Console]::Error.WriteLine("On a new machine, run '.\install.ps1 -Login' and then 'claudex --doctor'.")
    }
}
