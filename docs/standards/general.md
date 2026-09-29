# General standards (all scripts)

Applies to every script regardless of language. Language-specific rules are in
[bash.md](bash.md) and [powershell.md](powershell.md). See [README.md](README.md)
for how to read the rule keywords and IDs.

## Layout and naming

- **GEN-01 - MUST** - Scripts live at `scripts/<category>/<name>.<ext>`: exactly one
  category directory deep. Categories are a single lowercase word naming the
  domain (`archive`, `git`, `maintenance`, `wsl`). Add a new category only when no
  existing one fits.
- **GEN-02 - MUST** - File names are `snake_case`: lowercase ASCII letters, digits,
  and underscores. **SHOULD** say what the script does, verb first where natural
  (`copy_to_downloads`, `archive_directory`).
- **GEN-03 - MUST** - Language follows where the script runs. Bash (`.sh`) for
  Linux/WSL; PowerShell (`.ps1`) for anything that must run on the Windows side
  (WSL/usbipd helpers, Task Scheduler, winget, Windows Update). A Bash script may
  call Windows executables (`powershell.exe`, `cmd.exe`) from WSL. Do not add a
  third language without first adding a standards document for it.
- **GEN-04 - MUST** - Each script is self-contained and runnable directly
  (`./scripts/<category>/name.sh`). No shared library, no sourcing/dot-sourcing of
  other scripts in this repo, no dependence on the current working directory. Data
  files that sit next to a script are located relative to the script itself
  (`SH-33`, `PS-31`), and an optional one is documented as optional.
- **GEN-05 - MUST** - A template for a local, untracked config file is committed as
  `<stem>.sample.<ext>` next to the script; the real copy is git-ignored
  (`GEN-42`).

## File format

- **GEN-10 - MUST** - Script source is **ASCII only**: hyphen-minus instead of
  en/em dashes, straight quotes, `...` instead of an ellipsis character. If a
  non-ASCII character is genuinely required in a value, build it from an escape
  (`$'\u2014'` in Bash, `[char]0x2014` in PowerShell) instead of embedding it.
  *Why:* Windows PowerShell 5.1 reads a BOM-less file as ANSI (Windows-1252), so any
  non-ASCII byte is silently corrupted. One rule for every language is simpler than
  "ASCII, unless BOM". This applies to source files, not to files a script
  generates at run time (which use whatever encoding their consumer needs, and say
  so in a comment).
- **GEN-11 - MUST** - LF line endings (no CR), a final newline, no trailing
  whitespace, no tab characters. *Why:* a CR after the shebang makes the kernel
  look for the interpreter `bash\r`; a checkout on the Windows side with
  `autocrlf` will introduce them.
- **GEN-12 - MUST** - Indentation is spaces: 2 per level in Bash, 4 per level in
  PowerShell.
- **GEN-13 - SHOULD** - Wrap comments and prose at 80 columns and keep code within
  about 100. Long string literals, URLs, and `param` lines may exceed it. There is
  no hard limit.
- **GEN-14 - MUST** - Comments explain **why**, not what. No commented-out code. A
  `TODO` says what is left to do and why.
- **GEN-15 - SHOULD** - Divide a script into sections with the house banner: a
  comment line of `# ` plus 75 hyphens (77 columns), a `# Title` line, and a
  closing banner line. Use the same skeleton in both languages, omitting sections
  that don't apply:

  1. Header (`SH-04` / `PS-03`)
  2. Strict mode / `set -euo pipefail`
  3. Arguments (`SH-30`) / parameters (`PS-05`)
  4. Config (`GEN-40`)
  5. Helper functions
  6. Sanity checks (`GEN-31`)
  7. The work, in execution order
  8. Failure summary and `Done.` line (`GEN-51`)
- **GEN-16 - MUST** - Shell scripts are committed executable (git mode `100755`);
  `.ps1` files and data files are `100644`. *Why:* the Bash scripts are invoked as
  commands; PowerShell scripts run on Windows, where the mode is meaningless.

## Documentation

- **GEN-20 - MUST** - Every script opens with a header in its language's native
  form (`SH-04`, `PS-03`) covering:
  - what it does, in one to three sentences;
  - how to invoke it, if it takes arguments, options, or environment variables;
  - its **requirements**: tools, OS, privileges, network access, accounts;
  - anything surprising or destructive it does (`GEN-35`).
- **GEN-21 - MUST** - [README.md](../../README.md) has a `## scripts/<category>/<file>`
  section for every script, covering purpose, a usage example, every option or
  environment variable, and requirements. Add or update it in the same commit as
  the script. The script's own help output is the source of truth; the README must
  not disagree with it.
- **GEN-22 - MUST** - [CLAUDE.md](../../CLAUDE.md)'s layout tree is updated whenever
  a script is added, moved, renamed, or removed.
- **GEN-23 - MUST** - Requirements listed in the header, in the README, and in
  `flake.nix` (`GEN-60`) agree with each other.

## Behaviour

- **GEN-30 - MUST** - Exit status is `0` only on success. Any fatal error, and any
  batch run in which an item failed, exits non-zero. Finding nothing to do is
  success (exit `0` with a message). A script that deliberately exits non-zero in
  a non-error case (e.g. steps skipped by `-NoElevate`) documents it.
- **GEN-31 - MUST** - Validate before doing work: check dependencies (`GEN-61`),
  authentication, arguments, that the output location is writable, and that the
  output does not already exist, all **before** the first expensive or destructive
  step. *Why:* `github_backup.sh` refuses an existing archive before cloning a
  hundred repos, not after.
- **GEN-32 - MUST** - When operating on a list of items, a failure on one item
  is recorded and the loop continues; a summary of failures is printed at the end
  and the script exits non-zero if any failed (`FAILED=()` in Bash; a results
  list in PowerShell). Do not abort the whole run for one bad item unless the
  items depend on each other.
- **GEN-33 - MUST** - Never overwrite or delete pre-existing user data without an
  explicit `--force` / `-Force`. Without it, refuse with a clear message, or pick a
  non-colliding name and say so. A script may delete only what it created itself
  (its temp directory) or a target the user explicitly forced.
- **GEN-34 - SHOULD** - Be safe to re-run. A second run either reaches the same end
  state or fails cleanly before changing anything.
- **GEN-35 - MUST** - Document destructive or system-wide side effects and their
  blast radius in the header and README (for example, "cleanmgr ... **empties the
  Recycle Bin**" and runs against every fixed drive).
- **GEN-36 - SHOULD** - Scripts that delete, overwrite, or register persistent state
  offer a way to preview: `-WhatIf` in PowerShell (`PS-50`); `--dry-run` in Bash
  (MAY, when the script is destructive enough to warrant it).
- **GEN-37 - MUST** - No implicit privilege escalation. A script that needs
  Administrator/root says so up front: `#Requires -RunAsAdministrator` when it is
  always required; otherwise documented, prompted self-elevation with an opt-out
  (`PS-51`). Bash scripts MUST NOT call `sudo` unless the header and README say so.
- **GEN-38 - MUST NOT** - Persistently weaken system security (execution policy,
  Defender exclusions, UAC, firewall rules, world-writable permissions), and never
  download-and-execute remote code (`curl ... | sh`, `iwr ... | iex`). Installing a
  dependency from a package source the script's requirements already name (PSGallery
  module, winget package) is allowed when it is documented and scoped to the
  current user where possible.
- **GEN-39 - MUST NOT** - Block waiting for input unless documented. Provide a
  non-interactive path (a flag or argument) for anything that prompts. An
  "Press Enter to close" pause in a spawned window is documented behaviour, not an
  exception to this rule.

## Configuration and secrets

- **GEN-40 - MUST** - Tunable values (default owner names, device IDs, output
  locations, limits) live in a clearly labelled `Config` section near the top, not
  scattered through the logic. Bash exposes per-run overrides as environment
  variables with a default (`SH-32`); PowerShell exposes them as parameters
  with defaults. Every one is documented in the header and README.
- **GEN-41 - MUST NOT** - Commit, hard-code, print, or log secrets (tokens,
  passwords, keys). Take them from an environment variable or an interactive prompt
  (`SecureString`/`Get-Credential` in PowerShell), never a positional argument.
  When a tool forces a secret onto its command line (`7z -p...`), say so in the
  header and README, as `github_backup.sh` does.
- **GEN-42 - MUST** - Local, untracked config (for example `winget_ignore.txt`) is
  listed in `.gitignore`; only its `.sample` template is committed (`GEN-05`). A
  missing local config file is treated as "empty/defaults", not an error, unless
  the script cannot work without it.

## Output

- **GEN-50 - MUST** - Results and progress go to stdout; warnings and errors go to
  stderr (`>&2` in Bash; `Write-Warning`/`Write-Error` in PowerShell). Output is
  line-oriented and readable without color. If a script ever adds color, it MUST
  check that the output is a terminal and honour `NO_COLOR`.
- **GEN-51 - SHOULD** - Long-running scripts announce their target before starting
  (the archive path, the repo being cloned) and end with a `Done.` line stating
  what was produced and where.
- **GEN-52 - MUST** - An error message says what failed, quotes the offending
  value, and, where a fix exists, names it ("Pass --dest or set
  WIN_DOWNLOADS_DIR", "Install usbipd-win: <url>").

## Dependencies and paths

- **GEN-60 - MUST** - Every third-party tool a Linux/WSL script calls is listed in
  `devShells.default.packages` in [flake.nix](../../flake.nix) and named in the
  script's header. Tools the flake cannot supply (Windows-side 7-Zip, usbipd-win,
  winget, the `PSWindowsUpdate` module) are documented in the header and README
  instead.
- **GEN-61 - MUST** - Detect missing dependencies up front, before doing any work,
  with a message that names the missing tool (`Error: required command 'jq' not
  found in PATH.`). Use `command -v` in Bash and `Get-Command` in PowerShell.
- **GEN-62 - MUST NOT** - Hard-code the location of a tool (`/usr/bin/jq`,
  `/bin/bash`, `C:\Program Files\7-Zip\7z.exe`) as the only way to find it.
  Resolve it from `PATH`; falling back to a well-known install location after the
  `PATH` lookup fails is fine when documented (`Resolve-SevenZip` in
  `archive_directory.ps1`). Permitted fixed paths: `/usr/bin/env` in a shebang,
  WSL mount points (`/mnt/c`), and Windows system binaries built from
  `$env:SystemRoot`. *Why:* NixOS has no `/bin/bash` and no `/usr/bin/jq`.
- **GEN-63 - MUST** - Temporary files and directories are created uniquely
  (`mktemp` in Bash; a timestamped or GUID-named folder under `$env:TEMP` in
  PowerShell), never at a fixed, predictable name. They are removed on exit, or the
  script prints their location and documents that it keeps them.

## Version control

- **GEN-80 - MUST** - Commit messages use Conventional Commits:
  `type(scope): summary`. Types in use: `feat`, `fix`, `docs`, `ci`, `chore`
  (also `refactor` and `test` when applicable). Scope is optional and is usually
  the category directory or area (`maintenance`, `wsl`, `flake`, `standards`).
  Summary is lower-case imperative, no trailing period, about 72 characters or
  fewer. `chore(flake): sync YYYY-MM-DD` is the flake-lock refresh.
- **GEN-81 - MUST** - A script, its README section, and the CLAUDE.md layout entry
  (`GEN-21`, `GEN-22`) change in the same commit.
- **GEN-82 - MUST** - Scripts pass the linters (`shellcheck -x`, PSScriptAnalyzer)
  before they are committed. The `lefthook` pre-commit hooks and the CI workflows
  run the same checks.

## Checklist for a new or changed script

1. Path and name follow `GEN-01`/`GEN-02`; file is ASCII, LF, correct mode.
2. Header lists purpose, usage, requirements, and side effects.
3. Shebang/strict mode (Bash) or help block, `#Requires`, strict mode (PowerShell)
   are in place.
4. Dependencies are checked up front and are in `flake.nix` where Nix can provide
   them.
5. Failure paths exit non-zero; batch loops collect failures.
6. Nothing destructive happens without `--force`/`-Force`; secrets stay out of argv,
   logs, and the repo.
7. README section and CLAUDE.md layout entry are added or updated.
8. Linters pass; commit message follows `GEN-80`.
