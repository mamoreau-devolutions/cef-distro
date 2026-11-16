param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidateSet('linux-x64', 'linux-arm64', 'windows-x64', 'windows-arm64', 'macos-x64', 'macos-arm64')][string]$Target,
    [Parameter(Mandatory)][long]$Deadline
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'build-env.ps1')
$Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
Set-CefBuildEnvironment $Directory $Target
$platform, $arch = $Target.Split('-')
$src = Join-Path $Directory 'chromium' 'src'
$ninjaName = if ($IsWindows) { 'ninja.exe' } else { 'ninja' }
$ninja = Join-Path $src 'third_party' 'ninja' $ninjaName
$targets = switch ($platform) {
    'linux' { @('cefsimple', 'chrome_sandbox') }
    'windows' { @('cefclient', 'bootstrap', 'bootstrapc') }
    'macos' { @('cefclient') }
}
$arguments = @('-C', "out/Release_GN_$arch") + $targets
Write-Host "+ $ninja $($arguments -join ' ')"
if ($IsWindows) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class CefNinjaProcess {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
        public short showWindow, reserved2;
        public IntPtr reservedPtr, stdInput, stdOutput, stdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo {
        public IntPtr process, thread;
        public int processId, threadId;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment,
        string directory, ref StartupInfo startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GenerateConsoleCtrlEvent(uint signal, uint groupId);
    public static Process Start(string executable, string directory, string[] arguments) {
        var startup = new StartupInfo {
            cb = Marshal.SizeOf<StartupInfo>(), flags = 0x100,
            stdInput = GetStdHandle(-10), stdOutput = GetStdHandle(-11), stdError = GetStdHandle(-12)
        };
        var command = new StringBuilder("\"" + executable + "\"");
        foreach (var argument in arguments) {
            if (argument.IndexOfAny(new[] {' ', '\t', '"'}) >= 0)
                throw new ArgumentException("Unexpected ninja argument: " + argument);
            command.Append(' ').Append(argument);
        }
        ProcessInfo info;
        if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, true, 0x200,
            IntPtr.Zero, directory, ref startup, out info))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Starting ninja failed");
        try {
            var process = Process.GetProcessById(info.processId);
            var handle = process.SafeHandle;
            return process;
        }
        finally { CloseHandle(info.thread); CloseHandle(info.process); }
    }
    public static void Interrupt(int pid) {
        if (!GenerateConsoleCtrlEvent(1, (uint)pid))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Interrupting ninja failed");
    }
}
'@
    $process = [CefNinjaProcess]::Start($ninja, $src, [string[]]$arguments)
} else {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $ninja
    $start.WorkingDirectory = $src
    $start.UseShellExecute = $false
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
}
try {
    $remaining = [Math]::Max(0, $Deadline - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $milliseconds = [int][Math]::Min([int]::MaxValue, $remaining * 1000)
    if ($process.WaitForExit($milliseconds)) {
        if ($process.ExitCode -ne 0) { throw "Ninja failed with exit code $($process.ExitCode)" }
        $complete = $true
    } else {
        Write-Host 'Deadline reached; interrupting ninja to resume in the next stage.'
        try {
            if (-not $process.HasExited) {
                if ($IsWindows) {
                    [CefNinjaProcess]::Interrupt($process.Id)
                } else {
                    & /bin/kill -INT $process.Id
                    if ($LASTEXITCODE -ne 0 -and -not $process.HasExited) { throw 'Interrupting ninja failed' }
                }
            }
        } catch {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            throw
        }
        if (-not $process.WaitForExit(300000)) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $complete = $false
    }
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Encoding utf8 -LiteralPath $env:GITHUB_OUTPUT -Value "complete=$($complete.ToString().ToLowerInvariant())"
    }
    Write-Host $(if ($complete) { 'Build complete.' } else { 'Build incomplete; resume required.' })
} finally {
    $process.Dispose()
}
