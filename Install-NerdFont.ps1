#Requires -Version 7.0
<#
.SYNOPSIS
    Downloads and installs a Nerd Font (patched) from the ryanoasis/nerd-fonts
    releases. Defaults to FiraCode, per-user, no elevation required.

.DESCRIPTION
    Per-user installs drop the .ttf files into
    %LOCALAPPDATA%\Microsoft\Windows\Fonts and register them under
    HKCU, which needs no administrator rights. Machine-wide installs
    use C:\Windows\Fonts and HKLM, and do require elevation.

    Fonts are registered under their real full name read from the TTF 'name'
    table, matching how Windows itself registers them.

.PARAMETER Font
    Nerd Fonts release asset base name, e.g. FiraCode, JetBrainsMono, Hack.

.PARAMETER Variant
    Which faces to install:
      Mono     - FiraCodeNerdFontMono-*  (single-width glyphs; best for terminals)
      Standard - FiraCodeNerdFont-*      (variable-width glyphs)
      Propo    - FiraCodeNerdFontPropo-* (proportional)
      All      - everything in the archive (default)

.PARAMETER Scope
    User (default, no elevation) or Machine (requires an elevated shell).

.PARAMETER SetTerminalFont
    Point Windows Terminal's default profile at the installed font.
    Rewrites settings.json - see the warning it prints about comments.

.PARAMETER Version
    Pin a nerd-fonts release tag, e.g. 'v3.5.1'. Defaults to the latest release.

.EXAMPLE
    .\Install-NerdFont.ps1
    Install all FiraCode Nerd Font faces for the current user.

.EXAMPLE
    .\Install-NerdFont.ps1 -Variant Mono -SetTerminalFont
    Install just the Mono faces and set Windows Terminal to use them.

.EXAMPLE
    .\Install-NerdFont.ps1 -WhatIf
    Show what would be downloaded and installed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Font = 'FiraCode',

    [ValidateSet('Mono', 'Standard', 'Propo', 'All')]
    [string] $Variant = 'All',

    [ValidateSet('User', 'Machine')]
    [string] $Scope = 'User',

    [switch] $SetTerminalFont,

    [string] $Version,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param($Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param($Message) Write-Host "    $Message" -ForegroundColor DarkGray }

# --- Read the real font name from the TTF 'name' table ------------------------

function Get-FontFullName {
    param([string] $Path)

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)

        # The [int] casts matter: PowerShell masks the shift count when the left
        # operand is a [byte], so ($byte -shl 16) silently evaluates to 0.
        function RU16 { param($r) $a = [int]$r.ReadByte(); $b = [int]$r.ReadByte(); ($a -shl 8) -bor $b }
        function RU32 { param($r)
            $a = [int]$r.ReadByte(); $b = [int]$r.ReadByte()
            $c = [int]$r.ReadByte(); $d = [int]$r.ReadByte()
            ($a -shl 24) -bor ($b -shl 16) -bor ($c -shl 8) -bor $d
        }

        $null      = RU32 $br              # sfntVersion
        $numTables = RU16 $br
        $null = RU16 $br; $null = RU16 $br; $null = RU16 $br

        $nameOffset = 0
        for ($i = 0; $i -lt $numTables; $i++) {
            $tag  = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
            $null = RU32 $br
            $off  = RU32 $br
            $null = RU32 $br
            if ($tag -eq 'name') { $nameOffset = $off }
        }
        if (-not $nameOffset) { return $null }

        $fs.Position = $nameOffset
        $null        = RU16 $br            # format
        $count       = RU16 $br
        $stringOff   = RU16 $br

        $best = $null
        for ($i = 0; $i -lt $count; $i++) {
            $platform = RU16 $br; $encoding = RU16 $br; $language = RU16 $br
            $nameId   = RU16 $br; $len      = RU16 $br; $off      = RU16 $br

            # nameID 4 = full font name, platform 3 = Windows, encoding 1 = UCS-2
            if ($nameId -eq 4 -and $platform -eq 3 -and $encoding -eq 1) {
                $save        = $fs.Position
                $fs.Position = $nameOffset + $stringOff + $off
                $best        = [System.Text.Encoding]::BigEndianUnicode.GetString($br.ReadBytes($len))
                $fs.Position = $save
                if ($language -eq 0x409) { break }   # prefer en-US
            }
        }
        return $best
    }
    finally { $fs.Dispose() }
}

# --- Tell running apps a font was added ---------------------------------------

function Invoke-FontChangeBroadcast {
    if (-not ('NativeFont' -as [type])) {
        Add-Type -Namespace '' -Name NativeFont -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@
    }
    $HWND_BROADCAST = [IntPtr]0xFFFF
    $WM_FONTCHANGE  = 0x001D
    $result         = [IntPtr]::Zero
    $null = [NativeFont]::SendMessageTimeout($HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$result)
}

# --- 1. Scope and destinations ------------------------------------------------

$IsAdmin = (New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent())
           ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

if ($Scope -eq 'Machine') {
    if (-not $IsAdmin) { throw 'Machine scope requires an elevated shell. Re-run as administrator, or use -Scope User.' }
    $FontDir = Join-Path $env:SystemRoot 'Fonts'
    $RegKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
}
else {
    $FontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $RegKey  = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
}

Write-Step "Installing $Font Nerd Font ($Variant faces, $Scope scope)"
Write-Note "Fonts    : $FontDir"
Write-Note "Registry : $RegKey"

# --- 2. Resolve the release ---------------------------------------------------

Write-Step 'Resolving release'

if ($Version) {
    $tag = $Version
    $url = "https://github.com/ryanoasis/nerd-fonts/releases/download/$tag/$Font.zip"
}
else {
    $api  = 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest'
    $rel  = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'PowerShell' }
    $tag  = $rel.tag_name
    $asset = $rel.assets | Where-Object name -EQ "$Font.zip"
    if (-not $asset) {
        throw "No asset '$Font.zip' in nerd-fonts $tag. Check the font name at https://github.com/ryanoasis/nerd-fonts/releases"
    }
    $url = $asset.browser_download_url
}
Write-Ok "$Font @ $tag"

# --- 3. Download and extract --------------------------------------------------

$work = Join-Path ([System.IO.Path]::GetTempPath()) "nerdfont-$Font-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$zip  = Join-Path $work "$Font.zip"

if ($PSCmdlet.ShouldProcess($url, 'Download')) {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Write-Step 'Downloading'
    $ProgressPreference = 'SilentlyContinue'   # ~10x faster for large files
    Invoke-WebRequest -Uri $url -OutFile $zip
    Write-Ok "$([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB"

    Write-Step 'Extracting'
    Expand-Archive -Path $zip -DestinationPath $work -Force
}

$pattern = switch ($Variant) {
    'Mono'     { "^${Font}NerdFontMono-" }
    'Standard' { "^${Font}NerdFont-" }
    'Propo'    { "^${Font}NerdFontPropo-" }
    default    { '\.ttf$' }
}

$files = if (Test-Path $work) {
    @(Get-ChildItem -Path $work -Filter '*.ttf' -Recurse | Where-Object { $_.Name -match $pattern })
} else { @() }

if ($PSCmdlet.ShouldProcess('font files', 'Install') -and -not $files) {
    throw "No .ttf files matched '$pattern' in the archive."
}
if ($files) { Write-Ok "$($files.Count) face(s) to install" }

# --- 4. Install ---------------------------------------------------------------

$installed = 0
$skipped   = 0

if (-not (Test-Path -LiteralPath $FontDir)) {
    if ($PSCmdlet.ShouldProcess($FontDir, 'Create directory')) {
        New-Item -ItemType Directory -Path $FontDir -Force | Out-Null
    }
}
if (-not (Test-Path -LiteralPath $RegKey)) {
    if ($PSCmdlet.ShouldProcess($RegKey, 'Create registry key')) {
        New-Item -Path $RegKey -Force | Out-Null
    }
}

foreach ($file in $files) {
    $fullName = Get-FontFullName $file.FullName
    if (-not $fullName) { $fullName = $file.BaseName }
    $entry    = "$fullName (TrueType)"
    $dest     = Join-Path $FontDir $file.Name

    $already = (Get-ItemProperty -Path $RegKey -Name $entry -ErrorAction SilentlyContinue)
    if ($already -and (Test-Path -LiteralPath $dest) -and -not $Force) {
        $skipped++
        continue
    }

    if ($PSCmdlet.ShouldProcess($entry, 'Install font')) {
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        # Machine scope registers by filename; user scope needs the full path.
        $value = if ($Scope -eq 'Machine') { $file.Name } else { $dest }
        New-ItemProperty -Path $RegKey -Name $entry -Value $value -PropertyType String -Force | Out-Null
        Write-Note "+ $entry"
        $installed++
    }
}

if ($installed -or $skipped) {
    Write-Ok "$installed installed, $skipped already present"
}

if ($installed -and -not $WhatIfPreference) {
    Invoke-FontChangeBroadcast
    Write-Note 'Broadcast WM_FONTCHANGE'
}

# --- 5. Clean up --------------------------------------------------------------

if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 6. Point every PowerShell surface at the font ----------------------------

# The family name terminals want, not the per-face full name.
$FamilyName = switch ($Variant) {
    'Mono'  { "$Font Nerd Font Mono" }
    'Propo' { "$Font Nerd Font Propo" }
    default { "$Font Nerd Font" }
}

if (-not $SetTerminalFont) {
    Write-Host ''
    Write-Note "Set your terminal font to: $FamilyName"
    Write-Note 'Or re-run with -SetTerminalFont to apply it everywhere.'
    return
}

Write-Step "Pointing terminals at '$FamilyName'"

# 6a. Windows Terminal - covers every profile and every future tab.
$wtSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'

if (-not (Test-Path -LiteralPath $wtSettings)) {
    Write-Note 'Windows Terminal: not installed, skipped'
}
elseif ($PSCmdlet.ShouldProcess($wtSettings, "Set default font to '$FamilyName'")) {
    $backup = "$wtSettings.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $wtSettings -Destination $backup -Force

    $raw = Get-Content -LiteralPath $wtSettings -Raw
    if ($raw -match '(?m)^\s*//') {
        Write-Warning 'settings.json contains comments; the rewrite drops them (backup keeps them).'
    }

    $json = $raw | ConvertFrom-Json
    if (-not $json.profiles)          { $json | Add-Member profiles ([pscustomobject]@{}) -Force }
    if (-not $json.profiles.defaults) { $json.profiles | Add-Member defaults ([pscustomobject]@{}) -Force }
    $json.profiles.defaults | Add-Member font ([pscustomobject]@{ face = $FamilyName }) -Force

    $json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $wtSettings -Encoding utf8
    Write-Ok "Windows Terminal: all profiles -> $FamilyName"
    Write-Note "  backup: $backup"
}

# 6b. Legacy console (conhost) - the window you get launching pwsh.exe directly.
#     conhost will only offer fonts listed under the HKLM allow-list below, and
#     adding to it needs elevation. The HKCU default is set either way.
if ($PSCmdlet.ShouldProcess('HKCU:\Console', "Set FaceName to '$FamilyName'")) {
    Set-ItemProperty -Path 'HKCU:\Console' -Name 'FaceName'   -Value $FamilyName
    Set-ItemProperty -Path 'HKCU:\Console' -Name 'FontFamily' -Value 54 -Type DWord   # 54 = TrueType
    Set-ItemProperty -Path 'HKCU:\Console' -Name 'FontWeight' -Value 400 -Type DWord
    Write-Ok "Legacy console: default face -> $FamilyName"

    $ttKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Console\TrueTypeFont'
    $listed = if (Test-Path $ttKey) {
        (Get-ItemProperty $ttKey).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' -and $_.Value -eq $FamilyName }
    }

    if ($listed) {
        Write-Note '  already in the console font allow-list'
    }
    elseif ($IsAdmin) {
        # Keys are sequential strings of zeroes: "0", "00", "000", ...
        $existing = (Get-ItemProperty $ttKey).PSObject.Properties |
                        Where-Object Name -match '^0+$' | Select-Object -Expand Name
        $slot = '0' * (($existing | Measure-Object -Property Length -Maximum).Maximum + 1)
        New-ItemProperty -Path $ttKey -Name $slot -Value $FamilyName -PropertyType String -Force | Out-Null
        Write-Note "  added to the console font allow-list (slot '$slot')"
    }
    else {
        Write-Warning "  conhost may not offer '$FamilyName' until it is added to:"
        Write-Note    "    $ttKey"
        Write-Note    '    Re-run elevated to add it. Windows Terminal is unaffected.'
    }
}

# 6c. VS Code integrated terminal.
$codeSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
if (-not (Test-Path -LiteralPath $codeSettings)) {
    Write-Note 'VS Code: not installed, skipped'
}
elseif ($PSCmdlet.ShouldProcess($codeSettings, "Set terminal font to '$FamilyName'")) {
    $backup = "$codeSettings.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $codeSettings -Destination $backup -Force

    $raw = Get-Content -LiteralPath $codeSettings -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
    $json = $raw | ConvertFrom-Json
    $json | Add-Member 'terminal.integrated.fontFamily' $FamilyName -Force

    $json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $codeSettings -Encoding utf8
    Write-Ok "VS Code: terminal font -> $FamilyName"
    Write-Note "  backup: $backup"
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
}
