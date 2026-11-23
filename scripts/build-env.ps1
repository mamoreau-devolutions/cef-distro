# GN arguments for one target, apart from what CEF's own tooling adds.
function Get-CefGnDefines([string]$Target) {
    $platform, $arch = $Target.Split('-')
    $gn = @('is_official_build=true', 'use_thin_lto=false', 'chrome_pgo_phase=0', 'symbol_level=0', 'use_siso=false')
    if ($platform -eq 'linux') {
        $gn += 'use_sysroot=true', 'is_cfi=false'
    }
    if ($Target -eq 'macos-x64') {
        # macOS x64 is cross-compiled on an arm64 runner. The V8 context
        # snapshot is made by a host program that links all of Blink, so the
        # cross build compiles Blink and its dependencies a second time for
        # the arm64 host: about 29k of its 95k ninja steps. Without it, V8
        # starts from snapshot_blob.bin, which CEF ships in the framework in
        # its place, and new contexts take slightly longer to create.
        $gn += 'use_v8_context_snapshot=false'
    }
    return $gn
}

function Set-CefBuildEnvironment([string]$Directory, [string]$Target) {
    if ($Target -cnotin @('linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64')) {
        throw "Unsupported target: $Target"
    }
    $platform, $arch = $Target.Split('-')
    $hostPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    if ($platform -cne $hostPlatform) { throw "$Target must be built on $platform, not $hostPlatform" }
    # Chromium's bindgen rejects an inherited TARGET environment variable.
    if (Test-Path Env:TARGET) { Remove-Item Env:TARGET }
    $depotTools = Join-Path $Directory 'depot_tools'
    $env:PATH = "$depotTools$([IO.Path]::PathSeparator)$env:PATH"
    $env:GN_OUT_CONFIGS = "Release_GN_$arch"
    $env:CEF_ARCHIVE_FORMAT = 'tar.bz2'
    $env:DEPOT_TOOLS_UPDATE = '0'
    $gn = Get-CefGnDefines $Target
    if ($platform -eq 'linux') {
        if ($arch -eq 'arm64') { $env:CEF_INSTALL_SYSROOT = 'arm64' }
    } else {
        if ($platform -eq 'windows') { $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0' }
        if ($arch -eq 'arm64') { $env:CEF_ENABLE_ARM64 = '1' } else { $env:CEF_ENABLE_AMD64 = '1' }
    }
    $env:GN_DEFINES = $gn -join ' '
}

# Official Chromium compile jobs can each take about 2 GiB. Ninja's default of
# CPUs + 2 jobs fits the 16 GB Linux and Windows runners but makes the 7 GB macOS
# runner swap until it stops responding, so memory also limits the job count.
$CefBytesPerNinjaJob = 2GB

function Get-CefNinjaJobs([long]$MemoryBytes, [int]$ProcessorCount) {
    if ($env:CEF_NINJA_JOBS) {
        $jobs = 0
        if (-not [int]::TryParse($env:CEF_NINJA_JOBS, [ref]$jobs) -or $jobs -lt 1) {
            throw "CEF_NINJA_JOBS must be a positive integer: $env:CEF_NINJA_JOBS"
        }
        return $jobs
    }
    $byMemory = [Math]::Floor($MemoryBytes / $CefBytesPerNinjaJob)
    return [int][Math]::Max(1, [Math]::Min($ProcessorCount + 2, $byMemory))
}

function Get-CefMemoryReport {
    try {
        if ($IsMacOS) {
            $free = (& memory_pressure -Q 2>$null | Select-String 'free percentage') -replace '^.*:\s*', ''
            $swap = (& sysctl -n vm.swapusage 2>$null) -join ' '
            return "memory free $free; swap $swap"
        }
        if ($IsLinux) {
            $info = @{}
            foreach ($line in Get-Content -LiteralPath /proc/meminfo) {
                if ($line -match '^(\w+):\s+(\d+) kB') { $info[$Matches[1]] = [long]$Matches[2] * 1KB }
            }
            $swapUsed = $info.SwapTotal - $info.SwapFree
            return 'memory available {0:N1} of {1:N1} GiB; swap used {2:N1} of {3:N1} GiB' -f
                ($info.MemAvailable / 1GB), ($info.MemTotal / 1GB), ($swapUsed / 1GB), ($info.SwapTotal / 1GB)
        }
        $os = Get-CimInstance Win32_OperatingSystem
        return 'memory free {0:N1} of {1:N1} GiB; commit free {2:N1} of {3:N1} GiB' -f
            ($os.FreePhysicalMemory * 1KB / 1GB), ($os.TotalVisibleMemorySize * 1KB / 1GB),
            ($os.FreeVirtualMemory * 1KB / 1GB), ($os.TotalVirtualMemorySize * 1KB / 1GB)
    } catch {
        return "memory report unavailable: $($_.Exception.Message)"
    }
}

function Get-CefDiskReport([string]$Directory) {
    try {
        if ($IsWindows) {
            $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($Directory).Substring(0, 1))
            return 'disk free {0:N1} of {1:N1} GiB' -f ($drive.Free / 1GB), (($drive.Free + $drive.Used) / 1GB)
        }
        $fields = (& df -Pk $Directory | Select-Object -Last 1) -split '\s+'
        return 'disk free {0:N1} of {1:N1} GiB' -f ([long]$fields[3] * 1KB / 1GB), ([long]$fields[1] * 1KB / 1GB)
    } catch {
        return "disk report unavailable: $($_.Exception.Message)"
    }
}
