[CmdletBinding()]
param([switch] $Login)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repositoryUrl = 'https://github.com/BeamoINT/Claudex'
$apiUrl = 'https://api.github.com/repos/BeamoINT/Claudex/releases/latest'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('claudex-bootstrap-' + [guid]::NewGuid().ToString('N'))

function Fail([string] $Message) {
    [Console]::Error.WriteLine("Claudex bootstrap: $Message")
    exit 1
}

try {
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    $headers = @{ 'User-Agent' = 'Claudex-Installer' }
    $release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri $apiUrl -TimeoutSec 60
    $tag = [string] $release.tag_name
    if ($tag -notmatch '^v(\d+)\.(\d+)\.(\d+)$') { Fail "the latest release tag is invalid: $tag" }
    $version = $tag.Substring(1)
    $archiveName = "claudex-$version-windows.zip"
    $downloadBase = "$repositoryUrl/releases/download/$tag"
    $archive = Join-Path $temporary $archiveName
    $checksums = Join-Path $temporary 'SHA256SUMS'

    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "$downloadBase/$archiveName" -OutFile $archive -TimeoutSec 180
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "$downloadBase/SHA256SUMS" -OutFile $checksums -TimeoutSec 60

    $matches = @([IO.File]::ReadAllLines($checksums) | ForEach-Object {
        if ($_ -match '^([0-9A-Fa-f]{64})\s+(.+)$' -and $Matches[2] -eq $archiveName) { $Matches[1].ToLowerInvariant() }
    })
    if ($matches.Count -ne 1) { Fail "SHA256SUMS must contain exactly one valid digest for $archiveName" }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $matches[0]) { Fail "checksum mismatch for $archiveName" }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $archiveRoot = "claudex-$version"
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name -or $name.StartsWith('/') -or $name -match '(^|/)\.\.?(?:/|$)' -or
                ($name -ne $archiveRoot -and -not $name.StartsWith("$archiveRoot/"))) {
                Fail "unsafe archive path: $name"
            }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) { Fail "release archive contains a symbolic link: $name" }
            $destination = [IO.Path]::GetFullPath((Join-Path $temporary $name))
            $safeRoot = [IO.Path]::GetFullPath($temporary) + [IO.Path]::DirectorySeparatorChar
            if (-not $destination.StartsWith($safeRoot, [StringComparison]::OrdinalIgnoreCase)) { Fail "unsafe archive path: $name" }
        }
    } finally { $zip.Dispose() }

    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $temporary)
    $sourceRoot = Join-Path $temporary "claudex-$version"
    foreach ($required in @('package.json', 'install.ps1', 'claudex.ps1', 'codex-session.ps1', 'settings.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) { Fail "release archive is missing $required" }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $sourceRoot 'package.json') -Raw | ConvertFrom-Json
    if ([string] $manifest.version -ne $version) { Fail "archive version $($manifest.version) does not match release $version" }

    [Console]::WriteLine("Installing Claudex $version from its verified GitHub release...")
    $env:CLAUDEX_INSTALL_METHOD = 'archive'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $sourceRoot 'install.ps1'))
    if ($Login) { $arguments += '-Login' }
    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { Fail "Claudex installer failed with exit code $LASTEXITCODE" }
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
}
