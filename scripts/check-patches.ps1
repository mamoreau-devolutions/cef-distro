$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
Assert-PatchIdentity

$compatibilityUrl = "https://raw.githubusercontent.com/chromiumembedded/cef/$($CefPins.cef_commit)/CHROMIUM_BUILD_COMPATIBILITY.txt"
$compatibility = (Invoke-WebRequest -Uri $compatibilityUrl -TimeoutSec 60).Content
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
            Invoke-WebRequest -Uri $url -TimeoutSec 60 -OutFile $destination
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
