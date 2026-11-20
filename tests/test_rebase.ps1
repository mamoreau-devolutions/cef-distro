# Rebases the patches from the pinned upstream files onto themselves: every
# patch must apply unchanged and nothing in the checkout may change. Needs
# network access (and GH_TOKEN in CI) for the upstream files.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-rebase-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $before = & git -C $repo status --porcelain -- patches scripts/candidate.ps1 pins.json
    & pwsh -NoProfile -File (Join-Path $repo 'scripts' 'rebase-patches.ps1') -Start `
        -FromPins (Join-Path $repo 'pins.json') -Workspace (Join-Path $temp 'rebase')
    if ($LASTEXITCODE -ne 0) { throw "rebase-patches.ps1 exited with $LASTEXITCODE" }
    $state = Get-Content -Raw (Join-Path $temp 'rebase' 'state.json') | ConvertFrom-Json
    $changed = @($state.trees.patches | Where-Object status -cne 'unchanged')
    if ($changed) { throw "Patches did not apply unchanged: $($changed.name -join ', ')" }
    $after = & git -C $repo status --porcelain -- patches scripts/candidate.ps1 pins.json
    if ("$before" -cne "$after") { throw 'Rebasing onto the same pins changed the checkout' }
    Write-Host 'rebase tests passed'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
