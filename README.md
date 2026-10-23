# my-scripts-and-stuff

A repository with all my scripts. See [CLAUDE.md](CLAUDE.md) for repo layout and
conventions for writing/maintaining scripts. This file documents what each script
does, how to configure it, and its requirements. The rules every script must
follow are in [docs/standards/](docs/standards/README.md).

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

Backs up every repo (public + private) owned by each account in `OWNERS` into a
single timestamped (UTC) `.7z` in `$OUTPUT_DIR` (default `$PWD`), with each
owner's repos in their own top-level `<owner>/` folder (e.g.
`evictedcucumber/foo/`, `Zezura-Archive/bar/`). For each repo: clones it,
force-fetches all tags, checks out submodules, and creates local tracking
branches for every remote branch, so the resulting archive is a self-contained,
browsable set of working trees — not a bare mirror. After creation the archive
is verified (`7z t`) and `chmod 600`ed; the run aborts up front if the target
archive already exists, and errors out if *every* repo fails. If only *some*
repos fail, the archive is still created from the rest, the failures are listed
on stderr, and the script **exits 1** so an incomplete backup is never mistaken
for a good one.

```bash
./scripts/git/github_backup.sh                                   # back up the default OWNERS into $PWD
OWNERS="someone some-org" OUTPUT_DIR=~/backups ./scripts/git/github_backup.sh
```

Takes no arguments; `-h, --help` prints the usage and any other argument is
rejected.

Before cloning anything it validates `gh`'s access and aborts, listing every
problem at once, if any check fails:
- the token has the `repo` scope, plus `read:org` when an owner is an org
  (skipped with a warning for fine-grained tokens, which don't report scopes);
- every owner exists; for an org, your membership is `active`, and the org
  doesn't block GitHub CLI (OAuth app restrictions) or require SAML SSO
  authorisation; another user's account only warns (public repos only);
- the public/private repo counts `gh repo list` returns match what GitHub
  reports for each owner, so repos invisible to the token can't silently go
  missing. (Your personal private count is only checked if GitHub exposes it
  to the token.)

Requires: `gh` (authenticated — `gh auth status`), `git`, `7z`, `jq`.

Config: `DEFAULT_OWNERS` and `IGNORE_LIST` sit at the top of the script;
everything else is an env var.
- `OWNERS` — GitHub users/orgs to back up, space/newline separated. Defaults to
  `evictedcucumber Zezura-Archive` (`DEFAULT_OWNERS` in the script). An owner
  with no repos is warned about and skipped; a `gh repo list` failure for any
  owner aborts the run. For an org's private repos, `gh` needs the `read:org`
  scope (`gh auth refresh -s read:org`) and, if the org restricts OAuth apps,
  GitHub CLI approved in the org's settings.
- `OWNER` — single owner, honoured only when `OWNERS` is unset (backwards
  compatibility).
- `IGNORE_LIST` — `"owner/name"` entries to skip (edit the array in the script).
- `GH_BACKUP_IGNORE` — env var; extra `"owner/name"` entries (space/newline
  separated) appended to `IGNORE_LIST`.
- `OUTPUT_DIR` — env var, defaults to `$PWD`.
- `GH_BACKUP_PASSWORD` — env var; if set, encrypts the archive (`7z -mhe=on`) and
  also hides file names/metadata. Passed to `7z` as `-p...`, so it is briefly
  visible in the process list — only use on a trusted host.

### Git transport (HTTPS via gh, never SSH)

Every clone/fetch goes over HTTPS, authenticated by `gh` (`gh auth
git-credential`), regardless of `gh config get git_protocol` — repos are cloned
from an explicit `https://github.com/...` URL, and SSH-style `github.com`
submodule URLs are rewritten to HTTPS. This is set through `GIT_CONFIG_*`
environment variables for the run only; your git/gh config is untouched. So no
SSH key — and no hardware-key (Yubikey) PIN/touch prompt per repo — is needed.

## scripts/git/sync_craft_forks/sync_craft_forks.sh

Reads a GitHub star list (default **zezura-archive-craft**) for the `gh`-authenticated
user and keeps every repo in it mirrored locally. It runs in phases: steps 1–3
for **every** repo first, then step 4 for each repo that synced cleanly, then
step 5 for each repo that built cleanly, so a slow or failing build never holds
up the syncing.

1. **Forks** — syncs the fork's copy of the upstream default branch on GitHub
   from its parent (`gh repo sync <fork> --branch <upstream default>`),
   fast-forward only.
2. Clones it into `DEST_DIR/<name>` if missing (`gh repo clone`, which also adds
   an `upstream` remote for forks); otherwise `git fetch --all --prune`, then
   `git fetch --tags --force origin` (your fork's tags win locally over a
   same-named upstream tag at another commit).
3. Fast-forwards the local copy of that branch to `origin/<branch>` — via
   `git merge --ff-only` when it is checked out, otherwise by updating the ref
   without touching the working tree.
4. **Builds** the repo's main binary (the package and bin named after the repo,
   e.g. `apps/photocraft`) in release mode and copies it into
   `BUILD_DIR/<name>/` (default `~/builds/craft-forks/<name>/`):
   - `<name>-linux-x86_64`: `cargo zigbuild` for
     `x86_64-unknown-linux-gnu`, pinned to glibc 2.35 like upstream's
     Ubuntu 22.04 release builds. A plain `cargo build` on NixOS would set the
     ELF interpreter to `/nix/store/...`, so the binary would only run on NixOS.
     Builds set `CFLAGS_x86_64_unknown_linux_gnu="-fno-function-sections
     -fno-data-sections"`: the `cc` crate's default `-ffunction-sections
     -fdata-sections` makes zig's clang emit section symbols with an undefined
     section index, and lld then fails with empty `undefined symbol:` errors
     (seen with `aws-lc-sys`).
   - `<name>-windows-x86_64.exe`: `cargo xwin build` for
     `x86_64-pc-windows-msvc` (MSVC, like upstream). The MSVC CRT/SDK is
     downloaded into `~/.cache/cargo-xwin` on first use.
   - macOS: **skipped**. It can't be cross-built from Linux without Apple's
     SDK, and upstream builds it on macOS runners.
   - **Fonts**: if the repo's `.github/workflows/release.yml` pins a
     [storytold/craft-fonts](https://github.com/storytold/craft-fonts) commit
     (a `craft-fonts-ref:` input, or `ref:` on a craft-fonts checkout step),
     that commit is checked out into `CRAFT_FONTS_CACHE` and both builds get
     `CRAFT_FONTS_DIR` + `CRAFT_FONTS_REQUIRED=1`, exactly like upstream's
     release builds. Without this the apps silently build with no embedded
     fonts (deckcraft warns, because its `.cargo/config.toml` points at a
     `../craft-fonts` sibling checkout). If the fonts can't be checked out, the
     repo isn't built.
   - Windows **icon/version resources are not embedded** (e.g. filmcraft warns
     `built without icon/version resources (cross-compiled from a non-Windows
     host)`): the apps only depend on `winresource` on Windows hosts, so
     there's no way to embed them from Linux without patching the forks. The
     `.exe` works; it just has the default icon in Explorer and the taskbar.

   Builds run from the working tree, so a clone that isn't on the default
   branch is reported and not built. Binaries are copied, not moved, so
   cargo's cache stays valid and an unchanged repo rebuilds almost instantly.
   All repos build into one shared `CARGO_TARGET_DIR`, so dependencies they
   have in common (same version, features and release profile) compile once.
   Each repo keeps its own release profile, so binaries are optimised as
   upstream intends; repos with different profiles just share less.
   On top of that, builds go through **sccache** (`RUSTC_WRAPPER=sccache`,
   cache in `~/.cache/sccache`), which also caches C/assembly objects from
   `cc`-based build scripts (e.g. `aws-lc-sys`, for both zig and `clang-cl`).
   That covers what cargo's fingerprints throw away: a crate rebuilt because
   an env var or flag changed (`CRAFT_FONTS_DIR`, `CFLAGS_*`), a cleaned or
   deleted target dir, or C code shared between repos. sccache's Rust cache
   is keyed on absolute paths, so it only hits while `CARGO_TARGET_DIR`
   stays the same. Hit/miss stats are printed at the end of the run.
5. **Releases** both binaries on GitHub (`gh release create`) — only on repos
   owned by `FORK_OWNER` (default `Zezura-Archive`, the org holding your forks;
   never the upstream parent or anyone else's repo in the list), and only when both the Linux and Windows builds
   succeeded. The tag is always `v<version>-forked`, from the binary's
   version in `cargo metadata`. The suffix means a fork release never clashes
   with (or is mistaken for) upstream's own `v<version>` tag, and each version
   has exactly one release that later runs can update. The release targets
   the built commit (`origin/<branch>`). If your repo already has that
   release, it is **updated in place** rather than a new one created: its tag
   is moved to the built commit and its binaries and notes are replaced
   (`gh release upload --clobber`). If it already points at the built commit,
   nothing is done.

Repos with no binary named after the repo (checked with `cargo metadata`), such
as **craft-fonts** and **craft-libs** — the font and library repos the apps
build against — are synced
(steps 1–3) but not built or released. Non-fork repos in the list are just
cloned/fetched and fast-forwarded on their default branch. A fork whose branch has diverged from upstream, a fork that is
archived (read-only) on GitHub, or a local clone with diverged commits is
reported as failed rather than overwritten. Each failed step (sync, clone,
each build target) is listed at the end and the script **exits 1**.

```bash
./scripts/git/sync_craft_forks/sync_craft_forks.sh              # sync + build + release
./scripts/git/sync_craft_forks/sync_craft_forks.sh --sync       # sync only
./scripts/git/sync_craft_forks/sync_craft_forks.sh --build      # sync + build, no releases
./scripts/git/sync_craft_forks/sync_craft_forks.sh --release    # same as no mode
./scripts/git/sync_craft_forks/sync_craft_forks.sh --clean      # wipe cargo target dir + sccache cache
./scripts/git/sync_craft_forks/sync_craft_forks.sh -j 8         # sync 8 repos at a time
./scripts/git/sync_craft_forks/sync_craft_forks.sh --build --only filmcraft,effectcraft
./scripts/git/sync_craft_forks/sync_craft_forks.sh ~/archive    # custom source destination
STAR_LIST="Other List" ./scripts/git/sync_craft_forks/sync_craft_forks.sh
```

- `DEST_DIR` (optional positional) — where repos are cloned; default
  `~/repos/craft-forks`, created if missing.
- `-f, --force` — hard-reset instead of fast-forwarding, on GitHub
  (`gh repo sync --force`) and locally (`git reset --hard` / forced ref update).
  **Discards** fork commits that upstream does not have.
- `--sync` — sync only (steps 1-3).
- `--build` — sync, then build (steps 1-4); no releases.
- `--release` — sync, build, then release (steps 1-5); the default when no
  mode is given.
- `--clean` — delete the build caches and do nothing else: stops the sccache
  server, then removes `CARGO_TARGET_DIR` and `SCCACHE_DIR` (default
  `~/.cache/sccache`). Sources (`DEST_DIR`), binaries (`BUILD_DIR`) and
  `CRAFT_FONTS_CACHE` are kept, and no `gh` login is needed. Takes no other
  options or `DEST_DIR`.
- Only one of `--sync`/`--build`/`--release`/`--clean` may be given.
- `--only REPO[,REPO...]` — process only these repos of the star list
  (repeatable, comma-separated). Each is matched case-insensitively against a
  repo's name, its `owner/name`, or a fork's upstream `owner/name`; a name that
  matches nothing is an error, listing the repos in the list. Unselected repos
  aren't synced, built or released, but their existing clones and forks still
  serve the selected repos' git dependencies (craft-libs, forked crates) and
  craft-fonts, as in a full run.
- `-j, --jobs N` — sync up to N repos in parallel (default 1). Only the sync
  phase (steps 1-3) runs in parallel: builds share the cargo target dir and
  run one at a time, as do releases. With N > 1 each repo's sync output is
  buffered and printed as one block when that repo finishes.
- `STAR_LIST` — env var; the star list name to read (exact match).
- `FORK_OWNER` — env var; user/org that owns the forks, the only owner whose
  repos get releases (default `Zezura-Archive`, matched case-insensitively).
- `BUILD_DIR` — env var; where binaries go (default `~/builds/craft-forks`).
- `CARGO_TARGET_DIR` — env var; cargo target dir shared by all repos (default
  `~/.cache/craft-forks/target`). Per-repo `target/` dirs from earlier runs
  are no longer used and can be deleted.
- `RUSTC_WRAPPER` — env var; compiler wrapper for the builds (default
  `sccache`). Set it to an empty string to build without one; any other value
  you've already exported is used as-is. sccache's own settings
  (`SCCACHE_DIR`, `SCCACHE_CACHE_SIZE`, default 10 GiB, ...) apply as usual.
- `CRAFT_FONTS_CACHE` — env var; the craft-fonts checkout that font-embedding
  builds use (default `~/.cache/craft-forks/craft-fonts`), switched between
  the commits the repos pin. When craft-fonts is in the star list (your fork,
  synced to `DEST_DIR/craft-fonts` like the others), it is a detached
  `git worktree` of that clone, so nothing is downloaded twice and the synced
  clone's branch is left alone; otherwise it is a standalone clone of
  upstream.

Star lists are only exposed through the GraphQL API (`viewer.lists`), so the
list is read with `gh api graphql`, not `gh repo list`.

All git operations (clone, fetch, `ls-remote`) go over HTTPS authenticated with
`gh`'s token, so no SSH key, passphrase or hardware-key touch is needed — even if
`gh`'s `git_protocol` is `ssh` or existing clones have SSH remotes. For the
duration of the run only, the script sets `GIT_CONFIG_*` env vars that rewrite
`git@github.com:` / `ssh://git@github.com/` URLs to `https://github.com/` and
use `gh auth git-credential` as the sole credential helper for `github.com`;
your global git/gh config and the clones' saved remote URLs are left unchanged.

The build phase also fetches cargo git dependencies on any repo whose fork
synced cleanly from that fork rather than from upstream: for example,
effectcraft's `filmcraft-*` crates come from `Zezura-Archive/filmcraft`, not
`storytold/filmcraft`. This works the same way, through a run-only `insteadOf`
rewrite plus `CARGO_NET_GIT_FETCH_WITH_CLI=true`, so no `Cargo.toml` or
`Cargo.lock` is touched. The lockfile still pins the same commit, so the code
built is identical; only where it is fetched from changes.

**craft-libs** goes one step further, like craft-fonts: when
[storytold/craft-libs](https://github.com/storytold/craft-libs) is in the star
list (your fork, synced to `DEST_DIR/craft-libs`), its crates (`craft-ui`,
`craft-docpath`, `craft-print`, ...) are fetched from that **local clone**
(`file://` rewrite) instead of GitHub. Before each build, any craft-libs
commit the repo's `Cargo.lock` pins that the clone lacks (e.g. one only on a
deleted PR branch) is fetched into it from your fork first; if that fails the
repo isn't built.

Requires: `nix`, and `gh` authenticated (and allowed to push to and create
releases on the `FORK_OWNER` org's repos).

Before syncing anything, the script checks that `gh` can do all of that and
exits with the fix if not:

- the token has the `repo`, `workflow` (needed by `gh repo sync` once upstream
  touches `.github/workflows/`) and `read:org` scopes — skipped for
  fine-grained/app tokens, which don't report scopes;
- you are `FORK_OWNER` or an **active** member of that org — this also
  catches an org that restricts OAuth app access (approve GitHub CLI under the
  org's *Settings → Third-party access*);
- you have write access (`WRITE`/`MAINTAIN`/`ADMIN`) to every fork in the
  list, and any fork not owned by `FORK_OWNER` is flagged as sync-only.

Most failures are fixed by
`gh auth refresh -h github.com -s repo,workflow,read:org`.
The script has its own [flake.nix](scripts/git/sync_craft_forks/flake.nix)
beside it and re-execs itself inside that flake's devShell
(`nix develop path:<script dir> --command ...`), which provides `gh`, `git`,
`jq`, a Rust toolchain with the `x86_64-pc-windows-msvc` std (from
[rust-overlay](https://github.com/oxalica/rust-overlay)), `cargo-zigbuild`,
`zig`, `cargo-xwin`, clang/lld/llvm, `sccache`, and `pkg-config` + `alsa-lib` (for
`alsa-sys`, which needs `pkg-config --libs --cflags alsa`). So it runs from any directory — no
direnv or `nix develop` needed — as long as `flake.nix`/`flake.lock` stay next
to it; symlinking the script (e.g. into `~/bin`) works too. The first run
builds the environment; later runs reuse it from the Nix store.

## scripts/maintenance/windows_maintenance.ps1

Windows-side helper (not run from WSL/bash) that runs a batch of maintenance
and health tasks in one pass — Windows Update, winget, DISM/SFC repair, Disk
Cleanup, WSL disk compaction, a disk / event-log health check, drive
optimization, driver updates and a Defender update + full scan — and prints an `OK` / `WARN` / `FAIL` / `SKIP` summary at the
end. Steps are independent — one failing does not abort the rest — and the
script exits non-zero if any step failed. `WARN` means a step finished but found
something worth a look (a health finding, a guard that held work back); it does
not fail the run. It never reboots. **It takes no options**: every run does everything, and
it's unattended after one up-front question.

**It asks before doing anything.** The script first prints what it is about to
do, with the destructive parts (Disk Cleanup empties the Recycle Bin; component
store cleanup drops superseded component versions) and the disruptive parts
(`wsl --shutdown` ends every running WSL session and anything that depends on it,
including a WSL shell you may have started the script from; winget may close
running apps) called out, and asks `Proceed? [y/N]` — the only prompt in the run.
Declining (or a non-interactive session) exits with code 1 without changing
anything. After you confirm, it warns about an already-pending reboot and
nearly-full volumes, and creates a System Restore point (Windows declines if System Protection is off or one was made in the last 24
hours — the script says so and carries on).

**Each step runs in its own console window.** The orchestrator re-invokes the
script with an internal `-RunStep <name>` per step, waits for it, and reads a
small JSON result back from a temp run directory (path printed at the start and
end of the run). That keeps each step's noisy output — winget's table redraws,
the DISM progress bar, `Optimize-Volume -Verbose` — in a separate window and a
per-step `output.log`, leaving the orchestrator window a clean
one-line-per-step progress list. A step window auto-closes a few seconds after
its step finishes, pass or fail — nothing waits for a keypress — and the run
directory (`%TEMP%\windows_maintenance_<timestamp>\<Step>\`) is kept afterward.
Console QuickEdit is switched off in step windows so a stray click can't freeze
them. (`Start-Transcript` on
Windows PowerShell 5.1 may not capture native-EXE output in full — the live
window always shows everything.)

It does **not** require elevation to start. Nearly every step needs
Administrator, so the script **relaunches itself elevated in a new console**
(one UAC prompt, after the confirmation above), runs there, and mirrors that
run's exit code; the summary is saved as `summary.txt` in the run directory and
echoed by the original window when the elevated one closes. Declining UAC exits
non-zero. The winget user pass always runs de-elevated (if the script is already
elevated, e.g. via `sudo pwsh -File ...`, it is launched with a basic-user token
through `runas /trustlevel`).

```powershell
.\scripts\maintenance\windows_maintenance.ps1
```

1. **Windows Update** — installs all applicable *software* updates via the
   [`PSWindowsUpdate`](https://www.powershellgallery.com/packages/PSWindowsUpdate)
   module (`Get-WindowsUpdate -UpdateType Software -MicrosoftUpdate -AcceptAll
   -Install -IgnoreReboot`). `-MicrosoftUpdate` includes Office and other
   Microsoft products; the Microsoft Update service is registered on first use
   (the same switch as Settings → "Receive updates for other Microsoft
   products"), and if that fails the step carries on with Windows Update only.
   Drivers are excluded here — they come from step 2.
   If the module is missing it is installed from the PSGallery on first run
   (`Install-Module`, `CurrentUser` scope; the NuGet provider is bootstrapped
   first, and PSGallery may prompt once to trust it on a locked-down host).
   Automatic reboots are suppressed; a resulting pending reboot is reported in
   the summary only.
2. **Driver updates** — `Get-WindowsUpdate
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
   (`0x8A15002B`) counts as success; if some packages fail to upgrade, the rest are still attempted and the pass is recorded as `WARN` with the failed-package count; any other non-zero exit fails that pass.
   Packages listed in `winget_ignore.txt`, next to the script, are
   `--exclude`d from the upgrade — copy
   [`winget_ignore.sample.txt`](scripts/maintenance/winget_ignore.sample.txt)
   to `winget_ignore.txt` (same folder) and list one winget package `Id` per
   line (`#` comments and blank lines allowed); the file is optional and
   nothing is excluded on its account if it's absent.
   WSL and winget: upgrading `Microsoft.WSL` runs `wsl --shutdown`. Because
   the up-front confirmation already covers a WSL shutdown, the package is
   upgraded normally. On a winget too old for `--exclude`, a configured ignore
   list is skipped with a warning (the upgrade proceeds).
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
9. **Microsoft Defender** — `Update-MpSignature`, then a full scan (can
   take hours), then reports signature age, real-time
   protection and threats. An active threat is a `FAIL`; a detection Defender
   already handled during the scan, stale signatures (> 3 days) or real-time
   protection being off are `WARN`s. `SKIP`ped when Defender isn't the active
   antivirus (a third-party product has put it in passive mode).

- `-Relaunched`, `-RunStep`, `-RunDir` — internal, set by the script when it
  relaunches itself (for elevation) or launches a step's window; don't pass
  them by hand. There are no user-facing options.

Written for desktops: there are no battery / AC-power checks.

Requires: Windows 10/11 (or matching Server), PowerShell 5.1+. No
`#Requires -RunAsAdministrator` — the script self-elevates. Internet access for steps 1–4
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
`homelab` is neither a repo nor a flake. `.git`, `node_modules`, `.direnv` and
`.claude` directories (at any depth, so Claude Code worktrees under
`.claude/worktrees/` are never touched) are not searched, nor is
`~/repos/craft-forks` (the search root's `craft-forks`, managed by
`sync_craft_forks.sh`).

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
- `-h, --help` — print the usage. Any other option starting with `-` is an
  error; use `--` before an `IGNORE` that itself starts with `-`.

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
copy_to_downloads.sh --dry-run --force ./build/app.zip   # preview, change nothing
```

- `<wsl-path>` (positional, required) — the file or directory to copy.
- `-d, --dest DIR` — destination directory instead of Downloads; accepts a WSL
  path or a Windows path (`C:\...`). Also settable via `WIN_DOWNLOADS_DIR`.
- `-f, --force` — replace an existing item of the same name (otherwise the copy
  is refused). The existing item is deleted with `rm -rf` before the copy.
- `-n, --dry-run` — run every check and print what would be copied (and
  replaced), but change nothing.
- `-v, --verbose` — pass `-v` to `cp`.
- `WIN_DOWNLOADS_DIR` — env var; same as `--dest`, which wins if both are given.

Requires: WSL (`wslpath`), coreutils; `powershell.exe` / `cmd.exe` for Downloads
autodetection (not needed when `--dest` / `WIN_DOWNLOADS_DIR` is given).

## scripts/wsl/attach_yubikey.ps1

Windows-side helper (not run from WSL/bash) that finds a connected YubiKey via
`usbipd list` (matched on VID:PID `1050:0407`) and attaches it to WSL with
`usbipd attach --wsl --busid <id>`. Skips the attach if the device is already
`Attached`; if the device has never been shared it runs `usbipd bind --busid
<id>` first (one-time, persistent). No-ops with a message if no matching device
is found, and exits non-zero if `usbipd list` itself fails. Supports `-WhatIf` /
`-Confirm`: the bind and the attach are the only changes it makes, and neither
runs under `-WhatIf`.

Requires: Windows PowerShell 5.1+, [usbipd-win](https://github.com/dorssel/usbipd-win),
run from an elevated PowerShell prompt (`usbipd bind`/`attach` need
Administrator).

Run manually whenever the YubiKey needs to (re)appear inside WSL, e.g. after a
replug or reboot — not scheduled or hooked into anything automatically. To
automate this, see `register_yubikey_attach_task.ps1` below.

## scripts/wsl/register_yubikey_attach_task.ps1

Windows-side, run once (and re-run any time to update): idempotently registers a
Scheduled Task (`AttachYubiKeyToWSL`) that runs `attach_yubikey.ps1` whenever any
USB device is connected, so plugging in the YubiKey auto-attaches it to WSL with
no manual step. Run with `-Remove` to unregister the task and delete the
generated VBScript wrapper (`attach_yubikey.ps1` is left in place). Supports
`-WhatIf` / `-Confirm`: enabling the event log, writing the wrapper, registering
the task and the `-Remove` teardown each report what they would do and change
nothing under `-WhatIf`.

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

Requires: Windows PowerShell 5.1+, Windows Task Scheduler (`ScheduledTasks`
module, built in), run from an elevated PowerShell prompt. Expects `attach_yubikey.ps1` to already be deployed
at `%USERPROFILE%\Documents\Scripts\attach_yubikey.ps1` — copy it there before
running this script.

## configs/windows_sandbox/windows_sandbox.wsb

A Windows Sandbox config. At logon it runs `sandbox_setup.ps1` to give a fresh
sandbox:

- **Dark mode**: sets `AppsUseLightTheme` / `SystemUsesLightTheme` to 0, then
  restarts Explorer so the taskbar and Start update.
- **winget**: Microsoft's documented sandbox method. It installs the
  `Microsoft.WinGet.Client` module from PSGallery, then runs
  `Repair-WinGetPackageManager -AllUsers`.
- **Microsoft Store**: runs ThioJoe's
  [`Install-Microsoft-Store.ps1`](https://github.com/ThioJoe/Windows-Sandbox-Tools),
  pinned to a commit and checked against a SHA256 in the config section of
  `sandbox_setup.ps1`. It downloads the Store and its dependencies from
  Microsoft's Windows Update delivery service, installs them with
  `Add-AppxPackage`, and sets the region to US, which the Store needs.

Each step that fails is reported and skipped, and the others still run. Output
is logged to `sandbox_setup.log` on the sandbox desktop. Setup takes a few
minutes after the desktop appears, and it re-runs on every launch, since the
sandbox is discarded when closed.

The `.wsb` is self-contained: `sandbox_setup.ps1` is embedded in its
`<LogonCommand>` (gzipped and base64-encoded), and decoded into `%TEMP%` inside
the sandbox at logon. Nothing is mapped in from the host, because Windows
Sandbox doesn't support relative `<HostFolder>` paths. Copy just the `.wsb` to
anywhere on the Windows host and double-click it:

```bash
./scripts/wsl/copy_to_downloads.sh --force configs/windows_sandbox/windows_sandbox.wsb
```

The `.wsb` is generated, so don't edit it by hand. Edit `sandbox_setup.ps1`,
then regenerate the `.wsb` and commit both files:

```bash
./configs/windows_sandbox/build_wsb.sh
```

`build_wsb.sh --check` fails if the `.wsb` is out of date. The pre-commit hook
and CI both run it.

Requires: Windows 11 with the Windows Sandbox feature enabled. The sandbox
needs network access, which is on by default.
