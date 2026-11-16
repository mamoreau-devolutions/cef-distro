$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts' 'candidate.ps1')
$sync = Join-Path $repo 'scripts' 'sync.ps1'
$realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-sync-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null
$global:CefSyncEvents = [Collections.Generic.List[string]]::new()

function global:git {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'hash-object') {
        if ($args[-1] -like '*automate-git.py') { return $CefPins.automate_git_blob }
        & $realGit @args
    } elseif ($args[0] -eq 'clone') {
        New-Item -ItemType Directory -Force -Path $args[-1] | Out-Null
        $global:CefSyncEvents.Add('clone')
    } elseif ($args[2] -eq 'rev-parse') {
        if ($args[1] -like '*depot_tools') { return $CefPins.depot_tools_commit }
        if ($args[1] -like '*cef') { return $CefPins.cef_commit }
        return $CefPins.chromium_commit
    } elseif ($args[2] -eq 'apply') {
        if ($args -cnotcontains '--check') { $global:CefSyncEvents.Add([IO.Path]::GetFileName($args[-1])) }
    } elseif ($args[2] -eq 'checkout') {
        $global:CefSyncEvents.Add('checkout')
    } else { throw "Unexpected git invocation: $args" }
}
function global:Invoke-WebRequest {
    param($Uri, $TimeoutSec, $OutFile)
    if ($OutFile) {
        [IO.File]::WriteAllText($OutFile, 'mock automate script')
    } else {
        [pscustomobject]@{ Content = @"
{
  'chromium_checkout': 'refs/tags/$($CefPins.chromium_tag)',
  'depot_tools_checkout': '$($CefPins.depot_tools_commit)',
}
"@ }
    }
}
function global:python {
    $global:LASTEXITCODE = 0
    if ($args[0] -like '*automate-git.py') {
        $dir = $args[2]
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'chromium' 'src' 'cef') | Out-Null
        $global:CefSyncEvents.Add('automate')
    } else { $global:CefSyncEvents.Add('hook') }
}
function global:cmd { $global:LASTEXITCODE = 0; $global:CefSyncEvents.Add('bootstrap') }
function global:bash { $global:LASTEXITCODE = 0; $global:CefSyncEvents.Add('bootstrap') }

try {
    $platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $marker = Join-Path $temp 'keep'
    [IO.File]::WriteAllText($marker, 'unchanged')
    try {
        & $sync -Directory $temp -Target "$platform-x64"
        throw 'Expected existing-directory rejection'
    } catch {
        if ($_.Exception.Message -notlike '*must not already exist*') { throw }
    }
    if ([IO.File]::ReadAllText($marker) -cne 'unchanged') { throw 'Existing directory was modified' }
    $build = Join-Path $temp 'new-build'
    & $sync -Directory $build -Target "$platform-arm64"
    $expected = @('clone', 'checkout', 'bootstrap', 'automate',
        'isolated-clipboard.patch', 'remote-devices-cef.patch',
        'remote-devices-chromium.patch', 'in-process-audio-shutdown.patch')
    if ($platform -ne 'windows') { $expected += 'disable-chromium-shutdown-signals.patch' }
    $expected += 'hook'
    if (($global:CefSyncEvents -join ',') -cne ($expected -join ',') -or
        $env:GN_OUT_CONFIGS -cne 'Release_GN_arm64' -or
        $env:GN_DEFINES -notlike '*is_official_build=true*') {
        throw "Unexpected synchronization sequence: $($global:CefSyncEvents -join ',')"
    }
    Write-Host 'PowerShell synchronization checks passed.'
} finally {
    foreach ($name in @('git', 'Invoke-WebRequest', 'python', 'cmd', 'bash')) {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable CefSyncEvents -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
