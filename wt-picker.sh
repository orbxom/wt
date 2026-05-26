#!/usr/bin/env bash
# wt-picker.sh — interactive worktree picker. Prints absolute target path on stdout.
#
# Usage: wt-picker.sh [--no-pr] [--pick-by-branch <branch>] [-h|--help]
set -euo pipefail

_WT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-lib.sh"
[ -r "$_WT_LIB" ] || { echo "wt-lib.sh missing next to $(basename "$0")" >&2; exit 1; }
source "$_WT_LIB"
unset _WT_LIB

NO_PR=0
PICK_BY_BRANCH=""

usage() {
  cat <<EOF
Usage: wt-picker.sh [options]

Options:
  --no-pr                  Skip PR-status lookups (faster startup).
  --pick-by-branch <name>  Skip fzf; use <name> as the selected branch. (test seam)
  -h, --help               Show this help and exit.

Prints the absolute path of the target worktree on stdout. Exits 0 on success,
130 on user cancel (fzf Esc/Ctrl-C), 1 on error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pr)            NO_PR=1; shift ;;
    --pick-by-branch)
      [ $# -ge 2 ] || { echo "--pick-by-branch requires an argument" >&2; exit 2; }
      PICK_BY_BRANCH="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

need fzf
need jq

resolve_primary_root
build_worktree_map

CURRENT_BRANCH=$(git -C "$PRIMARY_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null) || CURRENT_BRANCH=""

list_branches() {
  # Prints one line per local branch, newest-committerdate first:
  #   <branch>\t<age-relative>
  git for-each-ref \
    --sort=-committerdate \
    --format='%(refname:short)%09%(committerdate:relative)' \
    refs/heads/
}

compose_rows() {
  # Reads "<branch>\t<age>" lines from list_branches and prints
  # "<display>\t<hidden_path>\t<hidden_branch>" rows. fzf shows column 1 only;
  # path and branch ride along so we never have to re-parse the display column.
  local branch age wt_marker pr_cell display path star branch_for_display
  while IFS=$'\t' read -r branch age; do
    path="${WORKTREE_MAP[$branch]:-}"
    if [ -n "$path" ]; then wt_marker="●  "; else wt_marker=" "; fi
    pr_cell="${PR_MAP[$branch]:--}"
    if [ "$branch" = "$CURRENT_BRANCH" ]; then star="* "; else star="  "; fi
    branch_for_display="${star}${branch}"
    if [ ${#branch_for_display} -gt 50 ]; then
      branch_for_display="${branch_for_display:0:49}…"
    fi
    display=$(printf '%-50s  %-14s  %-3s  %-16s' \
      "$branch_for_display" "$age" "$wt_marker" "$pr_cell")
    printf '%s\t%s\t%s\n' "$display" "$path" "$branch"
  done < <(list_branches)
}

resolve_target() {
  local branch="$1"
  if [ -n "${WORKTREE_MAP[$branch]:-}" ]; then
    echo "${WORKTREE_MAP[$branch]}"
    return 0
  fi
  local flat="${branch//\//-}"
  local target="$PRIMARY_ROOT/.worktrees/$flat"
  if [ -e "$target" ]; then
    echo "target path exists but isn't a worktree: $target" >&2
    return 1
  fi
  if ! git -C "$PRIMARY_ROOT" worktree add "$target" "$branch" >&2; then
    return 1
  fi
  local helper="$PRIMARY_ROOT/.setup/shared/symlink-settings.sh"
  if [ -x "$helper" ]; then
    "$helper" --target "$target" >&2 || true
  fi
  echo "$target"
}

if [ -n "$PICK_BY_BRANCH" ]; then
  declare -gA PR_MAP=()
  PICKED=$(compose_rows | awk -F'\t' -v b="$PICK_BY_BRANCH" '$3==b {print; exit}')
  if [ -z "$PICKED" ]; then
    echo "branch not found: $PICK_BY_BRANCH" >&2
    exit 1
  fi
else
  build_pr_map "$NO_PR"

  ROWS=$(compose_rows)
  if [ -z "$ROWS" ]; then
    echo "no branches" >&2
    exit 1
  fi

  HEADER_COLS=$(printf '%-50s  %-14s  %-3s  %-16s' "BRANCH" "AGE" "WT" "PR")
  HEADER_LEGEND='● = worktree exists  ·  * = current branch  ·  ↑/↓ select  ·  Enter open  ·  Esc cancel'

  PICKED=$(echo "$ROWS" | run_fzf 'worktree › ' "$HEADER_COLS" "$HEADER_LEGEND") || exit $?
fi

# Parse tab-separated row by hand: `IFS=$'\t' read` would collapse adjacent
# tabs (tab is IFS-whitespace), folding the empty path field into its neighbor.
rest="${PICKED#*$'\t'}"
PATH_HINT="${rest%%$'\t'*}"
BRANCH="${rest#*$'\t'}"
if [ -n "$PATH_HINT" ]; then
  echo "$PATH_HINT"
  exit 0
fi
resolve_target "$BRANCH"
