param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidateSet('linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64')][string]$Target
)

$ErrorActionPreference = 'Stop'
$Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
$platform, $arch = $Target.Split('-')
. (Join-Path $PSScriptRoot 'build-env.ps1')
Set-CefBuildEnvironment $Directory $Target

$src = Join-Path $Directory 'chromium' 'src'
$cef = Join-Path $src 'cef'
$outputDirectory = Join-Path $cef 'binary_distrib'
$arguments = @('make_distrib.py', "--output-dir=$outputDirectory", '--ninja-build', "--$arch-build", '--minimal', '--no-docs', '--allow-partial')
if ($platform -ne 'linux') { $arguments += '--no-symbols' }
Push-Location (Join-Path $cef 'tools')
try {
    & python @arguments
    if ($LASTEXITCODE -ne 0) { throw "CEF make_distrib.py failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
