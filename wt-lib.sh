#!/usr/bin/env bash
# wt-lib.sh — shared helpers for wt-picker.sh and wt-cleaner.sh.
# Not directly executable; meant to be sourced.
#
# Provides:
#   - bash 4 version check (runs at source time)
#   - hint_for / need        : dependency check + install-hint helpers
#   - resolve_primary_root   : sets PRIMARY_ROOT global
#   - build_worktree_map     : populates WORKTREE_MAP global (branch -> path)
#   - build_pr_map "$NO_PR"  : populates PR_MAP global (branch -> "#N State")
#   - run_fzf                : wraps the shared fzf flag set
#
# Both scripts' display tables use widths 50 (branch), 14 (age), 16 (PR).
# Column 3 differs by script: picker uses 3 (●/space marker), cleaner uses 18
# (status string like "↑3 ↓1 +5"). Don't drift the shared columns.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "wt requires bash 4 or newer (associative arrays)." >&2
  echo "  current: ${BASH_VERSION:-unknown}" >&2
  echo "  macOS:   brew install bash   then re-run with the homebrew bash" >&2
  echo "  Linux:   your distro should already have bash 4+; check your PATH" >&2
  exit 1
fi

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

resolve_primary_root() {
  PRIMARY_ROOT=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "not inside a git repo" >&2
    exit 1
  }
  PRIMARY_ROOT=$(dirname "$PRIMARY_ROOT")
}

build_worktree_map() {
  declare -gA WORKTREE_MAP=()
  local line current_path="" br
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
}

# Skipped (PR_MAP left empty) if NO_PR=1, or gh is missing/unauthenticated.
build_pr_map() {
  declare -gA PR_MAP=()
  local no_pr="${1:-0}"
  if [ "$no_pr" -eq 1 ]; then return 0; fi
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

# Reads rows on stdin, runs fzf with the shared flag set, prints picked row(s).
# Usage: <rows> | run_fzf [--multi] <prompt> <header_cols> <header_legend>
run_fzf() {
  local -a extra=()
  if [ "${1:-}" = "--multi" ]; then extra+=(--multi); shift; fi
  local prompt="$1" cols="$2" legend="$3"
  fzf "${extra[@]}" \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=1 \
    --nth=1 \
    --layout=reverse \
    --height=80% \
    --prompt="$prompt" \
    --header="${cols}"$'\n'"${legend}"
}
