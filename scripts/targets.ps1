[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Targets,
    [switch]$SkipMacOS
)
$ErrorActionPreference = 'Stop'

$known = 'linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64'
$requested = @(ConvertFrom-Json -InputObject $Targets)
foreach ($target in $requested) {
    if ($target -notin $known) { throw "Unsupported target: $target" }
}
$selected = @($requested | Where-Object { -not ($SkipMacOS -and $_ -like 'macos-*') } | Select-Object -Unique)
if ($selected.Count -eq 0) { throw 'No targets selected' }
ConvertTo-Json -InputObject $selected -Compress
