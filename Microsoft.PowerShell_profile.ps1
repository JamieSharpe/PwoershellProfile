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

    Start-Transcript -Path (Join-Path $LogDir $LogName) -NoClobber -IncludeInvocationHeader -ErrorAction Stop | Out-Null

    $null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PSEngineEvent]::Exiting) -Action {
        try { Stop-Transcript } catch { }
    }
}
catch {
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
#   [ADMIN] [ssh] [user] [path] [git] [env] [jobs] [exit] [took] [time]
#   > _
#
# Every segment hides itself when it has nothing to say, so a plain local shell
# in a plain directory shows only user, path and time.
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

    ShowUser = $true
    ShowGit  = $true
    ShowSsh  = $true
    ShowJobs = $true
    ShowEnv  = $true
    ShowTime = $true

    TimeFormat = 'yyyy-MM-dd HH:mm:ss'

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

    # Show the duration segment only for commands that took at least this long;
    # anything quicker is noise.
    DurationThresholdMs = 1000

    # Render the path in full up to this width, then abbreviate its parent
    # directories to single letters.
    MaxPathLength = 45

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
        Env          = @{ Fg = '#0F2E2A'; Bg = '#3FA796' }
        Jobs         = @{ Fg = '#FFFFFF'; Bg = '#556B2F' }
        Failed       = @{ Fg = '#FFFFFF'; Bg = '#A31515' }
        Duration     = @{ Fg = '#C6C6DA'; Bg = '#4B4B6A' }
        Time         = @{ Fg = '#9E9E9E'; Bg = '#2E2E2E' }
        CaretOk      = @{ Fg = '#57A64A' }
        CaretFail    = @{ Fg = '#D14545' }
    }
}

# None of these can change within a session, so resolve them once here rather
# than on every redraw. Doing the identity lookups in the prompt cost two
# WindowsIdentity::GetCurrent() calls per keystroke-return.
$PromptUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($PromptUserName -like '*\*') { $PromptUserName = $PromptUserName.Split('\')[-1] }

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
$script:PromptLastHistoryId = -1

# Tracked separately from the history id: the first draw of a session has no
# previous command to close, and inferring that from the history id instead
# swallowed the mark for the session's very first command.
$script:PromptDrawn = $false

function Reset-PromptCache {
    [CmdletBinding()]
    param()
    $script:PromptGitRoots.Clear()
    $script:PromptSlowRepos.Clear()
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
            Separator = "`u{e0b0}"   # solid right-pointing powerline arrow
            Elevated  = "`u{f0e7}"   # bolt
            Ssh       = "`u{f233} "  # server
            User      = "`u{f007} "  # person
            Folder    = "`u{f07b} "  # folder
            Branch    = "`u{e0a0} "  # branch
            Detached  = "`u{27a6} "  # hooked arrow, for a detached HEAD
            Env       = "`u{f1b2} "  # cube
            Jobs      = "`u{f013} "  # gear
            Clock     = "`u{f017} "  # clock, for how long the last command took
            Calendar  = "`u{f073} "  # calendar, for the wall clock
            Failed    = "`u{f00d} "  # cross
            Ahead     = "`u{21e1}"
            Behind    = "`u{21e3}"
            Caret     = "`u{276f}"
        }
    }
    else {
        @{
            Separator = ' '
            Elevated  = 'ADMIN'
            Ssh       = 'ssh:'
            User      = 'USER:'
            Folder    = ''
            Branch    = 'git:'
            Detached  = 'at '
            Env       = 'env:'
            Jobs      = 'jobs:'
            Clock     = 'took '
            Calendar  = ''
            Failed    = 'exit '
            Ahead     = '+'
            Behind    = '-'
            Caret     = '>'
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

        # The reflog is the cheap way to count stashes: 'git stash list' would
        # be a second process per redraw.
        $stashLog = Join-Path $gitDir 'logs\refs\stash'
        if (Test-Path -LiteralPath $stashLog) {
            $info.Stashed = @(Get-Content -LiteralPath $stashLog -ErrorAction Ignore).Count
        }
    }

    return $info
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

# The exit status to hand the terminal in an OSC 133;D mark. A PowerShell-level
# error carries no numeric code, so -1 says "this failed" without inventing one;
# 0 means success, and anything else is a real native exit code.
function Get-PromptExitStatus {
    param(
        [bool] $Succeeded,
        [AllowNull()] $LastExit,
        [AllowNull()] $LastError,
        [AllowNull()] $LastHistory
    )

    if ($Succeeded) { return 0 }
    if ($LastError -and $LastHistory -and $LastError.InvocationInfo.HistoryId -eq $LastHistory.Id) { return -1 }
    if ($LastExit) { return $LastExit }
    return 1
}

# Join the segments into one powerline strip. Each divider is drawn in the
# outgoing segment's background against the incoming one's, which is what welds
# the blocks together; the last is drawn against the terminal's own background.
function Format-PromptLine {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList] $Segments)

    if ($Segments.Count -eq 0) { return '' }

    if (-not $PromptSettings.UseColour) {
        return (($Segments | ForEach-Object { $_.Text.Trim() }) -join ' ')
    }

    $separator = $script:PromptGlyphs.Separator
    $reset     = "`e[0m"
    $sb        = [System.Text.StringBuilder]::new()

    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $style = $script:PromptStyles[$Segments[$i].Style]
        [void]$sb.Append($style.Set).Append($Segments[$i].Text)

        if ($i -lt $Segments.Count - 1) {
            $next = $script:PromptStyles[$Segments[$i + 1].Style]
            [void]$sb.Append($style.BgAsFg).Append($next.Bg).Append($separator)
        }
        else {
            [void]$sb.Append($reset).Append($style.BgAsFg).Append($separator).Append($reset)
        }
    }
    return $sb.ToString()
}

function prompt {

    # $?, $LASTEXITCODE and $Error[0] all describe the command just finished and
    # are clobbered by the first statement in here, so capture them before
    # anything else runs. $Error matters as much as the other two: it is how a
    # PowerShell-level failure is told apart from a native non-zero exit.
    $succeeded = $?
    $lastExit  = $global:LASTEXITCODE
    $lastError = $global:Error[0]

    $glyphs   = $script:PromptGlyphs
    $segments = [System.Collections.Generic.List[hashtable]]::new()

    # Whether a command actually ran since the last redraw. Pressing Enter on an
    # empty line, or Ctrl+C, leaves history untouched; both the duration segment
    # and the terminal's end-of-command mark need to know that.
    $lastHistory     = Get-History -Count 1
    $isFirstPrompt   = -not $script:PromptDrawn
    $historyAdvanced = $lastHistory -and $lastHistory.Id -ne $script:PromptLastHistoryId

    $location     = $ExecutionContext.SessionState.Path.CurrentLocation
    $isFileSystem = $location.Provider.Name -eq 'FileSystem'

    # The repo has to be resolved before the path, because inside one the path
    # is rendered relative to it.
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

    if ($PromptSettings.ShowSsh -and $script:PromptIsSsh) {
        $segments.Add(@{ Style = 'Ssh'; Text = (' {0}{1} ' -f $glyphs.Ssh, $env:COMPUTERNAME) })
    }

    if ($PromptSettings.ShowUser) {
        $segments.Add(@{ Style = 'User'; Text = (' {0}{1} ' -f $glyphs.User, $PromptUserName) })
    }

    $segments.Add(@{ Style = 'Path'; Text = (' {0}{1} ' -f $glyphs.Folder, $shortPath) })

    if ($git) {
        $label = if ($git.Detached) { '{0}{1}' -f $glyphs.Detached, $git.Branch }
                 else               { '{0}{1}' -f $glyphs.Branch,   $git.Branch }

        $marks = [System.Collections.Generic.List[string]]::new()
        if ($git.Ahead)     { $marks.Add(('{0}{1}' -f $glyphs.Ahead,  $git.Ahead)) }
        if ($git.Behind)    { $marks.Add(('{0}{1}' -f $glyphs.Behind, $git.Behind)) }
        if ($git.Staged)    { $marks.Add('+{0}' -f $git.Staged) }
        if ($git.Unstaged)  { $marks.Add('!{0}' -f $git.Unstaged) }
        if ($git.Untracked) { $marks.Add('?{0}' -f $git.Untracked) }
        if ($git.Conflicts) { $marks.Add('~{0}' -f $git.Conflicts) }
        if ($git.Stashed)   { $marks.Add('*{0}' -f $git.Stashed) }

        # The operation reads as part of the branch, the way git itself says
        # "interactive rebase in progress", so it goes next to the name.
        if ($git.Operation) { $label = '{0}|{1}' -f $label, $git.Operation }

        # Conflicts outrank a running operation: mid-rebase is context, but a
        # conflict is the thing actually blocking you. Grey says "branch only,
        # state unknown" for a repo whose status call was skipped, and must not
        # read as a clean worktree.
        $gitStyle = if     ($git.Partial)       { 'GitPartial' }
                    elseif ($git.Conflicts)     { 'GitConflict' }
                    elseif ($git.Operation)     { 'GitOperation' }
                    elseif ($marks.Count -gt 0) { 'GitDirty' }
                    else                        { 'GitClean' }

        $segments.Add(@{ Style = $gitStyle; Text = (' {0} ' -f ((@($label) + $marks) -join ' ')) })
    }

    if ($PromptSettings.ShowEnv) {
        $envContext = Get-PromptEnvContext
        if ($envContext) { $segments.Add(@{ Style = 'Env'; Text = (' {0}{1} ' -f $glyphs.Env, $envContext) }) }
    }

    if ($PromptSettings.ShowJobs) {
        $jobs = @(Get-Job -State Running -ErrorAction Ignore).Count
        if ($jobs -gt 0) { $segments.Add(@{ Style = 'Jobs'; Text = (' {0}{1} ' -f $glyphs.Jobs, $jobs) }) }
    }

    # Gate on $? alone: $LASTEXITCODE lingers from the last native command, so on
    # its own it would keep flagging a failure long after a successful cmdlet.
    if (-not $succeeded) {
        $code = if ($lastExit) { $lastExit } else { 1 }
        $segments.Add(@{ Style = 'Failed'; Text = (' {0}{1} ' -f $glyphs.Failed, $code) })
    }

    # Only for a command that actually just ran; without the history check the
    # previous command's duration would sit there looking current.
    if ($historyAdvanced) {
        $elapsed = ($lastHistory.EndExecutionTime - $lastHistory.StartExecutionTime).TotalSeconds
        if ($elapsed * 1000 -ge $PromptSettings.DurationThresholdMs) {
            $segments.Add(@{ Style = 'Duration'; Text = (' {0}{1} ' -f $glyphs.Clock, (Format-PromptDuration $elapsed)) })
        }
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

    $out = [System.Text.StringBuilder]::new()

    # Shell integration marks. These print nothing; they tell Windows Terminal
    # where a prompt starts, where typing starts, and how the last command
    # ended, which is what powers scrollbar marks, jumping between commands
    # with scrollToMark, selecting a whole command's output, and opening new
    # tabs in this directory. Terminal needs autoMarkPrompts and
    # showMarksOnScrollbar turned on to act on them.
    if ($PromptSettings.ShellIntegration -and -not $isFirstPrompt) {
        if ($historyAdvanced) {
            $status = Get-PromptExitStatus -Succeeded $succeeded -LastExit $lastExit -LastError $lastError -LastHistory $lastHistory
            [void]$out.Append("`e]133;D;$status`a")
        }
        else {
            # Ctrl+C, or Enter on an empty line: nothing ran, so there is no
            # exit code to report and an omitted one leaves the mark uncoloured.
            [void]$out.Append("`e]133;D`a")
        }
    }

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

    # Leave $LASTEXITCODE as the command left it: the git call above overwrote
    # it, and code that reads it after the prompt has drawn deserves the truth.
    $global:LASTEXITCODE = $lastExit
    return $out.ToString()
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
