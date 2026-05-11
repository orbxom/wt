#!/usr/bin/env bash
# wt-summary.test.sh — tests for wt-summary.sh. Runs every test_* function.
set -u

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")" && pwd)/wt-summary.sh"

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

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected to NOT contain: $needle"
  echo "       got:                              $haystack"
  return 1
}

assert_exit_code() {
  local got="$1" expected="$2" label="${3:-}"
  if [ "$got" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected exit $expected, got $got"
  return 1
}

# --- session-env helper -----------------------------------------------------
#
# Creates a throwaway HOME + workdir pair. Setting HOME isolates BOTH:
#   - the project-dir lookup at $HOME/.claude/projects/<encoded-workdir>/
#   - the summary cache at $HOME/.cache/wt-summary/
# so tests can't pollute each other and don't touch the real ~/.claude.
#
# Usage:
#   eval "$(new_session_env)"
#   # $TEST_HOME, $TEST_WORKDIR, $TEST_PROJECT_DIR now set
#   trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR'" RETURN

new_session_env() {
  local home workdir encoded
  home=$(mktemp -d)
  workdir=$(mktemp -d)
  encoded="${workdir//[^a-zA-Z0-9_-]/-}"
  printf 'TEST_HOME=%q\n'         "$home"
  printf 'TEST_WORKDIR=%q\n'      "$workdir"
  printf 'TEST_PROJECT_DIR=%q\n'  "$home/.claude/projects/$encoded"
}

# --- fake-claude helper -----------------------------------------------------
#
# Writes a stub `claude` script into a tmp bindir and echoes the bindir path.
# Caller prepends to PATH:  PATH="$bindir:$PATH" ...
#
# Behaviors:
#   echo:<text>      — consume stdin, echo <text>, exit 0
#   passthrough      — echo stdin verbatim to stdout, exit 0 (useful for asserting
#                      what the production code piped to claude without recording)
#   sleep:<seconds>  — consume stdin, sleep N seconds, echo "slept", exit 0
#   exit:<code>      — consume stdin, exit <code> with no output
#   record:<path>    — record argv + stdin to <path>, echo "recorded", exit 0
#   fail-loud        — echo "FAKE-CLAUDE-CALLED" to stderr and exit 99

new_fake_claude() {
  local bindir behavior="${1:-echo:fake-summary}"
  bindir=$(mktemp -d)
  case "$behavior" in
    echo:*)
      cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo '${behavior#echo:}'
EOF
      ;;
    passthrough)
      cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
cat
EOF
      ;;
    sleep:*)
      cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
cat >/dev/null
sleep ${behavior#sleep:}
echo slept
EOF
      ;;
    exit:*)
      cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
cat >/dev/null
exit ${behavior#exit:}
EOF
      ;;
    record:*)
      local recordfile="${behavior#record:}"
      cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
{
  echo "ARGV: \$*"
  echo "STDIN_BEGIN"
  cat
  echo "STDIN_END"
} > '$recordfile'
echo "recorded-summary"
EOF
      ;;
    fail-loud)
      cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "FAKE-CLAUDE-CALLED" >&2
exit 99
EOF
      ;;
    *)
      echo "new_fake_claude: unknown behavior: $behavior" >&2
      return 1
      ;;
  esac
  chmod +x "$bindir/claude"
  echo "$bindir"
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

test_path_encoding_handles_dots() {
  # Regression: BrandCrowd.Net-style paths (with `.` in dir names) must encode
  # the dot as `-` because that's what Claude does. Slash-only encoding would
  # produce a wrong project_dir and the script would silent-skip incorrectly.
  local home parent dotted encoded
  home=$(mktemp -d)
  parent=$(mktemp -d)
  dotted="$parent/Has.Dot"
  mkdir -p "$dotted"
  encoded="${dotted//[^a-zA-Z0-9_-]/-}"
  mkdir -p "$home/.claude/projects/$encoded"
  echo '{"type":"user","message":{"content":"hi"}}' \
    > "$home/.claude/projects/$encoded/fix.jsonl"
  local bindir; bindir=$(new_fake_claude "echo:dotted-summary-ok")
  trap "rm -rf '$home' '$parent' '$bindir'" RETURN

  local out rc
  out=$(cd "$dotted" && HOME="$home" PATH="$bindir:$PATH" \
        "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "dotted rc"                                 || return 1
  assert_eq "$out" "dotted-summary-ok" "summary printed for dotted path" || return 1
}

# Stub tests — bodies added in subsequent tasks. They pass as no-ops so the
# harness is wired up but the test surface is visible.

test_silent_skip_when_no_project_dir() {
  eval "$(new_session_env)"
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR'" RETURN
  # No project dir created. Script must exit 0 with no output.
  local out rc
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "no-project-dir rc" || return 1
  assert_eq "$out" "" "no-project-dir stdout"  || return 1
}
test_silent_skip_when_no_jsonl() {
  eval "$(new_session_env)"
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"  # exists but contains no *.jsonl
  local out rc
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "no-jsonl rc" || return 1
  assert_eq "$out" "" "no-jsonl stdout"  || return 1
}
test_silent_skip_when_claude_missing() {
  if [ -x /usr/bin/claude ] || [ -x /bin/claude ]; then
    echo "  SKIP (claude in /usr/bin or /bin — can't isolate)"
    return 0
  fi
  eval "$(new_session_env)"
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  echo '{}' > "$TEST_PROJECT_DIR/dummy.jsonl"
  local out rc
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH=/usr/bin:/bin "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "no-claude rc" || return 1
  assert_eq "$out" "" "no-claude stdout"  || return 1
}
test_jq_filter_extracts_user_and_assistant() {
  eval "$(new_session_env)"
  local bindir; bindir=$(new_fake_claude "passthrough")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  cat > "$TEST_PROJECT_DIR/fix.jsonl" <<'EOF'
{"type":"user","message":{"content":"hello there"}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}
{"type":"assistant","message":{"content":[{"type":"thinking","text":"hmm"},{"type":"text","text":"i replied"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","input":{}}]}}
EOF
  local out rc
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
        "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "extract rc"                              || return 1
  assert_contains     "$out" "USER: hello there" "user line"          || return 1
  assert_contains     "$out" "ASSISTANT: i replied" "assistant line"  || return 1
  assert_not_contains "$out" "tool_result" "tool_result dropped"      || return 1
  assert_not_contains "$out" "tool_use"    "tool_use dropped"         || return 1
  assert_not_contains "$out" "hmm"         "thinking dropped"         || return 1
}

test_processing_message_printed_before_claude_call() {
  eval "$(new_session_env)"
  local bindir errfile
  bindir=$(new_fake_claude "echo:bullet-one")
  errfile=$(mktemp)
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir' '$errfile'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  echo '{"type":"user","message":{"content":"hi"}}' \
    > "$TEST_PROJECT_DIR/fix.jsonl"
  local stdout rc
  stdout=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
           "$SCRIPT_UNDER_TEST" 2>"$errfile") ; rc=$?
  local stderr; stderr=$(cat "$errfile")
  assert_exit_code "$rc" 0 "processing rc"                            || return 1
  assert_eq "$stdout" "bullet-one" "summary on stdout"                 || return 1
  assert_contains "$stderr" "summarizing" "thinking msg on stderr"    || return 1
}

test_no_processing_message_on_cache_hit() {
  eval "$(new_session_env)"
  local bindir errfile
  bindir=$(new_fake_claude "echo:bullet-one")
  errfile=$(mktemp)
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir' '$errfile'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  echo '{"type":"user","message":{"content":"hi"}}' \
    > "$TEST_PROJECT_DIR/fix.jsonl"
  # Prime cache (first call's stderr is allowed to have the thinking msg).
  cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
     "$SCRIPT_UNDER_TEST" >/dev/null 2>/dev/null
  # Second call: pure cache hit, MUST be silent on stderr.
  cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
     "$SCRIPT_UNDER_TEST" >/dev/null 2>"$errfile"
  local stderr; stderr=$(cat "$errfile")
  assert_eq "$stderr" "" "cache hit must be silent on stderr" || return 1
}

test_silent_skip_when_extraction_is_empty() {
  # JSONL exists but contains only tool-call / meta / sidechain entries —
  # nothing for Haiku to summarize. Script must exit silently without burning
  # a claude call (fail-loud fake would scream).
  eval "$(new_session_env)"
  local bindir; bindir=$(new_fake_claude "fail-loud")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  cat > "$TEST_PROJECT_DIR/fix.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","input":{}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}
{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"hook reminder"}]}}
{"type":"file-history-snapshot","snapshot":"..."}
EOF
  local out rc
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
        "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "empty-extract rc"                          || return 1
  assert_eq "$out" "" "empty-extract stdout"                            || return 1
  assert_not_contains "$out" "FAKE-CLAUDE-CALLED" "claude not invoked"  || return 1
}

test_jq_filter_drops_meta_and_sidechain() {
  eval "$(new_session_env)"
  local bindir; bindir=$(new_fake_claude "passthrough")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  cat > "$TEST_PROJECT_DIR/fix.jsonl" <<'EOF'
{"type":"user","message":{"content":"real user message"}}
{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"injected hook reminder"}]}}
{"type":"user","isSidechain":true,"message":{"content":"subagent dispatch"}}
{"type":"file-history-snapshot","snapshot":"..."}
EOF
  local out rc
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
        "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "meta rc"                            || return 1
  assert_contains     "$out" "USER: real user message" "real"   || return 1
  assert_not_contains "$out" "injected hook" "isMeta dropped"   || return 1
  assert_not_contains "$out" "subagent"      "sidechain dropped"|| return 1
  assert_not_contains "$out" "file-history"  "snapshot dropped" || return 1
}
test_tail_keeps_last_10_messages() {
  eval "$(new_session_env)"
  local bindir; bindir=$(new_fake_claude "passthrough")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  : > "$TEST_PROJECT_DIR/fix.jsonl"
  local i
  for i in $(seq 1 25); do
    printf '{"type":"user","message":{"content":"msg-%02d"}}\n' "$i" \
      >> "$TEST_PROJECT_DIR/fix.jsonl"
  done
  local out rc msg_count
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
        "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  assert_exit_code "$rc" 0 "tail rc" || return 1
  msg_count=$(printf '%s\n' "$out" | grep -c 'USER: msg-')
  assert_eq "$msg_count" "10" "exactly 10 USER: msg- lines"        || return 1
  assert_contains     "$out" "msg-16" "16th message kept (tail)"   || return 1
  assert_contains     "$out" "msg-25" "last message kept"          || return 1
  assert_not_contains "$out" "msg-01" "first message dropped"      || return 1
  assert_not_contains "$out" "msg-15" "15th dropped (before tail)" || return 1
}
test_summary_calls_claude_with_haiku_flags() {
  eval "$(new_session_env)"
  local recordfile bindir
  recordfile=$(mktemp)
  bindir=$(new_fake_claude "record:$recordfile")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir' '$recordfile'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  echo '{"type":"user","message":{"content":"hello world"}}' \
    > "$TEST_PROJECT_DIR/fix.jsonl"
  local out rc recorded
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
        "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  recorded=$(cat "$recordfile")
  assert_exit_code "$rc" 0 "task7 rc"                                       || return 1
  assert_eq "$out" "recorded-summary" "stdout is claude output"             || return 1
  assert_contains "$recorded" "--model haiku"            "--model haiku flag"        || return 1
  assert_contains "$recorded" "-p"                       "-p flag"                   || return 1
  assert_contains "$recorded" "--no-session-persistence" "--no-session-persistence"  || return 1
  assert_contains "$recorded" "--append-system-prompt"   "--append-system-prompt"    || return 1
  assert_contains "$recorded" "transcript"               "system prompt frames task" || return 1
  assert_contains "$recorded" "USER: hello world"        "stdin has filtered msg"    || return 1
}
test_timeout_kills_hung_claude() {
  eval "$(new_session_env)"
  local bindir; bindir=$(new_fake_claude "sleep:60")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  echo '{"type":"user","message":{"content":"hi"}}' \
    > "$TEST_PROJECT_DIR/fix.jsonl"
  local start_ts end_ts elapsed out rc
  start_ts=$(date +%s)
  out=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir:$PATH" \
        "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc=$?
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  assert_exit_code "$rc" 0 "timeout rc still 0" || return 1
  assert_eq "$out" "" "no output on timeout"    || return 1
  if [ "$elapsed" -gt 32 ]; then
    echo "  FAIL elapsed ${elapsed}s (expected <= 32 — script didn't enforce 30s timeout)"
    return 1
  fi
}
test_cache_hit_skips_claude() {
  eval "$(new_session_env)"
  local bindir1 bindir2
  bindir1=$(new_fake_claude "echo:first-summary")
  bindir2=$(new_fake_claude "fail-loud")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir1' '$bindir2'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  echo '{"type":"user","message":{"content":"hi"}}' \
    > "$TEST_PROJECT_DIR/fix.jsonl"

  # First call populates the cache.
  local out1 rc1
  out1=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir1:$PATH" \
         "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc1=$?
  assert_exit_code "$rc1" 0 "first-call rc"                || return 1
  assert_eq "$out1" "first-summary" "first-call output"    || return 1

  # Second call swaps in a fail-loud claude. If cache hits, claude is NEVER
  # invoked, and we should see the cached value with no error noise.
  local out2 rc2
  out2=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir2:$PATH" \
         "$SCRIPT_UNDER_TEST" 2>/dev/null) ; rc2=$?
  assert_exit_code "$rc2" 0 "cache-hit rc"                              || return 1
  assert_eq "$out2" "first-summary" "cache-hit returns cached value"    || return 1
  assert_not_contains "$out2" "FAKE-CLAUDE-CALLED" "fail-loud not run"  || return 1
}

test_cache_miss_on_new_mtime() {
  eval "$(new_session_env)"
  local bindir1 bindir2
  bindir1=$(new_fake_claude "echo:first-summary")
  bindir2=$(new_fake_claude "echo:second-summary")
  trap "rm -rf '$TEST_HOME' '$TEST_WORKDIR' '$bindir1' '$bindir2'" RETURN
  mkdir -p "$TEST_PROJECT_DIR"
  echo '{"type":"user","message":{"content":"hi"}}' \
    > "$TEST_PROJECT_DIR/fix.jsonl"

  # First call: populate cache.
  local out1
  out1=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir1:$PATH" \
         "$SCRIPT_UNDER_TEST" 2>/dev/null)
  assert_eq "$out1" "first-summary" "first call" || return 1

  # Bump mtime — stat -c %Y has integer-second resolution, so sleep before touch.
  sleep 1
  touch "$TEST_PROJECT_DIR/fix.jsonl"

  # Second call should miss cache and call the fresh fake (which echoes a
  # different summary).
  local out2
  out2=$(cd "$TEST_WORKDIR" && HOME="$TEST_HOME" PATH="$bindir2:$PATH" \
         "$SCRIPT_UNDER_TEST" 2>/dev/null)
  assert_eq "$out2" "second-summary" "cache invalidated after touch" || return 1
}

run_all_tests
