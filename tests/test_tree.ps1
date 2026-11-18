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
    if (@(Get-ChildItem -LiteralPath $parts -Filter 'tree.tar.zst.*' -File).Count -lt 2) { throw 'Tree was not split' }
    if (-not (Test-Path -LiteralPath (Join-Path $parts 'tree.sha256'))) { throw 'Packed tree has no checksums' }

    # A part that changes after packing must fail before extraction starts.
    $corrupt = Join-Path $temp 'corrupt-parts'
    Copy-Item -LiteralPath $parts -Destination $corrupt -Recurse
    $victim = Join-Path $corrupt 'tree.tar.zst.0001'
    $data = [IO.File]::ReadAllBytes($victim)
    $data[0] = $data[0] -bxor 0xff
    [IO.File]::WriteAllBytes($victim, $data)
    $rejected = $false
    try { & $tree -Mode unpack -Directory (Join-Path $temp 'corrupt-restored') -Parts $corrupt }
    catch { $rejected = "$_" -like 'Downloaded tree parts are corrupt: tree.tar.zst.0001 *' }
    if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $temp 'corrupt-restored'))) { throw 'Corrupt part was not rejected' }

    # Trees saved before checksums existed still restore.
    $legacy = Join-Path $temp 'legacy-parts'
    Copy-Item -LiteralPath $parts -Destination $legacy -Recurse
    Remove-Item -LiteralPath (Join-Path $legacy 'tree.sha256')
    & $tree -Mode unpack -Directory (Join-Path $temp 'legacy-restored') -Parts $legacy
    $legacyCopy = [IO.File]::ReadAllBytes((Join-Path $temp 'legacy-restored' 'out' 'input.o'))
    if ([Convert]::ToHexString($legacyCopy) -cne [Convert]::ToHexString($bytes)) { throw 'Legacy tree did not restore' }

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
    $whole = Join-Path $temp 'whole-parts'
    & $tree -Mode pack -Directory $source -Output $whole
    if (@(Get-ChildItem -LiteralPath $whole -Filter 'tree.tar.zst.*' -File).Count -ne 1) { throw 'Default part size did not produce one part' }
    Write-Host 'PowerShell compressed tree round-trip checks passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
