#Requires -Version 5.1
# EZ Triage engine: finds EZ Tools, reads evidence (folder, mounted drive, KAPE,
# Velociraptor, ZIP), plans tool runs and executes them in parallel.
# No GUI code lives here so the same engine drives the window and the CLI.

$script:ModuleRoot = Split-Path -Parent $PSScriptRoot
$script:ModuleFile = $PSCommandPath
$script:EngineVersion = '0.1.0'

#region Tool catalog

function Get-EztCatalog {
    # Category = output folder. Heavy tools run one at a time; light tools run alongside.
    @(
        [pscustomobject]@{ Id = 'MFTECmd'; Group = 'File system'; Category = 'FileSystem'; Exe = 'MFTECmd.exe'; Heavy = $true
            Artifact = 'NTFS metadata'; Description = 'Parses NTFS metadata files. Pick only the ones you need; $J and $LogFile take the longest.' }
        [pscustomobject]@{ Id = 'RBCmd'; Group = 'File system'; Category = 'FileSystem'; Exe = 'RBCmd.exe'; Heavy = $false
            Artifact = 'Recycle Bin'; Description = 'Deleted files with their original path and deletion time.' }
        [pscustomobject]@{ Id = 'PECmd'; Group = 'Execution'; Category = 'Execution'; Exe = 'PECmd.exe'; Heavy = $false
            Artifact = 'Prefetch'; Description = 'Run counts and the last 8 run times per program. One CSV row per prefetch file, plus a timeline CSV.' }
        [pscustomobject]@{ Id = 'AmcacheParser'; Group = 'Execution'; Category = 'Execution'; Exe = 'AmcacheParser.exe'; Heavy = $false
            Artifact = 'Amcache.hve'; Description = 'Program paths, install information and SHA1 hashes.' }
        [pscustomobject]@{ Id = 'AppCompatCacheParser'; Group = 'Execution'; Category = 'Execution'; Exe = 'AppCompatCacheParser.exe'; Heavy = $false
            Artifact = 'Shimcache'; Description = 'Shimcache entries from the SYSTEM hive.' }
        [pscustomobject]@{ Id = 'EvtxECmd'; Group = 'Event logs'; Category = 'EventLogs'; Exe = 'EvtxECmd.exe'; Heavy = $true
            Artifact = 'Event logs'; Description = 'Event logs to one CSV, normalized with the bundled maps. Defaults to the FOR508 key logs and event IDs so it finishes quickly.' }
        [pscustomobject]@{ Id = 'RECmd'; Group = 'Registry'; Category = 'Registry'; Exe = 'RECmd.exe'; Heavy = $true
            Artifact = 'Registry hives'; Description = 'Runs a batch file across every hive found (SYSTEM, SOFTWARE, SAM, NTUSER, UsrClass, Amcache). Transaction logs are replayed automatically.' }
        [pscustomobject]@{ Id = 'SBECmd'; Group = 'Registry'; Category = 'Registry'; Exe = 'SBECmd.exe'; Heavy = $false
            Artifact = 'ShellBags'; Description = 'Folders each user browsed, from NTUSER.DAT and UsrClass.dat. All users.' }
        [pscustomobject]@{ Id = 'LECmd'; Group = 'User activity'; Category = 'UserActivity'; Exe = 'LECmd.exe'; Heavy = $false
            Artifact = 'LNK files'; Description = 'Shortcut targets, volume serial numbers and timestamps. Every .lnk on the volume, all users.' }
        [pscustomobject]@{ Id = 'JLECmd'; Group = 'User activity'; Category = 'UserActivity'; Exe = 'JLECmd.exe'; Heavy = $false
            Artifact = 'Jump Lists'; Description = 'Recently opened files per application. All users.' }
        [pscustomobject]@{ Id = 'SrumECmd'; Group = 'User activity'; Category = 'UserActivity'; Exe = 'SrumECmd.exe'; Heavy = $false
            Artifact = 'SRUM'; Description = 'Per-application network and resource usage by hour (SRUDB.dat with the SOFTWARE hive).' }
        [pscustomobject]@{ Id = 'WxTCmd'; Group = 'User activity'; Category = 'UserActivity'; Exe = 'WxTCmd.exe'; Heavy = $false
            Artifact = 'Windows Timeline'; Description = 'ActivitiesCache.db for every user profile found.' }
        [pscustomobject]@{ Id = 'SQLECmd'; Group = 'User activity'; Category = 'UserActivity'; Exe = 'SQLECmd.exe'; Heavy = $false
            Artifact = 'Browser databases'; Description = 'SQLite databases under Users matched by the bundled maps (Chrome, Edge, Firefox and more).' }
        [pscustomobject]@{ Id = 'RecentFileCacheParser'; Group = 'Other'; Category = 'Other'; Exe = 'RecentFileCacheParser.exe'; Heavy = $false
            Artifact = 'Windows 7 only'; Description = 'RecentFileCache.bcf, found on Windows 7 and Server 2008 R2 only.' }
        [pscustomobject]@{ Id = 'SumECmd'; Group = 'Other'; Category = 'Other'; Exe = 'SumECmd.exe'; Heavy = $false
            Artifact = 'Server only'; Description = 'User Access Logging databases, found on Windows Server only.' }
    )
}

function Get-EztPresets {
    [ordered]@{
        'FOR508 triage' = @('MFTECmd', 'RBCmd', 'PECmd', 'AmcacheParser', 'AppCompatCacheParser', 'EvtxECmd', 'RECmd', 'SBECmd', 'LECmd', 'JLECmd', 'SrumECmd', 'WxTCmd', 'SQLECmd')
        'Execution'     = @('PECmd', 'AmcacheParser', 'AppCompatCacheParser', 'EvtxECmd', 'SrumECmd')
        'File system'   = @('MFTECmd', 'RBCmd', 'LECmd', 'SBECmd')
        'Event logs'    = @('EvtxECmd')
        'User activity' = @('SBECmd', 'LECmd', 'JLECmd', 'WxTCmd', 'SQLECmd', 'SrumECmd')
    }
}

function Get-EztDefaultOptions {
    @{
        MftFiles       = @('MFT')        # any of MFT, J, LogFile, Boot, SDS
        MftAllTimestamps = $false
        MftRecoverSlack  = $false
        EvtxMode       = 'Key'           # Key | Pick | All
        EvtxLogs       = @(Get-EztKeyLogs)
        EvtxIdMode     = 'FOR508'        # FOR508 | All | Custom
        EvtxCustomIds  = ''
        RecmdBatch     = 'Kroll_Batch.reb'
    }
}

function Read-EztListFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Get-EztKeyLogs { Read-EztListFile (Join-Path $script:ModuleRoot 'config\EventLogs-FOR508.txt') }

function Get-EztFor508Ids {
    $ids = (Read-EztListFile (Join-Path $script:ModuleRoot 'config\EventIds-FOR508.txt')) -join ','
    ConvertTo-EztIdList $ids
}

function ConvertTo-EztIdList([string]$Text) {
    # Normalizes "4624, 4625`n4688" into "4624,4625,4688"; drops anything that is not a number.
    (@($Text -split '[,\s;]+' | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)) -join ','
}

#endregion

#region EZ Tools discovery

function Find-EztTools {
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{ Path = $Path; Tools = @{}; Versions = @{}; BatchFiles = @(); Missing = @(); DotNet = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [pscustomobject]$result }

    # EZ Tools ship either flat or with a subfolder per tool (EvtxECmd\, RECmd\, SQLECmd\).
    $exes = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
        if (-not $exes.ContainsKey($f.Name)) { $exes[$f.Name] = $f.FullName }
    }
    foreach ($t in Get-EztCatalog) {
        if ($exes.ContainsKey($t.Exe)) {
            $result.Tools[$t.Id] = $exes[$t.Exe]
            try { $result.Versions[$t.Id] = [Diagnostics.FileVersionInfo]::GetVersionInfo($exes[$t.Exe]).FileVersion } catch { $result.Versions[$t.Id] = '' }
        } else { $result.Missing += $t.Id }
    }
    if ($result.Tools['RECmd']) {
        $bd = Join-Path (Split-Path $result.Tools['RECmd']) 'BatchExamples'
        if (Test-Path -LiteralPath $bd) { $result.BatchFiles = @(Get-ChildItem -LiteralPath $bd -Filter '*.reb' -File | Sort-Object Name | ForEach-Object Name) }
    }
    $result.DotNet = Test-EztDotNet $result.Tools
    [pscustomobject]$result
}

function Test-EztDotNet($Tools) {
    # Framework-dependent EZ Tools name the .NET version they need in *.runtimeconfig.json.
    $exe = @($Tools.Values) | Select-Object -First 1
    if (-not $exe) { return [pscustomobject]@{ Ok = $true; Needed = ''; Message = '' } }
    $cfg = [IO.Path]::ChangeExtension($exe, '.runtimeconfig.json')
    if (-not (Test-Path -LiteralPath $cfg)) { return [pscustomobject]@{ Ok = $true; Needed = ''; Message = 'Self-contained build' } }
    try {
        $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
        $fw = $j.runtimeOptions.framework
        if (-not $fw) { $fw = @($j.runtimeOptions.frameworks)[0] }
        $major = ($fw.version -split '\.')[0]
    } catch { return [pscustomobject]@{ Ok = $true; Needed = ''; Message = '' } }
    $roots = @("$env:ProgramFiles\dotnet\shared\Microsoft.NETCore.App")
    if ($env:DOTNET_ROOT) { $roots += (Join-Path $env:DOTNET_ROOT 'shared\Microsoft.NETCore.App') }
    $found = $false
    foreach ($r in $roots) {
        if ((Test-Path -LiteralPath $r) -and (Get-ChildItem -LiteralPath $r -Directory -Filter "$major.*" -ErrorAction SilentlyContinue)) { $found = $true }
    }
    $msg = if ($found) { ".NET $major runtime found" } else { ".NET $major runtime NOT found. Install the .NET $major Runtime or the tools will not start." }
    [pscustomobject]@{ Ok = $found; Needed = $major; Message = $msg }
}

#endregion

#region Evidence model
# Evidence is a tree of nodes: @{ Name; Path; IsDir; Size; Children }. Folder children are
# read lazily from disk; ZIP children are built from the entry list. Velociraptor names
# are URL-decoded ("C%3A" -> "C:") so every lookup uses real Windows names.

function ConvertFrom-EztVeloName([string]$Name) {
    if ($Name.IndexOf('%') -lt 0) { return $Name }
    try { [Uri]::UnescapeDataString($Name) } catch { $Name }
}

function New-EztNode([string]$Name, [string]$Path, [bool]$IsDir, [long]$Size, [string]$Rel = '') {
    # Rel = decoded path relative to the evidence root (used to rebuild clean paths).
    @{ Name = $Name; Path = $Path; IsDir = $IsDir; Size = $Size; Children = $null; Rel = $Rel }
}

function Join-EztRel([string]$Parent, [string]$Name) { if ($Parent) { "$Parent\$Name" } else { $Name } }

function Get-EztChildren($Evidence, $Node) {
    if ($null -ne $Node.Children) { return $Node.Children }
    $h = @{}   # PowerShell hashtables are case-insensitive, like NTFS
    if ($Node.IsDir -and -not $Evidence.IsZip) {
        try {
            $di = New-Object IO.DirectoryInfo -ArgumentList $Node.Path
            foreach ($fsi in $di.EnumerateFileSystemInfos()) {
                $name = if ($Evidence.Decode) { ConvertFrom-EztVeloName $fsi.Name } else { $fsi.Name }
                if ($h.ContainsKey($name)) { continue }
                $isDir = ($fsi.Attributes -band [IO.FileAttributes]::Directory) -ne 0
                $size = 0; if (-not $isDir) { $size = $fsi.Length }
                $h[$name] = New-EztNode $name $fsi.FullName $isDir $size (Join-EztRel $Node.Rel $name)
            }
        } catch { }
    }
    $Node.Children = $h
    $h
}

function Get-EztSafeSegment([string]$Seg) {
    # Turns a ZIP entry segment into a legal Windows file name (and blocks ".." escapes).
    $s = $Seg -replace '[<>:"|?*\x00-\x1f]', '_'
    if ($s -eq '..' -or $s -eq '.') { $s = '_' + $s }
    $s = $s -replace '[. ]+$', '_'
    if ($s -match '^(?i)(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?$') { $s = '_' + $s }
    if (-not $s) { $s = '_' }
    $s
}

function Open-EztEvidence {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExtractTo   # where a ZIP is (or will be) extracted
    )
    $Path = $Path.Trim().Trim('"')
    $ev = [pscustomobject]@{
        Path = $Path; Type = 'Unknown'; Description = ''; IsZip = $false; Decode = $false; TreeDecoded = $false
        ZipPath = $null; ExtractDir = $null; Extracted = $false; ZipBytes = 0
        Root = $null; Volumes = @(); Hostname = ''; Warnings = @(); Error = $null
    }
    if (-not (Test-Path -LiteralPath $Path)) { $ev.Error = 'Path not found.'; return $ev }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        $ext = $item.Extension.ToLowerInvariant()
        if ($ext -in '.e01', '.ex01', '.vhd', '.vhdx', '.vmdk', '.raw', '.dd', '.img', '.001') {
            $ev.Error = "Disk images are not read directly. Mount it first (Arsenal Image Mounter, or double-click a VHDX) and point to the mounted drive."
            return $ev
        }
        if ($ext -ne '.zip') { $ev.Error = 'Choose a folder, a mounted drive or a .zip collection.'; return $ev }
        $ev.IsZip = $true; $ev.ZipPath = $item.FullName; $ev.ZipBytes = $item.Length
        if (-not $ExtractTo) { $ExtractTo = Join-Path $item.DirectoryName ($item.BaseName) }
        $ev.ExtractDir = $ExtractTo
        if (Test-EztExtracted $ev) {
            # Already extracted earlier: read the extracted copy from disk instead of the ZIP.
            $ev.Extracted = $true; $ev.IsZip = $false
            $ev.Root = New-EztNode '' $ev.ExtractDir $true 0
        } else {
            $ev.Root = Read-EztZipTree $ev
            if ($ev.Error) { return $ev }
        }
    } else {
        $ev.Root = New-EztNode '' $item.FullName $true 0
    }

    # Identify the collection type from markers at (or just below) the root.
    $top = Get-EztChildren $ev $ev.Root
    $veloRoot = $null
    if ($top.ContainsKey('uploads') -and ($top.ContainsKey('client_info.json') -or $top.ContainsKey('collection_context.json') -or $top.ContainsKey('uploads.json'))) {
        $veloRoot = $ev.Root
    } else {
        foreach ($c in $top.Values) {
            if (-not $c.IsDir) { continue }
            $cc = Get-EztChildren $ev $c
            if ($cc.ContainsKey('uploads') -and ($cc.ContainsKey('client_info.json') -or $cc.ContainsKey('collection_context.json'))) { $veloRoot = $c; break }
        }
    }
    if ($veloRoot) {
        $ev.Type = 'Velociraptor'; $ev.Decode = $true
        # Children were read before we knew to decode; reset the cache so names decode.
        $veloName = if ($veloRoot -eq $ev.Root) { $null } else { $veloRoot.Name }
        Reset-EztChildren $ev $ev.Root
        $veloRoot = if ($veloName) { (Get-EztChildren $ev $ev.Root)[$veloName] } else { $ev.Root }
        $vc = Get-EztChildren $ev $veloRoot
        if ($vc.ContainsKey('client_info.json')) {
            $ci = $vc['client_info.json']
            try {
                if ($ev.IsZip) { $ev.Hostname = (Read-EztZipText $ev $ci.ZipEntry | ConvertFrom-Json).Hostname }
                else { $ev.Hostname = (Get-Content -LiteralPath $ci.Path -Raw | ConvertFrom-Json).Hostname }
            } catch { }
        }
    }

    $ev.Volumes = @(Find-EztVolumes $ev)
    if ($ev.Type -eq 'Unknown') {
        $kape = Test-EztKape $ev
        if ($kape) { $ev.Type = 'KAPE' }
        elseif ($item.PSIsContainer -and $item.FullName -match '^[A-Za-z]:\\?$') { $ev.Type = 'Mounted drive' }
        elseif ($ev.Volumes.Count) { $ev.Type = 'Folder' }
    }
    if (-not $ev.Volumes.Count) { $ev.Warnings += 'No Windows volume found (looked for Windows, Users, $MFT folders).' }
    if ($ev.Type -eq 'Mounted drive') { $ev.Warnings += 'NTFS system files ($MFT, $J) are usually hidden on a mounted drive. Collect them with KAPE if MFTECmd shows not found.' }

    $what = $ev.Type
    if ($ev.IsZip -or $ev.Extracted) { $what += ' (ZIP)' }
    $vols = ($ev.Volumes | ForEach-Object { $_.Label }) -join ', '
    $ev.Description = if ($ev.Volumes.Count) { "$what. Volumes: $vols" } else { $what }
    if ($ev.Hostname) { $ev.Description += ". Host: $($ev.Hostname)" }
    $ev
}

function Reset-EztChildren($Evidence, $Node) {
    if ($Evidence.IsZip) {
        # ZIP trees are prebuilt (already decoded when Velociraptor was spotted in the entry list).
        if (-not $Evidence.TreeDecoded) { $Evidence.Root = Read-EztZipTree $Evidence }
        return
    }
    $Node.Children = $null
}

function Test-EztKape($Evidence) {
    $top = Get-EztChildren $Evidence $Evidence.Root
    foreach ($n in $top.Keys) { if ($n -like '*_ConsoleLog.txt' -or $n -like '*CopyLog*.csv' -or $n -like '*_SkipLog.csv') { return $true } }
    foreach ($v in $Evidence.Volumes) {
        foreach ($r in $v.Roots) { if ($r.Path -match '\\[A-Za-z]$' -and $r -ne $Evidence.Root) { return $true } }
    }
    $false
}

function Get-EztZipDir($Evidence, $Dirs, [string]$Prefix) {
    # Returns (creating as needed) the directory node for a ZIP path prefix like "uploads/auto".
    $node = $null
    if ($Dirs.TryGetValue($Prefix, [ref]$node)) { return $node }
    $i = $Prefix.LastIndexOf('/')
    $parent = if ($i -lt 0) { $Dirs[''] } else { Get-EztZipDir $Evidence $Dirs $Prefix.Substring(0, $i) }
    $raw = $Prefix.Substring($i + 1)
    $name = if ($Evidence.Decode) { ConvertFrom-EztVeloName $raw } else { $raw }
    if ($parent.Children.ContainsKey($name)) { $node = $parent.Children[$name] }
    else {
        $node = New-EztNode $name ($parent.Path + '\' + (Get-EztSafeSegment $raw)) $true 0 (Join-EztRel $parent.Rel $name)
        $node.Children = @{}
        $parent.Children[$name] = $node
    }
    $Dirs[$Prefix] = $node
    $node
}

function Read-EztZipTree($Evidence) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = New-EztNode '' $Evidence.ExtractDir $true 0
    $root.Children = @{}
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Evidence.ZipPath)
    } catch { $Evidence.Error = "Cannot open ZIP: $($_.Exception.Message)"; return $root }
    try {
        # Decide on Velociraptor name decoding before building, so the tree is built once.
        $hasInfo = $false; $hasUploads = $false
        foreach ($e in $zip.Entries) {
            $n = $e.FullName
            if (-not $hasInfo -and $n -match '^([^/]+/)?(client_info|collection_context)\.json$') { $hasInfo = $true }
            if (-not $hasUploads -and $n -match '^([^/]+/)?uploads/') { $hasUploads = $true }
            if ($hasInfo -and $hasUploads) { break }
        }
        $Evidence.Decode = $hasInfo -and $hasUploads
        $Evidence.TreeDecoded = $Evidence.Decode
        $dirs = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        $dirs[''] = $root
        foreach ($e in $zip.Entries) {
            $full = $e.FullName.Replace('\', '/').Trim('/')
            if (-not $full) { continue }
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { [void](Get-EztZipDir $Evidence $dirs $full); continue }
            $i = $full.LastIndexOf('/')
            $parent = if ($i -lt 0) { $root } else { Get-EztZipDir $Evidence $dirs $full.Substring(0, $i) }
            $raw = $full.Substring($i + 1)
            $name = if ($Evidence.Decode) { ConvertFrom-EztVeloName $raw } else { $raw }
            if ($parent.Children.ContainsKey($name)) { continue }
            $node = New-EztNode $name ($parent.Path + '\' + (Get-EztSafeSegment $raw)) $false $e.Length (Join-EztRel $parent.Rel $name)
            $node.ZipEntry = $e.FullName
            $parent.Children[$name] = $node
        }
    } finally { $zip.Dispose() }
    $root
}

function Read-EztZipText($Evidence, [string]$EntryName) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Evidence.ZipPath)
    try {
        $e = $zip.GetEntry($EntryName)
        $r = New-Object IO.StreamReader -ArgumentList $e.Open()
        try { $r.ReadToEnd() } finally { $r.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-EztExtractMarker([string]$Dir) { Join-Path $Dir '.eztriage-extracted.json' }

function Test-EztExtracted($Evidence) {
    $m = Get-EztExtractMarker $Evidence.ExtractDir
    if (-not (Test-Path -LiteralPath $m)) { return $false }
    try {
        $j = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        $zi = Get-Item -LiteralPath $Evidence.ZipPath
        return ($j.Complete -and $j.ZipBytes -eq $zi.Length -and $j.ZipLastWrite -eq $zi.LastWriteTimeUtc.ToString('o'))
    } catch { return $false }
}

function Expand-EztZip {
    # Extracts once into ExtractDir; a marker records the ZIP size/time so reruns reuse it.
    param($Evidence, $State)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zi = Get-Item -LiteralPath $Evidence.ZipPath
    [void](New-Item -ItemType Directory -Path $Evidence.ExtractDir -Force)
    $zip = [IO.Compression.ZipFile]::OpenRead($Evidence.ZipPath)
    try {
        $total = [long]0; foreach ($e in $zip.Entries) { $total += $e.Length }
        $done = [long]0; $count = 0
        foreach ($e in $zip.Entries) {
            if ($State -and $State.Cancel) { throw 'Cancelled' }
            $segs = @($e.FullName -split '[\\/]' | Where-Object { $_ -ne '' })
            if (-not $segs) { continue }
            $target = $Evidence.ExtractDir
            foreach ($s in $segs) { $target = $target + '\' + (Get-EztSafeSegment $s) }
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) {
                [void][IO.Directory]::CreateDirectory((Get-EztLongPath $target)); continue
            }
            [void][IO.Directory]::CreateDirectory((Get-EztLongPath (Split-Path $target)))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Get-EztLongPath $target), $true)
            $done += $e.Length; $count++
            if ($State -and ($count % 50 -eq 0)) { $State.ExtractPercent = [int](100.0 * $done / [Math]::Max([long]1, $total)) }
        }
    } finally { $zip.Dispose() }
    @{ Complete = $true; ZipPath = $zi.FullName; ZipBytes = $zi.Length; ZipLastWrite = $zi.LastWriteTimeUtc.ToString('o'); ExtractedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Get-EztExtractMarker $Evidence.ExtractDir) -Encoding UTF8
    if ($State) { $State.ExtractPercent = 100 }
}

function Get-EztLongPath([string]$Path) {
    if ($Path.Length -lt 240 -or $Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    '\\?\' + $Path
}

#region Velociraptor hive repair
# Velociraptor stores sparse files compacted and writes a <file>.idx describing the
# original layout. Registry hives and their .LOG files lose trailing zero pages that
# way, which breaks transaction log replay. Registry tools therefore read full-size
# copies rebuilt under <case>\_work\hives. The evidence itself is never modified.

$script:HiveNamePattern = '^(?i)(NTUSER\.DAT|UsrClass\.dat|SYSTEM|SOFTWARE|SAM|SECURITY|DEFAULT|COMPONENTS|DRIVERS|BBI|ELAM|Amcache\.hve|Syscache\.hve|User\.dat|UserClasses\.dat|settings\.dat)$'

function Get-EztHiveFiles($Evidence, $Volume) {
    $list = New-Object Collections.ArrayList
    $stack = New-Object Collections.Stack
    foreach ($r in $Volume.Roots) { $stack.Push($r) }
    while ($stack.Count) {
        $n = $stack.Pop()
        $ch = Get-EztChildren $Evidence $n
        foreach ($c in $ch.Values) {
            if ($c.IsDir) { $stack.Push($c); continue }
            if ($c.Size -gt 0 -and $c.Name -match $script:HiveNamePattern) {
                [void]$list.Add($c)
                foreach ($s in 'LOG', 'LOG1', 'LOG2') { $k = "$($c.Name).$s"; if ($ch.ContainsKey($k)) { [void]$list.Add($ch[$k]) } }
            }
        }
    }
    $list.ToArray()
}

function Copy-EztVeloFile([string]$Src, [string]$Dst) {
    # Returns $true when the file had to be rebuilt from its .idx ranges.
    $idx = "$Src.idx"
    if (-not (Test-Path -LiteralPath $idx)) { Copy-Item -LiteralPath $Src -Destination $Dst -Force; return $false }
    $ranges = @((Get-Content -LiteralPath $idx -Raw | ConvertFrom-Json).ranges)
    $total = [long]0; foreach ($r in $ranges) { $total += [long]$r.length }
    $in = [IO.File]::Open($Src, 'Open', 'Read', 'ReadWrite')
    $out = [IO.File]::Create($Dst)
    try {
        $out.SetLength($total)
        $buf = New-Object byte[] (1MB)
        foreach ($r in $ranges) {
            $left = [long]$r.file_length
            if ($left -le 0) { continue }   # sparse range: stays zero
            $in.Position = [long]$r.file_offset
            $out.Position = [long]$r.original_offset
            while ($left -gt 0) {
                $n = $in.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $left))
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n); $left -= $n
            }
        }
    } finally { $in.Dispose(); $out.Dispose() }
    try { [IO.File]::SetLastWriteTimeUtc($Dst, [IO.File]::GetLastWriteTimeUtc($Src)) } catch { }
    $true
}

function Get-EztSafeRel([string]$Rel) { (($Rel -split '\\') | ForEach-Object { Get-EztSafeSegment $_ }) -join '\' }

function Get-EztHivePath($Volume, $Node, [string]$HiveStage) {
    if ($HiveStage) { Join-Path $HiveStage (Get-EztSafeRel (Get-EztLogicalPath $Volume $Node)) } else { $Node.Path }
}

function Invoke-EztHiveStage($Evidence, $Volume, [string]$Dir, $State) {
    $marker = Join-Path $Dir '.eztriage-hives.json'
    if (Test-Path -LiteralPath $marker) {
        try {
            $m = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
            if ($m.Complete -and $m.Evidence -eq $Evidence.Path) { Write-EztLog $State "Registry hives for $($Volume.Label): reusing repaired copies from an earlier run"; return }
        } catch { }
    }
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $files = @(Get-EztHiveFiles $Evidence $Volume)
    $rebuilt = 0
    foreach ($f in $files) {
        if ($State -and $State.Cancel) { throw 'Cancelled' }
        $dst = Join-Path $Dir (Get-EztSafeRel (Get-EztLogicalPath $Volume $f))
        [void][IO.Directory]::CreateDirectory((Split-Path $dst))
        if (Copy-EztVeloFile $f.Path $dst) { $rebuilt++ }
    }
    @{ Complete = $true; Evidence = $Evidence.Path; Files = $files.Count; Rebuilt = $rebuilt; Created = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    Write-EztLog $State ("Registry hives for {0}: copied {1} files, {2} restored to full size from Velociraptor sparse uploads ({3:n1}s)" -f $Volume.Label, $files.Count, $rebuilt, $sw.Elapsed.TotalSeconds)
}

#endregion

#region SRUM repair
# SRUDB.dat from a running machine is almost always "dirty". SrumECmd refuses it, so a
# copy is recovered (esentutl /r) or repaired (esentutl /p) under <case>\_work\srum and
# the clean database is parsed from a folder of its own (stale logs make ESE retry).

function Invoke-EztEsentutl([string]$Arguments, [string]$WorkDir) {
    $psi = New-Object Diagnostics.ProcessStartInfo -ArgumentList (Join-Path $env:SystemRoot 'System32\esentutl.exe'), $Arguments
    $psi.WorkingDirectory = $WorkDir; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ Exit = -1; Text = 'timed out' } }
    [pscustomobject]@{ Exit = $p.ExitCode; Text = $out.Result + $err.Result }
}

function Get-EztEseState([string]$Db) {
    $r = Invoke-EztEsentutl "/mh `"$Db`"" (Split-Path $Db)
    if ($r.Text -match 'State:\s*([^\r\n]+)') { return $Matches[1].Trim() }
    'Unknown'
}

function Invoke-EztSrumRepair($Evidence, $Volume, [string]$Dir, $State) {
    $db = Join-Path $Dir 'db\SRUDB.dat'
    $marker = Join-Path $Dir '.eztriage-srum.json'
    if ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $db)) {
        try { $m = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json; if ($m.Evidence -eq $Evidence.Path) { Write-EztLog $State "SRUM: reusing the repaired copy from an earlier run ($($m.Result))"; return } } catch { }
    }
    $sru = Resolve-EztFirst $Evidence $Volume @('Windows\System32\sru')
    if (-not $sru) { return }
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path (Join-Path $Dir 'db') -Force)
    foreach ($f in (Get-EztChildren $Evidence $sru).Values) {
        if ($f.IsDir -or $f.Name -like '*.idx') { continue }
        [void](Copy-EztVeloFile $f.Path (Join-Path $Dir $f.Name))
    }
    $work = Join-Path $Dir 'SRUDB.dat'
    $result = Get-EztEseState $work
    if ($result -notmatch 'Clean') {
        Write-EztLog $State "SRUM: database is '$result'. Recovering a copy with esentutl /r"
        [void](Invoke-EztEsentutl '/r sru /i /o' $Dir)
        $result = Get-EztEseState $work
        if ($result -notmatch 'Clean') {
            Write-EztLog $State 'SRUM: recovery not possible (logs incomplete). Repairing the copy with esentutl /p'
            [void](Invoke-EztEsentutl '/p SRUDB.dat /o' $Dir)
            $result = Get-EztEseState $work
            if ($result -match 'Clean') { $result = 'repaired' }
        } else { $result = 'recovered' }
    } else { $result = 'already clean' }
    Copy-Item -LiteralPath $work -Destination $db -Force
    @{ Evidence = $Evidence.Path; Result = $result; Created = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    $lvl = if ($result -match 'Dirty|Unknown') { 'WARN' } else { 'INFO' }
    Write-EztLog $State "SRUM: database $result" $lvl
}

#endregion

function Test-EztVolumeRoot($Children) {
    if ($Children.ContainsKey('$MFT') -or $Children.ContainsKey('$Extend') -or $Children.ContainsKey('$Recycle.Bin')) { return $true }
    $w = $Children['Windows']; $u = $Children['Users']
    if ($w -and $w.IsDir) { return $true }
    if ($u -and $u.IsDir) { return $true }
    if ($Children.ContainsKey('Documents and Settings')) { return $true }
    $false
}

function Find-EztVolumes($Evidence) {
    # Breadth-first search for folders that look like the root of a Windows volume.
    # Several physical roots can map to one volume (Velociraptor keeps NTFS files apart).
    $vols = [ordered]@{}
    $queue = New-Object Collections.Queue
    $queue.Enqueue(@($Evidence.Root, 0))
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 4000) {
        $item = $queue.Dequeue(); $node = $item[0]; $depth = $item[1]; $visited++
        $ch = Get-EztChildren $Evidence $node
        if (Test-EztVolumeRoot $ch) {
            $key = Get-EztVolumeKey $Evidence $node
            if (-not $vols.Contains($key)) { $vols[$key] = [pscustomobject]@{ Key = $key; Label = $key; Roots = New-Object Collections.ArrayList } }
            [void]$vols[$key].Roots.Add($node)
            continue
        }
        if ($depth -ge 6) { continue }
        foreach ($c in $ch.Values) {
            if ($c.IsDir -and $c.Name -notin 'results', 'System Volume Information', '$RECYCLE.BIN') { $queue.Enqueue(@($c, $depth + 1)) }
        }
    }
    foreach ($v in $vols.Values) { if ($v.Key -match '^[A-Z]$') { $v.Label = "$($v.Key):" } }
    @($vols.Values)
}

function Get-EztVolumeKey($Evidence, $Node) {
    $name = $Node.Name
    if ($Node -eq $Evidence.Root) {
        if ($Node.Path -match '^([A-Za-z]):\\?$') { return $Matches[1].ToUpperInvariant() }
        $name = Split-Path $Node.Path -Leaf
    }
    if ($name -match '(?:^|\\|^\\\\[.?]\\)([A-Za-z])(?::)?\\?$') { return $Matches[1].ToUpperInvariant() }
    if ($name -match 'HarddiskVolumeShadowCopy(\d+)') { return "VSS$($Matches[1])" }
    if ($name) { return $name }
    'Volume'
}

function Resolve-EztPath($Evidence, $Volume, [string]$Logical) {
    # Returns every node matching a logical path ("Users\*\NTUSER.DAT") across the volume's roots.
    $segs = @($Logical -split '\\' | Where-Object { $_ -ne '' })
    $current = New-Object Collections.ArrayList
    foreach ($r in $Volume.Roots) { [void]$current.Add($r) }
    foreach ($s in $segs) {
        $next = New-Object Collections.ArrayList
        $wild = $s.Contains('*') -or $s.Contains('?')
        foreach ($n in $current) {
            if (-not $n.IsDir) { continue }
            $ch = Get-EztChildren $Evidence $n
            if ($wild) { foreach ($c in $ch.Values) { if ($c.Name -like $s) { [void]$next.Add($c) } } }
            elseif ($ch.ContainsKey($s)) { [void]$next.Add($ch[$s]) }
        }
        $current = $next
        if ($current.Count -eq 0) { break }
    }
    $current.ToArray()   # callers wrap in @() for a stable array
}

function Get-EztLogicalPath($Volume, $Node) {
    # "Users\alice\NTUSER.DAT" for a node, relative to whichever volume root holds it.
    foreach ($r in $Volume.Roots) {
        if ($r.Rel -eq '') { return $Node.Rel }
        if ($Node.Rel.StartsWith($r.Rel + '\', [StringComparison]::OrdinalIgnoreCase)) { return $Node.Rel.Substring($r.Rel.Length + 1) }
    }
    $Node.Name
}

function Resolve-EztFirst($Evidence, $Volume, [string[]]$Candidates) {
    foreach ($c in $Candidates) {
        $r = @(Resolve-EztPath $Evidence $Volume $c)
        if ($r.Count) { return $r[0] }
    }
    $null
}

#endregion

#region Planning

function Format-EztArg([string]$Value) {
    # Quotes one argument the way CommandLineToArgvW expects (trailing backslashes doubled).
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]' -and -not $Value.EndsWith('\')) { return $Value }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\', 2 * $bs + 1); $bs = 0; [void]$sb.Append('"'); continue }
        if ($bs) { [void]$sb.Append('\', $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs) { [void]$sb.Append('\', 2 * $bs) }
    [void]$sb.Append('"')
    $sb.ToString()
}

function Join-EztArgs([object[]]$Parts) { ($Parts | ForEach-Object { Format-EztArg ([string]$_) }) -join ' ' }

function New-EztJob {
    param($Tool, [string]$Key, [string]$Label, [object[]]$ArgList, [string]$SubDir = '', [string]$LogName, [long]$Weight = 0, $Stage = $null, [string]$Inputs = '')
    # Tools sharing a Lock never run at the same time (WxTCmd and SQLECmd both unpack
    # SQLite.Interop.dll into the tools folder and crash if they collide).
    $lock = if ($Tool.Id -in 'WxTCmd', 'SQLECmd') { 'sqlite' } else { '' }
    [pscustomobject]@{
        ToolId = $Tool.Id; Key = $Key; Label = $Label; Heavy = $Tool.Heavy; Lock = $lock
        ArgList = $ArgList; SubDir = $SubDir; LogName = $LogName; Weight = $Weight; Stage = $Stage; Inputs = $Inputs
        OutDir = ''; Exe = ''; Arguments = ''; Signature = ''; Requires = @(); Status = 'Queued'; Detail = ''; Started = $null; Finished = $null; ExitCode = $null; Outputs = 0
    }
}

function Get-EztToolInputs {
    # Works out what each tool would read on one volume. Returns jobs (without output paths)
    # plus a short "found" summary used by the GUI before anything runs.
    param($Evidence, $Volume, $Tool, $Options, $ToolInfo, [bool]$MultiVolume, [string]$HiveStage = '', [string]$SrumStage = '')
    $p = if ($MultiVolume) { "$($Volume.Key)_" } else { '' }
    $jobs = New-Object Collections.ArrayList
    $found = ''
    switch ($Tool.Id) {
        'MFTECmd' {
            $map = [ordered]@{
                MFT     = @('$MFT')
                J       = @('$Extend\$UsnJrnl:$J', '$Extend\$J', '$Extend\$UsnJrnl_$J', '$J')
                LogFile = @('$LogFile')
                Boot    = @('$Boot')
                SDS     = @('$Secure:$SDS', '$Secure_$SDS', '$SDS')
            }
            $mft = Resolve-EztFirst $Evidence $Volume $map.MFT
            $have = @()
            foreach ($k in $map.Keys) {
                $n = Resolve-EztFirst $Evidence $Volume $map[$k]
                if (-not $n) { continue }
                $have += $k
                if ($Options.MftFiles -notcontains $k) { continue }
                $a = @('-f', $n.Path)
                if ($k -eq 'J' -and $mft) { $a += @('-m', $mft.Path) }
                if ($k -eq 'MFT') { if ($Options.MftAllTimestamps) { $a += '--at' }; if ($Options.MftRecoverSlack) { $a += '--rs' } }
                $a += @('--csv', '{OUT}', '--csvf', "$p$k.csv")
                [void]$jobs.Add((New-EztJob $Tool "MFTECmd:$($Volume.Key):$k" "MFTECmd $k" $a -LogName "MFTECmd_$p$k.log" -Weight $n.Size -Inputs $n.Path))
            }
            $found = if ($have) { ($have | ForEach-Object { '$' + $_ }) -join ' ' } else { '' }
        }
        'RBCmd' {
            $n = Resolve-EztFirst $Evidence $Volume @('$Recycle.Bin', 'RECYCLER')
            if ($n) {
                $count = @((Get-EztChildren $Evidence $n).Values).Count
                [void]$jobs.Add((New-EztJob $Tool "RBCmd:$($Volume.Key)" 'RBCmd' @('-d', $n.Path, '-q', '--csv', '{OUT}', '--csvf', "${p}RBCmd_Output.csv") -LogName "RBCmd$p.log" -Inputs $n.Path))
                $found = "$count SIDs"
            }
        }
        'PECmd' {
            $n = Resolve-EztFirst $Evidence $Volume @('Windows\Prefetch')
            if ($n) {
                $count = @((Get-EztChildren $Evidence $n).Values | Where-Object { $_.Name -like '*.pf' }).Count
                if ($count) {
                    [void]$jobs.Add((New-EztJob $Tool "PECmd:$($Volume.Key)" 'PECmd' @('-d', $n.Path, '-q', '--csv', '{OUT}', '--csvf', "${p}PECmd_Output.csv") -LogName "PECmd$p.log" -Inputs $n.Path))
                    $found = "$count files"
                }
            }
        }
        'AmcacheParser' {
            $n = Resolve-EztFirst $Evidence $Volume @('Windows\AppCompat\Programs\Amcache.hve')
            if ($n) {
                [void]$jobs.Add((New-EztJob $Tool "AmcacheParser:$($Volume.Key)" 'AmcacheParser' @('-f', (Get-EztHivePath $Volume $n $HiveStage), '-i', '--csv', '{OUT}', '--csvf', "${p}Amcache.csv") -LogName "AmcacheParser$p.log" -Inputs $n.Path))
                $found = 'found'
            }
        }
        'AppCompatCacheParser' {
            $n = Resolve-EztFirst $Evidence $Volume @('Windows\System32\config\SYSTEM')
            if ($n) {
                [void]$jobs.Add((New-EztJob $Tool "AppCompatCacheParser:$($Volume.Key)" 'AppCompatCacheParser' @('-f', (Get-EztHivePath $Volume $n $HiveStage), '--csv', '{OUT}', '--csvf', "${p}AppCompatCache.csv") -LogName "AppCompatCacheParser$p.log" -Inputs $n.Path))
                $found = 'SYSTEM hive'
            }
        }
        'EvtxECmd' {
            $logsDir = Resolve-EztFirst $Evidence $Volume @('Windows\System32\winevt\Logs', 'Windows\System32\winevt\logs')
            if ($logsDir) {
                $all = @((Get-EztChildren $Evidence $logsDir).Values | Where-Object { $_.Name -like '*.evtx' })
                $ids = switch ($Options.EvtxIdMode) { 'FOR508' { Get-EztFor508Ids } 'Custom' { ConvertTo-EztIdList $Options.EvtxCustomIds } default { '' } }
                $a = @('-d', '{SRC}', '--csv', '{OUT}', '--csvf', "${p}EvtxECmd_Output.csv")
                if ($ids) { $a += @('--inc', $ids) }
                if ($Options.EvtxMode -eq 'All') {
                    $a[1] = $logsDir.Path
                    $w = [long]0; foreach ($x in $all) { $w += $x.Size }
                    [void]$jobs.Add((New-EztJob $Tool "EvtxECmd:$($Volume.Key)" 'EvtxECmd' $a -LogName "EvtxECmd$p.log" -Weight $w -Inputs $logsDir.Path))
                    $found = "$($all.Count) logs"
                } else {
                    $want = @($Options.EvtxLogs)
                    $pick = @($all | Where-Object { $want -contains $_.Name })
                    if ($pick.Count) {
                        $w = [long]0; foreach ($x in $pick) { $w += $x.Size }
                        $stage = @($pick | ForEach-Object { @{ From = $_.Path; Name = $_.Name } })
                        [void]$jobs.Add((New-EztJob $Tool "EvtxECmd:$($Volume.Key)" 'EvtxECmd' $a -LogName "EvtxECmd$p.log" -Weight $w -Stage $stage -Inputs "$($pick.Count) selected logs"))
                    }
                    $found = "$($pick.Count) of $($want.Count) logs"
                }
            }
        }
        'RECmd' {
            # Only roots that hold hives (Velociraptor also keeps near-empty "\\.\C:" roots).
            $roots = @($Volume.Roots | Where-Object {
                    $one = [pscustomobject]@{ Roots = @($_) }
                    @(Resolve-EztPath $Evidence $one 'Windows\System32\config\SYSTEM').Count -or @(Resolve-EztPath $Evidence $one 'Users\*\NTUSER.DAT').Count
                })
            $batchDir = if ($ToolInfo -and $ToolInfo.Tools['RECmd']) { Join-Path (Split-Path $ToolInfo.Tools['RECmd']) 'BatchExamples' } else { 'BatchExamples' }
            $batch = if ([IO.Path]::IsPathRooted($Options.RecmdBatch)) { $Options.RecmdBatch } else { Join-Path $batchDir $Options.RecmdBatch }
            $bname = [IO.Path]::GetFileNameWithoutExtension($batch)
            if ($HiveStage -and $roots.Count) {
                [void]$jobs.Add((New-EztJob $Tool "RECmd:$($Volume.Key)" 'RECmd' @('-d', $HiveStage, '--bn', $batch, '--csv', '{OUT}', '--csvf', "$p$bname.csv") -LogName "RECmd$p.log" -Inputs $HiveStage))
            } else {
                $i = 0
                foreach ($r in $roots) {
                    $i++; $sfx = if ($roots.Count -gt 1) { "_$i" } else { '' }
                    [void]$jobs.Add((New-EztJob $Tool "RECmd:$($Volume.Key)$sfx" 'RECmd' @('-d', $r.Path, '--bn', $batch, '--csv', '{OUT}', '--csvf', "$p${bname}$sfx.csv") -LogName "RECmd$p$sfx.log" -Inputs $r.Path))
                }
            }
            $hives = @(Resolve-EztPath $Evidence $Volume 'Windows\System32\config\SYSTEM').Count + @(Resolve-EztPath $Evidence $Volume 'Windows\System32\config\SOFTWARE').Count + @(Resolve-EztPath $Evidence $Volume 'Users\*\NTUSER.DAT').Count
            if ($roots.Count) { $found = "$hives main hives" }
        }
        'SBECmd' {
            $n = Resolve-EztFirst $Evidence $Volume @('Users', 'Documents and Settings')
            if ($n) {
                $u = @(Resolve-EztPath $Evidence $Volume 'Users\*\NTUSER.DAT').Count
                [void]$jobs.Add((New-EztJob $Tool "SBECmd:$($Volume.Key)" 'SBECmd' @('-d', (Get-EztHivePath $Volume $n $HiveStage), '--csv', '{OUT}', '--csvf', "${p}SBECmd_Output.csv") -LogName "SBECmd$p.log" -Inputs $n.Path))
                $found = "$u users"
            }
        }
        'LECmd' {
            $roots = @($Volume.Roots | Where-Object { $c = Get-EztChildren $Evidence $_; $c.ContainsKey('Users') -or $c.ContainsKey('ProgramData') -or $c.ContainsKey('Documents and Settings') })
            $i = 0
            foreach ($r in $roots) {
                $i++; $sfx = if ($roots.Count -gt 1) { "_$i" } else { '' }
                [void]$jobs.Add((New-EztJob $Tool "LECmd:$($Volume.Key)$sfx" 'LECmd' @('-d', $r.Path, '-q', '--csv', '{OUT}', '--csvf', "${p}LECmd_Output$sfx.csv") -LogName "LECmd$p$sfx.log" -Inputs $r.Path))
            }
            $recent = @(Resolve-EztPath $Evidence $Volume 'Users\*\AppData\Roaming\Microsoft\Windows\Recent').Count
            if ($roots.Count) { $found = "$recent users with Recent" }
        }
        'JLECmd' {
            $n = Resolve-EztFirst $Evidence $Volume @('Users')
            $ad = @(Resolve-EztPath $Evidence $Volume 'Users\*\AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations') + @(Resolve-EztPath $Evidence $Volume 'Users\*\AppData\Roaming\Microsoft\Windows\Recent\CustomDestinations')
            if ($n -and $ad.Count) {
                [void]$jobs.Add((New-EztJob $Tool "JLECmd:$($Volume.Key)" 'JLECmd' @('-d', $n.Path, '-q', '--csv', '{OUT}', '--csvf', "${p}JLECmd_Output.csv") -LogName "JLECmd$p.log" -Inputs $n.Path))
                $cnt = 0; foreach ($d in $ad) { $cnt += @((Get-EztChildren $Evidence $d).Values).Count }
                $found = "$cnt files"
            }
        }
        'SrumECmd' {
            $n = Resolve-EztFirst $Evidence $Volume @('Windows\System32\sru\SRUDB.dat')
            if ($n) {
                $a = @('-f', $(if ($SrumStage) { Join-Path $SrumStage 'db\SRUDB.dat' } else { $n.Path }))
                $sw = Resolve-EztFirst $Evidence $Volume @('Windows\System32\config\SOFTWARE')
                if ($sw) { $a += @('-r', (Get-EztHivePath $Volume $sw $HiveStage)) }
                $a += @('--csv', '{OUT}')
                [void]$jobs.Add((New-EztJob $Tool "SrumECmd:$($Volume.Key)" 'SrumECmd' $a -SubDir $(if ($MultiVolume) { $Volume.Key } else { '' }) -LogName "SrumECmd$p.log" -Weight $n.Size -Inputs $n.Path))
                $found = 'SRUDB.dat'
            }
        }
        'WxTCmd' {
            $dbs = @(Resolve-EztPath $Evidence $Volume 'Users\*\AppData\Local\ConnectedDevicesPlatform\*\ActivitiesCache.db')
            foreach ($db in $dbs) {
                $parts = $db.Path -split '\\'
                $user = '?'; for ($i = 0; $i -lt $parts.Count - 1; $i++) { if ($parts[$i] -eq 'Users') { $user = $parts[$i + 1] } }
                $acct = Split-Path (Split-Path $db.Path) -Leaf
                $sub = Get-EztSafeSegment "$p${user}_$acct"
                [void]$jobs.Add((New-EztJob $Tool "WxTCmd:$($Volume.Key):$user/$acct" "WxTCmd $user" @('-f', $db.Path, '--csv', '{OUT}') -SubDir $sub -LogName "WxTCmd_$sub.log" -Inputs $db.Path))
            }
            if ($dbs.Count) { $found = "$($dbs.Count) databases" }
        }
        'SQLECmd' {
            $n = Resolve-EztFirst $Evidence $Volume @('Users')
            if ($n) {
                [void]$jobs.Add((New-EztJob $Tool "SQLECmd:$($Volume.Key)" 'SQLECmd' @('-d', $n.Path, '--csv', '{OUT}') -SubDir $(if ($MultiVolume) { $Volume.Key } else { '' }) -LogName "SQLECmd$p.log" -Inputs $n.Path))
                $found = 'Users folder'
            }
        }
        'RecentFileCacheParser' {
            $n = Resolve-EztFirst $Evidence $Volume @('Windows\AppCompat\Programs\RecentFileCache.bcf')
            if ($n) {
                [void]$jobs.Add((New-EztJob $Tool "RecentFileCacheParser:$($Volume.Key)" 'RecentFileCacheParser' @('-f', $n.Path, '-q', '--csv', '{OUT}', '--csvf', "${p}RecentFileCache.csv") -LogName "RecentFileCacheParser$p.log" -Inputs $n.Path))
                $found = 'found'
            }
        }
        'SumECmd' {
            $n = Resolve-EztFirst $Evidence $Volume @('Windows\System32\LogFiles\Sum')
            if ($n) {
                [void]$jobs.Add((New-EztJob $Tool "SumECmd:$($Volume.Key)" 'SumECmd' @('-d', $n.Path, '--csv', '{OUT}') -SubDir $(if ($MultiVolume) { $Volume.Key } else { '' }) -LogName "SumECmd$p.log" -Inputs $n.Path))
                $found = 'found'
            }
        }
    }
    [pscustomobject]@{ Jobs = @($jobs); Found = $found }
}

function Get-EztAvailability {
    # Per tool: what was found in the evidence (for the tool list before running).
    param($Evidence, $Options, $ToolInfo)
    $res = @{}
    $multi = $Evidence.Volumes.Count -gt 1
    foreach ($t in Get-EztCatalog) {
        $f = @()
        foreach ($v in $Evidence.Volumes) {
            $r = Get-EztToolInputs -Evidence $Evidence -Volume $v -Tool $t -Options $Options -ToolInfo $ToolInfo -MultiVolume $multi
            if ($r.Found) { $f += $(if ($multi) { "$($v.Label) $($r.Found)" } else { $r.Found }) }
        }
        $res[$t.Id] = ($f -join '; ')
    }
    $res
}

function Get-EztMarkerPath([string]$Dir) { Join-Path $Dir '_eztriage.json' }

function Read-EztMarker([string]$Dir) {
    $m = Get-EztMarkerPath $Dir
    if (-not (Test-Path -LiteralPath $m)) { return $null }
    try { Get-Content -LiteralPath $m -Raw | ConvertFrom-Json } catch { $null }
}

function Get-EztJobSignature($Job) {
    # Arguments minus output paths: if these match, the earlier run did the same work.
    (@($Job.ArgList | Where-Object { $_ -ne '{OUT}' -and $_ -ne '{SRC}' }) -join '|') + '|stage:' + (@($Job.Stage | ForEach-Object { $_.Name }) -join ',')
}

function New-EztPlan {
    # Builds the full job list for the selected tools and spots earlier runs in the case folder.
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$CaseDir,
        [Parameter(Mandatory)][string[]]$ToolIds,
        [Parameter(Mandatory)]$ToolInfo,
        $Options = (Get-EztDefaultOptions)
    )
    $catalog = Get-EztCatalog
    $multi = $Evidence.Volumes.Count -gt 1
    $hiveTools = 'RECmd', 'SBECmd', 'AmcacheParser', 'AppCompatCacheParser', 'SrumECmd'
    $useStage = $Evidence.Decode -and @($ToolIds | Where-Object { $hiveTools -contains $_ }).Count
    $prep = @()
    $stages = @{}; $srum = @{}
    foreach ($v in $Evidence.Volumes) {
        $stages[$v.Key] = ''; $srum[$v.Key] = ''
        if ($useStage) {
            $stages[$v.Key] = Join-Path $CaseDir "_work\hives\$($v.Key)"
            $prep += [pscustomobject]@{ Kind = 'HiveStage'; Volume = $v; Dir = $stages[$v.Key] }
        }
        if ($ToolIds -contains 'SrumECmd' -and (Resolve-EztFirst $Evidence $v @('Windows\System32\sru\SRUDB.dat'))) {
            $srum[$v.Key] = Join-Path $CaseDir "_work\srum\$($v.Key)"
            $prep += [pscustomobject]@{ Kind = 'SrumRepair'; Volume = $v; Dir = $srum[$v.Key] }
        }
    }
    $tools = New-Object Collections.ArrayList
    foreach ($id in $ToolIds) {
        $t = $catalog | Where-Object Id -eq $id
        if (-not $t) { continue }
        $exe = $ToolInfo.Tools[$id]
        $jobs = @()
        foreach ($v in $Evidence.Volumes) {
            $hs = if ($hiveTools -contains $id) { $stages[$v.Key] } else { '' }
            $vj = @((Get-EztToolInputs -Evidence $Evidence -Volume $v -Tool $t -Options $Options -ToolInfo $ToolInfo -MultiVolume $multi -HiveStage $hs -SrumStage $srum[$v.Key]).Jobs)
            # Jobs that read prepared copies wait for that preparation step only.
            $req = @()
            if ($hs) { $req += "HiveStage:$($v.Key)" }
            if ($id -eq 'SrumECmd' -and $srum[$v.Key]) { $req += "SrumRepair:$($v.Key)" }
            foreach ($j in $vj) { $j.Requires = $req }
            $jobs += $vj
        }
        $dir = Join-Path (Join-Path $CaseDir $t.Category) $t.Id
        $marker = Read-EztMarker $dir
        $previous = @()
        foreach ($j in $jobs) {
            $j.Exe = $exe
            $j.Signature = Get-EztJobSignature $j
            if ($marker -and $marker.Jobs) {
                $old = $marker.Jobs | Where-Object { $_.Key -eq $j.Key -and $_.Status -in 'Done', 'Warnings' } | Select-Object -Last 1
                if ($old) { $previous += [pscustomobject]@{ Job = $j; Finished = $old.Finished; SameOptions = ($old.Signature -eq $j.Signature) } }
            }
        }
        [void]$tools.Add([pscustomobject]@{
                Tool = $t; Exe = $exe; Jobs = $jobs; Dir = $dir; Previous = $previous
                Missing = (-not $exe); NoInput = ($jobs.Count -eq 0); Decision = 'Run'
            })
    }
    [pscustomobject]@{
        Evidence = $Evidence; CaseDir = $CaseDir; Options = $Options; ToolInfo = $ToolInfo; Tools = @($tools); Prep = $prep
        Conflicts = @($tools | Where-Object { $_.Previous.Count -gt 0 })
    }
}

function Set-EztConflictPolicy {
    # Skip: leave earlier output alone and skip those jobs.
    # NewFolder: run the whole tool again into <Tool>_run2 (run3, ...).
    # Overwrite: clear the tool folder and run everything again.
    param($Plan, [ValidateSet('Skip', 'NewFolder', 'Overwrite')][string]$Policy, [string[]]$ToolIds)
    foreach ($tp in $Plan.Conflicts) {
        if ($ToolIds -and $ToolIds -notcontains $tp.Tool.Id) { continue }
        $tp.Decision = $Policy
    }
}

function Get-EztNextRunDir([string]$Dir) {
    $n = 2
    while (Test-Path -LiteralPath "${Dir}_run$n") { $n++ }
    "${Dir}_run$n"
}

#endregion

#region Execution

function Write-EztLog {
    param($State, [string]$Message, [string]$Level = 'INFO')
    $line = '{0}  {1,-5} {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
    if ($State) {
        $State.LogQueue.Enqueue($line)
        if ($State.LogWriter) { try { $State.LogWriter.WriteLine($line) } catch { } }
    } else { Write-Host $line }
}

function New-EztState {
    [hashtable]::Synchronized(@{
            Cancel = $false; Done = $false; Running = $false; Phase = 'Idle'; ExtractPercent = 0
            LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
            Jobs = @(); Total = 0; Completed = 0; Summary = ''; LogWriter = $null; CaseLog = ''; RunFile = ''
            Error = $null
        })
}

function Start-EztProcess($Job) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Job.Exe
    $psi.Arguments = $Job.Arguments
    $psi.WorkingDirectory = Split-Path $Job.Exe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true          # EZ Tools need a console; a hidden one is enough
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    [Diagnostics.Process]::Start($psi)
}

function Read-EztPending($Run) {
    # Drains whatever output lines are ready without blocking (ReadLineAsync + polling).
    foreach ($k in 'Out', 'Err') {
        $taskName = "${k}Task"; $reader = $Run["${k}Reader"]
        while ($true) {
            if ($null -eq $Run[$taskName]) {
                if ($Run["${k}Eof"]) { break }
                $Run[$taskName] = $reader.ReadLineAsync()
            }
            $t = $Run[$taskName]
            if (-not $t.IsCompleted) { break }
            $line = $null
            try { $line = $t.Result } catch { $line = $null }
            $Run[$taskName] = $null
            if ($null -eq $line) { $Run["${k}Eof"] = $true; break }
            $Run.Writer.WriteLine($line)
            if ($line -match 'Unhandled exception') { $Run.Fatal = $true }
            if ($line -match '(?i)\b(error|exception)\b' -and $line -notmatch '(?i)\b0 errors?\b') { $Run.Errors++; if ($Run.ErrorSample.Count -lt 3) { [void]$Run.ErrorSample.Add($line.Trim()) } }
            if ($line -match '(?i)(not found|no files found|nothing to process|found 0 )' -and $line -notmatch '(?i)administrator privileges') { $Run.NothingHint = $line.Trim() }
            if (-not $Run.FailHint -and $line -match '^(There was an error|Error processing file|Unhandled exception)') { $Run.FailHint = $line.Trim() }
        }
    }
}

function Invoke-EztPlan {
    param(
        [Parameter(Mandatory)]$Plan,
        $State = (New-EztState),
        [int]$LightSlots = 3
    )
    $State.Running = $true; $State.Done = $false; $State.Cancel = $false
    $State.CaseDir = $Plan.CaseDir
    $prepRunner = $null; $prepHandle = $null; $preps = @()
    $ev = $Plan.Evidence
    [void](New-Item -ItemType Directory -Path $Plan.CaseDir -Force)
    $State.CaseLog = Join-Path $Plan.CaseDir 'EZTriage.log'
    $sw0 = New-Object IO.StreamWriter -ArgumentList $State.CaseLog, $true, ([Text.Encoding]::UTF8)
    $sw0.AutoFlush = $true
    $State.LogWriter = [IO.TextWriter]::Synchronized($sw0)   # written from two threads
    $runStart = Get-Date
    try {
        Write-EztLog $State "=== EZ Triage $script:EngineVersion run started ==="
        Write-EztLog $State "Evidence: $($ev.Path) [$($ev.Description)]"
        Write-EztLog $State "Case folder: $($Plan.CaseDir)"

        if ($ev.IsZip -and -not $ev.Extracted) {
            $State.Phase = 'Extracting'
            Write-EztLog $State "Extracting ZIP once to $($ev.ExtractDir) (reused by later runs)"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Expand-EztZip -Evidence $ev -State $State
            $ev.Extracted = $true
            Write-EztLog $State ("Extraction finished in {0:n0} s" -f $sw.Elapsed.TotalSeconds)
        }
        # Preparation (hive repair, SRUM repair) runs on its own thread while tools that
        # do not need it are already working.
        $State.PrepDone = [hashtable]::Synchronized(@{})
        $preps = @($Plan.Prep | Where-Object { $_ })
        if ($preps.Count) {
            $prepRunner = [powershell]::Create()
            [void]$prepRunner.AddScript({
                    param($ModuleFile, $Evidence, $Preps, $State)
                    Import-Module $ModuleFile
                    foreach ($pp in $Preps) {
                        $key = "$($pp.Kind):$($pp.Volume.Key)"
                        try {
                            if ($pp.Kind -eq 'HiveStage') { Invoke-EztHiveStage -Evidence $Evidence -Volume $pp.Volume -Dir $pp.Dir -State $State }
                            if ($pp.Kind -eq 'SrumRepair') { Invoke-EztSrumRepair -Evidence $Evidence -Volume $pp.Volume -Dir $pp.Dir -State $State }
                        } catch { Write-EztLog $State "$($pp.Kind) failed: $($_.Exception.Message)" 'WARN' }
                        $State.PrepDone[$key] = $true
                    }
                }.ToString()).AddArgument($script:ModuleFile).AddArgument($ev).AddArgument($preps).AddArgument($State)
            $prepHandle = $prepRunner.BeginInvoke()
        }

        # Resolve folders and decisions into concrete jobs.
        $jobs = New-Object Collections.ArrayList
        foreach ($tp in $Plan.Tools) {
            if ($tp.Missing) { Write-EztLog $State "$($tp.Tool.Id): not installed in the EZ Tools folder. Skipped." 'WARN'; continue }
            if ($tp.NoInput) { Write-EztLog $State "$($tp.Tool.Id): no input found in the evidence. Nothing to do."; continue }
            $dir = $tp.Dir
            $skipKeys = @()
            switch ($tp.Decision) {
                'Skip' { $skipKeys = @($tp.Previous | ForEach-Object { $_.Job.Key }) }
                'NewFolder' { $dir = Get-EztNextRunDir $tp.Dir }
                'Overwrite' { if (Test-Path -LiteralPath $tp.Dir) { Remove-Item -LiteralPath $tp.Dir -Recurse -Force } }
            }
            $tp | Add-Member -NotePropertyName RunDir -NotePropertyValue $dir -Force
            foreach ($j in $tp.Jobs) {
                if ($skipKeys -contains $j.Key) {
                    $j.Status = 'Skipped'; $j.Detail = 'already processed'
                    Write-EztLog $State "$($j.Label): output from an earlier run exists. Skipped."
                    continue
                }
                $j.OutDir = if ($j.SubDir) { Join-Path $dir $j.SubDir } else { $dir }
                [void]$jobs.Add($j)
            }
        }
        $State.Jobs = @($Plan.Tools | ForEach-Object { $_.Jobs })
        $State.Total = $jobs.Count; $State.Completed = 0
        $State.Phase = 'Running'

        $heavyQ = New-Object Collections.ArrayList
        foreach ($j in ($jobs | Where-Object Heavy | Sort-Object Weight -Descending)) { [void]$heavyQ.Add($j) }
        $lightQ = New-Object Collections.ArrayList
        foreach ($j in ($jobs | Where-Object { -not $_.Heavy })) { [void]$lightQ.Add($j) }
        $running = New-Object Collections.ArrayList

        while (($heavyQ.Count + $lightQ.Count + $running.Count) -gt 0) {
            if ($State.Cancel) {
                foreach ($r in $running) { try { $r.Process.Kill() } catch { }; $r.Job.Status = 'Cancelled'; Complete-EztRun $State $r $true }
                $running.Clear()
                foreach ($q in $heavyQ, $lightQ) { foreach ($j in $q) { $j.Status = 'Cancelled' }; $q.Clear() }
                Write-EztLog $State 'Run cancelled.' 'WARN'
                break
            }
            foreach ($r in @($running)) {
                Read-EztPending $r
                if ($r.Process.HasExited -and $r.OutEof -and $r.ErrEof) {
                    Complete-EztRun $State $r $false
                    [void]$running.Remove($r)
                    $State.Completed++
                }
            }
            $heavyRunning = @($running | Where-Object { $_.Job.Heavy }).Count
            $lightRunning = $running.Count - $heavyRunning
            if ($heavyRunning -eq 0 -and $heavyQ.Count) {
                $next = Get-EztNextJob $heavyQ $running $State
                if ($next) { $r = Start-EztJob $State $next; if ($r) { [void]$running.Add($r) } else { $State.Completed++ } }
            }
            # When no heavy work is left, light tools get the spare slot.
            $slots = $LightSlots; if ($heavyQ.Count -eq 0 -and $heavyRunning -eq 0) { $slots = $LightSlots + 1 }
            while ($lightRunning -lt $slots -and $lightQ.Count) {
                $next = Get-EztNextJob $lightQ $running $State
                if (-not $next) { break }
                $r = Start-EztJob $State $next; if ($r) { [void]$running.Add($r); $lightRunning++ } else { $State.Completed++ }
            }
            # Safety net: if preparation died without flagging, report it and do not wait forever.
            if ($prepHandle -and $prepHandle.IsCompleted -and -not $State.PrepReported) {
                $State.PrepReported = $true
                foreach ($e in $prepRunner.Streams.Error) { Write-EztLog $State "Preparation error: $e" 'ERROR' }
                try { [void]$prepRunner.EndInvoke($prepHandle) } catch { Write-EztLog $State "Preparation stopped: $($_.Exception.InnerException.Message)" 'ERROR' }
                foreach ($pp in $preps) { $State.PrepDone["$($pp.Kind):$($pp.Volume.Key)"] = $true }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($prepHandle) { while (-not $prepHandle.IsCompleted) { Start-Sleep -Milliseconds 100 } }

        # Per-tool markers make reruns smart; the run file is the audit trail.
        foreach ($tp in $Plan.Tools) {
            if (-not $tp.PSObject.Properties['RunDir']) { continue }
            $ran = @($tp.Jobs | Where-Object { $_.Status -notin 'Queued', 'Skipped' })
            if (-not $ran.Count -or -not (Test-Path -LiteralPath $tp.RunDir)) { continue }
            $old = Read-EztMarker $tp.RunDir
            $list = New-Object Collections.ArrayList
            if ($old -and $old.Jobs) { foreach ($o in $old.Jobs) { if ($ran.Key -notcontains $o.Key) { [void]$list.Add($o) } } }
            foreach ($j in $ran) {
                [void]$list.Add([pscustomobject]@{ Key = $j.Key; Status = $j.Status; Signature = $j.Signature; Finished = $(if ($j.Finished) { $j.Finished.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }); Command = "$($j.Exe) $($j.Arguments)" })
            }
            [pscustomobject]@{ Tool = $tp.Tool.Id; Version = $Plan.ToolInfo.Versions[$tp.Tool.Id]; Evidence = $ev.Path; Jobs = @($list) } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-EztMarkerPath $tp.RunDir) -Encoding UTF8
        }
    } catch {
        $State.Error = $_.Exception.Message
        Write-EztLog $State "Run stopped: $($_.Exception.Message)" 'ERROR'
    } finally {
        $all = @($Plan.Tools | ForEach-Object { $_.Jobs })
        $counts = $all | Group-Object Status | ForEach-Object { "$($_.Count) $(Get-EztStatusText $_.Name)" }
        $elapsed = (Get-Date) - $runStart
        $State.Summary = if ($State.Error) { 'Stopped after {0}: {1}' -f (Format-EztDuration $elapsed), $State.Error }
        else { 'Finished in {0}: {1}' -f (Format-EztDuration $elapsed), ($counts -join ', ') }
        Write-EztLog $State $State.Summary
        try { Save-EztRunRecord $Plan $runStart $all } catch { Write-EztLog $State "Could not write run record: $($_.Exception.Message)" 'WARN' }
        if ($prepRunner) {
            if ($prepHandle) { $deadline = (Get-Date).AddSeconds(30); while (-not $prepHandle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 } }
            try { $prepRunner.Stop() } catch { }; $prepRunner.Dispose()
        }
        if ($State.LogWriter) { $State.LogWriter.Dispose(); $State.LogWriter = $null }
        $State.Phase = 'Done'; $State.Running = $false; $State.Done = $true
    }
}

function Get-EztNextJob($List, $Running, $State) {
    # First queued job whose preparation is finished and that does not clash with a
    # running one (same tool or same lock).
    foreach ($j in $List) {
        $ready = $true
        foreach ($req in @($j.Requires)) { if ($req -and -not $State.PrepDone[$req]) { $ready = $false } }
        if (-not $ready) { continue }
        $clash = $false
        foreach ($r in $Running) {
            if ($r.Job.ToolId -eq $j.ToolId -or ($j.Lock -and $r.Job.Lock -eq $j.Lock)) { $clash = $true; break }
        }
        if (-not $clash) { $List.Remove($j); return $j }
    }
    $null
}

function Get-EztStatusText([string]$Status) {
    switch ($Status) {
        'Done' { 'done' } 'Warnings' { 'done with warnings' } 'NoOutput' { 'no output' } 'Failed' { 'failed' }
        'Skipped' { 'skipped' } 'Cancelled' { 'cancelled' } 'Running' { 'running' } 'Queued' { 'queued' } default { $Status }
    }
}

function Format-EztDuration([TimeSpan]$T) {
    if ($T.TotalHours -ge 1) { return '{0}h {1}m' -f [int][Math]::Floor($T.TotalHours), $T.Minutes }
    if ($T.TotalMinutes -ge 1) { return '{0}m {1}s' -f [int][Math]::Floor($T.TotalMinutes), $T.Seconds }
    '{0:n1}s' -f $T.TotalSeconds
}

function Start-EztJob($State, $Job) {
    try {
        [void](New-Item -ItemType Directory -Path $Job.OutDir -Force)
        $src = ''
        if ($Job.Stage) {
            # Copy only the chosen event logs to a staging folder, like Automate_EvtxECmd.ps1.
            $src = Join-Path (Join-Path $State.CaseDir '_staging') ($Job.Key -replace '[:\\/]', '_')
            if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Recurse -Force }
            [void](New-Item -ItemType Directory -Path $src -Force)
            foreach ($s in $Job.Stage) { Copy-Item -LiteralPath $s.From -Destination (Join-Path $src $s.Name) -Force }
            Add-Member -InputObject $Job -NotePropertyName StageDir -NotePropertyValue $src -Force
        }
        $resolved = foreach ($a in $Job.ArgList) { if ($a -eq '{OUT}') { $Job.OutDir } elseif ($a -eq '{SRC}') { $src } else { $a } }
        $Job.Arguments = Join-EztArgs @($resolved)
        $logPath = Join-Path $Job.OutDir $Job.LogName
        $writer = New-Object IO.StreamWriter -ArgumentList $logPath, $false, ([Text.Encoding]::UTF8)
        $writer.AutoFlush = $true
        $writer.WriteLine("# EZ Triage $script:EngineVersion  $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
        $writer.WriteLine("# Command: `"$($Job.Exe)`" $($Job.Arguments)")
        $writer.WriteLine('')
        $Job.Started = Get-Date
        $Job.Status = 'Running'
        $p = Start-EztProcess $Job
        Write-EztLog $State "$($Job.Label): started$(if ($Job.Heavy) { ' (heavy)' })"
        @{
            Job = $Job; Process = $p; Writer = $writer; LogPath = $logPath
            OutReader = $p.StandardOutput; ErrReader = $p.StandardError; OutTask = $null; ErrTask = $null; OutEof = $false; ErrEof = $false
            Fatal = $false; Errors = 0; ErrorSample = New-Object Collections.ArrayList; NothingHint = ''; FailHint = ''
        }
    } catch {
        $Job.Status = 'Failed'; $Job.Detail = $_.Exception.Message; $Job.Finished = Get-Date
        Write-EztLog $State "$($Job.Label): could not start: $($_.Exception.Message)" 'ERROR'
        $null
    }
}

function Complete-EztRun($State, $Run, [bool]$Cancelled) {
    $j = $Run.Job
    $j.Finished = Get-Date
    try { $Run.Process.WaitForExit(2000) | Out-Null; $j.ExitCode = $Run.Process.ExitCode } catch { }
    # EZ Tools return 0 even when they fail, so judge by output files and log content.
    $outputs = @(Get-ChildItem -LiteralPath $j.OutDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.csv', '.json', '.html', '.xml', '.txt' -and $_.LastWriteTime -ge $j.Started.AddSeconds(-2) -and $_.FullName -ne $Run.LogPath -and $_.FullName -notlike '*\_staging\*' })
    $j.Outputs = $outputs.Count
    $dur = Format-EztDuration ($j.Finished - $j.Started)
    if ($Cancelled) { $j.Status = 'Cancelled'; $j.Detail = 'cancelled' }
    elseif ($Run.Fatal) { $j.Status = 'Failed'; $j.Detail = 'tool crashed (see log)' }
    elseif ($outputs.Count -eq 0 -and $Run.FailHint) {
        $j.Status = 'Failed'
        $j.Detail = $Run.FailHint; if ($j.Detail.Length -gt 180) { $j.Detail = $j.Detail.Substring(0, 180) + '...' }
    }
    elseif ($outputs.Count -eq 0) {
        $j.Status = 'NoOutput'
        $j.Detail = if ($Run.NothingHint) { $Run.NothingHint } else { 'no CSV written' }
    }
    elseif ($Run.Errors -gt 0) { $j.Status = 'Warnings'; $j.Detail = "$($Run.Errors) error lines" }
    else { $j.Status = 'Done'; $j.Detail = "$($outputs.Count) files" }
    $Run.Writer.WriteLine('')
    $Run.Writer.WriteLine("# Finished: $($j.Status) ($($j.Detail)) in $dur, exit code $($j.ExitCode)")
    $Run.Writer.Dispose()
    if ($j.PSObject.Properties['StageDir'] -and $j.StageDir -and (Test-Path -LiteralPath $j.StageDir)) {
        Remove-Item -LiteralPath $j.StageDir -Recurse -Force -ErrorAction SilentlyContinue
        $parent = Split-Path $j.StageDir
        if ((Split-Path $parent -Leaf) -eq '_staging' -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue }
    }
    $lvl = switch ($j.Status) { 'Done' { 'INFO' } 'Warnings' { 'WARN' } 'NoOutput' { 'WARN' } default { 'ERROR' } }
    $msg = "$($j.Label): $(Get-EztStatusText $j.Status) in $dur ($($j.Detail))"
    if ($j.Status -eq 'Warnings' -and $Run.ErrorSample.Count) { $msg += ". First: $($Run.ErrorSample[0])" }
    Write-EztLog $State $msg $lvl
}

function Save-EztRunRecord($Plan, [datetime]$Start, $Jobs) {
    $dir = Join-Path $Plan.CaseDir 'runs'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $rec = [pscustomobject]@{
        EZTriageVersion = $script:EngineVersion
        Started = $Start.ToString('o'); Finished = (Get-Date).ToString('o')
        Computer = $env:COMPUTERNAME; User = $env:USERNAME
        Evidence = [pscustomobject]@{ Path = $Plan.Evidence.Path; Type = $Plan.Evidence.Type; Description = $Plan.Evidence.Description; ExtractDir = $Plan.Evidence.ExtractDir }
        ToolsPath = $Plan.ToolInfo.Path
        Options = $Plan.Options
        Jobs = @($Jobs | ForEach-Object {
                [pscustomobject]@{
                    Tool = $_.ToolId; Key = $_.Key; Version = $Plan.ToolInfo.Versions[$_.ToolId]; Status = $_.Status; Detail = $_.Detail
                    Command = $(if ($_.Arguments) { "`"$($_.Exe)`" $($_.Arguments)" } else { '' })
                    OutDir = $_.OutDir; Started = $(if ($_.Started) { $_.Started.ToString('o') }); Finished = $(if ($_.Finished) { $_.Finished.ToString('o') }); ExitCode = $_.ExitCode; Outputs = $_.Outputs
                }
            })
    }
    $rec | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir ($Start.ToString('yyyyMMdd_HHmmss') + '.json')) -Encoding UTF8
}

function Get-EztCommandPreview {
    # Commands as they will run, with output folders filled in. Used by the GUI preview.
    param($Plan, [string]$ToolId)
    $tp = $Plan.Tools | Where-Object { $_.Tool.Id -eq $ToolId }
    if (-not $tp) { return '' }
    if ($tp.Missing) { return "$ToolId is not in the EZ Tools folder." }
    if ($tp.NoInput) { return "Nothing to parse: no input for $ToolId was found in this evidence." }
    $lines = foreach ($j in $tp.Jobs) {
        $out = if ($j.SubDir) { Join-Path $tp.Dir $j.SubDir } else { $tp.Dir }
        $src = '<case>\_staging\evtx'
        $resolved = foreach ($a in $j.ArgList) { if ($a -eq '{OUT}') { $out } elseif ($a -eq '{SRC}') { $src } else { $a } }
        $cmd = (Split-Path $j.Exe -Leaf) + ' ' + (Join-EztArgs @($resolved))
        if ($j.Stage) { "# copies $($j.Stage.Count) selected logs to a staging folder first`r`n$cmd" } else { $cmd }
    }
    ($lines -join "`r`n`r`n")
}

#endregion

# Everything is exported: background runspaces import this module and call internal steps.
Export-ModuleMember -Function *-Ezt*
