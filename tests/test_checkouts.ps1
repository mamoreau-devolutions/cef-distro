$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Split-Path $PSScriptRoot -Parent
$checkouts = Join-Path $repo 'scripts' 'checkouts.py'
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-checkouts-test-$([guid]::NewGuid())"
$chromium = Join-Path $temp 'chromium'
$src = Join-Path $chromium 'src'
$cef = Join-Path $src 'cef'
$v8 = Join-Path $src 'v8'
$record = Join-Path $temp 'record.json'
$old = [DateTime]::new(2020, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)

function New-Checkout([string]$Path, [hashtable]$Files) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    git -C $Path init --quiet
    foreach ($name in $Files.Keys) {
        New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $Path $name)) | Out-Null
        [IO.File]::WriteAllText((Join-Path $Path $name), $Files[$name])
    }
    git -C $Path add --all
    git -C $Path -c user.name=test -c user.email=test@example.invalid commit --quiet -m initial
}
function Set-Patched([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content)
    [IO.File]::SetLastWriteTimeUtc($Path, $old)
}

try {
    # src ignores its nested checkouts, as Chromium's .gitignore does.
    New-Checkout $src @{ 'base/a.h' = 'a'; 'base/b.h' = 'b'; '.gitignore' = "/cef/`n/v8/`n" }
    New-Checkout $cef @{ 'libcef/c.cc' = 'c' }
    New-Checkout $v8 @{ 'include/v8.h' = 'v8' }
    [IO.File]::WriteAllText((Join-Path $chromium '.gclient_entries'),
        "entries = {`n  'src': 'https://example.invalid/src.git',`n  'src/v8': 'https://example.invalid/v8.git',`n  'src/gone': None,`n}`n")

    # The built tree: patched files and a file a patch added, all built long ago.
    Set-Patched (Join-Path $src 'base' 'a.h') 'a patched'
    Set-Patched (Join-Path $src 'base' 'b.h') 'b patched'
    Set-Patched (Join-Path $src 'base' 'added.h') 'added'
    Set-Patched (Join-Path $cef 'libcef' 'c.cc') 'c patched'
    python $checkouts revert --tree $temp --record $record
    foreach ($check in @(
        @{ Path = (Join-Path $src 'base' 'a.h'); Content = 'a' }
        @{ Path = (Join-Path $src 'base' 'b.h'); Content = 'b' }
        @{ Path = (Join-Path $cef 'libcef' 'c.cc'); Content = 'c' }
    )) {
        if ([IO.File]::ReadAllText($check.Path) -cne $check.Content) { throw "Not reverted: $($check.Path)" }
    }
    if (Test-Path (Join-Path $src 'base' 'added.h')) { throw 'Added file was not removed' }
    foreach ($repository in @($src, $cef, $v8)) {
        if (git -C $repository status --porcelain) { throw "Checkout not clean: $repository" }
    }

    # The patches applied again: one file comes out different this time.
    [IO.File]::WriteAllText((Join-Path $src 'base' 'a.h'), 'a patched')
    [IO.File]::WriteAllText((Join-Path $src 'base' 'b.h'), 'b patched differently')
    [IO.File]::WriteAllText((Join-Path $src 'base' 'added.h'), 'added')
    [IO.File]::WriteAllText((Join-Path $cef 'libcef' 'c.cc'), 'c patched')
    python $checkouts restore --record $record
    foreach ($name in @('base/a.h', 'base/added.h')) {
        if ([IO.File]::GetLastWriteTimeUtc((Join-Path $src $name)) -ne $old) { throw "Old mtime not restored: $name" }
    }
    if ([IO.File]::GetLastWriteTimeUtc((Join-Path $cef 'libcef' 'c.cc')) -ne $old) { throw 'Old CEF mtime not restored' }
    if ([IO.File]::GetLastWriteTimeUtc((Join-Path $src 'base' 'b.h')) -eq $old) { throw 'Changed file kept its old mtime' }
    Write-Host 'Checkout revert and restore checks passed.'
} finally {
    try { Remove-Item -LiteralPath $temp -Recurse -Force } catch { Write-Warning "Could not remove ${temp}: $_" }
}
