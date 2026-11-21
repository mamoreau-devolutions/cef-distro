# Builds the IronRDP CEF browser server against an exported patched CEF and runs
# IronRDP's browser e2e suites, which exercise what the patches add at runtime.
param(
    # An IronRDP checkout (pins.json ironrdp_commit).
    [Parameter(Mandatory)][string]$IronRdp,
    # The candidate exported with cef-rs export-cef-dir (becomes CEF_PATH).
    [Parameter(Mandatory)][string]$Cef,
    [Parameter(Mandatory)][string]$Artifacts,
    # Run only these suites (names as listed below).
    [string[]]$Suites,
    # The cef-rs revision released for the candidate's CEF version. IronRDP's
    # cef-rs dependency moves to it, as IronRDP must to use this release; with an
    # older cef-rs, the build would silently use stock CEF instead.
    [string]$CefRs
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The IronRDP e2e gate runs on Windows x64' }
# pwsh -File passes "a,b" as one string.
$Suites = @($Suites | ForEach-Object { $_ -split ',' } | ForEach-Object Trim | Where-Object { $_ })
# cef-dll-sys builds CEF's C++ wrapper with CMake and MSVC.
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'Visual Studio with the x64 C++ tools is required' }
    Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
}
$env:CEF_PATH = (Resolve-Path -LiteralPath $Cef).ProviderPath
New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null
$Artifacts = (Resolve-Path -LiteralPath $Artifacts).ProviderPath
$IronRdp = (Resolve-Path -LiteralPath $IronRdp).ProviderPath

function Invoke-Logged([string]$Name, [string]$Executable, [string[]]$Arguments) {
    $log = Join-Path $Artifacts "$Name.log"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    & $Executable @Arguments *> $log
    $code = $LASTEXITCODE
    Write-Host ('{0}: exit {1} in {2:n0}s' -f $Name, $code, $watch.Elapsed.TotalSeconds)
    if ($code -ne 0) { Get-Content -LiteralPath $log -Tail 40 | Write-Host }
    return $code
}

Push-Location $IronRdp
try {
    $serverLock = '--locked'
    if ($CefRs) {
        $manifest = Join-Path $IronRdp 'server/cef/Cargo.toml'
        $text = [IO.File]::ReadAllText($manifest)
        $pattern = '(git = "https://github.com/tauri-apps/cef-rs", rev = ")([0-9a-f]{40})(")'
        $current = [regex]::Match($text, $pattern)
        if (-not $current.Success) { throw 'IronRDP does not depend on cef-rs by revision as expected' }
        if ($current.Groups[2].Value -cne $CefRs) {
            Write-Host "Moving IronRDP's cef-rs dependency from $($current.Groups[2].Value) to $CefRs"
            [IO.File]::WriteAllText($manifest, [regex]::Replace($text, $pattern, "`${1}$CefRs`${3}"))
            # The lockfile then matches the manifest again, so builds stay --locked.
            if ((Invoke-Logged 'update-cef-rs' 'cargo' @('update', '--manifest-path', 'server/cef/Cargo.toml', '-p', 'cef')) -ne 0) {
                throw 'Updating cef-rs failed'
            }
        }
    }
    $builds = [ordered]@{
        'build-bundle' = @('run', $serverLock, '--manifest-path', 'server/cef/Cargo.toml', '--features', 'bundle', '--bin', 'package-cef')
        'build-agent' = @('build', '--locked', '-p', 'ironrdp-agent')
        'build-media-fixture' = @('build', $serverLock, '--manifest-path', 'server/cef/Cargo.toml', '--features', 'media-fixture', '--bin', 'rdp-media-fixture')
        'build-rdpdr-fixture' = @('build', $serverLock, '--manifest-path', 'server/cef/Cargo.toml', '--features', 'runtime', '--bin', 'rdpdr-policy-fixture')
    }
    foreach ($name in $builds.Keys) {
        if ((Invoke-Logged $name 'cargo' $builds[$name]) -ne 0) { throw "$name failed" }
    }
    $server = 'server/cef/artifacts/bundle/ironrdp_cef_server.exe'
    $bundled = (Get-FileHash -LiteralPath 'server/cef/artifacts/bundle/libcef.dll').Hash
    if ($bundled -ne (Get-FileHash -LiteralPath (Join-Path $env:CEF_PATH 'libcef.dll')).Hash) {
        throw 'The packaged server does not contain the candidate libcef.dll'
    }
    $agent = 'target/debug/ironrdp-agent.exe'
    $media = 'server/cef/target/debug/rdp-media-fixture.exe'
    $policy = 'server/cef/target/debug/rdpdr-policy-fixture.exe'
    $all = [ordered]@{
        'e2e' = @('e2e.py', '--server-bin', $server, '--agent', $agent)
        'clipboard' = @('clipboard.py', '--server-bin', $server, '--agent', $agent, '--with-downloads')
        'downloads' = @('downloads.py', '--server-bin', $server, '--agent', $agent)
        'devices-permission' = @('devices.py', '--server-bin', $server, '--agent', $agent, '--permission-only')
        'rdpdr-policy' = @('rdpdr_policy.py', '--server-bin', $policy, '--agent', $agent)
        'media' = @('rdp_media.py', '--server-bin', $server, '--client-bin', $media)
        'media-restart' = @('rdp_media.py', '--server-bin', $server, '--client-bin', $media, '--restart')
        'media-reconnect' = @('rdp_media.py', '--server-bin', $server, '--client-bin', $media, '--reconnect')
        'media-hotplug' = @('rdp_media.py', '--server-bin', $server, '--client-bin', $media, '--hotplug')
        'media-nodevices' = @('rdp_media.py', '--server-bin', $server, '--client-bin', $media, '--without-devices')
        'media-nv12' = @('rdp_media.py', '--server-bin', $server, '--client-bin', $media, '--camera-format', 'nv12')
        'shutdown' = @('shutdown.py', '--server-bin', $server, '--iterations', '10')
    }
    # A suite gets a second run: some IronRDP suites have timing races on slow
    # hosted runners that have nothing to do with the patches. A suite that fails
    # twice fails the gate, and both attempts' logs and reports are kept.
    $unknown = @($Suites | Where-Object { $_ -notin $all.Keys })
    if ($unknown) { throw "Unknown suites: $($unknown -join ', ') (known: $($all.Keys -join ', '))" }
    $failed = @()
    $retried = @()
    $ran = 0
    foreach ($name in $all.Keys) {
        if ($Suites -and $name -notin $Suites) { continue }
        $ran++
        $passed = $false
        foreach ($attempt in 1, 2) {
            $label = if ($attempt -eq 1) { $name } else { "$name-retry" }
            $arguments = @("server/cef/testing/$($all[$name][0])") + $all[$name][1..($all[$name].Count - 1)] +
                @('--artifacts', (Join-Path $Artifacts $label))
            if ((Invoke-Logged "suite-$label" 'python' $arguments) -eq 0) { $passed = $true; break }
        }
        if (-not $passed) { $failed += $name } elseif ($attempt -eq 2) { $retried += $name }
    }
    if ($retried) { Write-Host "Passed on the second attempt: $($retried -join ', ')" }
    if ($failed) { throw "IronRDP e2e suites failed twice: $($failed -join ', ')" }
    if ($ran -eq 0) { throw 'No IronRDP e2e suite ran' }
    Write-Host "All $ran IronRDP e2e suites passed against the candidate."
} finally {
    Pop-Location
}
