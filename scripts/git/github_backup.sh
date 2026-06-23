#!/usr/bin/env bash
#
# gh-backup.sh
#
# Backs up all GitHub repos owned by evictedcucumber (public and private)
# into a single 7z archive. Creates normal, browsable repositories with
# working trees and full .git history. All branches are fetched and local
# branches are created for every remote branch so the backup is self-contained.
#
# Requirements: gh, git, 7z, jq
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Repos to skip, as "owner/name"
IGNORE_LIST=(
  # "evictedcucumber/some-repo"
)

OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="github-backup-${TIMESTAMP}.7z"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"

# Optional archive password
ARCHIVE_PASSWORD="${GH_BACKUP_PASSWORD:-}"

# GitHub user whose repos to back up
OWNER="evictedcucumber"

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

mapfile -t ALL_REPOS < <(gh "${LIST_ARGS[@]}")

if [[ ${#ALL_REPOS[@]} -eq 0 ]]; then
  echo "Error: no repos returned."
  exit 1
fi

REPOS=()

for repo in "${ALL_REPOS[@]}"; do
  skip=false

  for ignored in "${IGNORE_LIST[@]:-}"; do
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
  rm -rf "$WORKDIR"
}

trap cleanup EXIT

FAILED=()

# ---------------------------------------------------------------------------
# Clone repos
# ---------------------------------------------------------------------------

for repo in "${REPOS[@]}"; do
  name="${repo#*/}"
  dest="${WORKDIR}/${name}"

  echo
  echo "==== $repo ===="

  if gh repo clone "$repo" "$dest"; then
    (
      cd "$dest"

      echo "Fetching all refs..."
      git fetch origin '+refs/heads/*:refs/remotes/origin/*'
      git fetch origin --tags --force

      echo "Creating local branches..."

      while IFS= read -r remote_branch; do
        [[ "$remote_branch" == "origin/HEAD" ]] && continue

        branch="${remote_branch#origin/}"

        if ! git show-ref --verify --quiet "refs/heads/$branch"; then
          git branch --track "$branch" "$remote_branch" \
            >/dev/null 2>&1 || true
        fi
      done < <(
        git for-each-ref \
          --format='%(refname:short)' \
          refs/remotes/origin
      )

      echo "Repository ready."
    )
  else
    echo "WARNING: failed to clone $repo"
    FAILED+=("$repo")
    rm -rf "$dest"
  fi
done

# ---------------------------------------------------------------------------
# Failed repos summary
# ---------------------------------------------------------------------------

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  echo "The following repos failed:"
  printf '  %s\n' "${FAILED[@]}"
fi

# ---------------------------------------------------------------------------
# Create archive
# ---------------------------------------------------------------------------

mkdir -p "$OUTPUT_DIR"

echo
echo "Creating archive: $ARCHIVE_PATH"

SEVENZ_ARGS=(a -t7z -mx=9)

if [[ -n "$ARCHIVE_PASSWORD" ]]; then
  SEVENZ_ARGS+=(
    "-p${ARCHIVE_PASSWORD}"
    -mhe=on
  )
fi

(
  cd "$WORKDIR"
  7z "${SEVENZ_ARGS[@]}" "$ARCHIVE_PATH" .
)

echo
echo "Done."
echo "Archive: $ARCHIVE_PATH"
echo "Backed up ${#REPOS[@]} repo(s)"
echo "Failed: ${#FAILED[@]}"
