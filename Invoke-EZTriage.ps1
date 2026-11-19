#Requires -Version 5.1
<#
.SYNOPSIS
    Runs EZ Triage without the window (same engine as the GUI).
.EXAMPLE
    .\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence D:\Collection.zip -CaseDir D:\Cases\Host1 -Preset 'FOR508 triage'
.EXAMPLE
    .\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence F:\ -CaseDir D:\Cases\Host1 -Tools EvtxECmd -EvtxIdMode All
.NOTES
    Exit code 0: every selected tool ran ("done with warnings" and "no output" count as ran).
    Exit code 1: a tool failed, was cancelled or is not installed, the run stopped, or the arguments were invalid.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolsPath,
    [Parameter(Mandatory)][string]$Evidence,
    [Parameter(Mandatory)][string]$CaseDir,
    [string]$Preset,
    [string[]]$Tools,
    [string[]]$MftFiles = @('MFT'),   # any of MFT, J, LogFile, Boot, SDS
    [ValidateSet('Key', 'All')][string]$EvtxMode = 'Key',
    [ValidateSet('FOR508', 'All', 'Custom')][string]$EvtxIdMode = 'FOR508',
    [string]$EvtxCustomIds = '',
    [string]$RecmdBatch = 'Kroll_Batch.reb',
    [ValidateSet('Skip', 'NewFolder', 'Overwrite')][string]$IfAlreadyRan = 'Skip',
    [ValidateRange(1, 8)][int]$LightSlots = 3,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
# "powershell -File" passes "a,b" as one string; accept both forms.
$MftFiles = @($MftFiles -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Tools = @($Tools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Import-Module (Join-Path $PSScriptRoot 'lib\EZTriage.Engine.psm1') -Force

# Unknown names are an error: a typo must not fall back to the full triage or run nothing.
$presets = Get-EztPresets
$catalogIds = @(Get-EztCatalog | ForEach-Object Id)
$ids = @()
if ($Preset) {
    $name = @($presets.Keys | Where-Object { $_ -eq $Preset })[0]
    if (-not $name) { throw "Unknown preset '$Preset'. Valid presets: $(($presets.Keys | ForEach-Object { "'$_'" }) -join ', ')" }
    $ids += $presets[$name]
}
foreach ($t in $Tools) {
    $id = @($catalogIds | Where-Object { $_ -eq $t })[0]
    if (-not $id) { throw "Unknown tool '$t'. Valid tools: $($catalogIds -join ', ')" }
    $ids += $id
}
if (-not $ids) { $ids = $presets['FOR508 triage'] }
$ids = @($ids | Select-Object -Unique)

$toolInfo = Find-EztTools -Path $ToolsPath
if (-not $toolInfo.Tools.Count) { throw "No EZ Tools found under $ToolsPath" }
if (-not $toolInfo.DotNet.Ok) { Write-Warning $toolInfo.DotNet.Message }

$opt = Get-EztDefaultOptions
$opt.MftFiles = $MftFiles; $opt.EvtxMode = $EvtxMode; $opt.EvtxIdMode = $EvtxIdMode
$opt.EvtxCustomIds = $EvtxCustomIds; $opt.RecmdBatch = $RecmdBatch

$sw = [Diagnostics.Stopwatch]::StartNew()
$extract = if ($Evidence -like '*.zip') { Join-Path $CaseDir ('Evidence\' + [IO.Path]::GetFileNameWithoutExtension($Evidence)) } else { $null }
$ev = Open-EztEvidence -Path $Evidence -ExtractTo $extract
if ($ev.Error) { throw $ev.Error }
Write-Host "Evidence: $($ev.Description)  (read in $([int]$sw.ElapsedMilliseconds) ms)"
$ev.Warnings | ForEach-Object { Write-Warning $_ }

$plan = New-EztPlan -Evidence $ev -CaseDir $CaseDir -ToolIds $ids -ToolInfo $toolInfo -Options $opt
foreach ($c in $plan.Conflicts) { Write-Host "Already processed: $($c.Tool.Id) -> $IfAlreadyRan" }
if ($plan.Conflicts) { Set-EztConflictPolicy -Plan $plan -Policy $IfAlreadyRan }

if ($PlanOnly) {
    foreach ($tp in $plan.Tools) {
        Write-Host "`n[$($tp.Tool.Id)]" -ForegroundColor Cyan
        Write-Host (Get-EztCommandPreview -Plan $plan -ToolId $tp.Tool.Id)
    }
    return
}

$state = New-EztState
$runner = [powershell]::Create()
[void]$runner.AddScript({
        param($ModulePath, $Plan, $State, $Slots)
        Import-Module $ModulePath -Force
        Invoke-EztPlan -Plan $Plan -State $State -LightSlots $Slots
    }).AddArgument((Join-Path $PSScriptRoot 'lib\EZTriage.Engine.psm1')).AddArgument($plan).AddArgument($state).AddArgument($LightSlots)
$handle = $runner.BeginInvoke()
try {
    while (-not $handle.IsCompleted) {
        $line = $null
        while ($state.LogQueue.TryDequeue([ref]$line)) { Write-Host $line }
        Start-Sleep -Milliseconds 200
    }
} finally {
    if (-not $handle.IsCompleted) { $state.Cancel = $true; while (-not $handle.IsCompleted) { Start-Sleep -Milliseconds 100 } }
    $line = $null
    while ($state.LogQueue.TryDequeue([ref]$line)) { Write-Host $line }
    $runner.EndInvoke($handle) | Out-Null
    $runner.Streams.Error | ForEach-Object { Write-Warning $_.ToString() }
    $runner.Dispose()
}

# Exit code for scripts and scheduled tasks (see .NOTES).
$problems = @()
if ($state.Error) { $problems += "run stopped: $($state.Error)" }
foreach ($tp in $plan.Tools) {
    if ($tp.Missing) { $problems += "$($tp.Tool.Id) not installed"; continue }
    foreach ($j in $tp.Jobs) { if ($j.Status -in 'Failed', 'Cancelled') { $problems += "$($j.Label) $(Get-EztStatusText $j.Status)" } }
}
if ($problems) {
    Write-Host "Exit code 1: $($problems -join '; ')" -ForegroundColor Red
    exit 1
}
exit 0
