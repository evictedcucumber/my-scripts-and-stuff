#!/usr/bin/env bash
#
# sync_archive_forks.sh
#
# Reads a GitHub star list (default "Archive Forks") for the authenticated gh
# user. It first syncs every repo in it (steps 1-3), then builds every repo that
# synced cleanly (step 4):
#   1. if it is a fork, syncs the fork's copy of the upstream default branch
#      on GitHub from its parent (`gh repo sync`, fast-forward only unless
#      --force);
#   2. clones it into DEST_DIR/<name> if missing (gh adds an `upstream` remote
#      for forks), otherwise fetches all remotes;
#   3. fast-forwards the local copy of that branch to match GitHub;
#   4. release-builds the repo's main binary (package and bin named after the
#      repo) for Linux and Windows, and copies the results into
#      BUILD_DIR/<name>/:
#        <name>-linux-x86_64        cargo zigbuild, x86_64-unknown-linux-gnu,
#                                   glibc 2.35 (a plain NixOS build would point
#                                   its interpreter into /nix/store)
#        <name>-windows-x86_64.exe  cargo xwin, x86_64-pc-windows-msvc
#      macOS is skipped: it can't be cross-built from Linux without Apple's SDK.
#
# Non-fork repos in the list are just cloned/fetched and fast-forwarded on their
# default branch. Failures are collected per repo (and per build target) and
# summarised at the end; the script exits 1 if anything failed.
#
# Usage:
#   sync_archive_forks.sh [-f|--force] [--no-build] [-h|--help] [DEST_DIR]
#
# Arguments:
#   DEST_DIR      Where repos are cloned (default: ~/repos/archive-forks).
#                 Created if missing.
#
# Options:
#   -f, --force   Hard-reset instead of fast-forwarding, both on GitHub
#                 (`gh repo sync --force`) and locally (`git reset --hard`).
#                 Discards any commits on the fork's branch that upstream lacks.
#   --no-build    Only sync; skip step 4.
#
# Environment:
#   STAR_LIST     Name of the star list to read (default: "Archive Forks").
#   BUILD_DIR     Where binaries are copied (default: ~/builds/archive-forks).
#   CARGO_TARGET_DIR
#                 Cargo target dir shared by every repo, so dependencies built
#                 with matching versions, features and profile settings are
#                 compiled once (default: ~/.cache/archive-forks/target).
#
# Requirements: nix (flakes are enabled per-invocation) and an authenticated gh
# login. Everything else - gh, git, jq, cargo (with the x86_64-pc-windows-msvc
# std), cargo-zigbuild, zig, cargo-xwin, clang/lld/llvm - comes from the
# flake.nix next to this script: the script re-execs itself inside that flake's
# devShell (`nix develop`), so it runs from any directory without direnv.
#
set -euo pipefail

# Kept for the re-exec into the devShell below, before parsing consumes them.
ORIG_ARGS=("$@")

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: sync_archive_forks.sh [-f|--force] [--no-build] [-h|--help] [DEST_DIR]

Clone/sync every repo in a GitHub star list into DEST_DIR, syncing forks to
their upstream default branch on GitHub first, then release-build each repo's
main binary for Linux and Windows into BUILD_DIR/<name>/ (macOS is skipped).

Arguments:
  DEST_DIR      Where repos are cloned (default: ~/repos/archive-forks).

Options:
  -f, --force   Hard-reset (GitHub and local) instead of fast-forward only.
                Discards fork commits that upstream does not have.
      --no-build
                Only sync; don't build.
  -h, --help    Show this help.

Environment:
  STAR_LIST     Star list to read (default: "Archive Forks").
  BUILD_DIR     Where binaries go (default: ~/builds/archive-forks).
  CARGO_TARGET_DIR
                Shared cargo target dir (default: ~/.cache/archive-forks/target).

Exits 1 if any repo failed.
EOF
}

FORCE=false
BUILD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -f | --force)
      FORCE=true
      shift
      ;;
    --no-build)
      BUILD=false
      shift
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

if [[ $# -gt 1 ]]; then
  echo "Error: unexpected argument: $2 (only one DEST_DIR is accepted)." >&2
  usage >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Enter the devShell
#
# Re-exec this script inside the devShell of the flake.nix beside it (symlinks
# resolved, so a link in ~/bin works). `path:` copies only this directory into
# the store rather than the enclosing git repo, and doesn't need the flake files
# committed. SYNC_ARCHIVE_FORKS_IN_NIX stops the re-exec'd copy looping.
# ---------------------------------------------------------------------------

if [[ "${SYNC_ARCHIVE_FORKS_IN_NIX:-}" != 1 ]]; then
  if ! command -v nix >/dev/null 2>&1; then
    echo "Error: required command 'nix' not found in PATH." >&2
    exit 1
  fi

  SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
  SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
  if [[ ! -f "$SCRIPT_DIR/flake.nix" ]]; then
    echo "Error: no flake.nix next to the script in $SCRIPT_DIR." >&2
    exit 1
  fi

  export SYNC_ARCHIVE_FORKS_IN_NIX=1
  exec nix --extra-experimental-features 'nix-command flakes' \
    develop "path:$SCRIPT_DIR" --command "$SCRIPT_PATH" "${ORIG_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

STAR_LIST="${STAR_LIST:-Archive Forks}"
DEST_DIR="${1:-$HOME/repos/archive-forks}"
BUILD_DIR="${BUILD_DIR:-$HOME/builds/archive-forks}"
# One target dir for all repos: they share most of their dependency tree, and
# cargo reuses any artifact whose versions/features/profile match. Each repo
# keeps its own release profile; repos with different profiles just don't share.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/archive-forks/target}"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

REQUIRED_CMDS=(gh git jq)
if [[ "$BUILD" == true ]]; then
  REQUIRED_CMDS+=(cargo cargo-zigbuild zig cargo-xwin)
fi

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH (should come from the devShell of the flake.nix next to this script)." >&2
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

mkdir -p -- "$DEST_DIR"
DEST_DIR="$(cd -- "$DEST_DIR" && pwd)"
if [[ ! -w "$DEST_DIR" ]]; then
  echo "Error: destination directory is not writable: $DEST_DIR" >&2
  exit 1
fi

if [[ "$BUILD" == true ]]; then
  mkdir -p -- "$BUILD_DIR"
  BUILD_DIR="$(cd -- "$BUILD_DIR" && pwd)"
  if [[ ! -w "$BUILD_DIR" ]]; then
    echo "Error: build directory is not writable: $BUILD_DIR" >&2
    exit 1
  fi

  mkdir -p -- "$CARGO_TARGET_DIR"
  CARGO_TARGET_DIR="$(cd -- "$CARGO_TARGET_DIR" && pwd)"
  if [[ ! -w "$CARGO_TARGET_DIR" ]]; then
    echo "Error: cargo target directory is not writable: $CARGO_TARGET_DIR" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Read the star list
#
# Star lists are only exposed through GraphQL (viewer.lists). Find the list's
# node id by name, then page through its items.
# ---------------------------------------------------------------------------

echo "Looking up star list '$STAR_LIST'..."

LISTS_QUERY='
query {
  viewer {
    lists(first: 100) {
      nodes { id name }
    }
  }
}'

if ! list_id="$(
  gh api graphql -f query="$LISTS_QUERY" |
    jq -r --arg name "$STAR_LIST" \
      '[.data.viewer.lists.nodes[] | select(.name == $name)][0].id // empty'
)"; then
  echo "Error: failed to fetch star lists from GitHub." >&2
  exit 1
fi

if [[ -z "$list_id" ]]; then
  echo "Error: no star list named '$STAR_LIST' found." >&2
  exit 1
fi

# One TSV line per repo:
#   nameWithOwner  isFork  isArchived  branch  parentNameWithOwner
# where branch is the parent's default branch for forks (what gets synced),
# otherwise the repo's own default branch. Non-repo items are dropped.
# \$id/\$endCursor are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016
ITEMS_QUERY='
query($id: ID!, $endCursor: String) {
  node(id: $id) {
    ... on UserList {
      items(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on Repository {
            nameWithOwner
            isFork
            isArchived
            defaultBranchRef { name }
            parent { nameWithOwner defaultBranchRef { name } }
          }
        }
      }
    }
  }
}'

if ! items_tsv="$(
  gh api graphql --paginate -f id="$list_id" -f query="$ITEMS_QUERY" |
    jq -r '
      .data.node.items.nodes[]
      | select(.nameWithOwner != null)
      | [
          .nameWithOwner,
          (if .isFork and .parent != null then "true" else "false" end),
          (.isArchived | tostring),
          ((if .isFork and .parent != null
              then .parent.defaultBranchRef.name
              else .defaultBranchRef.name end) // ""),
          (.parent.nameWithOwner // "")
        ]
      | @tsv'
)"; then
  echo "Error: failed to read items of star list '$STAR_LIST'." >&2
  exit 1
fi

mapfile -t ITEMS <<< "$items_tsv"

# mapfile on an empty string yields a single empty element - normalise to [].
if [[ ${#ITEMS[@]} -eq 1 && -z "${ITEMS[0]}" ]]; then
  ITEMS=()
fi

echo "Found ${#ITEMS[@]} repo(s) in '$STAR_LIST'. Syncing into $DEST_DIR"

if [[ ${#ITEMS[@]} -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi

# ---------------------------------------------------------------------------
# Bring a local clone's BRANCH in line with origin/BRANCH.
#
# Runs in a subshell so `cd` stays scoped. Every step has an explicit
# `|| exit 1` because `set -e` is suppressed for a function invoked as an
# `if !` condition.
# ---------------------------------------------------------------------------

update_local() {
  local dir="$1" branch="$2"
  (
    cd -- "$dir" || exit 1

    git fetch --all --prune --tags || exit 1

    local current
    current="$(git symbolic-ref --quiet --short HEAD || true)"

    if [[ "$current" == "$branch" ]]; then
      if [[ "$FORCE" == true ]]; then
        git reset --hard "origin/$branch" || exit 1
      else
        git merge --ff-only "origin/$branch" || exit 1
      fi
    else
      # Updates (or creates) the branch without checking it out. A leading
      # `+` allows a non-fast-forward update, i.e. the --force behaviour.
      local refspec="refs/heads/$branch:refs/heads/$branch"
      [[ "$FORCE" == true ]] && refspec="+$refspec"
      git fetch origin "$refspec" || exit 1
    fi
  )
}

# ---------------------------------------------------------------------------
# Release-build one target of a repo's main binary and copy it to
# BUILD_DIR/<name>/<name>-<label><suffix>.
#
#   build_target DIR NAME LABEL TRIPLE SUFFIX CARGO_ARGS...
#
# TRIPLE is the target/ subdirectory cargo writes to; CARGO_ARGS is the cargo
# subcommand plus its --target. The binary is copied, not moved, so cargo's
# build cache stays fresh and an unchanged repo rebuilds as a no-op.
# ---------------------------------------------------------------------------

build_target() {
  local dir="$1" name="$2" label="$3" triple="$4" suffix="$5"
  shift 5

  echo "Building $name for $label..."
  (
    cd -- "$dir" || exit 1
    cargo "$@" --release --locked -p "$name" --bin "$name" || exit 1
  ) || return 1

  local out="$CARGO_TARGET_DIR/$triple/release/$name$suffix"
  if [[ ! -f "$out" ]]; then
    echo "Error: build succeeded but $out is missing." >&2
    return 1
  fi

  mkdir -p -- "$BUILD_DIR/$name" || return 1
  cp -f -- "$out" "$BUILD_DIR/$name/$name-$label$suffix" || return 1
  echo "Built: $BUILD_DIR/$name/$name-$label$suffix"
}

# ---------------------------------------------------------------------------
# Sync repos
# ---------------------------------------------------------------------------

SYNC_ARGS=()
[[ "$FORCE" == true ]] && SYNC_ARGS+=(--force)

FAILED=()

# "repo<TAB>name<TAB>dest<TAB>branch" for each repo that synced cleanly; the
# build phase only builds these.
SYNCED=()

# ---------------------------------------------------------------------------
# Phase 1: clone and sync every repo
# ---------------------------------------------------------------------------

for item in "${ITEMS[@]}"; do
  IFS=$'\t' read -r repo is_fork is_archived branch parent <<< "$item"
  name="${repo#*/}"
  dest="${DEST_DIR}/${name}"

  echo
  echo "==== $repo ===="

  if [[ -z "$branch" ]]; then
    echo "WARNING: $repo has no default branch (empty repo?); skipping." >&2
    FAILED+=("$repo (no default branch)")
    continue
  fi

  # 1. Sync the fork on GitHub from its parent.
  if [[ "$is_fork" == true ]]; then
    if [[ "$is_archived" == true ]]; then
      echo "WARNING: $repo is archived (read-only) on GitHub; cannot sync it from $parent." >&2
      FAILED+=("$repo (archived on GitHub)")
      continue
    fi

    echo "Syncing $repo:$branch from $parent:$branch on GitHub..."
    if ! gh repo sync "$repo" --branch "$branch" "${SYNC_ARGS[@]}"; then
      echo "WARNING: failed to sync $repo from $parent (diverged? retry with --force)." >&2
      FAILED+=("$repo (GitHub sync)")
      continue
    fi
  fi

  # 2. Clone if missing.
  if [[ ! -e "$dest" ]]; then
    echo "Cloning into $dest..."
    if ! gh repo clone "$repo" "$dest"; then
      echo "WARNING: failed to clone $repo" >&2
      FAILED+=("$repo (clone)")
      rm -rf -- "$dest"
      continue
    fi
  elif [[ ! -d "$dest/.git" ]]; then
    echo "WARNING: $dest exists but is not a git repository; skipping." >&2
    FAILED+=("$repo (not a git repo: $dest)")
    continue
  fi

  # 3. Bring the local branch up to date with GitHub.
  if ! update_local "$dest" "$branch"; then
    echo "WARNING: failed to update local $branch in $dest" >&2
    FAILED+=("$repo (local update)")
    continue
  fi

  echo "Up to date: $dest ($branch)"
  SYNCED+=("$repo"$'\t'"$name"$'\t'"$dest"$'\t'"$branch")
done

# ---------------------------------------------------------------------------
# Phase 2: build every synced repo and copy its binaries to BUILD_DIR
# ---------------------------------------------------------------------------

if [[ "$BUILD" == true && ${#SYNCED[@]} -gt 0 ]]; then
  echo
  echo "Synced ${#SYNCED[@]} of ${#ITEMS[@]} repo(s); building..."
fi

for entry in "${SYNCED[@]}"; do
  [[ "$BUILD" == true ]] || break

  IFS=$'\t' read -r repo name dest branch <<< "$entry"

  echo
  echo "==== build $repo ===="

  # The working tree is what gets built, so it must be on $branch.
  if [[ "$(git -C "$dest" symbolic-ref --quiet --short HEAD || true)" != "$branch" ]]; then
    echo "WARNING: $dest is not on $branch; not building it." >&2
    FAILED+=("$repo (build: working tree not on $branch)")
    continue
  fi

  # -fno-{function,data}-sections: the cc crate adds -ffunction-sections
  # -fdata-sections by default, and zig's clang then emits section symbols with
  # st_shndx=UND (e.g. aws-lc-sys's obj.o), which lld reports as "undefined
  # symbol:" with an empty name when linking. Appended after the defaults, so
  # it wins. Linux-only; the xwin (clang-cl) builds are unaffected.
  if ! CFLAGS_x86_64_unknown_linux_gnu="-fno-function-sections -fno-data-sections" \
    build_target "$dest" "$name" linux-x86_64 x86_64-unknown-linux-gnu "" \
    zigbuild --target x86_64-unknown-linux-gnu.2.35; then
    echo "WARNING: Linux build of $repo failed" >&2
    FAILED+=("$repo (build: linux-x86_64)")
  fi

  if ! build_target "$dest" "$name" windows-x86_64 x86_64-pc-windows-msvc .exe \
    xwin build --target x86_64-pc-windows-msvc; then
    echo "WARNING: Windows build of $repo failed" >&2
    FAILED+=("$repo (build: windows-x86_64)")
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "Processed ${#ITEMS[@]} repo(s): sources in $DEST_DIR"
if [[ "$BUILD" == true ]]; then
  echo "Binaries in $BUILD_DIR (macOS skipped: no cross toolchain from Linux)"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "The following steps failed:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
  exit 1
fi
