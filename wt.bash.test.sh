#!/usr/bin/env bash
# wt.bash.test.sh — verifies the `wt()` shell function dispatches correctly.
set -u

PASS=0
FAIL=0
FAILED_TESTS=()

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected to contain: $needle"
  echo "       got:                  $haystack"
  return 1
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected NOT to contain: $needle"
  echo "       got:                       $haystack"
  return 1
}

# Build a sandbox with stub picker and cleaner scripts and a copy of wt.bash
# that points at them. Each stub echoes which one was invoked plus its args.
new_sandbox() {
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/wt-picker.sh" <<'STUB'
#!/usr/bin/env bash
echo "picker:$*" >&2
echo "$PWD"  # the path wt() will cd to
STUB
  cat > "$tmp/wt-cleaner.sh" <<'STUB'
#!/usr/bin/env bash
echo "cleaner:$*" >&2
echo "$PWD"
STUB
  chmod +x "$tmp/wt-picker.sh" "$tmp/wt-cleaner.sh"
  cp "$(dirname "$0")/wt.bash" "$tmp/wt.bash"
  echo "$tmp"
}

test_no_args_dispatches_to_picker() {
  local sandbox out
  sandbox=$(new_sandbox)
  trap "rm -rf '$sandbox'" RETURN
  out=$(bash -c "source '$sandbox/wt.bash'; wt" 2>&1)
  assert_contains     "$out" "picker:"  "picker invoked"           || return 1
  assert_not_contains "$out" "cleaner:" "cleaner not invoked"      || return 1
}

test_clean_flag_dispatches_to_cleaner() {
  local sandbox out
  sandbox=$(new_sandbox)
  trap "rm -rf '$sandbox'" RETURN
  out=$(bash -c "source '$sandbox/wt.bash'; wt --clean" 2>&1)
  assert_contains     "$out" "cleaner:" "--clean → cleaner"        || return 1
  assert_not_contains "$out" "picker:"  "picker not invoked"       || return 1
}

test_c_alias_dispatches_to_cleaner() {
  local sandbox out
  sandbox=$(new_sandbox)
  trap "rm -rf '$sandbox'" RETURN
  out=$(bash -c "source '$sandbox/wt.bash'; wt -c" 2>&1)
  assert_contains     "$out" "cleaner:" "-c → cleaner"             || return 1
  assert_not_contains "$out" "picker:"  "picker not invoked"       || return 1
}

test_cleanup_alias_dispatches_to_cleaner() {
  local sandbox out
  sandbox=$(new_sandbox)
  trap "rm -rf '$sandbox'" RETURN
  out=$(bash -c "source '$sandbox/wt.bash'; wt --cleanup" 2>&1)
  assert_contains     "$out" "cleaner:" "--cleanup → cleaner"      || return 1
  assert_not_contains "$out" "picker:"  "picker not invoked"       || return 1
}

test_flag_after_dispatch_is_passed_to_cleaner() {
  local sandbox out
  sandbox=$(new_sandbox)
  trap "rm -rf '$sandbox'" RETURN
  out=$(bash -c "source '$sandbox/wt.bash'; wt --clean --no-pr" 2>&1)
  assert_contains "$out" "cleaner:--no-pr" "--no-pr forwarded"     || return 1
}

run_all_tests() {
  local fn
  while read -r fn; do
    echo "--- $fn"
    if "$fn"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("$fn"); fi
  done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
  echo
  echo "Passed: $PASS  Failed: $FAIL"
  if [ "$FAIL" -gt 0 ]; then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    return 1
  fi
}

run_all_tests
