#!/usr/bin/env bash
#
# github_backup.sh
#
# Backs up all GitHub repos owned by a configurable user (public and private,
# see OWNER below) into a single 7z archive. Creates normal, browsable
# repositories with working trees and full .git history. All branches are
# fetched and local branches are created for every remote branch so the backup
# is self-contained.
#
# Exits 1 if any repo failed to clone or prepare. The archive is still created
# from the repos that succeeded, so a partial backup is kept but flagged.
#
# Usage:
#   github_backup.sh [-h|--help]
#
# Environment:
#   OWNER               GitHub user/org to back up (default: evictedcucumber).
#   OUTPUT_DIR          Where the archive is written (default: current
#                       directory). Created if missing.
#   GH_BACKUP_IGNORE    Extra "owner/name" repos to skip, space- or
#                       newline-separated, appended to IGNORE_LIST below.
#   GH_BACKUP_PASSWORD  If set, encrypts the archive (7z -mhe=on). 7z takes the
#                       password as a -p... command-line argument, so it is
#                       visible to other local users via `ps` while 7z runs;
#                       only use this on a trusted host.
#
# Requirements: gh (authenticated), git, 7z, jq
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: github_backup.sh [-h|--help]

Back up every GitHub repo owned by OWNER into a single 7z archive.
Configured through environment variables, not arguments.

Environment:
  OWNER               GitHub user/org to back up (default: evictedcucumber).
  OUTPUT_DIR          Where the archive is written (default: current directory).
  GH_BACKUP_IGNORE    Extra "owner/name" repos to skip (space/newline separated).
  GH_BACKUP_PASSWORD  Encrypt the archive with this password. Visible in the
                      process list while 7z runs; use on a trusted host only.

Exits 1 if any repo failed; the archive is still created from the rest.

Options:
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "Error: unexpected argument: $1 (this script takes no arguments)." >&2
  usage >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# GitHub user/org whose repos to back up. Override with OWNER=... in the env.
OWNER="${OWNER:-evictedcucumber}"

# Repos to skip, as "owner/name" (e.g. evictedcucumber/some-repo). Extra entries
# can be passed at run time via GH_BACKUP_IGNORE (space- or newline-separated),
# which is appended to this list.
IGNORE_LIST=()

if [[ -n "${GH_BACKUP_IGNORE:-}" ]]; then
  # -d '' so the read spans newlines too; it returns non-zero at EOF (no NUL).
  read -r -d '' -a _extra_ignore <<< "$GH_BACKUP_IGNORE" || true
  IGNORE_LIST+=("${_extra_ignore[@]}")
fi

OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%SZ)"
ARCHIVE_NAME="github-backup-${TIMESTAMP}.7z"

# Optional archive password. NOTE: 7z takes the password as a command-line
# argument (-p...), so while 7z runs it is visible to other local users via
# `ps`. p7zip offers no stdin/env alternative; only run this on a trusted host.
ARCHIVE_PASSWORD="${GH_BACKUP_PASSWORD:-}"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

for cmd in gh git 7z jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

# Normalise the output dir to an absolute path and confirm it is writable
# *before* doing the expensive clone loop.
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
if [[ ! -w "$OUTPUT_DIR" ]]; then
  echo "Error: output directory is not writable: $OUTPUT_DIR" >&2
  exit 1
fi

ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"

if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "Error: archive already exists: $ARCHIVE_PATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build repo list
# ---------------------------------------------------------------------------

echo "Fetching repo list from GitHub..."

LIST_ARGS=(
  repo list "$OWNER"
  --limit 1000
  --json nameWithOwner
  --jq '.[].nameWithOwner'
)

if ! repo_list="$(gh "${LIST_ARGS[@]}")"; then
  echo "Error: 'gh repo list $OWNER' failed." >&2
  exit 1
fi

mapfile -t ALL_REPOS <<< "$repo_list"

# mapfile on an empty string yields a single empty element - normalise to [].
if [[ ${#ALL_REPOS[@]} -eq 1 && -z "${ALL_REPOS[0]}" ]]; then
  ALL_REPOS=()
fi

if [[ ${#ALL_REPOS[@]} -eq 0 ]]; then
  echo "Error: no repos returned for owner '$OWNER'." >&2
  exit 1
fi

if [[ ${#ALL_REPOS[@]} -eq 1000 ]]; then
  echo "WARNING: hit --limit 1000; some repos may be missing from the backup." >&2
fi

REPOS=()

for repo in "${ALL_REPOS[@]}"; do
  skip=false

  for ignored in "${IGNORE_LIST[@]}"; do
    [[ -z "$ignored" ]] && continue
    if [[ "$repo" == "$ignored" ]]; then
      skip=true
      break
    fi
  done

  if [[ "$skip" == true ]]; then
    echo "Skipping (ignored): $repo"
  else
    REPOS+=("$repo")
  fi
done

echo "Found ${#ALL_REPOS[@]} repo(s), backing up ${#REPOS[@]}."

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "Nothing to back up."
  exit 0
fi

# ---------------------------------------------------------------------------
# Temp directory
# ---------------------------------------------------------------------------

WORKDIR="$(mktemp -d -t gh-backup.XXXXXXXX)"
echo "Using temp dir: $WORKDIR"

cleanup() {
  echo "Cleaning up temp dir: $WORKDIR"
  rm -rf -- "${WORKDIR:?}"
}

trap cleanup EXIT

FAILED=()

# ---------------------------------------------------------------------------
# Prepare a single cloned repo: fetch every tag, materialise a local branch
# for every remote branch, pull in submodules.
#
# Runs in a subshell so `cd` stays scoped. Every critical step has an explicit
# `|| exit 1` because `set -e` is suppressed for a function invoked as an
# `if !` condition - a bare `git fetch` failure here would otherwise be lost.
# ---------------------------------------------------------------------------

prepare_repo() {
  (
    cd -- "$1" || exit 1

    echo "Fetching all tags..."
    git fetch origin --tags --force || exit 1

    # Best effort: a submodule that cannot be fetched (removed remote, no
    # access) must not fail the parent repo, which is still fully backed up.
    # A no-op (exit 0) when the repo has no .gitmodules.
    git submodule update --init --recursive || true

    echo "Creating local branches..."

    local -a remote_branches
    mapfile -t remote_branches < <(
      git for-each-ref --format='%(refname:short)' refs/remotes/origin
    )

    local remote_branch branch
    for remote_branch in "${remote_branches[@]}"; do
      [[ "$remote_branch" == "origin/HEAD" ]] && continue
      branch="${remote_branch#origin/}"
      git show-ref --verify --quiet "refs/heads/$branch" && continue
      # Best effort: an unusable ref name only costs that one local branch,
      # and the remote-tracking ref is still in the archive.
      git branch --track "$branch" "$remote_branch" >/dev/null 2>&1 || true
    done

    echo "Repository ready."
  )
}

# ---------------------------------------------------------------------------
# Clone repos
# ---------------------------------------------------------------------------

for repo in "${REPOS[@]}"; do
  name="${repo#*/}"
  dest="${WORKDIR}/${name}"

  echo
  echo "==== $repo ===="

  if ! gh repo clone "$repo" "$dest"; then
    echo "WARNING: failed to clone $repo" >&2
    FAILED+=("$repo")
    rm -rf -- "$dest"
    continue
  fi

  if ! prepare_repo "$dest"; then
    echo "WARNING: failed to prepare $repo" >&2
    FAILED+=("$repo")
  fi
done

# ---------------------------------------------------------------------------
# Failed repos summary
# ---------------------------------------------------------------------------

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo >&2
  echo "The following repos failed:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
fi

if [[ ${#FAILED[@]} -eq ${#REPOS[@]} ]]; then
  echo
  echo "Error: every repo failed; not creating an archive." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Create + verify archive
# ---------------------------------------------------------------------------

echo
echo "Creating archive: $ARCHIVE_PATH"

CREATE_ARGS=(a -t7z -mx=9)
VERIFY_ARGS=(t)

if [[ -n "$ARCHIVE_PASSWORD" ]]; then
  CREATE_ARGS+=("-p${ARCHIVE_PASSWORD}" -mhe=on)
  VERIFY_ARGS+=("-p${ARCHIVE_PASSWORD}")
fi

if ! (cd -- "$WORKDIR" && 7z "${CREATE_ARGS[@]}" "$ARCHIVE_PATH" .); then
  echo "Error: failed to create archive: $ARCHIVE_PATH" >&2
  exit 1
fi

echo "Verifying archive..."
if ! 7z "${VERIFY_ARGS[@]}" "$ARCHIVE_PATH" >/dev/null; then
  echo "Error: archive failed verification: $ARCHIVE_PATH" >&2
  exit 1
fi

# Backups of private repos should not be world-readable at rest.
chmod 600 -- "$ARCHIVE_PATH"

echo
echo "Done."
echo "Archive: $ARCHIVE_PATH"
echo "Backed up $(( ${#REPOS[@]} - ${#FAILED[@]} )) of ${#REPOS[@]} repo(s)"
echo "Failed: ${#FAILED[@]}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "WARNING: the archive is incomplete; see the failed repos above." >&2
  exit 1
fi
