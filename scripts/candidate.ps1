$CefRoot = Split-Path $PSScriptRoot -Parent
$CefPins = Get-Content -Raw -Encoding utf8 (Join-Path $CefRoot 'pins.json') | ConvertFrom-Json -AsHashtable
$CefPatchBlobs = [ordered]@{
    'isolated-clipboard.patch' = '5d9af697b96cb609504896d1d92b3fb090ad26a2'
    'remote-devices-cef.patch' = 'cfe65d65f75fcd7bd1e9160c9087520878b578d0'
    'remote-devices-chromium.patch' = '81abad66a88a812b13e04771c42242190c078b25'
    'in-process-audio-shutdown.patch' = 'ac5215315c4e8439d88474989f245f2750c43116'
    'disable-chromium-shutdown-signals.patch' = 'bd49755a5de794d2b7b16e865b00b2332611f770'
}

# Fetches a file from a GitHub repository at a revision, retrying rate limits
# and server errors. With GH_TOKEN it uses the REST contents API, which is
# limited per token; raw.githubusercontent.com is limited per IP address and
# throttles shared CI runners even when authenticated.
function Invoke-UpstreamRequest([string]$Repository, [string]$Revision, [string]$Path, [string]$OutFile) {
    $request = @{ TimeoutSec = 60 }
    if ($env:GH_TOKEN) {
        $escaped = ($Path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $request.Uri = "https://api.github.com/repos/$Repository/contents/${escaped}?ref=$Revision"
        $request.Headers = @{
            Authorization = "Bearer $env:GH_TOKEN"
            Accept = 'application/vnd.github.raw+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
    } else {
        $request.Uri = "https://raw.githubusercontent.com/$Repository/$Revision/$Path"
    }
    if ($OutFile) { $request.OutFile = $OutFile }
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-WebRequest @request }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            if ($attempt -ge 4 -or ($status -ne 429 -and $status -lt 500)) { throw }
            Start-Sleep -Seconds (20 * $attempt)
        }
    }
}

# Patches apply in this order, each tree from its own pinned upstream revision.
$CefPatchTrees = @(
    @{
        Name = 'cef'; Repository = 'chromiumembedded/cef'; RevisionPin = 'cef_commit'
        Patches = @('isolated-clipboard.patch', 'remote-devices-cef.patch')
    },
    @{
        Name = 'chromium'; Repository = 'chromium/chromium'; RevisionPin = 'chromium_commit'
        Patches = @('remote-devices-chromium.patch', 'in-process-audio-shutdown.patch', 'disable-chromium-shutdown-signals.patch')
    }
)

# Paths the patches touch; -Existing leaves out files the patches create.
function Get-PatchedPaths([string[]]$Patches, [switch]$Existing) {
    $paths = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Patches) {
        foreach ($line in Get-Content -Encoding utf8 -LiteralPath (Join-Path $CefRoot 'patches' $name)) {
            if ($line -cmatch '^--- a/(.+)$' -or (-not $Existing -and $line -cmatch '^\+\+\+ b/(.+)$')) {
                [void]$paths.Add($Matches[1])
            }
        }
    }
    return @($paths)
}

# Downloads upstream files at a revision into a directory, keeping their paths.
function Save-UpstreamFiles($Tree, [string]$Revision, [string[]]$Paths, [string]$Directory) {
    foreach ($path in $Paths) {
        $destination = Join-Path $Directory $path
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Invoke-UpstreamRequest $Tree.Repository $Revision $path $destination | Out-Null
    }
}

# Rewrites the patch blob identities above to match patches/*.patch.
function Update-PatchBlobs {
    $path = Join-Path $CefRoot 'scripts' 'candidate.ps1'
    $text = [IO.File]::ReadAllText($path)
    foreach ($name in @($CefPatchBlobs.Keys)) {
        $blob = (& git hash-object --no-filters -- (Join-Path $CefRoot 'patches' $name)).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Cannot hash patch: $name" }
        $pattern = "(?m)^(\s*'$([regex]::Escape($name))' = ')[0-9a-f]{40}(')"
        if ($text -cnotmatch $pattern) { throw "No blob identity for $name in candidate.ps1" }
        $text = [regex]::Replace($text, $pattern, "`${1}$blob`${2}")
        $CefPatchBlobs[$name] = $blob
    }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

function Assert-PatchIdentity {
    foreach ($name in $CefPatchBlobs.Keys) {
        $actual = & git hash-object --no-filters -- (Join-Path $CefRoot 'patches' $name)
        if ($LASTEXITCODE -ne 0) { throw "Cannot hash patch: $name" }
        if ($actual -cne $CefPatchBlobs[$name]) { throw "Patch differs from recorded blob: $name" }
    }
}

function Assert-CefCompatibility {
    $content = (Invoke-UpstreamRequest 'chromiumembedded/cef' $CefPins.cef_commit 'CHROMIUM_BUILD_COMPATIBILITY.txt').Content
    $compatibility = if ($content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content) } else { $content }
    foreach ($item in @(
        @('chromium_checkout', "refs/tags/$($CefPins.chromium_tag)"),
        @('depot_tools_checkout', $CefPins.depot_tools_commit)
    )) {
        $pattern = "(?m)^\s*'$($item[0])':\s*'([^']+)'\s*,?\s*$"
        $values = [regex]::Matches($compatibility, $pattern)
        if ($values.Count -ne 1 -or $values[0].Groups[1].Value -cne $item[1]) {
            throw "CEF compatibility mismatch: $($item[0])"
        }
    }
}

function Test-FlatMapEqual($Actual, $Expected) {
    if ($null -eq $Actual -or $Actual.Count -ne $Expected.Count) { return $false }
    foreach ($key in $Expected.Keys) {
        if ($Actual.Keys -cnotcontains $key -or $Actual[$key] -isnot [string] -or
            $Actual[$key] -cne $Expected[$key]) { return $false }
    }
    return $true
}

function Get-VerifiedCandidate([string]$Directory, [string]$Target) {
    $manifestPath = Join-Path $Directory 'manifest.json'
    $manifest = Get-Content -Raw -Encoding utf8 -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
    $platform, $arch = $Target.Split('-')
    if ($manifest.platform -cne $platform -or $manifest.architecture -cne $arch) {
        throw "${Directory}: manifest is not for $Target"
    }
    if (-not (Test-FlatMapEqual $manifest.pins $CefPins) -or
        -not (Test-FlatMapEqual $manifest.patch_git_blobs $CefPatchBlobs)) {
        throw "${Directory}: built from different pins or patches than this checkout"
    }
    $archive = Join-Path $Directory $manifest.archive
    $checksum = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($checksum -cne $manifest.sha256) { throw "${archive}: checksum does not match manifest" }
    return [pscustomobject]@{ Manifest = $manifest; Archive = $archive; ManifestPath = $manifestPath }
}
