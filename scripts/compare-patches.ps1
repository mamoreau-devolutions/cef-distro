# Checks that rebased patches still touch exactly the files they touched at
# BaseRef, and writes a Markdown summary of how each patch changed.
param(
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$Summary
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-compare-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null
$lines = @('| Patch | Files | Change |', '| --- | --- | --- |')
$problems = @()
try {
    foreach ($tree in $CefPatchTrees) {
        foreach ($name in $tree.Patches) {
            $old = Join-Path $temp $name
            $content = & git show "${BaseRef}:patches/$name"
            if ($LASTEXITCODE -ne 0) { throw "Cannot read patches/$name at $BaseRef" }
            [IO.File]::WriteAllLines($old, [string[]]$content)
            $paths = { param($file) @(Get-Content -LiteralPath $file | ForEach-Object {
                if ($_ -cmatch '^(?:---|\+\+\+) [ab]/(.+)$') { $Matches[1] } } | Sort-Object -Unique) }
            $before = & $paths $old
            $after = & $paths (Join-Path $CefRoot 'patches' $name)
            $added = @($after | Where-Object { $_ -cnotin $before })
            $dropped = @($before | Where-Object { $_ -cnotin $after })
            if ($added -or $dropped) {
                $problems += "$name now touches different files (added: $($added -join ', '); dropped: $($dropped -join ', '))"
            }
            & git diff --quiet $BaseRef -- "patches/$name"
            $change = if ($LASTEXITCODE -eq 0) { 'unchanged' } else {
                $stat = (& git diff --numstat $BaseRef -- "patches/$name") -split '\s+'
                "rebased (+$($stat[0]) / -$($stat[1]) patch lines)"
            }
            $lines += "| ``$name`` | $($after.Count) | $change |"
        }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($Summary) { [IO.File]::WriteAllLines($Summary, [string[]]$lines) } else { $lines | Write-Host }
if ($problems) { throw ($problems -join "`n") }
Write-Host 'Every patch touches the same files as before.'
