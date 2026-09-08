# scripts

A repository with all my scripts. See [CLAUDE.md](CLAUDE.md) for repo layout and
conventions for writing/maintaining scripts. This file documents what each script
does, how to configure it, and its requirements.

## scripts/archive/archive_directory.ps1

Windows-side helper that recursively compresses a directory into a single `.7z`
archive using 7-Zip's strongest lossless settings (LZMA2, `-mx=9`, `-mfb=273`, a
large dictionary, solid, sort-by-type) and drops it in the current user's
Downloads folder as `YYYY-MM-DD.7z` (today's local date). The named directory
becomes the archive's top-level entry.

```powershell
# archives C:\projects\foo -> %USERPROFILE%\Downloads\2026-09-05.7z
.\scripts\archive\archive_directory.ps1 C:\projects\foo
```

- `-Path <dir>` (position 0, required) — the directory to archive; relative or
  absolute.
- `-DestinationDirectory <dir>` — where to write the archive; defaults to the
  Downloads known folder (registry-resolved, falling back to
  `%USERPROFILE%\Downloads`).
- `-DictionarySize <size>` — LZMA2 dictionary (e.g. `128m`, `256m`, `512m`,
  `1g`); default `256m`. Bigger can compress better but needs roughly 10x that
  in RAM; 7-Zip auto-shrinks it to fit smaller inputs.
- `-Force` — replace an existing `YYYY-MM-DD.7z`; without it a `_2`, `_3`, …
  suffix is used.
- Supports `-WhatIf` / `-Confirm` (creates nothing under `-WhatIf`).

Requires: Windows, PowerShell 5.1+, and [7-Zip](https://www.7-zip.org) on `PATH`
(`7z`/`7za`) or installed under `%ProgramFiles%\7-Zip`. NTFS ACLs, alternate data
streams, and creation/access timestamps are not captured — see the script's
`.NOTES` for the switches to add if you need them.

## scripts/git/github_backup.sh

Backs up every repo (public + private) owned by `OWNER` into a single timestamped
(UTC) `.7z` in `$OUTPUT_DIR` (default `$PWD`). For each repo: clones it,
force-fetches all tags, checks out submodules, and creates local tracking
branches for every remote branch, so the resulting archive is a self-contained,
browsable set of working trees — not a bare mirror. After creation the archive
is verified (`7z t`) and `chmod 600`ed; the run aborts up front if the target
archive already exists, and errors out if *every* repo fails.

Requires: `gh` (authenticated — `gh auth status`), `git`, `7z`, `jq`.

Config: `OWNER` and `IGNORE_LIST` sit at the top of the script; everything else
is an env var.
- `OWNER` — GitHub user/org to back up. Defaults to `evictedcucumber`; override
  with `OWNER=...` in the environment.
- `IGNORE_LIST` — `"owner/name"` entries to skip (edit the array in the script).
- `GH_BACKUP_IGNORE` — env var; extra `"owner/name"` entries (space/newline
  separated) appended to `IGNORE_LIST`.
- `OUTPUT_DIR` — env var, defaults to `$PWD`.
- `GH_BACKUP_PASSWORD` — env var; if set, encrypts the archive (`7z -mhe=on`) and
  also hides file names/metadata. Passed to `7z` as `-p...`, so it is briefly
  visible in the process list — only use on a trusted host.

### SSH / hardware key (Yubikey) note

If `gh`'s git protocol is SSH and the key is hardware-backed (e.g. a `_sk` resident
key), every `git`/`gh` operation opens a new SSH connection and re-triggers a
PIN/touch prompt — this script does clone + fetch per repo, so a large repo list
means a lot of prompts. Fix is SSH connection multiplexing (`ControlMaster` /
`ControlPersist`) scoped to `github.com` in SSH config, so one PIN/touch covers the
whole run. In this user's setup that config is managed via home-manager in the
`nixos-config` repo (`home/modules/tools/ssh.nix`), not here — `~/.ssh/config` is a
generated symlink into the Nix store and shouldn't be edited directly.

## scripts/maintenance/windows_maintenance.ps1

Windows-side helper (not run from WSL/bash) that runs four system-maintenance
tasks in one pass and prints an `OK` / `FAIL` / `SKIP` summary at the end. Steps
are independent — one failing does not abort the rest — and the script exits
non-zero if any step failed. It never reboots.

**Each step runs in its own console window.** The orchestrator re-invokes the
script with an internal `-RunStep <name>` per step, waits for it, and reads a
small JSON result back from a temp run directory (path printed at the start and
end of the run). That keeps each step's noisy output — winget's table redraws,
the DISM progress bar, `Optimize-Volume -Verbose` — in a separate window and a
per-step `output.log`, leaving the orchestrator window a clean
one-line-per-step progress list. A step window auto-closes a few seconds after
a successful step and stays open (waiting for Enter) on failure; the run
directory (`%TEMP%\windows_maintenance_<timestamp>\<Step>\`) is kept afterward.
`-KeepStepWindows` keeps every step window open. (`Start-Transcript` on
Windows PowerShell 5.1 may not capture native-EXE output in full — the live
window always shows everything.)

It does **not** require elevation to start. Windows Update, Disk Cleanup and
defrag need Administrator; if any of them is going to run and the session is not
elevated, the script **relaunches itself elevated in a new console** (one UAC
prompt), runs there, mirrors that run's exit code, and leaves the window open at
the end so the summary is readable. `-NoElevate` suppresses the relaunch — those
steps are then marked `SKIP` (not `FAIL`) and the run exits non-zero. The winget
step needs no elevation of its own (without it, only user-scope packages are
upgraded). An explicit `-Skip…` always wins over both.

```powershell
# full pass — prompts for elevation if not already admin
.\scripts\maintenance\windows_maintenance.ps1

# no elevation, no UAC prompt: just upgrade user-scope winget packages
.\scripts\maintenance\windows_maintenance.ps1 -NoElevate -SkipWindowsUpdate -SkipDiskCleanup -SkipDefrag

# skip the slow ones
.\scripts\maintenance\windows_maintenance.ps1 -SkipWindowsUpdate -SkipDefrag
```

1. **Windows Update** — installs all applicable updates via the
   [`PSWindowsUpdate`](https://www.powershellgallery.com/packages/PSWindowsUpdate)
   module (`Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot`). If the module
   is missing it is installed from the PSGallery on first run (`Install-Module`,
   `CurrentUser` scope; the NuGet provider is bootstrapped first, and PSGallery
   may prompt once to trust it on a locked-down host). Automatic reboots are
   suppressed; a resulting pending reboot is reported in the summary only.
2. **winget** — `winget upgrade --all --include-unknown` with
   `--accept-source-agreements --accept-package-agreements
   --disable-interactivity`. winget's "no applicable upgrades" result
   (`0x8A15002B`) counts as success. When elevated, any other non-zero exit
   fails the step; when not elevated it is downgraded to a warning (winget
   can't touch machine-scope packages without Administrator).
   If a WSL distro is running (checked via `vmmemWSL` / `wsl -l --running`),
   `Microsoft.WSL` is `--exclude`d from the upgrade — upgrading it runs
   `wsl --shutdown` and would drop live sessions; the summary notes it was
   held back. On a winget too old for `--exclude`, if a WSL upgrade is
   pending the whole step is marked `SKIP` instead.
3. **Disk Cleanup (C:) + component store** — writes `StateFlags<profile>` for
   every Disk Cleanup handler **except "Downloads Folder"** under
   `...\Explorer\VolumeCaches`, runs `cleanmgr /sagerun:<profile>` and waits for
   it, then `DISM /Online /Cleanup-Image /StartComponentCleanup` to trim WinSxS.
   cleanmgr runs against every fixed drive, not just C:, and **this empties the
   Recycle Bin**. The step continues (DISM only) if `cleanmgr.exe` is absent
   (Server SKUs).
4. **Optimize / defrag all volumes** — `Optimize-Volume` on every fixed
   NTFS/ReFS volume with a drive letter, with no operation switch so Windows
   picks the media-appropriate action per volume (defrag on HDD, retrim on SSD),
   same as the built-in "Optimize Drives" task / `defrag /O`.

- `-SkipWindowsUpdate`, `-SkipWinget`, `-SkipDiskCleanup`, `-SkipDefrag` — skip
  the matching step. An explicit skip wins over the elevation logic: if it
  leaves no admin-only step to run, there is no relaunch and no non-zero exit.
- `-SagerunProfile <0-65535>` — the Disk Cleanup sageset/sagerun profile number
  used for the `StateFlags` values and `cleanmgr /sagerun:N`; default `100`.
  Change it only if that profile number is already in use on the box.
- `-KeepStepWindows` — keep every per-step console window open until dismissed
  (press Enter), instead of auto-closing after a successful step.
- `-NoElevate` — never relaunch elevated; skip the admin-only steps instead
  (exit non-zero). For unattended runs where a UAC prompt can't be answered.
- `-Relaunched`, `-RunStep`, `-RunDir` — internal, set by the script when it
  relaunches itself (for elevation) or launches a step's window; don't pass
  them by hand.

Requires: Windows 10/11 (or matching Server), PowerShell 5.1+. No
`#Requires -RunAsAdministrator` — the script self-elevates when an admin-only
step is due (or, with `-NoElevate`, skips it). Internet access for steps 1–2;
`winget` (App Installer) on `PATH`; `cleanmgr.exe` and `DISM` (both in-box,
though cleanmgr is an optional Feature on Server). PSScriptAnalyzer note:
`Get-Date`, `Get-Volume`, `Optimize-Volume`, `Get-WindowsUpdate` etc. are
Windows-only and not resolvable on the Linux CI linter, which is fine — the
default ruleset does not check command existence.

## scripts/wsl/copy_to_downloads.sh

Run from inside WSL: copies a file or directory to the Windows user's Downloads
folder. The destination is read from the Windows "Shell Folders" registry entry
via `powershell.exe` (so a relocated Downloads is respected), falling back to
`%USERPROFILE%\Downloads` (`cmd.exe`) and then `/mnt/c/Users/$USER/Downloads`.
The item keeps its own name and lands as `<Downloads>/<name>`; timestamps are
preserved, mode/ownership are not (they don't map onto the Windows filesystem).

```bash
copy_to_downloads.sh ~/reports/2026-09        # -> C:\Users\me\Downloads\2026-09
copy_to_downloads.sh --force ./build/app.zip
```

- `<wsl-path>` (positional, required) — the file or directory to copy.
- `-d, --dest DIR` — destination directory instead of Downloads; accepts a WSL
  path or a Windows path (`C:\...`). Also settable via `WIN_DOWNLOADS_DIR`.
- `-f, --force` — replace an existing item of the same name (otherwise the copy
  is refused).
- `-v, --verbose` — pass `-v` to `cp`.

Requires: WSL (`wslpath`), coreutils; `powershell.exe` / `cmd.exe` for Downloads
autodetection (not needed when `--dest` / `WIN_DOWNLOADS_DIR` is given).

## scripts/wsl/attach_yubikey.ps1

Windows-side helper (not run from WSL/bash) that finds a connected YubiKey via
`usbipd list` (matched on VID:PID `1050:0407`) and attaches it to WSL with
`usbipd attach --wsl --busid <id>`. Skips the attach if the device is already
`Attached`; if the device has never been shared it runs `usbipd bind --busid
<id>` first (one-time, persistent). No-ops with a message if no matching device
is found, and exits non-zero if `usbipd list` itself fails.

Requires: [usbipd-win](https://github.com/dorssel/usbipd-win), run from an elevated
PowerShell prompt (`usbipd bind`/`attach` need Administrator).

Run manually whenever the YubiKey needs to (re)appear inside WSL, e.g. after a
replug or reboot — not scheduled or hooked into anything automatically. To
automate this, see `register_yubikey_attach_task.ps1` below.

## scripts/wsl/register_yubikey_attach_task.ps1

Windows-side, run once (and re-run any time to update): idempotently registers a
Scheduled Task (`AttachYubiKeyToWSL`) that runs `attach_yubikey.ps1` whenever any
USB device is connected, so plugging in the YubiKey auto-attaches it to WSL with
no manual step. Run with `-Remove` to unregister the task and delete the
generated VBScript wrapper (`attach_yubikey.ps1` is left in place).

- Expects `attach_yubikey.ps1` to already be deployed at
  `%USERPROFILE%\Documents\Scripts\attach_yubikey.ps1` — copy it there before
  running this. That fixed path is resolved once at registration time and baked
  into the task's action.
- Trigger: event `2003` (device connected) in
  `Microsoft-Windows-DriverFrameworks-UserMode/Operational` — fires for any USB
  device, not just the YubiKey; `attach_yubikey.ps1` itself no-ops on a mismatch,
  so the broad trigger is safe. The script enables that event log if it's off
  (via the API, falling back to `wevtutil` if the channel rejects the API write).
- Task settings cap each run at a 5-minute `ExecutionTimeLimit`, so a stuck
  `usbipd`/`wsl.exe` invocation can't block every later trigger.
- Runs as the registering user (`Interactive` logon, `Highest` run level), no
  password stored. It deliberately does **not** run as `SYSTEM`: `usbipd attach
  --wsl` shells out to `wsl.exe`, and Microsoft Store WSL cannot be launched
  from Session 0, so a `SYSTEM`/`ServiceAccount` task fires and "completes"
  with no error in Task Scheduler's history but silently fails to attach
  ([microsoft/WSL#9231](https://github.com/microsoft/WSL/issues/9231)). The
  tradeoff is the task only fires while that user is logged on interactively.
- The task's action runs `wscript.exe` against a small VBScript wrapper
  (`run_attach_yubikey_hidden.vbs`, generated into the same deployment
  directory) that launches `powershell.exe` via `WScript.Shell.Run` with a
  hidden window style, rather than invoking `powershell.exe -WindowStyle
  Hidden` directly from the task action — the latter still flashes a console
  window briefly, since conhost creates it before the flag takes effect. On
  each run the wrapper is validated (present, UTF-16LE, expected content) and
  rewritten only if it is missing, wrongly encoded, or out of date.
- Idempotent: `Register-ScheduledTask -Force` replaces any existing task of the
  same name, so re-running after editing either script (or moving the repo) just
  updates the registered task in place.

Requires: Windows Task Scheduler (`ScheduledTasks` module, built in), run from an
elevated PowerShell prompt. Expects `attach_yubikey.ps1` to already be deployed
at `%USERPROFILE%\Documents\Scripts\attach_yubikey.ps1` — copy it there before
running this script.
