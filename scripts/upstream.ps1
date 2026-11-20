# Finds the newest stable CEF release on the pinned branch in CEF's builds index
# and resolves the pins it needs, from the same sources sync.ps1 verifies.
param(
    # A local copy of index.json instead of the CDN (tests).
    [string]$IndexPath,
    # Resolve this CEF version (for example 156.0.31) instead of the newest one.
    [string]$Version,
    # Report the selection without resolving commits.
    [switch]$SelectOnly,
    # Write the resolved pins to pins.json.
    [switch]$Write
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pinsPath = Join-Path $root 'pins.json'
$pins = Get-Content -Raw -Encoding utf8 -LiteralPath $pinsPath | ConvertFrom-Json
# Only versions published as stable for every target are complete releases.
$platforms = @('linux64', 'linuxarm64', 'windows64', 'windowsarm64', 'macosx64', 'macosarm64')
$versionPattern = '^(\d+)\.(\d+)\.(\d+)\+g([0-9a-f]{7,40})\+chromium-(\d+\.\d+\.\d+\.\d+)$'

function ConvertTo-Release([string]$CefVersion) {
    if ($CefVersion -cnotmatch $versionPattern) { return $null }
    [pscustomobject]@{
        CefVersion = $CefVersion
        Number = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        Major = [int]$Matches[1]
        ShortCommit = $Matches[4]
        Chromium = $Matches[5]
    }
}

function Invoke-GitHub([string[]]$Arguments) {
    $output = & gh api @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub API request failed: $($Arguments -join ' ')" }
    return $output
}

function Assert-Sha([string]$Name, [string]$Value) {
    if ($Value -cnotmatch '^[0-9a-f]{40}$') { throw "Resolved $Name is not a full commit or blob: $Value" }
}

$index = if ($IndexPath) {
    Get-Content -Raw -Encoding utf8 -LiteralPath $IndexPath | ConvertFrom-Json -Depth 20
} else {
    Invoke-RestMethod -Uri 'https://cef-builds.spotifycdn.com/index.json' -TimeoutSec 120
}
$stable = $null
foreach ($platform in $platforms) {
    $versions = @($index.$platform.versions | Where-Object channel -ceq 'stable' | ForEach-Object cef_version)
    $stable = if ($null -eq $stable) { $versions } else { @($stable | Where-Object { $versions -ccontains $_ }) }
}
$releases = @($stable | Select-Object -Unique | ForEach-Object { ConvertTo-Release $_ } | Where-Object { $_ })

$pinned = ConvertTo-Release $pins.cef_version
if (-not $pinned) { throw "Pinned CEF version is not in the expected form: $($pins.cef_version)" }
$branch = @($releases | Where-Object Major -eq $pinned.Major | Sort-Object Number)
$selected = if ($Version) {
    $match = @($branch | Where-Object { $_.Number -eq [version]$Version })
    if ($match.Count -ne 1) { throw "CEF $Version is not a stable release on the pinned $($pinned.Major) branch" }
    $match[0]
} elseif ($branch.Count) { $branch[-1] } else { $pinned }
$update = $selected.Number -gt $pinned.Number
$newestMajor = ($releases | Measure-Object -Property Major -Maximum).Maximum
$newMajor = if ($newestMajor -gt $pinned.Major) { "$newestMajor" } else { '' }

$result = [ordered]@{
    pinned = "$($pinned.Number)"
    selected = "$($selected.Number)"
    selected_cef_version = $selected.CefVersion
    update = $update
    new_major = $newMajor
}

if (-not $SelectOnly -and ($update -or $Version)) {
    $commit = Invoke-GitHub @("repos/chromiumembedded/cef/commits/$($selected.ShortCommit)", '--jq', '.sha')
    Assert-Sha 'CEF commit' $commit
    # The release must come from the pinned branch, not just share its major.
    $status = Invoke-GitHub @("repos/chromiumembedded/cef/compare/$commit...$($pins.cef_branch)", '--jq', '.status')
    if ($status -cnotin @('ahead', 'identical')) { throw "CEF $commit is not on branch $($pins.cef_branch) ($status)" }
    $compatibility = (Invoke-GitHub @('-H', 'Accept: application/vnd.github.raw',
        "repos/chromiumembedded/cef/contents/CHROMIUM_BUILD_COMPATIBILITY.txt?ref=$commit")) -join "`n"
    $checkouts = @{}
    foreach ($key in 'chromium_checkout', 'depot_tools_checkout') {
        $values = [regex]::Matches($compatibility, "(?m)^\s*'$key':\s*'([^']+)'\s*,?\s*$")
        if ($values.Count -ne 1) { throw "CEF $commit has no single $key" }
        $checkouts[$key] = $values[0].Groups[1].Value
    }
    $tag = $checkouts.chromium_checkout -creplace '^refs/tags/', ''
    if ($tag -cne $selected.Chromium) { throw "CEF $commit builds Chromium $tag, not $($selected.Chromium)" }
    $chromium = Invoke-GitHub @("repos/chromium/chromium/commits/$tag", '--jq', '.sha')
    $automate = Invoke-GitHub @("repos/chromiumembedded/cef/contents/tools/automate/automate-git.py?ref=$commit", '--jq', '.sha')
    Assert-Sha 'Chromium commit' $chromium
    Assert-Sha 'depot_tools commit' $checkouts.depot_tools_checkout
    Assert-Sha 'automate-git.py blob' $automate

    # cef_rs_commit and ironrdp_commit stay: a release on the same branch keeps the CEF API.
    $pins.cef_commit = $commit
    $pins.cef_version = $selected.CefVersion
    $pins.chromium_tag = $tag
    $pins.chromium_commit = $chromium
    $pins.depot_tools_commit = $checkouts.depot_tools_checkout
    $pins.automate_git_blob = $automate
    if ($Write) {
        $json = ($pins | ConvertTo-Json) -creplace "`r`n", "`n"
        [IO.File]::WriteAllText($pinsPath, $json + "`n", [Text.UTF8Encoding]::new($false))
        Write-Host "Pinned CEF $($selected.CefVersion)"
    }
    $result.pins = $pins
}

if ($env:GITHUB_OUTPUT) {
    foreach ($key in 'pinned', 'selected', 'selected_cef_version', 'new_major') {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$key=$($result[$key])"
    }
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "update=$("$update".ToLowerInvariant())"
}
$result | ConvertTo-Json -Depth 5
