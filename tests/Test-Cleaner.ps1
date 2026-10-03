#requires -Version 5.1
# Tests operate exclusively inside a newly created test folder.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Cleaner.Core.psm1') -Force
$script:passed=0
$script:skipped=0
function Assert([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
function OldFile([string]$Path,[string]$Content='old test data') {
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    [IO.File]::WriteAllText($Path,$Content)
    [IO.File]::SetLastWriteTimeUtc($Path,[datetime]::UtcNow.AddDays(-45))
    return $Path
}
function Snapshot { Get-RclSnapshot -Config $config -KeepDays 7 }
function RunCleanup($Snap,[string[]]$Categories=@('Logs','Cache','Crashes')) {
    Invoke-RclCleanup -Snapshot $Snap -Categories $Categories -Config $config -ProcessProbe { @() }
}
function Throws([scriptblock]$Action,[string]$Message) {
    $caught=$false
    try { & $Action | Out-Null } catch { $caught=$true }
    Assert $caught $Message
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('RclTests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$local=Join-Path $testRoot 'local'; $temp=Join-Path $testRoot 'temp'
[void][IO.Directory]::CreateDirectory($local); [void][IO.Directory]::CreateDirectory($temp)
$config=@(Get-RclConfig -LocalRoot $local -TempRoot $temp)
$isWindowsTest=($env:OS -eq 'Windows_NT')
$linkPaths=New-Object 'System.Collections.Generic.List[string]'
try {
    $log=OldFile (Join-Path $local 'Roblox/logs/old.log')
    $newLog=OldFile (Join-Path $local 'Roblox/logs/new.log')
    [IO.File]::SetLastWriteTimeUtc($newLog,[datetime]::UtcNow)
    $nonLog=OldFile (Join-Path $local 'Roblox/logs/keep.txt')
    $http=OldFile (Join-Path $temp 'Roblox/http/nested/cache[1].bin')
    $sound=OldFile (Join-Path $temp 'Roblox/sounds/sound.dat')
    $asset=OldFile (Join-Path $local 'Roblox/Cache/asset.png')
    $place=OldFile (Join-Path $local 'Roblox/Cache/important.rbxl')
    $settings=OldFile (Join-Path $local 'Roblox/Cache/settings.json')
    $code=OldFile (Join-Path $local 'Roblox/Cache/code.luau')
    $recovery=OldFile (Join-Path $local 'Roblox/Cache/AutoSaves/untitled.tmp')
    $database=OldFile (Join-Path $temp 'Roblox/rbx-storage.db')
    $installation=OldFile (Join-Path $local 'Roblox/Versions/version-123/RobloxPlayerBeta.exe')
    $client=OldFile (Join-Path $local 'Roblox/ClientSettings/ClientAppSettings.json')
    $outside=OldFile (Join-Path $testRoot 'outside/untouched.bin')
    $dump=OldFile (Join-Path $local 'CrashDumps/RobloxPlayerBeta.exe.1234.dmp')
    $otherDump=OldFile (Join-Path $local 'CrashDumps/OtherApp.exe.1234.dmp')
    $nestedDump=OldFile (Join-Path $local 'CrashDumps/nested/RobloxPlayerBeta.exe.4321.dmp')
    $snap=Snapshot
    Assert ($snap.Files.Count -eq 5) 'Only five eligible cache, log and Roblox dump files appear'
    Assert ($snap.Complete -and -not $snap.Cancelled) 'Normal scan completes'
    Assert (Test-Path -LiteralPath $log) 'Scan is read-only'
    Assert (@($snap.Files | ForEach-Object { $_.Path }) -notcontains $newLog) 'Newest logs retained'
    Assert (@($snap.Files | ForEach-Object { $_.Path }) -notcontains $recovery) 'Recovery directory excluded'
    Assert (@($snap.Files | ForEach-Object { $_.Path }) -notcontains $nestedDump) 'Nested shared crash folders excluded'
    $result=RunCleanup $snap @('Logs')
    Assert ($result.Removed -eq 1 -and $result.Skipped -eq 0) 'Only selected log category cleaned'
    Assert (-not (Test-Path -LiteralPath $log)) 'Previewed log removed'
    Assert (Test-Path -LiteralPath $http) 'Unselected cache retained'
    $result=RunCleanup (Snapshot)
    Assert ($result.Removed -eq 4) 'Cache and exact Roblox crash dump removed'
    foreach ($path in @($newLog,$nonLog,$place,$settings,$code,$recovery,$database,$installation,$client,$outside,$otherDump,$nestedDump)) {
        Assert (Test-Path -LiteralPath $path) ('Protected file preserved: '+[IO.Path]::GetFileName($path))
    }
    Assert (Test-Path -LiteralPath (Split-Path $http -Parent)) 'Cleanup leaves cache directories intact'

    $changed=OldFile (Join-Path $temp 'Roblox/http/changed.bin')
    $snap=Snapshot
    [IO.File]::WriteAllText($changed,'changed after preview')
    $result=RunCleanup $snap
    Assert ($result.Removed -eq 0 -and $result.Skipped -eq 1) 'Changed file skipped after preview'
    Assert (Test-Path -LiteralPath $changed) 'Changed file remains'

    $newFile=OldFile (Join-Path $temp 'Roblox/http/only-preview.bin')
    $snap=Snapshot
    $later=OldFile (Join-Path $temp 'Roblox/http/added-after-scan.bin')
    $result=RunCleanup $snap
    Assert (Test-Path -LiteralPath $later) 'New files never added to a cleanup implicitly'

    $snap=Snapshot
    Throws { Invoke-RclCleanup -Snapshot $snap -Categories @('Cache') -Config $config -ProcessProbe { 'RobloxStudioBeta' } } 'Running Studio blocks cleanup'
    Assert (Test-Path -LiteralPath $later) 'Blocked cleanup makes no changes'
    Throws { Invoke-RclCleanup -Snapshot $snap -Categories @('Cache') -Config $config -ProcessProbe { throw 'Enumeration failed' } } 'Failed process checks block cleanup'

    $clockFile=OldFile (Join-Path $temp 'Roblox/http/time-change.bin')
    $clockSnap=Snapshot
    [IO.File]::SetLastWriteTimeUtc($clockFile,[datetime]::UtcNow.AddDays(-40))
    $clockResult=RunCleanup $clockSnap
    Assert (Test-Path -LiteralPath $clockFile) 'Changed modification time also blocks deletion'

    # Initial check plus first batch succeed; the next batch sees Roblox start.
    foreach ($n in 1..55) { [void](OldFile (Join-Path $temp ('Roblox/http/batch-{0}.bin' -f $n))) }
    $batchSnap=Snapshot
    $probeState=@{Calls=0}
    $probe={ $probeState.Calls++; if($probeState.Calls -ge 3){ 'RobloxPlayerBeta' } }.GetNewClosure()
    $batchResult=Invoke-RclCleanup -Snapshot $batchSnap -Categories @('Cache') -Config $config -ProcessProbe $probe
    Assert ($batchResult.Blocked -and $batchResult.Removed -eq 50) 'Roblox reopening stops cleanup at the next batch check'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $temp 'Roblox/http') -File).Count -gt 0) 'Unprocessed files remain after Roblox reopens'
    [void](RunCleanup (Snapshot))

    $forged=[pscustomobject]@{
        Complete=$true; CutoffUtc=[datetime]::UtcNow; Files=@([pscustomobject]@{
            TargetId='http'; Category='Cache'; Path=$outside; Length=(Get-Item -LiteralPath $outside).Length
            LastWriteTicks=(Get-Item -LiteralPath $outside).LastWriteTimeUtc.Ticks
        })
    }
    $result=RunCleanup $forged
    Assert ($result.Skipped -eq 1 -and (Test-Path -LiteralPath $outside)) 'Outside-root manifest record rejected'
    $forged.Files[0].TargetId='unknown'
    $result=RunCleanup $forged
    Assert ($result.Skipped -eq 1) 'Unknown target rejected'

    $limit=Get-RclSnapshot -Config $config -KeepDays 7 -MaxEntries 2
    Assert ($limit.Limited -and -not $limit.Complete) 'Scan entry cap disables cleanup'
    Throws { RunCleanup $limit } 'Incomplete scan cannot clean'
    $cancel=Get-RclSnapshot -Config $config -Control @{Cancel=$true}
    Assert ($cancel.Cancelled -and -not $cancel.Complete) 'Cancelled scan disables cleanup'
    $result=Invoke-RclCleanup -Snapshot $snap -Categories @('Cache') -Config $config -Control @{Cancel=$true} -ProcessProbe { @() }
    Assert ($result.Cancelled -and $result.Removed -eq 0) 'Cleanup cancellation leaves pending files'

    $link=Join-Path $temp 'Roblox/http/external-link'
    try {
        if ($isWindowsTest) { [void](New-Item -ItemType Junction -Path $link -Target (Split-Path $outside -Parent)) }
        else { [void](New-Item -ItemType SymbolicLink -Path $link -Target (Split-Path $outside -Parent)) }
        $linkPaths.Add($link)
    } catch { $script:skipped++; Write-Output 'SKIP: Directory link creation unavailable' }
    if ($linkPaths.Contains($link)) {
        $snap=Snapshot
        Assert (@($snap.Files | ForEach-Object { $_.Path }) -notcontains (Join-Path $link 'untouched.bin')) 'Scan does not traverse folder links'
        Assert ($snap.Warnings.Count -gt 0) 'Skipped link is disclosed in scan notices'
        $result=RunCleanup $snap
        Assert (Test-Path -LiteralPath $outside) 'Folder link destination survives cleanup'
        if ($isWindowsTest) { [IO.Directory]::Delete($link) } else { Remove-Item -LiteralPath $link }
        [void]$linkPaths.Remove($link)
    }

    # Replace a normal parent after the preview with a link to another location.
    $swapDir=Join-Path $temp 'Roblox/http/swap'
    $swap=OldFile (Join-Path $swapDir 'swap.bin')
    $destination=Join-Path $testRoot 'swap-destination'
    $destFile=OldFile (Join-Path $destination 'swap.bin')
    $snap=Snapshot
    Remove-Item -LiteralPath $swap
    [IO.Directory]::Delete($swapDir)
    try {
        if ($isWindowsTest) { [void](New-Item -ItemType Junction -Path $swapDir -Target $destination) }
        else { [void](New-Item -ItemType SymbolicLink -Path $swapDir -Target $destination) }
        $linkPaths.Add($swapDir)
    } catch { $script:skipped++; Write-Output 'SKIP: Parent-swap test requires folder-link support' }
    if ($linkPaths.Contains($swapDir)) {
        $result=RunCleanup $snap
        Assert ($result.Skipped -ge 1 -and (Test-Path -LiteralPath $destFile)) 'Parent swapped for link cannot redirect deletion'
    }
    if ($isWindowsTest) {
        $locked=OldFile (Join-Path $temp 'Roblox/http/locked.bin')
        $snap=Snapshot
        $handle=[IO.File]::Open($locked,'Open','Read','None')
        try {
            $result=RunCleanup $snap
            Assert ($result.Skipped -ge 1 -and (Test-Path -LiteralPath $locked)) 'Locked files skipped without forced access'
        } finally { $handle.Dispose() }
    } else { $script:skipped++; Write-Output 'SKIP: Windows exclusive-file lock behavior cannot be tested on Linux' }

    $payload=OldFile (Join-Path $local 'Roblox/rbx-storage/aa/abc123.bin')
    $secondary=OldFile (Join-Path $temp 'Roblox/rbx-storage-sc/bb/def456')
    $shader=OldFile (Join-Path $local 'Roblox/shadercachevk.bin')
    $tempShader=OldFile (Join-Path $temp 'Roblox/shadercache.bin')
    $localHttp=OldFile (Join-Path $local 'Roblox/http/extra.bin')
    $tempCache=OldFile (Join-Path $temp 'Roblox/Cache/extra.bin')
    $payloadPlace=OldFile (Join-Path $local 'Roblox/rbx-storage/saved.rbxlx')
    $payloadDb=OldFile (Join-Path $local 'Roblox/rbx-storage/other.db-wal')
    $credential=OldFile (Join-Path $local 'Roblox/rbx-storage/credentials.dat')
    $rootOther=OldFile (Join-Path $local 'Roblox/random.bin')
    $nestedShader=OldFile (Join-Path $local 'Roblox/Versions/test/shadercachevk.bin')
    $scanControl=@{Cancel=$false}
    $deep=Get-RclSnapshot -Config $config -KeepDays 7 -Control $scanControl
    $deepPaths=@($deep.Files | ForEach-Object { $_.Path })
    Assert ($config.Count -eq 14) 'Expanded scanner recognizes fourteen exact locations'
    foreach ($path in @($payload,$secondary,$shader,$tempShader,$localHttp,$tempCache)) {
        Assert ($deepPaths -contains $path) ('Expanded scan includes: '+$path.Substring($testRoot.Length))
    }
    Assert ($scanControl.Processed -gt 0 -and $scanControl.Phase -eq 'Scanning') 'Scan progress counts real entries'
    $standard=RunCleanup $deep @('Cache')
    Assert ((Test-Path -LiteralPath $payload) -and (Test-Path -LiteralPath $shader)) 'Deep cache stays untouched when the category is not selected'
    $cleanControl=@{Cancel=$false}
    $deepResult=Invoke-RclCleanup -Snapshot $deep -Categories @('DeepCache') -Config $config -Control $cleanControl -ProcessProbe { @() }
    Assert ($deepResult.Removed -eq 4 -and $deepResult.Pending -eq 0) 'Selected payloads and exact shader files cleaned'
    Assert ($cleanControl.Processed -eq 4 -and $cleanControl.Total -eq 4) 'Cleanup progress matches the actual selected file count'
    foreach ($path in @($payloadPlace,$payloadDb,$credential,$rootOther,$nestedShader,$database)) {
        Assert (Test-Path -LiteralPath $path) ('Expanded scan still protects: '+[IO.Path]::GetFileName($path))
    }
    $fresh=OldFile (Join-Path $temp 'Roblox/rbx-storage/fresh.bin')
    [IO.File]::SetLastWriteTimeUtc($fresh,[datetime]::UtcNow.AddMinutes(-2))
    $retained=Get-RclSnapshot -Config $config -KeepDays 1
    Assert (@($retained.Files | ForEach-Object { $_.Path }) -notcontains $fresh) 'Standard retention keeps fresh payloads'
    $allAges=Get-RclSnapshot -Config $config -KeepDays 0
    Assert (@($allAges.Files | ForEach-Object { $_.Path }) -contains $fresh) 'Deep preset all-ages scan includes fresh payloads'
    $readOnly=OldFile (Join-Path $temp 'Roblox/http/readonly.bin')
    [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)
    try {
        $readOnlySnap=Snapshot
        Assert (@($readOnlySnap.Files | ForEach-Object { $_.Path }) -notcontains $readOnly) 'Read-only files stay excluded in expanded mode'
    } finally { [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::Normal) }
    Throws { Get-RclConfig -LocalRoot ([IO.Path]::GetPathRoot($testRoot)) -TempRoot $temp } 'Drive roots rejected'
    Assert ((Format-RclBytes 1024) -eq '1.0 KB') 'Byte counts formatted consistently'
    Write-Output "RESULT: $script:passed assertions passed; $script:skipped platform-dependent tests skipped."
} finally {
    foreach ($path in $linkPaths) {
        if ($isWindowsTest) { [IO.Directory]::Delete($path) } else { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
