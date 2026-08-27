#Requires -Version 7.0

<#
.SYNOPSIS
    Turns on the Windows Terminal half of shell integration, so it acts on the
    OSC marks the prompt already emits.

.DESCRIPTION
    The profile's prompt writes invisible OSC 133 sequences saying where a
    prompt starts, where typing starts, and how the last command ended, plus an
    OSC 9;9 report of the working directory. Windows Terminal ignores all of
    that until the settings below are switched on. Together they give:

      - a mark in the scrollbar for every command, red where one failed
      - Ctrl+Up / Ctrl+Down to jump between commands
      - select a whole command, or its whole output, from the right-click menu
      - new tabs and panes opening in the current working directory
      - recent commands in the suggestions UI

    Marks are a stable feature from Terminal 1.21; earlier builds had them
    behind 'experimental.' prefixes and are not handled here.

    The script is idempotent - settings already present are left alone, and a
    key chord already bound to something else is reported rather than stolen.
    The settings file is backed up before it is written.

.PARAMETER SettingsPath
    Point at a different settings.json - useful for the Terminal Preview build,
    or for trying the change against a copy first.

.PARAMETER JumpKeys
    The two chords bound to jumping between marks. Defaults to Ctrl+Up and
    Ctrl+Down. Pass an empty array to add the actions without binding keys.

.EXAMPLE
    .\Enable-ShellIntegration.ps1
    Enable it for the installed Windows Terminal.

.EXAMPLE
    .\Enable-ShellIntegration.ps1 -WhatIf
    Show what would change without writing anything.

.LINK
    https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SettingsPath,

    [string[]] $JumpKeys = @('ctrl+up', 'ctrl+down')
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param($Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param($Message) Write-Host "    $Message" -ForegroundColor DarkGray }

# --- 1. Locate settings.json --------------------------------------------------

Write-Step 'Locating Windows Terminal settings'

if (-not $SettingsPath) {
    $SettingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
}

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    throw "Windows Terminal settings not found: $SettingsPath"
}
Write-Ok $SettingsPath

# Comments are legal in this file and ConvertFrom-Json discards them, so a
# round-trip would silently delete any the user has written. Say so rather than
# eating them.
$raw = Get-Content -LiteralPath $SettingsPath -Raw
if ($raw -match '(?m)^\s*//' -or $raw -match '/\*') {
    Write-Warning 'settings.json contains comments. Rewriting it will drop them; the backup keeps the original.'
}

$json    = $raw | ConvertFrom-Json
$changes = [System.Collections.Generic.List[string]]::new()

# --- 2. Profile defaults ------------------------------------------------------

Write-Step 'Profile defaults'

if (-not $json.profiles.defaults) {
    $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) -Force
}

$defaults = [ordered]@{
    showMarksOnScrollbar                 = $true  # the marks themselves
    autoMarkPrompts                      = $true  # required for pwsh/cmd/bash integration
    'experimental.rightClickContextMenu' = $true  # right-click to select a command or its output
}

foreach ($name in $defaults.Keys) {
    if ($json.profiles.defaults.PSObject.Properties.Name -contains $name) {
        Write-Note "$name already set"
        continue
    }
    $json.profiles.defaults | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name] -Force
    $changes.Add("profiles.defaults.$name = $($defaults[$name])")
    Write-Ok "$name = $($defaults[$name])"
}

# --- 3. Actions ---------------------------------------------------------------

Write-Step 'Actions'

# Recent Terminal versions split an action (which carries an id) from the
# keybinding that refers to that id, so new actions are added the same way.
$wanted = @(
    [pscustomobject]@{ command = [pscustomobject]@{ action = 'scrollToMark';  direction = 'previous' }; id = 'User.scrollToMark.previous' }
    [pscustomobject]@{ command = [pscustomobject]@{ action = 'scrollToMark';  direction = 'next'     }; id = 'User.scrollToMark.next' }
    [pscustomobject]@{ command = [pscustomobject]@{ action = 'selectOutput';  direction = 'prev'     }; id = 'User.selectOutput.prev' }
    [pscustomobject]@{ command = [pscustomobject]@{ action = 'selectOutput';  direction = 'next'     }; id = 'User.selectOutput.next' }
    [pscustomobject]@{ command = [pscustomobject]@{ action = 'selectCommand'; direction = 'prev'     }; id = 'User.selectCommand.prev' }
    [pscustomobject]@{ command = [pscustomobject]@{ action = 'selectCommand'; direction = 'next'     }; id = 'User.selectCommand.next' }
)

$actions   = [System.Collections.Generic.List[object]]::new()
$knownIds  = @{}
foreach ($action in @($json.actions)) {
    $actions.Add($action)
    if ($action.id) { $knownIds[$action.id] = $true }
}

foreach ($action in $wanted) {
    if ($knownIds.ContainsKey($action.id)) { Write-Note "$($action.id) already present"; continue }
    $actions.Add($action)
    $changes.Add("action $($action.id)")
    Write-Ok $action.id
}
$json | Add-Member -NotePropertyName actions -NotePropertyValue @($actions) -Force

# --- 4. Keybindings -----------------------------------------------------------

Write-Step 'Keybindings'

# Only jumping between marks gets a chord. selectOutput and selectCommand stay
# reachable from the right-click menu rather than claiming more of the keyboard.
$jumpIds  = @('User.scrollToMark.previous', 'User.scrollToMark.next')

$bindings = [System.Collections.Generic.List[object]]::new()
$usedKeys = @{}
$boundIds = @{}
foreach ($binding in @($json.keybindings)) {
    $bindings.Add($binding)
    if ($binding.keys) { $usedKeys[$binding.keys] = $true }
    if ($binding.id)   { $boundIds[$binding.id] = $true }
}

for ($i = 0; $i -lt $JumpKeys.Count -and $i -lt $jumpIds.Count; $i++) {
    $key = $JumpKeys[$i]
    $id  = $jumpIds[$i]

    if ($boundIds.ContainsKey($id)) { Write-Note "$id already bound"; continue }
    if ($usedKeys.ContainsKey($key)) {
        Write-Warning "$key is already bound to something else; leaving it. Bind $id by hand if you want it."
        continue
    }

    $bindings.Add([pscustomobject]@{ id = $id; keys = $key })
    $changes.Add("$key -> $id")
    Write-Ok "$key -> $id"
}
$json | Add-Member -NotePropertyName keybindings -NotePropertyValue @($bindings) -Force

# --- 5. Write -----------------------------------------------------------------

if ($changes.Count -eq 0) {
    Write-Step 'Nothing to do'
    Write-Ok 'Shell integration is already configured.'
    return
}

Write-Step 'Writing settings'

if (-not $PSCmdlet.ShouldProcess($SettingsPath, "Apply $($changes.Count) shell integration change(s)")) {
    $changes | ForEach-Object { Write-Note "would add: $_" }
    return
}

$backup = '{0}.backup-{1}' -f $SettingsPath, (Get-Date -Format 'yyyy-MM-dd_HHmmss')
Copy-Item -LiteralPath $SettingsPath -Destination $backup
Write-Ok "Backed up to $backup"

$json | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $SettingsPath -Encoding utf8
Write-Ok "Applied $($changes.Count) change(s)"

Write-Step 'Done'
Write-Note 'Open a new tab for the settings to take effect.'
Write-Note 'Ctrl+Up / Ctrl+Down jump between commands; right-click a command to select it or its output.'
