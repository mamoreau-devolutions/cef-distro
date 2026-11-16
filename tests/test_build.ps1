$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$buildScript = Join-Path $repo 'scripts' 'build.ps1'
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
$env:GITHUB_OUTPUT = Join-Path $temp 'outputs'
$platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
$targets = if ($IsWindows) { 'cefclient bootstrap bootstrapc' } elseif ($IsMacOS) { 'cefclient' } else { 'cefsimple chrome_sandbox' }
try {
    Set-Content -Encoding ascii -LiteralPath (Join-Path $outputDirectory 'build.ninja') -Value "build $targets`: phony"
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
    Remove-Item -LiteralPath $temp -Recurse -Force
}
