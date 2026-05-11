#!/usr/bin/env bash
# wt.bash — defines the `wt` shell function for use with wt-picker.sh.
#
# Usage: add this line to your ~/.bashrc (or ~/.zshrc, ~/.bash_aliases):
#
#   source /absolute/path/to/wt.bash
#
# Then in any git repo, run `wt` to open the interactive worktree picker.

# Resolve our own directory so we can find wt-picker.sh next to us, regardless
# of where the repo was cloned. Works in bash; in zsh use `${(%):-%N}` instead.
_WT_PICKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-picker.sh"

wt() {
  local target
  target=$("$_WT_PICKER" "$@") || return $?
  cd "$target"
}
