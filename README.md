# scripts

A repository with all my scripts. See [CLAUDE.md](CLAUDE.md) for repo layout and
conventions for writing/maintaining scripts. This file documents what each script
does, how to configure it, and its requirements.

## scripts/archive/archive_directory.ps1

Windows-side helper that recursively compresses a directory's contents into a
single `.7z` archive using 7-Zip's strongest lossless settings (LZMA2, `-mx=9`,
`-mfb=273`, a large dictionary, solid, sort-by-type) and drops it in the current
user's Downloads folder as `YYYY-MM-DD.7z` (today's local date). Names are stored
relative to the directory, so archiving `C:\projects\foo` puts `bar\baz` at the
archive root, not `foo\bar\baz`.

```powershell
# archives the contents of C:\projects\foo -> %USERPROFILE%\Downloads\2026-09-05.7z
.\scripts\archive\archive_directory.ps1 C:\projects\foo
```

- `-Path <dir>` (position 0, required) — the directory whose contents to
  archive; relative or absolute. The directory's own name is not kept as a path
  prefix inside the archive; an empty directory is rejected.
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
archive already exists, and errors out if *every* repo fails. If only *some*
repos fail, the archive is still created from the rest, the failures are listed
on stderr, and the script **exits 1** so an incomplete backup is never mistaken
for a good one.

```bash
./scripts/git/github_backup.sh                                   # back up OWNER's repos into $PWD
OWNER=someone OUTPUT_DIR=~/backups ./scripts/git/github_backup.sh
```

Takes no arguments; `-h, --help` prints the usage and any other argument is
rejected.

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

Windows-side helper (not run from WSL/bash) that runs a batch of maintenance
and health tasks in one pass — Windows Update, winget, DISM/SFC repair, Disk
Cleanup, WSL disk compaction, a disk / event-log health check, drive
optimization and a Defender update + scan, plus driver updates with
`-DriverUpdate` — and prints an `OK` / `WARN` / `FAIL` / `SKIP` summary at the
end. Steps are independent — one failing does not abort the rest — and the
script exits non-zero if any step failed. `WARN` means a step finished but found
something worth a look (a health finding, a guard that held work back); it does
not fail the run. It never reboots.

**It asks before doing anything.** The script first prints what it is about to
do, with the destructive parts (Disk Cleanup empties the Recycle Bin; component
store cleanup drops superseded component versions) and the disruptive parts
(`wsl --shutdown` ends every running WSL session and anything that depends on it,
including a WSL shell you may have started the script from; winget may close
running apps) called out, and asks `Proceed? [y/N]`. Declining exits without
changing anything. `-Yes` skips the question (the plan is still printed) and is
required for unattended runs — a non-interactive session without it declines.
After you confirm, it warns about an already-pending reboot and nearly-full
volumes, and creates a System Restore point (`-SkipRestorePoint` to skip;
Windows declines if System Protection is off or one was made in the last 24
hours — the script says so and carries on).

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

It does **not** require elevation to start. Everything except the winget user
pass needs Administrator; if any such step is going to run and the session is
not elevated, the script **relaunches itself elevated in a new console** (one
UAC prompt, after the confirmation above), runs there, mirrors that run's exit
code, and leaves the window open at the end so the summary is readable.
`-NoElevate` suppresses the relaunch — those steps are then marked `SKIP` (not
`FAIL`) and the run exits non-zero. The winget user pass always runs de-elevated
(if the script is already elevated, e.g. via `sudo pwsh -File ...`, it is
launched with a basic-user token through `runas /trustlevel`). An explicit
`-Skip…` always wins over both.

```powershell
# full pass — asks to confirm, then prompts for elevation if not already admin
.\scripts\maintenance\windows_maintenance.ps1

# also install Windows Update driver updates (verified/WHQL only)
.\scripts\maintenance\windows_maintenance.ps1 -DriverUpdate

# leave WSL alone (no wsl --shutdown, no compaction; a running WSL keeps Microsoft.WSL held back)
.\scripts\maintenance\windows_maintenance.ps1 -SkipWslCompact

# full Defender scan instead of a quick one (can take hours)
.\scripts\maintenance\windows_maintenance.ps1 -DefenderFullScan

# skip the slow ones
.\scripts\maintenance\windows_maintenance.ps1 -SkipWindowsUpdate -SkipDefrag -SkipIntegrity

# no elevation, no UAC prompt, no question: just the user-scope winget pass
.\scripts\maintenance\windows_maintenance.ps1 -NoElevate -Yes -SkipWindowsUpdate -SkipIntegrity -SkipDiskCleanup -SkipWslCompact -SkipHealthCheck -SkipDefrag -SkipDefender
```

1. **Windows Update** — installs all applicable *software* updates via the
   [`PSWindowsUpdate`](https://www.powershellgallery.com/packages/PSWindowsUpdate)
   module (`Get-WindowsUpdate -UpdateType Software -MicrosoftUpdate -AcceptAll
   -Install -IgnoreReboot`). `-MicrosoftUpdate` includes Office and other
   Microsoft products; the Microsoft Update service is registered on first use
   (the same switch as Settings → "Receive updates for other Microsoft
   products"), and if that fails the step carries on with Windows Update only.
   Drivers are excluded here — they only come with `-DriverUpdate` (step 2).
   If the module is missing it is installed from the PSGallery on first run
   (`Install-Module`, `CurrentUser` scope; the NuGet provider is bootstrapped
   first, and PSGallery may prompt once to trust it on a locked-down host).
   Automatic reboots are suppressed; a resulting pending reboot is reported in
   the summary only.
2. **Driver updates** *(only with `-DriverUpdate`)* — `Get-WindowsUpdate
   -UpdateType Driver -Install` via the same PSWindowsUpdate module as step 1.
   This is the "verified drivers only" path: every driver on Windows Update is
   WHQL-certified and submitted by the hardware vendor through Microsoft's
   Hardware Dev Center — unlike Driver Booster and similar, which pull from
   their own unvetted repositories. Off by default (driver updates carry more
   regression risk); reboots suppressed and reported like step 1.
3. **winget** — two passes: first a **user** pass, run de-elevated with
   `--scope user`, then a **system** pass, run elevated with no scope filter (so
   it picks up machine-scope packages and anything the user pass couldn't
   upgrade). Each is `winget upgrade --all --include-unknown` with
   `--accept-source-agreements --accept-package-agreements
   --disable-interactivity`. winget's "no applicable upgrades" result
   (`0x8A15002B`) counts as success; any other non-zero exit fails that pass.
   Packages listed in `winget_ignore.txt`, next to the script, are
   `--exclude`d from the upgrade — copy
   [`winget_ignore.sample.txt`](scripts/maintenance/winget_ignore.sample.txt)
   to `winget_ignore.txt` (same folder) and list one winget package `Id` per
   line (`#` comments and blank lines allowed); the file is optional and
   nothing is excluded on its account if it's absent.
   WSL and winget: upgrading `Microsoft.WSL` runs `wsl --shutdown`. Because
   the up-front confirmation already covers a WSL shutdown (unless you pass
   `-SkipWslCompact`), the package is upgraded normally. With `-SkipWslCompact`
   no shutdown is approved, so if a WSL distro is running (checked via
   `vmmemWSL` / `wsl -l --running`) `Microsoft.WSL` is `--exclude`d instead and
   the summary notes it was held back. On a winget too old for `--exclude`: a
   configured ignore list is skipped with a warning (upgrade proceeds), but a
   pending WSL upgrade instead marks the whole step `SKIP`, since dropping a
   live session is worse than an unexcluded package.
4. **System file integrity** — `DISM /Online /Cleanup-Image /RestoreHealth`
   (scans the component store and repairs it only if damaged), then
   `sfc /scannow`. The sfc outcome is read from the `[SR]` entries in `CBS.log`
   rather than its localised console text; anything it can't determine is a
   `WARN`, never a silent "clean". Unrepairable corruption is a `FAIL`. Runs
   before Disk Cleanup because the repair needs the component store intact.
5. **Disk Cleanup (all fixed drives) + component store** — writes
   `StateFlags<profile>` for every Disk Cleanup handler under
   `...\Explorer\VolumeCaches` **except** four that are unsafe to automate:
   "Downloads Folder", "Previous Installations" (Windows.old, the OS rollback),
   "Device Driver Packages" (driver rollback) and "Windows ESD installation
   files" (local *Reset this PC*). It runs `cleanmgr /sagerun:<profile>` and
   waits for it, then `DISM /Online /Cleanup-Image /StartComponentCleanup` to
   trim WinSxS, and reports the free-space change per drive. cleanmgr runs
   against every fixed drive, not just C:, and **this empties the Recycle Bin**.
   The step continues (DISM only) if `cleanmgr.exe` is absent (Server SKUs).
6. **WSL disk compaction** — WSL 2 distro disks (`ext4.vhdx`) grow but never
   shrink on their own. This step runs `fstrim` inside each distro (so freed
   blocks are reclaimable), runs `wsl --shutdown` (approved in the up-front
   confirmation), then compacts each distro's `.vhdx` with Hyper-V's
   `Optimize-VHD -Mode Full` and reports the space reclaimed. WSL is left
   stopped and restarts on next use. It runs before the optimize step so the
   freed space gets retrimmed. Every guard is checked *before* `wsl --shutdown`,
   so a machine that can't compact never has WSL shut down for nothing. A
   distro's disk is skipped (`WARN`, never `FAIL`) when: the host volume's disk
   isn't `Healthy`; the host volume has less than max(1 GB, 10% of the image)
   free; the image isn't on a local drive letter; or, after the shutdown, the
   image is attached or still locked (e.g. Docker Desktop restarted its
   backend). The whole step is `SKIP`ped, with WSL left running, if
   `Optimize-VHD` (the Hyper-V PowerShell module) is missing, the Hyper-V
   Virtual Machine Management service (`vmms`) isn't running, or WSL is
   installed but no WSL 2 disk is found; and it `WARN`s without compacting if
   WSL hasn't fully stopped within 60 seconds. Docker Desktop's own distros
   (`docker-desktop*`) are compacted but not `fstrim`med. WSL 1 distros have no
   disk image and are ignored. **A power loss or crash mid-compaction can
   corrupt a distro disk — keep backups (`wsl --export`).** Distros are read
   from the current user's registry (`HKCU`), so this needs the same account
   elevated, not a different admin account.
7. **Health check** *(report only — nothing is repaired)* — physical disk
   health and SSD wear / temperature / uncorrected-error counters
   (`Get-PhysicalDisk`, `Get-StorageReliabilityCounter`); an online filesystem
   scan per NTFS/ReFS volume (`Repair-Volume -Scan`); low free space; the last
   7 days of disk / NTFS / volume / WHEA hardware errors, unexpected shutdowns
   (Kernel-Power 41) and bugchecks from the System event log; the last few boot
   times; and the list of startup entries. An unhealthy disk or volume, or a
   filesystem scan that reports errors, is a `FAIL`; softer findings (under 10%
   free, wear ≥ 80%, ≥ 70 °C, uncorrected errors, recent hardware error events,
   unexpected shutdowns) are `WARN`s. Full detail is in the step's window and
   `output.log`.
8. **Optimize / defrag all volumes** — `Optimize-Volume` on every fixed
   NTFS/ReFS volume with a drive letter, with no operation switch so Windows
   picks the media-appropriate action per volume (defrag on HDD, retrim on SSD),
   same as the built-in "Optimize Drives" task / `defrag /O`. A volume whose
   disk reports anything but `Healthy` is skipped (`WARN`) — back it up first.
9. **Microsoft Defender** — `Update-MpSignature`, then a quick scan (a full
   scan with `-DefenderFullScan`), then reports signature age, real-time
   protection and threats. An active threat is a `FAIL`; a detection Defender
   already handled during the scan, stale signatures (> 3 days) or real-time
   protection being off are `WARN`s. `SKIP`ped when Defender isn't the active
   antivirus (a third-party product has put it in passive mode).

- `-Yes` — skip the up-front `Proceed? [y/N]` question (the plan is still
  printed). Required for unattended runs.
- `-DriverUpdate` — add step 2 (Windows Update driver updates). Off by default.
- `-DefenderFullScan` — make step 9 a Defender full scan instead of a quick one.
- `-SkipWindowsUpdate`, `-SkipWinget`, `-SkipIntegrity`, `-SkipDiskCleanup`,
  `-SkipWslCompact`, `-SkipHealthCheck`, `-SkipDefrag`, `-SkipDefender` — skip
  the matching step. An explicit skip wins over the elevation logic: if it
  leaves no admin-only step to run, there is no relaunch and no non-zero exit.
  `-SkipWslCompact` also means the script does not shut WSL down (see step 3).
- `-SkipRestorePoint` — don't create a System Restore point before the run.
- `-SagerunProfile <0-65535>` — the Disk Cleanup sageset/sagerun profile number
  used for the `StateFlags` values and `cleanmgr /sagerun:N`; default `100`.
  Change it only if that profile number is already in use on the box.
- `-KeepStepWindows` — keep every per-step console window open until dismissed
  (press Enter), instead of auto-closing after a successful step.
- `-NoElevate` — never relaunch elevated; skip the admin-only steps instead
  (exit non-zero). For unattended runs where a UAC prompt can't be answered.
- `-Relaunched`, `-AllowWslShutdown`, `-RunStep`, `-RunDir` — internal, set by
  the script when it relaunches itself (for elevation) or launches a step's
  window; don't pass them by hand.

Written for desktops: there are no battery / AC-power checks.

Requires: Windows 10/11 (or matching Server), PowerShell 5.1+. No
`#Requires -RunAsAdministrator` — the script self-elevates when an admin-only
step is due (or, with `-NoElevate`, skips it). Internet access for steps 1–4
(and 9's signature update); `winget` (App Installer) on `PATH`; `cleanmgr.exe`,
`DISM`, `sfc` and the Storage / Defender modules (all in-box, though cleanmgr is
an optional Feature on Server). For step 6: `wsl.exe`, the Hyper-V PowerShell
module (`Optimize-VHD` / `Get-VHD`, i.e. the
`Microsoft-Hyper-V-Management-PowerShell` feature) and the Hyper-V Virtual
Machine Management service running — without them the step skips itself and
leaves WSL alone. The restore point needs System Protection enabled on the
system drive. `winget_ignore.txt` next to the script is optional (see step 3
above). PSScriptAnalyzer note: `Get-Date`, `Get-Volume`, `Optimize-Volume`,
`Get-WindowsUpdate` etc. are Windows-only and not resolvable on the Linux CI
linter, which is fine — the default ruleset does not check command existence.

## scripts/nix/update_flakes.sh

Recursively searches `~/repos` for every `flake.nix`, runs `nix flake update`
next to each, and commits the resulting `flake.lock` change as
`chore(flake): sync YYYY-MM-DD` (today's local date). **Never pushes.** The search
descends through plain folders, so `~/repos/homelab/foo` is found even though
`homelab` is neither a repo nor a flake. `.git`, `node_modules` and `.direnv` are
not searched.

```bash
update_flakes.sh                                  # update everything under ~/repos
update_flakes.sh homelab ~/repos/foo ../bar       # ...but leave those out
```

- `[IGNORE...]` (positional, any number) — directories to exclude, along with
  everything beneath them. Each may be an absolute path (a quoted `~/...` is
  expanded), a path relative to the current directory or to the search root
  (`homelab/lab`), or a bare name, which matches any directory with that name
  under the search root.
- `REPOS_DIR` — env var; directory to search instead of `~/repos`.
- `-h, --help` — print the header comment.

Safety behaviour: each repo gets one commit containing only its `flake.lock`
file(s) — other staged/unstaged changes are left alone and no commit is made if
the lock didn't change. A flake is skipped (listed in the summary) if it isn't in
a git repo, is in a linked worktree (only the main checkout is updated), has a
gitignored `flake.lock`, or already has uncommitted `flake.lock` changes. Failures
in one flake/repo don't stop the rest; the script exits non-zero if any failed.

Requires: `nix` (flakes enabled), `git`, `find`, `realpath`.

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
