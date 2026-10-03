#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start this tool with Start-Roblox-Cleaner.cmd (STA mode is required).' }
    $modulePath = Join-Path $PSScriptRoot 'Cleaner.Core.psm1'
    Import-Module $modulePath -Force
    [xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Interface.xaml') -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $ui = @{}
    foreach ($name in @('Scan','DeepScan','DeepCache','Clean','Cancel','Preview','Export','Cache','Logs','Crashes','Retention','Summary','Status','Total','FileCount','ProcessState','Progress')) {
        $ui[$name] = $window.FindName($name)
    }
    $script:snapshot = $null
    $script:job = $null
    $script:lastReport = ''
    $script:closeWhenDone = $false

    function Get-SelectedCategories {
        @('Cache','DeepCache','Logs','Crashes' | Where-Object { $ui[$_].IsChecked -eq $true })
    }
    function Set-Status([string]$Message) { $ui.Status.Text = $Message }
    function Update-Selection {
        $categories = @(Get-SelectedCategories)
        $files = @()
        if ($null -ne $script:snapshot) { $files = @($script:snapshot.Files | Where-Object { $_.Category -in $categories }) }
        [long]$bytes = 0
        foreach ($file in $files) { $bytes += $file.Length }
        $ui.Total.Text = Format-RclBytes $bytes
        $ui.FileCount.Text = ('{0:N0} eligible files selected' -f $files.Count)
        $ui.Clean.IsEnabled = ($null -eq $script:job -and $null -ne $script:snapshot -and $script:snapshot.Complete -and $files.Count -gt 0)
        $ui.Preview.IsEnabled = ($null -eq $script:job -and $null -ne $script:snapshot)
    }
    function Set-Busy([bool]$Busy) {
        $ui.Scan.IsEnabled = -not $Busy
        $ui.DeepScan.IsEnabled = -not $Busy
        $ui.Retention.IsEnabled = -not $Busy
        foreach ($name in @('Cache','DeepCache','Logs','Crashes')) { $ui[$name].IsEnabled = -not $Busy }
        $ui.Cancel.IsEnabled = $Busy
        $ui.Progress.IsIndeterminate = $Busy
        if ($Busy) { $ui.Clean.IsEnabled=$false; $ui.Preview.IsEnabled=$false }
        else { $ui.Progress.Value=0; Update-Selection }
    }
    function Start-Worker([string]$Operation, $Snapshot, [string[]]$Categories) {
        $control = [hashtable]::Synchronized(@{Cancel=$false;Phase='Starting';Processed=0;Total=0})
        $ps = [PowerShell]::Create()
        $runspace = [RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = 'MTA'
        $runspace.Open()
        $ps.Runspace = $runspace
        $worker = {
            param($ModulePath, $Operation, $Snapshot, $Categories, $Days, $Control)
            $ErrorActionPreference='Stop'
            Import-Module $ModulePath -Force
            if ($Operation -eq 'Scan') { Get-RclSnapshot -KeepDays $Days -Control $Control }
            else { Invoke-RclCleanup -Snapshot $Snapshot -Categories $Categories -Control $Control }
        }
        $days = @(1,7,30,0)[$ui.Retention.SelectedIndex]
        [void]$ps.AddScript($worker.ToString()).AddArgument($modulePath).AddArgument($Operation).AddArgument($Snapshot).AddArgument($Categories).AddArgument($days).AddArgument($control)
        try {
            $handle = $ps.BeginInvoke()
            $script:job = @{PowerShell=$ps; Runspace=$runspace; Handle=$handle; Control=$control; Operation=$Operation}
            Set-Busy $true
        } catch { $ps.Dispose(); $runspace.Dispose(); throw }
    }
    function New-ScanReport($Snapshot) {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('Roblox Cleaner Lite v0.2.0 - scan report')
        $lines.Add('UTC: ' + $Snapshot.ScannedUtc.ToString('o'))
        $lines.Add('Keep newest days: ' + $Snapshot.KeepDays)
        $lines.Add('Complete: ' + $Snapshot.Complete)
        $lines.Add('This scan did not delete any files.')
        foreach ($row in $Snapshot.Summary) { $lines.Add("$($row.Name): $($row.Count) files, $($row.Size), $($row.State) - $($row.Path)") }
        foreach ($warning in $Snapshot.Warnings) { $lines.Add('NOTICE: ' + $warning) }
        $lines.Add('')
        foreach ($file in $Snapshot.Files) { $lines.Add("$($file.Category) | $($file.Length) bytes | $($file.Path)") }
        return $lines -join [Environment]::NewLine
    }
    $ui.Scan.Add_Click({
        try { Set-Status 'Scanning recognized Roblox folders...'; Start-Worker 'Scan' $null @() }
        catch { Set-Status $_.Exception.Message }
    })
    $ui.DeepScan.Add_Click({
        try {
            $ui.Cache.IsChecked=$true; $ui.DeepCache.IsChecked=$true; $ui.Logs.IsChecked=$true
            $ui.Retention.SelectedIndex=3
            Update-Selection
            Set-Status 'Deep scan: all ages, including asset payloads and shader cache. Nothing is deleted yet.'
            Start-Worker 'Scan' $null @()
        } catch { Set-Status $_.Exception.Message }
    })
    foreach ($name in @('Cache','DeepCache','Logs','Crashes')) { $ui[$name].Add_Click({ Update-Selection }) }
    $ui.Retention.Add_SelectionChanged({
        if ($null -ne $script:snapshot) {
            $script:snapshot=$null; $ui.Summary.ItemsSource=$null; Update-Selection
            Set-Status 'Age filter changed. Scan again to update the preview.'
        }
    })
    $ui.Cancel.Add_Click({
        if ($null -ne $script:job) { $script:job.Control.Cancel=$true; $ui.Cancel.IsEnabled=$false; Set-Status 'Stopping after the current file...' }
    })
    $ui.Clean.Add_Click({
        try {
            $running = @(Get-RclRunningProcesses)
            if ($running.Count -gt 0) { Set-Status ('Close Roblox and Studio first: ' + ($running -join ', ')); return }
            $categories = @(Get-SelectedCategories)
            $selected = @($script:snapshot.Files | Where-Object { $_.Category -in $categories })
            [long]$bytes=0
            foreach ($file in $selected) { $bytes += $file.Length }
            $message = "Permanently delete $($selected.Count) previewed files ($(Format-RclBytes $bytes))?`n`nSelected: $($categories -join ', ')`nDeleted files will not go to the Recycle Bin. Asset caches may download again next time you play."
            $answer = [Windows.MessageBox]::Show($window, $message, 'Confirm cleanup', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
            if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
            Set-Status 'Cleaning the previewed files...'
            Start-Worker 'Clean' $script:snapshot $categories
        } catch { Set-Status $_.Exception.Message }
    })
    $ui.Preview.Add_Click({
        $dialog = New-Object Windows.Window
        $dialog.Title='Files selected for cleanup'; $dialog.Owner=$window; $dialog.Width=920; $dialog.Height=560
        $dialog.MinWidth=600; $dialog.MinHeight=360; $dialog.WindowStartupLocation='CenterOwner'
        $dialog.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#12101B')
        $dialog.Foreground=[Windows.Media.Brushes]::White
        [void]$dialog.Resources.MergedDictionaries.Add($window.Resources)
        $tabs = New-Object Windows.Controls.TabControl
        $tabs.Margin='16'
        $tabs.Foreground=[Windows.Media.Brushes]::Black
        $filesTab=New-Object Windows.Controls.TabItem; $filesTab.Header='Selected files'
        $grid=New-Object Windows.Controls.DataGrid
        $grid.IsReadOnly=$true; $grid.AutoGenerateColumns=$true; $grid.CanUserAddRows=$false
        $categories=@(Get-SelectedCategories)
        $grid.ItemsSource=@($script:snapshot.Files | Where-Object { $_.Category -in $categories } | Select-Object Category, @{Name='Size';Expression={Format-RclBytes $_.Length}}, Path)
        $filesTab.Content=$grid; [void]$tabs.Items.Add($filesTab)
        $notesTab=New-Object Windows.Controls.TabItem; $notesTab.Header='Scan notices'
        $notes=New-Object Windows.Controls.TextBox
        $notes.IsReadOnly=$true; $notes.TextWrapping='Wrap'; $notes.VerticalScrollBarVisibility='Auto'; $notes.Padding='12'
        $notes.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#0D0A14')
        $notes.Foreground=[Windows.Media.Brushes]::White
        $notes.Text=($script:snapshot.Warnings -join [Environment]::NewLine)
        if (-not $notes.Text) { $notes.Text='No scan notices. Missing folders are shown as Not found in the main window.' }
        $notesTab.Content=$notes; [void]$tabs.Items.Add($notesTab)
        $dialog.Content=$tabs; [void]$dialog.ShowDialog()
    })
    $ui.Export.Add_Click({
        try {
            $save=New-Object Microsoft.Win32.SaveFileDialog
            $save.Filter='Text report (*.txt)|*.txt'; $save.FileName=('RobloxCleaner-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            if ($save.ShowDialog($window)) {
                [IO.File]::WriteAllText($save.FileName, $script:lastReport, [Text.UTF8Encoding]::new($true))
                Set-Status 'Report saved.'
            }
        } catch { Set-Status ('Could not save report: ' + $_.Exception.Message) }
    })
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(200)
    $script:lastProcessCheck=[datetime]::MinValue
    $timer.Add_Tick({
        if ($null -ne $script:job -and $script:job.Handle.IsCompleted) {
            $completed=$script:job
            try {
                $output=@($completed.PowerShell.EndInvoke($completed.Handle))
                if ($completed.PowerShell.HadErrors) { throw ($completed.PowerShell.Streams.Error | Out-String) }
                if ($output.Count -ne 1) { throw 'Unexpected worker result. No further cleanup will be attempted.' }
                $result=$output[0]
                if ($completed.Operation -eq 'Scan') {
                    $script:snapshot=$result
                    $ui.Summary.ItemsSource=@($result.Summary)
                    $script:lastReport=New-ScanReport $result
                    if ($result.Cancelled) { Set-Status 'Scan cancelled. Scan again before cleaning.' }
                    elseif ($result.Limited) { Set-Status 'Scan limit reached. Cleanup disabled; see scan notices.' }
                    elseif ($result.Warnings.Count -gt 0) { Set-Status ("Scan complete with $($result.Warnings.Count) notices. Use Preview files to review.") }
                    else { Set-Status 'Scan complete. Review the files, then clean your selection.' }
                } else {
                    $lines=New-Object 'System.Collections.Generic.List[string]'
                    $lines.Add('Roblox Cleaner Lite v0.2.0 - cleanup report')
                    $lines.Add('UTC: '+$result.FinishedUtc.ToString('o'))
                    $lines.Add("Removed: $($result.Removed) files; $(Format-RclBytes $result.RemovedBytes) in file data")
                    $lines.Add("Skipped: $($result.Skipped); Cancelled: $($result.Cancelled); Blocked: $($result.Blocked)")
                    $lines.Add("Not attempted: $($result.Pending)")
                    foreach ($row in $result.Results) { $lines.Add("$($row.Status) | $($row.Category) | $($row.Path) | $($row.Detail)") }
                    $script:lastReport=$lines -join [Environment]::NewLine
                    $script:snapshot=$null; $ui.Summary.ItemsSource=$null
                    $status="Removed $($result.Removed) files ($(Format-RclBytes $result.RemovedBytes)); skipped $($result.Skipped)."
                    if ($result.Pending -gt 0) { $status+=" $($result.Pending) files not attempted." }
                    if ($result.Cancelled) { $status+=' Cleanup cancelled.' }
                    if ($result.Blocked) { $status+=' Roblox started; cleanup stopped.' }
                    Set-Status ($status+' Scan again to refresh. Export report for details.')
                }
                $ui.Export.IsEnabled=$true
            } catch {
                Set-Status ('Operation stopped: '+$_.Exception.Message.Trim())
                if ($completed.Operation -eq 'Clean') { $script:snapshot=$null; $ui.Summary.ItemsSource=$null }
            } finally {
                $completed.PowerShell.Dispose(); $completed.Runspace.Dispose(); $script:job=$null; Set-Busy $false
                if ($script:closeWhenDone) { $window.Close() }
            }
        }
        if ($null -ne $script:job -and -not $script:job.Control.Cancel) {
            $progress=$script:job.Control
            if ($progress.Phase -eq 'Scanning') {
                Set-Status ('Scanning recognized folders: {0:N0} entries checked...' -f $progress.Processed)
            } elseif ($progress.Phase -eq 'Cleaning' -and $progress.Total -gt 0) {
                $ui.Progress.IsIndeterminate=$false
                $ui.Progress.Value=100.0*$progress.Processed/$progress.Total
                Set-Status ('Cleaning previewed files: {0:N0} of {1:N0} processed...' -f $progress.Processed,$progress.Total)
            }
        }
        if (([datetime]::UtcNow-$script:lastProcessCheck).TotalSeconds -ge 2) {
            try {
                $running=@(Get-RclRunningProcesses)
                $ui.ProcessState.Text=if ($running.Count -gt 0) { 'Roblox / Studio open - close before cleaning' } else { 'Roblox / Studio closed' }
            } catch { $ui.ProcessState.Text='Process check unavailable - cleanup will be blocked' }
            $script:lastProcessCheck=[datetime]::UtcNow
        }
    })
    $window.Add_Closing({
        param($sender,$eventArgs)
        if ($null -ne $script:job) {
            $eventArgs.Cancel=$true; $script:closeWhenDone=$true; $script:job.Control.Cancel=$true
            Set-Status 'Stopping safely before closing...'
        }
    })
    $window.Add_Closed({ $timer.Stop() })
    Update-Selection
    $timer.Start()
    [void]$window.ShowDialog()
} catch {
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show($_.Exception.Message, 'Roblox Cleaner Lite could not start', 'OK', 'Error')
    } catch { Write-Error 'Roblox Cleaner Lite requires Windows with desktop PowerShell 5.1 and WPF.' }
    exit 1
}
