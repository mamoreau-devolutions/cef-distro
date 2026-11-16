param(
    [Parameter(Mandatory)][string[]]$Source,
    [Parameter(Mandatory)][string]$Targets,
    [Parameter(Mandatory)][string]$Output,
    [string]$SmokeProofs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
Assert-PatchIdentity
$selectedTargets = @(ConvertFrom-Json -InputObject $Targets)
if (Test-Path -LiteralPath $Output) { throw "Output already exists: $Output" }
New-Item -ItemType Directory -Path $Output | Out-Null
$sums = [System.Collections.Generic.List[string]]::new()
foreach ($target in $selectedTargets) {
    $directory = $null
    foreach ($sourceDirectory in $Source) {
        $candidate = Join-Path $sourceDirectory "candidate-$target"
        if (Test-Path -LiteralPath (Join-Path $candidate 'manifest.json') -PathType Leaf) {
            $directory = $candidate
            break
        }
    }
    if ($null -eq $directory) { throw "No candidate for $target" }
    $verified = Get-VerifiedCandidate $directory $target
    if ($SmokeProofs) {
        $proof = Join-Path $SmokeProofs "native-smoke-$target" 'archive.sha256'
        if ((Get-Content -Raw -Encoding ascii -LiteralPath $proof).Trim() -cne $verified.Manifest.sha256) {
            throw "${target}: native smoke tested a different archive"
        }
    }
    Copy-Item -LiteralPath $verified.Archive -Destination (Join-Path $Output $verified.Manifest.archive)
    Copy-Item -LiteralPath $verified.ManifestPath -Destination (Join-Path $Output "manifest-$target.json")
    $sums.Add("$($verified.Manifest.sha256)  $($verified.Manifest.archive)")
    Write-Host "$target`: $($verified.Manifest.archive) from $directory (commit $($verified.Manifest.repository_commit))"
}
[System.IO.File]::WriteAllText(
    (Join-Path (Resolve-Path -LiteralPath $Output) 'SHA256SUMS'),
    ($sums -join "`n") + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
