#!/usr/bin/env bash
# wt-picker.sh — interactive worktree picker. Prints absolute target path on stdout.
#
# Usage: wt-picker.sh [--no-pr] [--no-color] [--pick-by-branch <branch>] [-h|--help]
set -euo pipefail

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

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 not found. install with: $2" >&2; exit 1; }
}
need fzf "sudo apt install fzf"
need jq  "sudo apt install jq"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "not inside a git repo" >&2
  exit 1
}
PRIMARY_ROOT=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

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

CURRENT_BRANCH=""
if git -C "$PRIMARY_ROOT" symbolic-ref --quiet --short HEAD >/dev/null 2>&1; then
  CURRENT_BRANCH=$(git -C "$PRIMARY_ROOT" symbolic-ref --short HEAD)
fi

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
  # "<display>\t<hidden_path>" rows.
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
    printf '%s\t%s\n' "$display" "$path"
  done < <(list_branches)
}

resolve_target() {
  local branch="$1"
  if [ -n "${WORKTREE_MAP[$branch]:-}" ]; then
    echo "${WORKTREE_MAP[$branch]}"
    return 0
  fi
  local flat="${branch//\//-}"
  local target="$REPO_ROOT/.worktrees/$flat"
  if [ -e "$target" ]; then
    echo "target path exists but isn't a worktree: $target" >&2
    return 1
  fi
  if ! git -C "$REPO_ROOT" worktree add "$target" "$branch" >&2; then
    return 1
  fi
  local helper="$PRIMARY_ROOT/.setup/shared/symlink-settings.sh"
  if [ -x "$helper" ]; then
    "$helper" --target "$target" >&2 || true
  fi
  echo "$target"
}

if [ -n "$PICK_BY_BRANCH" ]; then
  resolve_target "$PICK_BY_BRANCH"
  exit $?
fi

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

# PICKED is "<display>\t<hidden_path>". Recover the branch name from <display>:
#   <display> = "<star><branch>" padded to 50 then "  <age>  <wt>  <pr>".
# The branch text starts at column 0 after stripping "* " or "  " and trailing
# spaces/ellipsis. We need the original branch — re-extract from the row.
DISPLAY="${PICKED%$'\t'*}"
PATH_HINT="${PICKED##*$'\t'}"
if [ -n "$PATH_HINT" ]; then
  echo "$PATH_HINT"
  exit 0
fi

# No pre-existing worktree — derive branch from display column.
# Strip leading "* " or "  ", then strip trailing padding/ellipsis.
NAME_FIELD="${DISPLAY:0:50}"            # first 50 chars (the branch column)
NAME_FIELD="${NAME_FIELD#"${NAME_FIELD%%[![:space:]]*}"}"  # ltrim
NAME_FIELD="${NAME_FIELD%"${NAME_FIELD##*[![:space:]]}"}"  # rtrim
NAME_FIELD="${NAME_FIELD#\* }"          # drop current-branch marker if present
if [[ "$NAME_FIELD" == *"…" ]]; then
  echo "branch name was truncated in display; cannot resolve. (this is a wt-picker.sh bug)" >&2
  exit 1
fi
resolve_target "$NAME_FIELD"
