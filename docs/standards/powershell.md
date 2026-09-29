# PowerShell standards

Applies to every `*.ps1` file, in addition to [general.md](general.md). See
[README.md](README.md) for how to read the rule keywords and IDs.

PowerShell scripts here run on the Windows side (WSL/usbipd helpers, Task
Scheduler, winget, Windows Update). The reference implementations are
[archive_directory.ps1](../../scripts/archive/archive_directory.ps1) (parameters,
`ShouldProcess`, native-tool handling) and
[windows_maintenance.ps1](../../scripts/maintenance/windows_maintenance.ps1)
(orchestration, self-elevation, result collection).

## Baseline

- **PS-01 - MUST** - Target **Windows PowerShell 5.1**, the in-box `powershell.exe`,
  and stay compatible with PowerShell 7 unless the script declares
  `#Requires -Version 7` and the README says so. Do not use 7-only syntax or
  parameters: `??`, `??=`, `?.`, the ternary `? :`, the `&&` / `||` pipeline chain
  operators, `ForEach-Object -Parallel`, `-Encoding utf8NoBOM`, `Get-Content
  -AsByteStream`. *Why:* CI and the pre-commit hook run PSScriptAnalyzer under
  PowerShell 7 on Linux, so a construct that fails to parse on 5.1 would pass
  every check and break on the machine that runs it.
- **PS-02 - MUST** - `#Requires -Version 5.1` is present (after the help block, before
  `param`). Add `#Requires -RunAsAdministrator` as well when the script always
  needs elevation (`GEN-37`). A script that elevates only some of the time does
  **not** use it and follows `PS-51`.
- **PS-03 - MUST** - The file starts with a comment-based help block (`<# ... #>`) with:
  - `.SYNOPSIS` - one or two lines;
  - `.DESCRIPTION` - behaviour, side effects, and blast radius (`GEN-35`);
  - `.PARAMETER <Name>` for **every** parameter, including internal ones (worded
    "Internal. ... Not meant to be passed by hand.");
  - `.EXAMPLE` - **SHOULD** have at least one for any script with parameters;
  - `.NOTES` - a `Requirements:` entry listing OS, PowerShell version, tools,
    modules, and privileges (`GEN-20`).
- **PS-04 - MUST** - The first two statements after the `param` block are
  `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. (`param`
  must come first, so they cannot go earlier.) They are the PowerShell counterpart
  of `set -euo pipefail`.
- **PS-05 - MUST** - A script with a `param` block declares `[CmdletBinding()]` (or
  `[CmdletBinding(SupportsShouldProcess)]`). Every parameter has a type. Constrain
  values with `[Parameter(Mandatory)]`, `[ValidateSet()]`, `[ValidateRange()]`, and
  `[ValidatePattern()]` rather than checking by hand. Internal, self-relaunch
  parameters carry a `# Internal` comment in the block and are documented as
  internal in `.PARAMETER` and the README (`windows_maintenance.ps1`:
  `-Relaunched`, `-RunStep`, `-RunDir`).

## Style

- **PS-10 - MUST** - Four-space indentation.
- **PS-11 - MUST** - Braces: the opening brace is on the same line; `else`, `elseif`,
  `catch`, and `finally` start on a new line after the closing brace. Braces are
  never omitted, even for one-line bodies.

  ```powershell
  try {
      $value = Get-Thing
  }
  catch {
      Write-Warning "Get-Thing failed: $($_.Exception.Message)"
  }
  ```
- **PS-12 - MUST** - Naming:
  - functions are `Verb-Noun` with an approved verb (`Get-Verb`), PascalCase,
    singular noun (`Resolve-SevenZip`, `Test-Administrator`);
  - parameters and script-level config values are PascalCase (`$TaskName`,
    `$VidPid`);
  - local variables are camelCase (`$busId`, `$sevenZip`);
  - shared script state is `$script:PascalCase` (`$script:Results`).
- **PS-13 - SHOULD** - Use single-quoted strings for literals and double-quoted only
  for interpolation. A variable directly followed by `:` inside a double-quoted
  string is written `${name}:`, or PowerShell reads `$name:` as a scope or drive
  qualifier.
- **PS-14 - MUST** - Use full cmdlet names and named parameters; no aliases (`gci`,
  `%`, `?`, `iwr`, `curl`) and no positional parameters beyond the obvious first
  one. Each helper function starts with a `#` comment inside its body stating
  its purpose, and declares its parameters in an explicit `param()` block.
- **PS-15 - SHOULD** - Prefer splatting (`@args`) or a pipeline/parenthesis continuation
  over backtick line continuation for calls with many parameters. Existing
  backtick continuations are tolerated; new code should not add more.
- **PS-16 - SHOULD** - Follow the section skeleton in `GEN-15`, with the same 77-column
  banner as Bash:

  ```powershell
  # ---------------------------------------------------------------------------
  # Sanity checks
  # ---------------------------------------------------------------------------
  ```

## Errors and control flow

- **PS-20 - MUST** - A fatal condition (missing prerequisite, invalid input) is
  `Write-Error "<message>"` followed by `exit 1`. Under
  `$ErrorActionPreference = 'Stop'`, `Write-Error` already raises a terminating
  error, so the `exit 1` is a statement of intent that keeps the exit code explicit;
  keep it for consistency. Messages follow `GEN-52`.
- **PS-21 - MUST** - Native executables are invoked with the call operator and an
  argument array (`& $sevenZip @sevenZipArgs`), and `$LASTEXITCODE` is checked
  **immediately** afterwards - `$ErrorActionPreference = 'Stop'` does not turn a
  non-zero exit code into an error. Copy it to a variable
  (`$exitCode = $LASTEXITCODE`) if anything runs before it is used. When a tool has
  meaningful non-error codes (7-Zip `1` = warning, winget `0x8A15002B` = nothing to
  upgrade), handle them by name.
- **PS-22 - MUST NOT** - Use `Invoke-Expression`. When `Start-Process -ArgumentList`
  receives arguments that may contain whitespace, quote them first
  (`Format-ProcessArgument` in `windows_maintenance.ps1`): `Start-Process` joins
  the tokens with spaces and does no quoting of its own.
- **PS-23 - MUST** - `try/catch` wraps operations that are expected to fail and
  reports something actionable. A `catch` block is never empty: warn, log with
  `Write-Verbose`, or rethrow. `-ErrorAction SilentlyContinue` is for existence
  probes (`Get-Command x -ErrorAction SilentlyContinue`), not for operations whose
  failure matters.
- **PS-24 - MUST** - Exit `0` on success and non-zero on failure. Pass through a
  child tool's exit code when it is meaningful (`exit $exitCode`); an orchestrator
  that relaunches itself mirrors the child's exit code.
- **PS-25 - MUST** - Batch work collects results in a list (`$script:Results`), prints an
  `OK` / `FAIL` / `SKIP` summary at the end, and exits non-zero if anything
  failed (`GEN-32`).

## Paths and files

- **PS-30 - MUST** - Pass paths that come from variables or user input with
  `-LiteralPath` on every cmdlet that has it (`Test-Path`, `Get-Item`,
  `Get-ChildItem`, `Get-Content`, `Set-Content`, `Remove-Item`, `Resolve-Path`,
  `Copy-Item`). Use `-Path` only when wildcard expansion is intended, and say so in
  a comment. Build paths with `Join-Path`, not string concatenation.
- **PS-31 - MUST** - Locate well-known folders through environment variables or the
  shell API (`$env:USERPROFILE`, `$env:ProgramFiles`, `$env:SystemRoot`,
  `$env:TEMP`; the Downloads known-folder lookup in `archive_directory.ps1`); never
  hard-code a user name or drive letter. Locate files next to the script with
  `$PSScriptRoot`, not the working directory (`GEN-04`).
- **PS-32 - MUST** - State `-Encoding` explicitly on `Set-Content`, `Add-Content`,
  `Out-File`, and `Export-*`, and when reading text whose encoding matters.
  *Why:* on 5.1 the defaults differ per cmdlet (`Set-Content` is ANSI, `Out-File`
  and `>` are UTF-16LE). Comment the choice, as the VBScript wrapper in
  `register_yubikey_attach_task.ps1` does.

## Output

- **PS-40 - MUST** - Use `Write-Output` for results and progress, `Write-Warning` for
  warnings, `Write-Error` for errors, and `Write-Verbose` for diagnostics shown only
  with `-Verbose`. **Never `Write-Host`** (it bypasses the pipeline and cannot be
  redirected; PSScriptAnalyzer `PSAvoidUsingWriteHost`). `Read-Host` only for a
  documented interactive pause (`GEN-39`).
- **PS-41 - MUST** - A function that returns a value emits only that value. It reports
  progress with `Write-Verbose`/`Write-Warning`, not `Write-Output`, because
  anything else written to the output stream becomes part of the return value.
  Discard unwanted output with `| Out-Null` or `[void]`.

## Side effects and elevation

- **PS-50 - SHOULD** - A script that creates, changes, or removes persistent state
  (files, registry values, scheduled tasks, devices) declares
  `[CmdletBinding(SupportsShouldProcess)]` and gates each such action with
  `$PSCmdlet.ShouldProcess(...)`, so `-WhatIf` and `-Confirm` work and `-WhatIf` has
  no side effects (`archive_directory.ps1`). It is **MUST** where the script can
  delete or overwrite user data (`GEN-33`, `GEN-36`).
- **PS-51 - MUST** - Conditional self-elevation (`windows_maintenance.ps1`) is
  allowed only when it:
  1. detects the current state (`Test-Administrator`) and elevates **only** when a
     step that needs it will actually run;
  2. relaunches with a UAC prompt (`Start-Process -Verb RunAs`) and mirrors the
     child's exit code;
  3. provides an opt-out (`-NoElevate`) under which the affected work is skipped
     and reported, not attempted;
  4. is described in `.DESCRIPTION` and the README (`GEN-37`).

## Linting

- **PS-60 - MUST** - `Invoke-ScriptAnalyzer -Severity Warning,Error` reports nothing
  with the default rule set (the same command the `lefthook` hook and CI run).
  Suppress a finding only with `[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]`
  on the smallest enclosing scope, and add a comment giving the reason. The default
  rules do not check that a command exists, so Windows-only cmdlets do not trip
  the Linux CI run; do not contort the code to satisfy a linter about that.
- **PS-61 - SHOULD** - Add a `PSUseCompatibleSyntax` check targeting 5.1 to catch
  `PS-01` violations mechanically. Not enabled yet; see
  [adoption.md](adoption.md).
