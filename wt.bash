#!/usr/bin/env bash
# wt.bash — defines the `wt` shell function for use with wt-picker.sh.
#
# Usage: add this line to your ~/.bashrc (or ~/.zshrc, ~/.bash_aliases):
#
#   source /absolute/path/to/wt.bash
#
# Then in any git repo, run `wt` to open the interactive worktree picker.

# Resolve our own directory so we can find sibling scripts regardless of where
# the repo was cloned. Works in bash; in zsh use `${(%):-%N}` instead.
_WT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WT_PICKER="$_WT_DIR/wt-picker.sh"

wt() {
  local target
  target=$("$_WT_PICKER" "$@") || return $?
  cd "$target" || return $?
}
