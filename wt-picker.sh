#!/usr/bin/env bash
# wt-picker.sh — interactive worktree picker. Prints absolute target path on stdout.
#
# Usage: wt-picker.sh [--no-pr] [--no-color] [--pick-by-branch <branch>] [-h|--help]
set -euo pipefail

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "wt-picker.sh requires bash 4 or newer (associative arrays)." >&2
  echo "  current: ${BASH_VERSION:-unknown}" >&2
  echo "  macOS:   brew install bash   then re-run with the homebrew bash" >&2
  echo "  Linux:   your distro should already have bash 4+; check your PATH" >&2
  exit 1
fi

NO_PR=0
NO_COLOR=0
PICK_BY_BRANCH=""

usage() {
  cat <<EOF
Usage: wt-picker.sh [options]

Options:
  --no-pr                  Skip PR-status lookups (faster startup).
  --no-color               Disable ANSI colors.
  --pick-by-branch <name>  Skip fzf; use <name> as the selected branch. (test seam)
  -h, --help               Show this help and exit.

Prints the absolute path of the target worktree on stdout. Exits 0 on success,
130 on user cancel (fzf Esc/Ctrl-C), 1 on error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pr)            NO_PR=1; shift ;;
    --no-color)         NO_COLOR=1; shift ;;
    --pick-by-branch)
      [ $# -ge 2 ] || { echo "--pick-by-branch requires an argument" >&2; exit 2; }
      PICK_BY_BRANCH="$2"; shift 2 ;;
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

CURRENT_BRANCH=$(git -C "$PRIMARY_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null) || CURRENT_BRANCH=""

list_branches() {
  # Prints one line per local branch, newest-committerdate first:
  #   <branch>\t<age-relative>
  git for-each-ref \
    --sort=-committerdate \
    --format='%(refname:short)%09%(committerdate:relative)' \
    refs/heads/
}

build_pr_map() {
  # Populates the global PR_MAP associative array.
  # Skipped if --no-pr is set or gh is missing/unauthenticated.
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
  build_pr_map

  ROWS=$(compose_rows)
  if [ -z "$ROWS" ]; then
    echo "no branches" >&2
    exit 1
  fi

  HEADER_COLS=$(printf '%-50s  %-14s  %-3s  %-16s' "BRANCH" "AGE" "WT" "PR")
  HEADER_LEGEND='● = worktree exists  ·  * = current branch  ·  ↑/↓ select  ·  Enter open  ·  Esc cancel'

  PICKED=$(echo "$ROWS" | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=1 \
    --nth=1 \
    --layout=reverse \
    --height=80% \
    --prompt='worktree › ' \
    --header="${HEADER_COLS}"$'\n'"${HEADER_LEGEND}") || exit $?
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
