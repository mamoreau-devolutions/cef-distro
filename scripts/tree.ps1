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

if ($Mode -eq 'pack') {
    if (-not $Output -or $PartSize -le 0) { throw 'A pack output and positive part size are required' }
    $Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
    if (Test-Path -LiteralPath $Output) { throw "Pack output already exists: $Output" }
    New-Item -ItemType Directory -Path $Output | Out-Null
    $Output = (Resolve-Path -LiteralPath $Output).ProviderPath
    $compress = Start-StreamProcess $zstd @('-q', '-T0', '-3', '-c') $true $true
    $split = Start-ThreadJob -ArgumentList $compress.StandardOutput.BaseStream, $Output, $PartSize -ScriptBlock {
        param($stream, $output, $partSize)
        $ErrorActionPreference = 'Stop'
        $buffer = [byte[]]::new(8MB)
        $part = $null
        $count = 0
        $written = 0
        try {
            while (($length = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $offset = 0
                while ($offset -lt $length) {
                    if ($null -eq $part -or $written -eq $partSize) {
                        if ($part) { $part.Dispose() }
                        $part = [IO.File]::Create((Join-Path $output ('tree.tar.zst.{0:D4}' -f $count)))
                        $count++
                        $written = 0
                    }
                    $take = [int][Math]::Min($length - $offset, $partSize - $written)
                    $part.Write($buffer, $offset, $take)
                    $offset += $take
                    $written += $take
                }
            }
        } finally {
            if ($part) { $part.Dispose() }
        }
        return $count
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
        $count = Receive-Job -Job $split -Wait -ErrorAction Stop
        $compress.WaitForExit()
        if ($compress.ExitCode -ne 0 -or $count -lt 1) { throw "Tree compression failed: $($compress.ExitCode)" }
        Write-Host "Packed $Directory into $count parts"
    } finally {
        if (-not $compress.HasExited) { $compress.Kill($true); $compress.WaitForExit() }
        if ($tarProcess -and -not $tarProcess.HasExited) { $tarProcess.Kill($true); $tarProcess.WaitForExit() }
        if ($split.State -eq 'Running') { Stop-Job $split }
        Remove-Job $split -Force
        if ($tarProcess) { $tarProcess.Dispose() }
        $compress.Dispose()
    }
} else {
    if (-not $Parts) { throw 'A parts directory is required' }
    $files = @(Get-ChildItem -LiteralPath $Parts -Filter 'tree.tar.zst.*' -File | Sort-Object Name)
    if (-not $files.Count) { throw "No tree parts in $Parts" }
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
