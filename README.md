# scripts

A repository with all my scripts. See [CLAUDE.md](CLAUDE.md) for repo layout and
conventions for writing/maintaining scripts. This file documents what each script
does, how to configure it, and its requirements.

## scripts/git/github_backup.sh

Backs up every repo (public + private) owned by a fixed GitHub user into a single
timestamped `.7z` in `$OUTPUT_DIR` (default `$PWD`). For each repo: clones it, force-fetches
all tags, and creates local tracking branches for every remote branch, so the
resulting archive is a self-contained, browsable set of working trees — not a bare
mirror.

Requires: `gh` (authenticated — `gh auth status`), `git`, `7z`, `jq`.

Config lives at the top of the script (edit directly, no CLI flags):
- `OWNER` — GitHub user/org to back up.
- `IGNORE_LIST` — `"owner/name"` entries to skip.
- `OUTPUT_DIR` — env var, defaults to `$PWD`.
- `GH_BACKUP_PASSWORD` — env var; if set, encrypts the archive (`7z -mhe=on`) and
  also hides file names/metadata.

### SSH / hardware key (Yubikey) note

If `gh`'s git protocol is SSH and the key is hardware-backed (e.g. a `_sk` resident
key), every `git`/`gh` operation opens a new SSH connection and re-triggers a
PIN/touch prompt — this script does clone + fetch per repo, so a large repo list
means a lot of prompts. Fix is SSH connection multiplexing (`ControlMaster` /
`ControlPersist`) scoped to `github.com` in SSH config, so one PIN/touch covers the
whole run. In this user's setup that config is managed via home-manager in the
`nixos-config` repo (`home/modules/tools/ssh.nix`), not here — `~/.ssh/config` is a
generated symlink into the Nix store and shouldn't be edited directly.

## scripts/wsl/attach_yubikey.ps1

Windows-side helper (not run from WSL/bash) that finds a connected YubiKey via
`usbipd list` (matched on VID:PID `1050:0407`) and attaches it to WSL with
`usbipd attach --wsl --busid <id>`. Skips the attach if the device is already in
the `Attached` state, and no-ops with a message if no matching device is found.

Requires: [usbipd-win](https://github.com/dorssel/usbipd-win), run from an elevated
PowerShell prompt (`usbipd attach` needs Administrator).

Run manually whenever the YubiKey needs to (re)appear inside WSL, e.g. after a
replug or reboot — not scheduled or hooked into anything automatically. To
automate this, see `register_yubikey_attach_task.ps1` below.

## scripts/wsl/register_yubikey_attach_task.ps1

Windows-side, run once (and re-run any time to update): idempotently registers a
Scheduled Task (`AttachYubiKeyToWSL`) that runs `attach_yubikey.ps1` whenever any
USB device is connected, so plugging in the YubiKey auto-attaches it to WSL with
no manual step.

- Trigger: event `2003` (device connected) in
  `Microsoft-Windows-DriverFrameworks-UserMode/Operational` — fires for any USB
  device, not just the YubiKey; `attach_yubikey.ps1` itself no-ops on a mismatch,
  so the broad trigger is safe. The script enables that event log if it's off.
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
  window briefly, since conhost creates it before the flag takes effect.
- Idempotent: `Register-ScheduledTask -Force` replaces any existing task of the
  same name, so re-running after editing either script (or moving the repo) just
  updates the registered task in place.

Requires: Windows Task Scheduler (`ScheduledTasks` module, built in), run from an
elevated PowerShell prompt. Expects `attach_yubikey.ps1` to already be deployed at
`%USERPROFILE%\Documents\Scripts\attach_yubikey.ps1` — copy it there before
running this script (that fixed path is resolved once at registration time and
baked into the task's action).
