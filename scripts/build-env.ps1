function Set-CefBuildEnvironment([string]$Directory, [string]$Target) {
    if ($Target -cnotin @('linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64')) {
        throw "Unsupported target: $Target"
    }
    $platform, $arch = $Target.Split('-')
    $hostPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    if ($platform -cne $hostPlatform) { throw "$Target must be built on $platform, not $hostPlatform" }
    $depotTools = Join-Path $Directory 'depot_tools'
    $env:PATH = "$depotTools$([IO.Path]::PathSeparator)$env:PATH"
    $env:GN_OUT_CONFIGS = "Release_GN_$arch"
    $env:CEF_ARCHIVE_FORMAT = 'tar.bz2'
    $env:DEPOT_TOOLS_UPDATE = '0'
    $gn = @('is_official_build=true', 'use_thin_lto=false', 'chrome_pgo_phase=0', 'symbol_level=0', 'use_siso=false')
    if ($platform -eq 'linux') {
        $gn += 'use_sysroot=true', 'is_cfi=false'
        if ($arch -eq 'arm64') { $env:CEF_INSTALL_SYSROOT = 'arm64' }
    } else {
        if ($platform -eq 'windows') { $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0' }
        if ($arch -eq 'arm64') { $env:CEF_ENABLE_ARM64 = '1' } else { $env:CEF_ENABLE_AMD64 = '1' }
    }
    $env:GN_DEFINES = $gn -join ' '
}
