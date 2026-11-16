$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' 'targets.ps1'
$all = '["linux-x64","linux-arm64","windows-x64","windows-arm64","macos-x64","macos-arm64"]'

function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "Expected $Expected, got $Actual" }
}

Assert-Equal (& $script -Targets $all) $all
Assert-Equal (& $script -Targets $all -SkipMacOS) '["linux-x64","linux-arm64","windows-x64","windows-arm64"]'
Assert-Equal (& $script -Targets '["windows-x64"]' -SkipMacOS) '["windows-x64"]'

foreach ($case in @(
        @{ Targets = '["macos-arm64"]'; Expected = 'No targets selected' },
        @{ Targets = '["linux-x86"]'; Expected = 'Unsupported target: linux-x86' })) {
    try { & $script -Targets $case.Targets -SkipMacOS; throw 'no error' } catch {
        if ($_.Exception.Message -ne $case.Expected) { throw "Expected '$($case.Expected)', got '$($_.Exception.Message)'" }
    }
}
Write-Host 'targets tests passed'
