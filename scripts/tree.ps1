param(
    [Parameter(Mandatory)][ValidateSet('pack', 'unpack')][string]$Mode,
    [Parameter(Mandatory)][string]$Directory,
    [string]$Output,
    [string]$Parts,
    [long]$PartSize = 2GB
)

$ErrorActionPreference = 'Stop'
if ($IsWindows) { . (Join-Path $PSScriptRoot 'windows-tree.ps1') }
$zstdCommand = Get-Command zstd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$zstd = if ($zstdCommand) { $zstdCommand.Source } elseif (Test-Path -LiteralPath 'C:\tools\zstd\zstd.exe') {
    'C:\tools\zstd\zstd.exe'
} else { throw 'zstd executable not found' }
$tar = (Get-Command tar -CommandType Application | Select-Object -First 1).Source

function Start-StreamProcess([string]$Executable, [string[]]$Arguments, [bool]$InputStream, [bool]$OutputStream) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $InputStream
    $start.RedirectStandardOutput = $OutputStream
    return [Diagnostics.Process]::Start($start)
}

$checksumName = 'tree.sha256'

function Get-TreeParts([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -Filter 'tree.tar.zst.*' -File | Sort-Object Name)
}

function Write-TreeParts([string]$Directory, [string]$Output) {
    New-Item -ItemType Directory -Path $Output | Out-Null
    $compress = Start-StreamProcess $zstd @('-q', '-T0', '-3', '-c') $true $true
    $split = Start-ThreadJob -ArgumentList $compress.StandardOutput.BaseStream, $Output, $PartSize -ScriptBlock {
        param($stream, $output, $partSize)
        $ErrorActionPreference = 'Stop'
        $buffer = [byte[]]::new(8MB)
        $part = $null
        $hash = $null
        $name = $null
        $sums = [Collections.Generic.List[string]]::new()
        $written = 0
        try {
            while (($length = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $offset = 0
                while ($offset -lt $length) {
                    if ($null -eq $part -or $written -eq $partSize) {
                        if ($part) {
                            $part.Dispose()
                            $sums.Add("$([Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant())  $name")
                        } else {
                            $hash = [Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
                        }
                        $name = 'tree.tar.zst.{0:D4}' -f $sums.Count
                        $part = [IO.File]::Create((Join-Path $output $name))
                        $written = 0
                    }
                    $take = [int][Math]::Min([long]($length - $offset), [long]$partSize - $written)
                    $part.Write($buffer, $offset, $take)
                    $hash.AppendData($buffer, $offset, $take)
                    $offset += $take
                    $written += $take
                }
            }
            if ($part) {
                $part.Dispose()
                $part = $null
                $sums.Add("$([Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant())  $name")
            }
        } finally {
            if ($part) { $part.Dispose() }
            if ($hash) { $hash.Dispose() }
            $stream.Dispose()
        }
        return $sums.ToArray()
    }
    $tarProcess = $null
    try {
        if ($IsWindows) {
            Write-CefWindowsTree $Directory $compress.StandardInput.BaseStream
        } else {
            $format = if ($IsLinux) { @('--format=posix') } else { @('--format', 'pax') }
            $tarProcess = Start-StreamProcess $tar (@($format) + @('-cf', '-', '-C', $Directory, '.')) $false $true
            $tarProcess.StandardOutput.BaseStream.CopyTo($compress.StandardInput.BaseStream)
            $tarProcess.WaitForExit()
            if ($tarProcess.ExitCode -ne 0) { throw "Tree tar failed: $($tarProcess.ExitCode)" }
        }
        $compress.StandardInput.Close()
        $sums = @(Receive-Job -Job $split -Wait -ErrorAction Stop)
        $compress.WaitForExit()
        if ($compress.ExitCode -ne 0 -or $sums.Count -lt 1) { throw "Tree compression failed: $($compress.ExitCode)" }
        [IO.File]::WriteAllText((Join-Path $Output $checksumName), ($sums -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    } finally {
        if (-not $compress.HasExited) { $compress.Kill($true); $compress.WaitForExit() }
        if ($tarProcess -and -not $tarProcess.HasExited) { $tarProcess.Kill($true); $tarProcess.WaitForExit() }
        if ($split.State -eq 'Running') { Stop-Job $split }
        Remove-Job $split -Force
        if ($tarProcess) { $tarProcess.Dispose() }
        $compress.Dispose()
    }
}

# Compares parts with the hashes recorded while they were written; returns the first mismatch.
function Test-TreeChecksums([string]$Path) {
    $sums = Join-Path $Path $checksumName
    if (-not (Test-Path -LiteralPath $sums)) { return $null }
    $expected = @{}
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
        if ($line -notmatch '^([0-9a-f]{64})  (tree\.tar\.zst\.\d{4})$') { return "malformed line in ${checksumName}: $line" }
        $expected[$Matches[2]] = $Matches[1]
    }
    $files = Get-TreeParts $Path
    if ($files.Count -ne $expected.Count) { return "$($files.Count) parts present but $($expected.Count) recorded" }
    foreach ($file in $files) {
        if (-not $expected.ContainsKey($file.Name)) { return "$($file.Name) is not recorded" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        if ($actual -cne $expected[$file.Name]) { return "$($file.Name) does not match its recorded SHA-256" }
    }
    return $null
}

# Decodes the parts as stored, so corruption fails this stage rather than the next one.
function Test-TreeStream([string]$Path) {
    $check = Start-StreamProcess $zstd @('-q', '-t') $true $false
    try {
        foreach ($file in Get-TreeParts $Path) {
            $stream = [IO.File]::OpenRead($file.FullName)
            try { $stream.CopyTo($check.StandardInput.BaseStream) } finally { $stream.Dispose() }
        }
        $check.StandardInput.Close()
        $check.WaitForExit()
        return $check.ExitCode -eq 0
    } catch [IO.IOException] {
        # zstd exits early on corrupt input, which breaks the pipe.
        $check.WaitForExit()
        return $false
    } finally {
        if (-not $check.HasExited) { $check.Kill($true); $check.WaitForExit() }
        $check.Dispose()
    }
}

if ($Mode -eq 'pack') {
    if (-not $Output -or $PartSize -le 0) { throw 'A pack output and positive part size are required' }
    $Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
    if (Test-Path -LiteralPath $Output) { throw "Pack output already exists: $Output" }
    $Output = [IO.Path]::GetFullPath($Output)
    for ($attempt = 1; ; $attempt++) {
        Write-TreeParts $Directory $Output
        $problem = Test-TreeChecksums $Output
        if (-not $problem -and -not (Test-TreeStream $Output)) { $problem = 'the stored parts do not decompress' }
        if (-not $problem) { break }
        if ($attempt -ge 2) { throw "Packed tree failed verification twice: $problem" }
        Write-Warning "Packed tree failed verification ($problem); packing again"
        Remove-Item -LiteralPath $Output -Recurse -Force
    }
    Write-Host "Packed $Directory into $((Get-TreeParts $Output).Count) verified parts"
} else {
    if (-not $Parts) { throw 'A parts directory is required' }
    $files = Get-TreeParts $Parts
    if (-not $files.Count) { throw "No tree parts in $Parts" }
    $problem = Test-TreeChecksums $Parts
    if ($problem) { throw "Downloaded tree parts are corrupt: $problem" }
    Remove-Item -LiteralPath (Join-Path $Parts $checksumName) -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Directory) { throw "Restore directory already exists: $Directory" }
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $decompress = Start-StreamProcess $zstd @('-q', '-d', '-c') $true $true
    $feed = Start-ThreadJob -ArgumentList $decompress.StandardInput.BaseStream, ([string[]]$files.FullName) -ScriptBlock {
        param($stream, $files)
        $ErrorActionPreference = 'Stop'
        try {
            foreach ($path in $files) {
                $file = [IO.File]::OpenRead($path)
                try { $file.CopyTo($stream) } finally { $file.Dispose() }
                Remove-Item -LiteralPath $path -Force
            }
        } finally { $stream.Close() }
    }
    $tarProcess = $null
    try {
        if ($IsWindows) {
            Read-CefWindowsTree $decompress.StandardOutput.BaseStream $Directory
            $decompress.StandardOutput.BaseStream.CopyTo([IO.Stream]::Null)
        } else {
            $tarProcess = Start-StreamProcess $tar @('-xf', '-', '-C', $Directory) $true $false
            $decompress.StandardOutput.BaseStream.CopyTo($tarProcess.StandardInput.BaseStream)
            $tarProcess.StandardInput.Close()
            $tarProcess.WaitForExit()
            if ($tarProcess.ExitCode -ne 0) { throw "Tree extraction failed: $($tarProcess.ExitCode)" }
        }
        Receive-Job -Job $feed -Wait -ErrorAction Stop
        $decompress.WaitForExit()
        if ($decompress.ExitCode -ne 0) { throw "Tree decompression failed: $($decompress.ExitCode)" }
        Write-Host "Restored tree into $Directory"
    } finally {
        if (-not $decompress.HasExited) { $decompress.Kill($true); $decompress.WaitForExit() }
        if ($tarProcess -and -not $tarProcess.HasExited) { $tarProcess.Kill($true); $tarProcess.WaitForExit() }
        if ($feed.State -eq 'Running') { Stop-Job $feed }
        Remove-Job $feed -Force
        if ($tarProcess) { $tarProcess.Dispose() }
        $decompress.Dispose()
    }
}
