#!/usr/bin/env bash
# wt-cleaner.sh — interactive worktree cleaner. Prints the path the parent shell
# should cd to on stdout.
#
# Usage: wt-cleaner.sh [--no-pr] [--yes] [--pick-branches <a,b,c>]
#                     [--debug-status <branch>] [-h|--help]
set -euo pipefail

_WT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-lib.sh"
[ -r "$_WT_LIB" ] || { echo "wt-lib.sh missing next to $(basename "$0")" >&2; exit 1; }
source "$_WT_LIB"
unset _WT_LIB

NO_PR=0
YES=0
PICK_BRANCHES=""
DEBUG_STATUS=""

usage() {
  cat <<EOF
Usage: wt-cleaner.sh [options]

Options:
  --no-pr                  Skip PR-status lookups (faster startup).
  -h, --help               Show this help and exit.

Test seam (not for normal use):
  --yes                    Skip the size/confirm prompt.
  --pick-branches <a,b,c>  Skip fzf; treat <a>,<b>,<c> as the selected rows.
  --debug-status <branch>  Print the status string for <branch> and exit.

Prints the path the parent shell should cd to on stdout. Exits 0 on any
success, 130 on cancel, 1 on nothing-to-clean / all-failed, 2 on bad flags.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pr)            NO_PR=1; shift ;;
    --yes)              YES=1; shift ;;
    --pick-branches)
      [ $# -ge 2 ] || { echo "--pick-branches requires an argument" >&2; exit 2; }
      PICK_BRANCHES="$2"; shift 2 ;;
    --debug-status)
      [ $# -ge 2 ] || { echo "--debug-status requires an argument" >&2; exit 2; }
      DEBUG_STATUS="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

need fzf
need jq

resolve_primary_root
build_worktree_map

declare -A ELIGIBLE_WORKTREES=()
for branch in "${!WORKTREE_MAP[@]}"; do
  path="${WORKTREE_MAP[$branch]}"
  [ "$path" = "$PRIMARY_ROOT" ] && continue
  ELIGIBLE_WORKTREES["$branch"]="$path"
done

compute_status() {
  local path="$1"
  if [ -z "$path" ]; then
    echo "clean"
    return 0
  fi
  local parts="" upstream ahead behind
  local -a dirty_lines=()
  upstream=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    ahead=$(git -C "$path"  rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
    behind=$(git -C "$path" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
    [ "$ahead"  -gt 0 ] && parts="$parts ↑$ahead"
    [ "$behind" -gt 0 ] && parts="$parts ↓$behind"
  fi
  mapfile -t dirty_lines < <(git -C "$path" status --porcelain 2>/dev/null || true)
  [ "${#dirty_lines[@]}" -gt 0 ] && parts="$parts +${#dirty_lines[@]}"
  parts="${parts# }"
  [ -z "$parts" ] && parts="clean"
  echo "$parts"
}

if [ -n "$DEBUG_STATUS" ]; then
  compute_status "${WORKTREE_MAP[$DEBUG_STATUS]:-}"
  exit 0
fi

compose_rows() {
  # Prints "<display>\t<hidden_path>\t<hidden_branch>" per eligible worktree,
  # sorted oldest-first by committerdate.
  local branch path status_str pr_cell display branch_for_display age ts log_out
  local -a sortable=()
  for branch in "${!ELIGIBLE_WORKTREES[@]}"; do
    path="${ELIGIBLE_WORKTREES[$branch]}"
    log_out=$(git -C "$path" log -1 --format='%ct%x09%cr' 2>/dev/null || echo $'0\t?')
    ts="${log_out%%$'\t'*}"
    age="${log_out#*$'\t'}"
    # Pad timestamp to a fixed width so lexicographic sort is numeric-correct.
    sortable+=("$(printf '%012d\t%s\t%s\t%s\n' "$ts" "$age" "$branch" "$path")")
  done
  if [ "${#sortable[@]}" -eq 0 ]; then return 0; fi
  printf '%s\n' "${sortable[@]}" | sort | while IFS=$'\t' read -r _ts age branch path; do
    status_str=$(compute_status "$path")
    pr_cell="${PR_MAP[$branch]:--}"
    branch_for_display="$branch"
    if [ ${#branch_for_display} -gt 50 ]; then
      branch_for_display="${branch_for_display:0:49}…"
    fi
    display=$(printf '%-50s  %-14s  %-18s  %-16s' \
      "$branch_for_display" "$age" "$status_str" "$pr_cell")
    printf '%s\t%s\t%s\n' "$display" "$path" "$branch"
  done
}

resolve_from_pick_branches() {
  local picks_csv="$1" pick path
  local -a picks=()
  IFS=',' read -ra picks <<< "$picks_csv"
  for pick in "${picks[@]}"; do
    path="${ELIGIBLE_WORKTREES[$pick]:-}"
    if [ -z "$path" ]; then
      echo "not an eligible worktree to clean: $pick" >&2
      exit 1
    fi
    SELECTED_PATHS+=("$path")
    SELECTED_BRANCHES+=("$pick")
  done
}

resolve_from_fzf() {
  build_pr_map "$NO_PR"
  local ROWS PICKED HEADER_COLS HEADER_LEGEND _display path branch
  ROWS=$(compose_rows)
  if [ -z "$ROWS" ]; then
    echo "no worktrees to clean" >&2
    exit 1
  fi
  HEADER_COLS=$(printf '%-50s  %-14s  %-18s  %-16s' "BRANCH" "AGE" "STATUS" "PR")
  HEADER_LEGEND='Tab select  ·  Enter confirm  ·  Esc cancel'
  PICKED=$(echo "$ROWS" | run_fzf --multi 'clean › ' "$HEADER_COLS" "$HEADER_LEGEND") || exit $?

  if [ -z "$PICKED" ]; then
    echo "nothing selected" >&2
    exit 130
  fi

  # IFS=$'\t' read is safe here: every eligible branch has a worktree, so
  # the path field is never empty. (The picker can't use this shape — its
  # rows carry an empty path field for not-yet-worktreed branches, which
  # adjacent tabs would collapse.)
  while IFS=$'\t' read -r _display path branch; do
    SELECTED_PATHS+=("$path")
    SELECTED_BRANCHES+=("$branch")
  done <<< "$PICKED"
}

declare -a SELECTED_PATHS=()
declare -a SELECTED_BRANCHES=()
if [ -n "$PICK_BRANCHES" ]; then
  resolve_from_pick_branches "$PICK_BRANCHES"
else
  resolve_from_fzf
fi

# BSD and GNU `du` both support `-sk` — kilobytes, hence the `* 1024`.
dir_bytes() {
  local kb
  kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
  echo $(( ${kb:-0} * 1024 ))
}

fmt_size() {
  awk -v b="$1" 'BEGIN {
    if      (b >= 1073741824) printf "%.1f GB", b/1073741824
    else if (b >= 1048576)    printf "%.0f MB", b/1048576
    else if (b >= 1024)       printf "%.0f KB", b/1024
    else                      printf "%d B", b
  }'
}

# Size each selected worktree once; the delete loop reuses these for the
# per-row `[i/N]` line so we don't run `du -sk` twice on GB-scale trees.
declare -a SELECTED_SIZES=()
declare -i TOTAL_SELECTED_BYTES=0
for path in "${SELECTED_PATHS[@]}"; do
  size=$(dir_bytes "$path")
  SELECTED_SIZES+=("$size")
  TOTAL_SELECTED_BYTES=$(( TOTAL_SELECTED_BYTES + size ))
done

if [ "$YES" -ne 1 ]; then
  printf 'Delete %d worktrees (%s)? [Y/n] ' \
    "${#SELECTED_PATHS[@]}" "$(fmt_size "$TOTAL_SELECTED_BYTES")" >&2
  if ! read -r REPLY; then
    echo "" >&2
    exit 130
  fi
  case "$REPLY" in
    ""|y|Y|yes|YES) : ;;
    *) exit 130 ;;
  esac
fi

# Detect whether $PWD is one of the picked paths (self-delete case).
ORIGINAL_PWD="$PWD"
SELF_DELETE=0
for path in "${SELECTED_PATHS[@]}"; do
  if [ "$ORIGINAL_PWD" = "$path" ]; then
    SELF_DELETE=1
    break
  fi
done

# If we're about to remove our own cwd, step out to PRIMARY_ROOT first so
# git doesn't refuse with "cannot remove the current working directory".
if [ "$SELF_DELETE" -eq 1 ]; then
  cd "$PRIMARY_ROOT"
fi

declare -i SUCCESS_COUNT=0
declare -i FAIL_COUNT=0
declare -i TOTAL_FREED_BYTES=0

TOTAL=${#SELECTED_PATHS[@]}
for i in "${!SELECTED_PATHS[@]}"; do
  path="${SELECTED_PATHS[$i]}"
  branch="${SELECTED_BRANCHES[$i]}"
  size="${SELECTED_SIZES[$i]}"
  printf '[%d/%d] %s (%s)\n' "$(( i + 1 ))" "$TOTAL" "$branch" "$(fmt_size "$size")" >&2
  if err=$(git -C "$PRIMARY_ROOT" worktree remove --force --force "$path" 2>&1); then
    SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
    TOTAL_FREED_BYTES=$(( TOTAL_FREED_BYTES + size ))
  else
    echo "failed: $branch — $err" >&2
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
done

freed_str=$(fmt_size "$TOTAL_FREED_BYTES")
if [ "$SUCCESS_COUNT" -gt 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  echo "freed $freed_str across $SUCCESS_COUNT worktrees" >&2
elif [ "$SUCCESS_COUNT" -gt 0 ]; then
  echo "freed $freed_str across $SUCCESS_COUNT worktrees · $FAIL_COUNT failed (see above)" >&2
elif [ "$FAIL_COUNT" -gt 0 ]; then
  echo "nothing freed · $FAIL_COUNT failed" >&2
fi

# stdout: where the parent shell should cd.
if [ "$SELF_DELETE" -eq 1 ]; then
  echo "$PRIMARY_ROOT"
else
  echo "$ORIGINAL_PWD"
fi

if [ "$SUCCESS_COUNT" -gt 0 ]; then
  exit 0
else
  exit 1
fi
