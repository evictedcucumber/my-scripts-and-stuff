# Script standards

Standards that apply to every script in this repository. [CLAUDE.md](../../CLAUDE.md)
describes the repo layout and how to work in it; [README.md](../../README.md)
documents what each script does; these documents define **what a script must look
like**.

> **Status: defined, not yet applied.** These documents were written on
> 2026-09-29 by reviewing the existing scripts, CI, and hooks. They describe the
> target state. Nothing in the repo has been changed to conform yet, and some
> existing files deviate. The deviations, and the tooling that would enforce each
> rule, are tracked in [adoption.md](adoption.md).

## Documents

| Document | Applies to |
| --- | --- |
| [general.md](general.md) | Every script, any language: layout, naming, file format, headers, config, secrets, safety, output, dependencies, git. |
| [bash.md](bash.md) | Every `*.sh` file. |
| [powershell.md](powershell.md) | Every `*.ps1` file. |
| [adoption.md](adoption.md) | What is enforced today, what is planned, and known deviations from these rules. |

A script must satisfy `general.md` **and** the document for its language.

## How to read the rules

- **Keywords.** MUST / MUST NOT are requirements with no exceptions unless a rule
  says so. SHOULD / SHOULD NOT are the default; deviate only with a reason. MAY is
  optional.
- **IDs.** Every rule has a stable ID (`GEN-30`, `SH-01`, `PS-04`). IDs are never
  renumbered or reused; a removed rule leaves a gap. Reference them in commit
  messages, reviews, and exception comments.
- **Why.** Most rules carry a short rationale. If you can't see the point of a
  rule, the rationale is where to check whether it still applies.
- **Examples.** The existing scripts are the reference implementations; the rules
  were derived from them. Where a rule cites a script, that script shows the
  pattern.

## Exceptions

A script may deviate from a rule only when the deviation is deliberate and visible:

- If a linter flags it, use the linter's own suppression mechanism, scoped to the
  smallest possible region, with the reason next to it (see `SH-50`, `PS-60`).
- Otherwise, put a comment on or directly above the deviating code:
  `# standards-exception: SH-17 <reason>` (Bash) or
  `# standards-exception: PS-14 <reason>` (PowerShell). The prefix is greppable so
  exceptions can be audited.
- If the same exception keeps recurring, the rule is wrong; change the rule.

## Changing the standards

1. Edit the relevant document. Keep IDs stable; add new rules at the end of their
   section with the next unused number.
2. Update [adoption.md](adoption.md) so its deviation list and enforcement table
   stay accurate.
3. If [CLAUDE.md](../../CLAUDE.md)'s condensed "Bash standards" / "PowerShell
   standards" sections would now disagree with these documents, update them in the
   same commit. (Long term they should link here instead of restating the rules;
   see [adoption.md](adoption.md).)
4. Use a `docs(standards): ...` commit; if the change also brings scripts into
   line, say so in the body.

## Where the standards come from

Rules are grouped by the reason they exist, which helps when deciding whether one
applies to a new situation:

- **Portability**: the scripts run on NixOS/WSL and on Windows with Windows
  PowerShell 5.1 (`GEN-10`, `GEN-11`, `GEN-62`, `SH-01`, `PS-01`).
- **Fail loudly**: a script that half-works and exits 0 is worse than one that
  stops (`GEN-30`-`GEN-33`, `SH-05`, `SH-21`, `PS-04`, `PS-21`).
- **Protect the user's data**: no silent overwrites, no surprise deletions, no
  secrets in the repo or in logs (`GEN-33`, `GEN-35`, `GEN-41`).
- **Self-contained**: each script runs on its own and documents its own
  requirements (`GEN-04`, `GEN-20`, `GEN-60`).
- **Lint-clean**: `shellcheck` and PSScriptAnalyzer are the automated floor
  (`SH-50`, `PS-60`).
