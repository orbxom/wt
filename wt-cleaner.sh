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
