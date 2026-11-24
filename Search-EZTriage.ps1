#Requires -Version 5.1
<#
.SYNOPSIS
    Searches EZ Triage output for IOCs (same search as the Search IOCs window).
.DESCRIPTION
    Searches every tool CSV in a case folder, or in every case folder under a folder of cases,
    for user names, IPs, file names, paths, hashes or any other text. Only the output is read.
    Results go to <Path>\Search\<date>_<time>\ (Hits.csv, Summary.csv, SearchLog.txt, IOCs.txt).
.EXAMPLE
    .\Search-EZTriage.ps1 -Path D:\Cases\Host1_EZTriage -IocFile D:\Intel\iocs.txt
.EXAMPLE
    .\Search-EZTriage.ps1 -Path D:\Cases -Ioc svc_backup, 10.1.1.5, evil.exe
.NOTES
    Exit code 0: every file was searched in full (with or without hits).
    Exit code 1: the search failed, was cancelled, or some files could not be read, so "no hits" is not conclusive.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$IocFile,
    [string[]]$Ioc,
    [ValidateRange(1, 10000000)][int]$MaxHitsPerFile = 10000
)
$ErrorActionPreference = 'Stop'
if ([bool]$IocFile -eq [bool]$Ioc) { throw 'Give either -IocFile (a text file, one IOC per line) or -Ioc (a list), not both.' }
$EnginePath = Join-Path $PSScriptRoot 'lib\EZTriage.Engine.psm1'
Import-Module $EnginePath -Force

# "powershell -File" passes "a,b" as one string; accept both forms.
$text = if ($IocFile) { Get-Content -LiteralPath $IocFile -Raw } else { (@($Ioc -split ',') | ForEach-Object { $_.Trim() }) -join "`n" }
$iocs = @(ConvertFrom-EztIocText $text)
if (-not $iocs.Count) { throw 'No IOCs given (blank lines and # comments are ignored).' }

$state = New-EztState
$runner = [powershell]::Create()
[void]$runner.AddScript({
        param($ModulePath, $Root, $Iocs, $State, $Cap)
        Import-Module $ModulePath -Force
        Invoke-EztSearch -Path $Root -Iocs $Iocs -State $State -Cap $Cap
    }).AddArgument($EnginePath).AddArgument($Path).AddArgument($iocs).AddArgument($state).AddArgument($MaxHitsPerFile)
$handle = $runner.BeginInvoke()
$failed = $null
try {
    while (-not $handle.IsCompleted) {
        $line = $null
        while ($state.LogQueue.TryDequeue([ref]$line)) { Write-Host $line }
        if ($state.BytesTotal) {
            $done = [double]$state.BytesDone; $sc = $state.Scanner; if ($sc) { $done += $sc.BytesRead }
            $pct = [int][Math]::Min(100, 100 * $done / $state.BytesTotal)
            Write-Progress -Activity 'Searching EZ Triage output' -Status "File $($state.FileIndex) of $($state.FileCount): $($state.CurrentFile)" -PercentComplete $pct
        }
        Start-Sleep -Milliseconds 250
    }
} finally {
    # Ctrl+C: stop the search cleanly so the partial results are written and marked as partial.
    if (-not $handle.IsCompleted) {
        $state.Cancel = $true; $sc = $state.Scanner; if ($sc) { $sc.Cancel = $true }
        while (-not $handle.IsCompleted) { Start-Sleep -Milliseconds 100 }
    }
    Write-Progress -Activity 'Searching EZ Triage output' -Completed
    $line = $null
    while ($state.LogQueue.TryDequeue([ref]$line)) { Write-Host $line }
    try { $runner.EndInvoke($handle) | Out-Null } catch { $failed = $state.Error; if (-not $failed) { $failed = $_.Exception.Message } }
    $runner.Dispose()
}

if ($failed -or -not $state.Result) {
    Write-Host "Exit code 1: the search failed: $failed" -ForegroundColor Red
    exit 1
}
$res = $state.Result
Write-Host ''
Write-Host (Format-EztSearchSummary $res)
if ($res.Cancelled -or $res.Skipped.Count) {
    Write-Host 'Exit code 1: not every file was searched (see SearchLog.txt).' -ForegroundColor Red
    exit 1
}
exit 0
