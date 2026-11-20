$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
Assert-PatchIdentity

Assert-CefCompatibility

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("cef-patch-check-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $trees = @(
        @{
            Name = 'cef'; Repository = 'chromiumembedded/cef'; Revision = $CefPins.cef_commit
            Patches = @('isolated-clipboard.patch', 'remote-devices-cef.patch')
        },
        @{
            Name = 'chromium'; Repository = 'chromium/chromium'; Revision = $CefPins.chromium_commit
            Patches = @('remote-devices-chromium.patch', 'in-process-audio-shutdown.patch', 'disable-chromium-shutdown-signals.patch')
        }
    )
    foreach ($tree in $trees) {
        $directory = Join-Path $temp $tree.Name
        New-Item -ItemType Directory -Path $directory | Out-Null
        $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($name in $tree.Patches) {
            $patch = Join-Path $CefRoot 'patches' $name
            foreach ($line in Get-Content -Encoding utf8 -LiteralPath $patch) {
                if ($line -cmatch '^--- a/(.+)$') { [void]$paths.Add($Matches[1]) }
            }
        }
        foreach ($path in $paths) {
            $destination = Join-Path $directory $path
            New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
            $url = "https://raw.githubusercontent.com/$($tree.Repository)/$($tree.Revision)/$path"
            Invoke-UpstreamRequest $url $destination | Out-Null
        }
        foreach ($name in $tree.Patches) {
            $patch = Join-Path $CefRoot 'patches' $name
            & git -C $directory apply --check $patch
            if ($LASTEXITCODE -ne 0) { throw "Patch check failed: $name" }
            & git -C $directory apply $patch
            if ($LASTEXITCODE -ne 0) { throw "Patch application failed: $name" }
        }
    }
    Write-Host 'All patches apply in order to the pinned upstream files.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
