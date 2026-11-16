$ErrorActionPreference = 'Stop'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("cef-publish-test-" + [guid]::NewGuid())
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts' 'candidate.ps1')
New-Item -ItemType Directory -Path $root | Out-Null

function New-TestCandidate([string]$Source, [string]$Target) {
    $directory = Join-Path $Source "candidate-$Target"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $archive = Join-Path $directory "cef_binary_${Target}_minimal.tar.bz2"
    [System.IO.File]::WriteAllText($archive, $Target)
    $platform, $arch = $Target.Split('-')
    $manifest = @{
        platform = $platform; architecture = $arch; archive = [System.IO.Path]::GetFileName($archive)
        sha256 = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
        pins = $CefPins; patch_git_blobs = $CefPatchBlobs; repository_commit = 'a' * 40
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 (Join-Path $directory 'manifest.json')
    return $archive
}

function Assert-Fails([scriptblock]$Action, [string]$Expected) {
    try { & $Action } catch {
        if ($_.Exception.Message -like "*$Expected*") { return }
        throw
    }
    throw "Expected failure containing: $Expected"
}

try {
    $first = Join-Path $root 'run1'
    $second = Join-Path $root 'run2'
    $archive = New-TestCandidate $first 'linux-x64'
    $other = New-TestCandidate $second 'windows-x64'
    Assert-Fails {
        Get-VerifiedCandidate (Join-Path $second 'candidate-windows-x64') 'linux-x64'
    } 'manifest is not for'
    $expectedBlob = $CefPatchBlobs['isolated-clipboard.patch']
    try {
        $CefPatchBlobs['isolated-clipboard.patch'] = '0' * 40
        Assert-Fails { Assert-PatchIdentity } 'Patch differs from recorded blob'
    } finally {
        $CefPatchBlobs['isolated-clipboard.patch'] = $expectedBlob
    }
    $proofs = Join-Path $root 'proofs'
    foreach ($pair in @(@('linux-x64', $archive), @('windows-x64', $other))) {
        $directory = Join-Path $proofs "native-smoke-$($pair[0])"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        (Get-FileHash -Algorithm SHA256 $pair[1]).Hash.ToLowerInvariant() |
            Set-Content -Encoding ascii (Join-Path $directory 'archive.sha256')
    }
    $publish = Join-Path $repo 'scripts' 'publish.ps1'
    & $publish -Source @($first, $second) -Targets '["linux-x64","windows-x64"]' `
        -SmokeProofs $proofs -Output (Join-Path $root 'out')
    $sums = Get-Content (Join-Path $root 'out' 'SHA256SUMS')
    if ($sums.Count -ne 2 -or $sums[0] -cne "$((Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant())  $([System.IO.Path]::GetFileName($archive))") {
        throw 'Incorrect assembled checksums'
    }
    Assert-Fails {
        & $publish -Source @($first) -Targets '["linux-x64"]' -SmokeProofs (Join-Path $root 'missing') -Output (Join-Path $root 'missing-proof')
    } 'Cannot find path'
    Set-Content -Encoding ascii (Join-Path $proofs 'native-smoke-linux-x64' 'archive.sha256') ('0' * 64)
    Assert-Fails {
        & $publish -Source @($first) -Targets '["linux-x64"]' -SmokeProofs $proofs -Output (Join-Path $root 'bad-proof')
    } 'native smoke tested a different archive'
    [System.IO.File]::WriteAllText($archive, 'corrupted')
    Assert-Fails {
        & $publish -Source @($first) -Targets '["linux-x64"]' -Output (Join-Path $root 'bad-archive')
    } 'checksum does not match manifest'
    $manifestPath = Join-Path $second 'candidate-windows-x64' 'manifest.json'
    $manifest = Get-Content -Raw -Encoding utf8 $manifestPath | ConvertFrom-Json -AsHashtable
    $manifest.pins.cef_commit = '0' * 40
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $manifestPath
    Assert-Fails {
        & $publish -Source @($second) -Targets '["windows-x64"]' -Output (Join-Path $root 'bad-pins')
    } 'different pins or patches'
    $manifest.pins.cef_commit = $CefPins.cef_commit
    $manifest.pins.cef_branch = 8078
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $manifestPath
    Assert-Fails {
        & $publish -Source @($second) -Targets '["windows-x64"]' -Output (Join-Path $root 'bad-pin-type')
    } 'different pins or patches'
    Write-Host 'PowerShell candidate assembly checks passed.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
