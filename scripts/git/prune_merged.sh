#!/usr/bin/env bash
#
# prune_merged.sh
#
# Removes every linked worktree and deletes every local branch in the current
# git repo whose work is fully committed and already merged into a base branch
# (default: main). A tip counts as merged when it is an ancestor of the base
# (regular/fast-forward merge), when every one of its commits' patches is
# already in the base (rebase merge; not used if the branch has merge commits),
# or when its combined, non-empty diff matches a single base commit (squash
# merge).
#
# A worktree is removed only if it is clean (no staged, unstaged or untracked
# changes, whatever status.showUntrackedFiles says; gitignored files go with it
# and are counted in the plan), unlocked, merged, has no rebase/merge/
# cherry-pick/bisect in progress, holds no other worktree inside it, is not on
# the base branch, and is neither the main worktree nor the one the script runs
# from. Stale entries whose directory is gone are pruned, unless one of them
# is a detached HEAD that isn't merged. A branch is deleted only if merged and
# not checked out in a worktree that is kept. Every tip is re-checked just
# before it is removed. The base branch and remote branches are never touched.
#
# Prints the plan and asks before changing anything (skip with -y).
#
# Usage:
#   prune_merged.sh [-b|--base BRANCH] [-n|--dry-run] [-y|--yes] [-h|--help]
#
# Requirements: git 2.36+ (for `git worktree list -z`)
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prune_merged.sh [-b|--base BRANCH] [-n|--dry-run] [-y|--yes] [-h|--help]

Remove clean, merged worktrees and delete merged local branches in the current
git repo. Run from anywhere inside the repo.

Options:
  -b, --base BRANCH  Local branch to check merges against (default: main).
  -n, --dry-run      Print the plan and exit without changing anything.
  -y, --yes          Don't ask for confirmation.
  -h, --help         Show this help.
EOF
}

BASE=main
DRY_RUN=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b | --base)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 needs a branch name" >&2
        exit 1
      fi
      BASE="$2"
      shift 2
      ;;
    --base=*)
      BASE="${1#*=}"
      shift
      ;;
    -n | --dry-run)
      DRY_RUN=1
      shift
      ;;
    -y | --yes)
      ASSUME_YES=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: not inside a git repository" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "refs/heads/$BASE^{commit}" >/dev/null; then
  echo "Error: no local branch '$BASE' (use --base to pick another)" >&2
  exit 1
fi

CURRENT_TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)

# Merged = ancestor of BASE, or all patches already in BASE, or squash-equivalent.
is_merged() {
  local ref="$1" mb cherry merges tree squash

  if git merge-base --is-ancestor "$ref" "refs/heads/$BASE"; then
    return 0
  fi
  mb=$(git merge-base "refs/heads/$BASE" "$ref") || return 1

  # git cherry ignores merge commits, so it can't vouch for a branch with any.
  merges=$(git rev-list --merges -n 1 "$ref" --not "refs/heads/$BASE") || return 1
  if [[ -z "$merges" ]]; then
    cherry=$(git cherry "refs/heads/$BASE" "$ref") || return 1
    if [[ -n "$cherry" ]] && ! grep -q '^+' <<<"$cherry"; then
      return 0
    fi
  fi

  tree=$(git rev-parse "$ref^{tree}") || return 1
  [[ "$tree" == "$(git rev-parse "$mb^{tree}")" ]] && return 1
  squash=$(GIT_AUTHOR_NAME=prune GIT_AUTHOR_EMAIL=prune@localhost \
    GIT_COMMITTER_NAME=prune GIT_COMMITTER_EMAIL=prune@localhost \
    git commit-tree "$tree" -p "$mb" -m squash) || return 1
  cherry=$(git cherry "refs/heads/$BASE" "$squash") || return 1
  [[ "$cherry" == "-"* ]]
}

worktree_status() {
  git -C "$1" status --porcelain --untracked-files=all --ignore-submodules=none
}

operation_in_progress() {
  local dir="$1" name path
  for name in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
    path=$(git -C "$dir" rev-parse --path-format=absolute --git-path "$name") || return 0
    [[ -e "$path" ]] && return 0
  done
  return 1
}

# A worktree mid-rebase has a detached HEAD; its branch is in head-name.
rebasing_branch() {
  local dir name file
  [[ -n "$wt_branch" ]] && return 0
  for dir in rebase-merge rebase-apply; do
    file=$(git -C "$1" rev-parse --path-format=absolute --git-path "$dir/head-name") || continue
    [[ -f "$file" ]] || continue
    name=$(<"$file")
    [[ "$name" == refs/heads/* ]] && wt_branch="${name#refs/heads/}"
    return 0
  done
  return 0
}

ALL_WT=()
WT_REMOVE=()
WT_PRUNE=()
PRUNE_BLOCKERS=()
PRUNE_BRANCHES=()
BR_DELETE=()
SKIPPED=()
declare -A KEEP_BRANCH=() WT_HEAD=() WT_BRANCH=() WT_NOTE=() BR_SHA=()

wt_path="" wt_head="" wt_branch="" wt_locked=0 wt_prunable=0 wt_bare=0 wt_index=0

keep_worktree() {
  [[ -n "$wt_branch" ]] && KEEP_BRANCH["$wt_branch"]="$2"
  [[ -n "$1" ]] && SKIPPED+=("$1")
  return 0
}

consider_worktree() {
  local label="worktree $wt_path${wt_branch:+ [$wt_branch]}" status ignored

  if ((wt_index == 0 || wt_bare)); then
    ((wt_bare)) || ALL_WT+=("$wt_path")
    keep_worktree "" "checked out in the main worktree"
    return 0
  fi
  if ((wt_locked)); then
    keep_worktree "$label: locked" "checked out in locked worktree $wt_path"
    return 0
  fi
  if ((wt_prunable)); then
    if [[ -z "$wt_branch" ]] && ! is_merged "$wt_head"; then
      PRUNE_BLOCKERS+=("$wt_path")
      SKIPPED+=("$label: directory missing and detached HEAD $wt_head isn't merged into $BASE")
      return 0
    fi
    WT_PRUNE+=("$wt_path")
    [[ -n "$wt_branch" ]] && PRUNE_BRANCHES+=("$wt_branch")
    return 0
  fi

  ALL_WT+=("$wt_path")
  local kept="checked out in kept worktree $wt_path"
  if [[ -n "$CURRENT_TOP" && "$wt_path" -ef "$CURRENT_TOP" ]]; then
    keep_worktree "$label: it's the current worktree" "$kept"
    return 0
  fi
  if [[ "$wt_branch" == "$BASE" ]]; then
    keep_worktree "$label: it's on $BASE" "$kept"
    return 0
  fi
  if operation_in_progress "$wt_path"; then
    rebasing_branch "$wt_path"
    keep_worktree "$label: rebase/merge/cherry-pick/bisect in progress" "$kept"
    return 0
  fi
  if ! status=$(worktree_status "$wt_path"); then
    keep_worktree "$label: git status failed" "$kept"
    return 0
  fi
  if [[ -n "$status" ]]; then
    keep_worktree "$label: uncommitted or untracked changes" "$kept"
    return 0
  fi
  if ! is_merged "$wt_head"; then
    keep_worktree "$label: not merged into $BASE" "$kept"
    return 0
  fi

  ignored=$(git -C "$wt_path" status --porcelain --ignored --untracked-files=normal | grep -c '^!!' || true)
  ((ignored > 0)) && WT_NOTE["$wt_path"]=" ($ignored gitignored path(s) go with it)"
  WT_HEAD["$wt_path"]="$wt_head"
  WT_BRANCH["$wt_path"]="$wt_branch"
  WT_REMOVE+=("$wt_path")
  [[ -n "$wt_branch" ]] && WT_NOTE["$wt_path"]+=" [$wt_branch]"
  return 0
}

mapfile -d '' WT_LINES < <(git worktree list --porcelain -z)
for line in "${WT_LINES[@]}" ""; do
  case "$line" in
    "worktree "*) wt_path="${line#worktree }" ;;
    "HEAD "*) wt_head="${line#HEAD }" ;;
    "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
    locked | "locked "*) wt_locked=1 ;;
    prunable | "prunable "*) wt_prunable=1 ;;
    bare) wt_bare=1 ;;
    "")
      if [[ -n "$wt_path" ]]; then
        consider_worktree
        wt_index=$((wt_index + 1))
      fi
      wt_path="" wt_head="" wt_branch="" wt_locked=0 wt_prunable=0 wt_bare=0
      ;;
  esac
done

# Removing a worktree deletes any worktree nested inside it, so keep those.
REMOVABLE=()
for path in "${WT_REMOVE[@]}"; do
  nested=""
  for other in "${ALL_WT[@]}"; do
    [[ "$other" == "$path" ]] && continue
    if [[ "$other" == "$path"/* ]]; then
      nested="$other"
      break
    fi
  done
  if [[ -n "$nested" ]]; then
    SKIPPED+=("worktree $path: contains worktree $nested")
    branch="${WT_BRANCH[$path]}"
    [[ -n "$branch" ]] && KEEP_BRANCH["$branch"]="checked out in kept worktree $path"
    continue
  fi
  REMOVABLE+=("$path")
done
WT_REMOVE=("${REMOVABLE[@]}")

if ((${#WT_PRUNE[@]} > 0 && ${#PRUNE_BLOCKERS[@]} > 0)); then
  for path in "${WT_PRUNE[@]}"; do
    SKIPPED+=("worktree $path: directory missing, but git worktree prune would also drop ${PRUNE_BLOCKERS[0]}")
  done
  for branch in "${PRUNE_BRANCHES[@]}"; do
    KEEP_BRANCH["$branch"]="checked out in stale worktree that can't be pruned"
  done
  WT_PRUNE=()
fi

mapfile -t BRANCHES < <(git for-each-ref --format='%(refname)' refs/heads/)
for ref in "${BRANCHES[@]}"; do
  branch="${ref#refs/heads/}"
  [[ "$branch" == "$BASE" ]] && continue
  if [[ -n "${KEEP_BRANCH[$branch]+set}" ]]; then
    SKIPPED+=("branch $branch: ${KEEP_BRANCH[$branch]}")
    continue
  fi
  if ! is_merged "$ref"; then
    SKIPPED+=("branch $branch: not merged into $BASE")
    continue
  fi
  BR_SHA["$branch"]=$(git rev-parse "$ref")
  BR_DELETE+=("$branch")
done

print_list() {
  local title="$1" item
  shift
  (($# == 0)) && return 0
  echo "$title"
  for item in "$@"; do
    echo "  $item"
  done
}

WT_LABELS=()
for path in "${WT_REMOVE[@]}"; do
  WT_LABELS+=("$path${WT_NOTE[$path]:-}")
done

print_list "Worktrees to remove:" "${WT_LABELS[@]}"
print_list "Stale worktree entries to prune (directory missing):" "${WT_PRUNE[@]}"
print_list "Branches to delete:" "${BR_DELETE[@]}"
print_list "Kept:" "${SKIPPED[@]}"

if ((${#WT_REMOVE[@]} + ${#WT_PRUNE[@]} + ${#BR_DELETE[@]} == 0)); then
  echo "Nothing to prune."
  exit 0
fi
if ((DRY_RUN)); then
  echo "Dry run: nothing changed."
  exit 0
fi
if ((!ASSUME_YES)); then
  if [[ ! -t 0 ]]; then
    echo "Error: stdin is not a terminal; pass -y to proceed without confirmation" >&2
    exit 1
  fi
  read -rp "Proceed? [y/N] " reply
  if [[ "$reply" != [yY] && "$reply" != [yY][eE][sS] ]]; then
    echo "Aborted."
    exit 1
  fi
fi

FAILED=()

for path in "${WT_REMOVE[@]}"; do
  head=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
  status=$(worktree_status "$path" 2>/dev/null || echo changed)
  if [[ "$head" != "${WT_HEAD[$path]}" || -n "$status" ]]; then
    FAILED+=("worktree $path: changed since the plan")
    continue
  fi
  if ! git worktree remove "$path"; then
    FAILED+=("worktree $path")
    continue
  fi
  echo "Removed worktree $path"
done

if ((${#WT_PRUNE[@]} > 0)); then
  if git worktree prune; then
    echo "Pruned stale worktree entries"
  else
    FAILED+=("git worktree prune")
  fi
fi

for branch in "${BR_DELETE[@]}"; do
  sha="${BR_SHA[$branch]}"
  if [[ "$(git rev-parse --verify --quiet "refs/heads/$branch" || true)" != "$sha" ]]; then
    FAILED+=("branch $branch: moved since the plan")
    continue
  fi
  if ! git branch -D "$branch" >/dev/null; then
    FAILED+=("branch $branch")
    continue
  fi
  echo "Deleted branch $branch (was ${sha:0:12})"
done

if ((${#FAILED[@]} > 0)); then
  print_list "Failed:" "${FAILED[@]}" >&2
  exit 1
fi
