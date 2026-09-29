# Adoption status

Where the repository stands against the [standards](README.md): what is enforced
automatically today, what could be, and what was changed to bring the existing
scripts into line. **The scripts conform except for the [open items](#open-items); the
enforcement tooling proposed below has not been implemented.**

Snapshot taken 2026-09-29 against commit `6a1c9cf` plus the conformance changes
described under [Deviations fixed](#deviations-fixed). Update it whenever a
deviation is fixed or a new rule is added.

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

## Deviations fixed

The first review (commit `ae96cb3`) listed the deviations that were fixed first;
a second, full review on the same day, covering the scripts added since and
checking every rule by hand and with tooling, found more (marked *new*).

### MUST rules

| Rule | File | What was wrong | Fix |
| --- | --- | --- | --- |
| `GEN-42` | `windows_maintenance.ps1` | Local `winget_ignore.txt` was not git-ignored. | Added `scripts/maintenance/winget_ignore.txt` to `.gitignore`. |
| `GEN-50`, `SH-22` | `github_backup.sh` | `WARNING:` lines and the failed-repo list went to stdout. | Now stderr. |
| `SH-17` | `github_backup.sh` | `mkdir`/`cd` on user-supplied `OUTPUT_DIR` without `--`. | Added `--` (also on `cd`, `rm -rf`, `chmod`). |
| `PS-02` | `attach_yubikey.ps1`, `register_yubikey_attach_task.ps1` | No `#Requires -Version 5.1`. | Added. |
| `GEN-30`, `SH-23` (*new*) | `github_backup.sh` | Exited `0` when some (not all) repos failed, so an incomplete backup looked good. | Archive is still created, failures are listed, and the script exits `1`. Header and README say so. |
| `SH-30` (*new*) | `update_flakes.sh` | Hand-rolled argument loop: no `--`, and an unknown `-x` was silently treated as an ignore path. | `while`/`case` parser: `-h`/`--help`, `--`, unknown `-*` rejected with usage and exit `1`. |
| `GEN-50`, `SH-22` (*new*) | `update_flakes.sh` | `WARNING:` lines to stdout. | Now stderr. |
| `GEN-32` (*new*) | `update_flakes.sh` | A failing `git rev-parse` would abort the whole run under `set -e`. | Recorded in `FAILED` and the loop continues. |
| `SH-17` (*new*) | `update_flakes.sh` | `cd "$1"` without `--`. | Added. |
| `SH-04`, `GEN-40`, `GEN-41` (*new*) | `github_backup.sh`, `update_flakes.sh`, `copy_to_downloads.sh` | Header had no `Environment:` list; `github_backup.sh` documented the `7z -p` password exposure only in a code comment. | `Usage`/`Environment` added to every header; the password note is in the header. |
| `SH-21` (*new*) | `github_backup.sh`, `copy_to_downloads.sh` | `\|\| true` without a reason. | Reason added next to each. |
| `GEN-30` (*new*) | `copy_to_downloads.sh` | Last statement was `[[ -n "$WIN_DEST" ]] && echo ...`; if `wslpath -w` failed, a successful copy exited `1`. | Guard clause. |
| `SH-22` (*new*) | `copy_to_downloads.sh` | Missing option value and surplus argument printed no usage. | Usage to stderr, exit `1`. |
| `PS-14` (*new*) | `archive_directory.ps1`, `windows_maintenance.ps1` | 14 helper functions had no purpose comment (including `Resolve-SevenZip`). | Added. |
| `PS-21` (*new*) | `attach_yubikey.ps1` | `usbipd` invoked as a bare command. | `& $usbipd.Source ...` on the resolved path. |
| `PS-21` (*new*) | `windows_maintenance.ps1` | `wsl --list --running` and `winget upgrade --help` did not check `$LASTEXITCODE`. | Checked. `cleanmgr` and `fstrim` deliberately use `Start-Process`; marked with `standards-exception: PS-21` and a reason. |
| `PS-23` (*new*) | `windows_maintenance.ps1` | Four `catch` blocks only `return`ed. | Each logs with `Write-Verbose`. |
| `PS-32` (*new*) | `windows_maintenance.ps1` | `Set-Content` for `pid.txt` had no `-Encoding`. | `-Encoding ASCII`. |
| `GEN-30` (*new*) | `windows_maintenance.ps1` | Declining the prompt exits `1` but the help and README did not say so. | Documented. |

### SHOULD rules

| Rule | File | Fix |
| --- | --- | --- |
| `SH-31` | `github_backup.sh` | `usage()`, `-h`/`--help`, and unexpected arguments rejected. |
| `SH-31` (*new*) | `update_flakes.sh` | `usage()` is a quoted heredoc instead of `sed`-ing the header, so it matches the reference implementation. |
| `PS-03` | all four `.ps1` files | `.EXAMPLE` added (also to `windows_maintenance.ps1`). |
| `PS-50` | `attach_yubikey.ps1`, `register_yubikey_attach_task.ps1` | `SupportsShouldProcess`; each persistent change is gated, and `-WhatIf` changes nothing. |
| `GEN-36` | `copy_to_downloads.sh` | `-n`/`--dry-run` added; `--force` replacement can be previewed. |
| `GEN-14` (*new*) | `github_backup.sh` | Commented-out array entry in `IGNORE_LIST` replaced by an example in prose. |

`GEN-10`, `GEN-11`, `GEN-16`, `SH-01`, `SH-04`, `SH-05`, `SH-13`,
`SH-14`, `SH-24`, `SH-25`, `SH-50`, `PS-01`, `PS-04`, `PS-05`, `PS-30`, `PS-40`
and `PS-60` were checked by tool or by hand over every script and hold: the Bash
scripts use the `env` shebang, `set -euo pipefail`, `[[ ]]` and `$(...)` only, are
`100755` and shellcheck-clean; every script is ASCII, LF, ends in a newline and
has no tabs or trailing whitespace; the PowerShell scripts are PSScriptAnalyzer
clean, parse under a `PSUseCompatibleSyntax` (5.1) check, set strict mode and
`Stop`, avoid `Write-Host` and use `-LiteralPath`.

## Open items

| Rule | File | Status |
| --- | --- | --- |
| `PS-50`, `GEN-33`, `GEN-36` | `windows_maintenance.ps1` | **Needs a design decision.** No `-WhatIf`, and Disk Cleanup empties the Recycle Bin. The up-front plan plus the single `[y/N]` prompt is the only gate. Each step runs in its own process, so `-WhatIf` would have to be honoured by the orchestrator (list the steps and skip launching them) and by the elevated relaunch. Decide whether that prompt counts as the explicit opt-in `GEN-33` asks for, or add `-WhatIf`. |
| `PS-15` | `windows_maintenance.ps1`, `register_yubikey_attach_task.ps1` | Backtick continuation remains in several calls; tolerated for existing code. |
| `GEN-13` | `windows_maintenance.ps1` | About 110 lines exceed 100 columns, mostly long string literals and `param`/`Write-Warning` lines, which the rule allows. Not audited line by line. |

### Ambiguities in the rules, not changed

- **`PS-14` positional parameters.** Read literally, "no positional parameters
  beyond the obvious first one" forbids `Join-Path $a 'b'`, which every script,
  including the reference implementations, uses. PSScriptAnalyzer's
  `PSAvoidUsingPositionalParameters` accepts it and the earlier review counted
  `PS-14` as holding, so it was left alone. Consider saying so in the rule.
- **`PS-11` inline `if`.** `$x = if (...) { 'a' } else { 'b' }` keeps `else` on
  the same line as the closing brace. It is used widely in
  `windows_maintenance.ps1` and was left alone; the rule text only describes
  statement-form `if`.
- **`SH-16` and `echo`.** Messages such as `echo "Error: ... $path"` interpolate
  a variable after literal text. Treated as allowed ("`echo` is fine for literal
  messages"), matching `SH-22`.
- **`GEN-23` and `github_backup.sh`.** `jq` is listed as a requirement (header,
  README, `flake.nix` agree) and checked up front, but the script only uses
  `gh --jq`, which is built into `gh`. Not a violation; the dependency could be
  dropped.

### Not deviations, but worth deciding

- **CLAUDE.md duplicates part of these rules.** Its "Bash standards" and
  "PowerShell standards" sections predate this directory and agree with the
  documents today, but two copies will drift. CLAUDE.md now links here and says
  to change the rules here first; replacing the summaries entirely with a link is
  still an option.
- **`GEN-80` history.** Some past commits are unscoped (`feat: improve scripts`).
  History is not being rewritten; the rule applies going forward.
