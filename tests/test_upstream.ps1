$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repo 'scripts' 'upstream.ps1'
$pinned = (Get-Content -Raw -Encoding utf8 (Join-Path $repo 'pins.json') | ConvertFrom-Json).cef_version
$major = [int]$pinned.Split('.')[0]
# Release numbers relative to the pinned one, so the test follows pins.json.
$patch = [int]($pinned.Split('+')[0].Split('.')[2])
function Newer([int]$By) { "$major.0.$($patch + $By)" }
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-upstream-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null

function Release([string]$Number, [string]$Channel = 'stable') {
    @{ cef_version = "$Number+g0123abc+chromium-$major.0.1.$($Number.Split('.')[-1])"; channel = $Channel }
}

function Select-Upstream([hashtable]$Extra, [string[]]$Arguments = @()) {
    $index = [ordered]@{}
    foreach ($platform in 'linux64', 'linuxarm64', 'windows64', 'windowsarm64', 'macosx64', 'macosarm64') {
        $versions = @(@{ cef_version = $pinned; channel = 'stable' })
        $versions += @($Extra.All)
        if ($Extra.ContainsKey($platform)) { $versions += @($Extra[$platform]) }
        $index[$platform] = @{ versions = $versions }
    }
    $path = Join-Path $temp 'index.json'
    $index | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    $output = & pwsh -NoProfile -File $script -IndexPath $path -SelectOnly @Arguments
    if ($LASTEXITCODE -ne 0) { throw "upstream.ps1 failed: $output" }
    return ($output -join "`n") | ConvertFrom-Json
}

try {
    # Numeric order (+100 beats +9 although "9" sorts after "1" as text), betas
    # and releases missing a target are ignored.
    $result = Select-Upstream @{
        All = @((Release (Newer 9)), (Release (Newer 100)), (Release (Newer 200) 'beta'))
        windows64 = @(Release (Newer 150))
    }
    if ($result.selected -cne (Newer 100) -or -not $result.update -or $result.new_major) {
        throw "Unexpected selection: $($result | ConvertTo-Json -Compress)"
    }

    # A newer milestone is reported only once every target has it, and is never selected.
    $result = Select-Upstream @{ All = @(Release "$($major + 2).0.3") }
    if ($result.new_major -cne "$($major + 2)" -or $result.update) {
        throw "Unexpected milestone report: $($result | ConvertTo-Json -Compress)"
    }
    $result = Select-Upstream @{ All = @(); linux64 = @(Release "$($major + 2).0.3") }
    if ($result.new_major) { throw 'A milestone missing targets was reported' }

    # Nothing newer: no update.
    $result = Select-Upstream @{ All = @() }
    if ($result.update -or $result.selected -cne $result.pinned) { throw 'Reported an update without a newer release' }

    # A requested version must be a stable release on the pinned branch.
    $result = Select-Upstream @{ All = @((Release (Newer 3)), (Release (Newer 4))) } @('-Version', (Newer 3))
    if ($result.selected -cne (Newer 3)) { throw 'Did not select the requested version' }
    $failed = $false
    try { Select-Upstream @{ All = @() } @('-Version', (Newer 999)) | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Accepted a version that is not released' }
    Write-Host 'upstream tests passed'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
