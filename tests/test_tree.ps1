$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tree = Join-Path $repo 'scripts' 'tree.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-tree-test-$([guid]::NewGuid())"
$source = Join-Path $temp 'source'
$parts = Join-Path $temp 'parts'
$restored = Join-Path $temp 'restored'
New-Item -ItemType Directory -Force -Path (Join-Path $source 'out') | Out-Null
try {
    $file = Join-Path $source 'out' 'input.o'
    $bytes = [byte[]]::new(8192)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    [IO.File]::WriteAllBytes($file, $bytes)
    [IO.File]::WriteAllBytes((Join-Path $source 'empty'), [byte[]]@())
    $deep = $source
    for ($i = 0; $i -lt 15; $i++) { $deep = Join-Path $deep ('directory_component_{0:D2}' -f $i) }
    New-Item -ItemType Directory -Force -Path $deep | Out-Null
    [IO.File]::WriteAllText((Join-Path $deep 'file.txt'), 'deep')
    if ($IsWindows) {
        New-Item -ItemType HardLink -Path (Join-Path $source 'hard.o') -Target $file | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $source 'junction') -Target (Join-Path $source 'out') | Out-Null
    }
    $stamp = [DateTime]::new(638355968001234567, [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($file, $stamp)
    if ($IsLinux) {
        & touch -d '@1700000000.123456789' $file
        if ($LASTEXITCODE -ne 0) { throw 'Cannot set nanosecond test timestamp' }
        $nanoseconds = & stat -c '%y' $file
        if ($LASTEXITCODE -ne 0 -or $nanoseconds -notlike '*.123456789 *') { throw 'Nanosecond test timestamp was not set' }
    }
    $link = Join-Path $source 'link.o'
    $hasLink = $false
    try {
        New-Item -ItemType SymbolicLink -Path $link -Target 'out/input.o' -ErrorAction Stop | Out-Null
        $hasLink = $true
    } catch { }
    & $tree -Mode pack -Directory $source -Output $parts -PartSize 1024
    if (@(Get-ChildItem -LiteralPath $parts -File).Count -lt 2) { throw 'Tree was not split' }
    & $tree -Mode unpack -Directory $restored -Parts $parts
    $copy = Join-Path $restored 'out' 'input.o'
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($copy)) -cne [Convert]::ToHexString($bytes) -or
        [IO.File]::GetLastWriteTimeUtc($copy).Ticks -ne [IO.File]::GetLastWriteTimeUtc($file).Ticks -or
        @(Get-ChildItem -LiteralPath $parts -File).Count -ne 0) {
        throw 'Restored tree, timestamp or parts differ'
    }
    if ($hasLink -and -not (Get-Item -LiteralPath (Join-Path $restored 'link.o') -Force).LinkTarget) {
        throw 'File link was not restored'
    }
    if ($IsLinux -and (& stat -c '%y' $copy) -cne $nanoseconds) { throw 'Nanosecond timestamp changed' }
    if (-not (Test-Path -LiteralPath (Join-Path $restored 'empty')) -or
        (Get-Item -LiteralPath (Join-Path $restored 'empty')).Length -ne 0) { throw 'Empty file was not restored' }
    $deepCopy = Join-Path $restored ([IO.Path]::GetRelativePath($source, (Join-Path $deep 'file.txt')))
    if ([IO.File]::ReadAllText($deepCopy) -cne 'deep') { throw 'Deep path was not restored' }
    $legacy = Join-Path $repo 'scripts' 'cef.py'
    $parts = Join-Path $temp 'legacy-parts'
    & python $legacy pack --directory $source --output $parts --part-size 1024
    if ($LASTEXITCODE -ne 0) { throw 'Legacy tree packing failed' }
    $legacyRestored = Join-Path $temp 'legacy-restored'
    & $tree -Mode unpack -Directory $legacyRestored -Parts $parts
    $legacyCopy = Join-Path $legacyRestored 'out' 'input.o'
    if ([IO.File]::GetLastWriteTimeUtc($legacyCopy).Ticks -ne [IO.File]::GetLastWriteTimeUtc($file).Ticks -or
        [Convert]::ToHexString([IO.File]::ReadAllBytes($legacyCopy)) -cne [Convert]::ToHexString($bytes)) {
        throw 'PowerShell did not restore the legacy tree'
    }
    if ($IsWindows -and
        (-not (Get-Item -LiteralPath (Join-Path $legacyRestored 'junction') -Force).LinkTarget -or
         [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $legacyRestored 'hard.o'))) -cne [Convert]::ToHexString($bytes))) {
        throw 'PowerShell did not restore legacy junction or hard link'
    }
    $parts = Join-Path $temp 'reverse-parts'
    & $tree -Mode pack -Directory $source -Output $parts -PartSize 1024
    $reverse = Join-Path $temp 'legacy-reader'
    & python $legacy unpack --directory $reverse --parts $parts
    if ($LASTEXITCODE -ne 0) { throw 'Legacy tree unpacking failed' }
    $reverseCopy = Join-Path $reverse 'out' 'input.o'
    if ([IO.File]::GetLastWriteTimeUtc($reverseCopy).Ticks -ne [IO.File]::GetLastWriteTimeUtc($file).Ticks -or
        [Convert]::ToHexString([IO.File]::ReadAllBytes($reverseCopy)) -cne [Convert]::ToHexString($bytes)) {
        throw 'Legacy reader did not restore the PowerShell tree'
    }
    Write-Host 'PowerShell compressed tree round-trip checks passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
