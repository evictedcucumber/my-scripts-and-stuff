# Bash standards

Applies to every `*.sh` file, in addition to [general.md](general.md). See
[README.md](README.md) for how to read the rule keywords and IDs.

The reference implementations are
[github_backup.sh](../../scripts/git/github_backup.sh) (environment-driven, batch
loop, temp dir) and
[copy_to_downloads.sh](../../scripts/wsl/copy_to_downloads.sh) (argument parsing,
WSL interop).

## Baseline

- **SH-01 - MUST** - Line 1 is exactly `#!/usr/bin/env bash`. Never `#!/bin/bash`,
  `#!/usr/bin/bash`, `#!/bin/sh`, or a Nix-store path, and no flags on the shebang
  line (`#!/usr/bin/env bash -e` does not work on Linux; use `set`, `SH-05`).
  *Why:* NixOS has no `/bin/bash`. `/usr/bin/env` is the one path that exists on
  every target, and it finds whichever Bash is first on `PATH` (including the flake
  devShell's).
- **SH-02 - MUST** - Bash only. No POSIX `sh` scripts; Bash features (arrays,
  `[[ ]]`, `mapfile`, `local -a`) are expected.
- **SH-03 - MUST** - Target Bash 4.4 or newer. Don't add workarounds for macOS's
  Bash 3.2. *Why:* the scripts expand possibly-empty arrays under `set -u` and use
  `mapfile`, which need 4.4 / 4.0.
- **SH-04 - MUST** - The header is a comment block directly after the shebang, then
  `set -euo pipefail` directly after the header:

  ```bash
  #!/usr/bin/env bash
  #
  # script_name.sh
  #
  # What it does, in one to three sentences.
  #
  # Usage:
  #   script_name.sh [options] <arg>
  #
  # Options:
  #   -f, --force   What it does.
  #   -h, --help    Show this help.
  #
  # Requirements: gh, git, jq
  #
  set -euo pipefail
  ```

  `Usage`/`Options` are omitted for scripts that take neither arguments nor
  environment variables; environment variables get an `Environment:` list.
  `Requirements` is always present (`GEN-20`).
- **SH-05 - MUST** - `set -euo pipefail` is present and is the first executable line.
  Do not turn it off (`set +e`) except around a single command, with a comment
  saying why. Do not rely on `set -e` for control flow (`SH-21`).
- **SH-06 - MUST** - The file is executable and runnable as
  `./scripts/<category>/name.sh` (`GEN-16`).

## Style

- **SH-10 - MUST** - Two-space indentation. `then` and `do` share the line of their
  `if`/`for`/`while`. `case` patterns are indented one level under `case`, bodies
  one more, `;;` aligned with the body, and `|` in alternations has a space on each
  side:

  ```bash
  case "$1" in
    -f | --force)
      FORCE=true
      shift
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      exit 1
      ;;
  esac
  ```
- **SH-11 - MUST** - Functions are written `name() {` (no `function` keyword), named
  in `snake_case`, and defined before their first use. Every variable assigned in
  a function is `local`. When the exit status of a command substitution matters,
  declare and assign separately (`local out; out="$(cmd)"`), because
  `local out="$(cmd)"` discards the status (SC2155).
- **SH-12 - MUST** - Naming: configuration, constants, and script-level state are
  `UPPER_SNAKE_CASE` (`OUTPUT_DIR`, `FAILED`); function-local and loop variables are
  `lower_snake_case`; a throwaway temporary starts with an underscore
  (`_extra_ignore`). Export a variable only when a child process needs it.
- **SH-13 - MUST** - Conditionals use `[[ ... ]]`, never `[ ... ]` or `test`. Use
  `==` for string equality. Compare numbers with `-eq`/`-lt`... inside `[[ ]]`, or
  use `(( ))`.
- **SH-14 - MUST** - Use `$(...)` for command substitution, never backticks.
- **SH-15 - MUST** - Quote every expansion unless word splitting or globbing is
  intended; if it is, comment why. Hold lists of values and command arguments in
  arrays and expand them as `"${arr[@]}"` (`CREATE_ARGS=(a -t7z -mx=9)`); never
  build a command in a string.
- **SH-16 - MUST** - Print variable data with `printf '%s\n' "$var"`, not `echo`
  (`echo` may swallow `-n`/`-e` or interpret backslashes). `echo` is fine for
  literal messages. No `echo -e`. Static multi-line text (usage) uses a heredoc
  with a quoted delimiter (`<<'EOF'`).
- **SH-17 - MUST** - Put `--` before paths that come from a variable or from user
  input, so a leading `-` is not read as an option:
  `cp -- "$src" "$dst"`, `rm -rf -- "$path"`, `cd -- "$dir"`, `basename -- "$p"`.
- **SH-18 - MUST NOT** - Delete a path built by concatenating a variable that might
  be empty (`rm -rf "$dir/"*`). Use `"${dir:?}"` or check the value first.
- **SH-19 - SHOULD** - Follow the section skeleton in `GEN-15`, with the banner
  rendered as a 77-column comment:

  ```bash
  # ---------------------------------------------------------------------------
  # Sanity checks
  # ---------------------------------------------------------------------------
  ```

## Control flow and errors

- **SH-20 - MUST** - Guard clauses, not nesting. Handle the failure and
  `continue`/`exit`/`return`, then let the success path run at the outer level:
  `if ! cmd; then handle_error; continue; fi`.
- **SH-21 - MUST** - Remember that `set -e` is **ignored** inside anything used as an
  `if`/`while`/`!`/`&&`/`||` condition, including functions and subshells called
  from there. A multi-step function used as `if ! prepare_repo ...; then` does not
  stop at a failing step by itself, so each critical command inside it ends with
  `|| return 1` (or `|| exit 1` in a subshell) - see `prepare_repo` in
  `github_backup.sh`. A subshell that is only the last statement of an `if ... then`
  body silently discards its status; check it in a guard clause instead.
  `cmd || true` is allowed only with a comment saying why the failure is
  acceptable.
- **SH-22 - MUST** - Fatal errors are `echo "Error: <message>" >&2` followed by
  `exit 1`. Warnings are `echo "WARNING: <message>" >&2` and execution continues.
  A usage error prints the error and then the usage text to stderr and exits `1`.
  Messages follow `GEN-52`.
- **SH-23 - MUST** - Batch operations collect failures into a `FAILED=()` array,
  keep going, print the list at the end, and exit non-zero if it is non-empty
  (`GEN-32`).
- **SH-24 - MUST** - Scratch space comes from `mktemp -d` (with a template that names
  the script, e.g. `-t gh-backup.XXXXXXXX`), and `trap cleanup EXIT` is registered
  immediately after it is created, before anything that can fail. `cleanup` removes
  only that directory. Never use a fixed name under `/tmp` (`GEN-63`).
- **SH-25 - MUST** - Check dependencies with `command -v tool >/dev/null 2>&1` (never
  `which` or `type`), in a single loop over the required commands, before any work:
  `Error: required command 'x' not found in PATH.` (`GEN-61`).
- **SH-26 - SHOULD** - Read command output into arrays with
  `mapfile -t arr < <(cmd)` rather than `cmd | while read`, so variables set in the
  loop survive. Prefer process substitution to a here-string: `mapfile <<< ""`
  yields one empty element that has to be normalised away (as `github_backup.sh`
  does), while `< <(printf '')` yields none. Always `read -r`.
- **SH-27 - MUST NOT** - Use `eval`, or `source` a file the user supplies. Parse JSON
  with `jq` (or `gh --json ... --jq`), never with `grep`/`sed`. Do not parse `ls`.

## Arguments, help, and configuration

- **SH-30 - MUST** - A script that takes arguments parses them with
  `while [[ $# -gt 0 ]]; do case "$1" in ... esac; done` (not `getopts`, so long
  options work) and:
  - accepts `-h`/`--help` (usage to stdout, exit `0`);
  - accepts `--` to end option parsing;
  - rejects unknown `-*` options (`Error: unknown option: ...`, usage to stderr,
    exit `1`);
  - checks that an option that takes a value has one (`[[ $# -ge 2 ]]`);
  - rejects surplus positional arguments;
  - sets its defaults before the loop.
- **SH-31 - SHOULD** - Text for `--help` comes from a `usage()` function printing a
  quoted heredoc, kept in step with the header comment. Scripts that take no
  arguments SHOULD still answer `-h`/`--help` and SHOULD reject unexpected
  arguments rather than ignoring them.
- **SH-32 - MUST** - Environment-variable configuration is written
  `NAME="${NAME:-default}"` in the `Config` section, documented in the header and
  README (`GEN-40`), and validated up front. Secrets come from the environment,
  never from a positional argument (`GEN-41`).
- **SH-33 - MUST** - Do not depend on the working directory. When the script needs a
  sibling file, resolve its own directory with
  `"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"`. Defaulting an output
  directory to `$PWD` is allowed when it is documented.

## Linting

- **SH-50 - MUST** - `shellcheck -x` reports nothing, at any severity. Suppress a
  finding only with a `# shellcheck disable=SCxxxx` directive on the line directly
  above the command it applies to, followed by the reason on the same line - never
  file-wide and never in a shared rc file:

  ```bash
  # shellcheck disable=SC2016  # $k/$g/$p/$env are PowerShell vars, kept literal
  ```

  Where a script uses `source`, add a `# shellcheck source=...` directive so `-x`
  can follow it.
- **SH-51 - MAY** - Format with `shfmt -i 2 -ci`. Not required yet; see
  [adoption.md](adoption.md).
