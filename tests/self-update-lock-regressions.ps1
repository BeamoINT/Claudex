$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('claudex-self-update-locks-' + [guid]::NewGuid().ToString('N'))
$config = Join-Path $temporary 'config'
$fixture = Join-Path $temporary 'fixture'
$update = Join-Path $config 'update\claudex'
$lock = Join-Path $update 'lock'
$utf8 = New-Object Text.UTF8Encoding($false)
$shell = (Get-Process -Id $PID).Path
$scriptPath = Join-Path $root 'self-update.ps1'
$arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $scriptPath + '"'), '-Check')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "assertion failed: $Message" }
}

function Wait-File([string] $Path) {
    for ($attempt = 0; $attempt -lt 500; $attempt++) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        Start-Sleep -Milliseconds 20
    }
    throw "timed out waiting for $Path"
}

function Set-Old([string] $Path) {
    (Get-Item -LiteralPath $Path).LastWriteTimeUtc = [DateTime]::Parse('2000-01-01T00:00:00Z').ToUniversalTime()
}

function Set-Pause([string] $Stage, [string] $Name) {
    [Environment]::SetEnvironmentVariable("CLAUDEX_TEST_UPDATE_LOCK_${Stage}_READY", (Join-Path $temporary "$Name-ready"), 'Process')
    [Environment]::SetEnvironmentVariable("CLAUDEX_TEST_UPDATE_LOCK_${Stage}_CONTINUE", (Join-Path $temporary "$Name-continue"), 'Process')
}

function Clear-Pause([string] $Stage) {
    [Environment]::SetEnvironmentVariable("CLAUDEX_TEST_UPDATE_LOCK_${Stage}_READY", $null, 'Process')
    [Environment]::SetEnvironmentVariable("CLAUDEX_TEST_UPDATE_LOCK_${Stage}_CONTINUE", $null, 'Process')
}

function Continue-Pause([string] $Name) {
    [IO.File]::WriteAllText((Join-Path $temporary "$Name-continue"), "continue`n", $utf8)
}

function Start-Check {
    return Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -WindowStyle Hidden
}

function Invoke-ExpectedFailedCheck {
    $savedErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 promotes a native child's stderr to a
        # NativeCommandError when the caller uses Stop. The nonzero result is
        # expected in these contention cases, so collect it without allowing
        # the diagnostic stream to abort the regression before its assertions.
        $ErrorActionPreference = 'Continue'
        & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Check 2>$null | Out-Null
        return [int] $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrorPreference }
}

try {
    [IO.Directory]::CreateDirectory($config) | Out-Null
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    [IO.File]::WriteAllText((Join-Path $config 'install.json'), '{"schema":1,"version":"1.3.1","method":"archive","binDir":"C:\\claudex-test","repository":"BeamoINT/Claudex"}', $utf8)
    $release = [ordered]@{
        tag_name = 'v1.3.2'; draft = $false; prerelease = $false; published_at = '2026-07-16T00:00:00Z'
        assets = @(
            [ordered]@{ name = 'claudex-1.3.2-windows.zip'; url = 'https://api.github.com/assets/claudex-1.3.2-windows.zip' },
            [ordered]@{ name = 'SHA256SUMS'; url = 'https://api.github.com/assets/SHA256SUMS' }
        )
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'latest.json'), (($release | ConvertTo-Json -Depth 10) + "`n"), $utf8)
    $env:CLAUDEX_CONFIG_DIR = $config
    $env:CLAUDEX_TEST_MODE = '1'
    $env:CLAUDEX_TEST_UPDATE_FIXTURE_DIR = $fixture
    $env:CLAUDEX_TEST_UPDATE_LOCK_ATTEMPTS = '12'

    $source = [IO.File]::ReadAllText($scriptPath)
    foreach ($required in @('function Publish-UpdateLockFile', '[IO.FileMode]::CreateNew', 'identity=', 'generation', 'quarantine',
            'Remove-UpdateLockGeneration', 'Recover-OwnedUpdateLock', 'Test-UpdateLockOwnerCurrent',
            'legacy update lock owner appeared during publication', 'Test-LegacyUpdateLockOwnerValid',
            'Get-UpdateLockDirectoryIdentity', 'update lock directory changed during publication',
            'Claudex.SelfUpdateDirectoryIdentity', 'GetFileInformationByHandle',
            'using (SafeFileHandle handle = CreateFile',
            'Get-UpdateCompatibilityOwnerToken', "Publish-UpdateLockFile `$compatibilityTemporary (Join-Path `$script:LockPath 'owner.json')")) {
        Assert-True ($source.Contains($required)) "PowerShell update lock contains $required"
    }

    # A paused directory creator cannot overwrite a complete B generation.
    Set-Pause 'AFTER_MKDIR' 'a'
    $a = Start-Check
    Clear-Pause 'AFTER_MKDIR'
    Wait-File (Join-Path $temporary 'a-ready')
    Set-Old $lock
    Set-Pause 'AFTER_PUBLISH' 'b'
    $b = Start-Check
    Clear-Pause 'AFTER_PUBLISH'
    Wait-File (Join-Path $temporary 'b-ready')
    $bNonce = ([IO.File]::ReadAllLines((Join-Path $lock 'owner')) | Where-Object { $_.StartsWith('nonce=') })[0]
    Continue-Pause 'a'
    Assert-True ($a.WaitForExit(15000)) 'paused A exits'
    Assert-True ([IO.File]::ReadAllText((Join-Path $lock 'owner')).Contains($bNonce)) 'A preserves B generation'
    Continue-Pause 'b'
    Assert-True ($b.WaitForExit(15000)) 'B exits'
    Assert-True (-not (Test-Path -LiteralPath $lock)) 'B releases exact generation'

    # A new creator can resume inside a replacement lock published by the old
    # owner.json protocol. It must remove only its injected generation and
    # restore the legacy B owner intact.
    Set-Pause 'AFTER_MKDIR' 'mixed-a'
    $mixedA = Start-Check
    Clear-Pause 'AFTER_MKDIR'
    Wait-File (Join-Path $temporary 'mixed-a-ready')
    Move-Item -LiteralPath $lock -Destination (Join-Path $update 'abandoned-mixed-a')
    [IO.Directory]::CreateDirectory($lock) | Out-Null
    [IO.File]::WriteAllText((Join-Path $lock 'owner.json'), "{`"pid`":$PID,`"token`":`"legacy-b`"}`n", $utf8)
    Remove-Item -LiteralPath (Join-Path $update 'abandoned-mixed-a') -Recurse -Force
    Continue-Pause 'mixed-a'
    Assert-True ($mixedA.WaitForExit(15000) -and $mixedA.ExitCode -ne 0) 'mixed protocol A exits outside update section'
    Assert-True ([IO.File]::ReadAllText((Join-Path $lock 'owner.json')).Contains('legacy-b')) 'mixed protocol A preserves legacy B owner'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $lock 'generation'))) 'mixed protocol A withdraws only its injected generation'
    Assert-True (@(Get-ChildItem -LiteralPath $update -Directory -Filter 'lock.quarantine.*' -ErrorAction SilentlyContinue).Count -eq 0) 'mixed protocol cleanup leaves no barrier'
    Remove-Item -LiteralPath $lock -Recurse -Force

    # Stable directory identity also covers B's earlier publication window,
    # where B replaced A but has not written owner.json yet.
    Set-Pause 'AFTER_MKDIR' 'empty-b'
    $emptyBA = Start-Check
    Clear-Pause 'AFTER_MKDIR'
    Wait-File (Join-Path $temporary 'empty-b-ready')
    $abandonedCreationTime = (Get-Item -LiteralPath $lock).CreationTimeUtc
    Move-Item -LiteralPath $lock -Destination (Join-Path $update 'abandoned-empty-b-a')
    [IO.Directory]::CreateDirectory($lock) | Out-Null
    # Creation timestamps are mutable and therefore cannot serve as an ABA
    # identity. Match A's timestamp exactly to prove the native file ID still
    # distinguishes B's replacement directory.
    (Get-Item -LiteralPath $lock).CreationTimeUtc = $abandonedCreationTime
    Remove-Item -LiteralPath (Join-Path $update 'abandoned-empty-b-a') -Recurse -Force
    Continue-Pause 'empty-b'
    Assert-True ($emptyBA.WaitForExit(15000) -and $emptyBA.ExitCode -ne 0) 'A rejects an empty replacement directory'
    Assert-True ((Test-Path -LiteralPath $lock -PathType Container) -and
        -not (Test-Path -LiteralPath (Join-Path $lock 'generation')) -and
        -not (Test-Path -LiteralPath (Join-Path $lock 'owner'))) 'A preserves B before legacy owner publication'
    [IO.File]::WriteAllText((Join-Path $lock 'owner.json'), "{`"pid`":$PID,`"token`":`"late-legacy-b`"}`n", $utf8)
    Assert-True ([IO.File]::ReadAllText((Join-Path $lock 'owner.json')).Contains('late-legacy-b')) 'B can finish legacy owner publication'
    Remove-Item -LiteralPath $lock -Recurse -Force

    # Crash recovery observes the legacy owner before the injected generation.
    # A live owner.json B is restored and A's partial generation is withdrawn.
    $mixedBarrier = "$lock.quarantine.synthetic-live-legacy"
    [IO.Directory]::CreateDirectory($mixedBarrier) | Out-Null
    [IO.File]::WriteAllText((Join-Path $mixedBarrier 'generation'), "injected-a`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $mixedBarrier 'owner'), "pid=2147483000`nidentity=dead`nnonce=injected-a`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $mixedBarrier 'owner.json'), "{`"pid`":$PID,`"token`":`"legacy-b-crash`"}`n", $utf8)
    Set-Old $mixedBarrier
    $mixedCrashExit = Invoke-ExpectedFailedCheck
    Assert-True ($mixedCrashExit -ne 0) 'mixed protocol crash recovery keeps contender outside update section'
    Assert-True ([IO.File]::ReadAllText((Join-Path $lock 'owner.json')).Contains('legacy-b-crash')) 'mixed protocol crash recovery restores live B'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $lock 'generation'))) 'mixed protocol crash recovery removes injected A generation'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $lock 'owner'))) 'mixed protocol crash recovery removes injected A owner'
    Assert-True (@(Get-ChildItem -LiteralPath $update -Directory -Filter 'lock.quarantine.*' -ErrorAction SilentlyContinue).Count -eq 0) 'mixed protocol crash recovery leaves no barrier'
    Remove-Item -LiteralPath $lock -Recurse -Force

    # X prechecks a dead owner, Y acquires, and the quarantine blocks Z until
    # the exact moved Y nonce is restored.
    [IO.Directory]::CreateDirectory($lock) | Out-Null
    [IO.File]::WriteAllText((Join-Path $lock 'generation'), "x`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $lock 'owner'), "pid=2147483000`nidentity=dead`nnonce=x`n", $utf8)
    Set-Old $lock
    Set-Pause 'BEFORE_RENAME' 'x-before'
    Set-Pause 'AFTER_RENAME' 'x-after'
    $x = Start-Check
    Clear-Pause 'BEFORE_RENAME'; Clear-Pause 'AFTER_RENAME'
    Wait-File (Join-Path $temporary 'x-before-ready')
    Set-Pause 'AFTER_PUBLISH' 'y'
    $y = Start-Check
    Clear-Pause 'AFTER_PUBLISH'
    Wait-File (Join-Path $temporary 'y-ready')
    $yNonce = ([IO.File]::ReadAllLines((Join-Path $lock 'owner')) | Where-Object { $_.StartsWith('nonce=') })[0]
    Continue-Pause 'x-before'
    Wait-File (Join-Path $temporary 'x-after-ready')
    $z = Start-Check
    Assert-True ($z.WaitForExit(15000) -and $z.ExitCode -ne 0) 'Z remains outside quarantined update section'
    Continue-Pause 'x-after'
    for ($attempt = 0; $attempt -lt 500; $attempt++) {
        if ((Test-Path -LiteralPath (Join-Path $lock 'owner')) -and [IO.File]::ReadAllText((Join-Path $lock 'owner')).Contains($yNonce)) { break }
        Start-Sleep -Milliseconds 20
    }
    Assert-True ([IO.File]::ReadAllText((Join-Path $lock 'owner')).Contains($yNonce)) 'X restores exact moved Y nonce'
    Continue-Pause 'y'
    Assert-True ($y.WaitForExit(15000)) 'Y exits'
    Assert-True ($x.WaitForExit(15000)) 'X exits'

    # Hardlink denial falls back to CreateNew and an incomplete publication is
    # withdrawn without leaving an owner or quarantine barrier.
    $env:CLAUDEX_TEST_FORCE_HARDLINK_FAILURE = '1'
    & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Check | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $lock)) 'CreateNew fallback succeeds'
    Remove-Item Env:CLAUDEX_TEST_FORCE_HARDLINK_FAILURE
    $env:CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE = '1'
    $publicationFailureExit = Invoke-ExpectedFailedCheck
    Assert-True ($publicationFailureExit -ne 0 -and -not (Test-Path -LiteralPath $lock)) 'incomplete publication is removed'
    Assert-True (@(Get-ChildItem -LiteralPath $update -Directory -Filter 'lock.quarantine.*' -ErrorAction SilentlyContinue).Count -eq 0) 'incomplete publication leaves no barrier'
    Remove-Item Env:CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE

    # Dead and PID reused owners are reclaimable, but a recent ownerless lock
    # from the legacy format is retained through the transition grace period.
    foreach ($case in @('dead', 'reused')) {
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
        [IO.Directory]::CreateDirectory($lock) | Out-Null
        [IO.File]::WriteAllText((Join-Path $lock 'generation'), "$case`n", $utf8)
        $ownerPid = if ($case -eq 'dead') { 2147483000 } else { $PID }
        [IO.File]::WriteAllText((Join-Path $lock 'owner'), "pid=$ownerPid`nidentity=old-start`nnonce=$case`n", $utf8)
        Set-Old $lock
        & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Check | Out-Null
        Assert-True ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $lock)) "$case owner is reclaimed"
    }
    [IO.Directory]::CreateDirectory($lock) | Out-Null
    $liveNewIdentity = [string] (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    [IO.File]::WriteAllText((Join-Path $lock 'generation'), "live-new`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $lock 'owner'), "pid=$PID`nidentity=$liveNewIdentity`nnonce=live-new`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $lock 'owner.json'), "{`"pid`":$PID,`"token`":`"live-new`"}`n", $utf8)
    Set-Old $lock
    $legacyVisibleOwner = Get-Content -LiteralPath (Join-Path $lock 'owner.json') -Raw | ConvertFrom-Json
    Assert-True ([int]$legacyVisibleOwner.pid -eq $PID -and $null -ne (Get-Process -Id ([int]$legacyVisibleOwner.pid) -ErrorAction SilentlyContinue)) 'previous PowerShell updater recognizes current live owner'
    $liveGenerationExit = Invoke-ExpectedFailedCheck
    Assert-True ($liveGenerationExit -ne 0 -and (Test-Path -LiteralPath (Join-Path $lock 'owner.json'))) 'current contender also preserves old live generation'
    Remove-Item -LiteralPath $lock -Recurse -Force
    [IO.Directory]::CreateDirectory($lock) | Out-Null
    $ownerlessGraceExit = Invoke-ExpectedFailedCheck
    Assert-True ($ownerlessGraceExit -ne 0 -and (Test-Path -LiteralPath $lock)) 'recent legacy ownerless lock is retained'
    Set-Old $lock
    & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Check | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $lock)) 'expired legacy ownerless lock is reclaimed'
    [IO.Directory]::CreateDirectory($lock) | Out-Null
    [IO.File]::WriteAllText((Join-Path $lock 'owner.json'), "{`"pid`":$PID,`"token`":`"legacy`"}`n", $utf8)
    Set-Old $lock
    $legacyOwnerExit = Invoke-ExpectedFailedCheck
    Assert-True ($legacyOwnerExit -ne 0 -and (Test-Path -LiteralPath (Join-Path $lock 'owner.json'))) 'old live legacy owner is retained'
    Remove-Item -LiteralPath $lock -Recurse -Force

    # The exit path validates its nonce and cannot delete a replacement owner.
    Set-Pause 'AFTER_PUBLISH' 'exit'
    $oldOwner = Start-Check
    Clear-Pause 'AFTER_PUBLISH'
    Wait-File (Join-Path $temporary 'exit-ready')
    Move-Item -LiteralPath $lock -Destination (Join-Path $update 'displaced-lock')
    [IO.Directory]::CreateDirectory($lock) | Out-Null
    [IO.File]::WriteAllText((Join-Path $lock 'generation'), "replacement`n", $utf8)
    $identity = [string] (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    [IO.File]::WriteAllText((Join-Path $lock 'owner'), "pid=$PID`nidentity=$identity`nnonce=replacement`n", $utf8)
    Continue-Pause 'exit'
    Assert-True ($oldOwner.WaitForExit(15000)) 'obsolete owner exits'
    Assert-True ([IO.File]::ReadAllText((Join-Path $lock 'owner')).Contains('nonce=replacement')) 'exit hook preserves replacement generation'

    [Console]::WriteLine('PowerShell self update lock regressions passed')
} finally {
    foreach ($name in @('CLAUDEX_CONFIG_DIR', 'CLAUDEX_TEST_MODE', 'CLAUDEX_TEST_UPDATE_FIXTURE_DIR',
            'CLAUDEX_TEST_UPDATE_LOCK_ATTEMPTS', 'CLAUDEX_TEST_FORCE_HARDLINK_FAILURE', 'CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
