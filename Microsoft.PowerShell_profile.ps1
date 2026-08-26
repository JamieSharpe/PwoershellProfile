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
    Start-Transcript -OutputDirectory "$HOME\Shell Logs" -NoClobber -IncludeInvocationHeader -ErrorAction Stop | Out-Null
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

function prompt {

    #Assign Windows Title Text
    $host.ui.RawUI.WindowTitle = "Current Folder: $pwd"

    #Configure current user, current folder and date outputs
    $CmdPromptCurrentFolder = Split-Path -Path $pwd -Leaf
    $CmdPromptUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Date = Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt'

    # Take the account name after the domain, when there is one.
    $UserName = $CmdPromptUser.Name
    if ($UserName -like '*\*') { $UserName = $UserName.Split('\')[-1] }

    # Test for Admin / Elevated
    $IsAdmin = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    #Calculate execution time of last cmd and convert to milliseconds, seconds or minutes
    $RunTime = 0
    $LastCommand = Get-History -Count 1
    if ($LastCommand) { $RunTime = ($LastCommand.EndExecutionTime - $LastCommand.StartExecutionTime).TotalSeconds }

    if ($RunTime -ge 60) {
        $ts = [timespan]::fromseconds($RunTime)
        $min, $sec = ($ts.ToString("mm\:ss")).Split(":")
        $ElapsedTime = -join ($min, " min ", $sec, " sec")
    }
    else {
        $ElapsedTime = [math]::Round(($RunTime), 2)
        $ElapsedTime = -join (($ElapsedTime.ToString()), " sec")
    }

    #Decorate the CMD Prompt
    Write-Host ""
    Write-Host ($(if ($IsAdmin) { 'Elevated ' } else { '' })) -BackgroundColor DarkRed -ForegroundColor White -NoNewline
    Write-Host " USER:$UserName " -BackgroundColor DarkBlue -ForegroundColor White -NoNewline
    If ($CmdPromptCurrentFolder -like "*:*")
        {Write-Host " $CmdPromptCurrentFolder "  -ForegroundColor White -BackgroundColor DarkGray -NoNewline}
        else {Write-Host ".\$CmdPromptCurrentFolder\ "  -ForegroundColor White -BackgroundColor DarkGray -NoNewline}

    Write-Host " $Date " -ForegroundColor White
    Write-Host "[$ElapsedTime] " -NoNewline -ForegroundColor Green
    return "> "
} #end prompt function

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
