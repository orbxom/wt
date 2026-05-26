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
fi

if [ "${#ELIGIBLE_BRANCHES[@]}" -eq 0 ]; then
  echo "no worktrees to clean" >&2
  exit 1
fi
