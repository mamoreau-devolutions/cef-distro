$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ("cef-distrib-test-" + [guid]::NewGuid())
$tools = Join-Path $temp 'chromium' 'src' 'cef' 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null
$global:CefTestPythonExit = 0
function python {
    $global:CefTestCapturedArguments = @($args)
    $global:CefTestCapturedDirectory = (Get-Location).Path
    $global:LASTEXITCODE = $global:CefTestPythonExit
}

try {
    $platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $distrib = Join-Path $repo 'scripts' 'distrib.ps1'
    foreach ($arch in @('x64', 'arm64')) {
        & $distrib -Directory $temp -Target "$platform-$arch"
        if ($global:CefTestCapturedDirectory -cne $tools -or
            $global:CefTestCapturedArguments -cnotcontains "--$arch-build" -or
            $global:CefTestCapturedArguments -cnotcontains '--minimal' -or
            $global:CefTestCapturedArguments -cnotcontains '--ninja-build' -or
            $global:CefTestCapturedArguments -cnotcontains "--output-dir=$(Join-Path $temp 'chromium' 'src' 'cef' 'binary_distrib')" -or
            $env:GN_OUT_CONFIGS -cne "Release_GN_$arch" -or
            $env:CEF_ARCHIVE_FORMAT -cne 'tar.bz2') {
            throw "Incorrect distribution invocation for $platform-$arch"
        }
        if (($platform -ne 'linux') -ne ($global:CefTestCapturedArguments -ccontains '--no-symbols')) {
            throw "Incorrect symbol setting for $platform-$arch"
        }
        if ($platform -eq 'linux' -and $arch -eq 'arm64' -and $env:CEF_INSTALL_SYSROOT -cne 'arm64') {
            throw 'Linux ARM64 sysroot was not selected'
        }
    }
    Push-Location (Split-Path $temp -Parent)
    try {
        & $distrib -Directory (Split-Path $temp -Leaf) -Target "$platform-x64"
        $expectedOutput = "--output-dir=$(Join-Path $temp 'chromium' 'src' 'cef' 'binary_distrib')"
        if ($global:CefTestCapturedArguments -cnotcontains $expectedOutput) {
            throw 'Relative build directory was not resolved before invoking CEF'
        }
    } finally {
        Pop-Location
    }
    $global:CefTestPythonExit = 17
    try {
        & $distrib -Directory $temp -Target "$platform-x64"
        throw 'Expected a distribution failure'
    } catch {
        if ($_.Exception.Message -notlike '*exit code 17*') { throw }
    } finally {
        $global:LASTEXITCODE = 0
    }
    Write-Host 'PowerShell distribution invocation checks passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
