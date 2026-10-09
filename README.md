# EZ Triage

A small Windows tool that runs [Eric Zimmerman's forensic tools](https://ericzimmerman.github.io/) against collected evidence. Point it at your EZ Tools folder and a collection, pick a preset or individual tools, and click **Start**. It works out the commands, runs the tools in parallel and keeps the output in a tidy case folder with one log per tool.

- **No install, no EXE.** Plain PowerShell with the built-in Windows interface, so it runs on locked-down forensic workstations where unsigned executables get blocked.
- **Offline.** It never touches the internet.
- **Reads the common collection formats:** KAPE output (folder or mounted VHDX), Velociraptor offline collections (folder or ZIP), mounted images (for example Arsenal Image Mounter) and plain folders.
- **Fast.** A full FOR508-style triage of a typical workstation collection takes about a minute.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in).
- [EZ Tools](https://ericzimmerman.github.io/) downloaded separately. They are not included in this repository. The .NET 9 build (`net9` folder) is what this was tested with.
- The .NET runtime those tools need (.NET 9 for the `net9` build). EZ Triage checks for it and warns if it is missing.

## Getting started

1. Download this repository: **Code > Download ZIP**, or `git clone https://github.com/MrVergilChair/ez-triage.git`.
2. If you downloaded the ZIP, right-click it, choose **Properties**, tick **Unblock**, then extract it. This stops Windows warning about every file.
3. Double-click **`Start-EZTriage.cmd`**.

The launcher bypasses the PowerShell execution policy for this one process only. Nothing on the machine is changed.

## Using it

1. **EZ Tools folder.** Point it at the folder that contains `MFTECmd.exe`, `PECmd.exe` and so on. Tools in subfolders (`EvtxECmd\`, `RECmd\`, `SQLECmd\`) are found too. The location is remembered.
2. **Evidence.** Choose a folder or drive, or a ZIP. EZ Triage detects the collection type, the host name (Velociraptor) and the Windows volumes inside it, and shows what each tool found, for example `642 files` for Prefetch or `11 of 16 logs` for event logs.
3. **Case folder.** Suggested automatically next to the evidence (`<evidence name>_EZTriage`). Change it if you like.
4. **Tools.** Pick a preset or tick tools yourself. Click a tool's name to see its options and the exact command that will run.
5. **Start.** Progress and a live log appear at the bottom. Use **Show** to switch between the combined log and any single tool's log.

### Presets

| Preset | Tools |
|---|---|
| FOR508 triage | MFTECmd, RBCmd, PECmd, AmcacheParser, AppCompatCacheParser, EvtxECmd, RECmd, SBECmd, LECmd, JLECmd, SrumECmd, WxTCmd, SQLECmd |
| Execution | PECmd, AmcacheParser, AppCompatCacheParser, EvtxECmd, SrumECmd |
| File system | MFTECmd, RBCmd, LECmd, SBECmd |
| Event logs | EvtxECmd |
| User activity | SBECmd, LECmd, JLECmd, WxTCmd, SQLECmd, SrumECmd |

RecentFileCacheParser (Windows 7) and SumECmd (Windows Server) are available but not in any preset.

### Tool options

- **MFTECmd:** choose any of `$MFT`, `$J`, `$LogFile`, `$Boot` and `$SDS` separately (only `$MFT` by default), plus all timestamps (`--at`) and slack recovery (`--rs`). `$J` is parsed with the `$MFT` so paths are complete.
- **EvtxECmd:** parse the FOR508 key logs (default), only the logs you tick, or every log. Filter by the 108 FOR508 event IDs (default), all events, or your own list. Selected logs are copied to a staging folder first, the same approach as Mark Hallman's `Automate_EvtxECmd.ps1`, so the tool does not run for an hour.
- **RECmd:** choose any batch file from RECmd's `BatchExamples` folder (`Kroll_Batch.reb` by default, `DFIRBatch.reb` for more coverage) or your own `.reb`.
- Every other tool finds its input automatically. User-based tools always process **all** user profiles.

The key log list and the event ID list are plain text files in `config\`. Edit them to suit your cases:

- `config\EventLogs-FOR508.txt`: Security, System, Application, both PowerShell logs, Task Scheduler, the four RDP logs (LocalSessionManager, RemoteConnectionManager, RDPClient, RdpCoreTS), WMI, WinRM, Defender, Sysmon, BITS and NetworkProfile.
- `config\EventIds-FOR508.txt`: the event IDs passed to `--inc`.

## The case folder

```
<case>\
  EZTriage.log                 every run, all tools, in order
  runs\<date>_<time>.json      audit record: commands, tool versions, times, results
  FileSystem\MFTECmd\          MFT.csv, J.csv, MFTECmd_MFT.log, ...
  FileSystem\RBCmd\
  Execution\PECmd\             PECmd_Output.csv, PECmd_Output_Timeline.csv, PECmd.log
  Execution\AmcacheParser\
  Execution\AppCompatCacheParser\
  EventLogs\EvtxECmd\
  Registry\RECmd\
  Registry\SBECmd\
  UserActivity\LECmd\ JLECmd\ SrumECmd\ WxTCmd\ SQLECmd\
  Evidence\                    extracted ZIP (only when the evidence was a ZIP)
  _work\                       working copies (see below)
```

### Running again

EZ Triage remembers what already ran in each case folder. When you start again it asks what to do with tools that already finished:

- **Skip them.** Keeps the earlier output and runs only what is new (for example `$J` added after an `$MFT`-only run). Anything that failed before is retried.
- **Run again in new folder.** Writes to `MFTECmd_run2`, `MFTECmd_run3` and so on, next to the original.
- **Overwrite.** Deletes the earlier output for that tool first.

Set **If already processed** next to the Start button to choose once instead of being asked.

## What it handles for you

The evidence is never modified. When a tool needs something fixed first, EZ Triage works on a copy under `<case>\_work`.

- **ZIP collections** are extracted once into the case folder and reused on later runs.
- **Velociraptor hives.** Velociraptor stores sparse files trimmed, with an `.idx` file describing the original layout. Registry hives and their `.LOG` files lose trailing pages that way, which breaks transaction log replay. Hives are rebuilt to full size before RECmd, SBECmd, AmcacheParser, AppCompatCacheParser and SrumECmd read them.
- **Dirty SRUM databases** (normal for a copy of a running system) are recovered with `esentutl /r`, or repaired with `esentutl /p` when the logs are incomplete, before SrumECmd parses them.
- **SQLite databases** (Windows Timeline, browsers and others) are copied with their `-wal`/`-shm` files before WxTCmd and SQLECmd open them. SQLite needs write access next to a database and can change it, which fails on read-only KAPE output and would alter evidence elsewhere.
- **KAPE `LongFileNames`.** Shortcut files KAPE moved there because their paths were too long are parsed into `LECmd_LongFileNames.csv`. The original path is in each file's `_OriginalPathInfo.txt`.
- **Tool status.** EZ Tools return exit code 0 even when they fail, so EZ Triage decides from the files written and the tool's own output: **done**, **done with warnings** (the tool logged errors but wrote output, usually harmless), **no output** or **failed**.

### Speed

Heavy tools (MFTECmd, EvtxECmd, RECmd) run one at a time, starting with the largest job. Light tools run alongside them, three at a time by default (change **Light tools in parallel**). Preparation steps run in the background so tools that do not need them start immediately. Tools that clash (WxTCmd and SQLECmd both unpack the same SQLite DLL) never run together.

## Command line

`Invoke-EZTriage.ps1` uses the same engine without the window, which is handy for scripting:

```powershell
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net9 -Evidence D:\Collection.zip -CaseDir D:\Cases\Host1
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net9 -Evidence F:\ -CaseDir D:\Cases\Host1 -Preset 'Event logs' -EvtxIdMode All
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net9 -Evidence F:\ -CaseDir D:\Cases\Host1 -Tools MFTECmd -MftFiles MFT,J -PlanOnly
```

Other parameters: `-EvtxMode Key|All`, `-EvtxCustomIds 4624,4625`, `-RecmdBatch DFIRBatch.reb`, `-IfAlreadyRan Skip|NewFolder|Overwrite`, `-LightSlots 1-8`. `-PlanOnly` prints the commands without running anything.

The window also accepts `-ToolsPath`, `-Evidence` and `-CaseDir`, so a shortcut can open straight onto a collection:

```
powershell.exe -STA -ExecutionPolicy Bypass -File EZTriage.ps1 -Evidence F:\
```

Settings (tools folder, last selection, options) are saved in `%APPDATA%\EZTriage\settings.json`.

## Troubleshooting

- **AppCompatCacheParser says the ShimCache value is incomplete.** The SYSTEM hive was copied from a live system while Windows was rewriting that value. The rest of the hive is fine. Collect again, or use a KAPE copy.
- **MFTECmd finds nothing on a mounted drive.** `$MFT` and `$J` are hidden on a drive mounted by Windows. Collect them with KAPE or Velociraptor first.
- **Disk images (E01, VHDX, VMDK)** are not read directly. Mount them first and point EZ Triage at the drive letter.
- **".NET 9 runtime NOT found".** Install the .NET 9 Runtime from Microsoft, or use the EZ Tools build that matches the runtime you have.
- **"Done with warnings".** Open the tool's log (Show > tool name). Typical messages such as empty jump lists or unmapped ShellBag GUIDs do not mean data is missing.

## Credits

- [Eric Zimmerman](https://ericzimmerman.github.io/) for the tools this runs.
- The SANS FOR508 course for the artifact priorities behind the presets.
- Mark Hallman's `Automate_EvtxECmd.ps1` for the key event log approach and event ID list.
