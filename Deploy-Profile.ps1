#Requires -Version 7.0

<#
.SYNOPSIS
    Sets up this PowerShell 7 environment: Nerd Font, terminal fonts, profile.

.DESCRIPTION
    Run with no arguments to do the lot:

      1. Install FiraCode Nerd Font (patched), per-user, no elevation
      2. Point Windows Terminal, the legacy console and VS Code at it
      3. Install the predictor modules the profile uses for autocomplete
      4. Symlink the profile so 'git pull' updates the live copy
      5. Move aside any leftover Windows PowerShell 5.1 profile
      6. Verify the profile loads

    Every step is idempotent, backs up whatever it replaces, and honours -WhatIf.
    Use the -Skip* switches to leave parts alone.

    Only steps 1 and 3 need a network. To deploy somewhere with none, run
    '.\Deploy-Profile.ps1 -Prepare' on a connected machine to fill the cache,
    copy the whole folder across, then run '.\Deploy-Profile.ps1 -Offline'.
    A cache is used automatically whenever one is present, online or not.

    The cache also holds a PowerShell 7 installer, since this script requires
    version 7 and so cannot be what installs it. Install that first on a bare
    machine; cache\INSTALL.txt spells out the steps in plain text, for the case
    where there is no PowerShell 7 around to read this help with.

    PowerShell 7 only - run it with pwsh.

.PARAMETER Mode
    Link  - symlink the profile path at this repo (default). Needs Developer Mode
            or an elevated shell; falls back to Copy automatically if unavailable.
    Copy  - plain file copy. Re-run after each 'git pull'.

.PARAMETER Pull
    Run 'git pull --ff-only' in the repo before installing.

.PARAMETER SkipFont
    Do not install the Nerd Font or touch any terminal font setting.

.PARAMETER SkipTerminalFont
    Install the font but leave Windows Terminal, conhost and VS Code alone.

.PARAMETER SkipPredictor
    Do not install the predictor modules. The profile still enables Predictive
    IntelliSense from command history; only the plugin half, which can predict
    commands never typed before, is missing.

.PARAMETER PredictorModule
    Predictor modules to install from the PSGallery, per-user. Defaults to
    CompletionPredictor, which feeds tab-completion results in as predictions.
    Add Az.Tools.Predictor here if you work in Az. Keep this in step with
    $PSReadLinePredictors in the profile, which decides what actually gets
    imported.

.PARAMETER Prepare
    Download PowerShell, the font and the predictor modules into the cache and
    stop, installing nothing. Run this on a connected machine, then copy the
    folder to the offline one. Hands off to Save-DeployCache.ps1, which has more
    options - pinned versions, architecture, and a portable zip instead of the
    MSI.

.PARAMETER SkipPowerShell
    Only meaningful with -Prepare: leave the PowerShell installer out of the
    cache, saving over 100 MB, for when the offline machine already has it.
    This script cannot install PowerShell in any case - it needs version 7 to
    run at all.

.PARAMETER Offline
    Install using only what is in the cache, and fail loudly rather than quietly
    reaching for the network. Refuses to run without a cache, and rejects -Pull.

.PARAMETER CachePath
    Where the cache lives. Defaults to 'cache' inside the repo, which is what
    makes it travel when the folder is copied.

.PARAMETER KeepLegacyProfile
    Leave the Windows PowerShell 5.1 profile in place. By default it is moved
    aside, because this profile is 7-only and a stale copy at the 5.1 path
    errors on every Windows PowerShell launch.

.PARAMETER Font
    Nerd Font to install. Defaults to FiraCode.

.PARAMETER TargetPath
    Install somewhere other than the default profile path - for example an
    all-hosts profile, or a staging path when testing.

.EXAMPLE
    .\Deploy-Profile.ps1
    Everything: font, terminal fonts, profile, 5.1 cleanup.

.EXAMPLE
    .\Deploy-Profile.ps1 -Pull
    Update from git first, then the full setup.

.EXAMPLE
    .\Deploy-Profile.ps1 -SkipFont
    Profile only, leave fonts alone.

.EXAMPLE
    .\Deploy-Profile.ps1 -PredictorModule CompletionPredictor, Az.Tools.Predictor
    Add the Azure predictor alongside the default one.

.EXAMPLE
    .\Deploy-Profile.ps1 -WhatIf
    Show what would happen without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Link', 'Copy')]
    [string] $Mode = 'Link',

    [switch] $Pull,

    [switch] $SkipFont,

    [switch] $SkipTerminalFont,

    [switch] $SkipPredictor,

    [string[]] $PredictorModule = @('CompletionPredictor'),

    [switch] $Prepare,

    [switch] $SkipPowerShell,

    [switch] $Offline,

    [string] $CachePath,

    [switch] $KeepLegacyProfile,

    [string] $Font = 'FiraCode',

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

# --- 0. Cache -----------------------------------------------------------------
# Two of the steps below reach out to the network: the font comes from GitHub
# releases and the predictor modules from the PSGallery. Save-DeployCache.ps1
# pulls both down in advance, and this reads whatever it left behind.

if (-not $CachePath) { $CachePath = Join-Path $RepoRoot 'cache' }

if ($Prepare) {
    if ($Offline) { throw '-Prepare needs a network; it cannot be combined with -Offline.' }

    $prepareScript = Join-Path $RepoRoot 'Save-DeployCache.ps1'
    if (-not (Test-Path -LiteralPath $prepareScript)) {
        throw "Save-DeployCache.ps1 not found next to this script: $prepareScript"
    }

    $prepareArgs = @{ CachePath = $CachePath; Font = $Font; PredictorModule = $PredictorModule }
    if ($SkipFont)         { $prepareArgs.SkipFont       = $true }
    if ($SkipPredictor)    { $prepareArgs.SkipPredictor  = $true }
    if ($SkipPowerShell)   { $prepareArgs.SkipPowerShell = $true }
    if ($WhatIfPreference) { $prepareArgs.WhatIf         = $true }

    & $prepareScript @prepareArgs
    return
}

$Cache = $null
$ManifestPath = Join-Path $CachePath 'cache.json'

if (Test-Path -LiteralPath $ManifestPath) {
    try {
        $Cache = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        Write-Step 'Cache'
        Write-Ok "$CachePath (captured $($Cache.createdUtc) on $($Cache.createdOn))"
    }
    catch {
        Write-Warning "Cache manifest unreadable, ignoring it: $($_.Exception.Message)"
        $Cache = $null
    }
}

if ($Offline) {
    if (-not $Cache) {
        throw "-Offline needs a cache, and none was found at $CachePath. Run '.\Save-DeployCache.ps1' on a connected machine first, then copy this folder across."
    }
    if ($Pull) {
        throw '-Pull needs a network; it cannot be combined with -Offline.'
    }
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

# --- 1b. Optional font install ------------------------------------------------

if (-not $SkipFont) {
    $fontScript = Join-Path $RepoRoot 'Install-NerdFont.ps1'
    if (-not (Test-Path -LiteralPath $fontScript)) {
        throw "Install-NerdFont.ps1 not found next to this script: $fontScript"
    }

    $fontArgs = @{ Font = $Font; Variant = 'Mono' }
    if (-not $SkipTerminalFont) { $fontArgs.SetTerminalFont = $true }
    if ($WhatIfPreference)      { $fontArgs.WhatIf          = $true }

    # A cached archive is preferred whenever one is there, online or not: it is
    # the same bytes and it saves a download.
    $cachedFont = @($Cache.fonts | Where-Object { $_.font -eq $Font })[0]

    if ($cachedFont) {
        $archive = Join-Path $CachePath ($cachedFont.file -replace '/', '\')

        if (-not (Test-Path -LiteralPath $archive)) {
            if ($Offline) { throw "Cache lists $($cachedFont.file) but the file is missing from $CachePath." }
            Write-Warning "Cached font missing from disk, falling back to a download: $archive"
        }
        else {
            # The cache is expected to have crossed a USB stick or a share, so
            # verify it rather than trusting it, before unpacking fonts from it.
            Write-Step 'Verifying cached font'
            $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
            if ($actual -ne $cachedFont.sha256) {
                throw "Cached font is corrupt: $archive`nexpected $($cachedFont.sha256)`ngot      $actual"
            }
            Write-Ok "$($cachedFont.font) $($cachedFont.tag), SHA256 matches"
            $fontArgs.ArchivePath = $archive
        }
    }
    elseif ($Offline) {
        throw "-Offline was given but the cache holds no font for '$Font'. Re-run Save-DeployCache.ps1 with -Font $Font."
    }

    & $fontScript @fontArgs
    if ($LASTEXITCODE) { throw "Font install failed (exit $LASTEXITCODE)" }
    Write-Host ''
}

# --- 1c. Predictor modules ----------------------------------------------------
# The profile turns on Predictive IntelliSense either way, drawing on command
# history. These modules add the plugin half of it, which can suggest commands
# never typed before. The profile imports whichever it finds and carries on
# quietly without the rest, so this step is a convenience and never fatal.

if (-not $SkipPredictor -and $PredictorModule.Count) {
    Write-Step 'Predictor modules'

    $UserModuleDir = Join-Path (Split-Path -Parent $PROFILE.CurrentUserAllHosts) 'Modules'

    foreach ($name in $PredictorModule) {
        if (Get-Module -Name $name -ListAvailable) {
            Write-Note "$name already installed"
            continue
        }

        $cachedModule = @($Cache.modules | Where-Object { $_.name -eq $name })[0]

        # From the cache this is a directory copy into the module path - no
        # repository registration, nothing to resolve, and so nothing that can
        # fail on a machine with no route to the gallery.
        if ($cachedModule) {
            $source = Join-Path $CachePath ($cachedModule.path -replace '/', '\')

            if (-not (Test-Path -LiteralPath $source)) {
                if ($Offline) { throw "Cache lists $($cachedModule.path) but the folder is missing from $CachePath." }
                Write-Warning "Cached module missing from disk, falling back to the gallery: $source"
            }
            elseif ($PSCmdlet.ShouldProcess($name, "Copy $($cachedModule.version) from cache")) {
                $dest = Join-Path $UserModuleDir "$name\$($cachedModule.version)"
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Copy-Item -Path (Join-Path $source '*') -Destination $dest -Recurse -Force
                Write-Ok "Installed $name $($cachedModule.version) from cache"
                continue
            }
            else { continue }
        }

        if ($Offline) {
            Write-Warning "-Offline was given but the cache holds no module '$name'; skipping."
            Write-Note "Re-run Save-DeployCache.ps1 with -PredictorModule $name to include it."
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($name, 'Install-Module from PSGallery (CurrentUser)')) { continue }

        try {
            # -Force answers the untrusted-repository prompt, which a deploy
            # script must not block on.
            Install-Module -Name $name -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop
            Write-Ok "Installed $name"
        }
        catch {
            # Autocomplete is a nicety; losing it must not cost you the profile.
            Write-Warning "Could not install ${name}: $($_.Exception.Message)"
            Write-Note 'Prediction from history still works. Install it later, or pass -SkipPredictor.'
        }
    }
    Write-Host ''
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
    if ($KeepLegacyProfile) {
        Write-Warning "Left in place: $legacy"
        Write-Note 'It will error on every Windows PowerShell launch (profile is 7-only).'
    }
    else {
        $backup = "$legacy.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        if ($PSCmdlet.ShouldProcess($legacy, "Back up to $backup and remove")) {
            Move-Item -LiteralPath $legacy -Destination $backup -Force
            Write-Ok "Moved aside -> $backup"
        }
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
