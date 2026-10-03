Set-StrictMode -Version 2.0

function Get-RclConfig {
    param(
        [string]$LocalRoot = [Environment]::GetFolderPath('LocalApplicationData'),
        [string]$TempRoot = [IO.Path]::GetTempPath()
    )
    foreach ($root in @($LocalRoot, $TempRoot)) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not [IO.Path]::IsPathRooted($root)) {
            throw 'Windows user folders could not be resolved. No cleanup is permitted.'
        }
        if ([IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar) -eq [IO.Path]::GetPathRoot($root).TrimEnd([IO.Path]::DirectorySeparatorChar)) {
            throw 'A drive root cannot be used as a user folder.'
        }
    }
    @(
        [pscustomobject]@{Id='logs'; Category='Logs'; Name='Roblox logs'; Root=(Join-Path $LocalRoot 'Roblox/logs'); Mode='Logs'}
        [pscustomobject]@{Id='cache'; Category='Cache'; Name='Roblox asset cache'; Root=(Join-Path $LocalRoot 'Roblox/Cache'); Mode='Cache'}
        [pscustomobject]@{Id='http'; Category='Cache'; Name='Temporary HTTP cache'; Root=(Join-Path $TempRoot 'Roblox/http'); Mode='Cache'}
        [pscustomobject]@{Id='sounds'; Category='Cache'; Name='Temporary sound cache'; Root=(Join-Path $TempRoot 'Roblox/sounds'); Mode='Cache'}
        [pscustomobject]@{Id='crashes'; Category='Crashes'; Name='Roblox crash dumps'; Root=(Join-Path $LocalRoot 'CrashDumps'); Mode='Crashes'}
        [pscustomobject]@{Id='local-http'; Category='Cache'; Name='Local HTTP cache'; Root=(Join-Path $LocalRoot 'Roblox/http'); Mode='Cache'}
        [pscustomobject]@{Id='local-sounds'; Category='Cache'; Name='Local sound cache'; Root=(Join-Path $LocalRoot 'Roblox/sounds'); Mode='Cache'}
        [pscustomobject]@{Id='temp-cache'; Category='Cache'; Name='Temporary asset cache'; Root=(Join-Path $TempRoot 'Roblox/Cache'); Mode='Cache'}
        [pscustomobject]@{Id='local-payload'; Category='DeepCache'; Name='Local asset payloads'; Root=(Join-Path $LocalRoot 'Roblox/rbx-storage'); Mode='Payload'}
        [pscustomobject]@{Id='local-payload-sc'; Category='DeepCache'; Name='Local secondary payloads'; Root=(Join-Path $LocalRoot 'Roblox/rbx-storage-sc'); Mode='Payload'}
        [pscustomobject]@{Id='temp-payload'; Category='DeepCache'; Name='Temporary asset payloads'; Root=(Join-Path $TempRoot 'Roblox/rbx-storage'); Mode='Payload'}
        [pscustomobject]@{Id='temp-payload-sc'; Category='DeepCache'; Name='Temporary secondary payloads'; Root=(Join-Path $TempRoot 'Roblox/rbx-storage-sc'); Mode='Payload'}
        [pscustomobject]@{Id='local-shaders'; Category='DeepCache'; Name='Local shader cache files'; Root=(Join-Path $LocalRoot 'Roblox'); Mode='Shaders'}
        [pscustomobject]@{Id='temp-shaders'; Category='DeepCache'; Name='Temporary shader cache files'; Root=(Join-Path $TempRoot 'Roblox'); Mode='Shaders'}
    )
}

function Format-RclBytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

function Get-RclRunningProcesses {
    # Fail closed if process enumeration itself fails. Never stop a process.
    @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^Roblox' } | Select-Object -ExpandProperty ProcessName -Unique)
}

function Test-RclPlainPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    # Check the entry AND all ancestors, including the user-folder ancestors.
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    return $true
}

function Test-RclCandidate {
    param($Item, $Target, [datetime]$CutoffUtc)
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if (($Item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { return $false }
    if ($Item.LastWriteTimeUtc -gt $CutoffUtc) { return $false }
    $full = [IO.Path]::GetFullPath($Item.FullName)
    $prefix = [IO.Path]::GetFullPath($Target.Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    switch ($Target.Mode) {
        'Shaders' {
            return ($Item.DirectoryName -ieq [IO.Path]::GetFullPath($Target.Root)) -and
                ($Item.Name -match '^shadercache(?:vk)?\.bin$')
        }
        'Logs' { return $Item.Extension -ieq '.log' }
        'Crashes' {
            return ($Item.DirectoryName -ieq [IO.Path]::GetFullPath($Target.Root)) -and
                ($Item.Name -match '^Roblox(?:PlayerBeta|StudioBeta|Player|Studio)\.exe\.\d+\.dmp$')
        }
        { $_ -in @('Cache','Payload') } {
            # Protect saved work, executable code, local settings and databases,
            # even if somebody put them into one of the cache locations.
            $relative = $full.Substring($prefix.Length)
            return $Item.Extension -notmatch '^\.(rbxlx?|rbxmx?|lua|luau|py|js|ps1|psm1|bat|cmd|vbs|exe|dll|msi|json|xml|ini|cfg|db(?:-(?:wal|shm|journal))?|sqlite|sqlite3|wal|shm)$' -and
                $relative -notmatch '(?i)(autosave|autorecover|recovery|clientsettings|rbx-storage|credential|cookie|password|token|auth|session|login|userdata)'
        }
        default { return $false }
    }
}

function Get-RclSnapshot {
    param(
        [object[]]$Config = (Get-RclConfig),
        [ValidateRange(0,365)][int]$KeepDays = 7,
        [hashtable]$Control = @{Cancel=$false},
        [ValidateRange(1,1000000)][int]$MaxEntries = 250000
    )
    $cutoff = [datetime]::UtcNow.AddDays(-$KeepDays)
    $files = New-Object 'System.Collections.Generic.List[object]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $summary = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $entries = 0
    $Control['Phase']='Scanning'; $Control['Processed']=0; $Control['Total']=0
    $limited = $false
    foreach ($target in $Config) {
        $count = 0; [long]$bytes = 0; $state = 'Not found'
        if ($Control.Cancel -or $limited) { break }
        try {
            if (-not (Test-Path -LiteralPath $target.Root)) {
                $summary.Add([pscustomobject]@{Id=$target.Id; Category=$target.Category; Name=$target.Name; Path=$target.Root; Count=0; Bytes=0; Size='0 bytes'; State=$state})
                continue
            }
            if (-not (Test-RclPlainPath $target.Root)) { throw 'Linked folder skipped.' }
            $rootItem = Get-Item -LiteralPath $target.Root -Force -ErrorAction Stop
            if (-not $rootItem.PSIsContainer) { throw 'Expected a directory; skipped.' }
            $state = 'Scanned'
            $stack = New-Object 'System.Collections.Generic.Stack[string]'
            $stack.Push($target.Root)
            while ($stack.Count -gt 0 -and -not $Control.Cancel -and -not $limited) {
                $dir = $stack.Pop()
                try {
                    if (-not (Test-RclPlainPath $dir)) { throw 'Linked directory skipped.' }
                    # Enumerate lazily: never load an entire large cache into memory.
                    $iterator = [IO.Directory]::EnumerateFileSystemEntries($dir).GetEnumerator()
                    try {
                        while ($iterator.MoveNext()) {
                            if ($Control.Cancel) { break }
                            $entries++
                            $Control['Processed']=$entries
                            if ($entries -gt $MaxEntries) { $limited = $true; break }
                            try {
                                $item = Get-Item -LiteralPath $iterator.Current -Force -ErrorAction Stop
                                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                                    $warnings.Add("Linked entry skipped: $($item.FullName)")
                                    continue
                                }
                                if ($item.PSIsContainer) {
                                    if ($target.Mode -notin @('Crashes','Shaders') -and $item.Name -notmatch '(?i)(autosave|autorecover|recovery|clientsettings)') { $stack.Push($item.FullName) }
                                } elseif ((Test-RclCandidate $item $target $cutoff) -and $seen.Add($item.FullName)) {
                                    $files.Add([pscustomobject]@{
                                        TargetId=$target.Id; Category=$target.Category; Path=$item.FullName
                                        Length=[long]$item.Length; LastWriteTicks=$item.LastWriteTimeUtc.Ticks
                                    })
                                    $count++; $bytes += $item.Length
                                }
                            } catch { $warnings.Add("Unreadable entry: $($iterator.Current) - $($_.Exception.Message)"); $state='Partial' }
                        }
                    } finally { if ($iterator -is [IDisposable]) { $iterator.Dispose() } }
                } catch { $warnings.Add("Cannot scan $dir - $($_.Exception.Message)"); $state='Partial' }
            }
        } catch { $state='Skipped'; $warnings.Add("$($target.Root): $($_.Exception.Message)") }
        $summary.Add([pscustomobject]@{Id=$target.Id; Category=$target.Category; Name=$target.Name; Path=$target.Root; Count=$count; Bytes=$bytes; Size=(Format-RclBytes $bytes); State=$state})
    }
    if ($limited) { $warnings.Add("Scan limit ($MaxEntries entries) reached. Cleanup disabled; use a smaller cache or inspect it manually.") }
    [pscustomobject]@{
        Files=$files.ToArray(); Summary=$summary.ToArray(); Warnings=$warnings.ToArray()
        CutoffUtc=$cutoff; KeepDays=$KeepDays; Cancelled=[bool]$Control.Cancel; Limited=$limited
        Complete=(-not $Control.Cancel -and -not $limited); ScannedUtc=[datetime]::UtcNow
    }
}

function Invoke-RclCleanup {
    param(
        [Parameter(Mandatory=$true)]$Snapshot,
        [Parameter(Mandatory=$true)][string[]]$Categories,
        [object[]]$Config = (Get-RclConfig),
        [hashtable]$Control = @{Cancel=$false},
        [scriptblock]$ProcessProbe = { Get-RclRunningProcesses }
    )
    if (-not $Snapshot.Complete) { throw 'A complete scan is required before cleanup.' }
    $running = @(& $ProcessProbe)
    if ($running.Count -gt 0) { throw ('Close Roblox before cleaning: ' + ($running -join ', ')) }
    $selected=@($Snapshot.Files | Where-Object { $_.Category -in $Categories })
    $Control['Phase']='Cleaning'; $Control['Total']=$selected.Count; $Control['Processed']=0
    $results = New-Object 'System.Collections.Generic.List[object]'
    [long]$removedBytes=0; $removed=0; $skipped=0; $index=0; $blocked=$false
    foreach ($record in $selected) {
        if ($Control.Cancel) { break }
        $index++
        $status='Skipped'; $detail=''; [long]$size=0
        try {
            if (($index % 50) -eq 1) {
                $running = @(& $ProcessProbe)
                if ($running.Count -gt 0) { $blocked=$true; throw 'Roblox opened during cleanup; remaining files were left alone.' }
            }
            if ($blocked) { throw 'Roblox is running.' }
            $targets = @($Config | Where-Object { $_.Id -eq $record.TargetId -and $_.Category -eq $record.Category })
            if ($targets.Count -ne 1) { throw 'Unknown cleanup target.' }
            if (-not (Test-RclPlainPath $record.Path)) { throw 'A file or parent folder is now a link.' }
            $item = Get-Item -LiteralPath $record.Path -Force -ErrorAction Stop
            if (-not (Test-RclCandidate $item $targets[0] $Snapshot.CutoffUtc)) { throw 'File is outside the cleanup rules.' }
            if ($item.Length -ne $record.Length -or $item.LastWriteTimeUtc.Ticks -ne $record.LastWriteTicks) {
                throw 'File changed after the scan. Scan again.'
            }
            $size = $item.Length
            # Only the exact previewed file is removed. No recursive deletion or folder removal.
            Remove-Item -LiteralPath $item.FullName -ErrorAction Stop
            $removed++; $removedBytes += $size; $status='Removed'
        } catch { $skipped++; $detail=$_.Exception.Message }
        $results.Add([pscustomobject]@{Status=$status; Category=$record.Category; Path=$record.Path; Bytes=$size; Detail=$detail})
        $Control['Processed']=$index
        if ($blocked) { break }
    }
    [pscustomobject]@{
        Removed=$removed; RemovedBytes=$removedBytes; Skipped=$skipped; Results=$results.ToArray()
        Pending=($selected.Count-$index)
        Cancelled=[bool]$Control.Cancel; Blocked=$blocked; FinishedUtc=[datetime]::UtcNow
    }
}

Export-ModuleMember -Function Get-RclConfig, Format-RclBytes, Get-RclRunningProcesses, Get-RclSnapshot, Invoke-RclCleanup
