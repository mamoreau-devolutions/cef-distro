param(
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Checksum,
    [string]$ProbeLibrary,
    [string]$ProbeDirectory
)

$ErrorActionPreference = 'Stop'
if ($ProbeLibrary) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CefNativeSmoke {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Enabled();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate long Generation();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetDllDirectory(string path);
}
'@
    if ($IsWindows -and -not [CefNativeSmoke]::SetDllDirectory($ProbeDirectory)) {
        throw "SetDllDirectory failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $handle = [Runtime.InteropServices.NativeLibrary]::Load($ProbeLibrary)
    try {
        $enabled = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
            [Runtime.InteropServices.NativeLibrary]::GetExport($handle, 'cef_isolated_clipboard_enabled'),
            [CefNativeSmoke+Enabled])
        $generation = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
            [Runtime.InteropServices.NativeLibrary]::GetExport($handle, 'cef_isolated_clipboard_generation'),
            [CefNativeSmoke+Generation])
        $enabledValue = $enabled.Invoke()
        $generationValue = $generation.Invoke()
        if ($enabledValue -ne 0 -or $generationValue -ne -2) {
            throw "Unexpected clipboard state: enabled=$enabledValue, generation=$generationValue"
        }
        Write-Host "Native patched library loaded: clipboard enabled=$enabledValue, generation=$generationValue"
    } finally {
        [Runtime.InteropServices.NativeLibrary]::Free($handle)
    }
    return
}

$platform, $arch = $Target.Split('-')
$actualPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
$actualArch = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($platform -cne $actualPlatform -or $arch -cne $actualArch) {
    throw "Native runner required for $Target, got $actualPlatform-$actualArch"
}
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
if (-not $archivePath.EndsWith('.tar.bz2', [StringComparison]::Ordinal)) {
    throw "Unexpected archive name: $archivePath"
}
$root = [IO.Path]::GetFileName($archivePath).Substring(0, [IO.Path]::GetFileName($archivePath).Length - 8)
$entries = & tar -tf $archivePath
if ($LASTEXITCODE -ne 0) { throw "Cannot list archive: $archivePath" }
foreach ($entry in $entries) {
    $parts = $entry.Split('/')
    if ($parts[0] -cne $root -or $parts -contains '..' -or $entry.Contains('\')) {
        throw "Unsafe archive path: $entry"
    }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "cef-native-smoke-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    & tar -xf $archivePath -C $temp
    if ($LASTEXITCODE -ne 0) { throw "Cannot extract archive: $archivePath" }
    $release = Join-Path $temp $root 'Release'
    $library = switch ($platform) {
        'linux' { Join-Path $release 'libcef.so' }
        'windows' { Join-Path $release 'libcef.dll' }
        'macos' { Join-Path $release 'Chromium Embedded Framework.framework' 'Chromium Embedded Framework' }
        default { throw "Unsupported target: $Target" }
    }
    if ($IsLinux) {
        $env:LD_LIBRARY_PATH = "$release$([IO.Path]::PathSeparator)$env:LD_LIBRARY_PATH"
    }
    & pwsh -NoProfile -File $PSCommandPath -Target $Target -Archive $archivePath `
        -Checksum $Checksum -ProbeLibrary $library -ProbeDirectory $release
    if ($LASTEXITCODE -ne 0) { throw "Native probe failed with exit code $LASTEXITCODE" }
    [IO.File]::WriteAllText((Join-Path $env:RUNNER_TEMP 'archive.sha256'), "$Checksum`n",
        [Text.Encoding]::ASCII)
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
