if (-not ('CefWindowsTree' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Formats.Tar;
using System.IO;
using System.Runtime.InteropServices;

public static class CefWindowsTree
{
    const string DirectoryLink = "CEF.directory_link";

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLinkW(string fileName, string existingFileName, IntPtr securityAttributes);

    public static long Write(string root, Stream stream)
    {
        long count = 0;
        using (var writer = new TarWriter(stream, TarEntryFormat.Pax, true))
        {
            var pending = new Stack<DirectoryInfo>();
            pending.Push(new DirectoryInfo(root));
            while (pending.Count > 0)
            {
                foreach (var item in pending.Pop().EnumerateFileSystemInfos())
                {
                    string relative = Path.GetRelativePath(root, item.FullName).Replace('\\', '/');
                    bool isLink = (item.Attributes & FileAttributes.ReparsePoint) != 0;
                    bool isDirectory = (item.Attributes & FileAttributes.Directory) != 0;
                    var extra = new Dictionary<string, string>();
                    if (isLink && isDirectory) extra[DirectoryLink] = "1";
                    var type = isLink ? TarEntryType.SymbolicLink
                        : isDirectory ? TarEntryType.Directory : TarEntryType.RegularFile;
                    var entry = new PaxTarEntry(type, relative, extra);
                    entry.ModificationTime = new DateTimeOffset(item.LastWriteTimeUtc);
                    if (isLink)
                    {
                        if (string.IsNullOrEmpty(item.LinkTarget)) throw new IOException("Cannot read link target: " + item.FullName);
                        entry.LinkName = item.LinkTarget;
                        writer.WriteEntry(entry);
                    }
                    else if (isDirectory)
                    {
                        writer.WriteEntry(entry);
                        pending.Push((DirectoryInfo)item);
                    }
                    else
                    {
                        using (var file = new FileStream(item.FullName, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
                        {
                            entry.DataStream = file;
                            writer.WriteEntry(entry);
                        }
                    }
                    if (++count % 50000 == 0) Console.WriteLine("Archived " + count + " entries; last: " + relative);
                }
            }
        }
        return count;
    }

    static string SafePath(string root, string name, string what)
    {
        name = name.Replace('\\', '/');
        string[] parts = name.Split('/');
        if (Path.IsPathRooted(name) || Array.IndexOf(parts, "..") >= 0 ||
            (parts[0].Length >= 2 && parts[0][1] == ':' && char.IsLetter(parts[0][0])))
            throw new IOException("Unsafe " + what + ": " + name);
        return Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar));
    }

    public static long Read(Stream stream, string root)
    {
        var times = new List<(string Path, DateTime Time, bool Directory)>();
        using (var reader = new TarReader(stream, true))
        {
            TarEntry entry;
            while ((entry = reader.GetNextEntry(false)) != null)
            {
                string target = SafePath(root, entry.Name, "tree entry");
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                bool isLink = false;
                switch (entry.EntryType)
                {
                    case TarEntryType.RegularFile:
                    case TarEntryType.V7RegularFile:
                        using (var file = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
                        {
                            if (entry.DataStream != null) entry.DataStream.CopyTo(file);
                        }
                        break;
                    case TarEntryType.Directory:
                        Directory.CreateDirectory(target);
                        break;
                    case TarEntryType.SymbolicLink:
                        isLink = true;
                        string flag;
                        var pax = entry as PaxTarEntry;
                        if (pax != null && pax.ExtendedAttributes.TryGetValue(DirectoryLink, out flag) && flag == "1")
                            Directory.CreateSymbolicLink(target, entry.LinkName);
                        else
                            File.CreateSymbolicLink(target, entry.LinkName);
                        break;
                    case TarEntryType.HardLink:
                        string existing = SafePath(root, entry.LinkName, "hard link");
                        if (!CreateHardLinkW(target, existing, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create hard link " + target);
                        break;
                    default:
                        throw new IOException("Unsupported tree entry type " + entry.EntryType + ": " + entry.Name);
                }
                if (!isLink) times.Add((target, entry.ModificationTime.UtcDateTime, entry.EntryType == TarEntryType.Directory));
                if (times.Count % 50000 == 0 && !isLink) Console.WriteLine("Restored " + times.Count + " entries; last: " + entry.Name);
            }
        }
        for (int i = times.Count - 1; i >= 0; i--)
        {
            if (times[i].Directory) Directory.SetLastWriteTimeUtc(times[i].Path, times[i].Time);
            else File.SetLastWriteTimeUtc(times[i].Path, times[i].Time);
        }
        return times.Count;
    }
}
"@
}

function Write-CefWindowsTree([string]$Directory, [IO.Stream]$Stream) {
    $count = [CefWindowsTree]::Write($Directory, $Stream)
    Write-Host "Archived $count entries"
}

function Read-CefWindowsTree([IO.Stream]$Stream, [string]$Directory) {
    $count = [CefWindowsTree]::Read($Stream, $Directory)
    Write-Host "Restored $count entries"
}
