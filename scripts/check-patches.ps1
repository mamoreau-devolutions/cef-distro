$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
Assert-PatchIdentity

Assert-CefCompatibility

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("cef-patch-check-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    foreach ($tree in $CefPatchTrees) {
        $directory = Join-Path $temp $tree.Name
        New-Item -ItemType Directory -Path $directory | Out-Null
        Save-UpstreamFiles $tree $CefPins[$tree.RevisionPin] (Get-PatchedPaths $tree.Patches -Existing) $directory
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
