#!/usr/bin/env bash
# wt-picker.test.sh — tests for wt-picker.sh. Runs every test_* function in this file.
set -u

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")" && pwd)/wt-picker.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# --- assertion helpers -------------------------------------------------------

assert_eq() {
  # assert_eq <actual> <expected> [<label>]
  local actual="$1" expected="$2" label="${3:-}"
  if [ "$actual" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected: $expected"
  echo "       got:      $actual"
  return 1
}

assert_contains() {
  # assert_contains <haystack> <needle> [<label>]
  local haystack="$1" needle="$2" label="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected to contain: $needle"
  echo "       got:                  $haystack"
  return 1
}

assert_exit_code() {
  # assert_exit_code <got> <expected> [<label>]
  local got="$1" expected="$2" label="${3:-}"
  if [ "$got" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected exit $expected, got $got"
  return 1
}

# --- repo helper -------------------------------------------------------------

new_repo() {
  # Creates a throwaway git repo with one initial commit. Prints the path.
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q -b main
  git -C "$tmpdir" config user.email "test@test"
  git -C "$tmpdir" config user.name  "test"
  git -C "$tmpdir" commit -q --allow-empty -m initial
  echo "$tmpdir"
}

# --- runner ------------------------------------------------------------------

# Tests are defined below this line as `test_*` functions.

run_all_tests() {
  local fn
  while read -r fn; do
    echo "--- $fn"
    if "$fn"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      FAILED_TESTS+=("$fn")
    fi
  done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
  echo
  echo "Passed: $PASS  Failed: $FAIL"
  if [ "$FAIL" -gt 0 ]; then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    return 1
  fi
}

# --- tests -------------------------------------------------------------------

test_harness_smoke() {
  assert_eq "1" "1" "smoke"
}

test_help_exits_zero_and_prints_usage() {
  local out rc
  out=$("$SCRIPT_UNDER_TEST" --help 2>&1) ; rc=$?
  assert_exit_code "$rc" 0 "--help rc"      || return 1
  assert_contains "$out" "Usage:" "--help"  || return 1
}

test_unknown_flag_exits_two() {
  local out rc
  out=$("$SCRIPT_UNDER_TEST" --bogus 2>&1) ; rc=$?
  assert_exit_code "$rc" 2 "--bogus rc"     || return 1
  assert_contains "$out" "unknown" "--bogus stderr" || return 1
}

test_missing_fzf_exits_one_with_install_hint() {
  local out rc
  out=$(PATH=/usr/bin:/bin "$SCRIPT_UNDER_TEST" --pick-by-branch foo 2>&1) ; rc=$?
  # The above only fails the test if fzf happens to be in /usr/bin or /bin.
  # If your fzf is in /home/<user>/.local/bin or similar, this test isolates it.
  # Adjust PATH if needed.
  if command -v fzf >/dev/null 2>&1 && { [ -x /usr/bin/fzf ] || [ -x /bin/fzf ]; }; then
    echo "  SKIP (fzf in /usr/bin or /bin — can't isolate)"
    return 0
  fi
  assert_exit_code "$rc" 1 "fzf-missing rc"                    || return 1
  assert_contains "$out" "fzf" "fzf-missing stderr"            || return 1
  assert_contains "$out" "install" "fzf-missing install hint"  || return 1
}

test_missing_jq_exits_one_with_install_hint() {
  # Tries to scrub jq from PATH the same way as the fzf test.
  if command -v jq >/dev/null 2>&1 && { [ -x /usr/bin/jq ] || [ -x /bin/jq ]; }; then
    echo "  SKIP (jq in /usr/bin or /bin — can't isolate)"
    return 0
  fi
  local out rc
  out=$(PATH=/usr/bin:/bin "$SCRIPT_UNDER_TEST" --pick-by-branch foo 2>&1) ; rc=$?
  assert_exit_code "$rc" 1 "jq-missing rc"                     || return 1
  assert_contains "$out" "jq" "jq-missing stderr"              || return 1
}

test_outside_git_repo_exits_one() {
  local tmpdir out rc
  tmpdir=$(mktemp -d)
  out=$(cd "$tmpdir" && "$SCRIPT_UNDER_TEST" --pick-by-branch foo 2>&1) ; rc=$?
  rm -rf "$tmpdir"
  assert_exit_code "$rc" 1 "outside-repo rc"           || return 1
  assert_contains "$out" "git repo" "outside-repo stderr" || return 1
}

test_pick_existing_worktree_returns_its_path() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch foo
  git -C "$repo" worktree add -q "$repo/.worktrees/foo" foo
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --pick-by-branch foo) ; rc=$?
  assert_exit_code "$rc" 0 "pick-existing rc" || return 1
  assert_eq "$out" "$repo/.worktrees/foo" "pick-existing path" || return 1
}

test_pick_branch_checked_out_in_primary_returns_primary_root() {
  local repo out rc primary
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  # Primary repo is on `main` by default after new_repo. Pick `main`.
  primary=$(cd "$repo" && git rev-parse --show-toplevel)
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --pick-by-branch main) ; rc=$?
  assert_exit_code "$rc" 0 "primary-checkout rc"   || return 1
  assert_eq "$out" "$primary" "primary-checkout path" || return 1
}

test_pick_new_branch_creates_slash_flattened_worktree() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat/bar/baz
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --pick-by-branch feat/bar/baz) ; rc=$?
  assert_exit_code "$rc" 0 "create-flat rc"                        || return 1
  assert_eq "$out" "$repo/.worktrees/feat-bar-baz" "create-flat path"   || return 1
  # Worktree must actually exist.
  [ -d "$repo/.worktrees/feat-bar-baz" ] || { echo "  FAIL worktree dir missing"; return 1; }
  git -C "$repo" worktree list --porcelain | grep -q "$repo/.worktrees/feat-bar-baz" \
    || { echo "  FAIL not registered as worktree"; return 1; }
}

test_pick_new_branch_from_inside_worktree_anchors_at_primary() {
  local repo out rc inner
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch existing
  git -C "$repo" worktree add -q "$repo/.worktrees/existing" existing
  inner="$repo/.worktrees/existing"
  git -C "$repo" branch feat/new/thing
  # Run the picker from inside the existing worktree, not the primary.
  out=$(cd "$inner" && "$SCRIPT_UNDER_TEST" --pick-by-branch feat/new/thing) ; rc=$?
  assert_exit_code "$rc" 0 "anchored rc"                                       || return 1
  assert_eq "$out" "$repo/.worktrees/feat-new-thing" "anchored-at-primary path" || return 1
}

test_pick_new_branch_refuses_when_target_occupied() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch foo/bar
  mkdir -p "$repo/.worktrees/foo-bar"
  echo "i am not a worktree" > "$repo/.worktrees/foo-bar/marker.txt"
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --pick-by-branch foo/bar 2>&1) ; rc=$?
  assert_exit_code "$rc" 1 "occupied rc"                               || return 1
  assert_contains "$out" "exists but isn't a worktree" "occupied msg"  || return 1
  # Confirm the marker file wasn't touched.
  [ -f "$repo/.worktrees/foo-bar/marker.txt" ] || { echo "  FAIL clobbered marker"; return 1; }
}

test_symlink_helper_invoked_when_present() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch quux

  # Stage a fake symlink helper that records its invocation.
  mkdir -p "$repo/.setup/shared"
  cat > "$repo/.setup/shared/symlink-settings.sh" <<'STUB'
#!/usr/bin/env bash
# Record the invocation by writing the args to a known file in the target.
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$target" ] || exit 0
mkdir -p "$target"
echo "called for $target" > "$target/.symlink-helper-was-called"
STUB
  chmod +x "$repo/.setup/shared/symlink-settings.sh"

  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --pick-by-branch quux) ; rc=$?
  assert_exit_code "$rc" 0 "symlink rc" || return 1
  [ -f "$repo/.worktrees/quux/.symlink-helper-was-called" ] \
    || { echo "  FAIL helper not invoked"; return 1; }
}

test_symlink_helper_absent_is_silent() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch absent-helper
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --pick-by-branch absent-helper 2>&1) ; rc=$?
  assert_exit_code "$rc" 0 "absent-helper rc"               || return 1
  # No mention of symlinking should appear in stderr.
  if echo "$out" | grep -qi 'symlink'; then
    echo "  FAIL unexpected 'symlink' in stderr: $out"
    return 1
  fi
}

test_no_pr_flag_runs_without_gh() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch nogh
  out=$(cd "$repo" && PATH=/usr/bin:/bin "$SCRIPT_UNDER_TEST" --no-pr --pick-by-branch nogh) ; rc=$?
  assert_exit_code "$rc" 0 "no-pr rc"                             || return 1
  assert_eq "$out" "$repo/.worktrees/nogh" "no-pr path"           || return 1
}

run_all_tests
