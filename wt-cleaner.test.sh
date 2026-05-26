#!/usr/bin/env bash
# wt-cleaner.test.sh — tests for wt-cleaner.sh. Runs every test_* function in this file.
set -u

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")" && pwd)/wt-cleaner.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# --- assertion helpers -------------------------------------------------------

assert_eq() {
  local actual="$1" expected="$2" label="${3:-}"
  if [ "$actual" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected: $expected"
  echo "       got:      $actual"
  return 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected to contain: $needle"
  echo "       got:                  $haystack"
  return 1
}

assert_exit_code() {
  local got="$1" expected="$2" label="${3:-}"
  if [ "$got" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected exit $expected, got $got"
  return 1
}

# --- repo helper -------------------------------------------------------------

new_repo() {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q -b main
  git -C "$tmpdir" config user.email "test@test"
  git -C "$tmpdir" config user.name  "test"
  git -C "$tmpdir" commit -q --allow-empty -m initial
  echo "$tmpdir"
}

# --- runner ------------------------------------------------------------------

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
  if command -v fzf >/dev/null 2>&1 && { [ -x /usr/bin/fzf ] || [ -x /bin/fzf ]; }; then
    echo "  SKIP (fzf in /usr/bin or /bin — can't isolate)"
    return 0
  fi
  local out rc
  out=$(PATH=/usr/bin:/bin "$SCRIPT_UNDER_TEST" --pick-branches foo 2>&1) ; rc=$?
  assert_exit_code "$rc" 1 "fzf-missing rc"                    || return 1
  assert_contains "$out" "fzf" "fzf-missing stderr"            || return 1
  assert_contains "$out" "install" "fzf-missing install hint"  || return 1
}

test_missing_jq_exits_one_with_install_hint() {
  if command -v jq >/dev/null 2>&1 && { [ -x /usr/bin/jq ] || [ -x /bin/jq ]; }; then
    echo "  SKIP (jq in /usr/bin or /bin — can't isolate)"
    return 0
  fi
  local out rc
  out=$(PATH=/usr/bin:/bin "$SCRIPT_UNDER_TEST" --pick-branches foo 2>&1) ; rc=$?
  assert_exit_code "$rc" 1 "jq-missing rc"            || return 1
  assert_contains "$out" "jq" "jq-missing stderr"     || return 1
}

test_outside_git_repo_exits_one() {
  local tmpdir out rc
  tmpdir=$(mktemp -d)
  out=$(cd "$tmpdir" && "$SCRIPT_UNDER_TEST" --pick-branches foo 2>&1) ; rc=$?
  rm -rf "$tmpdir"
  assert_exit_code "$rc" 1 "outside-repo rc"              || return 1
  assert_contains "$out" "git repo" "outside-repo stderr" || return 1
}

test_nothing_to_clean_exits_one() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" 2>&1) ; rc=$?
  assert_exit_code "$rc" 1 "nothing-to-clean rc"                  || return 1
  assert_contains "$out" "no worktrees" "nothing-to-clean stderr" || return 1
}

test_primary_excluded_from_picks() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  # `main` is checked out in the primary worktree (the repo root itself).
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches main 2>&1) ; rc=$?
  assert_exit_code "$rc" 1 "primary-pick rc"                 || return 1
  assert_contains "$out" "not an eligible" "primary-pick stderr" || return 1
}

test_unknown_branch_in_pick_branches_errors() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch real
  git -C "$repo" worktree add -q "$repo/.worktrees/real" real
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches no-such 2>&1) ; rc=$?
  assert_exit_code "$rc" 1 "unknown-pick rc"                  || return 1
  assert_contains "$out" "not an eligible" "unknown-pick stderr" || return 1
  # And confirm the real worktree wasn't touched.
  [ -d "$repo/.worktrees/real" ] || { echo "  FAIL real worktree disappeared"; return 1; }
}

test_deletes_selected_worktree() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat-a
  git -C "$repo" worktree add -q "$repo/.worktrees/feat-a" feat-a
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches feat-a 2>/dev/null)
  rc=$?
  assert_exit_code "$rc" 0 "single-delete rc" || return 1
  [ ! -d "$repo/.worktrees/feat-a" ] || { echo "  FAIL worktree still exists"; return 1; }
}

test_deletes_multiple_selected_worktrees() {
  local repo rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat-a
  git -C "$repo" branch feat-b
  git -C "$repo" worktree add -q "$repo/.worktrees/feat-a" feat-a
  git -C "$repo" worktree add -q "$repo/.worktrees/feat-b" feat-b
  (cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches feat-a,feat-b) >/dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 0 "multi-delete rc" || return 1
  [ ! -d "$repo/.worktrees/feat-a" ] || { echo "  FAIL feat-a still exists"; return 1; }
  [ ! -d "$repo/.worktrees/feat-b" ] || { echo "  FAIL feat-b still exists"; return 1; }
}

test_force_removes_dirty_worktree() {
  local repo rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat-d
  git -C "$repo" worktree add -q "$repo/.worktrees/feat-d" feat-d
  echo "uncommitted change" > "$repo/.worktrees/feat-d/scratch.txt"
  (cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches feat-d) >/dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 0 "force-dirty rc" || return 1
  [ ! -d "$repo/.worktrees/feat-d" ] || { echo "  FAIL dirty worktree survived"; return 1; }
}

test_deletes_succeed_summary_reaches_stderr() {
  local repo err
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat
  git -C "$repo" worktree add -q "$repo/.worktrees/feat" feat
  err=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches feat 2>&1 >/dev/null)
  assert_contains "$err" "freed" "summary mentions freed"          || return 1
  assert_contains "$err" "1 worktree" "summary mentions count"     || return 1
}

test_partial_failure_continues_and_reports() {
  local repo err rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat-ok
  git -C "$repo" branch feat-broken
  git -C "$repo" worktree add -q "$repo/.worktrees/feat-ok"     feat-ok
  git -C "$repo" worktree add -q "$repo/.worktrees/feat-broken" feat-broken
  # Break the second one: remove the .git pointer so `git worktree remove`
  # refuses ("not a working tree"). The admin entry stays around so it's
  # still in `git worktree list --porcelain`.
  rm "$repo/.worktrees/feat-broken/.git"
  err=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches feat-ok,feat-broken 2>&1 >/dev/null)
  rc=$?
  assert_exit_code "$rc" 0 "partial-failure rc"                          || return 1
  [ ! -d "$repo/.worktrees/feat-ok" ]      || { echo "  FAIL ok survived"; return 1; }
  [   -d "$repo/.worktrees/feat-broken" ] || { echo "  FAIL broken vanished"; return 1; }
  assert_contains "$err" "failed: feat-broken" "per-failure line" || return 1
  assert_contains "$err" "1 failed"           "summary count"     || return 1
}

test_all_failures_exit_one() {
  local repo rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat-bad
  git -C "$repo" worktree add -q "$repo/.worktrees/feat-bad" feat-bad
  rm "$repo/.worktrees/feat-bad/.git"
  (cd "$repo" && "$SCRIPT_UNDER_TEST" --yes --pick-branches feat-bad) >/dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "all-fail rc" || return 1
}

test_debug_status_clean() {
  local repo out
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat
  git -C "$repo" worktree add -q "$repo/.worktrees/feat" feat
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --debug-status feat)
  assert_eq "$out" "clean" "status-clean" || return 1
}

test_debug_status_dirty() {
  local repo out
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat
  git -C "$repo" worktree add -q "$repo/.worktrees/feat" feat
  echo "untracked" > "$repo/.worktrees/feat/junk.txt"
  echo "modified"  > "$repo/.worktrees/feat/scratch.txt"
  git -C "$repo/.worktrees/feat" add scratch.txt >/dev/null
  git -C "$repo/.worktrees/feat" commit -q -m "track scratch"
  echo "changed"   > "$repo/.worktrees/feat/scratch.txt"
  # Now: 1 untracked (junk.txt) + 1 modified (scratch.txt) = 2.
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --debug-status feat)
  assert_eq "$out" "+2" "status-dirty" || return 1
}

test_debug_status_ahead() {
  local repo out remote
  repo=$(new_repo)
  remote=$(mktemp -d)
  trap "rm -rf '$repo' '$remote'" RETURN
  git -C "$remote" init -q --bare
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main
  git -C "$repo" branch feat main
  git -C "$repo" worktree add -q "$repo/.worktrees/feat" feat
  git -C "$repo/.worktrees/feat" branch --set-upstream-to=origin/main feat >/dev/null
  git -C "$repo/.worktrees/feat" commit -q --allow-empty -m "ahead 1"
  git -C "$repo/.worktrees/feat" commit -q --allow-empty -m "ahead 2"
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --debug-status feat)
  assert_eq "$out" "↑2" "status-ahead" || return 1
}

test_debug_status_ahead_and_dirty() {
  local repo out remote
  repo=$(new_repo)
  remote=$(mktemp -d)
  trap "rm -rf '$repo' '$remote'" RETURN
  git -C "$remote" init -q --bare
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main
  git -C "$repo" branch feat main
  git -C "$repo" worktree add -q "$repo/.worktrees/feat" feat
  git -C "$repo/.worktrees/feat" branch --set-upstream-to=origin/main feat >/dev/null
  git -C "$repo/.worktrees/feat" commit -q --allow-empty -m "ahead 1"
  echo "x" > "$repo/.worktrees/feat/u.txt"
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --debug-status feat)
  assert_eq "$out" "↑1 +1" "status-combined" || return 1
}

test_debug_status_no_upstream() {
  local repo out
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch feat
  git -C "$repo" worktree add -q "$repo/.worktrees/feat" feat
  echo "x" > "$repo/.worktrees/feat/u.txt"
  # No upstream set → ahead/behind not reported, only dirty count.
  out=$(cd "$repo" && "$SCRIPT_UNDER_TEST" --debug-status feat)
  assert_eq "$out" "+1" "status-no-upstream" || return 1
}

run_all_tests
