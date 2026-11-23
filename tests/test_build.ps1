$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$buildScript = Join-Path $repo 'scripts' 'build.ps1'
. (Join-Path $repo 'scripts' 'build-env.ps1')
$previousJobs = $env:CEF_NINJA_JOBS
try {
    $env:CEF_NINJA_JOBS = $null
    foreach ($case in @(
        @{ Memory = 7GB; Cpus = 3; Expected = 3 },   # standard macOS arm64 runner
        @{ Memory = 16GB; Cpus = 4; Expected = 6 },  # standard Linux and Windows runners
        @{ Memory = 14GB; Cpus = 5; Expected = 7 },
        @{ Memory = 1GB; Cpus = 8; Expected = 1 }
    )) {
        $actual = Get-CefNinjaJobs $case.Memory $case.Cpus
        if ($actual -ne $case.Expected) {
            throw "Ninja jobs for $($case.Memory / 1GB) GiB and $($case.Cpus) CPUs: expected $($case.Expected), got $actual"
        }
    }
    $env:CEF_NINJA_JOBS = '9'
    if ((Get-CefNinjaJobs 7GB 3) -ne 9) { throw 'CEF_NINJA_JOBS override was ignored' }
    foreach ($invalid in @('0', '-1', 'many')) {
        $env:CEF_NINJA_JOBS = $invalid
        $rejected = $false
        try { Get-CefNinjaJobs 7GB 3 | Out-Null } catch {
            if ($_.Exception.Message -notlike '*must be a positive integer*') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "Accepted CEF_NINJA_JOBS=$invalid" }
    }
} finally {
    $env:CEF_NINJA_JOBS = $previousJobs
}
$memoryReport = Get-CefMemoryReport
if ($memoryReport -like 'memory report unavailable*') { throw "Memory report failed: $memoryReport" }
$ninjaCommand = Get-Command ninja -CommandType Application -ErrorAction Stop | Select-Object -First 1
$ninjaSource = $ninjaCommand.Source
if ($IsWindows -and $env:ChocolateyInstall) {
    $chocolateyNinja = Join-Path $env:ChocolateyInstall 'lib' 'ninja' 'tools' 'ninja.exe'
    if (Test-Path -LiteralPath $chocolateyNinja) { $ninjaSource = $chocolateyNinja }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-build-test-$([guid]::NewGuid())"
$src = Join-Path $temp 'chromium' 'src'
$ninjaDirectory = Join-Path $src 'third_party' 'ninja'
$outputDirectory = Join-Path $src 'out' 'Release_GN_x64'
New-Item -ItemType Directory -Force -Path $ninjaDirectory, $outputDirectory | Out-Null
$ninjaName = if ($IsWindows) { 'ninja.exe' } else { 'ninja' }
Copy-Item -LiteralPath $ninjaSource -Destination (Join-Path $ninjaDirectory $ninjaName)
$previousOutput = $env:GITHUB_OUTPUT
$previousTarget = $env:TARGET
$env:GITHUB_OUTPUT = Join-Path $temp 'outputs'
$platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
$targets = if ($IsWindows) { 'cefclient bootstrap bootstrapc' } elseif ($IsMacOS) { 'cefclient' } else { 'cefsimple chrome_sandbox' }
try {
    $env:TARGET = 'inherited-target'
    @"
rule check_environment
  command = pwsh -NoProfile -Command "if (Test-Path Env:TARGET) { exit 19 }"
build checked: check_environment
build $targets`: phony checked
"@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $outputDirectory 'build.ninja')
    & $buildScript -Directory $temp -Target "$platform-x64" -Deadline ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)
    if ((Get-Content -LiteralPath $env:GITHUB_OUTPUT | Select-Object -Last 1) -cne 'complete=true') {
        throw 'Completed build was not reported'
    }
    @"
rule slow
  command = pwsh -NoProfile -Command "Start-Sleep -Seconds 5"
build slow: slow
build $targets`: phony slow
"@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $outputDirectory 'build.ninja')
    & $buildScript -Directory $temp -Target "$platform-x64" -Deadline ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 2)
    $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT | Select-Object -Last 1
    if ($result -cne 'complete=false') { throw "Timed build was not interrupted: result=$result" }
    @"
rule fail
  command = pwsh -NoProfile -Command "exit 17"
build failed: fail
build $targets`: phony failed
"@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $outputDirectory 'build.ninja')
    try {
        & $buildScript -Directory $temp -Target "$platform-x64" -Deadline ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)
        throw 'Expected a ninja failure'
    } catch {
        if ($_.Exception.Message -notlike '*Ninja failed with exit code*') { throw }
    }
    Write-Host 'PowerShell ninja completion and interruption checks passed.'
} finally {
    $env:GITHUB_OUTPUT = $previousOutput
    $env:TARGET = $previousTarget
    Remove-Item -LiteralPath $temp -Recurse -Force
}
