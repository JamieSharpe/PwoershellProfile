# C:\Users\[User]\Documents\Powershell\Microsoft.PowerShell_profile.ps1
# Set-ExecutionPolicy -ExecutionPolicy Unrestricted

set-executionpolicy Unrestricted process

# Log all actions carried out.
Start-Transcript -OutputDirectory "$HOME\Shell Logs\" -NoClobber -IncludeInvocationHeader

# Aliases
New-Alias -Name 'eth' -Value Get-NetAdapter

# Global variables
$projects_dir = "C:\# Projects"
$cases_dir = "K:\"

function HOME {
    Set-Location $HOME
    Get-ChildItem
}
Set-Alias ~ HOME

# Compute file hashes
function md5    { Get-FileHash -Algorithm MD5 $args }
function sha1   { Get-FileHash -Algorithm SHA1 $args }
function sha256 { Get-FileHash -Algorithm SHA256 $args }

# Compute string hashes
function md5sum($input_string)
{
    $md5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding
    $hash = [System.BitConverter]::ToString($md5.ComputeHash($utf8.GetBytes($input_string))) -replace '-',''
    Write-Output $hash
}

# Open explorere in current directory
function explore { "explorer.exe `"$(Get-Location)`"" | Invoke-Expression }

# Create a file
function touch ($file) { Write-Output "" >> $file; }

# Download a file from a URL
function download ($url, $file) {(new-object Net.WebClient).DownloadFile($url, $file)}
function wget ($url) {(new-object Net.WebClient).DownloadString("$url")}

# Custom Prompt
function prompt {

    #Assign Windows Title Text
    $host.ui.RawUI.WindowTitle = "Current Folder: $pwd"

    #Configure current user, current folder and date outputs
    $CmdPromptCurrentFolder = Split-Path -Path $pwd -Leaf
    $CmdPromptUser = [Security.Principal.WindowsIdentity]::GetCurrent();
    $Date = Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt'

    # Test for Admin / Elevated
    $IsAdmin = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    #Calculate execution time of last cmd and convert to milliseconds, seconds or minutes
    $LastCommand = Get-History -Count 1
    if ($lastCommand) { $RunTime = ($lastCommand.EndExecutionTime - $lastCommand.StartExecutionTime).TotalSeconds }

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
    Write-Host " USER:$($CmdPromptUser.Name.split("\")[1]) " -BackgroundColor DarkBlue -ForegroundColor White -NoNewline
    If ($CmdPromptCurrentFolder -like "*:*")
        {Write-Host " $CmdPromptCurrentFolder "  -ForegroundColor White -BackgroundColor DarkGray -NoNewline}
        else {Write-Host ".\$CmdPromptCurrentFolder\ "  -ForegroundColor White -BackgroundColor DarkGray -NoNewline}

    Write-Host " $date " -ForegroundColor White
    Write-Host "[$elapsedTime] " -NoNewline -ForegroundColor Green
    return "> "
} #end prompt function


# Simple function to start a new elevated process. If arguments are supplied then 
# a single command is started with admin rights; if not then a new admin instance
# of PowerShell is started.
function admin
{
    if ($args.Count -gt 0)
    {   
       $argList = "& '" + $args + "'"
       Start-Process "$psHome\powershell.exe" -Verb runAs -ArgumentList $argList
    }
    else
    {
       Start-Process "$psHome\powershell.exe" -Verb runAs
    }
}