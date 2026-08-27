#Requires -Version 7.0
# PowerShell 7 profile
# Deploy to: $HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1
# Source of truth: C:\1 - Projects\PowershellProfile\Microsoft.PowerShell_profile.ps1

#region Session setup

# Allow unsigned scripts, this process only.
# Swap to 'RemoteSigned' if you want internet-sourced scripts to stay blocked.
try {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force -ErrorAction Stop
}
catch {
    Write-Warning "Execution policy not set: $($_.Exception.Message)"
}

# Log all actions carried out. Guarded: hosts that cannot transcribe would
# otherwise throw here and abort the rest of the profile.
#
# Declared before the try so they exist even when it fails. The prompt reads
# them: a session that is silently not being recorded is worth noticing while
# it is happening, not when you go looking for the log afterwards.
$PromptTranscriptPath    = $null
$PromptTranscriptRunning = $false

try {
    $LogDir = Join-Path $HOME 'Shell Logs'
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    # Timestamp leads so the folder sorts chronologically by name. The default
    # -OutputDirectory naming puts a random token before the timestamp, which
    # sorts by the random part instead. Milliseconds separate sessions started
    # in the same second; machine and user identify the logs if the folder is
    # ever synced or pooled; the host executable name gives the bare PID meaning
    # once the process is gone.
    $HostName = if ([Environment]::ProcessPath) {
        [System.IO.Path]::GetFileNameWithoutExtension([Environment]::ProcessPath)
    }
    else {
        (Get-Process -Id $PID).Name
    }

    # Usernames may contain spaces or characters that are awkward in a filename.
    $UserName = $env:USERNAME -replace '[^\w-]', '_'

    $LogName = 'PowerShell_transcript.{0}.{1}.{2}.{3}.{4}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss.fff'), $env:COMPUTERNAME, $UserName, $HostName, $PID

    $PromptTranscriptPath = Join-Path $LogDir $LogName

    Start-Transcript -Path $PromptTranscriptPath -NoClobber -IncludeInvocationHeader -ErrorAction Stop | Out-Null
    $PromptTranscriptRunning = $true

    # Said once, up front, so the path is in reach without hunting for it - and
    # so its absence is conspicuous when transcription did not start.
    Write-Host "Transcript: $PromptTranscriptPath" -ForegroundColor DarkGray

    $null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PSEngineEvent]::Exiting) -Action {
        try { Stop-Transcript } catch { }
    }
}
catch {
    $PromptTranscriptRunning = $false
    Write-Warning "Transcript not started: $($_.Exception.Message)"
}

#endregion
#region Aliases and globals

# Set-Alias, not New-Alias, so re-sourcing the profile does not error.
Set-Alias -Name 'eth' -Value Get-NetAdapter

$projects_dir = 'C:\1 - Projects'
$cases_dir    = 'K:\'

function HOME {
    Set-Location $HOME
    Get-ChildItem
}
Set-Alias ~ HOME

#endregion
#region Navigation

# Up one or more directories.
#
# Quiet on purpose, unlike HOME above: that is a destination, and worth seeing
# the contents of on arrival, while these are transit and often run two or three
# times in a row. Append 'Get-ChildItem' if you would rather they listed.
#
# Going up past the root needs no guard - the provider clamps to it rather than
# erroring - and this works in any provider that understands '..', so it is
# equally at home in HKLM: as on disk.
function up {
    [CmdletBinding()]
    param([ValidateRange(1, 32)][int] $Levels = 1)
    Set-Location -Path ((1..$Levels | ForEach-Object { '..' }) -join [System.IO.Path]::DirectorySeparatorChar)
}

# '..' and '...' are paths in PowerShell but never commands, so these add
# something rather than shadowing it. 'cd ..' is unaffected: there '..' is an
# argument, not the command being resolved.
function ..  { up 1 }
function ... { up 2 }

# Make a directory and move into it. -Force keeps it idempotent - an existing
# directory comes back instead of an error, and nothing is truncated - and the
# resolved FullName is what gets used, so a relative argument still lands right.
function mkcd {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string] $Path)
    $dir = New-Item -ItemType Directory -Path $Path -Force
    Set-Location -LiteralPath $dir.FullName
}

#endregion
#region Listing

# Both forward their arguments untouched and return real FileInfo and
# DirectoryInfo objects rather than formatted text, so 'll | Where-Object ...'
# still works. The filesystem provider already lists directories before files,
# so neither needs to sort.
#
# The only difference is -Force, which is what surfaces hidden and system
# entries - .git and .gitignore among them.
function ll { Get-ChildItem @args }
function la { Get-ChildItem -Force @args }

#endregion
#region Disks

# Stops at MB rather than KB: nothing here is ever that small, and a capacity in
# KB would be noise dressed up as precision. It has to reach down that far
# though - a Microsoft Reserved partition is 16 MB and an EFI System partition
# around 100 MB, and rounding those to GB reports them as nothing at all.
function Format-DiskSize {
    param([Parameter(Mandatory)][AllowNull()] $Bytes)

    if ($null -eq $Bytes) { return '' }
    if ($Bytes -ge 1TB)   { return '{0:0.##} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB)   { return '{0:0.#} GB'  -f ($Bytes / 1GB) }
    return '{0:0} MB' -f ($Bytes / 1MB)
}

<#
.SYNOPSIS
    Get-Disk with the detail it leaves out: sector geometry, partition style,
    and every partition with its formatting, as tables.

.DESCRIPTION
    Joins Get-Disk, Get-PhysicalDisk, Get-Partition and Get-Volume into one
    view, because the interesting facts are spread across all four: sector
    sizes and partition style come from the disk, SSD-or-spinning from the
    physical disk, offsets and partition type from the partition, and the
    filesystem, label and cluster size from the volume.

    Two tables by default - the disks, then their partitions. Partitions with
    no volume, such as EFI System or Microsoft Reserved, still appear; they
    simply have nothing to say in the formatting columns.

    Reads only, and needs no elevation.

.PARAMETER Number
    Limit to these disk numbers. All disks by default.

.PARAMETER Detailed
    Render the disks as a list of every field rather than a lean table, which
    is what you want when recording a machine's disks rather than glancing at
    them. Adds serial number, GPT guid or MBR signature, firmware and bus
    location - the things a table has to truncate.

.PARAMETER Raw
    Return objects instead of tables, each disk carrying its partitions in a
    Partitions property. For piping, sorting and exporting - 'Get-DiskInfo -Raw
    | Export-Csv' and so on.

.EXAMPLE
    disks
    Every disk, and every partition on them.

.EXAMPLE
    disks 0 -Detailed
    Everything known about disk 0, for the case notes.

.EXAMPLE
    (disks -Raw).Partitions | Where-Object FS -eq 'NTFS'
    The NTFS partitions, as objects.
#>
function Get-DiskInfo {
    [CmdletBinding()]
    param(
        # uint32 rather than int to match what Get-Disk declares. A scalar int
        # coerces on its own, but an array of them does not: the CIM binder
        # rejects int[] against a uint[] parameter outright, so 'disks 0' would
        # work while 'disks 0,1' failed.
        [Parameter(Position = 0)][uint32[]] $Number,

        [switch] $Detailed,

        [switch] $Raw
    )

    if (-not (Get-Command Get-Disk -ErrorAction Ignore)) {
        throw 'The Storage module is not available here, so disk details cannot be read.'
    }

    $disks = if ($Number) { Get-Disk -Number $Number -ErrorAction Stop }
             else         { Get-Disk -ErrorAction Stop }

    # Sorted rather than left to chance: neither Get-Disk nor Get-Partition
    # promises an order, and -Number hands them back in whatever order it was
    # given. Doing it here rather than at display time means -Raw comes out
    # ordered too, and the flat partition table inherits disk-then-partition
    # order for free.
    $disks = @($disks | Sort-Object Number)

    # Whether a disk is solid state lives on the physical disk rather than the
    # logical one, so it takes a second lookup, indexed once rather than
    # re-queried per disk.
    $physical = @{}
    foreach ($p in @(Get-PhysicalDisk -ErrorAction Ignore)) {
        $id = $p.DeviceId -as [int]
        if ($null -ne $id) { $physical[$id] = $p }
    }

    $rows = foreach ($disk in $disks) {

        $phys = $physical[[int]$disk.Number]

        $media  = ''
        $spindle = $null
        if ($phys) {
            $media   = $phys.MediaType
            $spindle = $phys.SpindleSpeed
        }

        $flags = [System.Collections.Generic.List[string]]::new()
        if ($disk.IsBoot)     { $flags.Add('boot') }
        if ($disk.IsSystem)   { $flags.Add('system') }
        if ($disk.IsReadOnly) { $flags.Add('READONLY') }
        if ($disk.IsOffline)  { $flags.Add('OFFLINE') }

        # A GPT disk carries a guid and an MBR disk a signature; never both, so
        # one column can hold whichever identifies this one.
        $identifier = if ($disk.Guid) { $disk.Guid } else { $disk.Signature }

        # Trailing dots and padding turn up in serials read over some buses.
        $serial = ''
        if ($disk.SerialNumber) { $serial = $disk.SerialNumber.Trim().TrimEnd('.') }

        # By partition number, which is what the table is keyed on. Note that
        # this is not necessarily physical order - numbers survive deletions and
        # can end up out of step with the offsets - so StartSector is where to
        # look for the layout on the platter.
        $diskPartitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Ignore | Sort-Object PartitionNumber)

        $partitions = foreach ($part in $diskPartitions) {

            $volume = $part | Get-Volume -ErrorAction Ignore

            $letter = ''
            if ($part.DriveLetter) { $letter = '{0}:' -f $part.DriveLetter }

            $label = ''; $fs = ''; $cluster = $null; $free = ''; $used = ''
            $freeBytes = $null
            if ($volume) {
                $label     = $volume.FileSystemLabel
                $fs        = $volume.FileSystem
                $cluster   = $volume.AllocationUnitSize
                $freeBytes = $volume.SizeRemaining
                $free      = Format-DiskSize $volume.SizeRemaining
                if ($volume.Size -gt 0) {
                    $used = '{0}%' -f [math]::Round((($volume.Size - $volume.SizeRemaining) / $volume.Size) * 100)
                }
            }

            $pflags = [System.Collections.Generic.List[string]]::new()
            if ($part.IsBoot)   { $pflags.Add('boot') }
            if ($part.IsActive) { $pflags.Add('active') }
            if ($part.IsHidden) { $pflags.Add('hidden') }

            # The byte offset matters, but imaging and carving tools want it in
            # sectors, so that is what the table shows; the bytes stay on the
            # object for anyone who needs them.
            $startSector = $null
            if ($disk.LogicalSectorSize -gt 0) {
                $startSector = [int64]($part.Offset / $disk.LogicalSectorSize)
            }

            [pscustomobject]@{
                Disk        = $part.DiskNumber
                Part        = $part.PartitionNumber
                Letter      = $letter
                Label       = $label
                FS          = $fs
                Cluster     = $cluster
                Size        = Format-DiskSize $part.Size
                Free        = $free
                Used        = $used
                StartSector = $startSector
                Type        = $part.Type
                Flags       = $pflags -join ' '
                OffsetBytes = $part.Offset
                SizeBytes   = $part.Size
                FreeBytes   = $freeBytes
                GptType     = $part.GptType
                MbrType     = $part.MbrType
                Guid        = $part.Guid
            }
        }

        [pscustomobject]@{
            Disk               = $disk.Number
            Name               = $disk.FriendlyName
            Media              = $media
            Bus                = $disk.BusType
            Size               = Format-DiskSize $disk.Size
            Style              = $disk.PartitionStyle
            # Logical over physical. A 512e drive reports 512/4096, and that
            # mismatch is the sort of thing that decides how it gets imaged.
            Sector             = '{0}/{1}' -f $disk.LogicalSectorSize, $disk.PhysicalSectorSize
            Parts              = $disk.NumberOfPartitions
            Health             = $disk.HealthStatus
            Flags              = $flags -join ' '
            Serial             = $serial
            Identifier         = $identifier
            Firmware           = $disk.FirmwareVersion
            Location           = $disk.Location
            SizeBytes          = $disk.Size
            LogicalSectorSize  = $disk.LogicalSectorSize
            PhysicalSectorSize = $disk.PhysicalSectorSize
            SpindleSpeed       = $spindle
            Path               = $disk.Path
            Partitions         = @($partitions)
        }
    }

    $rows = @($rows)
    if ($Raw) { return $rows }

    if ($Detailed) {
        $rows | Select-Object -Property * -ExcludeProperty Partitions | Format-List
    }
    else {
        # Serial and the rest are left out here on purpose: they are wide enough
        # to push the table past the window and get truncated. -Detailed is
        # where they belong.
        $rows | Format-Table -AutoSize Disk, Name, Media, Bus, Size, Style, Sector, Parts, Health, Flags
    }

    $allPartitions = @($rows.Partitions)
    if ($allPartitions.Count -gt 0) {
        $allPartitions | Format-Table -AutoSize Disk, Part, Letter, Label, FS, Cluster, Size, Free, Used, StartSector, Type, Flags
    }
}

Set-Alias -Name 'disks' -Value Get-DiskInfo

#endregion
#region File hashes

function md5 {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments)][string[]] $Path)
    process { Get-FileHash -Algorithm MD5 -Path $Path }
}

function sha1 {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments)][string[]] $Path)
    process { Get-FileHash -Algorithm SHA1 -Path $Path }
}

function sha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments)][string[]] $Path)
    process { Get-FileHash -Algorithm SHA256 -Path $Path }
}

#endregion
#region String hashes

function md5sum {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $InputString
    )
    process {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
            [System.BitConverter]::ToString($md5.ComputeHash($bytes)) -replace '-', ''
        }
        finally { $md5.Dispose() }
    }
}

#endregion
#region Filesystem helpers

# Open Explorer in a directory (default: current). No Invoke-Expression, so
# paths containing '$' or backticks survive intact.
function explore {
    param([string] $Path = '.')
    explorer.exe (Convert-Path -LiteralPath $Path)
}

# Create empty files, or bump LastWriteTime if they already exist.
function touch {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments)][string[]] $Path)
    process {
        foreach ($p in $Path) {
            if (Test-Path -LiteralPath $p) {
                (Get-Item -LiteralPath $p).LastWriteTime = Get-Date
            }
            else {
                New-Item -ItemType File -Path $p | Out-Null
            }
        }
    }
}

#endregion
#region Downloads

# Save a URL to disk.
function download {
    param(
        [Parameter(Mandatory, Position = 0)][string] $Url,
        [Parameter(Mandatory, Position = 1)][string] $Path
    )
    Invoke-WebRequest -Uri $Url -OutFile $Path
}

# Fetch a URL as a string. Named 'geturl' rather than 'wget': in Windows
# PowerShell 'wget' is a built-in alias that outranks functions, so a function
# by that name is silently unreachable there.
function geturl {
    param([Parameter(Mandatory, Position = 0)][string] $Url)
    (Invoke-WebRequest -Uri $Url).Content
}

#endregion
#region Prompt

# A powerline prompt: coloured segments divided by Nerd Font separators, with
# the caret on its own line so long paths never crowd what you type.
#
#   [ADMIN] [ssh] [user@machine] [path] [git] [drive] [env] [jobs] [NO LOG]
#   [exit] [took] [time]
#   > _
#
# Every segment hides itself when it has nothing to say, so a plain local shell
# in a plain directory shows only user, path and time. When the segments no
# longer fit the window they wrap onto further lines rather than being cut off.
#
# Needs a Nerd Font in the terminal (Install-NerdFont.ps1) and 24-bit ANSI
# colour; Windows Terminal gives both. Without a patched font set UseGlyphs to
# false below - the layout and colours survive, only the icons drop to ASCII.
#
# Change $PromptSettings, then run Update-PromptTheme to apply it.

$PromptSettings = [ordered]@{

    # Nerd Font glyphs. Off falls back to ASCII labels.
    UseGlyphs = $true

    # 24-bit ANSI colour. Off gives an unstyled, plain-text prompt.
    UseColour = [bool]$Host.UI.SupportsVirtualTerminal

    ShowUser    = $true
    ShowMachine = $true
    ShowGit     = $true
    ShowSsh     = $true
    ShowDrive   = $true
    ShowJobs    = $true
    ShowEnv     = $true
    ShowTime    = $true

    # Warn in the prompt itself when this session is not being transcribed.
    ShowTranscriptWarning = $true

    # A line above the prompt reporting how the last command went: whether it
    # succeeded, its exit code if not, and how long it took. It annotates the
    # command that just finished, so it sits directly under that command's
    # output rather than inside the prompt block below.
    #
    # Unlike the duration segment it has no threshold - the point is to see the
    # timing of everything, not only the slow ones.
    ShowStatusLine = $true

    # The two segments the status line makes redundant. Both off by default
    # because showing the same duration and the same exit code twice on one
    # screen is clutter, not emphasis; turn either back on if you would rather
    # have it in the prompt block, or turn ShowStatusLine off and rely on them.
    ShowDurationSegment = $false
    ShowFailedSegment   = $false

    TimeFormat = 'yyyy-MM-dd HH:mm:ss'

    # Wrap the segments onto further lines when they outgrow the window, rather
    # than letting the terminal fold them mid-block and tear the powerline.
    MultiLine = $true

    # Counting untracked files means walking the worktree. The slow-repo guard
    # below is what keeps that honest on large trees.
    ShowUntracked = $true

    # Inside a repo, show the path as repo-name plus the part below it rather
    # than the absolute path, the way Starship does. Off gives the full path.
    PathRelativeToRepo = $true

    # Emit the OSC escape sequences Windows Terminal uses for shell
    # integration. What they buy, and the terminal settings needed to act on
    # them, is documented where they are written at the end of the prompt.
    ShellIntegration = $true

    # A repo whose status call runs longer than this is remembered as slow, and
    # from then on shows only the branch name, read straight out of .git/HEAD.
    # One sluggish repo therefore costs one sluggish redraw, not every redraw.
    GitSlowThresholdMs = 750

    # Flag the branch when the last fetch is older than this. Ahead/behind is
    # only ever as truthful as the last fetch, and a stale one quietly reports
    # "up to date" about a branch that has moved on.
    FetchStaleThresholdHours = 24

    # Show the duration segment only for commands that took at least this long;
    # anything quicker is noise.
    DurationThresholdMs = 1000

    # Render the path in full up to this width, then abbreviate its parent
    # directories to single letters.
    MaxPathLength = 45

    # Warn when the current drive has less than this much room. Imaging fills
    # disks, and finding out at the end of a long copy is expensive.
    LowSpaceThresholdGB = 10

    # Reading the read-only flag off a volume needs a Win32 call, and compiling
    # the wrapper for it costs the best part of a second - once per session, the
    # first time it is needed. Removable, network and optical volumes are worth
    # that; a plain fixed disk almost never is, so it is skipped there.
    #
    # Turn this on if you use a hardware write blocker: several present the
    # blocked disk as Fixed, and its read-only state is then the single most
    # important thing on the line.
    ReadOnlyCheckAllDrives = $false

    # Environment variables worth surfacing, in the order they should appear,
    # each mapped to the label that introduces it. A value that is a rooted
    # path shows as its leaf, which is what makes VIRTUAL_ENV readable.
    #
    # Kubernetes context and Azure subscription are deliberately absent: they
    # live in config files, not environment variables, so showing them means a
    # file read and a parse on every redraw. Add them here only if you are
    # willing to pay that.
    EnvVars = [ordered]@{
        VIRTUAL_ENV            = 'venv:'
        CONDA_DEFAULT_ENV      = 'conda:'
        AWS_PROFILE            = 'aws:'
        AWS_REGION             = 'region:'
        ASPNETCORE_ENVIRONMENT = 'aspnet:'
        NODE_ENV               = 'node:'
    }

    # Segment colours, as #rrggbb foreground/background pairs. Carets take a
    # foreground only.
    Theme = [ordered]@{
        Elevated     = @{ Fg = '#FFFFFF'; Bg = '#A31515' }
        Ssh          = @{ Fg = '#FFFFFF'; Bg = '#7A3E9D' }
        User         = @{ Fg = '#FFFFFF'; Bg = '#2D5F8B' }
        Path         = @{ Fg = '#E4E4E4'; Bg = '#3A3A3A' }
        GitClean     = @{ Fg = '#1C1C1C'; Bg = '#57A64A' }
        GitDirty     = @{ Fg = '#1C1C1C'; Bg = '#D7A020' }
        GitOperation = @{ Fg = '#FFFFFF'; Bg = '#B5651D' }
        GitConflict  = @{ Fg = '#FFFFFF'; Bg = '#8B2E2E' }
        GitPartial   = @{ Fg = '#E4E4E4'; Bg = '#5F5F5F' }
        Drive        = @{ Fg = '#E4E4E4'; Bg = '#4A5568' }
        DriveAlert   = @{ Fg = '#FFFFFF'; Bg = '#9B3030' }
        Env          = @{ Fg = '#0F2E2A'; Bg = '#3FA796' }
        Jobs         = @{ Fg = '#FFFFFF'; Bg = '#556B2F' }
        NoLog        = @{ Fg = '#FFFFFF'; Bg = '#A31515' }
        Failed       = @{ Fg = '#FFFFFF'; Bg = '#A31515' }
        Duration     = @{ Fg = '#C6C6DA'; Bg = '#4B4B6A' }
        Time         = @{ Fg = '#9E9E9E'; Bg = '#2E2E2E' }
        # The status line is plain coloured text, not a filled block: it is a
        # footnote to the output above it, and a powerline bar would give it
        # more weight than the prompt it sits over.
        StatusOk     = @{ Fg = '#57A64A' }
        StatusFail   = @{ Fg = '#D14545' }
        StatusTime   = @{ Fg = '#8A8A8A' }
        CaretOk      = @{ Fg = '#57A64A' }
        CaretFail    = @{ Fg = '#D14545' }
    }
}

# None of these can change within a session, so resolve them once here rather
# than on every redraw. Doing the identity lookups in the prompt cost two
# WindowsIdentity::GetCurrent() calls per keystroke-return.
$PromptUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($PromptUserName -like '*\*') { $PromptUserName = $PromptUserName.Split('\')[-1] }

$PromptMachineName = $env:COMPUTERNAME

$PromptIsAdmin = (New-Object Security.Principal.WindowsPrincipal(
                      [Security.Principal.WindowsIdentity]::GetCurrent())
                 ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

# Any of the three means this shell is being driven over SSH; OpenSSH sets
# SSH_TTY only for interactive sessions, so the other two are the reliable ones.
$script:PromptIsSsh = [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY)

# An absent git turns the segment off rather than throwing a
# CommandNotFoundException on every redraw.
$script:PromptHasGit = [bool](Get-Command git -CommandType Application -ErrorAction Ignore)

# Repo lookups walk the filesystem and 'git status' spawns a process, both of
# them per-keystroke-return costs. Directory -> repo root, where $null means
# "not in a repo"; run Reset-PromptCache after a 'git init' or a 'git clone'
# into somewhere the prompt has already been.
$script:PromptGitRoots      = @{}
$script:PromptSlowRepos     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:PromptDrives        = @{}
$script:PromptLastHistoryId = -1

# Tracked separately from the history id: the first draw of a session has no
# previous command to close, and inferring that from the history id instead
# swallowed the mark for the session's very first command.
$script:PromptDrawn = $false

# Whatever last stopped the prompt from rendering, kept for inspection instead
# of being reprinted on every redraw. See the catch at the end of prompt.
$PromptLastError = $null

function Reset-PromptCache {
    [CmdletBinding()]
    param()
    $script:PromptGitRoots.Clear()
    $script:PromptSlowRepos.Clear()
    $script:PromptDrives.Clear()
}

# '#rrggbb' -> 'r;g;b', the tail of an ANSI colour sequence.
function ConvertTo-PromptRgb {
    param([Parameter(Mandatory)][string] $Hex)
    $h = $Hex.TrimStart('#')
    '{0};{1};{2}' -f [Convert]::ToInt32($h.Substring(0, 2), 16),
                     [Convert]::ToInt32($h.Substring(2, 2), 16),
                     [Convert]::ToInt32($h.Substring(4, 2), 16)
}

# Rebuild the glyph set and the escape sequences from $PromptSettings. Colours
# do not change between redraws, so parsing hex here keeps it out of the prompt.
function Update-PromptTheme {
    [CmdletBinding()]
    param()

    $script:PromptGlyphs = if ($PromptSettings.UseGlyphs) {
        @{
            Separator  = "`u{e0b0}"   # solid right-pointing powerline arrow
            Elevated   = "`u{f0e7}"   # bolt
            Ssh        = "`u{f233}"   # server
            User       = "`u{f007} "  # person
            Folder     = "`u{f07b} "  # folder
            Branch     = "`u{e0a0} "  # branch
            Detached   = "`u{27a6} "  # hooked arrow, for a detached HEAD
            NoUpstream = "`u{f127}"   # broken chain, for a branch never pushed
            Fetch      = "`u{f021}"   # refresh, for a stale fetch
            DriveFixed = "`u{f0a0}"   # hard disk
            DriveUsb   = "`u{f287}"   # usb, for removable and optical media
            DriveNet   = "`u{f0e8}"   # sitemap, for network drives
            ReadOnly   = "`u{f023}"   # padlock
            LowSpace   = "`u{f071}"   # warning triangle
            NoLog      = "`u{f05e}"   # circle-slash, for "not being recorded"
            Env        = "`u{f1b2} "  # cube
            Jobs       = "`u{f013} "  # gear
            Clock      = "`u{f017} "  # clock, for how long the last command took
            Calendar   = "`u{f073} "  # calendar, for the wall clock
            Failed     = "`u{f00d} "  # cross
            StatusOk   = "`u{f00c}"   # tick, for the status line above the prompt
            StatusFail = "`u{f00d}"   # cross
            Ahead      = "`u{21e1}"
            Behind     = "`u{21e3}"
            Caret      = "`u{276f}"
        }
    }
    else {
        @{
            Separator  = ' '
            Elevated   = 'ADMIN'
            Ssh        = 'ssh'
            User       = 'USER:'
            Folder     = ''
            Branch     = 'git:'
            Detached   = 'at '
            NoUpstream = 'no-upstream'
            Fetch      = 'fetched '
            DriveFixed = 'disk'
            DriveUsb   = 'removable'
            DriveNet   = 'network'
            ReadOnly   = 'read-only'
            LowSpace   = 'LOW'
            NoLog      = 'NO LOG'
            Env        = 'env:'
            Jobs       = 'jobs:'
            Clock      = 'took '
            Calendar   = ''
            Failed     = 'exit '
            StatusOk   = 'OK'
            StatusFail = 'FAIL'
            Ahead      = '+'
            Behind     = '-'
            Caret      = '>'
        }
    }

    $script:PromptStyles = @{}
    foreach ($name in $PromptSettings.Theme.Keys) {
        $pair  = $PromptSettings.Theme[$name]
        $style = @{}
        if ($pair.Fg) {
            $fg = ConvertTo-PromptRgb $pair.Fg
            $style.Fg = "`e[38;2;${fg}m"
        }
        if ($pair.Bg) {
            $bg = ConvertTo-PromptRgb $pair.Bg
            $style.Bg = "`e[48;2;${bg}m"
            # The separator is drawn in the segment's background colour against
            # the next segment's, which is what welds the two blocks together.
            $style.BgAsFg = "`e[38;2;${bg}m"
        }
        $style.Set = "$($style.Fg)$($style.Bg)"
        $script:PromptStyles[$name] = $style
    }

    # On a parse error PSReadLine repaints the tail of the prompt in its error
    # colour, working out how much to repaint by analysing the prompt function -
    # an analysis the docs admit is not always right, and a prompt as full of
    # escape sequences as this one is exactly what confuses it. Telling it
    # outright avoids the guess. It measures the value in visible cells rather
    # than matching the string, so the caret alone is the right answer even
    # though the real prompt wraps it in colour.
    if (Get-Module -Name PSReadLine) {
        try { Set-PSReadLineOption -PromptText "$($script:PromptGlyphs.Caret) " -ErrorAction Stop }
        catch { Write-Warning "PSReadLine PromptText not set: $($_.Exception.Message)" }
    }
}

Update-PromptTheme

# The .git entry is a directory in a normal clone and a 'gitdir:' pointer file
# in a worktree or a submodule.
function Get-PromptGitDir {
    param([Parameter(Mandatory)][string] $Root)

    $dot = Join-Path $Root '.git'
    if (Test-Path -LiteralPath $dot -PathType Container) { return $dot }
    if (Test-Path -LiteralPath $dot -PathType Leaf) {
        $line = Get-Content -LiteralPath $dot -TotalCount 1 -ErrorAction Ignore
        if ($line -match '^gitdir:\s*(.+)$') {
            $target = $Matches[1].Trim()
            if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $Root $target }
            return $target
        }
    }
    return $null
}

# Walk up looking for a .git entry. Pure filesystem, so no process spawn, and
# the answer is cached per directory.
function Get-PromptGitRoot {
    param([Parameter(Mandatory)][string] $Path)

    if ($script:PromptGitRoots.ContainsKey($Path)) { return $script:PromptGitRoots[$Path] }

    $root = $null
    $dir  = $Path
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $root = $dir; break }
        $parent = Split-Path -Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    $script:PromptGitRoots[$Path] = $root
    return $root
}

# Which multi-step operation, if any, the repo is stopped in the middle of.
# Every one of these leaves a marker in the git directory, so this is a handful
# of Test-Path calls against a directory already resolved for the stash count -
# no extra process, unlike asking git itself.
function Get-PromptGitOperation {
    param([Parameter(Mandatory)][string] $GitDir)

    # An interactive rebase uses rebase-merge; 'rebase --apply' and 'git am'
    # share rebase-apply, told apart by the 'applying' file that only am
    # leaves. Both keep the step counters in msgnum and end.
    foreach ($name in 'rebase-merge', 'rebase-apply') {
        $dir = Join-Path $GitDir $name
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

        $label = if (Test-Path -LiteralPath (Join-Path $dir 'applying')) { 'AM' } else { 'REBASE' }
        $step  = Get-Content -LiteralPath (Join-Path $dir 'msgnum') -TotalCount 1 -ErrorAction Ignore
        $total = Get-Content -LiteralPath (Join-Path $dir 'end')    -TotalCount 1 -ErrorAction Ignore
        if ($step -and $total) { return '{0} {1}/{2}' -f $label, $step.Trim(), $total.Trim() }
        return $label
    }

    if (Test-Path -LiteralPath (Join-Path $GitDir 'MERGE_HEAD'))       { return 'MERGE' }
    if (Test-Path -LiteralPath (Join-Path $GitDir 'CHERRY_PICK_HEAD')) { return 'CHERRY-PICK' }
    if (Test-Path -LiteralPath (Join-Path $GitDir 'REVERT_HEAD'))      { return 'REVERT' }
    if (Test-Path -LiteralPath (Join-Path $GitDir 'BISECT_LOG'))       { return 'BISECT' }
    return $null
}

# Hours since the last fetch, from the timestamp git leaves on FETCH_HEAD.
# One file stat, and the only honest way to know whether ahead/behind means
# anything. $null when the repo has never fetched.
function Get-PromptFetchAge {
    param([Parameter(Mandatory)][string] $GitDir)

    $fetchHead = Join-Path $GitDir 'FETCH_HEAD'
    if (-not (Test-Path -LiteralPath $fetchHead)) { return $null }

    $written = (Get-Item -LiteralPath $fetchHead -ErrorAction Ignore).LastWriteTime
    if (-not $written) { return $null }
    return ((Get-Date) - $written).TotalHours
}

# Branch name only, straight out of HEAD. Used for repos that proved too slow to
# call 'git status' on; costs one small file read.
function Get-PromptGitHead {
    param([Parameter(Mandatory)][string] $Root)

    $gitDir = Get-PromptGitDir $Root
    if (-not $gitDir) { return $null }

    $line = Get-Content -LiteralPath (Join-Path $gitDir 'HEAD') -TotalCount 1 -ErrorAction Ignore
    if (-not $line) { return $null }

    $info = if ($line -match '^ref:\s*refs/heads/(.+)$') {
        @{ Branch = $Matches[1].Trim(); Detached = $false; Partial = $true }
    }
    else {
        @{ Branch = $line.Substring(0, [Math]::Min(7, $line.Length)); Detached = $true; Partial = $true }
    }

    # Cheap enough to keep even on a repo we gave up calling git on, and it is
    # the one piece of state you most want to be reminded of.
    $info.Operation = Get-PromptGitOperation $gitDir

    # Deliberately not set here: without 'git status' we cannot know whether an
    # upstream exists, and a fetch age with nothing to compare against would
    # only invite the wrong conclusion.
    $info.HasUpstream = $true
    $info.FetchAge    = $null
    return $info
}

# One 'git status' call covers branch, ahead/behind and every file state.
# --no-optional-locks stops a mere redraw from rewriting the index.
function Get-PromptGitInfo {
    param([Parameter(Mandatory)][string] $Root)

    if ($script:PromptSlowRepos.Contains($Root)) { return Get-PromptGitHead $Root }

    $untracked = if ($PromptSettings.ShowUntracked) { 'normal' } else { 'no' }
    $watch     = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $lines = & git --no-optional-locks status --porcelain=v2 --branch --untracked-files=$untracked 2>$null
    }
    catch { return $null }
    $watch.Stop()

    if ($LASTEXITCODE -ne 0) { return $null }
    if ($watch.ElapsedMilliseconds -gt $PromptSettings.GitSlowThresholdMs) {
        [void]$script:PromptSlowRepos.Add($Root)
    }

    $info = @{
        Branch = ''; Oid = ''; Detached = $false; Partial = $false; Operation = $null
        HasUpstream = $false; FetchAge = $null
        Ahead  = 0;  Behind = 0
        Staged = 0;  Unstaged = 0; Untracked = 0; Conflicts = 0; Stashed = 0
    }

    # Switching on the first character rather than regex-matching every line
    # keeps a repo with thousands of changed files off the critical path.
    foreach ($line in $lines) {
        if ($line.Length -lt 2) { continue }
        switch ($line[0]) {
            { $_ -eq '1' -or $_ -eq '2' } {
                $xy = $line.Substring(2, 2)
                if ($xy[0] -ne '.') { $info.Staged++ }
                if ($xy[1] -ne '.') { $info.Unstaged++ }
            }
            'u' { $info.Conflicts++ }
            '?' { $info.Untracked++ }
            '#' {
                if ($line -match '^# branch\.head (.+)$') {
                    if ($Matches[1] -eq '(detached)') { $info.Detached = $true } else { $info.Branch = $Matches[1] }
                }
                elseif ($line -match '^# branch\.oid (.+)$') {
                    $info.Oid = $Matches[1]
                }
                # Emitted only when the branch actually tracks something, which
                # is exactly what makes its absence worth reporting.
                elseif ($line -match '^# branch\.upstream (.+)$') {
                    $info.HasUpstream = $true
                }
                elseif ($line -match '^# branch\.ab \+(\d+) -(\d+)') {
                    $info.Ahead = [int]$Matches[1]; $info.Behind = [int]$Matches[2]
                }
            }
        }
    }

    if ($info.Detached -and $info.Oid) {
        $info.Branch = $info.Oid.Substring(0, [Math]::Min(7, $info.Oid.Length))
    }

    $gitDir = Get-PromptGitDir $Root
    if ($gitDir) {
        $info.Operation = Get-PromptGitOperation $gitDir

        # Only meaningful against an upstream; on a purely local branch there is
        # nothing the fetch would have been comparing to.
        if ($info.HasUpstream) { $info.FetchAge = Get-PromptFetchAge $gitDir }

        # The reflog is the cheap way to count stashes: 'git stash list' would
        # be a second process per redraw.
        $stashLog = Join-Path $gitDir 'logs\refs\stash'
        if (Test-Path -LiteralPath $stashLog) {
            $info.Stashed = @(Get-Content -LiteralPath $stashLog -ErrorAction Ignore).Count
        }
    }

    return $info
}

# True when the volume is mounted read-only. There is no managed API for this,
# so it goes through Win32 - and compiling that wrapper is slow enough that it
# is done on first use rather than at profile load, and only for the drives
# $PromptSettings says are worth asking about.
function Test-PromptDriveReadOnly {
    param([Parameter(Mandatory)][string] $Root)

    if (-not ('PromptWin32Volume' -as [type])) {
        Add-Type -Namespace Prompt -Name Win32Volume -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool GetVolumeInformationW(
    string rootPathName,
    System.Text.StringBuilder volumeNameBuffer, int volumeNameSize,
    out uint volumeSerialNumber, out uint maximumComponentLength,
    out uint fileSystemFlags,
    System.Text.StringBuilder fileSystemNameBuffer, int fileSystemNameSize);
'@ -ErrorAction Stop
    }

    $name = [System.Text.StringBuilder]::new(261)
    $fs   = [System.Text.StringBuilder]::new(261)
    [uint32]$serial = 0
    [uint32]$maxLen = 0
    [uint32]$flags  = 0

    if (-not [Prompt.Win32Volume]::GetVolumeInformationW($Root, $name, $name.Capacity, [ref]$serial, [ref]$maxLen, [ref]$flags, $fs, $fs.Capacity)) {
        return $false
    }

    # FILE_READ_ONLY_VOLUME
    return [bool]($flags -band 0x00080000)
}

# What kind of volume the current directory sits on, how much room is left, and
# whether it is write protected. Cached per drive: none of it changes often, and
# the read-only probe in particular is not something to repeat per keystroke.
function Get-PromptDriveInfo {
    param([Parameter(Mandatory)][string] $Path)

    $root = [System.IO.Path]::GetPathRoot($Path)
    if (-not $root) { return $null }

    if ($script:PromptDrives.ContainsKey($root)) { return $script:PromptDrives[$root] }

    $result = $null
    try {
        $drive = [System.IO.DriveInfo]::new($root)
        if ($drive.IsReady) {
            $checkReadOnly = $PromptSettings.ReadOnlyCheckAllDrives -or
                             $drive.DriveType -in @([System.IO.DriveType]::Removable,
                                                    [System.IO.DriveType]::Network,
                                                    [System.IO.DriveType]::CDRom)

            $readOnly = $false
            if ($checkReadOnly) {
                try { $readOnly = Test-PromptDriveReadOnly -Root $root }
                catch { $readOnly = $false }
            }

            $result = @{
                Root      = $root.TrimEnd('\', '/')
                Type      = $drive.DriveType
                FreeBytes = $drive.AvailableFreeSpace
                ReadOnly  = $readOnly
            }
        }
    }
    catch {
        # An unavailable or exotic volume simply gets no segment.
        $result = $null
    }

    $script:PromptDrives[$root] = $result
    return $result
}

# Cut a path down to MaxLength by abbreviating its parent directories to a
# single letter each, keeping the root and the last two components whole so the
# directory you are actually in stays readable.
function Compress-PromptPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $MaxLength = 45
    )

    if ($Path.Length -le $MaxLength) { return $Path }

    $sep   = [System.IO.Path]::DirectorySeparatorChar
    $parts = $Path -split '[\\/]'

    # How much of the front is the root and must stay whole. A UNC path splits
    # to two leading empty strings, so its '\\server\share' spans four parts;
    # abbreviating those to single letters would leave it unrecognisable.
    $headCount = if ($Path.StartsWith('\\')) { 4 } else { 1 }

    # Nothing between the root and the last two components to abbreviate.
    if ($parts.Count -lt $headCount + 3) { return $Path }

    $head = $parts[0..($headCount - 1)] -join $sep
    $tail = $parts[($parts.Count - 2)..($parts.Count - 1)]
    $mid  = foreach ($p in $parts[$headCount..($parts.Count - 3)]) {
        if ($p.Length -gt 0) { $p.Substring(0, 1) } else { $p }
    }

    $short = (@($head) + @($mid) + @($tail)) -join $sep
    if ($short.Length -le $MaxLength) { return $short }

    # Still too wide even abbreviated: drop the middle entirely.
    return (@($head, "`u{2026}") + @($tail)) -join $sep
}

# An absolute path, with home as '~'.
function Format-PromptPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Path,
        [int] $MaxLength = 45
    )

    if ([string]::IsNullOrEmpty($Path)) { return $Path }

    if ($Path.Equals($HOME, [StringComparison]::OrdinalIgnoreCase)) { return '~' }
    if ($Path.StartsWith($HOME + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $Path = '~' + $Path.Substring($HOME.Length)
    }

    return Compress-PromptPath -Path $Path -MaxLength $MaxLength
}

# The path as the repo name plus whatever sits below it, so a deep working
# directory reads as 'PowershellProfile\src\thing' rather than burning half the
# line on where the repo happens to live.
function Format-PromptRepoPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [int] $MaxLength = 45
    )

    $repo = Split-Path -Path $Root -Leaf
    if ($Path.Length -le $Root.Length) { return $repo }

    $relative = $Path.Substring($Root.Length).TrimStart('\', '/')
    return Compress-PromptPath -Path ('{0}{1}{2}' -f $repo, [System.IO.Path]::DirectorySeparatorChar, $relative) -MaxLength $MaxLength
}

function Format-PromptDuration {
    param([Parameter(Mandatory)][double] $Seconds)

    if ($Seconds -lt 60) { return '{0:0.##}s' -f $Seconds }

    # Hours must be handled explicitly: TimeSpan's "mm\:ss" wraps at 60 minutes,
    # so a 1 hr 2 min command used to render as "02 min 05 sec".
    $ts = [timespan]::FromSeconds($Seconds)
    if ($ts.TotalHours -lt 1) { return '{0}m {1}s' -f $ts.Minutes, $ts.Seconds }
    return '{0}h {1}m {2}s' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
}

# Coarse on purpose: the point is "how stale", not the exact interval.
function Format-PromptAge {
    param([Parameter(Mandatory)][double] $Hours)

    if ($Hours -lt 48)      { return '{0}h' -f [int]$Hours }
    if ($Hours -lt 24 * 14) { return '{0}d' -f [int]($Hours / 24) }
    return '{0}w' -f [int]($Hours / (24 * 7))
}

function Format-PromptBytes {
    param([Parameter(Mandatory)][double] $Bytes)

    if ($Bytes -ge 1TB) { return '{0:0.#} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:0.#} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:0} MB'   -f ($Bytes / 1MB) }
    return '{0:0} KB' -f ($Bytes / 1KB)
}

# Whichever of the watched environment variables are set, in configured order.
# Reading environment variables is free, which is the whole reason this segment
# is limited to them.
function Get-PromptEnvContext {
    [CmdletBinding()]
    param()

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $PromptSettings.EnvVars.Keys) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        # VIRTUAL_ENV and friends hold a full path; the leaf is the bit that
        # identifies the environment and the rest is noise.
        if ([System.IO.Path]::IsPathRooted($value)) { $value = Split-Path -Path $value -Leaf }

        $parts.Add(('{0}{1}' -f $PromptSettings.EnvVars[$name], $value))
    }

    if ($parts.Count -eq 0) { return $null }
    return $parts -join ' '
}

# How the last command ended, decided once and used three ways: the status line
# above the prompt, the optional failed segment, and the exit status handed to
# the terminal in an OSC 133;D mark.
#
# $? decides whether anything failed at all. $LASTEXITCODE lingers from the last
# native command, so on its own it would keep flagging a failure long after a
# successful cmdlet.
#
# Code is deliberately null for a PowerShell-level failure. A cmdlet error
# carries no exit code, and $LASTEXITCODE at that moment still holds whatever
# the last native command left there - reporting that is worse than reporting
# nothing, because a stale number looks like a real answer. The error's
# HistoryId matching the current history entry is what identifies the failure as
# PowerShell's own, and is the same check Microsoft's shell-integration sample
# uses. MarkStatus still has to be a number for the terminal, so -1 says "this
# failed" there without inventing a code.
function Get-PromptCommandResult {
    [CmdletBinding()]
    param(
        [bool] $Succeeded,
        [AllowNull()] $LastExit,
        [AllowNull()] $LastError,
        [AllowNull()] $LastHistory
    )

    if ($Succeeded) {
        return [pscustomobject]@{ Failed = $false; Code = $null; MarkStatus = 0 }
    }

    $isPowerShellError = [bool]($LastError -and $LastHistory -and
                                $LastError.InvocationInfo.HistoryId -eq $LastHistory.Id)

    if ($isPowerShellError) {
        return [pscustomobject]@{ Failed = $true; Code = $null; MarkStatus = -1 }
    }

    $code = if ($LastExit) { $LastExit } else { $null }
    $mark = if ($null -ne $code) { $code } else { 1 }
    return [pscustomobject]@{ Failed = $true; Code = $code; MarkStatus = $mark }
}

# How wide the prompt may be before it wraps. Zero means "do not wrap", which is
# also what a redirected or headless host gets, since there is no width to ask.
function Get-PromptWidth {
    [CmdletBinding()]
    param()

    if (-not $PromptSettings.MultiLine) { return 0 }

    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -gt 20) { return $width }
    }
    catch { }
    return 0
}

# Join the segments into powerline strips, one per line. Each divider is drawn
# in the outgoing segment's background against the incoming one's, which is what
# welds the blocks together; the last on a line is drawn against the terminal's
# own background.
#
# Segment text is plain - all the colour lives in the styles - so its length is
# its width on screen, which is what makes the wrapping arithmetic honest.
function Format-PromptLine {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList] $Segments)

    if ($Segments.Count -eq 0) { return '' }

    $separator = $script:PromptGlyphs.Separator
    $reset     = "`e[0m"
    $width     = Get-PromptWidth

    # Pack the segments into rows that fit. Each costs its own text plus the one
    # separator cell that follows it. Done before rendering so that the plain,
    # uncoloured prompt wraps on the same terms as the decorated one.
    $rows    = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $used    = 0

    foreach ($segment in $Segments) {
        $cost = $segment.Text.Length + 1
        if ($width -gt 0 -and $current.Count -gt 0 -and ($used + $cost) -gt $width) {
            $rows.Add($current)
            $current = [System.Collections.Generic.List[object]]::new()
            $used    = 0
        }
        $current.Add($segment)
        $used += $cost
    }
    if ($current.Count -gt 0) { $rows.Add($current) }

    if (-not $PromptSettings.UseColour) {
        $plain = foreach ($row in $rows) { (($row | ForEach-Object { $_.Text.Trim() }) -join ' ') }
        return ($plain -join "`n")
    }

    $lines = foreach ($row in $rows) {
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $row.Count; $i++) {
            $style = $script:PromptStyles[$row[$i].Style]
            [void]$sb.Append($style.Set).Append($row[$i].Text)

            if ($i -lt $row.Count - 1) {
                $next = $script:PromptStyles[$row[$i + 1].Style]
                [void]$sb.Append($style.BgAsFg).Append($next.Bg).Append($separator)
            }
            else {
                [void]$sb.Append($reset).Append($style.BgAsFg).Append($separator).Append($reset)
            }
        }
        $sb.ToString()
    }

    return ($lines -join "`n")
}

function prompt {

    # $?, $LASTEXITCODE and $Error[0] all describe the command just finished and
    # are clobbered by the first statement in here, so capture them before
    # anything else runs. $Error matters as much as the other two: it is how a
    # PowerShell-level failure is told apart from a native non-zero exit.
    $succeeded = $?
    $lastExit  = $global:LASTEXITCODE
    $lastError = $global:Error[0]

    try {
        $glyphs   = $script:PromptGlyphs
        $segments = [System.Collections.Generic.List[hashtable]]::new()

        # Whether a command actually ran since the last redraw. Pressing Enter on
        # an empty line, or Ctrl+C, leaves history untouched; both the duration
        # segment and the terminal's end-of-command mark need to know that.
        $lastHistory     = Get-History -Count 1
        $isFirstPrompt   = -not $script:PromptDrawn
        $historyAdvanced = $lastHistory -and $lastHistory.Id -ne $script:PromptLastHistoryId

        # Resolved once: the status line and the duration segment both want it,
        # and it is the same command either way.
        $elapsedSeconds = $null
        if ($historyAdvanced) {
            $elapsedSeconds = ($lastHistory.EndExecutionTime - $lastHistory.StartExecutionTime).TotalSeconds
        }

        $result      = Get-PromptCommandResult -Succeeded $succeeded -LastExit $lastExit -LastError $lastError -LastHistory $lastHistory
        $failed      = $result.Failed
        $failureCode = $result.Code

        $location     = $ExecutionContext.SessionState.Path.CurrentLocation
        $isFileSystem = $location.Provider.Name -eq 'FileSystem'

        # The repo has to be resolved before the path, because inside one the
        # path is rendered relative to it.
        $gitRoot = $null
        $git     = $null
        if ($PromptSettings.ShowGit -and $script:PromptHasGit -and $isFileSystem) {
            $gitRoot = Get-PromptGitRoot $location.ProviderPath
            if ($gitRoot) { $git = Get-PromptGitInfo $gitRoot }
        }

        $shortPath = if (-not $isFileSystem) {
            $location.Path
        }
        elseif ($gitRoot -and $PromptSettings.PathRelativeToRepo) {
            Format-PromptRepoPath -Path $location.ProviderPath -Root $gitRoot -MaxLength $PromptSettings.MaxPathLength
        }
        else {
            Format-PromptPath -Path $location.ProviderPath -MaxLength $PromptSettings.MaxPathLength
        }

        if ($PromptIsAdmin) {
            $segments.Add(@{ Style = 'Elevated'; Text = (' {0} ' -f $glyphs.Elevated.Trim()) })
        }

        # Just a marker now: the machine name lives in the user segment, and
        # saying it twice on one line helps nobody.
        if ($PromptSettings.ShowSsh -and $script:PromptIsSsh) {
            $segments.Add(@{ Style = 'Ssh'; Text = (' {0} ' -f $glyphs.Ssh.Trim()) })
        }

        if ($PromptSettings.ShowUser) {
            $who = if ($PromptSettings.ShowMachine) { '{0}@{1}' -f $PromptUserName, $PromptMachineName }
                   else                             { $PromptUserName }
            $segments.Add(@{ Style = 'User'; Text = (' {0}{1} ' -f $glyphs.User, $who) })
        }

        $segments.Add(@{ Style = 'Path'; Text = (' {0}{1} ' -f $glyphs.Folder, $shortPath) })

        if ($git) {
            $label = if ($git.Detached) { '{0}{1}' -f $glyphs.Detached, $git.Branch }
                     else               { '{0}{1}' -f $glyphs.Branch,   $git.Branch }

            $marks = [System.Collections.Generic.List[string]]::new()

            # A branch with no upstream shows no ahead/behind at all, which
            # otherwise looks identical to being perfectly in sync.
            if (-not $git.Detached -and -not $git.HasUpstream) {
                $marks.Add($glyphs.NoUpstream)
            }

            if ($git.Ahead)     { $marks.Add(('{0}{1}' -f $glyphs.Ahead,  $git.Ahead)) }
            if ($git.Behind)    { $marks.Add(('{0}{1}' -f $glyphs.Behind, $git.Behind)) }
            if ($git.Staged)    { $marks.Add('+{0}' -f $git.Staged) }
            if ($git.Unstaged)  { $marks.Add('!{0}' -f $git.Unstaged) }
            if ($git.Untracked) { $marks.Add('?{0}' -f $git.Untracked) }
            if ($git.Conflicts) { $marks.Add('~{0}' -f $git.Conflicts) }
            if ($git.Stashed)   { $marks.Add('*{0}' -f $git.Stashed) }

            if ($null -ne $git.FetchAge -and $git.FetchAge -ge $PromptSettings.FetchStaleThresholdHours) {
                $marks.Add(('{0}{1}' -f $glyphs.Fetch, (Format-PromptAge $git.FetchAge)))
            }

            # The operation reads as part of the branch, the way git itself says
            # "interactive rebase in progress", so it goes next to the name.
            if ($git.Operation) { $label = '{0}|{1}' -f $label, $git.Operation }

            # Conflicts outrank a running operation: mid-rebase is context, but a
            # conflict is the thing actually blocking you. Grey says "branch
            # only, state unknown" for a repo whose status call was skipped, and
            # must not read as a clean worktree.
            $gitStyle = if     ($git.Partial)       { 'GitPartial' }
                        elseif ($git.Conflicts)     { 'GitConflict' }
                        elseif ($git.Operation)     { 'GitOperation' }
                        elseif ($marks.Count -gt 0) { 'GitDirty' }
                        else                        { 'GitClean' }

            $segments.Add(@{ Style = $gitStyle; Text = (' {0} ' -f ((@($label) + $marks) -join ' ')) })
        }

        # Shown only when there is something to say about the volume: a local
        # fixed disk with room on it is the unremarkable case and stays quiet.
        if ($PromptSettings.ShowDrive -and $isFileSystem) {
            $drive = Get-PromptDriveInfo -Path $location.ProviderPath
            if ($drive) {
                $lowSpace  = $drive.FreeBytes -lt ($PromptSettings.LowSpaceThresholdGB * 1GB)
                $notFixed  = $drive.Type -ne [System.IO.DriveType]::Fixed

                if ($lowSpace -or $drive.ReadOnly -or $notFixed) {
                    $typeGlyph = switch ($drive.Type) {
                        ([System.IO.DriveType]::Removable) { $glyphs.DriveUsb }
                        ([System.IO.DriveType]::CDRom)     { $glyphs.DriveUsb }
                        ([System.IO.DriveType]::Network)   { $glyphs.DriveNet }
                        default                            { $glyphs.DriveFixed }
                    }

                    $parts = [System.Collections.Generic.List[string]]::new()
                    $parts.Add(('{0} {1}' -f $typeGlyph, $drive.Root))
                    if ($drive.ReadOnly) { $parts.Add($glyphs.ReadOnly) }
                    if ($lowSpace)       { $parts.Add(('{0} {1}' -f $glyphs.LowSpace, (Format-PromptBytes $drive.FreeBytes))) }

                    # Read-only is information - often the point, with a write
                    # blocker. Running out of room is the only actual alarm.
                    $driveStyle = if ($lowSpace) { 'DriveAlert' } else { 'Drive' }
                    $segments.Add(@{ Style = $driveStyle; Text = (' {0} ' -f ($parts -join ' ')) })
                }
            }
        }

        if ($PromptSettings.ShowEnv) {
            $envContext = Get-PromptEnvContext
            if ($envContext) { $segments.Add(@{ Style = 'Env'; Text = (' {0}{1} ' -f $glyphs.Env, $envContext) }) }
        }

        if ($PromptSettings.ShowJobs) {
            $jobs = @(Get-Job -State Running -ErrorAction Ignore).Count
            if ($jobs -gt 0) { $segments.Add(@{ Style = 'Jobs'; Text = (' {0}{1} ' -f $glyphs.Jobs, $jobs) }) }
        }

        # The startup warning scrolls away in seconds; this does not. Worth the
        # space, because the alternative is finding out afterwards that a whole
        # session went unrecorded.
        if ($PromptSettings.ShowTranscriptWarning -and -not $PromptTranscriptRunning) {
            $segments.Add(@{ Style = 'NoLog'; Text = (' {0} ' -f $glyphs.NoLog.Trim()) })
        }

        # Both of these are off by default, superseded by the status line above
        # the prompt; they remain for anyone who would rather have the facts in
        # the prompt block itself.
        if ($PromptSettings.ShowFailedSegment -and $failed) {
            $shown = if ($null -ne $failureCode) { $failureCode } else { '' }
            $segments.Add(@{ Style = 'Failed'; Text = (' {0}{1} ' -f $glyphs.Failed, $shown).Replace('  ', ' ') })
        }

        if ($PromptSettings.ShowDurationSegment -and $null -ne $elapsedSeconds -and
            ($elapsedSeconds * 1000) -ge $PromptSettings.DurationThresholdMs) {
            $segments.Add(@{ Style = 'Duration'; Text = (' {0}{1} ' -f $glyphs.Clock, (Format-PromptDuration $elapsedSeconds)) })
        }

        if ($PromptSettings.ShowTime) {
            $segments.Add(@{ Style = 'Time'; Text = (' {0}{1} ' -f $glyphs.Calendar, (Get-Date -Format $PromptSettings.TimeFormat)) })
        }

        $host.UI.RawUI.WindowTitle = if ($PromptIsAdmin) { "Admin: $shortPath" } else { $shortPath }

        # One caret per nesting level, so a nested prompt is obvious.
        $caret = $glyphs.Caret * (1 + $NestedPromptLevel)
        if ($PromptSettings.UseColour) {
            $caretStyle = if ($succeeded) { $script:PromptStyles['CaretOk'] } else { $script:PromptStyles['CaretFail'] }
            $caret = '{0}{1}{2}' -f $caretStyle.Fg, $caret, "`e[0m"
        }

        # How the last command went, reported above the prompt. Only when one
        # actually ran: Enter on an empty line, or Ctrl+C, would otherwise
        # repeat the previous verdict as though it were fresh.
        $statusLine = ''
        if ($PromptSettings.ShowStatusLine -and $null -ne $elapsedSeconds) {
            $duration = Format-PromptDuration $elapsedSeconds

            if ($failed) {
                # The code is appended only when there is an honest one to
                # give; a bare mark beats a borrowed number.
                $mark = if ($null -ne $failureCode) { '{0} {1}' -f $glyphs.StatusFail, $failureCode }
                        else                        { $glyphs.StatusFail }
                $markStyle = 'StatusFail'
            }
            else {
                $mark      = $glyphs.StatusOk
                $markStyle = 'StatusOk'
            }

            $statusLine = if ($PromptSettings.UseColour) {
                '{0}{1}{2} {3}{4}{2}' -f $script:PromptStyles[$markStyle].Fg, $mark, "`e[0m",
                                         $script:PromptStyles['StatusTime'].Fg, $duration
            }
            else {
                '{0} {1}' -f $mark, $duration
            }
        }

        $out = [System.Text.StringBuilder]::new()

        # Shell integration marks. These print nothing; they tell Windows
        # Terminal where a prompt starts, where typing starts, and how the last
        # command ended, which is what powers scrollbar marks, jumping between
        # commands with scrollToMark, selecting a whole command's output, and
        # opening new tabs in this directory. Terminal needs autoMarkPrompts and
        # showMarksOnScrollbar turned on to act on them.
        if ($PromptSettings.ShellIntegration -and -not $isFirstPrompt) {
            if ($historyAdvanced) {
                [void]$out.Append("`e]133;D;$($result.MarkStatus)`a")
            }
            else {
                # Ctrl+C, or Enter on an empty line: nothing ran, so there is no
                # exit code to report and an omitted one leaves the mark
                # uncoloured.
                [void]$out.Append("`e]133;D`a")
            }
        }

        # Above the blank line, so it reads as a footnote to the output it
        # follows rather than as part of the prompt block below it.
        if ($statusLine) { [void]$out.Append($statusLine).Append("`n") }

        [void]$out.Append("`n")

        if ($PromptSettings.ShellIntegration) {
            [void]$out.Append("`e]133;A`a")
            if ($isFileSystem) { [void]$out.Append("`e]9;9;`"$($location.ProviderPath)`"`a") }
        }

        # Built as one multi-line string rather than written with Write-Host, so
        # PSReadLine knows the whole prompt and can redraw it intact.
        [void]$out.Append((Format-PromptLine $segments)).Append("`n").Append($caret).Append(' ')

        if ($PromptSettings.ShellIntegration) { [void]$out.Append("`e]133;B`a") }

        if ($lastHistory) { $script:PromptLastHistoryId = $lastHistory.Id }
        $script:PromptDrawn = $true

        # Leave $LASTEXITCODE as the command left it: the git call above
        # overwrote it, and code that reads it after the prompt has drawn
        # deserves the truth.
        $global:LASTEXITCODE = $lastExit
        return $out.ToString()
    }
    catch {
        # A prompt that throws prints its exception on every single redraw and
        # leaves the session barely usable. Fall back to something plain instead,
        # and keep the error in $PromptLastError for inspection rather than
        # reprinting it forever. Anything above can fail - a deleted working
        # directory, an unreadable repo, a volume that went away - and none of
        # that is worth losing the shell over.
        $global:PromptLastError = $_
        $global:LASTEXITCODE    = $lastExit
        return "`nPS $($PWD.Path) [prompt failed: see `$PromptLastError]`n> "
    }
}

#endregion
#region PSReadLine

# Predictive IntelliSense: while you type, PSReadLine offers whole commands
# drawn from two sources - your own history, and any predictor plugin that has
# registered itself. F2 switches between the list and inline views live, F4
# shows the full tooltip for the selected row, and Right Arrow or End accepts a
# suggestion (Ctrl+Right Arrow takes it one word at a time).
#
# Predictor modules the profile will use if they are installed. Deploy-Profile
# installs these; add to the list and it will install those too. Anything
# missing is skipped silently, so the profile still works on a bare machine.
$PSReadLinePredictors = @('CompletionPredictor')

# Guarded on PSReadLine actually being loaded, which it is not in a
# non-interactive host - including the 'pwsh -NoProfile' check Deploy-Profile
# runs to verify this file, so the region has to be skippable, not assumed.
if (Get-Module -Name PSReadLine) {

    # A plugin predictor only registers with the subsystem when its module is
    # imported; installed-but-never-imported produces no predictions at all.
    # CompletionPredictor feeds ordinary tab-completion results in as
    # predictions, which is what makes suggestions reach commands never typed
    # before rather than only ones already in history.
    foreach ($predictor in $PSReadLinePredictors) {
        if (Get-Module -Name $predictor) { continue }
        if (-not (Get-Module -Name $predictor -ListAvailable)) { continue }
        try { Import-Module -Name $predictor -ErrorAction Stop }
        catch { Write-Warning "Predictor '$predictor' not loaded: $($_.Exception.Message)" }
    }

    # 'Plugin' as a source arrived in PSReadLine 2.2; older versions know only
    # 'History' and throw on the enum value rather than degrading.
    $PSReadLineSource = if ((Get-Module -Name PSReadLine).Version -ge [version]'2.2.0') {
        'HistoryAndPlugin'
    }
    else {
        'History'
    }

    # PSReadLine refuses to predict where the console lacks virtual terminal
    # processing or output is redirected, and says so loudly. Checking first
    # keeps that off the screen of anyone piping a session to a file, where the
    # warning would be noise about a feature they cannot use anyway.
    if ($Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected) {
        try {
            Set-PSReadLineOption -PredictionSource $PSReadLineSource -ErrorAction Stop

            # ListView shows several candidates at once, each labelled with
            # where it came from, instead of the single inline ghost suggestion.
            Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction Stop
        }
        catch {
            Write-Warning "Prediction not enabled: $($_.Exception.Message)"
        }
    }

    # History is deliberately kept on disk. Predictions are only as good as what
    # they have to draw on, and a session-only history starts cold every time.
    # The consequence is worth being clear about: anything ever typed here can be
    # suggested back later, in front of whoever happens to be watching. If that
    # ever outweighs the convenience, -AddToHistoryHandler can return
    # 'MemoryOnly' for lines matching a pattern, which keeps them recallable in
    # the session but off the disk.
    Set-PSReadLineOption -HistorySaveStyle SaveIncrementally
    Set-PSReadLineOption -MaximumHistoryCount 10000

    # Matched to the prompt palette: dim grey for the inline ghost text, the
    # git-dirty amber for the list marker and source label, and the user
    # segment's blue behind the selected row.
    Set-PSReadLineOption -Colors @{
        InlinePrediction       = "`e[38;2;95;95;95m"
        ListPrediction         = "`e[38;2;215;160;32m"
        ListPredictionSelected = "`e[48;2;45;95;139m"
    }
}

#endregion
#region Elevation

# Start a new elevated process. With arguments, runs a single command elevated;
# without, opens a new admin PowerShell.
function admin {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]] $Command)

    $pwshPath = Join-Path $PSHOME 'pwsh.exe'

    if ($Command) {
        # Quote each argument separately so paths with spaces survive.
        $quoted  = $Command | ForEach-Object { "'{0}'" -f ($_ -replace "'", "''") }
        $cmdLine = '& ' + ($quoted -join ' ')
        Start-Process -FilePath $pwshPath -Verb RunAs -ArgumentList '-NoExit', '-Command', $cmdLine
    }
    else {
        Start-Process -FilePath $pwshPath -Verb RunAs
    }
}

#endregion
