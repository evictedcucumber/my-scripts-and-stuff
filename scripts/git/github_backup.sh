#!/usr/bin/env bash
#
# github_backup.sh
#
# Backs up all GitHub repos owned by one or more users/orgs (public and
# private, see OWNERS below) into a single 7z archive, with each owner's repos
# in their own top-level <owner>/ folder. Creates normal, browsable
# repositories with working trees and full .git history. All branches are
# fetched and local branches are created for every remote branch so the backup
# is self-contained.
#
# Before cloning, validates that gh can see everything it should (token scopes,
# org membership/OAuth/SSO access, listed vs reported repo counts) and aborts
# with every problem listed if not.
#
# Exits 1 if any repo failed to clone or prepare. The archive is still created
# from the repos that succeeded, so a partial backup is kept but flagged.
#
# Usage:
#   github_backup.sh [-h|--help]
#
# Environment:
#   OWNERS              GitHub users/orgs to back up, space- or newline-
#                       separated (default: evictedcucumber Zezura-Archive).
#   OWNER               Single owner; used only when OWNERS is unset, for
#                       backwards compatibility.
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

Back up every GitHub repo owned by each of OWNERS into a single 7z archive,
one <owner>/ folder per owner. Configured through environment variables, not
arguments.

Environment:
  OWNERS              GitHub users/orgs to back up, space/newline separated
                      (default: evictedcucumber Zezura-Archive).
  OWNER               Single owner; used only when OWNERS is unset.
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

# GitHub users/orgs whose repos to back up. Override with OWNERS="a b" in the
# env; a lone OWNER=... is still honoured when OWNERS is unset.
DEFAULT_OWNERS=(evictedcucumber Zezura-Archive)

if [[ -n "${OWNERS:-}" ]]; then
  # -d '' so the read spans newlines too; it returns non-zero at EOF (no NUL).
  read -r -d '' -a OWNER_LIST <<< "$OWNERS" || true
elif [[ -n "${OWNER:-}" ]]; then
  OWNER_LIST=("$OWNER")
else
  OWNER_LIST=("${DEFAULT_OWNERS[@]}")
fi

if [[ ${#OWNER_LIST[@]} -eq 0 ]]; then
  echo "Error: OWNERS is set but contains no owners." >&2
  exit 1
fi

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
# Validate gh access
#
# Checks up front that the gh token can see everything it should, so a backup
# that silently misses private repos is caught before the slow clone loop.
# Problems are collected into ACCESS_ERRORS and reported together.
# ---------------------------------------------------------------------------

echo "Validating gh access..."

ACCESS_ERRORS=()

if ! AUTH_USER="$(gh api user --jq '.login')"; then
  echo "Error: 'gh api user' failed; cannot identify the authenticated user." >&2
  exit 1
fi

# Classic OAuth tokens (gh auth login) report their scopes in this header.
# Fine-grained PATs / GITHUB_TOKEN don't; the repo count cross-check below
# still catches missing access for those.
TOKEN_SCOPES="$(
  gh api --include user 2>/dev/null | tr -d '\r' |
    sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | head -n 1
)" || true

has_scope() {
  [[ ", ${TOKEN_SCOPES}, " == *", $1, "* ]]
}

if [[ -z "$TOKEN_SCOPES" ]]; then
  echo "WARNING: could not read token scopes (fine-grained token?); relying on the repo count check." >&2
elif ! has_scope repo; then
  ACCESS_ERRORS+=("token is missing the 'repo' scope (private repos would be skipped): run 'gh auth refresh -s repo'")
fi

# Expected repo counts per owner, as reported by GitHub. An empty private count
# means GitHub didn't expose it to this token, so that half of the check is
# skipped.
declare -A EXPECTED_PUBLIC=()
declare -A EXPECTED_PRIVATE=()

for owner in "${OWNER_LIST[@]}"; do
  if ! owner_type="$(gh api "users/$owner" --jq '.type' 2>/dev/null)"; then
    ACCESS_ERRORS+=("$owner: account not found, or not visible to this token")
    continue
  fi

  if [[ "$owner_type" == "Organization" ]]; then
    if [[ -n "$TOKEN_SCOPES" ]] && ! has_scope read:org; then
      ACCESS_ERRORS+=("$owner: token is missing the 'read:org' scope: run 'gh auth refresh -s read:org'")
      continue
    fi

    # Fails when not a member, and also when the org restricts OAuth apps or
    # enforces SAML SSO and hasn't authorised the gh token; the API message
    # says which.
    # GitHub's own message here is often misleading (e.g. asking for
    # admin:org when you simply aren't a member), so only SSO is surfaced.
    if ! membership="$(gh api "user/memberships/orgs/$owner" --jq '.state' 2>&1)"; then
      if [[ "$membership" == *SAML* ]]; then
        ACCESS_ERRORS+=("$owner: the org enforces SAML SSO and this token isn't authorised for it: run 'gh auth refresh' and authorise $owner")
      else
        ACCESS_ERRORS+=("$owner: cannot confirm you are a member. If you are, the org may block GitHub CLI: approve it at https://github.com/organizations/$owner/settings/oauth_application_policy")
      fi
      continue
    fi

    if [[ "$membership" != "active" ]]; then
      ACCESS_ERRORS+=("$owner: org membership is '$membership', not 'active' (accept the invite on github.com)")
      continue
    fi

    org_counts="$(gh api "orgs/$owner" --jq '"\(.public_repos) \(.total_private_repos // "")"')" || {
      ACCESS_ERRORS+=("$owner: 'gh api orgs/$owner' failed")
      continue
    }
    read -r EXPECTED_PUBLIC["$owner"] EXPECTED_PRIVATE["$owner"] <<< "$org_counts" || true
  elif [[ "${owner,,}" == "${AUTH_USER,,}" ]]; then
    user_counts="$(gh api user --jq '"\(.public_repos) \(.total_private_repos // "")"')" || {
      ACCESS_ERRORS+=("$owner: 'gh api user' failed")
      continue
    }
    read -r EXPECTED_PUBLIC["$owner"] EXPECTED_PRIVATE["$owner"] <<< "$user_counts" || true
  else
    echo "WARNING: $owner is another user's account (gh is logged in as $AUTH_USER); only its public repos can be backed up." >&2
    EXPECTED_PUBLIC["$owner"]="$(gh api "users/$owner" --jq '.public_repos')" || true
  fi
done

if [[ ${#ACCESS_ERRORS[@]} -gt 0 ]]; then
  echo "Error: gh cannot access everything this backup needs:" >&2
  printf '  - %s\n' "${ACCESS_ERRORS[@]}" >&2
  exit 1
fi

echo "gh access OK (logged in as $AUTH_USER${TOKEN_SCOPES:+, scopes: $TOKEN_SCOPES})."

# ---------------------------------------------------------------------------
# Build repo list
# ---------------------------------------------------------------------------

ALL_REPOS=()

for owner in "${OWNER_LIST[@]}"; do
  echo "Fetching repo list for $owner from GitHub..."

  LIST_ARGS=(
    repo list "$owner"
    --limit 1000
    --json 'nameWithOwner,visibility'
    --jq '.[] | "\(.visibility) \(.nameWithOwner)"'
  )

  if ! repo_list="$(gh "${LIST_ARGS[@]}")"; then
    echo "Error: 'gh repo list $owner' failed." >&2
    exit 1
  fi

  owner_repos=()
  listed_public=0
  listed_private=0

  # Each line is "<VISIBILITY> <owner/name>"; INTERNAL counts as private.
  while read -r visibility name; do
    [[ -z "$name" ]] && continue
    owner_repos+=("$name")
    if [[ "$visibility" == "PUBLIC" ]]; then
      listed_public=$((listed_public + 1))
    else
      listed_private=$((listed_private + 1))
    fi
  done <<< "$repo_list"

  echo "  $owner: ${#owner_repos[@]} repo(s) ($listed_public public, $listed_private private)"

  # Fewer listed than GitHub reports means some are invisible to this token
  # (OAuth app restrictions, SSO, a fine-grained token without access to them).
  expected_public="${EXPECTED_PUBLIC[$owner]:-}"
  expected_private="${EXPECTED_PRIVATE[$owner]:-}"
  if [[ -n "$expected_public" ]] && ((listed_public < expected_public)); then
    ACCESS_ERRORS+=("$owner: listed $listed_public public repo(s) but GitHub reports $expected_public")
  fi
  if [[ -n "$expected_private" ]] && ((listed_private < expected_private)); then
    ACCESS_ERRORS+=("$owner: listed $listed_private private repo(s) but GitHub reports $expected_private; the token cannot see them all")
  fi

  if [[ ${#owner_repos[@]} -eq 0 ]]; then
    echo "WARNING: no repos returned for owner '$owner'." >&2
    continue
  fi

  if [[ ${#owner_repos[@]} -eq 1000 ]]; then
    echo "WARNING: hit --limit 1000 for $owner; some repos may be missing from the backup." >&2
  fi

  ALL_REPOS+=("${owner_repos[@]}")
done

if [[ ${#ACCESS_ERRORS[@]} -gt 0 ]]; then
  echo "Error: the repo list is incomplete:" >&2
  printf '  - %s\n' "${ACCESS_ERRORS[@]}" >&2
  exit 1
fi

if [[ ${#ALL_REPOS[@]} -eq 0 ]]; then
  echo "Error: no repos returned for any owner (${OWNER_LIST[*]})." >&2
  exit 1
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
  # "owner/name" -> <owner>/<name>/ in the archive, so each owner's repos stay
  # in their own folder and same-named repos across owners cannot collide.
  dest="${WORKDIR}/${repo}"

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
