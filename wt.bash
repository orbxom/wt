#!/usr/bin/env bash
# wt.bash — defines the `wt` shell function for use with wt-picker.sh.
#
# Usage: add this line to your ~/.bashrc (or ~/.zshrc, ~/.bash_aliases):
#
#   source /absolute/path/to/wt.bash
#
# Then in any git repo, run `wt` to open the interactive worktree picker.

# Resolve our own directory so we can find sibling scripts regardless of where
# the repo was cloned, and regardless of whether this is sourced from bash or zsh.
if [ -n "${BASH_SOURCE:-}" ]; then
  _wt_self="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _wt_self="${(%):-%N}"
else
  _wt_self="$0"
fi
_WT_DIR="$(cd "$(dirname "$_wt_self")" && pwd)"
_WT_PICKER="$_WT_DIR/wt-picker.sh"
_WT_CLEANER="$_WT_DIR/wt-cleaner.sh"
unset _wt_self

wt() {
  local target rc script
  case "${1:-}" in
    -c|--clean|--cleanup)
      shift
      script="$_WT_CLEANER"
      ;;
    *)
      script="$_WT_PICKER"
      ;;
  esac
  target=$("$script" "$@") ; rc=$?
  [ "$rc" -eq 0 ] || return $rc
  [ -n "$target" ] && cd "$target"
}
