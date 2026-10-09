#Requires -Version 5.1
<#
.SYNOPSIS
    EZ Triage: a window for running Eric Zimmerman's tools against collected evidence.
    Start it with Start-EZTriage.cmd (or: powershell -STA -ExecutionPolicy Bypass -File EZTriage.ps1).
#>
param(
    [string]$ToolsPath,   # optional: preselect the EZ Tools folder
    [string]$Evidence,    # optional: open this collection on start
    [string]$CaseDir      # optional: case folder (default: next to the evidence)
)
$ErrorActionPreference = 'Stop'
$AppRoot = $PSScriptRoot
$EnginePath = Join-Path $AppRoot 'lib\EZTriage.Engine.psm1'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

function Show-Message([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [Windows.MessageBox]::Show($Text, 'EZ Triage', $Buttons, $Icon)
}

# The launcher hides the console, so startup errors must surface as a message box.
trap {
    Show-Message "EZ Triage could not start:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)" 'Error' | Out-Null
    exit 1
}

Import-Module $EnginePath -Force

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) { $relaunch += @("-$($kv.Key)", "`"$($kv.Value)`"") }
    Start-Process powershell.exe -ArgumentList $relaunch
    return
}

#region Settings

$SettingsFile = Join-Path $env:APPDATA 'EZTriage\settings.json'

function Get-DefaultToolsPath {
    foreach ($c in @((Join-Path $AppRoot 'net9'), (Join-Path (Split-Path $AppRoot) 'net9'), (Join-Path $AppRoot 'EZTools'),
            (Join-Path (Split-Path $AppRoot) 'EZTools'), 'C:\Tools\EZTools\net9', 'C:\Tools\net9', 'C:\Tools\EZTools')) {
        if (Test-Path -LiteralPath (Join-Path $c 'MFTECmd.exe')) { return (Resolve-Path -LiteralPath $c).Path }
    }
    ''
}

function Read-Settings {
    $cfg = @{
        ToolsPath = ''; CaseRoot = ''; LastEvidenceDir = ''; LightSlots = 3; Policy = 'Ask'
        Preset = 'FOR508 triage'; Selected = @((Get-EztPresets)['FOR508 triage']); Options = Get-EztDefaultOptions
    }
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            foreach ($k in 'ToolsPath', 'CaseRoot', 'LastEvidenceDir', 'LightSlots', 'Policy', 'Preset') { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } }
            if ($null -ne $j.Selected) { $cfg.Selected = @($j.Selected) }
            if ($j.Options) { foreach ($p in $j.Options.PSObject.Properties) { if ($cfg.Options.ContainsKey($p.Name)) { $cfg.Options[$p.Name] = $p.Value } } }
            $cfg.Options.MftFiles = @($cfg.Options.MftFiles); $cfg.Options.EvtxLogs = @($cfg.Options.EvtxLogs)
        } catch { }
    }
    if (-not $cfg.ToolsPath -or -not (Test-Path -LiteralPath $cfg.ToolsPath)) { $cfg.ToolsPath = Get-DefaultToolsPath }
    $cfg
}

function Save-Settings {
    try {
        $st = $S.Settings
        $st.Selected = @($S.Selected)
        $st.Options = $S.Options
        [void](New-Item -ItemType Directory -Path (Split-Path $SettingsFile) -Force)
        ([pscustomobject]$st) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}

#endregion

#region Window

[xml]$xaml = Get-Content -LiteralPath (Join-Path $AppRoot 'lib\MainWindow.xaml') -Raw
$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if (-not $name) { $name = $n.GetAttribute('Name') }
    if ($name) { $ui[$name] = $Window.FindName($name) }
}

$script:S = @{
    Settings = Read-Settings; ToolInfo = $null; Evidence = $null; EvidenceLoading = $false; EvidenceSeq = 0
    Avail = @{}; EvidenceLogs = @(); Previous = @{}; Rows = @{}; LogRows = @{}; PresetButtons = @{}
    Focus = 'EvtxECmd'; Selected = New-Object 'System.Collections.Generic.List[string]'
    Bg = New-Object Collections.ArrayList; Run = $null; Plan = $null
    AllLog = New-Object Text.StringBuilder; LogItems = @{}; ViewPath = ''; ViewSize = -1; Suspend = $false
}
$S.Options = $S.Settings.Options
foreach ($id in $S.Settings.Selected) { if (-not $S.Selected.Contains($id)) { $S.Selected.Add($id) } }

$Brush = @{
    Text = '#1B1F23'; Muted = '#5A636E'; Faint = '#7A838D'; Good = '#1E7B46'; Warn = '#8A5A00'; Bad = '#B3261E'; Busy = '#0F6CBD'
    Focus = '#E5F1FB'; Preset = '#DCEBFA'
}
$catalog = Get-EztCatalog
$ui.LblVersion.Text = "EZ Triage 0.1.0"

# Fit the screen it opens on (collection laptops are often 1366x768 or 1080p at 125%).
$work = [Windows.SystemParameters]::WorkArea
if ($Window.Height -gt $work.Height - 10) { $Window.Height = [Math]::Max($Window.MinHeight, $work.Height - 10) }
if ($Window.Width -gt $work.Width - 10) { $Window.Width = [Math]::Max($Window.MinWidth, $work.Width - 10) }
if ($work.Height -lt 860) { $Window.WindowState = 'Maximized' }

#endregion

#region Background work (keeps the window responsive)

function Start-Background([string]$Script, [object[]]$Arguments, [scriptblock]$OnDone) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    [void]$S.Bg.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone })
}

function Update-Background {
    foreach ($b in @($S.Bg)) {
        if (-not $b.Handle.IsCompleted) { continue }
        [void]$S.Bg.Remove($b)
        $result = $null; $err = $null
        try { $result = $b.PS.EndInvoke($b.Handle) } catch { $err = $_.Exception.InnerException; if (-not $err) { $err = $_.Exception } }
        if (-not $err -and $b.PS.Streams.Error.Count) { $err = $b.PS.Streams.Error[0].Exception }
        $b.PS.Dispose()
        try { & $b.OnDone $(if ($result -and $result.Count) { $result[0] } else { $null }) $err } catch { $ui.LblStatus.Text = "Error: $($_.Exception.Message)" }
    }
}

#endregion

#region Tools folder

function Set-ToolsFolder([string]$Path) {
    $Path = $Path.Trim().Trim('"')
    $ui.TxtTools.Text = $Path
    $S.ToolInfo = $null
    if (-not $Path) { $ui.LblTools.Text = 'Point to the folder with MFTECmd.exe, PECmd.exe and the other tools.'; Update-All; return }
    $ti = Find-EztTools -Path $Path
    if (-not $ti.Tools.Count) {
        $ui.LblTools.Text = 'No EZ Tools found in this folder.'
        $ui.LblTools.Foreground = $Brush.Bad
    } else {
        $S.ToolInfo = $ti
        $S.Settings.ToolsPath = $Path
        $total = $catalog.Count
        $msg = "$($ti.Tools.Count) of $total tools found"
        if ($ti.Missing.Count) { $msg += " (missing: $($ti.Missing -join ', '))" }
        if ($ti.DotNet.Message) { $msg += ". $($ti.DotNet.Message)" }
        $ui.LblTools.Text = $msg
        $ui.LblTools.Foreground = $(if ($ti.DotNet.Ok) { $Brush.Muted } else { $Brush.Bad })
        $ui.LblVersion.Text = "EZ Triage 0.1.0  |  $($ti.DotNet.Message)"
    }
    Update-BatchList
    Update-All
}

function Update-BatchList {
    $S.Suspend = $true
    $ui.CmbBatch.Items.Clear()
    $files = @(); if ($S.ToolInfo) { $files = @($S.ToolInfo.BatchFiles) }
    if (-not $files.Count) { $files = @('Kroll_Batch.reb') }
    foreach ($f in $files) { [void]$ui.CmbBatch.Items.Add($f) }
    $want = $S.Options.RecmdBatch
    if ($want -and -not $ui.CmbBatch.Items.Contains($want)) { [void]$ui.CmbBatch.Items.Add($want) }
    $ui.CmbBatch.SelectedItem = $want
    if ($null -eq $ui.CmbBatch.SelectedItem) { $ui.CmbBatch.SelectedIndex = 0 }
    $S.Suspend = $false
}

#endregion

#region Evidence and case folder

function Get-DefaultCaseDir([string]$EvidencePath) {
    $p = $EvidencePath.Trim().Trim('"').TrimEnd('\')
    $leaf = Split-Path $p -Leaf
    if ($p -match '^[A-Za-z]:$') { $leaf = 'Drive_' + $p.Substring(0, 1) }
    $leaf = [IO.Path]::GetFileNameWithoutExtension($leaf + '.x')
    if ($p -like '*.zip') { $leaf = [IO.Path]::GetFileNameWithoutExtension($p) }
    $root = $S.Settings.CaseRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) {
        $parent = Split-Path $p
        $root = if ($parent) { $parent } else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'EZTriage Cases' }
    }
    Join-Path $root "${leaf}_EZTriage"
}

function Get-ExtractDir {
    $ev = $ui.TxtEvidence.Text.Trim().Trim('"')
    if ($ev -notlike '*.zip' -or -not $ui.TxtCase.Text.Trim()) { return $null }
    Join-Path $ui.TxtCase.Text.Trim() ('Evidence\' + [IO.Path]::GetFileNameWithoutExtension($ev))
}

function Set-Evidence([string]$Path, [bool]$ResetCase = $true) {
    $Path = $Path.Trim().Trim('"')
    if ($Path -match '^[A-Za-z]:$') { $Path += '\' }
    $ui.TxtEvidence.Text = $Path
    $S.Evidence = $null; $S.Avail = @{}; $S.EvidenceLogs = @()
    if (-not $Path) { $ui.LblEvidence.Text = 'A KAPE or Velociraptor collection (folder or ZIP), or a mounted drive.'; Update-All; return }
    if ($ResetCase) { $ui.TxtCase.Text = Get-DefaultCaseDir $Path }
    $S.EvidenceSeq++
    $seq = $S.EvidenceSeq
    $S.EvidenceLoading = $true
    $ui.LblEvidence.Foreground = $Brush.Muted
    $ui.LblEvidence.Text = 'Reading evidence...'
    $toolsPath = if ($S.ToolInfo) { $S.ToolInfo.Path } else { '' }
    Start-Background -Script {
        param($EnginePath, $Path, $ExtractTo, $ToolsPath, $Options)
        Import-Module $EnginePath
        $ev = Open-EztEvidence -Path $Path -ExtractTo $ExtractTo
        $ti = if ($ToolsPath) { Find-EztTools -Path $ToolsPath } else { $null }
        $avail = @{}; $logs = @()
        if (-not $ev.Error) {
            $avail = Get-EztAvailability -Evidence $ev -Options $Options -ToolInfo $ti
            foreach ($v in $ev.Volumes) {
                foreach ($d in @(Resolve-EztPath $ev $v 'Windows\System32\winevt\Logs')) {
                    $logs += @((Get-EztChildren $ev $d).Values | Where-Object { $_.Name -like '*.evtx' } | ForEach-Object { $_.Name })
                }
            }
        }
        [pscustomobject]@{ Evidence = $ev; Avail = $avail; Logs = @($logs | Sort-Object -Unique) }
    }.ToString() -Arguments @($EnginePath, $Path, (Get-ExtractDir), $toolsPath, $S.Options) -OnDone {
        param($r, $err)
        if ($seq -ne $S.EvidenceSeq) { return }   # a newer selection replaced this one
        $S.EvidenceLoading = $false
        if ($err) { $ui.LblEvidence.Text = "Could not read evidence: $($err.Message)"; $ui.LblEvidence.Foreground = $Brush.Bad; Update-All; return }
        if ($r.Evidence.Error) { $ui.LblEvidence.Text = $r.Evidence.Error; $ui.LblEvidence.Foreground = $Brush.Bad; Update-All; return }
        $S.Evidence = $r.Evidence; $S.Avail = $r.Avail; $S.EvidenceLogs = @($r.Logs)
        $text = "Detected: $($r.Evidence.Description)"
        if ($r.Evidence.IsZip -and -not $r.Evidence.Extracted) { $text += '. The ZIP is extracted once into the case folder when you start.' }
        elseif ($r.Evidence.Extracted) { $text += '. Using the copy extracted earlier.' }
        if ($r.Evidence.Warnings.Count) { $text += "`n" + ($r.Evidence.Warnings -join "`n") }
        $ui.LblEvidence.Text = $text
        $ui.LblEvidence.Foreground = $(if ($r.Evidence.Volumes.Count) { $Brush.Muted } else { $Brush.Warn })
        $S.Settings.LastEvidenceDir = Split-Path $Path
        Build-LogList
        Update-All
    }.GetNewClosure()
    Update-All
}

function Update-CaseInfo {
    $S.Previous = @{}
    $case = $ui.TxtCase.Text.Trim()
    if (-not $case) { $ui.LblCase.Text = 'Output goes here, one folder per tool.'; return }
    if (-not (Test-Path -LiteralPath $case)) { $ui.LblCase.Text = 'New case folder. It is created when you start.'; Update-LogViewList; return }
    foreach ($t in $catalog) {
        $m = Join-Path $case "$($t.Category)\$($t.Id)\_eztriage.json"
        if (Test-Path -LiteralPath $m) {
            try {
                $j = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
                $ok = @($j.Jobs | Where-Object { $_.Status -in 'Done', 'Warnings' })
                if ($ok.Count) { $S.Previous[$t.Id] = ($ok | ForEach-Object Finished | Sort-Object | Select-Object -Last 1) }
            } catch { }
        }
    }
    $ui.LblCase.Text = if ($S.Previous.Count) { "Existing case: $($S.Previous.Count) tools already processed here. They are marked in the list." } else { 'Existing folder. Output goes into it, one folder per tool.' }
    Update-LogViewList
}

#endregion

#region Tool list

function New-Text([string]$Text, [string]$Color = $Brush.Text, [string]$Weight = 'Normal') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.Foreground = $Color; $t.FontWeight = $Weight
    $t
}

function Build-ToolList {
    $ui.PnlTools.Children.Clear()
    $S.Rows = @{}
    $groups = New-Object Collections.Specialized.OrderedDictionary
    foreach ($t in $catalog) { if (-not $groups.Contains($t.Group)) { $groups[$t.Group] = New-Object Collections.ArrayList }; [void]$groups[$t.Group].Add($t) }
    foreach ($g in $groups.Keys) {
        $h = New-Text $g $Brush.Muted 'SemiBold'
        $h.Margin = '2,8,0,2'
        [void]$ui.PnlTools.Children.Add($h)
        foreach ($t in $groups[$g]) {
            $border = New-Object Windows.Controls.Border
            $border.CornerRadius = 2; $border.Padding = '4,0,2,0'
            $grid = New-Object Windows.Controls.Grid
            foreach ($w in 'Auto', '*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $grid.ColumnDefinitions.Add($cd) }
            $chk = New-Object Windows.Controls.CheckBox
            $chk.VerticalAlignment = 'Center'; $chk.Tag = $t.Id; $chk.Margin = '0,0,6,0'
            $chk.ToolTip = "Run $($t.Id)"
            $chk.Add_Click({ param($src, $evt) Set-ToolSelected $src.Tag ([bool]$src.IsChecked) })
            $btn = New-Object Windows.Controls.Button
            $btn.Tag = $t.Id; $btn.Background = 'Transparent'; $btn.BorderBrush = 'Transparent'; $btn.Padding = '2,4'
            $btn.HorizontalContentAlignment = 'Stretch'; $btn.Cursor = 'Hand'; $btn.ToolTip = "Show $($t.Id) options"
            $inner = New-Object Windows.Controls.DockPanel
            $status = New-Text '' $Brush.Muted
            $status.Margin = '8,0,0,0'
            [Windows.Controls.DockPanel]::SetDock($status, 'Right')
            $name = New-Object Windows.Controls.TextBlock
            $name.TextTrimming = 'CharacterEllipsis'
            $r1 = New-Object Windows.Documents.Run -ArgumentList $t.Id
            $r2 = New-Object Windows.Documents.Run -ArgumentList "  $($t.Artifact)"
            $r2.Foreground = $Brush.Muted
            $name.Inlines.Add($r1); $name.Inlines.Add($r2)
            [void]$inner.Children.Add($status); [void]$inner.Children.Add($name)
            $btn.Content = $inner
            $btn.Add_Click({ param($src, $evt) Set-Focus $src.Tag })
            [Windows.Controls.Grid]::SetColumn($btn, 1)
            [void]$grid.Children.Add($chk); [void]$grid.Children.Add($btn)
            $border.Child = $grid
            [void]$ui.PnlTools.Children.Add($border)
            $S.Rows[$t.Id] = @{ Border = $border; Check = $chk; Status = $status }
        }
    }
}

function Build-Presets {
    foreach ($name in (Get-EztPresets).Keys) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $name; $b.Tag = $name; $b.Margin = '0,0,4,4'; $b.Padding = '8,2'; $b.MinHeight = 24
        $b.Add_Click({ param($src, $evt) Set-Preset $src.Tag })
        [void]$ui.PnlPresets.Children.Add($b)
        $S.PresetButtons[$name] = $b
    }
}

function Set-Preset([string]$Name) {
    $S.Settings.Preset = $Name
    $S.Selected.Clear()
    foreach ($id in (Get-EztPresets)[$Name]) { $S.Selected.Add($id) }
    Update-All
}

function Set-ToolSelected([string]$Id, [bool]$On) {
    if ($On -and -not $S.Selected.Contains($Id)) { $S.Selected.Add($Id) }
    if (-not $On) { [void]$S.Selected.Remove($Id) }
    $S.Settings.Preset = ''
    foreach ($p in (Get-EztPresets).GetEnumerator()) {
        if (-not (Compare-Object @($p.Value) @($S.Selected)) -and $p.Value.Count -eq $S.Selected.Count) { $S.Settings.Preset = $p.Key }
    }
    Set-Focus $Id
}

function Get-ToolRunStatus([string]$Id) {
    if (-not $S.Plan) { return $null }
    $tp = $S.Plan.Tools | Where-Object { $_.Tool.Id -eq $Id }
    if (-not $tp -or -not $tp.Jobs.Count) { return $null }
    $st = @($tp.Jobs | ForEach-Object Status)
    foreach ($k in 'Running', 'Failed', 'Cancelled', 'Warnings', 'NoOutput', 'Queued', 'Done', 'Skipped') { if ($st -contains $k) { return $k } }
    $null
}

function Update-ToolRows {
    $running = $S.Run -and -not $S.Run.State.Done
    foreach ($t in $catalog) {
        $row = $S.Rows[$t.Id]
        $installed = $S.ToolInfo -and $S.ToolInfo.Tools[$t.Id]
        $row.Check.IsChecked = $S.Selected.Contains($t.Id)
        $row.Check.IsEnabled = [bool]$installed -and -not $running
        $row.Border.Background = $(if ($S.Focus -eq $t.Id) { $Brush.Focus } else { 'Transparent' })
        $text = ''; $color = $Brush.Muted
        $rs = Get-ToolRunStatus $t.Id
        if (-not $S.ToolInfo) { $text = '' }
        elseif (-not $installed) { $text = 'not installed'; $color = $Brush.Faint }
        elseif ($rs -and ($running -or $rs -ne 'Queued')) {
            $text = Get-EztStatusText $rs
            $color = switch ($rs) { 'Done' { $Brush.Good } 'Running' { $Brush.Busy } 'Warnings' { $Brush.Warn } 'NoOutput' { $Brush.Warn } 'Failed' { $Brush.Bad } default { $Brush.Muted } }
        }
        elseif ($S.Evidence) {
            $a = $S.Avail[$t.Id]
            if ($S.Previous.ContainsKey($t.Id)) { $text = 'processed ' + ([string]$S.Previous[$t.Id]).Split(' ')[0]; $color = $Brush.Warn }
            elseif ($a) { $text = $a }
            else { $text = 'not found'; $color = $Brush.Faint }
        }
        $row.Status.Text = $text; $row.Status.Foreground = $color
    }
    foreach ($kv in $S.PresetButtons.GetEnumerator()) {
        $kv.Value.Background = $(if ($S.Settings.Preset -eq $kv.Key) { $Brush.Preset } else { [Windows.SystemColors]::ControlBrush })
        $kv.Value.IsEnabled = -not $running
    }
}

#endregion

#region Options panel

function Set-Focus([string]$Id) {
    $S.Focus = $Id
    $t = $catalog | Where-Object Id -eq $Id
    $ui.GrpOptions.Header = "$Id options"
    $ui.LblToolDesc.Text = $t.Description
    $ui.PnlMft.Visibility = $(if ($Id -eq 'MFTECmd') { 'Visible' } else { 'Collapsed' })
    $ui.PnlEvtx.Visibility = $(if ($Id -eq 'EvtxECmd') { 'Visible' } else { 'Collapsed' })
    $ui.PnlRecmd.Visibility = $(if ($Id -eq 'RECmd') { 'Visible' } else { 'Collapsed' })
    $ui.LblNoOptions.Visibility = $(if ($Id -in 'MFTECmd', 'EvtxECmd', 'RECmd') { 'Collapsed' } else { 'Visible' })
    Update-All
}

function Write-OptionsToUi {
    $S.Suspend = $true
    $o = $S.Options
    $ui.ChkMftMFT.IsChecked = $o.MftFiles -contains 'MFT'
    $ui.ChkMftJ.IsChecked = $o.MftFiles -contains 'J'
    $ui.ChkMftLogFile.IsChecked = $o.MftFiles -contains 'LogFile'
    $ui.ChkMftBoot.IsChecked = $o.MftFiles -contains 'Boot'
    $ui.ChkMftSDS.IsChecked = $o.MftFiles -contains 'SDS'
    $ui.ChkMftAt.IsChecked = [bool]$o.MftAllTimestamps
    $ui.ChkMftRs.IsChecked = [bool]$o.MftRecoverSlack
    $ui.RbEvtxKey.IsChecked = $o.EvtxMode -eq 'Key'
    $ui.RbEvtxPick.IsChecked = $o.EvtxMode -eq 'Pick'
    $ui.RbEvtxAll.IsChecked = $o.EvtxMode -eq 'All'
    $ui.RbIdFor508.IsChecked = $o.EvtxIdMode -eq 'FOR508'
    $ui.RbIdAll.IsChecked = $o.EvtxIdMode -eq 'All'
    $ui.RbIdCustom.IsChecked = $o.EvtxIdMode -eq 'Custom'
    $ui.TxtCustomIds.Text = $o.EvtxCustomIds
    $ids = (Get-EztFor508Ids) -split ','
    $ui.LblIdFor508.Text = "FOR508 event IDs ($($ids.Count))"
    $ui.RbIdFor508.ToolTip = "The $($ids.Count) event IDs from config\EventIds-FOR508.txt, the list used by Automate_EvtxECmd.ps1"
    $S.Suspend = $false
}

function Read-OptionsFromUi {
    if ($S.Suspend) { return }
    $o = $S.Options
    $files = @()
    foreach ($k in 'MFT', 'J', 'LogFile', 'Boot', 'SDS') { if ($ui["ChkMft$k"].IsChecked) { $files += $k } }
    $o.MftFiles = $files
    $o.MftAllTimestamps = [bool]$ui.ChkMftAt.IsChecked
    $o.MftRecoverSlack = [bool]$ui.ChkMftRs.IsChecked
    $o.EvtxMode = if ($ui.RbEvtxAll.IsChecked) { 'All' } elseif ($ui.RbEvtxPick.IsChecked) { 'Pick' } else { 'Key' }
    $o.EvtxIdMode = if ($ui.RbIdAll.IsChecked) { 'All' } elseif ($ui.RbIdCustom.IsChecked) { 'Custom' } else { 'FOR508' }
    $o.EvtxCustomIds = $ui.TxtCustomIds.Text
    if ($ui.CmbBatch.SelectedItem) { $o.RecmdBatch = [string]$ui.CmbBatch.SelectedItem }
    if ($o.EvtxMode -eq 'Key') { $o.EvtxLogs = @(Get-EztKeyLogs) }
    elseif ($o.EvtxMode -eq 'Pick') { $o.EvtxLogs = @($S.LogRows.Keys | Where-Object { $S.LogRows[$_].IsChecked }) }
    Update-LogChecks
    Update-All
}

function Build-LogList {
    $ui.PnlLogList.Children.Clear()
    $S.LogRows = @{}
    $key = @(Get-EztKeyLogs)
    $present = @{}; foreach ($l in $S.EvidenceLogs) { $present[$l] = $true }
    $names = @($key) + @($S.EvidenceLogs | Where-Object { $key -notcontains $_ } | Sort-Object)
    foreach ($n in $names) {
        $c = New-Object Windows.Controls.CheckBox
        $c.Tag = $n; $c.Margin = '0,1'
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Inlines.Add((New-Object Windows.Documents.Run -ArgumentList $n))
        if ($key -contains $n) {
            $tag = if (-not $S.Evidence -or $present[$n]) { '  key log' } else { '  key log, not in evidence' }
            $r = New-Object Windows.Documents.Run -ArgumentList $tag
            $r.Foreground = $(if (-not $S.Evidence -or $present[$n]) { $Brush.Muted } else { $Brush.Faint })
            $tb.Inlines.Add($r)
        }
        $c.Content = $tb
        $c.Add_Click({
                param($src, $evt)
                if (-not $ui.RbEvtxPick.IsChecked) { $S.Suspend = $true; $ui.RbEvtxPick.IsChecked = $true; $S.Suspend = $false }
                Read-OptionsFromUi
            })
        [void]$ui.PnlLogList.Children.Add($c)
        $S.LogRows[$n] = $c
    }
    Update-LogChecks
    Update-LogFilter
}

function Update-LogChecks {
    $o = $S.Options
    $all = $o.EvtxMode -eq 'All'
    foreach ($kv in $S.LogRows.GetEnumerator()) {
        $kv.Value.IsChecked = $all -or (@($o.EvtxLogs) -contains $kv.Key)
        $kv.Value.IsEnabled = -not $all
    }
    $sel = @($o.EvtxLogs)
    if ($all) { $ui.LblEvtxCount.Text = "$($S.EvidenceLogs.Count) logs in evidence" }
    else {
        $found = @($sel | Where-Object { $S.EvidenceLogs -contains $_ }).Count
        $ui.LblEvtxCount.Text = if ($S.Evidence) { "$found of $($sel.Count) ticked logs are in the evidence" } else { "$($sel.Count) ticked" }
    }
}

function Update-LogFilter {
    $f = $ui.TxtLogFilter.Text.Trim()
    foreach ($kv in $S.LogRows.GetEnumerator()) {
        $kv.Value.Visibility = $(if (-not $f -or $kv.Key -like "*$f*") { 'Visible' } else { 'Collapsed' })
    }
}

function Update-Preview {
    if (-not $S.ToolInfo) { $ui.TxtPreview.Text = 'Choose the EZ Tools folder first.'; return }
    if ($S.EvidenceLoading) { $ui.TxtPreview.Text = 'Reading evidence...'; return }
    if (-not $S.Evidence) { $ui.TxtPreview.Text = 'Choose evidence to see the exact commands.'; return }
    try {
        $case = $ui.TxtCase.Text.Trim(); if (-not $case) { $case = '<case folder>' }
        $plan = New-EztPlan -Evidence $S.Evidence -CaseDir $case -ToolIds @($S.Focus) -ToolInfo $S.ToolInfo -Options $S.Options
        $text = Get-EztCommandPreview -Plan $plan -ToolId $S.Focus
        if ($plan.Prep.Count -and $S.Focus -in 'RECmd', 'SBECmd', 'AmcacheParser', 'AppCompatCacheParser', 'SrumECmd') {
            $text = "# hives are first copied to <case>\_work\hives and restored to full size (Velociraptor stores them trimmed)`r`n" + $text
        }
        if ($S.Focus -in 'WxTCmd', 'SQLECmd' -and @($plan.Prep | Where-Object Kind -eq 'SqliteStage').Count) {
            $text = "# databases are first copied to <case>\_work\sqlite so SQLite never touches the evidence`r`n" + $text
        }
        $ui.TxtPreview.Text = $text
    } catch { $ui.TxtPreview.Text = "Could not build the command: $($_.Exception.Message)" }
}

#endregion

#region Log view

function Read-SharedText([string]$Path, [int]$MaxBytes = 2MB) {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -gt $MaxBytes) { $fs.Position = $fs.Length - $MaxBytes }
        $r = New-Object IO.StreamReader -ArgumentList $fs, ([Text.Encoding]::UTF8)
        $t = $r.ReadToEnd()
        if ($fs.Length -gt $MaxBytes) { $t = "[showing the last $([int]($MaxBytes / 1MB)) MB; open in Notepad for the full log]`r`n" + $t }
        $t
    } finally { $fs.Dispose() }
}

function Add-LogViewItem([string]$Label, [string]$Path) {
    if ($S.LogItems.ContainsKey($Path)) { return }
    $item = New-Object Windows.Controls.ComboBoxItem
    $item.Content = $Label; $item.Tag = $Path
    [void]$ui.CmbLogView.Items.Add($item)
    $S.LogItems[$Path] = $item
}

function Update-LogViewList {
    # "All tools" first, then every tool log already in the case folder.
    $case = $ui.TxtCase.Text.Trim()
    $keep = $ui.CmbLogView.SelectedItem
    $keepPath = if ($keep) { $keep.Tag } else { '' }
    $ui.CmbLogView.Items.Clear(); $S.LogItems = @{}
    Add-LogViewItem 'All tools (run log)' '*'
    if ($case -and (Test-Path -LiteralPath $case)) {
        foreach ($t in $catalog) {
            foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $case $t.Category) -Directory -Filter "$($t.Id)*" -ErrorAction SilentlyContinue)) {
                foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object Name)) {
                    $label = if ($dir.Name -ne $t.Id) { "$($dir.Name)  -  $($f.Name)" } else { "$($t.Id)  -  $($f.Name)" }
                    Add-LogViewItem $label $f.FullName
                }
            }
        }
    }
    $sel = if ($keepPath -and $S.LogItems.ContainsKey($keepPath)) { $S.LogItems[$keepPath] } else { $S.LogItems['*'] }
    $ui.CmbLogView.SelectedItem = $sel
}

function Show-SelectedLog([bool]$Force = $true) {
    $item = $ui.CmbLogView.SelectedItem
    if (-not $item) { return }
    $path = [string]$item.Tag
    if ($path -eq '*') {
        if ($S.AllLog.Length -eq 0) {
            $caseLog = Join-Path $ui.TxtCase.Text.Trim() 'EZTriage.log'
            if ($ui.TxtCase.Text.Trim() -and (Test-Path -LiteralPath $caseLog)) {
                if ($Force -or $S.ViewPath -ne $caseLog) { $ui.TxtLog.Text = Read-SharedText $caseLog; $ui.TxtLog.ScrollToEnd() }
                $S.ViewPath = $caseLog
            } else { $ui.TxtLog.Text = 'Nothing has run yet.'; $S.ViewPath = '' }
        } elseif ($Force -or $S.ViewPath -ne '*') {
            $ui.TxtLog.Text = $S.AllLog.ToString(); $ui.TxtLog.ScrollToEnd(); $S.ViewPath = '*'
        }
        return
    }
    if (-not (Test-Path -LiteralPath $path)) { $ui.TxtLog.Text = 'Log not written yet.'; return }
    $size = (Get-Item -LiteralPath $path).Length
    if ($Force -or $S.ViewPath -ne $path -or $S.ViewSize -ne $size) {
        $atEnd = $ui.TxtLog.VerticalOffset + $ui.TxtLog.ViewportHeight -ge $ui.TxtLog.ExtentHeight - 20
        $ui.TxtLog.Text = Read-SharedText $path
        if ($Force -or $atEnd) { $ui.TxtLog.ScrollToEnd() }
        $S.ViewPath = $path; $S.ViewSize = $size
    }
}

function Get-SelectedLogPath {
    $item = $ui.CmbLogView.SelectedItem
    if (-not $item) { return $null }
    if ($item.Tag -eq '*') { $p = Join-Path $ui.TxtCase.Text.Trim() 'EZTriage.log'; if (Test-Path -LiteralPath $p) { return $p }; return $null }
    [string]$item.Tag
}

#endregion

#region Run

function Show-ConflictDialog($Plan) {
    $dx = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Already processed" SizeToContent="WidthAndHeight" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        FontFamily="Segoe UI" FontSize="12" ShowInTaskbar="False">
  <StackPanel Margin="16" MaxWidth="620">
    <TextBlock TextWrapping="Wrap" Text="These tools already ran against this evidence in this case folder:"/>
    <TextBlock x:Name="TxtList" Margin="0,8,0,8" FontFamily="Consolas"/>
    <TextBlock TextWrapping="Wrap" Foreground="#5A636E" Text="Skip keeps the earlier output and runs only what is new. Run again writes to a new folder next to the old one (for example MFTECmd_run2). Overwrite deletes the earlier output first."/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="BtnSkip" Content="Skip them" IsDefault="True" MinWidth="90" Padding="10,3"/>
      <Button x:Name="BtnNew" Content="Run again in new folder" Margin="6,0,0,0" Padding="10,3"/>
      <Button x:Name="BtnOver" Content="Overwrite" Margin="6,0,0,0" MinWidth="80" Padding="10,3"/>
      <Button x:Name="BtnStop" Content="Cancel" IsCancel="True" Margin="6,0,0,0" MinWidth="80" Padding="10,3"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $Window
    $lines = foreach ($c in $Plan.Conflicts) {
        $when = ($c.Previous | ForEach-Object Finished | Sort-Object | Select-Object -Last 1)
        $diff = if (@($c.Previous | Where-Object { -not $_.SameOptions }).Count) { '  (different options this time)' } else { '' }
        '{0,-22} {1}{2}' -f $c.Tool.Id, $when, $diff
    }
    $dlg.FindName('TxtList').Text = ($lines -join "`n")
    $script:DialogResult = $null
    $dlg.FindName('BtnSkip').Add_Click({ $script:DialogResult = 'Skip'; $dlg.Close() })
    $dlg.FindName('BtnNew').Add_Click({ $script:DialogResult = 'NewFolder'; $dlg.Close() })
    $dlg.FindName('BtnOver').Add_Click({ $script:DialogResult = 'Overwrite'; $dlg.Close() })
    $dlg.FindName('BtnStop').Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog()
    $script:DialogResult
}

function Start-Run {
    if (-not $S.ToolInfo) { Show-Message 'Choose the EZ Tools folder first.' 'Warning' | Out-Null; return }
    if (-not $S.Evidence) { Show-Message 'Choose the evidence first.' 'Warning' | Out-Null; return }
    $case = $ui.TxtCase.Text.Trim().Trim('"')
    if (-not $case) { Show-Message 'Choose a case folder.' 'Warning' | Out-Null; return }
    $ids = @($catalog | Where-Object { $S.Selected.Contains($_.Id) -and $S.ToolInfo.Tools[$_.Id] } | ForEach-Object Id)
    if (-not $ids.Count) { Show-Message 'Tick at least one tool.' 'Warning' | Out-Null; return }
    if (-not $S.ToolInfo.DotNet.Ok) {
        if ((Show-Message "$($S.ToolInfo.DotNet.Message)`n`nStart anyway?" 'Warning' 'YesNo') -ne 'Yes') { return }
    }
    $evRoot = $S.Evidence.Path.TrimEnd('\')
    if ($case.StartsWith($evRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and -not $S.Evidence.IsZip) {
        if ((Show-Message "The case folder is inside the evidence folder. Output would mix with the evidence.`n`nContinue anyway?" 'Warning' 'YesNo') -ne 'Yes') { return }
    }
    Read-OptionsFromUi
    Save-Settings

    $plan = New-EztPlan -Evidence $S.Evidence -CaseDir $case -ToolIds $ids -ToolInfo $S.ToolInfo -Options $S.Options
    if ($plan.Conflicts.Count) {
        $policy = [string]$ui.CmbPolicy.SelectedItem
        $choice = switch ($policy) { 'Skip' { 'Skip' } 'New folder' { 'NewFolder' } 'Overwrite' { 'Overwrite' } default { Show-ConflictDialog $plan } }
        if (-not $choice) { return }
        Set-EztConflictPolicy -Plan $plan -Policy $choice
    }

    $S.Plan = $plan
    [void]$S.AllLog.Clear()
    $state = New-EztState
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($EnginePath, $Plan, $State, $Slots)
            Import-Module $EnginePath
            Invoke-EztPlan -Plan $Plan -State $State -LightSlots $Slots
        }.ToString()).AddArgument($EnginePath).AddArgument($plan).AddArgument($state).AddArgument([int]$ui.CmbSlots.SelectedItem)
    $S.Run = @{ PS = $ps; Handle = $ps.BeginInvoke(); State = $state; Started = Get-Date }
    Update-LogViewList
    $ui.CmbLogView.SelectedItem = $S.LogItems['*']
    $ui.TxtLog.Text = ''
    Set-Running $true
}

function Set-Running([bool]$On) {
    foreach ($c in 'TxtTools', 'BtnTools', 'TxtEvidence', 'BtnEvFolder', 'BtnEvZip', 'TxtCase', 'BtnCase', 'BtnStart', 'BtnSelectAll', 'BtnSelectNone', 'PnlMft', 'PnlEvtx', 'PnlRecmd', 'CmbSlots', 'CmbPolicy') {
        $ui[$c].IsEnabled = -not $On
    }
    $ui.BtnCancel.IsEnabled = $On
    $ui.PrgRun.IsIndeterminate = $false
    Update-All
}

function Update-Run {
    $run = $S.Run
    if (-not $run) { return }
    $st = $run.State
    $line = $null; $new = New-Object Text.StringBuilder
    while ($st.LogQueue.TryDequeue([ref]$line)) { [void]$new.AppendLine($line) }
    if ($new.Length) {
        [void]$S.AllLog.Append($new.ToString())
        if ($S.ViewPath -eq '*' -or ($ui.CmbLogView.SelectedItem -and $ui.CmbLogView.SelectedItem.Tag -eq '*')) {
            if ($S.ViewPath -ne '*') { $ui.TxtLog.Text = ''; $S.ViewPath = '*' }
            $ui.TxtLog.AppendText($new.ToString()); $ui.TxtLog.ScrollToEnd()
        }
    }
    foreach ($tp in $S.Plan.Tools) {
        foreach ($j in $tp.Jobs) {
            if ($j.OutDir -and $j.Status -ne 'Queued' -and $j.Status -ne 'Skipped') { Add-LogViewItem "$(Split-Path $j.OutDir -Leaf)  -  $($j.LogName)" (Join-Path $j.OutDir $j.LogName) }
        }
    }
    $elapsed = Format-EztDuration ((Get-Date) - $run.Started)
    switch ($st.Phase) {
        'Extracting' { $ui.LblRun.Text = "Extracting ZIP... $($st.ExtractPercent)%  ($elapsed)"; $ui.PrgRun.IsIndeterminate = $false; $ui.PrgRun.Value = $st.ExtractPercent }
        'Preparing' { $ui.LblRun.Text = "Preparing registry hives...  ($elapsed)"; $ui.PrgRun.IsIndeterminate = $true }
        'Running' {
            $now = @($S.Plan.Tools | ForEach-Object { $_.Jobs } | Where-Object Status -eq 'Running' | ForEach-Object Label)
            $ui.PrgRun.IsIndeterminate = $false
            $ui.PrgRun.Value = $(if ($st.Total) { 100 * $st.Completed / $st.Total } else { 0 })
            $ui.LblRun.Text = "$($st.Completed) of $($st.Total) done  ($elapsed)" + $(if ($now.Count) { '   Running: ' + ($now -join ', ') } else { '' })
        }
    }
    if ($ui.CmbLogView.SelectedItem -and $ui.CmbLogView.SelectedItem.Tag -ne '*') { Show-SelectedLog $false }
    Update-ToolRows
    if ($st.Done -and $run.Handle.IsCompleted) {
        try { $run.PS.EndInvoke($run.Handle) | Out-Null } catch { }
        if ($run.PS.Streams.Error.Count) { [void]$S.AllLog.AppendLine("ERROR " + $run.PS.Streams.Error[0].ToString()) }
        $run.PS.Dispose()
        $S.Run = $null
        $ui.PrgRun.IsIndeterminate = $false; $ui.PrgRun.Value = 100
        $ui.LblRun.Text = $st.Summary
        $ui.LblStatus.Text = $st.Summary
        Set-Running $false
        Update-CaseInfo
        $failed = @($S.Plan.Tools | ForEach-Object { $_.Jobs } | Where-Object { $_.Status -in 'Failed' })
        if ($failed.Count) { $ui.LblStatus.Text = "$($st.Summary). Check the log of: $(($failed | ForEach-Object Label) -join ', ')" }
        [Media.SystemSounds]::Asterisk.Play()
    }
}

#endregion

#region Refresh

function Update-All {
    if ($S.Suspend) { return }
    Update-ToolRows
    Update-Preview
    $n = @($catalog | Where-Object { $S.Selected.Contains($_.Id) -and $S.ToolInfo -and $S.ToolInfo.Tools[$_.Id] }).Count
    $running = [bool]$S.Run
    $ui.BtnStart.Content = if ($n) { "Start ($n tools)" } else { 'Start' }
    $ui.BtnStart.IsEnabled = (-not $running) -and $n -gt 0 -and $S.Evidence -and $S.ToolInfo
    if (-not $running -and -not $ui.LblRun.Text) { $ui.LblRun.Text = 'Ready' }
}

function Select-Folder([string]$Description, [string]$Start) {
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.Description = $Description; $d.ShowNewFolderButton = $true
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.SelectedPath = $Start }
    if ($d.ShowDialog() -eq 'OK') { return $d.SelectedPath }
    $null
}

#endregion

#region Wire up

Build-Presets
Build-ToolList
Write-OptionsToUi
foreach ($i in 1..6) { [void]$ui.CmbSlots.Items.Add($i) }
$ui.CmbSlots.SelectedItem = [int]$S.Settings.LightSlots
if ($null -eq $ui.CmbSlots.SelectedItem) { $ui.CmbSlots.SelectedItem = 3 }
foreach ($p in 'Ask', 'Skip', 'New folder', 'Overwrite') { [void]$ui.CmbPolicy.Items.Add($p) }
$ui.CmbPolicy.SelectedItem = $S.Settings.Policy
if ($null -eq $ui.CmbPolicy.SelectedItem) { $ui.CmbPolicy.SelectedItem = 'Ask' }

$ui.BtnTools.Add_Click({ $p = Select-Folder 'Folder with the EZ Tools (MFTECmd.exe, PECmd.exe, ...)' $ui.TxtTools.Text; if ($p) { Set-ToolsFolder $p; if ($ui.TxtEvidence.Text) { Set-Evidence $ui.TxtEvidence.Text $false } } })
$ui.TxtTools.Add_LostFocus({ if ($ui.TxtTools.Text.Trim() -ne $S.Settings.ToolsPath -or -not $S.ToolInfo) { Set-ToolsFolder $ui.TxtTools.Text } })
$ui.BtnEvFolder.Add_Click({ $p = Select-Folder 'Collection folder or mounted drive' $S.Settings.LastEvidenceDir; if ($p) { Set-Evidence $p } })
$ui.BtnEvZip.Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Filter = 'ZIP collections (*.zip)|*.zip|All files (*.*)|*.*'
        if ($S.Settings.LastEvidenceDir -and (Test-Path -LiteralPath $S.Settings.LastEvidenceDir)) { $d.InitialDirectory = $S.Settings.LastEvidenceDir }
        if ($d.ShowDialog($Window)) { Set-Evidence $d.FileName }
    })
$ui.TxtEvidence.Add_LostFocus({ $t = $ui.TxtEvidence.Text.Trim(); if ($t -and (-not $S.Evidence -or $S.Evidence.Path -ne $t) -and -not $S.EvidenceLoading) { Set-Evidence $t } })
$ui.BtnCase.Add_Click({
        $p = Select-Folder 'Case folder (output goes here)' (Split-Path $ui.TxtCase.Text)
        if ($p) { $ui.TxtCase.Text = $p; $S.Settings.CaseRoot = Split-Path $p; Update-CaseInfo; if ($S.Evidence -and $S.Evidence.IsZip) { Set-Evidence $ui.TxtEvidence.Text $false } else { Update-All } }
    })
$ui.TxtCase.Add_TextChanged({ Update-CaseInfo; Update-ToolRows })
$ui.TxtCase.Add_LostFocus({ if ($S.Evidence -and $S.Evidence.IsZip -and $S.Evidence.ExtractDir -ne (Get-ExtractDir)) { Set-Evidence $ui.TxtEvidence.Text $false } else { Update-Preview } })
foreach ($tb in 'TxtTools', 'TxtEvidence', 'TxtCase') {
    $ui[$tb].Add_KeyDown({ param($src, $evt) if ($evt.Key -eq 'Return') { [void]$src.MoveFocus((New-Object Windows.Input.TraversalRequest 'Next')) } })
}

foreach ($c in 'ChkMftMFT', 'ChkMftJ', 'ChkMftLogFile', 'ChkMftBoot', 'ChkMftSDS', 'ChkMftAt', 'ChkMftRs', 'RbEvtxKey', 'RbEvtxPick', 'RbEvtxAll', 'RbIdFor508', 'RbIdAll', 'RbIdCustom') {
    $ui[$c].Add_Click({ Read-OptionsFromUi })
}
$ui.TxtCustomIds.Add_TextChanged({ if (-not $S.Suspend) { if (-not $ui.RbIdCustom.IsChecked -and $ui.TxtCustomIds.IsFocused) { $ui.RbIdCustom.IsChecked = $true }; Read-OptionsFromUi } })
$ui.TxtLogFilter.Add_TextChanged({ Update-LogFilter })
$ui.CmbBatch.Add_SelectionChanged({ Read-OptionsFromUi })
$ui.BtnBatch.Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Filter = 'RECmd batch files (*.reb)|*.reb'
        if ($d.ShowDialog($Window)) { if (-not $ui.CmbBatch.Items.Contains($d.FileName)) { [void]$ui.CmbBatch.Items.Add($d.FileName) }; $ui.CmbBatch.SelectedItem = $d.FileName }
    })

$ui.BtnSelectAll.Add_Click({
        $S.Selected.Clear()
        foreach ($t in $catalog) { if ($S.ToolInfo -and $S.ToolInfo.Tools[$t.Id] -and (-not $S.Evidence -or $S.Avail[$t.Id])) { $S.Selected.Add($t.Id) } }
        $S.Settings.Preset = ''; Update-All
    })
$ui.BtnSelectNone.Add_Click({ $S.Selected.Clear(); $S.Settings.Preset = ''; Update-All })

$ui.BtnStart.Add_Click({ try { Start-Run } catch { Show-Message "Could not start: $($_.Exception.Message)" 'Error' | Out-Null; Set-Running $false } })
$ui.BtnCancel.Add_Click({ if ($S.Run) { $S.Run.State.Cancel = $true; $ui.LblRun.Text = 'Cancelling...' } })
$ui.BtnOpenCase.Add_Click({ $c = $ui.TxtCase.Text.Trim(); if ($c -and (Test-Path -LiteralPath $c)) { Start-Process explorer.exe -ArgumentList "`"$c`"" } else { $ui.LblStatus.Text = 'The case folder does not exist yet.' } })
$ui.CmbLogView.Add_SelectionChanged({ Show-SelectedLog $true })
$ui.BtnOpenLog.Add_Click({ $p = Get-SelectedLogPath; if ($p) { Start-Process notepad.exe -ArgumentList "`"$p`"" } })
$ui.BtnOpenToolDir.Add_Click({ $p = Get-SelectedLogPath; if ($p) { Start-Process explorer.exe -ArgumentList "/select,`"$p`"" } })

# An unexpected error in a button handler is shown in the status bar instead of closing the window.
$Window.Dispatcher.Add_UnhandledException({
        param($src, $evt)
        $evt.Handled = $true
        $msg = $evt.Exception.Message
        if ($evt.Exception.InnerException) { $msg = $evt.Exception.InnerException.Message }
        $ui.LblStatus.Text = "Error: $msg"
        $ui.LblStatus.Foreground = $Brush.Bad
    })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
        try { Update-Background; Update-Run } catch { $ui.LblStatus.Text = "Error: $($_.Exception.Message)" }
    })
$timer.Start()

$Window.Add_Closing({
        param($src, $evt)
        if ($S.Run) {
            if ((Show-Message 'Tools are still running. Stop them and close?' 'Warning' 'YesNo') -ne 'Yes') { $evt.Cancel = $true; return }
            $S.Run.State.Cancel = $true
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $S.Run.Handle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        }
        $S.Settings.LightSlots = [int]$ui.CmbSlots.SelectedItem
        $S.Settings.Policy = [string]$ui.CmbPolicy.SelectedItem
        Save-Settings
    })

$Window.Add_ContentRendered({
        if ($ToolsPath) { $S.Settings.ToolsPath = $ToolsPath }
        if ($S.Settings.ToolsPath) { Set-ToolsFolder $S.Settings.ToolsPath } else { Update-All }
        Set-Focus $S.Focus
        if ($Evidence) {
            if ($CaseDir) { $ui.TxtCase.Text = $CaseDir }
            Set-Evidence $Evidence (-not $CaseDir)
        }
        Update-CaseInfo
    })

#endregion

[void]$Window.ShowDialog()
