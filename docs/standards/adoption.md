# Adoption status

Where the repository stands against the [standards](README.md): what is enforced
automatically today, what could be, and where existing files deviate. This is the
worklist for bringing the repo into line. **Nothing here has been implemented yet.**

Snapshot taken 2026-09-29 against commit `ae96cb3`. Update it whenever a deviation
is fixed or a new rule is added.

## What is enforced today

| Mechanism | Where it runs | Covers |
| --- | --- | --- |
| `shellcheck -x` on `*.sh` | `lefthook` pre-commit ([lefthook.yml](../../lefthook.yml)); CI ([shellcheck.yml](../../.github/workflows/shellcheck.yml)) | `SH-11` (SC2155), `SH-14`, `SH-15` (quoting), `SH-26` (partly), `SH-50` |
| `Invoke-ScriptAnalyzer -Severity Warning,Error` on `*.ps1` | `lefthook` pre-commit; CI ([psscriptanalyzer.yml](../../.github/workflows/psscriptanalyzer.yml)) | `PS-12` (approved verbs, singular nouns), `PS-14` (aliases, positional parameters), `PS-22` (`Invoke-Expression`), `PS-40` (`Write-Host`), `PS-60`, and the default BOM check, which only fires for files that contain non-ASCII text (`GEN-10`) |
| Nix devShell ([flake.nix](../../flake.nix)) | on `cd` via direnv | Provides the tools; `lefthook install` wires the hooks |

Everything else in the standards is currently enforced by review only. CI runs on
`scripts/**` paths only, so a change limited to `docs/` triggers no checks.

## Rules with no automated enforcement

These rules are not caught by any linter today. The first rows are cheap to check
mechanically; the last two rows are review-only. The proposals below are
candidates, not decisions.

| Rules | What to check |
| --- | --- |
| `SH-01`, `SH-05`, `SH-13` | Line 1 is exactly `#!/usr/bin/env bash`; `set -euo pipefail` present; no `[ ]` tests (shellcheck has an optional `require-double-brackets` check for the last one). |
| `GEN-16`, `SH-06` | Every `*.sh` is mode `100755`; every `*.ps1` is `100644`. |
| `GEN-10` | No byte above `0x7F` in any script source. |
| `GEN-11`, `GEN-12` | LF only, final newline, no trailing whitespace, no tabs. |
| `PS-01` | No PowerShell 7-only syntax (`PSUseCompatibleSyntax` targeting 5.1). |
| `PS-02`, `PS-04`, `PS-05` | `#Requires -Version 5.1`, strict mode + `Stop`, and `[CmdletBinding()]` present. |
| `GEN-42` | Every local-config path a script reads is in `.gitignore`. |
| `GEN-21`, `GEN-22`, `GEN-23` | README section and CLAUDE.md entry exist for each script (review only). |
| `GEN-30`-`GEN-39`, `GEN-41`, `SH-21`, `PS-21` | Behavioural rules (exit codes, safety, secrets, `set -e` traps, `$LASTEXITCODE`); review only. |

## Proposed enforcement (not implemented)

Listed in rough order of value for effort. Each would be its own change.

1. **`.gitattributes`**: `* text=auto eol=lf` (and `*.sh text eol=lf`,
   `*.ps1 text eol=lf`) so a Windows-side checkout can't introduce CRs (`GEN-11`).
2. **`.editorconfig`**: `charset = utf-8`, `end_of_line = lf`,
   `insert_final_newline`, `trim_trailing_whitespace`, `indent_style = space`;
   `indent_size = 2` for `*.sh` and `4` for `*.ps1` (`GEN-11`, `GEN-12`).
3. **A repo-conformance check** (extra `lefthook` commands and a matching CI step,
   or a small script) for the grep-able rules above: shebang, `set -euo pipefail`,
   file modes, ASCII-only, `#Requires`, strict mode. Keep the hook and the CI
   workflow in step, as `CLAUDE.md` already requires for the linters.
4. **`PSScriptAnalyzerSettings.psd1`** enabling `PSUseCompatibleSyntax` (target
   5.1 and 7.x) and, optionally, `PSUseConsistentIndentation` (4 spaces) and
   `PSPlaceOpenBrace` / `PSPlaceCloseBrace` (`PS-01`, `PS-10`, `PS-11`). Both the
   hook and the CI workflow must pass it via `-Settings`.
5. **`shfmt`** in the flake devShell, run as `shfmt -i 2 -ci -d` (`SH-51`). The
   existing scripts appear to be written in this style but that has not been
   verified; run it and review the diff before making it a requirement.
6. **`.shellcheckrc`** with `external-sources=true` (so `-x` need not be repeated on
   every command line) and any optional checks worth enabling. Per `SH-50`,
   findings are still suppressed inline, never in this file.
7. **CI path filters**: both workflows trigger only on `scripts/**` and their own
   workflow file. If items 3 or 4 add a config file or a conformance script, add it
   to the `paths:` lists so a change to it re-runs the checks.

## Known deviations in existing files

Found while writing the standards; none has been fixed. "Severity" follows the
rule's keyword.

### MUST rules

| Rule | File | Deviation |
| --- | --- | --- |
| `GEN-42` | `scripts/maintenance/windows_maintenance.ps1` | Reads `winget_ignore.txt` next to the script, but `.gitignore` only lists `*.7z` and `.direnv`, so a local copy is not ignored and could be committed. Add `scripts/maintenance/winget_ignore.txt`. |
| `GEN-50`, `SH-22` | `scripts/git/github_backup.sh:203`, `:209`, `:220-221`, and the failure summary | `WARNING: failed to clone/prepare ...` and the "The following repos failed:" list are written to stdout. Warnings and error listings belong on stderr (the `--limit` warning at `:106` already does this). |
| `SH-17` | `scripts/git/github_backup.sh:61-62` | `mkdir -p "$OUTPUT_DIR"` and `cd "$OUTPUT_DIR"` take a user-supplied path without `--`; `OUTPUT_DIR` starting with `-` would be read as an option. (Later paths derive from the resulting absolute path, so they are safe.) |
| `PS-02` | `scripts/wsl/attach_yubikey.ps1`, `scripts/wsl/register_yubikey_attach_task.ps1` | Have `#Requires -RunAsAdministrator` but no `#Requires -Version 5.1`. |

`SH-01`, `SH-04`, `SH-05`, `SH-13`, `SH-14`, `SH-24`, `SH-25`, `GEN-10`, `GEN-11`,
`GEN-16`, `PS-04`, `PS-05`, `PS-30`, `PS-40` were checked against the existing
files and hold: the Bash scripts use the `env` shebang, `set -euo pipefail`, `[[ ]]`
and `$(...)` only, and are `100755`; every script is ASCII, LF, ends in a newline
and has no trailing whitespace; the PowerShell scripts set strict mode and `Stop`,
avoid `Write-Host`, and use `-LiteralPath`.

### SHOULD rules

| Rule | File | Deviation |
| --- | --- | --- |
| `SH-31` | `scripts/git/github_backup.sh` | Takes no arguments but has no `-h`/`--help` and silently ignores any arguments it is given. |
| `PS-03` | all four `.ps1` files | No `.EXAMPLE` in the help block (examples live in the README). |
| `PS-15` | `windows_maintenance.ps1`, `register_yubikey_attach_task.ps1` | Backtick line continuation in several calls. |
| `PS-50` | `register_yubikey_attach_task.ps1`, `attach_yubikey.ps1`, `windows_maintenance.ps1` | Change persistent state (scheduled task, wrapper file, device binding, registry, updates) without `SupportsShouldProcess`. Only `archive_directory.ps1` supports `-WhatIf`. `windows_maintenance.ps1` may need a design decision, since each step runs in a separate process. |
| `GEN-36` | `scripts/wsl/copy_to_downloads.sh` | `--force` does `rm -rf` on the destination with no preview mode. |

### Not deviations, but worth deciding

- **CLAUDE.md duplicates part of these rules.** Its "Bash standards" and
  "PowerShell standards" sections predate this directory. They agree with the
  documents today, but two copies will drift. Suggested: replace them with a short
  summary that links to `docs/standards/`, keeping CLAUDE.md to layout and workflow.
  Not done, because the request was to add documents only.
- **README index.** `README.md` does not mention `docs/standards/`. A one-line link
  near the top would make the standards discoverable.
- **`GEN-80` history.** Some past commits are unscoped (`feat: improve scripts`).
  History is not being rewritten; the rule applies going forward.
