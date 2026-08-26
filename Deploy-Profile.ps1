#Requires -Version 7.0
<#
.SYNOPSIS
    Installs this repo's PowerShell 7 profile for the current user.

.DESCRIPTION
    Backs up anything already at the profile path, then installs either a symlink
    back to the repo (default, so 'git pull' updates the live profile) or a copy.

    PowerShell 7 only - run it with pwsh.

.PARAMETER Mode
    Link  - symlink the profile path at this repo (default). Needs Developer Mode
            or an elevated shell; falls back to Copy automatically if unavailable.
    Copy  - plain file copy. Re-run after each 'git pull'.

.PARAMETER Pull
    Run 'git pull --ff-only' in the repo before installing.

.PARAMETER RemoveLegacyProfile
    Move aside the leftover Windows PowerShell 5.1 profile if one exists. The repo
    profile is 7-only, so a stale copy at the 5.1 path errors on every Windows
    PowerShell launch.

.PARAMETER TargetPath
    Install somewhere other than the default profile path - for example an
    all-hosts profile, or a staging path when testing.

.EXAMPLE
    .\Deploy-Profile.ps1
    Symlink the profile into place.

.EXAMPLE
    .\Deploy-Profile.ps1 -Pull -RemoveLegacyProfile
    Update from git, install, and clear out the old 5.1 profile.

.EXAMPLE
    .\Deploy-Profile.ps1 -WhatIf
    Show what would happen without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Link', 'Copy')]
    [string] $Mode = 'Link',

    [switch] $Pull,

    [switch] $RemoveLegacyProfile,

    [string] $TargetPath
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param($Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param($Message) Write-Host "    $Message" -ForegroundColor DarkGray }

$RepoRoot   = $PSScriptRoot
$SourceFile = Join-Path $RepoRoot 'Microsoft.PowerShell_profile.ps1'

if (-not (Test-Path -LiteralPath $SourceFile)) {
    throw "Profile not found in repo: $SourceFile"
}

# --- 1. Optional git pull -----------------------------------------------------

if ($Pull) {
    Write-Step 'Updating repo'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git not found on PATH; omit -Pull or install git.'
    }
    if ($PSCmdlet.ShouldProcess($RepoRoot, 'git pull --ff-only')) {
        Push-Location $RepoRoot
        try {
            & git pull --ff-only
            if ($LASTEXITCODE -ne 0) { throw "git pull failed (exit $LASTEXITCODE)" }
        }
        finally { Pop-Location }
        Write-Ok 'Repo up to date'
    }
}

# --- 2. Resolve the target path -----------------------------------------------
# Derived from CurrentUserAllHosts rather than CurrentUserCurrentHost: both live
# in the same directory, but the latter changes name per host, so running this
# from the VS Code extension would otherwise target Microsoft.VSCode_profile.ps1.
# Using $PROFILE at all (instead of building "$HOME\Documents\PowerShell") keeps
# OneDrive-redirected Documents folders working.

Write-Step 'Resolving profile path'

if ($TargetPath) {
    $Target = $TargetPath
    Write-Note 'Using -TargetPath override'
}
else {
    $ProfileDir = Split-Path -Parent $PROFILE.CurrentUserAllHosts
    $Target     = Join-Path $ProfileDir 'Microsoft.PowerShell_profile.ps1'
}

$TargetDir = Split-Path -Parent $Target
Write-Ok $Target

if (-not (Test-Path -LiteralPath $TargetDir)) {
    if ($PSCmdlet.ShouldProcess($TargetDir, 'Create directory')) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Write-Note "Created $TargetDir"
    }
}

# --- 3. Inspect what is already installed -------------------------------------

$AlreadyLinked = $false
$existing = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue

if ($existing) {
    if ($existing.LinkType -eq 'SymbolicLink' -and $existing.Target -eq $SourceFile) {
        Write-Ok 'Already symlinked to this repo.'
        $AlreadyLinked = $true
    }
    else {
        Write-Step 'Backing up existing profile'
        $backup = "$Target.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        if ($PSCmdlet.ShouldProcess($Target, "Back up to $backup")) {
            if ($existing.LinkType) {
                # Never copy through a link - just drop it.
                Remove-Item -LiteralPath $Target -Force
                Write-Note "Removed existing $($existing.LinkType)"
            }
            else {
                Move-Item -LiteralPath $Target -Destination $backup -Force
                Write-Note "Saved $backup"
            }
        }
    }
}

# --- 4. Install ---------------------------------------------------------------

$installed = $null

if ($AlreadyLinked) {
    $installed = 'Link'
}
else {
    Write-Step "Installing ($Mode)"

    if ($Mode -eq 'Link' -and $PSCmdlet.ShouldProcess($Target, "Symlink to $SourceFile")) {
        try {
            New-Item -ItemType SymbolicLink -Path $Target -Target $SourceFile -Force -ErrorAction Stop | Out-Null
            $installed = 'Link'
        }
        catch {
            Write-Warning "Symlink failed: $($_.Exception.Message)"
            Write-Note 'Falling back to a copy. Enable Developer Mode or run elevated for a link.'
            $Mode = 'Copy'
        }
    }

    if ($Mode -eq 'Copy' -and -not $installed -and $PSCmdlet.ShouldProcess($Target, "Copy from $SourceFile")) {
        Copy-Item -LiteralPath $SourceFile -Destination $Target -Force
        $installed = 'Copy'
    }

    if ($installed -eq 'Link') { Write-Ok "Symlinked -> $SourceFile" }
    elseif ($installed)        { Write-Ok "Copied (re-run this script after each 'git pull')" }
}

# --- 5. Leftover Windows PowerShell 5.1 profile -------------------------------

$legacy = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'

if (Test-Path -LiteralPath $legacy) {
    Write-Step 'Leftover 5.1 profile'
    if ($RemoveLegacyProfile) {
        $backup = "$legacy.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        if ($PSCmdlet.ShouldProcess($legacy, "Back up to $backup and remove")) {
            Move-Item -LiteralPath $legacy -Destination $backup -Force
            Write-Ok "Moved aside -> $backup"
        }
    }
    else {
        Write-Warning "Still present: $legacy"
        Write-Note 'Re-run with -RemoveLegacyProfile to move it aside.'
    }
}

# --- 6. Verify ----------------------------------------------------------------

if (-not $WhatIfPreference) {
    Write-Step 'Verifying'
    $pwsh   = Join-Path $PSHOME 'pwsh.exe'
    $output = & $pwsh -NoProfile -Command ". `"$Target`"; exit 0" 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Profile loads cleanly.'
        Write-Host ''
        Write-Host 'Done. Open a new PowerShell 7 session to pick it up.' -ForegroundColor Green
    }
    else {
        Write-Warning "Profile failed to load (exit $LASTEXITCODE):"
        $output | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        exit 1
    }
}
