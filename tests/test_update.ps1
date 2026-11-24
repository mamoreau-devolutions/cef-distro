$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts' 'candidate.ps1')
$update = Join-Path $repo 'scripts' 'update.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-update-test-$([guid]::NewGuid())"
$global:CefUpdateEvents = [Collections.Generic.List[string]]::new()
$global:CefUpdateV8 = 'a' * 40
$global:CefUpdateDependency = 'b' * 40

# A built tree from an earlier version: checkouts as directories with a .git.
$chromium = Join-Path $temp 'chromium'
$src = Join-Path $chromium 'src'
foreach ($path in @('depot_tools', 'chromium/src/cef/patch/patches', 'chromium/src/v8/.git',
        'chromium/src/third_party/moved/.git', 'chromium/src/third_party/same/.git', 'chromium/src/.git')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $temp $path) | Out-Null
}
[IO.File]::WriteAllText((Join-Path $chromium '.gclient'),
    "solutions = [{'managed': False, 'name': 'src', 'url': 'https://chromium.googlesource.com/chromium/src.git@156.0.8078.1', }]")
[IO.File]::WriteAllText((Join-Path $src 'DEPS'), "vars = { 'v8_revision': '$global:CefUpdateV8', }")
[IO.File]::WriteAllText((Join-Path $src 'cef' 'patch' 'patches' 'runhooks.patch'), 'patch')

$global:CefRealGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
function global:git {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'hash-object') { return & $global:CefRealGit @args }
    $path, $command = $args[1], $args[2]
    $name = Split-Path $path -Leaf
    switch ($command) {
        'rev-parse' {
            switch ($name) {
                'depot_tools' { return $CefPins.depot_tools_commit }
                'cef' { return $CefPins.cef_commit }
                'v8' { return $global:CefUpdateV8 }
                'same' { return $global:CefUpdateDependency }
                'moved' { return 'c' * 40 }
                default { return $CefPins.chromium_commit }
            }
        }
        'cat-file' { $global:LASTEXITCODE = 1; return $null }
        'fetch' { $global:CefUpdateEvents.Add("fetch $name$(if ($args -contains '--depth=1') { ' shallow' })") }
        'checkout' { $global:CefUpdateEvents.Add("checkout $name") }
        'apply' { if ($args -cnotcontains '--check') { $global:CefUpdateEvents.Add([IO.Path]::GetFileName($args[-1])) } }
        default { throw "Unexpected git invocation: $args" }
    }
}
function global:gclient {
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'revinfo' {
            return @(
                "src: https://chromium.googlesource.com/chromium/src.git@$($CefPins.chromium_commit)"
                "src/v8: https://chromium.googlesource.com/v8/v8.git@$global:CefUpdateV8"
                "src/third_party/moved: https://example.invalid/moved.git@$global:CefUpdateDependency"
                "src/third_party/same: https://example.invalid/same.git@$global:CefUpdateDependency"
                "src/third_party/new: https://example.invalid/new.git@$global:CefUpdateDependency"
                'src/buildtools/linux64: gn_bucket/gn@version:1'
            )
        }
        'sync' { $global:CefUpdateEvents.Add("sync $($args[1..($args.Count - 1)] -join ' ')") }
        'runhooks' { $global:CefUpdateEvents.Add('runhooks') }
        default { throw "Unexpected gclient invocation: $args" }
    }
}
function global:python {
    $global:LASTEXITCODE = 0
    $script = [IO.Path]::GetFileName($args[0])
    switch ($script) {
        'checkouts.py' { $global:CefUpdateEvents.Add("checkouts $($args[1])") }
        'patcher.py' { $global:CefUpdateEvents.Add("patcher $([IO.Path]::GetFileName($args[2]))") }
        'gclient_hook.py' { $global:CefUpdateEvents.Add('hook') }
        default { throw "Unexpected python invocation: $args" }
    }
}
function global:Invoke-WebRequest {
    param($Uri, $TimeoutSec, $OutFile)
    [pscustomobject]@{ Content = @"
{
  'chromium_checkout': 'refs/tags/$($CefPins.chromium_tag)',
  'depot_tools_checkout': '$($CefPins.depot_tools_commit)',
}
"@ }
}
function global:cmd { $global:LASTEXITCODE = 0; $global:CefUpdateEvents.Add('bootstrap') }
function global:bash { $global:LASTEXITCODE = 0; $global:CefUpdateEvents.Add('bootstrap') }

try {
    $platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    & $update -Directory $temp -Target "$platform-x64" -Record (Join-Path $temp 'record.json')
    $expected = @(
        'checkouts revert'
        'fetch depot_tools', 'checkout depot_tools', 'bootstrap'
        'fetch cef', 'checkout cef'
        'fetch src shallow', 'checkout src'
        'fetch moved shallow'
        'sync --nohooks --no-history'
        'patcher runhooks', 'runhooks'
        'hook'
        'isolated-clipboard.patch', 'remote-devices-cef.patch'
        'remote-devices-chromium.patch', 'in-process-audio-shutdown.patch'
    )
    if ($platform -ne 'windows') { $expected += 'disable-chromium-shutdown-signals.patch' }
    $expected += 'checkouts restore', 'hook'
    if (($global:CefUpdateEvents -join ',') -cne ($expected -join ',')) {
        throw "Unexpected update sequence: $($global:CefUpdateEvents -join ',')"
    }
    $spec = [IO.File]::ReadAllText((Join-Path $chromium '.gclient'))
    if ($spec -notlike "*chromium/src.git@$($CefPins.chromium_commit)'*") { throw "Chromium not pinned by commit: $spec" }

    # A dependency that did not move with DEPS fails the update.
    $global:CefUpdateEvents.Clear()
    $global:CefUpdateV8 = 'd' * 40
    [IO.File]::WriteAllText((Join-Path $src 'DEPS'), "vars = { 'v8_revision': '$('e' * 40)', }")
    try {
        & $update -Directory $temp -Target "$platform-x64" -Record (Join-Path $temp 'record.json')
        throw 'Expected a V8 revision mismatch'
    } catch {
        if ($_.Exception.Message -notlike 'V8 is at*') { throw }
    }
    Write-Host 'In-place update checks passed.'
} finally {
    foreach ($name in @('git', 'gclient', 'python', 'Invoke-WebRequest', 'cmd', 'bash')) {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    foreach ($name in @('CefUpdateEvents', 'CefUpdateV8', 'CefUpdateDependency', 'CefRealGit')) {
        Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue
    }
    try { Remove-Item -LiteralPath $temp -Recurse -Force } catch { Write-Warning "Could not remove ${temp}: $_" }
}
