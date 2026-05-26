#!/usr/bin/env bash
# wt-cleaner.sh — interactive worktree cleaner. Prints the path the parent shell
# should cd to on stdout.
#
# Usage: wt-cleaner.sh [--no-pr] [--no-color] [--yes] [--pick-branches <a,b,c>]
#                     [--debug-status <branch>] [-h|--help]
set -euo pipefail

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "wt-cleaner.sh requires bash 4 or newer (associative arrays)." >&2
  echo "  current: ${BASH_VERSION:-unknown}" >&2
  echo "  macOS:   brew install bash   then re-run with the homebrew bash" >&2
  echo "  Linux:   your distro should already have bash 4+; check your PATH" >&2
  exit 1
fi

NO_PR=0
NO_COLOR=0
YES=0
PICK_BRANCHES=""
DEBUG_STATUS=""

usage() {
  cat <<EOF
Usage: wt-cleaner.sh [options]

Options:
  --no-pr                  Skip PR-status lookups (faster startup).
  --no-color               Disable ANSI colors.
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
    --no-color)         NO_COLOR=1; shift ;;
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

hint_for() {
  local tool="$1"
  if command -v brew >/dev/null 2>&1; then
    echo "brew install $tool"
  elif command -v apt >/dev/null 2>&1; then
    echo "sudo apt install $tool"
  elif command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install $tool"
  elif command -v pacman >/dev/null 2>&1; then
    echo "sudo pacman -S $tool"
  else
    echo "(install $tool with your package manager)"
  fi
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 not found. install with: $(hint_for "$1")" >&2
    exit 1
  }
}
need fzf
need jq

PRIMARY_ROOT=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "not inside a git repo" >&2
  exit 1
}
PRIMARY_ROOT=$(dirname "$PRIMARY_ROOT")

# Build branch -> absolute-path map from `git worktree list --porcelain`.
declare -A WORKTREE_MAP
current_path=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) current_path="${line#worktree }" ;;
    "branch refs/heads/"*)
      br="${line#branch refs/heads/}"
      WORKTREE_MAP["$br"]="$current_path"
      ;;
    "")  current_path="" ;;
  esac
done < <(git worktree list --porcelain)

# Eligible = everything except the primary worktree.
declare -a ELIGIBLE_BRANCHES=()
declare -a ELIGIBLE_PATHS=()
for branch in "${!WORKTREE_MAP[@]}"; do
  path="${WORKTREE_MAP[$branch]}"
  if [ "$path" = "$PRIMARY_ROOT" ]; then continue; fi
  ELIGIBLE_BRANCHES+=("$branch")
  ELIGIBLE_PATHS+=("$path")
done

compute_status() {
  local branch="$1"
  local path="${WORKTREE_MAP[$branch]:-}"
  if [ -z "$path" ]; then
    echo "clean"
    return 0
  fi
  local parts="" upstream ahead behind dirty
  upstream=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    ahead=$(git -C "$path"  rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
    behind=$(git -C "$path" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
    [ "$ahead"  -gt 0 ] && parts="$parts ↑$ahead"
    [ "$behind" -gt 0 ] && parts="$parts ↓$behind"
  fi
  dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ "$dirty" -gt 0 ] && parts="$parts +$dirty"
  parts="${parts# }"
  [ -z "$parts" ] && parts="clean"
  echo "$parts"
}

if [ -n "$DEBUG_STATUS" ]; then
  compute_status "$DEBUG_STATUS"
  exit 0
fi

build_pr_map() {
  declare -gA PR_MAP=()
  if [ "$NO_PR" -eq 1 ]; then return 0; fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh not installed; PR column will be '-'. Use --no-pr to silence." >&2
    return 0
  fi
  local json
  if ! json=$(gh pr list --state all --limit 200 \
                --json number,state,isDraft,headRefName 2>/dev/null); then
    echo "gh failed (auth?); PR column will be '-'." >&2
    return 0
  fi
  local ref num state draft cell
  while IFS=$'\t' read -r ref num state draft; do
    if [ "$draft" = "true" ]; then
      cell="#$num Draft"
    else
      cell="#$num $state"
    fi
    PR_MAP["$ref"]="$cell"
  done < <(echo "$json" | jq -r '.[] | [.headRefName, .number, .state, .isDraft] | @tsv')
}

compose_rows() {
  # Prints "<display>\t<hidden_path>\t<hidden_branch>" per eligible worktree,
  # sorted oldest-first by committerdate.
  local branch path status_str pr_cell display branch_for_display age ts
  local -a sortable=()
  for i in "${!ELIGIBLE_BRANCHES[@]}"; do
    branch="${ELIGIBLE_BRANCHES[$i]}"
    path="${ELIGIBLE_PATHS[$i]}"
    ts=$(git -C "$path" log -1 --format='%ct' 2>/dev/null || echo 0)
    # Pad timestamp to a fixed width so lexicographic sort is numeric-correct.
    sortable+=("$(printf '%012d\t%s\t%s\n' "$ts" "$branch" "$path")")
  done
  if [ "${#sortable[@]}" -eq 0 ]; then return 0; fi
  printf '%s\n' "${sortable[@]}" | sort | while IFS=$'\t' read -r _ts branch path; do
    status_str=$(compute_status "$branch")
    pr_cell="${PR_MAP[$branch]:--}"
    age=$(git -C "$path" log -1 --format='%cr' 2>/dev/null || echo "?")
    branch_for_display="$branch"
    if [ ${#branch_for_display} -gt 50 ]; then
      branch_for_display="${branch_for_display:0:49}…"
    fi
    display=$(printf '%-50s  %-14s  %-18s  %-16s' \
      "$branch_for_display" "$age" "$status_str" "$pr_cell")
    printf '%s\t%s\t%s\n' "$display" "$path" "$branch"
  done
}

# If --pick-branches was given, resolve each name to an eligible path.
# This runs before the "nothing to clean" guard so that picking a primary-only
# branch (e.g. main) produces "not an eligible" rather than "no worktrees".
declare -a SELECTED_PATHS=()
declare -a SELECTED_BRANCHES=()
if [ -n "$PICK_BRANCHES" ]; then
  IFS=',' read -ra picks <<< "$PICK_BRANCHES"
  for pick in "${picks[@]}"; do
    found=0
    for i in "${!ELIGIBLE_BRANCHES[@]}"; do
      if [ "${ELIGIBLE_BRANCHES[$i]}" = "$pick" ]; then
        SELECTED_PATHS+=("${ELIGIBLE_PATHS[$i]}")
        SELECTED_BRANCHES+=("$pick")
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "not an eligible worktree to clean: $pick" >&2
      exit 1
    fi
  done
else
  build_pr_map
  ROWS=$(compose_rows)
  if [ -z "$ROWS" ]; then
    echo "no worktrees to clean" >&2
    exit 1
  fi
  HEADER_COLS=$(printf '%-50s  %-14s  %-18s  %-16s' "BRANCH" "AGE" "STATUS" "PR")
  HEADER_LEGEND='Tab select  ·  Enter confirm  ·  Esc cancel'
  PICKED=$(echo "$ROWS" | fzf \
    --multi \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=1 \
    --nth=1 \
    --layout=reverse \
    --height=80% \
    --prompt='clean › ' \
    --header="${HEADER_COLS}"$'\n'"${HEADER_LEGEND}") || exit $?

  if [ -z "$PICKED" ]; then
    echo "nothing selected" >&2
    exit 130
  fi

  while IFS= read -r row; do
    rest="${row#*$'\t'}"
    p="${rest%%$'\t'*}"
    b="${rest#*$'\t'}"
    SELECTED_PATHS+=("$p")
    SELECTED_BRANCHES+=("$b")
  done <<< "$PICKED"
fi

if [ "${#ELIGIBLE_BRANCHES[@]}" -eq 0 ]; then
  echo "no worktrees to clean" >&2
  exit 1
fi

# Cross-platform size helpers, used by both the confirmation prompt and the
# delete loop's summary.
dir_bytes() {
  # `du -sk` is available on both GNU and BSD; multiply by 1024 to get bytes.
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

# Confirmation prompt (skipped by --yes).
if [ "$YES" -ne 1 ]; then
  total_bytes=0
  for path in "${SELECTED_PATHS[@]}"; do
    total_bytes=$(( total_bytes + $(dir_bytes "$path") ))
  done
  printf 'Delete %d worktrees (%s)? [Y/n] ' \
    "${#SELECTED_PATHS[@]}" "$(fmt_size "$total_bytes")" >&2
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

# Delete loop.
declare -i SUCCESS_COUNT=0
declare -i FAIL_COUNT=0
declare -i TOTAL_FREED_BYTES=0

for i in "${!SELECTED_PATHS[@]}"; do
  path="${SELECTED_PATHS[$i]}"
  branch="${SELECTED_BRANCHES[$i]}"
  size=$(dir_bytes "$path")
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
