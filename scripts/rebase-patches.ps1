# Rebases the patches onto new upstream revisions, one patch at a time, in order.
#
# -Start downloads every file the patches touch at the old pins (the revisions
# the current patches apply to) and at pins.json, then for each patch:
#   - applies it unchanged when it still applies, or
#   - three-way merges its change into the new upstream file (git merge-file,
#     with the old upstream file as base), which handles most upstream drift.
# When a merge conflicts it stops with exit code 2 and leaves conflict markers
# in .rebase/<tree>/work. Resolve them so each file holds the new upstream code
# with the patch's change, then run -Continue. When every patch is in, it
# rewrites patches/*.patch, checks they apply in order to the new upstream
# files, and updates their blob identities in scripts/candidate.ps1.
param(
    [switch]$Start,
    [switch]$Continue,
    # JSON file with the pins the current patches apply to; defaults to the
    # from_pins of rebase-request.json.
    [string]$FromPins,
    [string]$Workspace,
    # With -Start: only download and prepare; -Continue then merges.
    [switch]$DownloadOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
if (-not $Workspace) { $Workspace = Join-Path $CefRoot '.rebase' }
$statePath = Join-Path $Workspace 'state.json'
$git = @('-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', '-c', 'user.name=rebase-patches',
    '-c', 'user.email=rebase-patches@localhost', '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false')

function Invoke-Git([string]$Repository, [string[]]$Arguments) {
    $output = & git @git -C $Repository @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in $Repository" }
    return $output
}

function Save-Stage([string]$Repository, [string]$Tag, [string]$Message) {
    Invoke-Git $Repository @('add', '-A') | Out-Null
    Invoke-Git $Repository @('commit', '-q', '--allow-empty', '-m', $Message) | Out-Null
    Invoke-Git $Repository @('tag', $Tag) | Out-Null
}

# Downloads the files that exist upstream; returns the paths that do not.
function Save-Files($Tree, [string]$Revision, [string[]]$Paths, [string]$Directory) {
    $missing = @()
    foreach ($path in $Paths) {
        $destination = Join-Path $Directory $path
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        try {
            Invoke-UpstreamRequest $Tree.Repository $Revision $path $destination | Out-Null
        } catch {
            if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            $missing += $path
        }
    }
    return $missing
}

# The workspace lives inside this checkout, so each directory git applies patches
# in becomes its own repository; otherwise paths would resolve against this one.
function Initialize-Directory([string]$Directory) {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory '.git'))) { Invoke-Git $Directory @('init', '-q') | Out-Null }
}

function Get-TreeState([string]$Name) { $state.trees | Where-Object name -ceq $Name }

function Save-State { $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding utf8 }

function Get-ConflictedFiles([string]$Work, [string[]]$Paths) {
    @($Paths | Where-Object {
        $file = Join-Path $Work $_
        (Test-Path -LiteralPath $file) -and
            (Select-String -LiteralPath $file -Pattern '^(<{7}|\|{7}|={7}|>{7})( |$)' -Quiet)
    })
}

function Write-Conflict($Tree, $Patch, [int]$Index) {
    $root = Join-Path $Workspace $Tree.Name
    Write-Host ''
    Write-Host "CONFLICT: $($Tree.Name) patch $Index, $($Patch.name), does not merge into the new upstream files:"
    foreach ($path in $Patch.files) { Write-Host "  .rebase/$($Tree.Name)/work/$path" }
    Write-Host ''
    Write-Host 'For each file:'
    Write-Host "  - what the patch changes: .rebase/$($Tree.Name)/old/$($Index - 1)/<path> -> .rebase/$($Tree.Name)/old/$Index/<path>"
    Write-Host "  - what upstream changed:  .rebase/$($Tree.Name)/old/0/<path> -> .rebase/$($Tree.Name)/new/<path>"
    Write-Host '  - resolve every <<<<<<< (new upstream) ||||||| (old upstream) ======= (patch) >>>>>>> block'
    Write-Host '    so the file holds the new upstream code'
    Write-Host '    with the same change the patch makes; keep upstream code the patch does not touch.'
    Write-Host 'Then run: pwsh scripts/rebase-patches.ps1 -Continue'
}

# Merges or applies every remaining patch; returns $false at the first conflict.
function Invoke-Rebase {
    foreach ($tree in $CefPatchTrees) {
        $treeState = Get-TreeState $tree.Name
        $root = Join-Path $Workspace $tree.Name
        $work = Join-Path $root 'work'
        for ($index = 1; $index -le $treeState.patches.Count; $index++) {
            $patch = $treeState.patches[$index - 1]
            if ($patch.status -cin @('unchanged', 'merged', 'resolved')) { continue }
            if ($patch.status -ceq 'conflict') {
                $left = Get-ConflictedFiles $work $patch.files
                if ($left) {
                    $patch.files = $left
                    Save-State
                    Write-Conflict $tree $patch $index
                    return $false
                }
                Save-Stage $work "stage-$index" $patch.name
                $patch.status = 'resolved'
                Save-State
                Write-Host "$($tree.Name): $($patch.name) resolved"
                continue
            }
            $file = Join-Path $CefRoot 'patches' $patch.name
            & git @git -C $work apply --check $file 2>$null
            if ($LASTEXITCODE -eq 0) {
                Invoke-Git $work @('apply', $file) | Out-Null
                Save-Stage $work "stage-$index" $patch.name
                $patch.status = 'unchanged'
                Save-State
                Write-Host "$($tree.Name): $($patch.name) applies unchanged"
                continue
            }
            $before = Join-Path $root 'old' ($index - 1)
            $after = Join-Path $root 'old' $index
            $conflicts = @()
            foreach ($path in Get-PatchedPaths @($patch.name)) {
                $base = Join-Path $before $path
                $other = Join-Path $after $path
                $current = Join-Path $work $path
                if (-not (Test-Path -LiteralPath $other)) {
                    # The patch deletes the file.
                    if ((Test-Path -LiteralPath $current) -and
                        (Get-FileHash -LiteralPath $current).Hash -ne (Get-FileHash -LiteralPath $base).Hash) {
                        $conflicts += $path
                    } else {
                        Remove-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
                    }
                    continue
                }
                if (-not (Test-Path -LiteralPath $current) -and -not (Test-Path -LiteralPath $base)) {
                    # The patch creates the file.
                    New-Item -ItemType Directory -Force -Path (Split-Path $current -Parent) | Out-Null
                    Copy-Item -LiteralPath $other -Destination $current
                    continue
                }
                $empty = Join-Path $Workspace 'empty'
                if (-not (Test-Path -LiteralPath $current)) {
                    # Upstream removed or moved a file the patch changes: merge into an empty file.
                    New-Item -ItemType Directory -Force -Path (Split-Path $current -Parent) | Out-Null
                    [IO.File]::WriteAllBytes($current, [byte[]]@())
                }
                $baseFile = if (Test-Path -LiteralPath $base) { $base } else { $empty }
                # --diff3 also shows the old upstream code, so a resolver can tell the two changes apart.
                & git @git merge-file --diff3 -L 'new upstream' -L 'old upstream' -L $patch.name $current $baseFile $other
                $code = $LASTEXITCODE
                if ($code -ge 128 -or $code -lt 0) { throw "git merge-file failed for $path" }
                if ($code -gt 0) { $conflicts += $path }
            }
            if ($conflicts) {
                $patch.status = 'conflict'
                $patch.files = $conflicts
                Save-State
                Write-Conflict $tree $patch $index
                return $false
            }
            Save-Stage $work "stage-$index" $patch.name
            $patch.status = 'merged'
            Save-State
            Write-Host "$($tree.Name): $($patch.name) merged into the new upstream files"
        }
    }
    return $true
}

function Complete-Rebase {
    foreach ($tree in $CefPatchTrees) {
        $treeState = Get-TreeState $tree.Name
        $work = Join-Path $Workspace $tree.Name 'work'
        for ($index = 1; $index -le $treeState.patches.Count; $index++) {
            $patch = $treeState.patches[$index - 1]
            if ($patch.status -ceq 'unchanged') { continue }
            $output = Join-Path $CefRoot 'patches' $patch.name
            Invoke-Git $work @('diff', '--no-color', '--no-ext-diff', '--no-renames', '--abbrev=10',
                "--output=$output", "stage-$($index - 1)", "stage-$index") | Out-Null
        }
        # The rewritten patches must apply in order to the untouched new upstream files.
        $verify = Join-Path $Workspace "$($tree.Name)-verify"
        Remove-Item -LiteralPath $verify -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $Workspace $tree.Name 'new') -Destination $verify -Recurse
        Initialize-Directory $verify
        foreach ($name in $tree.Patches) {
            & git @git -C $verify apply (Join-Path $CefRoot 'patches' $name)
            if ($LASTEXITCODE -ne 0) { throw "Rewritten $name does not apply to the new upstream files" }
        }
    }
    # Record the new blob identities; check-patches.ps1 and release manifests compare them.
    Update-PatchBlobs
    Write-Host ''
    Write-Host 'All patches are rebased onto pins.json:'
    foreach ($treeState in $state.trees) {
        foreach ($patch in $treeState.patches) { Write-Host "  $($treeState.name): $($patch.name): $($patch.status)" }
    }
}

if ($Start -eq $Continue) { throw 'Pass -Start or -Continue' }
if ($Start) {
    if (Test-Path -LiteralPath $Workspace) { throw "$Workspace exists; remove it to start over" }
    $from = if ($FromPins) {
        Get-Content -Raw -Encoding utf8 -LiteralPath $FromPins | ConvertFrom-Json -AsHashtable
    } else {
        (Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $CefRoot 'rebase-request.json') | ConvertFrom-Json -AsHashtable).from_pins
    }
    Assert-PatchIdentity
    New-Item -ItemType Directory -Path $Workspace | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $Workspace 'empty'), [byte[]]@())
    $state = [ordered]@{ from = $from; trees = @() }
    foreach ($tree in $CefPatchTrees) {
        $root = Join-Path $Workspace $tree.Name
        $old = Join-Path $root 'old' '0'
        $work = Join-Path $root 'work'
        $existing = Get-PatchedPaths $tree.Patches -Existing
        $gone = Save-Files $tree $from[$tree.RevisionPin] $existing $old
        if ($gone) { throw "The current patches change files missing at the old pins: $($gone -join ', ')" }
        $missing = Save-Files $tree $CefPins[$tree.RevisionPin] $existing (Join-Path $root 'new')
        if ($missing) { Write-Warning "$($tree.Name): upstream no longer has $($missing -join ', ')" }
        Copy-Item -LiteralPath (Join-Path $root 'new') -Destination $work -Recurse
        Invoke-Git $work @('init', '-q') | Out-Null
        Save-Stage $work 'stage-0' "upstream $($CefPins[$tree.RevisionPin])"
        # Old stages: the old upstream files after each patch, for the merge base and its change.
        for ($index = 1; $index -le $tree.Patches.Count; $index++) {
            $stage = Join-Path $root 'old' $index
            Copy-Item -LiteralPath (Join-Path $root 'old' ($index - 1)) -Destination $stage -Recurse
            Initialize-Directory $stage
            & git @git -C $stage apply (Join-Path $CefRoot 'patches' $tree.Patches[$index - 1])
            if ($LASTEXITCODE -ne 0) { throw "$($tree.Patches[$index - 1]) does not apply at the old pins" }
        }
        $state.trees += [ordered]@{
            name = $tree.Name
            patches = @($tree.Patches | ForEach-Object { [ordered]@{ name = $_; status = 'pending'; files = @() } })
        }
    }
    Save-State
    if ($DownloadOnly) { exit 0 }
    $state = Get-Content -Raw -Encoding utf8 -LiteralPath $statePath | ConvertFrom-Json
} else {
    if (-not (Test-Path -LiteralPath $statePath)) { throw "No rebase in progress in $Workspace" }
    $state = Get-Content -Raw -Encoding utf8 -LiteralPath $statePath | ConvertFrom-Json
}

if (-not (Invoke-Rebase)) { exit 2 }
Complete-Rebase
exit 0
