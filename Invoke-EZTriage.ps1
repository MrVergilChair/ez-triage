#Requires -Version 5.1
<#
.SYNOPSIS
    Runs EZ Triage without the window (same engine as the GUI).
.DESCRIPTION
    One collection: -Evidence <folder, drive or ZIP> -CaseDir <case folder>.
    Several collections: -Evidence <folder of collections, or a wildcard> -CaseRoot <folder>.
    Each ZIP and each subfolder is processed in turn, one at a time, into
    <CaseRoot>\<name>_EZTriage. A failed collection does not stop the others.
.EXAMPLE
    .\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence D:\Collection.zip -CaseDir D:\Cases\Host1 -Preset 'FOR508 triage'
.EXAMPLE
    .\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence F:\ -CaseDir D:\Cases\Host1 -Tools EvtxECmd -EvtxIdMode All
.EXAMPLE
    .\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence D:\Collections\*.zip -CaseRoot D:\Cases
.NOTES
    Exit code 0: every selected tool ran ("done with warnings" and "no output" count as ran).
    Exit code 1: a tool failed, was cancelled or is not installed, the run stopped, or the arguments were invalid.
    With -CaseRoot, exit code 1 means at least one collection had one of those problems.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolsPath,
    [Parameter(Mandatory)][string]$Evidence,
    [string]$CaseDir,
    [string]$CaseRoot,
    [string]$Preset,
    [string[]]$Tools,
    [string[]]$MftFiles = @('MFT'),   # any of MFT, J, LogFile, Boot, SDS
    [ValidateSet('Key', 'All')][string]$EvtxMode = 'Key',
    [ValidateSet('FOR508', 'All', 'Custom')][string]$EvtxIdMode = 'FOR508',
    [string]$EvtxCustomIds = '',
    [string]$RecmdBatch = 'DFIRBatch.reb',
    [ValidateSet('Skip', 'NewFolder', 'Overwrite')][string]$IfAlreadyRan = 'Skip',
    [ValidateRange(1, 8)][int]$LightSlots = 3,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
if ([bool]$CaseDir -eq [bool]$CaseRoot) { throw 'Give either -CaseDir (one collection) or -CaseRoot (several collections), not both.' }
# "powershell -File" passes "a,b" as one string; accept both forms.
$MftFiles = @($MftFiles -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Tools = @($Tools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$EnginePath = Join-Path $PSScriptRoot 'lib\EZTriage.Engine.psm1'
Import-Module $EnginePath -Force

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

function Invoke-OneCollection([string]$EvidencePath, [string]$Case) {
    # Runs the selected tools on one collection. Returns the list of problems (empty = success).
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $extract = if ($EvidencePath -like '*.zip') { Join-Path $Case ('Evidence\' + [IO.Path]::GetFileNameWithoutExtension($EvidencePath)) } else { $null }
    $ev = Open-EztEvidence -Path $EvidencePath -ExtractTo $extract
    if ($ev.Error) { throw $ev.Error }
    Write-Host "Evidence: $($ev.Description)  (read in $([int]$sw.ElapsedMilliseconds) ms)"
    $ev.Warnings | ForEach-Object { Write-Warning $_ }

    $plan = New-EztPlan -Evidence $ev -CaseDir $Case -ToolIds $ids -ToolInfo $toolInfo -Options $opt
    foreach ($c in $plan.Conflicts) { Write-Host "Already processed: $($c.Tool.Id) -> $IfAlreadyRan" }
    if ($plan.Conflicts) { Set-EztConflictPolicy -Plan $plan -Policy $IfAlreadyRan }

    if ($PlanOnly) {
        foreach ($tp in $plan.Tools) {
            Write-Host "`n[$($tp.Tool.Id)]" -ForegroundColor Cyan
            Write-Host (Get-EztCommandPreview -Plan $plan -ToolId $tp.Tool.Id)
        }
        return @()
    }

    $state = New-EztState
    $runner = [powershell]::Create()
    [void]$runner.AddScript({
            param($ModulePath, $Plan, $State, $Slots)
            Import-Module $ModulePath -Force
            Invoke-EztPlan -Plan $Plan -State $State -LightSlots $Slots
        }).AddArgument($EnginePath).AddArgument($plan).AddArgument($state).AddArgument($LightSlots)
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

    $problems = @()
    if ($state.Error) { $problems += "run stopped: $($state.Error)" }
    foreach ($tp in $plan.Tools) {
        if ($tp.Missing) { $problems += "$($tp.Tool.Id) not installed"; continue }
        foreach ($j in $tp.Jobs) { if ($j.Status -in 'Failed', 'Cancelled') { $problems += "$($j.Label) $(Get-EztStatusText $j.Status)" } }
    }
    , $problems
}

# One collection.
if ($CaseDir) {
    $problems = Invoke-OneCollection $Evidence $CaseDir
    if ($problems) {
        Write-Host "Exit code 1: $($problems -join '; ')" -ForegroundColor Red
        exit 1
    }
    exit 0
}

# Several collections: every ZIP and subfolder of a folder, or whatever a wildcard matches.
$items = if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Evidence)) { @(Get-Item -Path $Evidence -ErrorAction SilentlyContinue) }
elseif (Test-Path -LiteralPath $Evidence -PathType Container) { @(Get-ChildItem -LiteralPath $Evidence -Force) }
else { throw "-Evidence must be a folder of collections or a wildcard when -CaseRoot is used: $Evidence" }
$items = @($items | Where-Object { $_.PSIsContainer -or $_.Extension -eq '.zip' } | Sort-Object Name)
if (-not $items.Count) { throw "No collections (ZIP files or folders) found at $Evidence" }

Write-Host "Processing $($items.Count) collections one at a time into $CaseRoot" -ForegroundColor Cyan
$results = New-Object Collections.ArrayList
$n = 0
foreach ($item in $items) {
    $n++
    $leaf = if ($item.PSIsContainer) { $item.Name } else { $item.BaseName }
    $case = Join-Path $CaseRoot "${leaf}_EZTriage"
    Write-Host "`n===== [$n/$($items.Count)] $($item.Name) =====" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $problems = @(Invoke-OneCollection $item.FullName $case) }
    catch { $problems = @("could not process: $($_.Exception.Message)"); Write-Host "  $($problems[0])" -ForegroundColor Red }
    [void]$results.Add([pscustomobject]@{
            Collection = $item.Name
            Result     = $(if ($problems) { 'PROBLEM' } else { 'OK' })
            Time       = Format-EztDuration $sw.Elapsed
            Details    = $(if ($problems) { $problems -join '; ' } else { $case })
        })
}

Write-Host "`n===== Summary =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$bad = @($results | Where-Object Result -ne 'OK').Count
if ($bad) {
    Write-Host "Exit code 1: $bad of $($results.Count) collections had problems" -ForegroundColor Red
    exit 1
}
exit 0
