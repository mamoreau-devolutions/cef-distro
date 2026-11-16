$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows tree tests require Windows' }
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts' 'windows-tree.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-windows-tree-test-$([guid]::NewGuid())"
$source = Join-Path $temp 'source'
$restore = Join-Path $temp 'restore'
New-Item -ItemType Directory -Force -Path (Join-Path $source 'out' 'obj'), $restore | Out-Null
try {
    $file = Join-Path $source 'out' 'obj' 'a.o'
    [IO.File]::WriteAllBytes($file, [byte[]](0..255))
    $stamp = [DateTime]::new(638355968001234567, [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($file, $stamp)
    $dir = Join-Path $source 'out' 'obj'
    [IO.Directory]::SetLastWriteTimeUtc($dir, $stamp.AddTicks(10))
    New-Item -ItemType Junction -Path (Join-Path $source 'junction') -Target $dir | Out-Null
    $fileLink = Join-Path $source 'link.o'
    try {
        New-Item -ItemType SymbolicLink -Path $fileLink -Target $file -ErrorAction Stop | Out-Null
        $hasFileLink = $true
    } catch { $hasFileLink = $false }
    $stream = [IO.MemoryStream]::new()
    try {
        Write-CefWindowsTree $source $stream
        $stream.Position = 0
        Read-CefWindowsTree $stream $restore
    } finally { $stream.Dispose() }
    $copy = Join-Path $restore 'out' 'obj' 'a.o'
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($copy)) -cne [Convert]::ToHexString([IO.File]::ReadAllBytes($file)) -or
        [IO.File]::GetLastWriteTimeUtc($copy).Ticks -ne [IO.File]::GetLastWriteTimeUtc($file).Ticks -or
        [IO.Directory]::GetLastWriteTimeUtc((Join-Path $restore 'out' 'obj')).Ticks -ne [IO.Directory]::GetLastWriteTimeUtc($dir).Ticks) {
        throw 'Tree content or timestamp changed'
    }
    if (-not (Get-Item -LiteralPath (Join-Path $restore 'junction') -Force).LinkTarget) { throw 'Junction was not restored as a link' }
    if ($hasFileLink -and -not (Get-Item -LiteralPath (Join-Path $restore 'link.o') -Force).LinkTarget) {
        throw 'File link was not restored'
    }
    Write-Host 'PowerShell Windows tree streaming checks passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
