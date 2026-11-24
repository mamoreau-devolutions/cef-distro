# Moves a finished build tree from an earlier build to the pinned versions in
# place, so that ninja rebuilds only what the update changed. It follows the
# same steps as a fresh sync (sync.ps1 and automate-git.py), on top of the
# existing checkouts and build output.
param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidateSet('linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64')][string]$Target,
    [string]$Record = (Join-Path ([IO.Path]::GetTempPath()) 'cef-update-reverted.json')
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'candidate.ps1')
. (Join-Path $PSScriptRoot 'build-env.ps1')
Assert-PatchIdentity
Assert-CefCompatibility
$Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
Set-CefBuildEnvironment $Directory $Target
$chromium = Join-Path $Directory 'chromium'
$src = Join-Path $chromium 'src'
$cef = Join-Path $src 'cef'
$depotTools = Join-Path $Directory 'depot_tools'
$checkouts = Join-Path $PSScriptRoot 'checkouts.py'

function Step([string]$Name, [scriptblock]$Action) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "::group::$Name"
    try { & $Action } finally {
        Write-Host '::endgroup::'
        Write-Host ('{0}: {1:N1} min' -f $Name, $watch.Elapsed.TotalMinutes)
    }
}

# gclient fetches a checkout's whole history whenever its pinned revision is
# missing, which the shallow Chromium checkouts cannot take (the server gives up
# after half an hour), so each revision is fetched alone first.
function Get-Shallow([string]$Repo, [string]$Revision) {
    $PSNativeCommandUseErrorActionPreference = $false
    $present = git -C $Repo cat-file -t "$Revision^{commit}" 2>$null
    $PSNativeCommandUseErrorActionPreference = $true
    if ($present -ne 'commit') {
        git -C $Repo fetch --quiet --depth=1 --no-tags origin $Revision
    }
}

# automate-git.py applies a patch named after a file only when CEF has one.
function Install-NamedPatch([string]$Name) {
    $patch = Join-Path $cef 'patch' 'patches' $Name
    if (Test-Path -LiteralPath "$patch.patch") {
        python (Join-Path $cef 'tools' 'patcher.py') --patch-file $patch --patch-dir $src
    }
}

function Invoke-GclientHook {
    Push-Location $cef
    try { python tools/gclient_hook.py } finally { Pop-Location }
}

$before = @{ CEF = (git -C $cef rev-parse HEAD); Chromium = (git -C $src rev-parse HEAD) }
Write-Host "Updating CEF $($before.CEF) and Chromium $($before.Chromium) to CEF $($CefPins.cef_version)"

Step 'Record and revert local changes' { python $checkouts revert --tree $Directory --record $Record }
Step 'Move depot_tools' {
    git -C $depotTools fetch --quiet origin
    git -C $depotTools checkout --quiet $CefPins.depot_tools_commit
    Push-Location $depotTools
    try {
        if ($IsWindows) { cmd /c (Join-Path $depotTools 'bootstrap' 'win_tools.bat') }
        else { bash (Join-Path $depotTools 'ensure_bootstrap') }
    } finally { Pop-Location }
}
Step 'Move CEF' {
    git -C $cef fetch --quiet origin
    git -C $cef checkout --quiet $CefPins.cef_commit
}
Step 'Move Chromium and its dependencies' {
    # Pin src by commit: a tag that is not present locally would make gclient
    # fetch the whole history.
    $gclient = Join-Path $chromium '.gclient'
    $spec = Get-Content -Raw -LiteralPath $gclient
    $updated = $spec -replace '(chromium/src\.git@)[0-9a-f.]+', "`${1}$($CefPins.chromium_commit)"
    if ($updated -notmatch [regex]::Escape("chromium/src.git@$($CefPins.chromium_commit)")) {
        throw "No Chromium revision found in .gclient: $spec"
    }
    Set-Content -NoNewline -LiteralPath $gclient -Value $updated
    Get-Shallow $src $CefPins.chromium_commit
    git -C $src checkout --quiet $CefPins.chromium_commit
    Install-NamedPatch 'DEPS'
    Push-Location $chromium
    try {
        $fetched = 0
        foreach ($line in (gclient revinfo)) {
            if ($line -notmatch '^(\S+): \S+@([0-9a-f]{40})$') { continue }
            $repo = Join-Path $chromium $Matches[1]
            if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { continue }
            if ((git -C $repo rev-parse HEAD) -ceq $Matches[2]) { continue }
            Get-Shallow $repo $Matches[2]
            $fetched++
        }
        Write-Host "Fetched new revisions of $fetched dependencies"
        gclient sync --nohooks --no-history
    } finally { Pop-Location }
}
Step 'Run hooks' {
    Install-NamedPatch 'runhooks'
    Push-Location $chromium
    try { gclient runhooks } finally { Pop-Location }
}
Step 'Apply CEF patches' { Invoke-GclientHook }
Step 'Apply distribution patches' { Install-DistroPatches $src $cef }
Step 'Restore mtimes of unchanged files' { python $checkouts restore --record $Record }
Step 'Generate build files' { Invoke-GclientHook }

foreach ($checkout in @(
    @{ Name = 'CEF'; Path = $cef; Expected = $CefPins.cef_commit }
    @{ Name = 'Chromium'; Path = $src; Expected = $CefPins.chromium_commit }
    @{ Name = 'depot_tools'; Path = $depotTools; Expected = $CefPins.depot_tools_commit }
)) {
    $head = git -C $checkout.Path rev-parse HEAD
    if ($head -cne $checkout.Expected) { throw "Unexpected $($checkout.Name) checkout: $head" }
}
# A dependency whose DEPS revision moved must have moved with it.
$v8 = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $src 'DEPS')), "'v8_revision':\s*'([0-9a-f]{40})'").Groups[1].Value
$v8Head = git -C (Join-Path $src 'v8') rev-parse HEAD
if ($v8Head -cne $v8) { throw "V8 is at $v8Head, not $v8 from DEPS" }
Write-Host "Updated the tree to CEF $($CefPins.cef_commit) and Chromium $($CefPins.chromium_commit)"
