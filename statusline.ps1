$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

$raw = [Console]::In.ReadToEnd()
$data = $null
try { $data = $raw | ConvertFrom-Json } catch { $data = $null }

$modelId = ''
$displayName = ''
$effort = ''
$contextPercent = $null
if ($data) {
    if ($data.model) {
        $modelId = [string] $data.model.id
        $displayName = [string] $data.model.display_name
    }
    if ($data.effort) { $effort = [string] $data.effort.level }
    if ($data.context_window -and $null -ne $data.context_window.used_percentage) {
        $contextPercent = [math]::Floor([double] $data.context_window.used_percentage)
    }
}

if (-not $effort) {
    $effort = if ($env:CLAUDE_CODE_EFFORT_LEVEL) { $env:CLAUDE_CODE_EFFORT_LEVEL } else { $env:CLAUDE_EFFORT }
}
if (-not $effort) {
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.config\claudex' }
    $settingsPath = Join-Path $configDir 'settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try { $effort = [string] ((Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).effortLevel) } catch { }
    }
}
if (-not $effort) { $effort = 'adaptive' }

$modelName = switch -Wildcard ($modelId) {
    'gpt-5.6-sol' { 'GPT-5.6 Sol'; break }
    'gpt-5.6-terra' { 'GPT-5.6 Terra'; break }
    'gpt-5.6-luna' { 'GPT-5.6 Luna'; break }
    'claude-fable-*' { 'GPT-5.6 Sol'; break }
    'claude-opus-*' { 'GPT-5.6 Sol'; break }
    'claude-sonnet-*' { 'GPT-5.6 Terra'; break }
    'claude-haiku-*' { 'GPT-5.6 Luna'; break }
    default {
        switch -Wildcard ($displayName) {
            '*Fable*' { 'GPT-5.6 Sol'; break }
            '*Opus*' { 'GPT-5.6 Sol'; break }
            '*Sonnet*' { 'GPT-5.6 Terra'; break }
            '*Haiku*' { 'GPT-5.6 Luna'; break }
            default { if ($modelId) { $modelId } elseif ($displayName) { $displayName } else { 'Unknown model' } }
        }
    }
}

$escape = [char] 27
$separator = [char] 0x00B7
[Console]::Out.Write("${escape}]0;Claudex $separator $modelName $separator $effort effort$([char]7)")
$line = "${escape}[38;5;81mClaudex${escape}[0m $separator ${escape}[1m$modelName${escape}[0m $separator $effort effort"
if ($null -ne $contextPercent) { $line += " $separator $contextPercent% context" }
[Console]::Out.WriteLine($line)
