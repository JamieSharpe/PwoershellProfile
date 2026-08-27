#Requires -Version 7.0

<#
.SYNOPSIS
    Downloads everything Deploy-Profile.ps1 would fetch and stores it beside the
    repo, so the deploy can then be run on a machine with no network.

.DESCRIPTION
    Run this on a connected machine. It fills a 'cache' folder inside the repo:

        cache\cache.json                        what was captured, and when
        cache\INSTALL.txt                       the offline steps, in plain text
        cache\powershell\PowerShell-7.6.5-win-x64.msi
        cache\fonts\FiraCode-v3.4.0.zip         the nerd-fonts release asset
        cache\modules\CompletionPredictor\...   the predictor module tree

    Then copy the whole repo folder - cache and all - to the offline machine and
    run:

        .\Deploy-Profile.ps1 -Offline

    Nothing else Deploy-Profile does touches the network, so that is the entire
    offline story. The profile, the prompt and Enable-ShellIntegration.ps1 are
    all local work already.

    PowerShell itself is cached because Deploy-Profile.ps1 requires version 7
    and so cannot install it - it could not even start on a machine that only
    has Windows PowerShell 5.1. Install the MSI first, then deploy. That is
    written into cache\INSTALL.txt so the bundle explains itself on a machine
    with no PowerShell 7 and no way to read this help. It is also the bulk of
    the cache, at over 100 MB, so -SkipPowerShell is there for when the target
    already has it.

    The cache is deliberately not committed: a font archive is tens of MB, and
    git is not a binary distribution channel. Move the folder, don't push it.
    Delete the cache folder to start clean; re-running refreshes it in place.

.PARAMETER CachePath
    Where to write the cache. Defaults to 'cache' inside the repo, which is what
    makes it travel when the folder is copied.

.PARAMETER Font
    Nerd Font to cache. Must match what Deploy-Profile.ps1 is later given.

.PARAMETER Version
    Pin a nerd-fonts release tag, e.g. 'v3.4.0'. Defaults to the latest release,
    whatever that is at the time this is run.

.PARAMETER PredictorModule
    Predictor modules to cache. Keep in step with Deploy-Profile.ps1's parameter
    of the same name.

.PARAMETER PowerShellVersion
    Pin a PowerShell release tag, e.g. 'v7.6.5'. Defaults to the latest stable
    release; previews are marked prerelease on GitHub and are never picked.

.PARAMETER PowerShellArchitecture
    Which build to cache. Defaults to x64 - deliberately not the architecture of
    the machine preparing the cache, which is rarely the one it is destined for.

.PARAMETER PowerShellPackage
    msi to install normally, or zip for a portable copy that needs no installer
    - useful where running an MSI is not permitted.

.PARAMETER SkipFont
    Do not cache the font.

.PARAMETER SkipPredictor
    Do not cache the predictor modules.

.PARAMETER SkipPowerShell
    Do not cache the PowerShell installer. Use when the offline machine already
    has PowerShell 7; it saves over 100 MB.

.PARAMETER Force
    Re-download even when the cache already holds a matching file.

.EXAMPLE
    .\Save-DeployCache.ps1
    Cache the latest FiraCode nerd font and CompletionPredictor.

.EXAMPLE
    .\Save-DeployCache.ps1 -Version v3.4.0
    Pin the font release, so the offline machine gets a known version.

.EXAMPLE
    .\Save-DeployCache.ps1 -CachePath D:\transfer\cache
    Write the cache to a USB stick instead of into the repo.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $CachePath,

    [string] $Font = 'FiraCode',

    [string] $Version,

    [string[]] $PredictorModule = @('CompletionPredictor'),

    [string] $PowerShellVersion,

    [ValidateSet('x64', 'x86', 'arm64')]
    [string] $PowerShellArchitecture = 'x64',

    [ValidateSet('msi', 'zip')]
    [string] $PowerShellPackage = 'msi',

    [switch] $SkipFont,

    [switch] $SkipPredictor,

    [switch] $SkipPowerShell,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param($Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param($Message) Write-Host "    $Message" -ForegroundColor DarkGray }

# One GitHub release asset: fetch it unless it is already here, then hash it so
# the offline side can tell a good copy from one a USB stick truncated.
# SupportsShouldProcess is load-bearing, not decoration: without it this advanced
# function gets its own $PSCmdlet whose ShouldProcess always returns true, and
# -WhatIf would download a hundred megabytes while claiming to do nothing.
function Save-CachedAsset {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Destination,
        [switch] $Force
    )

    $name = Split-Path -Leaf $Destination

    if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
        Write-Note "Already cached: $name"
    }
    elseif ($PSCmdlet.ShouldProcess($Url, 'Download')) {
        $ProgressPreference = 'SilentlyContinue'   # ~10x faster for large files
        Invoke-WebRequest -Uri $Url -OutFile $Destination
        Write-Ok "$([math]::Round((Get-Item -LiteralPath $Destination).Length / 1MB, 1)) MB -> $name"
    }

    if (-not (Test-Path -LiteralPath $Destination)) { return $null }

    $item = Get-Item -LiteralPath $Destination
    [pscustomobject]@{
        sizeBytes = $item.Length
        sha256    = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    }
}

# A GitHub release, latest stable unless a tag is pinned. Previews are flagged
# prerelease and never returned by the 'latest' endpoint.
function Get-GitHubRelease {
    param(
        [Parameter(Mandatory)][string] $Repo,
        [string] $Tag
    )

    $uri = if ($Tag) {
        "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    }
    else {
        "https://api.github.com/repos/$Repo/releases/latest"
    }

    Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'PowerShell' }
}

if (-not $CachePath) { $CachePath = Join-Path $PSScriptRoot 'cache' }

$FontDir   = Join-Path $CachePath 'fonts'
$ModuleDir = Join-Path $CachePath 'modules'
$PwshDir   = Join-Path $CachePath 'powershell'
$Manifest  = Join-Path $CachePath 'cache.json'

Write-Step 'Cache location'
Write-Ok $CachePath

foreach ($dir in $CachePath, $FontDir, $ModuleDir, $PwshDir) {
    if (-not (Test-Path -LiteralPath $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, 'Create directory')) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

# Re-running tops the cache up rather than starting over, so a failed font
# download does not cost you the modules you already have.
$cache = if (Test-Path -LiteralPath $Manifest) {
    Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
}
else {
    [pscustomobject]@{ schema = 2; createdUtc = $null; powershellPackages = @(); fonts = @(); modules = @() }
}

$pwshPackages = [System.Collections.Generic.List[object]]::new()
$fonts        = [System.Collections.Generic.List[object]]::new()
$modules      = [System.Collections.Generic.List[object]]::new()
# The null guard matters: a manifest written by an older version has no
# powershellPackages property at all, and @($null) is a one-element array
# holding null, not an empty one. Without this a null entry lands in the
# manifest and prints as a blank line in the summary.
foreach ($p in @($cache.powershellPackages)) { if ($p) { $pwshPackages.Add($p) } }
foreach ($f in @($cache.fonts))              { if ($f) { $fonts.Add($f) } }
foreach ($m in @($cache.modules))            { if ($m) { $modules.Add($m) } }

# --- 1. PowerShell ------------------------------------------------------------
# Cached first because it is the prerequisite for everything else: Deploy-Profile
# requires version 7 and cannot install what it needs in order to run.

if (-not $SkipPowerShell) {
    Write-Step 'Resolving PowerShell release'

    # Named apart from the font's $Version and $tag on purpose: PowerShell
    # variables are case-insensitive, so a local $version here would quietly
    # overwrite the -Version parameter and send the font lookup to a dead tag.
    $pwshRel     = Get-GitHubRelease -Repo 'PowerShell/PowerShell' -Tag $PowerShellVersion
    $pwshTag     = $pwshRel.tag_name
    $pwshRelease = $pwshTag.TrimStart('v')

    # Matched against the published asset list rather than built by hand, so a
    # change in their naming shows up as a clear error instead of a 404.
    $pwshAssetName = "PowerShell-$pwshRelease-win-$PowerShellArchitecture.$PowerShellPackage"
    $pwshAsset     = $pwshRel.assets | Where-Object name -EQ $pwshAssetName

    if (-not $pwshAsset) {
        $available = ($pwshRel.assets | Where-Object name -like '*win*' | Select-Object -ExpandProperty name) -join "`n  "
        throw "No asset '$pwshAssetName' in PowerShell $pwshTag. Available Windows assets:`n  $available"
    }

    Write-Ok "PowerShell $pwshRelease $PowerShellArchitecture ($PowerShellPackage), $pwshTag"

    Write-Step 'PowerShell package'
    $pwshInfo = Save-CachedAsset -Url $pwshAsset.browser_download_url -Destination (Join-Path $PwshDir $pwshAssetName) -Force:$Force

    if ($pwshInfo) {
        Write-Note "SHA256 $($pwshInfo.sha256)"

        $entry = [pscustomobject]@{
            version      = $pwshRelease
            tag          = $pwshTag
            architecture = $PowerShellArchitecture
            package      = $PowerShellPackage
            file         = "powershell/$pwshAssetName"
            sizeBytes    = $pwshInfo.sizeBytes
            sha256       = $pwshInfo.sha256
            sourceUrl    = $pwshAsset.browser_download_url
        }

        # One entry per architecture-and-package pair; a newer tag replaces it.
        $stale = @($pwshPackages | Where-Object { $_.architecture -eq $PowerShellArchitecture -and $_.package -eq $PowerShellPackage })
        foreach ($s in $stale) { [void]$pwshPackages.Remove($s) }
        $pwshPackages.Add($entry)
    }
}

# --- 2. Font ------------------------------------------------------------------

if (-not $SkipFont) {
    Write-Step 'Resolving nerd-fonts release'

    $rel   = Get-GitHubRelease -Repo 'ryanoasis/nerd-fonts' -Tag $Version
    $tag   = $rel.tag_name
    $asset = $rel.assets | Where-Object name -EQ "$Font.zip"
    if (-not $asset) {
        throw "No asset '$Font.zip' in nerd-fonts $tag. Check the font name at https://github.com/ryanoasis/nerd-fonts/releases"
    }
    $url = $asset.browser_download_url

    Write-Ok "$Font @ $tag"

    $fileName = "$Font-$tag.zip"
    $target   = Join-Path $FontDir $fileName

    Write-Step 'Font archive'
    $info = Save-CachedAsset -Url $url -Destination $target -Force:$Force

    if ($info) {
        Write-Note "SHA256 $($info.sha256)"

        $entry = [pscustomobject]@{
            font      = $Font
            tag       = $tag
            file      = "fonts/$fileName"
            sizeBytes = $info.sizeBytes
            sha256    = $info.sha256
            sourceUrl = $url
        }

        # One entry per font name; a re-run with a newer tag replaces it.
        $stale = @($fonts | Where-Object { $_.font -eq $Font })
        foreach ($s in $stale) { [void]$fonts.Remove($s) }
        $fonts.Add($entry)
    }
}

# --- 3. Predictor modules -----------------------------------------------------
# Saved as a plain module tree rather than nupkgs, so installing offline is a
# directory copy into the module path. That needs no repository registration on
# the target machine, which is one less thing to go wrong somewhere with no
# route to the gallery.

if (-not $SkipPredictor -and $PredictorModule.Count) {
    Write-Step 'Caching predictor modules'

    foreach ($name in $PredictorModule) {
        $dest = Join-Path $ModuleDir $name

        if ((Test-Path -LiteralPath $dest) -and -not $Force) {
            $have = @(Get-ChildItem -LiteralPath $dest -Directory | Select-Object -ExpandProperty Name)
            Write-Note "Already cached: $name $($have -join ', ')"
        }
        elseif ($PSCmdlet.ShouldProcess($name, 'Save-Module from PSGallery')) {
            try {
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }

                # Save-Module brings dependencies down alongside the module, so
                # the cache is self-contained.
                Save-Module -Name $name -Repository PSGallery -Path $ModuleDir -Force -ErrorAction Stop
                Write-Ok "Saved $name"
            }
            catch {
                Write-Warning "Could not cache ${name}: $($_.Exception.Message)"
                continue
            }
        }

        if (-not (Test-Path -LiteralPath $dest)) { continue }

        foreach ($versionDir in Get-ChildItem -LiteralPath $dest -Directory) {
            $entry = [pscustomobject]@{
                name    = $name
                version = $versionDir.Name
                path    = "modules/$name/$($versionDir.Name)"
            }
            $stale = @($modules | Where-Object { $_.name -eq $name -and $_.version -eq $versionDir.Name })
            foreach ($s in $stale) { [void]$modules.Remove($s) }
            $modules.Add($entry)
        }
    }
}

# --- 4. Manifest and offline instructions -------------------------------------

if ($PSCmdlet.ShouldProcess($Manifest, 'Write manifest')) {
    $out = [pscustomobject]@{
        schema             = 2
        createdUtc         = (Get-Date).ToUniversalTime().ToString('o')
        createdOn          = $env:COMPUTERNAME
        powershell         = $PSVersionTable.PSVersion.ToString()
        powershellPackages = @($pwshPackages)
        fonts              = @($fonts)
        modules            = @($modules)
    }
    $out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Manifest -Encoding utf8
}

# Plain text, written into the cache, because the machine that needs these
# instructions is by definition one that cannot run Get-Help on this script.
if ($PSCmdlet.ShouldProcess((Join-Path $CachePath 'INSTALL.txt'), 'Write offline instructions')) {

    $steps = [System.Collections.Generic.List[string]]::new()
    $steps.Add('Offline install')
    $steps.Add('================')
    $steps.Add('')
    $steps.Add("Captured $((Get-Date).ToUniversalTime().ToString('u')) on $env:COMPUTERNAME.")
    $steps.Add('Copy the whole repo folder to the target machine, then work through these.')
    $steps.Add('')

    $step = 1
    foreach ($p in $pwshPackages) {
        $steps.Add("$step. Install PowerShell $($p.version) ($($p.architecture)) - skip if it is already there.")
        $steps.Add('')
        if ($p.package -eq 'msi') {
            $steps.Add("     msiexec /i `"cache\$($p.file -replace '/', '\')`" /qn")
            $steps.Add('')
            $steps.Add('   Or double-click the .msi. Installing for all users needs an admin prompt.')
        }
        else {
            $steps.Add("     Expand cache\$($p.file -replace '/', '\') somewhere and run pwsh.exe from it.")
            $steps.Add('   The zip is portable - nothing is installed and nothing is registered.')
        }
        $steps.Add('')
        $step++
    }

    $steps.Add("$step. Open PowerShell 7 (pwsh) in the repo folder and run:")
    $steps.Add('')
    $steps.Add('     .\Deploy-Profile.ps1 -Offline')
    $steps.Add('')
    $steps.Add('   That installs the font, the predictor modules and the profile,')
    $steps.Add('   entirely from this cache. It will refuse rather than quietly')
    $steps.Add('   reach for the network.')
    $steps.Add('')
    $step++

    $steps.Add("$step. Optional, for Windows Terminal command marks and directory-aware tabs:")
    $steps.Add('')
    $steps.Add('     .\Enable-ShellIntegration.ps1')
    $steps.Add('')
    $steps.Add('Contents')
    $steps.Add('--------')
    foreach ($p in $pwshPackages) { $steps.Add("  PowerShell $($p.version) $($p.architecture) $($p.package)  $([math]::Round($p.sizeBytes / 1MB, 1)) MB") }
    foreach ($f in $fonts)        { $steps.Add("  $($f.font) nerd font $($f.tag)  $([math]::Round($f.sizeBytes / 1MB, 1)) MB") }
    foreach ($m in $modules)      { $steps.Add("  module $($m.name) $($m.version)") }

    $steps -join "`r`n" | Set-Content -LiteralPath (Join-Path $CachePath 'INSTALL.txt') -Encoding utf8
}

Write-Step 'Cached'
foreach ($p in $pwshPackages) { Write-Ok "pwsh   $($p.version) $($p.architecture) $($p.package)" }
foreach ($f in $fonts)        { Write-Ok "font   $($f.font) $($f.tag)" }
foreach ($m in $modules)      { Write-Ok "module $($m.name) $($m.version)" }

$size = if (Test-Path -LiteralPath $CachePath) {
    [math]::Round((Get-ChildItem -LiteralPath $CachePath -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
} else { 0 }

Write-Host ''
Write-Note "Total $size MB at $CachePath"
Write-Host 'Copy this folder to the offline machine, then run: .\Deploy-Profile.ps1 -Offline' -ForegroundColor Green
