$CefRoot = Split-Path $PSScriptRoot -Parent
$CefPins = Get-Content -Raw -Encoding utf8 (Join-Path $CefRoot 'pins.json') | ConvertFrom-Json -AsHashtable
$CefPatchBlobs = [ordered]@{
    'isolated-clipboard.patch' = 'ffb4fca9488c0851a0e4b6d6851dc79b3a33c14b'
    'remote-devices-cef.patch' = '2febae6e2f9c88d4565c87146f9950732f795b24'
    'remote-devices-chromium.patch' = 'c4a158a7c6108c8316e5111eb1ea7415abeac830'
    'in-process-audio-shutdown.patch' = 'ac5215315c4e8439d88474989f245f2750c43116'
    'disable-chromium-shutdown-signals.patch' = 'bd49755a5de794d2b7b16e865b00b2332611f770'
}

function Assert-PatchIdentity {
    foreach ($name in $CefPatchBlobs.Keys) {
        $actual = & git hash-object --no-filters -- (Join-Path $CefRoot 'patches' $name)
        if ($LASTEXITCODE -ne 0) { throw "Cannot hash patch: $name" }
        if ($actual -cne $CefPatchBlobs[$name]) { throw "Patch differs from recorded blob: $name" }
    }
}

function Assert-CefCompatibility {
    $url = "https://raw.githubusercontent.com/chromiumembedded/cef/$($CefPins.cef_commit)/CHROMIUM_BUILD_COMPATIBILITY.txt"
    $compatibility = (Invoke-WebRequest -Uri $url -TimeoutSec 60).Content
    foreach ($item in @(
        @('chromium_checkout', "refs/tags/$($CefPins.chromium_tag)"),
        @('depot_tools_checkout', $CefPins.depot_tools_commit)
    )) {
        $pattern = "(?m)^\s*'$($item[0])':\s*'([^']+)'\s*,?\s*$"
        $values = [regex]::Matches($compatibility, $pattern)
        if ($values.Count -ne 1 -or $values[0].Groups[1].Value -cne $item[1]) {
            throw "CEF compatibility mismatch: $($item[0])"
        }
    }
}

function Test-FlatMapEqual($Actual, $Expected) {
    if ($null -eq $Actual -or $Actual.Count -ne $Expected.Count) { return $false }
    foreach ($key in $Expected.Keys) {
        if ($Actual.Keys -cnotcontains $key -or $Actual[$key] -isnot [string] -or
            $Actual[$key] -cne $Expected[$key]) { return $false }
    }
    return $true
}

function Get-VerifiedCandidate([string]$Directory, [string]$Target) {
    $manifestPath = Join-Path $Directory 'manifest.json'
    $manifest = Get-Content -Raw -Encoding utf8 -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
    $platform, $arch = $Target.Split('-')
    if ($manifest.platform -cne $platform -or $manifest.architecture -cne $arch) {
        throw "${Directory}: manifest is not for $Target"
    }
    if (-not (Test-FlatMapEqual $manifest.pins $CefPins) -or
        -not (Test-FlatMapEqual $manifest.patch_git_blobs $CefPatchBlobs)) {
        throw "${Directory}: built from different pins or patches than this checkout"
    }
    $archive = Join-Path $Directory $manifest.archive
    $checksum = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($checksum -cne $manifest.sha256) { throw "${archive}: checksum does not match manifest" }
    return [pscustomobject]@{ Manifest = $manifest; Archive = $archive; ManifestPath = $manifestPath }
}
