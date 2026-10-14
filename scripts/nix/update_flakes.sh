#!/usr/bin/env bash
#
# update_flakes.sh
#
# Recursively finds every flake.nix under ~/repos (override with REPOS_DIR=...),
# runs `nix flake update` next to each one, and commits the resulting flake.lock
# change with the message "chore(flake): sync YYYY-MM-DD". Never pushes.
#
# Intermediate directories (e.g. ~/repos/homelab/) need not be repos or flakes
# themselves - the search descends through them. Never searched: .git,
# node_modules, .direnv and .claude directories at any depth, plus
# <root>/archive-forks (managed by sync_archive_forks.sh). A flake is skipped (and
# reported) if it is not inside a git repo, is inside a linked git worktree
# (the main checkout is the one that gets updated), has a gitignored
# flake.lock, or already has uncommitted changes to flake.lock (so the sync
# commit never swallows unrelated work). Only flake.lock files are committed;
# other staged or unstaged changes in the repo are left alone.
#
# Exits 1 if any flake failed to update or any commit failed; skipped flakes
# are reported but do not fail the run.
#
# Usage:
#   update_flakes.sh [options] [--] [IGNORE...]
#
# Options:
#   -h, --help   Show this help.
#
# Each IGNORE is a directory to leave out (with everything beneath it):
#   - an absolute path            (/home/me/repos/homelab/lab)
#   - a path relative to $PWD     (../repos/homelab/lab, ./lab), or relative to
#                                 the search root (homelab/lab)
#   - a bare name, which matches any directory with that name under the root
#                                 (homelab skips ~/repos/homelab and anything
#                                 else called homelab)
#
# Environment:
#   REPOS_DIR   Directory to search (default: ~/repos).
#
# Requirements: nix (with flakes enabled), git, find, realpath
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Directory to search. Override with REPOS_DIR=... in the env.
ROOT="${REPOS_DIR:-$HOME/repos}"

usage() {
  cat <<'EOF'
Usage: update_flakes.sh [options] [--] [IGNORE...]

Run `nix flake update` for every flake.nix under ~/repos and commit the
resulting flake.lock change as "chore(flake): sync YYYY-MM-DD". Never pushes.

Options:
  -h, --help   Show this help.

Each IGNORE is a directory to leave out (with everything beneath it):
  - an absolute path            (/home/me/repos/homelab/lab)
  - a path relative to $PWD     (../repos/homelab/lab, ./lab), or relative to
                                the search root (homelab/lab)
  - a bare name, which matches any directory with that name under the root
                                (homelab skips ~/repos/homelab and anything
                                else called homelab)

Environment:
  REPOS_DIR   Directory to search (default: ~/repos).

Always left out: .git, node_modules, .direnv and .claude directories at any
depth, and <root>/archive-forks.

Exits 1 if any flake failed to update or any commit failed.
EOF
}

# ---------------------------------------------------------------------------
# Ignore list
# ---------------------------------------------------------------------------

IGNORE_PATHS=() # absolute paths; each also excludes everything beneath it
IGNORE_NAMES=() # bare names; matched against every path component under ROOT

add_ignore() {
  local arg="$1"

  # A quoted "~/x" isn't expanded by the shell; do it here.
  if [[ "$arg" == \~ || "$arg" == \~/* ]]; then
    arg="${HOME}${arg:1}"
  fi
  arg="${arg%/}"
  [[ -z "$arg" ]] && return 0

  if [[ "$arg" != */* ]]; then
    IGNORE_NAMES+=("$arg")
  fi

  # Relative to the current directory (also covers absolute paths)...
  IGNORE_PATHS+=("$(realpath -m -- "$arg")")

  # ...and, for relative paths, relative to the search root.
  if [[ "$arg" != /* && "$arg" == */* ]]; then
    IGNORE_PATHS+=("$(realpath -m -- "$ROOT/$arg")")
  fi
}

is_ignored() {
  local dir="$1" ignored name component
  local -a components

  for ignored in "${IGNORE_PATHS[@]}"; do
    [[ "$dir" == "$ignored" || "$dir" == "$ignored"/* ]] && return 0
  done

  # Only components below ROOT count, so a name never matches the root's own
  # ancestors (e.g. "repos").
  IFS=/ read -r -a components <<< "${dir#"$ROOT"}"
  for name in "${IGNORE_NAMES[@]}"; do
    for component in "${components[@]}"; do
      [[ "$component" == "$name" ]] && return 0
    done
  done

  return 1
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

IGNORE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      IGNORE_ARGS+=("$@")
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      IGNORE_ARGS+=("$1")
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

for cmd in nix git find realpath; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

if [[ ! -d "$ROOT" ]]; then
  echo "Error: search directory does not exist: $ROOT" >&2
  exit 1
fi
ROOT="$(realpath -- "$ROOT")"

for arg in "${IGNORE_ARGS[@]}"; do
  add_ignore "$arg"
done

COMMIT_MESSAGE="chore(flake): sync $(date +%F)"

# ---------------------------------------------------------------------------
# Find flakes
# ---------------------------------------------------------------------------

echo "Searching for flakes under $ROOT..."

FLAKE_FILES=()
mapfile -d '' -t FLAKE_FILES < <(
  find "$ROOT" \
    \( -name .git -o -name node_modules -o -name .direnv -o -name .claude \
    -o -path "$ROOT/archive-forks" \) -prune -o \
    -type f -name flake.nix -print0 | sort -z
)

if [[ ${#FLAKE_FILES[@]} -eq 0 ]]; then
  echo "No flakes found."
  exit 0
fi

# ---------------------------------------------------------------------------
# Update flakes
# ---------------------------------------------------------------------------

FAILED=()
SKIPPED=()
REPO_ORDER=()      # repo toplevels, in first-seen order
declare -A REPO_LOCKS=() # toplevel -> newline-separated updated flake.lock paths

update_flake() {
  ( cd -- "$1" && nix flake update )
}

for flake_file in "${FLAKE_FILES[@]}"; do
  dir="${flake_file%/flake.nix}"

  if is_ignored "$dir"; then
    echo "Skipping (ignored): $dir"
    continue
  fi

  echo
  echo "==== $dir ===="

  if ! top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "Skipping: not inside a git repo"
    SKIPPED+=("$dir (not a git repo)")
    continue
  fi

  if ! git_dir="$(git -C "$dir" rev-parse --path-format=absolute --git-dir)" ||
    ! common_dir="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)"; then
    echo "WARNING: 'git rev-parse' failed in $dir" >&2
    FAILED+=("$dir (git rev-parse)")
    continue
  fi
  if [[ "$git_dir" != "$common_dir" ]]; then
    echo "Skipping: linked git worktree"
    SKIPPED+=("$dir (linked worktree)")
    continue
  fi

  lock="$dir/flake.lock"

  if git -C "$top" check-ignore -q -- "$lock"; then
    echo "Skipping: flake.lock is gitignored"
    SKIPPED+=("$dir (flake.lock is gitignored)")
    continue
  fi

  if [[ -n "$(git -C "$top" status --porcelain -- "$lock")" ]]; then
    echo "Skipping: flake.lock already has uncommitted changes"
    SKIPPED+=("$dir (flake.lock has uncommitted changes)")
    continue
  fi

  if ! update_flake "$dir"; then
    echo "WARNING: 'nix flake update' failed in $dir" >&2
    FAILED+=("$dir (nix flake update)")
    continue
  fi

  if [[ -z "${REPO_LOCKS[$top]:-}" ]]; then
    REPO_ORDER+=("$top")
    REPO_LOCKS["$top"]="$lock"
  else
    REPO_LOCKS["$top"]+=$'\n'"$lock"
  fi
done

# ---------------------------------------------------------------------------
# Commit (once per repo, only the flake.lock files)
# ---------------------------------------------------------------------------

COMMITTED=()

for top in "${REPO_ORDER[@]}"; do
  mapfile -t locks <<< "${REPO_LOCKS[$top]}"

  echo
  echo "==== $top ===="

  if [[ -z "$(git -C "$top" status --porcelain -- "${locks[@]}")" ]]; then
    echo "Already up to date; nothing to commit."
    continue
  fi

  if ! git -C "$top" add -- "${locks[@]}"; then
    echo "WARNING: 'git add' failed in $top" >&2
    FAILED+=("$top (git add)")
    continue
  fi

  if ! git -C "$top" commit -m "$COMMIT_MESSAGE" -- "${locks[@]}"; then
    echo "WARNING: 'git commit' failed in $top" >&2
    FAILED+=("$top (git commit)")
    continue
  fi

  COMMITTED+=("$top")
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "Done. Committed in ${#COMMITTED[@]} repo(s) (not pushed)."

if [[ ${#COMMITTED[@]} -gt 0 ]]; then
  printf '  %s\n' "${COMMITTED[@]}"
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo
  echo "Skipped:"
  printf '  %s\n' "${SKIPPED[@]}"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  echo "Failed:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
  exit 1
fi
