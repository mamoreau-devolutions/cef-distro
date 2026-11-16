function Write-CefWindowsTree([string]$Directory, [IO.Stream]$Stream) {
    $writer = [System.Formats.Tar.TarWriter]::new($Stream, [System.Formats.Tar.TarEntryFormat]::Pax, $true)
    try {
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($Directory)
        while ($pending.Count) {
            $folder = $pending.Pop()
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($folder)) {
                $item = Get-Item -LiteralPath $path -Force
                $relative = [IO.Path]::GetRelativePath($Directory, $path).Replace('\', '/')
                $isLink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                $extra = [Collections.Generic.Dictionary[string,string]]::new()
                if ($isLink -and $item.PSIsContainer) { $extra['CEF.directory_link'] = '1' }
                $type = if ($isLink) {
                    [System.Formats.Tar.TarEntryType]::SymbolicLink
                } elseif ($item.PSIsContainer) {
                    [System.Formats.Tar.TarEntryType]::Directory
                } else {
                    [System.Formats.Tar.TarEntryType]::RegularFile
                }
                $entry = [System.Formats.Tar.PaxTarEntry]::new($type, $relative, $extra)
                $entry.ModificationTime = [DateTimeOffset]::new($item.LastWriteTimeUtc)
                if ($isLink) {
                    if (-not $item.LinkTarget) { throw "Cannot read link target: $path" }
                    $entry.LinkName = $item.LinkTarget
                    $writer.WriteEntry($entry)
                } elseif ($item.PSIsContainer) {
                    $writer.WriteEntry($entry)
                    $pending.Push($path)
                } else {
                    $file = [IO.File]::OpenRead($path)
                    try {
                        $entry.DataStream = $file
                        $writer.WriteEntry($entry)
                    } finally {
                        $file.Dispose()
                    }
                }
            }
        }
    } finally {
        $writer.Dispose()
    }
}

function Read-CefWindowsTree([IO.Stream]$Stream, [string]$Directory) {
    $reader = [System.Formats.Tar.TarReader]::new($Stream, $true)
    $times = [Collections.Generic.List[object]]::new()
    try {
        while ($entry = $reader.GetNextEntry($false)) {
            $name = $entry.Name.Replace('\', '/')
            $parts = $name.Split('/')
            if ([IO.Path]::IsPathRooted($name) -or $parts -contains '..' -or
                ($parts[0] -match '^[A-Za-z]:')) { throw "Unsafe tree entry: $name" }
            $target = Join-Path $Directory ($name.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $parent = Split-Path $target -Parent
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            $isLink = $false
            switch ($entry.EntryType) {
                { $_ -in @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile) } {
                    $file = [IO.File]::Create($target)
                    try {
                        if ($entry.DataStream) { $entry.DataStream.CopyTo($file) }
                    } finally { $file.Dispose() }
                }
                ([System.Formats.Tar.TarEntryType]::Directory) {
                    [IO.Directory]::CreateDirectory($target) | Out-Null
                }
                ([System.Formats.Tar.TarEntryType]::SymbolicLink) {
                    $isLink = $true
                    $directoryLink = $entry -is [System.Formats.Tar.PaxTarEntry] -and
                        $entry.ExtendedAttributes.ContainsKey('CEF.directory_link') -and
                        $entry.ExtendedAttributes['CEF.directory_link'] -ceq '1'
                    if ($directoryLink) {
                        [IO.Directory]::CreateSymbolicLink($target, $entry.LinkName) | Out-Null
                    } else {
                        [IO.File]::CreateSymbolicLink($target, $entry.LinkName) | Out-Null
                    }
                }
                ([System.Formats.Tar.TarEntryType]::HardLink) {
                    $linkName = $entry.LinkName.Replace('\', '/')
                    if ([IO.Path]::IsPathRooted($linkName) -or $linkName.Split('/') -contains '..' -or
                        $linkName -match '^[A-Za-z]:') { throw "Unsafe hard link: $linkName" }
                    $linkTarget = Join-Path $Directory ($linkName.Replace('/', [IO.Path]::DirectorySeparatorChar))
                    New-Item -ItemType HardLink -Path $target -Target $linkTarget | Out-Null
                }
                default { throw "Unsupported tree entry type $($entry.EntryType): $name" }
            }
            if (-not $isLink) {
                $times.Add([pscustomobject]@{ Path = $target; Time = $entry.ModificationTime.UtcDateTime; Type = $entry.EntryType })
            }
        }
        for ($i = $times.Count - 1; $i -ge 0; $i--) {
            $time = $times[$i]
            if ($time.Type -eq [System.Formats.Tar.TarEntryType]::Directory) {
                [IO.Directory]::SetLastWriteTimeUtc($time.Path, $time.Time)
            } else {
                [IO.File]::SetLastWriteTimeUtc($time.Path, $time.Time)
            }
        }
    } finally {
        $reader.Dispose()
    }
}
