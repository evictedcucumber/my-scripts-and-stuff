#!/usr/bin/env bash
#
# sync_craft_forks.sh
#
# Reads a GitHub star list (default "zezura-archive-craft") for the authenticated gh
# user. It first syncs every repo in it (steps 1-3), then builds every repo that
# synced cleanly (step 4), then publishes those builds as releases (step 5):
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
#      If the repo's .github/workflows/release.yml pins a storytold/craft-fonts
#      commit (`craft-fonts-ref:`, or `ref:` on a craft-fonts checkout step),
#      that commit is checked out into CRAFT_FONTS_CACHE (a worktree of
#      DEST_DIR/craft-fonts when craft-fonts is itself in the star list, else
#      a clone of upstream) and the build gets
#      CRAFT_FONTS_DIR + CRAFT_FONTS_REQUIRED=1 like upstream's release builds,
#      so the fonts are embedded (and a missing font is an error, not a
#      silently font-less binary).
#      If storytold/craft-libs is in the star list too (your fork, synced to
#      DEST_DIR/craft-libs), cargo fetches the repos' craft-libs git
#      dependencies from that local clone instead of GitHub; any commit a
#      Cargo.lock pins that the clone lacks is fetched into it from the fork
#      first.
#      Windows icon/version resources are not embedded: the apps only pull in
#      `winresource` on Windows hosts, so their build.rs skips it (with a
#      warning) when cross-compiling.
#   5. if the repo is owned by FORK_OWNER (i.e. your fork in the Zezura-Archive
#      org, never the upstream parent) and both targets built, creates a GitHub release
#      on it with both binaries attached, tagged v<version>-forked from the
#      binary's version (`cargo metadata`), so it never clashes with
#      upstream's own v<version> tag. If that release already exists, it is
#      updated in place instead (tag moved to the built commit, assets and
#      notes replaced); skipped if it already points at the built commit.
#
# Repos without such a binary (e.g. craft-fonts or craft-libs, library/asset
# repos) are synced but not built or released. Non-fork repos in the list are just
# cloned/fetched and fast-forwarded on their default branch. Failures are collected per repo (and per build target) and
# summarised at the end; the script exits 1 if anything failed.
#
# Usage:
#   sync_craft_forks.sh [--sync|--build|--release] [-f|--force]
#                         [--only REPO[,REPO...]] [-j|--jobs N] [DEST_DIR]
#   sync_craft_forks.sh --clean
#   sync_craft_forks.sh -h|--help
#
# Arguments:
#   DEST_DIR      Where repos are cloned (default: ~/repos/craft-forks).
#                 Created if missing.
#
# Options:
#   -f, --force   Hard-reset instead of fast-forwarding, both on GitHub
#                 (`gh repo sync --force`) and locally (`git reset --hard`).
#                 Discards any commits on the fork's branch that upstream lacks.
#   --sync        Only sync (steps 1-3).
#   --build       Sync, then build (steps 1-4).
#   --release     Sync, build, then release (steps 1-5). The default.
#   --clean       Delete the build caches - CARGO_TARGET_DIR and sccache's
#                 SCCACHE_DIR (after stopping its server) - and nothing else:
#                 no sync, build or release, and DEST_DIR, BUILD_DIR and
#                 CRAFT_FONTS_CACHE are left alone. Needs no gh login.
#   Only one of --sync/--build/--release/--clean may be given.
#   --only REPO[,REPO...]
#                 Only process these repos of the star list (repeatable). Each
#                 REPO is matched, case-insensitively, against a repo's name,
#                 its owner/name, or a fork's upstream owner/name; one matching
#                 nothing is an error. Unselected repos are not synced, but
#                 their existing clones/forks still serve the selected repos'
#                 git dependencies (craft-libs, forked crates) and craft-fonts.
#   -j, --jobs N  Sync up to N repos at once (default 1). Only steps 1-3 run in
#                 parallel; builds and releases stay one at a time, as they
#                 share the cargo target dir. With N > 1 each repo's sync
#                 output is printed in one block when it finishes.
#
# Environment:
#   STAR_LIST     Name of the star list to read (default: "zezura-archive-craft").
#   FORK_OWNER    User/org that owns the forks; only its repos get releases
#                 (default: Zezura-Archive).
#   BUILD_DIR     Where binaries are copied (default: ~/builds/craft-forks).
#   CARGO_TARGET_DIR
#                 Cargo target dir shared by every repo, so dependencies built
#                 with matching versions, features and profile settings are
#                 compiled once (default: ~/.cache/craft-forks/target).
#   RUSTC_WRAPPER Compiler wrapper for the builds (default: sccache, which
#                 caches compiled crates in SCCACHE_DIR, default
#                 ~/.cache/sccache, so work the shared target dir can't reuse -
#                 a crate rebuilt after a flag/env change, a wiped target dir,
#                 the same crate in another repo's profile - is still a cache
#                 hit). Set it empty to build without a wrapper.
#   CRAFT_FONTS_CACHE
#                 craft-fonts checkout used for font-embedding builds: a
#                 worktree of DEST_DIR/craft-fonts if that exists, else a clone
#                 of storytold/craft-fonts
#                 (default: ~/.cache/craft-forks/craft-fonts).
#
# All git traffic to GitHub goes over HTTPS using gh's token (SSH remotes are
# rewritten for the run), so no SSH key or passphrase is needed. Cargo git
# dependencies on a repo with a fork in the list are fetched from that fork.
#
# Requirements: nix (flakes are enabled per-invocation) and an authenticated gh
# login. Everything else - gh, git, jq, cargo (with the x86_64-pc-windows-msvc
# std), cargo-zigbuild, zig, cargo-xwin, clang/lld/llvm, sccache - comes from the
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
Usage: sync_craft_forks.sh [--sync|--build|--release] [-f|--force]
                           [--only REPO[,REPO...]] [-j|--jobs N] [DEST_DIR]
       sync_craft_forks.sh --clean
       sync_craft_forks.sh -h|--help

Clone/sync every repo in a GitHub star list into DEST_DIR, syncing forks to
their upstream default branch on GitHub first, then release-build each repo's
main binary for Linux and Windows into BUILD_DIR/<name>/ (macOS is skipped),
then publish them as a GitHub release (v<version>-forked; an existing release
of that version is updated in place) on each repo you own.

Arguments:
  DEST_DIR      Where repos are cloned (default: ~/repos/craft-forks).

Modes (at most one; default --release):
      --sync    Only sync.
      --build   Sync, then build.
      --release Sync, build, then release.
      --clean   Delete CARGO_TARGET_DIR and SCCACHE_DIR (build caches) only.

Options:
  -f, --force   Hard-reset (GitHub and local) instead of fast-forward only.
                Discards fork commits that upstream does not have.
      --only REPO[,REPO...]
                Only process these repos (name, owner/name, or a fork's
                upstream owner/name; repeatable).
  -j, --jobs N  Sync up to N repos in parallel (default 1); builds stay serial.
  -h, --help    Show this help.

Environment:
  STAR_LIST     Star list to read (default: "zezura-archive-craft").
  FORK_OWNER    Owner of the forks; only its repos get releases
                (default: Zezura-Archive).
  BUILD_DIR     Where binaries go (default: ~/builds/craft-forks).
  CARGO_TARGET_DIR
                Shared cargo target dir (default: ~/.cache/craft-forks/target).
  RUSTC_WRAPPER Compiler wrapper (default: sccache; empty to disable).
  SCCACHE_DIR   sccache's cache, removed by --clean (default: ~/.cache/sccache).
  CRAFT_FONTS_CACHE
                craft-fonts clone for builds that embed it
                (default: ~/.cache/craft-forks/craft-fonts).

Exits 1 if any repo failed.
EOF
}

FORCE=false
MODE=""
ONLY=()
JOBS=1

set_mode() {
  if [[ -n "$MODE" && "$MODE" != "$1" ]]; then
    echo "Error: --$MODE and --$1 can't be combined." >&2
    usage >&2
    exit 1
  fi
  MODE="$1"
}

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
    --sync | --build | --release | --clean)
      set_mode "${1#--}"
      shift
      ;;
    --only | -j | --jobs)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 needs a value." >&2
        usage >&2
        exit 1
      fi
      if [[ "$1" == --only ]]; then
        ONLY+=("$2")
      else
        JOBS="$2"
      fi
      shift 2
      ;;
    --only=*)
      ONLY+=("${1#*=}")
      shift
      ;;
    --jobs=*)
      JOBS="${1#*=}"
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

# Each mode runs every phase before its own: releases publish the builds, and
# builds use the synced sources.
MODE="${MODE:-release}"
BUILD=false
RELEASE=false
case "$MODE" in
  build) BUILD=true ;;
  release) BUILD=true RELEASE=true ;;
esac

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --jobs needs a positive integer, got '$JOBS'." >&2
  exit 1
fi

# Split comma-separated --only values; drop whitespace and empty entries.
ONLY_NAMES=()
for value in "${ONLY[@]}"; do
  IFS=',' read -r -a names <<< "$value"
  for n in "${names[@]}"; do
    n="${n//[[:space:]]/}"
    [[ -n "$n" ]] && ONLY_NAMES+=("$n")
  done
done
if [[ ${#ONLY[@]} -gt 0 && ${#ONLY_NAMES[@]} -eq 0 ]]; then
  echo "Error: --only needs at least one repo name." >&2
  exit 1
fi

if [[ "$MODE" == clean &&
  ( "$FORCE" == true || ${#ONLY[@]} -gt 0 || "$JOBS" != 1 || $# -gt 0 ) ]]; then
  echo "Error: --clean takes no other options or arguments." >&2
  usage >&2
  exit 1
fi

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
# committed. SYNC_CRAFT_FORKS_IN_NIX stops the re-exec'd copy looping.
# ---------------------------------------------------------------------------

if [[ "${SYNC_CRAFT_FORKS_IN_NIX:-}" != 1 ]]; then
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

  export SYNC_CRAFT_FORKS_IN_NIX=1
  exec nix --extra-experimental-features 'nix-command flakes' \
    develop "path:$SCRIPT_DIR" --command "$SCRIPT_PATH" "${ORIG_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

STAR_LIST="${STAR_LIST:-zezura-archive-craft}"
# Releases are only created on repos owned by this account (the org holding
# the forks), never on the upstream parents or anyone else's repo in the list.
# The access checks below require you to be it or an active member of it.
FORK_OWNER="${FORK_OWNER:-Zezura-Archive}"
DEST_DIR="${1:-$HOME/repos/craft-forks}"
BUILD_DIR="${BUILD_DIR:-$HOME/builds/craft-forks}"
# One target dir for all repos: they share most of their dependency tree, and
# cargo reuses any artifact whose versions/features/profile match. Each repo
# keeps its own release profile; repos with different profiles just don't share.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/craft-forks/target}"
# sccache caches compiled crates (and, via cc-rs, C objects) beyond what the
# shared target dir reuses. An already-set RUSTC_WRAPPER - including an empty
# one, which disables wrapping - is left alone.
export RUSTC_WRAPPER="${RUSTC_WRAPPER-sccache}"

# The repos' release builds embed fonts from this repo at a pinned commit.
CRAFT_FONTS_REPO="storytold/craft-fonts"
CRAFT_FONTS_CACHE="${CRAFT_FONTS_CACHE:-$HOME/.cache/craft-forks/craft-fonts}"

# The repos' crates depend on this repo's crates as cargo git dependencies.
# When it is in the star list, its synced clone serves those (CRAFT_LIBS_LOCAL,
# set after phase 1).
CRAFT_LIBS_REPO="storytold/craft-libs"
CRAFT_LIBS_LOCAL=""

# ---------------------------------------------------------------------------
# --clean: delete the build caches and stop
# ---------------------------------------------------------------------------

# Refuses paths whose deletion would take more than a cache with it.
remove_cache_dir() {
  local label="$1" dir="$2" resolved
  if [[ ! -e "$dir" ]]; then
    echo "No $label at $dir; nothing to remove."
    return 0
  fi
  resolved="$(realpath -- "$dir")" || return 1
  if [[ "$resolved" == / || "$resolved" == "$(realpath -- "$HOME")" ]]; then
    echo "Error: refusing to remove $label at $resolved." >&2
    return 1
  fi
  echo "Removing $label: $resolved"
  rm -rf -- "$resolved"
}

if [[ "$MODE" == clean ]]; then
  # sccache's own default; the server holds the cache open, so stop it first
  # (it errors if it isn't running, which is fine).
  SCCACHE_DIR="${SCCACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/sccache}"
  if command -v sccache >/dev/null 2>&1; then
    sccache --stop-server >/dev/null 2>&1 || true
  fi

  CLEAN_FAILED=false
  remove_cache_dir "cargo target dir" "$CARGO_TARGET_DIR" || CLEAN_FAILED=true
  remove_cache_dir "sccache cache" "$SCCACHE_DIR" || CLEAN_FAILED=true
  [[ "$CLEAN_FAILED" == false ]] || exit 1
  echo "Build caches cleaned."
  exit 0
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

REQUIRED_CMDS=(gh git jq)
if [[ "$BUILD" == true ]]; then
  REQUIRED_CMDS+=(cargo cargo-zigbuild zig cargo-xwin)
  if [[ -n "$RUSTC_WRAPPER" ]]; then
    REQUIRED_CMDS+=("$RUSTC_WRAPPER")
  fi
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

# ---------------------------------------------------------------------------
# Access checks: fail up front, before anything is synced, if gh's token can't
# do what the run needs.
# ---------------------------------------------------------------------------

AUTH_FIX="gh auth refresh -h github.com -s repo,workflow,read:org"

if ! GH_USER="$(gh api user --jq .login)" || [[ -z "$GH_USER" ]]; then
  echo "Error: failed to look up the authenticated GitHub user." >&2
  exit 1
fi

# Classic OAuth tokens (what `gh auth login` creates) report their scopes in
# X-OAuth-Scopes. repo: clone/fetch, `gh repo sync`, releases. workflow: `gh
# repo sync` fails to fast-forward a fork past upstream commits that touch
# .github/workflows/ without it. read:org: the FORK_OWNER membership check
# below. Fine-grained/app tokens have no such header, so are not checked here.
if ! auth_headers="$(gh api -i user)"; then
  echo "Error: failed to query GitHub as $GH_USER." >&2
  exit 1
fi
scopes_line="$(grep -i '^x-oauth-scopes:' <<< "$auth_headers" | tr -d '\r' || true)"
if [[ -z "$scopes_line" ]]; then
  echo "WARNING: gh's token reports no OAuth scopes (fine-grained or app token?); skipping the scope check." >&2
else
  scopes_csv="${scopes_line#*:}"
  IFS=', ' read -r -a token_scopes <<< "$scopes_csv"
  missing_scopes=()
  for scope in repo workflow read:org; do
    have=false
    for s in "${token_scopes[@]}"; do
      # admin:org and write:org both include read:org.
      if [[ "$s" == "$scope" ]] ||
        [[ "$scope" == read:org && ( "$s" == admin:org || "$s" == write:org ) ]]; then
        have=true
        break
      fi
    done
    [[ "$have" == true ]] || missing_scopes+=("$scope")
  done
  if [[ ${#missing_scopes[@]} -gt 0 ]]; then
    echo "Error: gh's token is missing scope(s): ${missing_scopes[*]}. Fix with:" >&2
    echo "  $AUTH_FIX" >&2
    exit 1
  fi
fi

# FORK_OWNER must be you or an org you're an active member of. An org that
# restricts OAuth app access also rejects this call (with a message saying
# so), which would otherwise only surface as push/release 403s mid-run.
if [[ "${FORK_OWNER,,}" != "${GH_USER,,}" ]]; then
  if ! membership="$(gh api "user/memberships/orgs/$FORK_OWNER" --jq '.state + " " + .role' 2>&1)"; then
    echo "Error: can't access org '$FORK_OWNER' as $GH_USER:" >&2
    echo "  $membership" >&2
    if [[ "$membership" == *"OAuth App access restrictions"* ]]; then
      echo "Approve GitHub CLI for the org (Settings -> Third-party access -> OAuth app policy), or re-authorize gh and grant the org:" >&2
    else
      echo "Check you're a member of '$FORK_OWNER' (and FORK_OWNER is right), then re-authorize gh, granting the org:" >&2
    fi
    echo "  $AUTH_FIX" >&2
    exit 1
  fi
  if [[ "${membership%% *}" != active ]]; then
    echo "Error: your membership of '$FORK_OWNER' is '${membership%% *}', not active. Accept the invitation on GitHub first." >&2
    exit 1
  fi
fi

# Route every git operation on GitHub through HTTPS with gh's token, so no SSH
# key (passphrase, hardware-key PIN/touch) is needed even if gh's git_protocol
# is ssh or existing clones have SSH remotes. Set via GIT_CONFIG_* env vars, so
# it applies to this run only (including the git that `gh repo clone` runs) and
# neither global config nor the clones' saved remote URLs change. The empty
# helper clears any other credential helpers for github.com first.
GIT_ENV_CONFIG=(
  'url.https://github.com/.insteadOf=git@github.com:'
  'url.https://github.com/.insteadOf=ssh://git@github.com/'
  'credential.https://github.com.helper='
  'credential.https://github.com.helper=!gh auth git-credential'
)
git_config_idx="${GIT_CONFIG_COUNT:-0}"
for entry in "${GIT_ENV_CONFIG[@]}"; do
  export "GIT_CONFIG_KEY_$git_config_idx=${entry%%=*}"
  export "GIT_CONFIG_VALUE_$git_config_idx=${entry#*=}"
  git_config_idx=$((git_config_idx + 1))
done
export GIT_CONFIG_COUNT="$git_config_idx"

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
#   nameWithOwner  isFork  isArchived  viewerPermission  branch  parentNameWithOwner
# where branch is the parent's default branch for forks (what gets synced),
# otherwise the repo's own default branch. Non-repo items are dropped. Fields
# that can be empty come last: `read` with IFS=$'\t' merges adjacent tabs.
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
            viewerPermission
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
          (.viewerPermission // "NONE"),
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

echo "Found ${#ITEMS[@]} repo(s) in '$STAR_LIST'."

# --only: narrow ITEMS to the matching repos. ALL_ITEMS keeps the full list for
# the unselected repos' clones/forks, which the builds still fetch from.
ALL_ITEMS=("${ITEMS[@]}")
declare -A SELECTED=()
if [[ ${#ONLY_NAMES[@]} -gt 0 ]]; then
  declare -A matched=()
  ITEMS=()
  for item in "${ALL_ITEMS[@]}"; do
    IFS=$'\t' read -r repo _ _ _ _ parent <<< "$item"
    hit=false
    for want in "${ONLY_NAMES[@]}"; do
      want_lc="${want,,}"
      name_lc="${repo#*/}"
      name_lc="${name_lc,,}"
      if [[ "$want_lc" == "${repo,,}" || "$want_lc" == "$name_lc" ||
        ( -n "$parent" && "$want_lc" == "${parent,,}" ) ]]; then
        matched[$want]=1
        hit=true
      fi
    done
    if [[ "$hit" == true ]]; then
      ITEMS+=("$item")
      SELECTED[$repo]=1
    fi
  done

  unmatched=()
  for want in "${ONLY_NAMES[@]}"; do
    [[ -n "${matched[$want]:-}" ]] || unmatched+=("$want")
  done
  if [[ ${#unmatched[@]} -gt 0 ]]; then
    echo "Error: --only matched nothing in '$STAR_LIST' for: ${unmatched[*]}" >&2
    echo "Repos in the list:" >&2
    for item in "${ALL_ITEMS[@]}"; do
      printf '  %s\n' "${item%%$'\t'*}" >&2
    done
    exit 1
  fi
  echo "Selected ${#ITEMS[@]} of them with --only."
fi

echo "Syncing ${#ITEMS[@]} repo(s) into $DEST_DIR"

if [[ ${#ITEMS[@]} -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi

# Every fork gets pushed to (`gh repo sync`, and releases on FORK_OWNER's), so
# needs write access. Checked for all of them before anything runs. Forks
# outside FORK_OWNER are still synced but never released - flagged so a
# mistyped FORK_OWNER or a fork left behind in the move doesn't go unnoticed.
NO_WRITE=()
for item in "${ITEMS[@]}"; do
  IFS=$'\t' read -r repo is_fork _ permission _ <<< "$item"
  [[ "$is_fork" == true ]] || continue
  owner="${repo%%/*}"
  if [[ "$RELEASE" == true && "${owner,,}" != "${FORK_OWNER,,}" ]]; then
    echo "WARNING: fork $repo is not owned by $FORK_OWNER; it will be synced but not released." >&2
  fi
  case "$permission" in
    ADMIN | MAINTAIN | WRITE) ;;
    *) NO_WRITE+=("$repo ($permission)") ;;
  esac
done
if [[ ${#NO_WRITE[@]} -gt 0 ]]; then
  echo "Error: $GH_USER lacks write access to these forks (permission in brackets):" >&2
  printf '  - %s\n' "${NO_WRITE[@]}" >&2
  echo "Grant $GH_USER write access to them (or move them into $FORK_OWNER), or drop them from '$STAR_LIST'." >&2
  exit 1
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

    # Branches from every remote, then tags from origin only. Fork tags (e.g.
    # releases from older versions of this script, before the -forked suffix)
    # can reuse a tag name upstream already has at another commit, and both
    # land in the one refs/tags namespace, so a plain `--all --tags` fetch
    # rejects the clash ("would clobber existing tag"). --force makes the
    # fork's tag win locally; tags are not pruned, so upstream-only ones stay.
    git fetch --all --prune || exit 1
    git fetch --tags --force origin || exit 1

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
# Print the craft-fonts commit a repo's release workflow builds with, if any.
#
#   craft_fonts_ref DIR
#
# Recognises the forms used in .github/workflows/release.yml: a
# `craft-fonts-ref: <sha>` input to the shared release workflow, and a
# `ref: <sha>` in the same step as `repository: storytold/craft-fonts`. Either
# value may also be `${{ env.NAME }}`, resolved from the workflow's own
# `NAME: <sha>` entry. Prints nothing if the repo doesn't use craft-fonts;
# returns 1 (with an error) if it does but the ref can't be resolved.
# ---------------------------------------------------------------------------

craft_fonts_ref() {
  local workflow="$1/.github/workflows/release.yml"
  [[ -f "$workflow" ]] || return 0

  local value_re='[[:space:]]*(.*[^[:space:]])'
  local input_re="^[[:space:]]*craft-fonts-ref:$value_re"
  local repo_re="repository:[[:space:]]*$CRAFT_FONTS_REPO([[:space:]#]|\$)"
  local ref_re="^[[:space:]]*ref:$value_re"
  local step_re='^[[:space:]]*-[[:space:]]'
  local line ref="" in_fonts_step=false
  local lines=()
  mapfile -t lines < "$workflow"

  for line in "${lines[@]}"; do
    if [[ "$line" =~ $input_re ]]; then
      ref="${BASH_REMATCH[1]}"
      break
    fi
    # A new step (`- uses:`/`- name:`) ends the craft-fonts checkout step.
    if [[ "$line" =~ $step_re ]]; then
      in_fonts_step=false
    fi
    if [[ "$line" =~ $repo_re ]]; then
      in_fonts_step=true
    elif [[ "$in_fonts_step" == true && "$line" =~ $ref_re ]]; then
      ref="${BASH_REMATCH[1]}"
      break
    fi
  done
  [[ -n "$ref" ]] || return 0

  # Drop a trailing comment and optional quotes.
  ref="${ref%%[[:space:]]#*}"
  ref="${ref#\"}"
  ref="${ref%\"}"
  ref="${ref#\'}"
  ref="${ref%\'}"

  # ${{ env.NAME }}: the workflow-level (or job/step) `NAME: value` entry.
  local env_re='^\$\{\{[[:space:]]*env\.([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}\}$'
  if [[ "$ref" =~ $env_re ]]; then
    local var="${BASH_REMATCH[1]}" var_re resolved=""
    var_re='^[[:space:]]*'"$var"$':[[:space:]]*["\']?([^[:space:]"\'#]+)'
    for line in "${lines[@]}"; do
      if [[ "$line" =~ $var_re ]]; then
        resolved="${BASH_REMATCH[1]}"
        break
      fi
    done
    if [[ -z "$resolved" ]]; then
      echo "Error: $workflow uses craft-fonts ref $ref, but defines no $var." >&2
      return 1
    fi
    ref="$resolved"
  fi

  if [[ "$ref" == *"\${{"* || "$ref" =~ [[:space:]] ]]; then
    echo "Error: can't resolve craft-fonts ref '$ref' in $workflow." >&2
    return 1
  fi
  echo "$ref"
}

# ---------------------------------------------------------------------------
# Check out craft-fonts at REF in CRAFT_FONTS_CACHE.
#
#   prepare_craft_fonts REF
#
# If craft-fonts is in the star list (synced to DEST_DIR/craft-fonts in phase
# 1), CRAFT_FONTS_CACHE is a detached worktree of that clone, so no second copy
# is downloaded and the synced clone's own branch is never touched. Otherwise
# it is a standalone clone of upstream. A checkout that doesn't match (or no
# longer works, e.g. a worktree whose clone was deleted) is recreated.
# Builds run one at a time, so a single checkout is switched between the refs
# the repos pin. A ref that is already present locally as a commit is not
# fetched again.
# ---------------------------------------------------------------------------

prepare_craft_fonts() {
  local ref="$1" dir="$CRAFT_FONTS_CACHE"
  local synced="$DEST_DIR/${CRAFT_FONTS_REPO#*/}" want_git="" have_git=""

  if [[ -d "$synced/.git" ]]; then
    want_git="$(git -C "$synced" rev-parse --path-format=absolute --git-common-dir)" || return 1
  fi
  if [[ -e "$dir/.git" ]]; then
    have_git="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  fi

  if [[ -z "$have_git" || (-n "$want_git" && "$have_git" != "$want_git") ]]; then
    rm -rf -- "$dir"
    mkdir -p -- "$(dirname -- "$dir")" || return 1
    if [[ -n "$want_git" ]]; then
      echo "Adding a worktree of $synced at $dir..."
      git -C "$synced" worktree prune || return 1
      git -C "$synced" worktree add --quiet --detach "$dir" || return 1
    else
      echo "Cloning $CRAFT_FONTS_REPO into $dir..."
      git clone --quiet "https://github.com/$CRAFT_FONTS_REPO.git" "$dir" || return 1
    fi
  fi

  # Only a full SHA is immutable; anything else (a branch or tag) is re-fetched.
  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]] ||
    ! git -C "$dir" cat-file -e "$ref^{commit}" 2>/dev/null; then
    git -C "$dir" fetch --quiet origin "$ref" || return 1
    ref="$(git -C "$dir" rev-parse FETCH_HEAD)" || return 1
  fi

  git -C "$dir" -c advice.detachedHead=false \
    checkout --quiet --force --detach "$ref" || return 1
  echo "Using $CRAFT_FONTS_REPO@$ref"
}

# ---------------------------------------------------------------------------
# Make sure the local craft-libs clone has every craft-libs commit a repo's
# Cargo.lock pins, so cargo can fetch them from it.
#
#   prepare_craft_libs DIR
#
# Only used when CRAFT_LIBS_LOCAL is set. A pinned commit can be missing
# locally if it was never on a branch the clone fetched (e.g. a deleted PR
# branch); it is fetched from the fork, which GitHub serves every commit of the
# fork network from. Such a commit has no ref, so a later `git gc` may prune it
# and it is simply fetched again.
# ---------------------------------------------------------------------------

prepare_craft_libs() {
  local lock="$1/Cargo.lock" line sha
  [[ -f "$lock" ]] || return 0

  local source_re='^source = "git\+https://github\.com/'"$CRAFT_LIBS_REPO"'(\.git)?[?#].*#([0-9a-f]{40})"$'
  local shas=()
  while IFS= read -r line; do
    if [[ "$line" =~ $source_re ]]; then
      shas+=("${BASH_REMATCH[2]}")
    fi
  done < "$lock"

  local missing=()
  for sha in "${shas[@]}"; do
    git -C "$CRAFT_LIBS_LOCAL" cat-file -e "$sha^{commit}" 2>/dev/null || missing+=("$sha")
  done
  [[ ${#missing[@]} -gt 0 ]] || return 0

  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  echo "Fetching ${#missing[@]} pinned $CRAFT_LIBS_REPO commit(s) into $CRAFT_LIBS_LOCAL..."
  git -C "$CRAFT_LIBS_LOCAL" fetch --quiet origin "${missing[@]}" || return 1
}

# ---------------------------------------------------------------------------
# Whether a repo has a main binary to build: package NAME with a bin target
# NAME.
#
#   has_main_bin DIR NAME
#
# Returns 0 if it does, 1 if not (no Cargo.toml, or e.g. a library-only crate
# like craft-fonts/craft-libs), 2 if cargo can't read the manifest.
# ---------------------------------------------------------------------------

has_main_bin() {
  local dir="$1" name="$2" metadata
  [[ -f "$dir/Cargo.toml" ]] || return 1
  metadata="$(cd -- "$dir" && cargo metadata --no-deps --format-version 1 --locked)" || return 2
  jq -e --arg name "$name" '
    any(.packages[] | select(.name == $name) | .targets[];
        .name == $name and (.kind | index("bin")))' <<< "$metadata" >/dev/null || return 1
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
# Publish a repo's built binaries as a GitHub release on REPO.
#
#   release_repo REPO NAME DIR BRANCH
#
# The tag is always v<version>-forked, <version> being package NAME's version
# from `cargo metadata`. The suffix keeps fork releases from ever clashing with
# upstream's own v<version> tags, and gives each version exactly one release
# that later runs can update. If REPO already has that release, it is updated
# in place: its tag is moved to the built commit and its assets and notes
# replaced (nothing is done if it already points there). Otherwise it is
# created at the built commit.
# Returns 1 on failure, with an explanation on stderr.
# ---------------------------------------------------------------------------

release_repo() {
  local repo="$1" name="$2" dir="$3" branch="$4"

  local version
  version="$(
    cd -- "$dir" &&
      cargo metadata --no-deps --format-version 1 --locked |
      jq -r --arg name "$name" \
        '[.packages[] | select(.name == $name)][0].version // empty'
  )" || return 1
  if [[ -z "$version" ]]; then
    echo "Error: no package '$name' in the cargo metadata of $dir." >&2
    return 1
  fi

  # The release targets a commit on GitHub, so what was built must be exactly
  # origin/$branch (not local commits ahead of it).
  local sha
  sha="$(git -C "$dir" rev-parse HEAD)" || return 1
  if [[ "$sha" != "$(git -C "$dir" rev-parse "origin/$branch")" ]]; then
    echo "Error: $dir HEAD differs from origin/$branch; not releasing an unpushed build." >&2
    return 1
  fi

  local tag="v$version-forked"

  # Whether the release exists, and the commit its tag points at on GitHub (the
  # peeled ^{} line of an annotated tag comes last and wins).
  local releases_txt tag_txt released=false tag_sha="" line t
  releases_txt="$(gh release list -R "$repo" --limit 1000 --json tagName --jq '.[].tagName')" || return 1
  tag_txt="$(git -C "$dir" ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")" || return 1
  while IFS= read -r t; do
    if [[ "$t" == "$tag" ]]; then
      released=true
    fi
  done <<< "$releases_txt"
  while IFS=$'\t' read -r t line; do
    [[ -n "$line" ]] || continue
    tag_sha="$t"
  done <<< "$tag_txt"

  local assets=(
    "$BUILD_DIR/$name/$name-linux-x86_64"
    "$BUILD_DIR/$name/$name-windows-x86_64.exe"
  )
  local notes="Automated build of \`$name\` $version from $branch@$sha.

- \`$name-linux-x86_64\`: x86_64-unknown-linux-gnu, glibc 2.35
- \`$name-windows-x86_64.exe\`: x86_64-pc-windows-msvc"

  if [[ "$released" == true && "$tag_sha" == "$sha" ]]; then
    echo "Already released: $repo $tag ($sha)"
    return 0
  fi

  # Neither `gh release create --target` nor `gh release edit --target` moves a
  # tag that already exists, so point the tag at the built commit first
  # (creating it if missing).
  if [[ -z "$tag_sha" ]]; then
    gh api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$sha" >/dev/null || return 1
  elif [[ "$tag_sha" != "$sha" ]]; then
    gh api -X PATCH "repos/$repo/git/refs/tags/$tag" \
      -f sha="$sha" -F force=true >/dev/null || return 1
  fi

  if [[ "$released" == true ]]; then
    echo "Updating release $tag on $repo to $sha..."
    gh release upload "$tag" "${assets[@]}" -R "$repo" --clobber || return 1
    gh release edit "$tag" -R "$repo" \
      --title "$name $tag" \
      --notes "$notes" >/dev/null || return 1
    echo "Updated: https://github.com/$repo/releases/tag/$tag"
    return 0
  fi

  echo "Creating release $tag on $repo at $sha..."
  gh release create "$tag" "${assets[@]}" \
    -R "$repo" \
    --verify-tag \
    --title "$name $tag" \
    --notes "$notes" || return 1

  echo "Released: https://github.com/$repo/releases/tag/$tag"
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

# The SYNCED entries whose Linux and Windows builds both succeeded; only these
# are released.
BUILT=()

# "parent<TAB>fork" for each fork that synced cleanly; the build phase fetches
# git dependencies on a parent from the fork instead.
FORK_SOURCES=()

# ---------------------------------------------------------------------------
# Phase 1: clone and sync every repo
#
#   sync_repo ITEM RESULT
#
# Syncs one ITEMS entry (steps 1-3), then writes "ok" to the file RESULT, or
# the FAILED entry describing what went wrong. Runs either in the foreground
# (-j 1) or as a background job, so it reports through RESULT rather than the
# script's arrays; a missing RESULT means the job died before finishing.
# ---------------------------------------------------------------------------

sync_repo() {
  local item="$1" result="$2" repo is_fork is_archived branch parent name dest
  IFS=$'\t' read -r repo is_fork is_archived _ branch parent <<< "$item"
  name="${repo#*/}"
  dest="${DEST_DIR}/${name}"

  echo
  echo "==== $repo ===="

  if [[ -z "$branch" ]]; then
    echo "WARNING: $repo has no default branch (empty repo?); skipping." >&2
    echo "$repo (no default branch)" > "$result"
    return 1
  fi

  # 1. Sync the fork on GitHub from its parent.
  if [[ "$is_fork" == true ]]; then
    if [[ "$is_archived" == true ]]; then
      echo "WARNING: $repo is archived (read-only) on GitHub; cannot sync it from $parent." >&2
      echo "$repo (archived on GitHub)" > "$result"
      return 1
    fi

    echo "Syncing $repo:$branch from $parent:$branch on GitHub..."
    if ! gh repo sync "$repo" --branch "$branch" "${SYNC_ARGS[@]}"; then
      echo "WARNING: failed to sync $repo from $parent (diverged? retry with --force)." >&2
      echo "$repo (GitHub sync)" > "$result"
      return 1
    fi
  fi

  # 2. Clone if missing.
  if [[ ! -e "$dest" ]]; then
    echo "Cloning into $dest..."
    if ! gh repo clone "$repo" "$dest"; then
      echo "WARNING: failed to clone $repo" >&2
      echo "$repo (clone)" > "$result"
      rm -rf -- "$dest"
      return 1
    fi
  elif [[ ! -d "$dest/.git" ]]; then
    echo "WARNING: $dest exists but is not a git repository; skipping." >&2
    echo "$repo (not a git repo: $dest)" > "$result"
    return 1
  fi

  # 3. Bring the local branch up to date with GitHub.
  if ! update_local "$dest" "$branch"; then
    echo "WARNING: failed to update local $branch in $dest" >&2
    echo "$repo (local update)" > "$result"
    return 1
  fi

  echo "Up to date: $dest ($branch)"
  echo ok > "$result"
}

# Per-repo results (and, with -j > 1, buffered output), named by ITEMS index.
WORK_DIR="$(mktemp -d)"
cleanup() {
  local pids=()
  mapfile -t pids < <(jobs -pr)
  if [[ ${#pids[@]} -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

# Background job pid -> ITEMS index, for printing its output once it's done.
declare -A SYNC_JOBS=()
running=0

# Wait for any one sync job, then print its buffered output.
finish_sync_job() {
  local pid=""
  wait -n -p pid || true
  if [[ -z "$pid" ]]; then
    running=0
    return
  fi
  cat -- "$WORK_DIR/${SYNC_JOBS[$pid]}.log"
  unset "SYNC_JOBS[$pid]"
  running=$((running - 1))
}

if [[ "$JOBS" -eq 1 ]]; then
  for i in "${!ITEMS[@]}"; do
    sync_repo "${ITEMS[$i]}" "$WORK_DIR/$i" || true
  done
else
  echo "Syncing up to $JOBS repos at a time; each repo's output appears when it finishes."
  for i in "${!ITEMS[@]}"; do
    while [[ "$running" -ge "$JOBS" ]]; do
      finish_sync_job
    done
    sync_repo "${ITEMS[$i]}" "$WORK_DIR/$i" > "$WORK_DIR/$i.log" 2>&1 &
    SYNC_JOBS[$!]="$i"
    running=$((running + 1))
  done
  while [[ "$running" -gt 0 ]]; do
    finish_sync_job
  done
fi

# Collect the results in star-list order.
for i in "${!ITEMS[@]}"; do
  IFS=$'\t' read -r repo is_fork _ _ branch parent <<< "${ITEMS[$i]}"
  name="${repo#*/}"
  result=""
  if [[ -f "$WORK_DIR/$i" ]]; then
    result="$(< "$WORK_DIR/$i")"
  fi

  if [[ "$result" != ok ]]; then
    FAILED+=("${result:-$repo (sync: aborted)}")
    continue
  fi

  SYNCED+=("$repo"$'\t'"$name"$'\t'"$DEST_DIR/$name"$'\t'"$branch")
  # craft-libs is served from this clone instead of its fork on GitHub.
  if [[ "${parent:-$repo}" == "$CRAFT_LIBS_REPO" ]]; then
    CRAFT_LIBS_LOCAL="$DEST_DIR/$name"
  elif [[ "$is_fork" == true ]]; then
    FORK_SOURCES+=("$parent"$'\t'"$repo")
  fi
done

# Repos left out by --only weren't synced this run, but their existing
# craft-libs clone and forks still serve the selected repos' git dependencies
# (prepare_craft_libs fetches any pinned commit the clone lacks).
for item in "${ALL_ITEMS[@]}"; do
  IFS=$'\t' read -r repo is_fork _ _ _ parent <<< "$item"
  [[ ${#ONLY_NAMES[@]} -gt 0 && -z "${SELECTED[$repo]:-}" ]] || continue
  name="${repo#*/}"
  if [[ "${parent:-$repo}" == "$CRAFT_LIBS_REPO" ]]; then
    if [[ -z "$CRAFT_LIBS_LOCAL" && -d "$DEST_DIR/$name/.git" ]]; then
      CRAFT_LIBS_LOCAL="$DEST_DIR/$name"
    fi
  elif [[ "$is_fork" == true ]]; then
    FORK_SOURCES+=("$parent"$'\t'"$repo")
  fi
done

# ---------------------------------------------------------------------------
# Phase 2: build every synced repo and copy its binaries to BUILD_DIR
# ---------------------------------------------------------------------------

if [[ "$BUILD" == true && ${#SYNCED[@]} -gt 0 ]]; then
  echo
  echo "Synced ${#SYNCED[@]} of ${#ITEMS[@]} repo(s); building..."
fi

# Git dependencies on a repo we hold a fork of (e.g. effectcraft's filmcraft-*
# crates) are fetched from the fork, not upstream. A git URL rewrite (for this
# run only, like the SSH one above) leaves every Cargo.toml/Cargo.lock as is,
# so --locked still holds: the lockfile keeps the upstream URL and pinned rev,
# and the fork, just synced from upstream, has that commit. cargo's built-in
# libgit2 ignores GIT_CONFIG_* env vars, hence fetching with the git CLI.
# insteadOf is a prefix match: it covers .../filmcraft.git, but would also
# catch an unrelated upstream repo whose name starts with a fork's (.../filmcraft-x).
if [[ "$BUILD" == true && ${#FORK_SOURCES[@]} -gt 0 ]]; then
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
  for entry in "${FORK_SOURCES[@]}"; do
    IFS=$'\t' read -r parent repo <<< "$entry"
    echo "Fetching git dependencies on $parent from $repo."
    export "GIT_CONFIG_KEY_$git_config_idx=url.https://github.com/$repo.insteadOf"
    export "GIT_CONFIG_VALUE_$git_config_idx=https://github.com/$parent"
    git_config_idx=$((git_config_idx + 1))
  done
  export GIT_CONFIG_COUNT="$git_config_idx"
fi

# Likewise craft-libs, but from its synced clone in DEST_DIR (like craft-fonts),
# so cargo doesn't download a second copy. The .git form is listed too: git
# applies the longest matching insteadOf, which would otherwise turn
# .../craft-libs.git into a nonexistent .../craft-libs.git directory.
if [[ "$BUILD" == true && -n "$CRAFT_LIBS_LOCAL" ]]; then
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
  echo "Fetching git dependencies on $CRAFT_LIBS_REPO from $CRAFT_LIBS_LOCAL."
  for suffix in .git ""; do
    export "GIT_CONFIG_KEY_$git_config_idx=url.file://$CRAFT_LIBS_LOCAL.insteadOf"
    export "GIT_CONFIG_VALUE_$git_config_idx=https://github.com/$CRAFT_LIBS_REPO$suffix"
    git_config_idx=$((git_config_idx + 1))
  done
  export GIT_CONFIG_COUNT="$git_config_idx"
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

  # Repos with no binary of their own (e.g. craft-fonts or craft-libs, font and
  # library repos the others build against) are only synced: nothing to build
  # or release.
  bin_status=0
  has_main_bin "$dest" "$name" || bin_status=$?
  if [[ "$bin_status" -eq 1 ]]; then
    echo "Not building $repo: no '$name' binary (sync only)."
    continue
  elif [[ "$bin_status" -ne 0 ]]; then
    echo "WARNING: failed to read the cargo metadata of $dest; not building it." >&2
    FAILED+=("$repo (build: cargo metadata)")
    continue
  fi

  # Embed craft-fonts at the commit upstream releases with, or build without it
  # (unset, so nothing leaks over from the previous repo).
  unset CRAFT_FONTS_DIR CRAFT_FONTS_REQUIRED
  if ! fonts_ref="$(craft_fonts_ref "$dest")"; then
    echo "WARNING: can't tell which $CRAFT_FONTS_REPO commit $repo releases with; not building it." >&2
    FAILED+=("$repo (build: craft-fonts ref)")
    continue
  fi
  if [[ -n "$fonts_ref" ]]; then
    if ! prepare_craft_fonts "$fonts_ref"; then
      echo "WARNING: failed to check out $CRAFT_FONTS_REPO@$fonts_ref; not building $repo." >&2
      FAILED+=("$repo (build: craft-fonts $fonts_ref)")
      continue
    fi
    export CRAFT_FONTS_DIR="$CRAFT_FONTS_CACHE" CRAFT_FONTS_REQUIRED=1
  fi

  if [[ -n "$CRAFT_LIBS_LOCAL" ]] && ! prepare_craft_libs "$dest"; then
    echo "WARNING: failed to fetch the $CRAFT_LIBS_REPO commits $repo pins; not building it." >&2
    FAILED+=("$repo (build: craft-libs)")
    continue
  fi

  # -fno-{function,data}-sections: the cc crate adds -ffunction-sections
  # -fdata-sections by default, and zig's clang then emits section symbols with
  # st_shndx=UND (e.g. aws-lc-sys's obj.o), which lld reports as "undefined
  # symbol:" with an empty name when linking. Appended after the defaults, so
  # it wins. Linux-only; the xwin (clang-cl) builds are unaffected.
  built=true

  if ! CFLAGS_x86_64_unknown_linux_gnu="-fno-function-sections -fno-data-sections" \
    build_target "$dest" "$name" linux-x86_64 x86_64-unknown-linux-gnu "" \
    zigbuild --target x86_64-unknown-linux-gnu.2.35; then
    echo "WARNING: Linux build of $repo failed" >&2
    FAILED+=("$repo (build: linux-x86_64)")
    built=false
  fi

  if ! build_target "$dest" "$name" windows-x86_64 x86_64-pc-windows-msvc .exe \
    xwin build --target x86_64-pc-windows-msvc; then
    echo "WARNING: Windows build of $repo failed" >&2
    FAILED+=("$repo (build: windows-x86_64)")
    built=false
  fi

  if [[ "$built" == true ]]; then
    BUILT+=("$entry")
  fi
done

# ---------------------------------------------------------------------------
# Phase 3: release every fully built repo FORK_OWNER owns
# ---------------------------------------------------------------------------

for entry in "${BUILT[@]}"; do
  [[ "$RELEASE" == true ]] || break

  IFS=$'\t' read -r repo name dest branch <<< "$entry"

  # GitHub owner names are case-insensitive.
  owner="${repo%%/*}"
  if [[ "${owner,,}" != "${FORK_OWNER,,}" ]]; then
    echo
    echo "Not releasing $repo: owned by $owner, not $FORK_OWNER."
    continue
  fi

  echo
  echo "==== release $repo ===="

  if ! release_repo "$repo" "$name" "$dest" "$branch"; then
    echo "WARNING: failed to release $repo" >&2
    FAILED+=("$repo (release)")
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "Processed ${#ITEMS[@]} repo(s): sources in $DEST_DIR"
if [[ "$BUILD" == true ]]; then
  echo "Binaries in $BUILD_DIR (macOS skipped: no cross toolchain from Linux)"
  if [[ "$(basename -- "$RUSTC_WRAPPER")" == sccache ]]; then
    echo
    "$RUSTC_WRAPPER" --show-stats || true
  fi
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "The following steps failed:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
  exit 1
fi
