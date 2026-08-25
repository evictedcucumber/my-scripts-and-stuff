# personal-scripts

A collection of standalone shell scripts, organized by category under `scripts/`.

## Layout

```
scripts/
  git/
    github_backup.sh   # backs up all repos for a GitHub owner into a 7z archive
```

New scripts go in `scripts/<category>/`, named `snake_case.sh`. Each script should
be runnable directly (`./scripts/<category>/name.sh`), self-contained, and list its
own requirements in a header comment — there is no shared lib/framework here.

## Dev environment

This repo is a Nix flake (`flake.nix`) providing a devShell with the tools these
scripts depend on (`gh`, `git`, `jq`, `p7zip`, ...). `.envrc` uses direnv (`use flake`)
to load it automatically on `cd`.

- Add a script's runtime dependencies to `devShells.default.packages` in
  [flake.nix](flake.nix) when introducing a new tool.
- `shellcheck` is not currently in the devShell; run it ad hoc via
  `nix shell nixpkgs#shellcheck -c shellcheck -x scripts/**/*.sh` before committing
  script changes.

## Bash standards

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
- Quote all variable expansions unless intentionally relying on word-splitting/glob.
- `echo "Error: ..." >&2` + `exit 1` for fatal errors; keep going and collect
  failures into a `FAILED=()` array for per-item operations in a loop (see
  `github_backup.sh`), printing a summary at the end instead of aborting the whole
  run on one failure.

## github_backup.sh

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
