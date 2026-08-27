# PowerShell Profile

A PowerShell 7 profile for Windows, plus the scripts that install it.

- **Powerline prompt** — elevation, SSH, user, path, git state, environment, background jobs, failed exit codes, command duration and the time, each segment appearing only when it has something to say. Needs a Nerd Font.
- **Predictive autocomplete** — suggestions from command history and from predictor plugins, shown as a list.
- **Shell integration** — Windows Terminal gets command marks in the scrollbar, jump-between-commands, and new tabs that open in the current directory.
- **Session transcripts** — every session logged to `~\Shell Logs`.
- **Helpers** — `md5` / `sha1` / `sha256` / `md5sum`, `touch`, `explore`, `download`, `geturl`, `admin`.

| File | What it does |
|---|---|
| `Microsoft.PowerShell_profile.ps1` | The profile itself |
| `Deploy-Profile.ps1` | Installs everything |
| `Install-NerdFont.ps1` | Installs a Nerd Font and points terminals at it |
| `Save-DeployCache.ps1` | Downloads what an offline install needs |
| `Enable-ShellIntegration.ps1` | Turns on Windows Terminal shell integration |

**Requires** Windows and PowerShell 7 (`pwsh`). Run everything from `pwsh`, not `powershell`.

---

## 1. Installation (online)

```powershell
.\Deploy-Profile.ps1
```

That installs the FiraCode Nerd Font, points Windows Terminal, the legacy console and VS Code at it, installs the autocomplete predictor module, symlinks the profile into place, moves aside any stale Windows PowerShell 5.1 profile, and checks the result loads.

Then, optionally, for the Windows Terminal features:

```powershell
.\Enable-ShellIntegration.ps1
```

Open a new tab to pick it all up.

The profile is **symlinked** by default, so a `git pull` updates the live copy with no redeploy. That needs Developer Mode or an elevated shell; without either it falls back to a copy and tells you, in which case re-run the script after each pull.

Useful switches:

```powershell
.\Deploy-Profile.ps1 -WhatIf          # show what would happen, change nothing
.\Deploy-Profile.ps1 -Pull            # git pull --ff-only first
.\Deploy-Profile.ps1 -SkipFont        # leave fonts alone
.\Deploy-Profile.ps1 -Mode Copy       # copy instead of symlink
```

Every step is idempotent and backs up whatever it replaces, so re-running is safe.

---

## 2. Installation (offline)

Only two things need the network: the font (GitHub) and the predictor module (PSGallery). Cache them on a connected machine first, then carry the folder across.

**On a machine with internet:**

```powershell
.\Deploy-Profile.ps1 -Prepare
```

This fills `cache\` with a PowerShell 7 installer, the font archive and the predictor module — about 136 MB — and writes `cache\INSTALL.txt` with the steps below in plain text.

Add `-SkipPowerShell` to leave out the installer (saves ~108 MB) if the target already has PowerShell 7. For a repeatable bundle, pin the versions:

```powershell
.\Save-DeployCache.ps1 -PowerShellVersion v7.6.5 -Version v3.5.1
```

**Copy the whole folder** — cache and all — to the offline machine.

**On the offline machine:**

```powershell
msiexec /i "cache\powershell\PowerShell-7.6.5-win-x64.msi" /qn   # skip if pwsh 7 is present
```

Then from `pwsh`, in the repo folder:

```powershell
.\Deploy-Profile.ps1 -Offline
.\Enable-ShellIntegration.ps1     # optional
```

`-Offline` installs strictly from the cache and refuses rather than quietly reaching for the network. The cached font is checked against a SHA256 recorded at capture time, so a copy truncated in transit is caught before anything is installed.

> The cache is **not** committed to git — a font archive and an MSI are not something to push. Move the folder, don't clone it.

---

## Notes

`Deploy-Profile.ps1 -Offline` cannot install PowerShell itself: it requires version 7 to run at all, so on a bare machine the MSI goes first. That is why `cache\INSTALL.txt` exists — it is readable without PowerShell 7 present.

Run `Get-Help .\Deploy-Profile.ps1 -Full` (or on any of the scripts) for the complete options.
