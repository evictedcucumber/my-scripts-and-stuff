# my-scripts-and-stuff

A collection of standalone shell (and occasionally PowerShell) scripts, organized
by category under `scripts/`.

## Layout

```
configs/
  windows_sandbox/
    windows_sandbox.wsb   # Windows Sandbox config; maps this folder in (from ~/Downloads on the host) and runs sandbox_setup.ps1 at logon
    sandbox_setup.ps1     # runs inside the sandbox: dark mode + winget + Microsoft Store
scripts/
  archive/
    archive_directory.ps1   # max-compression 7z of a directory into ~/Downloads/YYYY-MM-DD.7z
  git/
    github_backup.sh     # backs up all repos for a GitHub owner into a 7z archive
    sync_archive_forks/
      flake.nix               # the script's own runtime env; the script re-execs itself in its devShell
      sync_archive_forks.sh   # clones/syncs every repo in a GitHub star list (forks synced to upstream on GitHub + locally), then cross-builds each main binary for Linux/Windows and releases them on your forks
  maintenance/
    windows_maintenance.ps1   # Windows Update + winget + DISM/SFC + Disk Cleanup + WSL disk compaction + health check + defrag + Defender + driver updates; no options - confirms once up front then runs unattended, each step in its own window, self-elevates via UAC
  nix/
    update_flakes.sh     # nix flake update + "chore(flake): sync YYYY-MM-DD" commit for every flake under ~/repos (no push)
  wsl/
    attach_yubikey.ps1                 # attaches a YubiKey to WSL via usbipd-win
    copy_to_downloads.sh               # copies a WSL file/dir to the Windows user's Downloads folder
    register_yubikey_attach_task.ps1   # registers a Scheduled Task that runs attach_yubikey.ps1 on USB connect
```

New scripts go in `scripts/<category>/`, named `snake_case.sh` (or `snake_case.ps1`
for Windows-only scripts, e.g. WSL/usbipd helpers that must run on the Windows
side). Each script should be runnable directly (`./scripts/<category>/name.sh`),
self-contained, and list its own requirements in a header comment — there is no
shared lib/framework here.

Things that aren't standalone scripts (config files for other tools, plus any
helper scripts that only make sense alongside them) go in `configs/<name>/`
instead. Any `.ps1`/`.sh` in there still follows the standards below and is
linted the same way.

Per-script usage, config, and requirements live in [README.md](README.md), not
here — add a section there for every new script. This file covers conventions
for writing/maintaining scripts, not how to use them.

## Dev environment

This repo is a Nix flake (`flake.nix`) providing a devShell with the tools these
scripts depend on (`gh`, `git`, `jq`, `lefthook`, `p7zip`, `powershell`, `shellcheck`, ...).
`.envrc` uses direnv (`use flake`) to load it automatically on `cd`.

- Add a script's runtime dependencies to `devShells.default.packages` in
  [flake.nix](flake.nix) when introducing a new tool.
- Exception: a script with a heavy or self-contained toolchain lives in its own
  `scripts/<category>/<name>/` directory with a `flake.nix` + `flake.lock`
  beside it, and re-execs itself inside that flake's devShell (guarded by an
  env var) so it runs from anywhere without direnv — see
  `sync_archive_forks.sh`. Its deps go in that flake, not the root one.
- The devShell's `shellHook` runs `lefthook install`, wiring up the git hooks
  defined in [lefthook.yml](lefthook.yml) automatically on `cd` (via direnv).
  Those hooks run `shellcheck -x` on staged `*.sh` files and
  `Invoke-ScriptAnalyzer` on staged `*.ps1` files at `pre-commit`, mirroring the
  `shellcheck`/`psscriptanalyzer` CI workflows in `.github/workflows/` so lint
  failures surface locally before a push triggers CI. Update `lefthook.yml`
  alongside those workflows if the CI checks change.

## Bash standards

The "Bash standards" and "PowerShell standards" sections below are a condensed
summary. The full rules, with stable IDs (`GEN-`, `SH-`, `PS-`), live in
[docs/standards/](docs/standards/README.md); change them there first and keep
these summaries in step.

Every script here should follow these conventions (matches the existing scripts):

- Shebang `#!/usr/bin/env bash`, and `set -euo pipefail` near the top.
- Must be shellcheck-clean (`shellcheck -x`).
- Use `[[ ]]` for conditionals, never `[ ]` or `test`.
- Use arrays for lists of args/values instead of space-joined strings; expand with
  `"${arr[@]}"` (quoted).
- Prefer `mapfile`/process substitution (`< <(...)`) over piping into `while read`,
  so loop-local variables survive outside subshells.
- Use `mktemp -d` for scratch directories, paired with `trap cleanup EXIT`.
- Guard clauses over deep nesting: `if ! cmd; then handle_error; continue/exit; fi`
  rather than wrapping the success path in an `if cmd; then ... fi`. This also
  ensures failures inside a `( subshell )` step are actually caught — a subshell
  used only as the last statement of an `if`'s `then` body silently discards its
  exit status.
- `set -e` is *ignored* inside anything run as an `if`/`while`/`!`/`&&`/`||`
  condition, and that suppression reaches into subshells and functions called
  there (re-arming `set -e` inside does nothing). So a multi-step
  `if ! ( cd x; do_thing ); then` does **not** stop at a failing `do_thing`. When
  a step like that needs per-command failure handling, put it in a function with
  an explicit `|| return 1` / `|| exit 1` on each command (see `prepare_repo` in
  `github_backup.sh`), not a bare `set -e`.
- Quote all variable expansions unless intentionally relying on word-splitting/glob.
- `echo "Error: ..." >&2` + `exit 1` for fatal errors; keep going and collect
  failures into a `FAILED=()` array for per-item operations in a loop (see
  `github_backup.sh`), printing a summary at the end instead of aborting the whole
  run on one failure.

## PowerShell standards

For the rare Windows-only script (`.ps1`):

- Comment-based help block (`.SYNOPSIS`/`.DESCRIPTION`/`.NOTES`) at the top, with
  requirements listed under `.NOTES` — the PowerShell equivalent of the bash header
  comment.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` near the
  top, mirroring `set -euo pipefail`.
- `#Requires -RunAsAdministrator` when the script needs elevation (e.g. `usbipd`).
- `Write-Output`/`Write-Warning`/`Write-Error` over `Write-Host`, so output stays
  pipeline/redirect-friendly (matches `PSScriptAnalyzer`'s `PSAvoidUsingWriteHost`).
- Check `$LASTEXITCODE` after calling external commands (`usbipd`, etc.) rather than
  assuming success.
- Lint with `Invoke-ScriptAnalyzer` (PSScriptAnalyzer module) before committing, the
  PowerShell analogue of `shellcheck`. PSScriptAnalyzer is not in the flake
  devShell (it isn't cleanly packaged in nixpkgs) — both the `psscriptanalyzer`
  lefthook hook and the CI workflow `Install-Module` it on demand into the
  user/CI PowerShell module path.
