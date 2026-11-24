# EZ Triage

> **Make sure your EZ Tools are up to date before each case.** Eric Zimmerman releases updates often, and EZ Triage never updates them for you. Update while preparing the machine, not in the middle of a case: a newer version can change the output, and every tool in a case should be the same version.
>
> Open PowerShell in your EZ Tools folder (the one that contains `Get-ZimmermanTools.ps1`) and paste:
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\Get-ZimmermanTools.ps1 -Dest "$PWD" -Sync
> ```
>
> This runs Eric Zimmerman's own updater, `Get-ZimmermanTools.ps1`, which is digitally signed by ZimTech LLC (check with `Get-AuthenticodeSignature .\Get-ZimmermanTools.ps1`). It downloads the tools from his official download site (ericzimmermanstools.com, linked from [ericzimmerman.github.io](https://ericzimmerman.github.io/)), and `-Sync` refreshes the EvtxECmd and SQLECmd maps and the RECmd batch files from his GitHub projects ([evtx](https://github.com/EricZimmerman/evtx), [RECmd](https://github.com/EricZimmerman/RECmd), [SQLECmd](https://github.com/EricZimmerman/SQLECmd)). The updater and the tools are his work; EZ Triage only shows the command. It downloads only what changed. If it says it updated itself, paste it again. If Windows says access is denied, open PowerShell as administrator. Don't have the tools yet? Get `Get-ZimmermanTools.zip` from [Eric Zimmerman's site](https://ericzimmerman.github.io/).

A small Windows tool that runs [Eric Zimmerman's forensic tools](https://ericzimmerman.github.io/) against collected evidence. Point it at your EZ Tools folder and a collection, pick a preset or individual tools, and click **Start**. It works out the commands, runs the tools in parallel and keeps the output in a tidy case folder with one log per tool.

- **No install, no EXE.** Plain PowerShell with the built-in Windows interface, so it runs on locked-down forensic workstations where unsigned executables get blocked.
- **Offline.** It never touches the internet, and it never updates the EZ Tools itself (see the note at the top).
- **Reads the common collection formats:** KAPE output (folder or mounted VHDX), Velociraptor offline collections (folder or ZIP), mounted images (for example Arsenal Image Mounter) and plain folders.
- **Fast.** A full FOR508-style triage of a typical workstation collection takes about a minute.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in).
- [EZ Tools](https://ericzimmerman.github.io/) downloaded separately. They are not included in this repository. `Get-ZimmermanTools.ps1` now downloads the .NET 10 build into a `net` folder. That is what this is tested with. Older `net9` downloads still work.
- The .NET runtime those tools need (.NET 10 for the `net` build, .NET 9 for an older `net9` build). EZ Triage checks for it and warns if it is missing.
- **Windows on ARM** (for example a Parallels VM on an Apple Silicon Mac): the EZ Tools are x64 programs, so install the **x64** .NET Runtime. The ARM64 runtime alone is not enough. EZ Triage tells you if only the ARM64 one is installed.

## Getting started

1. Download the ZIP of the latest release from the [Releases page](https://github.com/MrVergilChair/ez-triage/releases) (for example `EZTriage-1.2.0.zip`). A release is a fixed, tested version, so every case runs the same code.
2. Check it against the SHA-256 in the release notes before you use it:
   ```powershell
   (Get-FileHash .\EZTriage-1.2.0.zip -Algorithm SHA256).Hash
   ```
   Do not use the ZIP if the hash differs.
3. Right-click the ZIP, choose **Properties**, tick **Unblock**, then extract it. This stops Windows warning about every file.
4. Double-click **`Start-EZTriage.cmd`**.

The version is shown at the bottom right of the window and recorded in every run record, so a case can always be tied to the release it was processed with. (**Code > Download ZIP** or `git clone` gets the latest development code instead of a release.)

The launcher bypasses the PowerShell execution policy for this one process only. Nothing on the machine is changed.

## Using it

1. **EZ Tools folder.** Point it at the folder that contains `MFTECmd.exe`, `PECmd.exe` and so on. Tools in subfolders (`EvtxECmd\`, `RECmd\`, `SQLECmd\`) are found too. The location is remembered.
2. **Evidence.** Choose a folder or drive, or a ZIP. EZ Triage detects the collection type, the host name (Velociraptor) and the Windows volumes inside it, and shows what each tool found, for example `642 files` for Prefetch or `11 of 16 logs` for event logs.
3. **Case folder.** Suggested automatically next to the evidence (`<evidence name>_EZTriage`). To put it somewhere else, click **Browse...** and pick the folder it should go in; the `<evidence name>_EZTriage` name is kept. Pick an existing case folder to add tools to it.
4. **Tools.** Pick a preset or tick tools yourself. Click a tool's name to see its options and the exact command that will run.
5. **Start.** Progress and a live log appear at the bottom. Use **Show** to switch between the combined log and any single tool's log. **Open in Timeline Explorer** opens that tool's CSV output (or, with "All tools", lets you pick from every CSV). It is enabled when `TimelineExplorer.exe` is in the EZ Tools folder, which is where `Get-ZimmermanTools.ps1` puts it.

### Several collections at once

Click **ZIP...** and select several ZIPs with Ctrl or Shift. Pick your tools and options once, choose a folder as the case folder, and click **Start**: the same tools and options run on every collection, one collection at a time, each into its own `<name>_EZTriage` folder inside the case folder. Resource use is the same as for one collection; only the total time adds up.

- The tool list and command preview are based on the first collection.
- The progress line shows which collection is running (`[2/3] ...`). **Cancel** stops the current collection and skips the rest.
- The log ends with a summary: each collection, OK or the problem, and its case folder.
- **If already processed: Ask** counts as **Skip** here, since you cannot be asked for every collection. Choose New folder or Overwrite to run them again.
- With **All tools** selected under Show, **Open in Timeline Explorer** lists the CSVs of every collection.

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
- **EvtxECmd:** parse the FOR508 key logs (default), only the logs you tick, or every log. Filter by the 108 FOR508 event IDs (default), all events, or your own list. Selected logs are copied to a staging folder first, the same approach as Mark Hallman's `Automate_EvtxECmd.ps1`, so the tool does not run for an hour. **Recover records** (`--rr`, off by default) also brings back records left in chunk slack and in chunks emptied when a log was cleared, so a cleared Security log can often still give you its old logons. They come after the live records, marked in a `Recovered` column (`Slack` or `ClearedChunk`). It needs a recent EvtxECmd (2026.11 has it); with an older one the box is unticked and says to update EZ Tools.
- **RECmd:** choose any batch file from RECmd's `BatchExamples` folder (`DFIRBatch.reb` by default, `Kroll_Batch.reb` for a smaller subset of the same categories) or your own `.reb`. The result is named after the batch file, for example `RECmd_DFIRBatch.csv`.
- Every other tool finds its input automatically. User-based tools always process **all** user profiles.

The key log list and the event ID list are plain text files in `config\`. Edit them to suit your cases:

- `config\EventLogs-FOR508.txt`: Security, System, Application, both PowerShell logs, Task Scheduler, the four RDP logs (LocalSessionManager, RemoteConnectionManager, RDPClient, RdpCoreTS), WMI, WinRM, Defender, Sysmon, BITS and NetworkProfile.
- `config\EventIds-FOR508.txt`: the event IDs passed to `--inc`.

## Searching for IOCs

Once the tools have run, **Search IOCs...** searches every tool CSV in a case for user names, IPs, file names, paths, hashes, domains or any other text. Run it again whenever new IOCs come in; nothing is reprocessed.

1. **Where to search.** A case folder, or a folder that holds several case folders (after processing several collections) to search every host at once.
2. **IOCs.** Paste them or load a `.txt`, one per line. Lines starting with `#` are ignored. Defanged IOCs from threat reports (`10[.]1[.]1[.]1`, `hxxp://`, `evil[.]com`) are fixed automatically.
3. **Search.** It runs in the background with a progress bar. **Cancel** keeps what was found so far, marked as partial.

Results go into a new folder per search, `Search\<date>_<time>\`, in the folder you searched:

| File | Contents |
|---|---|
| `Hits.csv` | One row per matching row: its time (and which column that time came from), the IOC, the host, the tool CSV and line it came from (`Source`, `SourceLine`), the column that matched, and every non-empty field of the row on one line. Opens in Timeline Explorer. |
| `Summary.csv` | One row per IOC per host: the full hit count and which tool CSVs it was found in. IOCs with no hits are listed too. |
| `SearchLog.txt` | When and where it ran, the IOCs, every file searched (size, rows), every file that could not be read, whether it was cancelled, and the SHA-256 of `Hits.csv`. |
| `IOCs.txt` | The IOC list as searched. |

Each case's `EZTriage.log` also gets one line per search, with the hit count and the results folder.

**How matching works**

- Case-insensitive "contains": `jsmith` finds `CORP\JSmith`, `evil.exe` finds `C:\Users\Public\EVIL.EXE`.
- IPs match exactly: `10.1.1.1` does not match `10.1.1.10` or `110.1.1.1`.
- Only the tool output is searched, never the evidence. A tool or event log that was not processed was not searched, so check `SearchLog.txt` before reading "0 hits" as "not there".
- Hashes: EZ Tools output holds few file hashes (mainly the SHA1 in Amcache). A SHA256 or MD5 from a threat report will usually find nothing even when the file was there. Search for the file name as well.
- RECmd's `Split by category` folder is skipped: it holds the same rows as the combined CSV, so every registry hit would count twice.

**Limits that keep it from running out of memory**

- Files are read one row at a time, so a multi-GB `$J` or event log CSV uses no more memory than a small one.
- `Hits.csv` keeps at most 10,000 rows per IOC per file. Counting continues past that, so `Summary.csv` and the window show the true totals. A very common IOC (the main user's name, for example) cannot fill the disk.
- The row text saved in `Hits.csv` is trimmed to 32,000 characters (Excel's cell limit). Matching always uses the whole row.
- A file that cannot be read is listed in `SearchLog.txt` and the search continues.

**Speed.** The matching itself is a small compiled helper (`lib\IocScanner.cs`, compiled on first use), so the number of IOCs barely matters. On a test VM it searched three workstation cases (730 MB of CSVs) in about 5 seconds, and a 2.5 GB CSV in about 12 seconds, staying under 400 MB of memory. Expect slower times on spinning disks or network shares.

Identical copies of a CSV within a case are searched once and listed in `SearchLog.txt` (MFTECmd 2026.11 writes the `$MFT` CSV a second time when it parses `$J`).

## The case folder

```
<case>\
  EZTriage.log                 every run, all tools, in order
  runs\<date>_<time>.json      audit record: evidence SHA-256, commands, tool versions and hashes, times, results
  FileSystem\MFTECmd\          MFT.csv, J.csv, MFTECmd_MFT.log, ...
  FileSystem\RBCmd\
  Execution\PECmd\             PECmd_Output.csv, PECmd_Output_Timeline.csv, PECmd.log
  Execution\AmcacheParser\
  Execution\AppCompatCacheParser\
  EventLogs\EvtxECmd\
  Registry\RECmd\              RECmd_DFIRBatch.csv (all results), Split by category\ (the same rows, one CSV per category)
  Registry\SBECmd\
  UserActivity\LECmd\ JLECmd\ SrumECmd\ WxTCmd\ SQLECmd\
  Evidence\                    extracted ZIP (only when the evidence was a ZIP)
  _work\                       working copies (see below)
  Search\<date>_<time>\        IOC search results (see Searching for IOCs)
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
- **Evidence hash.** A ZIP collection is hashed (SHA-256) at the start of every run and the hash goes into the case log and the run record, together with hashes of the tool binaries that ran, so the output can be tied to the exact collection. Folders and mounted drives are not hashed; hash them when you acquire them.
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
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence D:\Collection.zip -CaseDir D:\Cases\Host1
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence F:\ -CaseDir D:\Cases\Host1 -Preset 'Event logs' -EvtxIdMode All
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence F:\ -CaseDir D:\Cases\Host1 -Tools MFTECmd -MftFiles MFT,J -PlanOnly
```

Other parameters: `-EvtxMode Key|All`, `-EvtxCustomIds 4624,4625`, `-EvtxRecover` (EvtxECmd `--rr`), `-RecmdBatch Kroll_Batch.reb`, `-IfAlreadyRan Skip|NewFolder|Overwrite`, `-LightSlots 1-8`. `-PlanOnly` prints the commands without running anything.

### Several collections

Give `-CaseRoot` instead of `-CaseDir`, and point `-Evidence` at a folder of collections or a wildcard. Every ZIP and subfolder is processed in turn, one collection at a time, into `<CaseRoot>\<name>_EZTriage`. Resource use is the same as a single run; only the total time adds up. A collection that fails does not stop the others, and a summary table lists each one at the end.

```powershell
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence D:\Collections\*.zip -CaseRoot D:\Cases
.\Invoke-EZTriage.ps1 -ToolsPath C:\Tools\net -Evidence D:\KAPE -CaseRoot D:\Cases -Preset 'Execution'
```

Leave room on the case drive: each ZIP is extracted into its case folder, and `$J` or event log CSVs can be several GB on a busy machine.

### Searching for IOCs

`Search-EZTriage.ps1` runs the same search as the **Search IOCs** window:

```powershell
.\Search-EZTriage.ps1 -Path D:\Cases\Host1_EZTriage -IocFile D:\Intel\iocs.txt
.\Search-EZTriage.ps1 -Path D:\Cases -Ioc svc_backup, 10.1.1.5, evil.exe
```

`-Path` is a case folder or a folder of case folders. `-MaxHitsPerFile` changes the 10,000-row limit per IOC per file. Ctrl+C stops the search and still writes the partial results. The exit code is `0` when every file was searched in full, with or without hits, and `1` when the search failed, was cancelled or some files could not be read (so "no hits" is not conclusive).

### Exit codes

An unknown `-Preset` or `-Tools` name stops with the list of valid names. The exit code is `0` when every selected tool ran ("done with warnings" and "no output" count as ran) and `1` when a tool failed, was cancelled or is not installed, or the run stopped, so scripts and scheduled tasks can check `$LASTEXITCODE`. With `-CaseRoot`, `1` means at least one collection had a problem.

The window also accepts `-ToolsPath`, `-Evidence` and `-CaseDir`, so a shortcut can open straight onto a collection:

```
powershell.exe -STA -ExecutionPolicy Bypass -File EZTriage.ps1 -Evidence F:\
```

Settings (tools folder, last selection, options) are saved in `%APPDATA%\EZTriage\settings.json`.

## Troubleshooting

- **AppCompatCacheParser says the ShimCache value is incomplete.** The SYSTEM hive was copied from a live system while Windows was rewriting that value. The rest of the hive is fine. Collect again, or use a KAPE copy.
- **MFTECmd finds nothing on a mounted drive.** `$MFT` and `$J` are hidden on a drive mounted by Windows. Collect them with KAPE or Velociraptor first.
- **Disk images (E01, VHDX, VMDK)** are not read directly. Mount them first and point EZ Triage at the drive letter.
- **".NET 10 runtime NOT found"** (or another version). Install that .NET Runtime from Microsoft, or use the EZ Tools build that matches the runtime you have.
- **"...found, but only the ARM64 version"** (Windows on ARM). Install the x64 .NET Runtime of that version as well. It installs next to the ARM64 one, in `C:\Program Files\dotnet\x64`.
- **A case folder will not delete** ("Could not find a part of the path", "file name too long"). An extracted collection can contain paths longer than Windows' classic 260-character limit (Windows Error Reporting files, for example), which File Explorer and Windows PowerShell's `Remove-Item` cannot always remove. Delete it with the long-path form instead: `cmd /c rd /s /q "\\?\D:\Cases\Host1"` (replace the path; it must be a full path starting with a drive letter).
- **EvtxECmd is set to "Only the logs I tick below" but nothing is ticked.** Start stops and says so. Tick some logs or choose "FOR508 key logs". (Before 1.0 this setting could be saved empty by changing an option before choosing evidence.)
- **An event log has a size but no rows in the output.** Event logs take their full size up front (often 1 MB or 20 MB), so a log that was never used or was cleared still has that size. First check the event ID filter: with "FOR508 event IDs" a log with none of those IDs comes out empty, so try "All events". If the log was cleared, tick **Recover records** (`--rr`) to bring back old records from its emptied chunks.
- **The IOC search says it "needs to compile a small C# helper" and was blocked.** The search compiles `lib\IocScanner.cs` the first time it runs, because the same loop in PowerShell would take far too long on large CSVs. Some locked-down workstations block that. Processing with the tools is not affected.
- **"Done with warnings".** Open the tool's log (Show > tool name). Typical messages such as empty jump lists or unmapped ShellBag GUIDs do not mean data is missing.

## Credits

- [Eric Zimmerman](https://ericzimmerman.github.io/) for the tools this runs.
- The SANS FOR508 course for the artifact priorities behind the presets.
- Mark Hallman's `Automate_EvtxECmd.ps1` for the key event log approach and event ID list.

EZ Triage is an independent project. It is not affiliated with or endorsed by SANS, GIAC or Eric Zimmerman. FOR508 refers to the SANS course whose artifact priorities inspired the presets; SANS, GIAC and FOR508 are trademarks of their owners.
