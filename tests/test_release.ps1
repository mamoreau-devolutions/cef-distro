$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts' 'candidate.ps1')
$release = Join-Path $repo 'scripts' 'release.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-release-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null

function global:nm {
    $global:LASTEXITCODE = 0
    if (-not $global:CefTestMissingExports) {
        @(
            'cef_isolated_clipboard_enabled', 'cef_isolated_clipboard_generation',
            'cef_isolated_clipboard_read', 'cef_isolated_clipboard_write_item',
            'cef_remote_media_enabled', 'cef_remote_camera_get_format',
            'cef_remote_camera_push_frame', 'cef_remote_microphone_active',
            'cef_remote_microphone_push', 'cef_remote_microphone_reset',
            'cef_remote_webauthn_enabled', 'cef_remote_webauthn_set_handler',
            'cef_remote_webauthn_respond', 'cef_remote_webauthn_set_platform_available'
        )
    }
}
function Assert-Fails([scriptblock]$Action, [string]$Expected) {
    try { & $Action } catch {
        if ($_.Exception.Message -like "*$Expected*") { return }
        throw
    }
    throw "Expected failure containing: $Expected"
}
try {
    $build = Join-Path $temp 'build'
    $directory = Join-Path $build 'chromium' 'src' 'cef' 'binary_distrib'
    $name = "cef_binary_$($CefPins.cef_version)_linux64_minimal.tar.bz2"
    $archive = Join-Path $directory $name
    $tree = Join-Path $temp 'tree'
    $root = $name.Substring(0, $name.Length - 8)
    $library = Join-Path $tree $root 'Release' 'libcef.so'
    New-Item -ItemType Directory -Force -Path (Split-Path $library -Parent), $directory | Out-Null
    [IO.File]::WriteAllText($library, 'lib')
    & tar -cjf $archive -C $tree $root
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create fixture archive' }
    $output = Join-Path $temp 'output'
    & $release -Build $build -Output $output -Platform linux -Arch x64 -Revision ('a' * 40)
    $manifest = Get-Content -Raw -Encoding utf8 (Join-Path $output 'manifest.json') | ConvertFrom-Json -AsHashtable
    $checksum = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    if ($manifest.sha256 -cne $checksum -or $manifest.repository_commit -cne ('a' * 40) -or
        -not (Test-FlatMapEqual $manifest.patch_git_blobs $CefPatchBlobs) -or
        [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $output 'SHA256SUMS'))) -cne "$checksum  $name`n" -or
        (Get-FileHash -Algorithm SHA256 (Join-Path $output $name)).Hash.ToLowerInvariant() -cne $checksum) {
        throw 'Candidate archive, checksum or manifest differs from input'
    }
    $global:CefTestMissingExports = $true
    Assert-Fails {
        & $release -Build $build -Output (Join-Path $temp 'missing') -Platform linux -Arch x64 -Revision ('a' * 40)
    } 'Missing patched exports'
    New-Item -ItemType Directory -Force -Path (Join-Path $tree 'other' 'Release') | Out-Null
    [IO.File]::WriteAllText((Join-Path $tree 'other' 'Release' 'libcef.so'), 'lib')
    & tar -cjf $archive -C $tree 'other'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create bad fixture archive' }
    Assert-Fails {
        & $release -Build $build -Output (Join-Path $temp 'unsafe') -Platform linux -Arch x64 -Revision ('a' * 40)
    } 'unexpected top-level directory'
    Write-Host 'PowerShell candidate preparation checks passed.'
} finally {
    Remove-Item Function:\nm -ErrorAction SilentlyContinue
    Remove-Variable CefTestMissingExports -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
