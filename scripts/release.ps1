param(
    [Parameter(Mandatory)][string]$Build,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][ValidateSet('linux', 'macos', 'windows')][string]$Platform,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Arch,
    [Parameter(Mandatory)][string]$Revision
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'candidate.ps1')
$exports = @(
    'cef_isolated_clipboard_enabled', 'cef_isolated_clipboard_generation',
    'cef_isolated_clipboard_read', 'cef_isolated_clipboard_write_item',
    'cef_remote_media_enabled', 'cef_remote_camera_get_format',
    'cef_remote_camera_push_frame', 'cef_remote_microphone_active',
    'cef_remote_microphone_push', 'cef_remote_microphone_reset',
    'cef_remote_webauthn_enabled', 'cef_remote_webauthn_set_handler',
    'cef_remote_webauthn_respond', 'cef_remote_webauthn_set_platform_available'
)

function Get-PeExports([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $pe = $reader.ReadUInt32()
        $stream.Position = $pe
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Not a PE image' }
        $stream.Position = $pe + 6
        $sectionCount = $reader.ReadUInt16()
        $stream.Position = $pe + 20
        $optionalSize = $reader.ReadUInt16()
        $optional = $pe + 24
        $stream.Position = $optional
        $magic = $reader.ReadUInt16()
        $directoryOffset = switch ($magic) {
            0x10b { 96 }
            0x20b { 112 }
            default { throw "Unsupported PE optional header: $magic" }
        }
        $stream.Position = $optional + $directoryOffset
        $exportRva = $reader.ReadUInt32()
        if ($exportRva -eq 0) { return }
        $sections = @()
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $stream.Position = $optional + $optionalSize + 40 * $i + 8
            $sections += [pscustomobject]@{
                Size = $reader.ReadUInt32(); Address = $reader.ReadUInt32()
                RawSize = $reader.ReadUInt32(); Pointer = $reader.ReadUInt32()
            }
        }
        function Convert-Rva([uint32]$Rva) {
            foreach ($section in $sections) {
                if ($Rva -ge $section.Address -and
                    [uint64]$Rva -lt ([uint64]$section.Address + [Math]::Max($section.Size, $section.RawSize))) {
                    return [uint64]$Rva - $section.Address + $section.Pointer
                }
            }
            throw "PE RVA outside sections: $Rva"
        }
        $stream.Position = (Convert-Rva $exportRva) + 24
        $count = $reader.ReadUInt32()
        $stream.Position += 4
        $namesRva = $reader.ReadUInt32()
        $namesOffset = Convert-Rva $namesRva
        for ($i = 0; $i -lt $count; $i++) {
            $stream.Position = $namesOffset + 4 * $i
            $nameRva = $reader.ReadUInt32()
            $stream.Position = Convert-Rva $nameRva
            $bytes = [Collections.Generic.List[byte]]::new()
            while (($value = $reader.ReadByte()) -ne 0) { $bytes.Add($value) }
            [Text.Encoding]::ASCII.GetString($bytes.ToArray())
        }
    } finally {
        $reader.Dispose()
    }
}

Assert-PatchIdentity
if ($Revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Expected a full repository commit SHA' }
$suffixes = @{
    'linux-x64' = 'linux64'; 'linux-arm64' = 'linuxarm64'
    'macos-x64' = 'macosx64'; 'macos-arm64' = 'macosarm64'
    'windows-x64' = 'windows64'; 'windows-arm64' = 'windowsarm64'
}
$name = "cef_binary_$($CefPins.cef_version)_$($suffixes["$Platform-$Arch"])_minimal.tar.bz2"
$archive = Join-Path $Build 'chromium' 'src' 'cef' 'binary_distrib' $name
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    throw "Expected standard-named minimal archive: $archive"
}
$archive = (Resolve-Path -LiteralPath $archive).ProviderPath
$root = $name.Substring(0, $name.Length - 8)
$library = @{ linux = 'libcef.so'; windows = 'libcef.dll'; macos = 'Chromium Embedded Framework' }[$Platform]
$entries = @(& tar -tf $archive)
if ($LASTEXITCODE -ne 0) { throw "Cannot list archive: $archive" }
foreach ($entry in $entries) {
    $parts = $entry.Split('/')
    if ($parts[0] -cne $root -or $parts -contains '..' -or $entry.Contains('\')) {
        throw "Archive has an unexpected top-level directory or unsafe path: $entry"
    }
}
$candidateEntries = @($entries | Where-Object {
    $parts = $_.Split('/')
    $parts[-1] -ceq $library -and $parts -ccontains 'Release'
})
$details = @(& tar -tvf $archive)
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect archive: $archive" }
$candidates = @($candidateEntries | Where-Object {
    $candidate = $_
    @($details | Where-Object { $_.StartsWith('-') -and $_.EndsWith(" $candidate", [StringComparison]::Ordinal) }).Count -eq 1
})
if ($candidates.Count -ne 1) { throw "Expected one Release/$library, found $($candidates.Count)" }

$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-exports-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $binary = Join-Path $temp $library
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command tar -CommandType Application | Select-Object -First 1).Source
    foreach ($arg in @('-xOf', $archive, '--', $candidates[0])) { [void]$start.ArgumentList.Add($arg) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stderr = $process.StandardError.ReadToEndAsync()
    $destination = [IO.File]::Create($binary)
    try { $process.StandardOutput.BaseStream.CopyTo($destination) } finally { $destination.Dispose() }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Cannot extract library: $($stderr.Result)" }
    if ($Platform -eq 'windows') {
        $symbols = (Get-PeExports $binary) -join "`n"
    } else {
        $nm = Join-Path $Build 'chromium' 'src' 'third_party' 'llvm-build' 'Release+Asserts' 'bin' 'llvm-nm'
        if (-not (Test-Path -LiteralPath $nm -PathType Leaf)) {
            $nm = 'nm'
            $flags = if ($IsMacOS) { @('-gU') } else { @('-D', '--defined-only') }
        } else {
            $flags = if ($Platform -eq 'macos') { @('-g', '--defined-only') } else { @('-D', '--defined-only') }
        }
        $symbols = (& $nm @flags $binary) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Cannot read library exports: $nm" }
    }
    $missing = @($exports | Where-Object { $symbols -cnotmatch "(?<![A-Za-z0-9_])_?$([regex]::Escape($_))(?![A-Za-z0-9_])" })
    if ($missing.Count) { throw "Missing patched exports: $($missing -join ', ')" }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}

if (Test-Path -LiteralPath $Output) { throw "Output already exists: $Output" }
New-Item -ItemType Directory -Path $Output | Out-Null
$target = Join-Path $Output $name
Copy-Item -LiteralPath $archive -Destination $target
$checksum = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path (Resolve-Path $Output).ProviderPath 'SHA256SUMS'), "$checksum  $name`n", [Text.Encoding]::UTF8)
$patchHashes = [ordered]@{}
foreach ($patch in $CefPatchBlobs.Keys) {
    $patchHashes[$patch] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $CefRoot 'patches' $patch)).Hash.ToLowerInvariant()
}
$manifest = [ordered]@{
    schema = 1; status = 'draft-unvalidated'; repository_commit = $Revision
    platform = $Platform; architecture = $Arch; archive = $name
    sha256 = $checksum; pins = $CefPins; patch_git_blobs = $CefPatchBlobs
    patch_sha256 = $patchHashes; verified_exports = $exports
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Output 'manifest.json')
Write-Host "Prepared ${target}: $checksum"
