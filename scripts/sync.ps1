param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidateSet('linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64')][string]$Target
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
. (Join-Path $PSScriptRoot 'build-env.ps1')
Assert-PatchIdentity
if (Test-Path -LiteralPath $Directory) { throw "Build directory must not already exist: $Directory" }
Assert-CefCompatibility
New-Item -ItemType Directory -Path $Directory | Out-Null
$Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
Set-CefBuildEnvironment $Directory $Target
$arch = $Target.Split('-')[1]
$automate = Join-Path $Directory 'automate-git.py'
$url = "https://raw.githubusercontent.com/chromiumembedded/cef/$($CefPins.cef_commit)/tools/automate/automate-git.py"
Invoke-WebRequest -Uri $url -TimeoutSec 60 -OutFile $automate
$actualBlob = & git hash-object --no-filters -- $automate
if ($LASTEXITCODE -ne 0 -or $actualBlob -cne $CefPins.automate_git_blob) {
    throw 'Pinned automate-git.py blob does not match'
}
$depotTools = Join-Path $Directory 'depot_tools'
& git clone --quiet https://chromium.googlesource.com/chromium/tools/depot_tools.git $depotTools
if ($LASTEXITCODE -ne 0) { throw 'Cloning depot_tools failed' }
& git -C $depotTools checkout --quiet $CefPins.depot_tools_commit
if ($LASTEXITCODE -ne 0) { throw 'Checking out depot_tools failed' }
Push-Location $depotTools
try {
    if ($IsWindows) {
        & cmd /c (Join-Path $depotTools 'bootstrap' 'win_tools.bat')
    } else {
        & bash (Join-Path $depotTools 'ensure_bootstrap')
    }
    if ($LASTEXITCODE -ne 0) { throw "depot_tools bootstrap failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}
& python $automate --download-dir $Directory --branch $CefPins.cef_branch --checkout $CefPins.cef_commit `
    --no-depot-tools-update --no-chromium-history "--$arch-build" --no-build --no-distrib
if ($LASTEXITCODE -ne 0) { throw "CEF synchronization failed: $LASTEXITCODE" }
$src = Join-Path $Directory 'chromium' 'src'
$cef = Join-Path $src 'cef'
foreach ($checkout in @(
    @{ Name = 'CEF'; Path = $cef; Expected = $CefPins.cef_commit }
    @{ Name = 'Chromium'; Path = $src; Expected = $CefPins.chromium_commit }
    @{ Name = 'depot_tools'; Path = $depotTools; Expected = $CefPins.depot_tools_commit }
)) {
    $head = & git -C $checkout.Path rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -cne $checkout.Expected) {
        throw "Unexpected $($checkout.Name) checkout: $head"
    }
}
$trees = @(
    @{ Path = $cef; Patches = @('isolated-clipboard.patch', 'remote-devices-cef.patch') }
    @{ Path = $src; Patches = @('remote-devices-chromium.patch', 'in-process-audio-shutdown.patch') }
)
if (-not $IsWindows) { $trees[1].Patches += 'disable-chromium-shutdown-signals.patch' }
foreach ($tree in $trees) {
    foreach ($name in $tree.Patches) {
        $patch = Join-Path $CefRoot 'patches' $name
        & git -C $tree.Path apply --check $patch
        if ($LASTEXITCODE -ne 0) { throw "Patch check failed: $name" }
        & git -C $tree.Path apply $patch
        if ($LASTEXITCODE -ne 0) { throw "Patch application failed: $name" }
    }
}
Push-Location $cef
try {
    & python tools/gclient_hook.py
    if ($LASTEXITCODE -ne 0) { throw "CEF build generation failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}
