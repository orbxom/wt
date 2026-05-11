# `wt` Worktree Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `wt`, an interactive shell command that lists local branches in the current git repo (newest-commit-first, with worktree + PR status), lets the user arrow-select one, and `cd`s into the existing worktree or creates a new one at `.worktrees/<slash-flattened-branch>`.

**Architecture:** Thin shell function in `~/.bash_aliases` calls a thick helper script at `~/.claude/scripts/wt-picker.sh`. Helper script does enumeration, fzf invocation, and worktree create/resolve; it prints the absolute target path to stdout. The function captures stdout and runs `cd`. A `--pick-by-branch <name>` flag bypasses fzf for automated tests.

**Tech Stack:** Bash, `fzf`, `jq`, `gh` (soft dependency), `git`.

**Important constraint — no git commits.** `~/.claude/` is not a git repository, so per-task commit steps from the standard plan template are replaced with "run the test suite, all tests pass." If you (the implementing agent) feel a strong urge to `git init` `~/.claude/`, stop and ask the user — that's a separate decision.

**Specification:** `~/.claude/docs/specs/2026-05-11-worktree-picker-design.md` — read it before starting.

---

## File Structure

| File | Purpose | Created in task |
|---|---|---|
| `~/.claude/scripts/wt-picker.sh` | Main helper script. Enumerates branches, builds worktree + PR maps, runs fzf, resolves selection, prints target path. | Task 3 onward |
| `~/.claude/scripts/wt-picker.test.sh` | Bash test harness. Auto-discovers `test_*` functions, runs them in throwaway repos, reports pass/fail count. | Task 2 |
| `~/.bash_aliases` | Append a `wt` shell function that calls the script and `cd`s into its stdout. | Task 17 |

Test scope: `wt-picker.sh` is exercised end-to-end via `--pick-by-branch <name>` (which skips fzf). fzf interaction itself is verified by a manual smoke test (Task 18). Symlink propagation is verified by checking that the symlink helper script gets invoked and the symlink actually exists after creation.

---

## Task 1: Create stub files and directory layout

**Files:**
- Create: `~/.claude/scripts/wt-picker.sh` (empty stub)
- Create: `~/.claude/scripts/wt-picker.test.sh` (empty stub)

- [ ] **Step 1: Create stub script with shebang + executable bit**

Run:
```bash
cat > ~/.claude/scripts/wt-picker.sh <<'EOF'
#!/usr/bin/env bash
# wt-picker.sh — interactive worktree picker. Prints absolute target path on stdout.
#
# Usage: wt-picker.sh [--no-pr] [--no-color] [--pick-by-branch <branch>] [-h|--help]
set -euo pipefail

echo "wt-picker.sh: not implemented yet" >&2
exit 1
EOF
chmod +x ~/.claude/scripts/wt-picker.sh
```

- [ ] **Step 2: Create stub test harness with shebang + executable bit**

Run:
```bash
cat > ~/.claude/scripts/wt-picker.test.sh <<'EOF'
#!/usr/bin/env bash
# wt-picker.test.sh — tests for wt-picker.sh. Runs every test_* function.
set -u

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")" && pwd)/wt-picker.sh"

echo "(no tests defined yet)"
EOF
chmod +x ~/.claude/scripts/wt-picker.test.sh
```

- [ ] **Step 3: Verify stubs run without error**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected output: `(no tests defined yet)`, exit 0.

Run: `bash ~/.claude/scripts/wt-picker.sh`
Expected: stderr `wt-picker.sh: not implemented yet`, exit 1.

---

## Task 2: Build the test harness

**Files:**
- Modify: `~/.claude/scripts/wt-picker.test.sh` (replace stub with full harness)

- [ ] **Step 1: Write the harness with assertion helpers, repo helper, and auto-runner**

Replace the contents of `~/.claude/scripts/wt-picker.test.sh` with:

```bash
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

run_all_tests
```

- [ ] **Step 2: Run the suite and verify the smoke test passes**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected:
```
--- test_harness_smoke

Passed: 1  Failed: 0
```
Exit 0.

---

## Task 3: Usage / `--help` / unknown-flag handling

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`
- Modify: `~/.claude/scripts/wt-picker.test.sh` (add tests)

- [ ] **Step 1: Add failing tests**

In `wt-picker.test.sh`, just above `run_all_tests`, add:

```bash
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
```

- [ ] **Step 2: Run tests, observe both fail**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 2 failures (`test_help_exits_zero_and_prints_usage`, `test_unknown_flag_exits_two`). Script currently exits 1 with "not implemented yet".

- [ ] **Step 3: Replace the script body with arg-parsing scaffolding**

Replace the contents of `~/.claude/scripts/wt-picker.sh` with:

```bash
#!/usr/bin/env bash
# wt-picker.sh — interactive worktree picker. Prints absolute target path on stdout.
#
# Usage: wt-picker.sh [--no-pr] [--no-color] [--pick-by-branch <branch>] [-h|--help]
set -euo pipefail

NO_PR=0
NO_COLOR=0
PICK_BY_BRANCH=""

usage() {
  cat <<EOF
Usage: wt-picker.sh [options]

Options:
  --no-pr                  Skip PR-status lookups (faster startup).
  --no-color               Disable ANSI colors.
  --pick-by-branch <name>  Skip fzf; use <name> as the selected branch. (test seam)
  -h, --help               Show this help and exit.

Prints the absolute path of the target worktree on stdout. Exits 0 on success,
130 on user cancel (fzf Esc/Ctrl-C), 1 on error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pr)            NO_PR=1; shift ;;
    --no-color)         NO_COLOR=1; shift ;;
    --pick-by-branch)
      [ $# -ge 2 ] || { echo "--pick-by-branch requires an argument" >&2; exit 2; }
      PICK_BY_BRANCH="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

echo "wt-picker.sh: not implemented yet" >&2
exit 1
```

- [ ] **Step 4: Run tests, verify the two new tests pass**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 3 passed, 0 failed.

---

## Task 4: Dependency checks (`fzf`, `jq`)

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`
- Modify: `~/.claude/scripts/wt-picker.test.sh`

- [ ] **Step 1: Add failing tests**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
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
```

(If both `fzf` and `jq` are installed system-wide in `/usr/bin`, these tests SKIP gracefully — they exist mainly to document expected behavior.)

- [ ] **Step 2: Run tests, observe failures (or skips on system-wide installs)**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: tests fail OR skip depending on host. On a Debian/Ubuntu box with `apt install fzf jq` installed, they will skip.

- [ ] **Step 3: Add dep check before the "not implemented" exit**

In `wt-picker.sh`, just above `echo "wt-picker.sh: not implemented yet" >&2`, insert:

```bash
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 not found. install with: $2" >&2; exit 1; }
}
need fzf "sudo apt install fzf"
need jq  "sudo apt install jq"
```

- [ ] **Step 4: Run tests**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 5 passed (or some skipped depending on PATH), 0 failed.

---

## Task 5: Repo root resolution

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`
- Modify: `~/.claude/scripts/wt-picker.test.sh`

- [ ] **Step 1: Add failing test**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
test_outside_git_repo_exits_one() {
  local tmpdir out rc
  tmpdir=$(mktemp -d)
  out=$(cd "$tmpdir" && "$SCRIPT_UNDER_TEST" --pick-by-branch foo 2>&1) ; rc=$?
  rm -rf "$tmpdir"
  assert_exit_code "$rc" 1 "outside-repo rc"           || return 1
  assert_contains "$out" "git repo" "outside-repo stderr" || return 1
}
```

- [ ] **Step 2: Run tests, observe failure**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: `test_outside_git_repo_exits_one` fails (probably script exits 1 with "not implemented" — close but message wrong).

- [ ] **Step 3: Add repo-root resolution**

In `wt-picker.sh`, replace the `echo "wt-picker.sh: not implemented yet"` line with:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "not inside a git repo" >&2
  exit 1
}
PRIMARY_ROOT=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

echo "wt-picker.sh: not implemented yet (REPO_ROOT=$REPO_ROOT)" >&2
exit 1
```

- [ ] **Step 4: Run tests**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 6 passed, 0 failed.

---

## Task 6: Build worktree map + resolve case "branch has pre-existing worktree"

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`
- Modify: `~/.claude/scripts/wt-picker.test.sh`

- [ ] **Step 1: Add failing test**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
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
```

- [ ] **Step 2: Run tests, observe failure**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: `test_pick_existing_worktree_returns_its_path` fails (script still exits 1).

- [ ] **Step 3: Add worktree-map builder and resolve logic**

In `wt-picker.sh`, replace the `echo "wt-picker.sh: not implemented yet ..."` and `exit 1` lines with:

```bash
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

resolve_target() {
  # Echoes the target path on stdout, exits non-zero on error.
  local branch="$1"
  if [ -n "${WORKTREE_MAP[$branch]:-}" ]; then
    echo "${WORKTREE_MAP[$branch]}"
    return 0
  fi
  echo "no-worktree case not implemented yet" >&2
  return 1
}

if [ -n "$PICK_BY_BRANCH" ]; then
  resolve_target "$PICK_BY_BRANCH"
  exit $?
fi

echo "fzf path not implemented yet" >&2
exit 1
```

- [ ] **Step 4: Run tests**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 7 passed, 0 failed.

---

## Task 7: Resolve case "branch is checked out in primary repo"

**Files:**
- Modify: `~/.claude/scripts/wt-picker.test.sh`

The worktree map from Task 6 already covers this — the primary repo shows up in `git worktree list --porcelain` like any other worktree. This task just adds the test to lock the behavior in.

- [ ] **Step 1: Add test that asserts primary-repo case works**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
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
```

- [ ] **Step 2: Run tests, verify it passes immediately (worktree map already handles this)**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 8 passed, 0 failed.

---

## Task 8: Resolve case "no worktree, target path free → create"

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`
- Modify: `~/.claude/scripts/wt-picker.test.sh`

- [ ] **Step 1: Add failing test**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
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
```

- [ ] **Step 2: Run tests, observe failure**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: `test_pick_new_branch_creates_slash_flattened_worktree` fails with "no-worktree case not implemented yet".

- [ ] **Step 3: Implement worktree creation in `resolve_target`**

In `wt-picker.sh`, replace the `resolve_target` function with:

```bash
resolve_target() {
  local branch="$1"
  if [ -n "${WORKTREE_MAP[$branch]:-}" ]; then
    echo "${WORKTREE_MAP[$branch]}"
    return 0
  fi
  local flat="${branch//\//-}"
  local target="$REPO_ROOT/.worktrees/$flat"
  if [ -e "$target" ]; then
    echo "target path exists but isn't a worktree: $target" >&2
    return 1
  fi
  if ! git -C "$REPO_ROOT" worktree add "$target" "$branch" >&2; then
    return 1
  fi
  echo "$target"
}
```

Note: `git worktree add`'s normal output goes to stderr (`>&2`) so it doesn't contaminate stdout.

- [ ] **Step 4: Run tests**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 9 passed, 0 failed.

---

## Task 9: Resolve case "target path occupied by non-worktree directory"

**Files:**
- Modify: `~/.claude/scripts/wt-picker.test.sh`

The error handling in `resolve_target` from Task 8 already covers this (`[ -e "$target" ]`). This task adds the regression test.

- [ ] **Step 1: Add test**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
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
```

- [ ] **Step 2: Run tests**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 10 passed, 0 failed.

---

## Task 10: Symlink propagation after worktree create

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`
- Modify: `~/.claude/scripts/wt-picker.test.sh`

- [ ] **Step 1: Add failing test for symlink-present case**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
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
```

- [ ] **Step 2: Run tests, observe `test_symlink_helper_invoked_when_present` fails**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: the `present` test fails; the `absent` test already passes (since the script doesn't try to symlink at all yet).

- [ ] **Step 3: Add symlink invocation after successful create**

In `wt-picker.sh`, replace the `resolve_target` function with:

```bash
resolve_target() {
  local branch="$1"
  if [ -n "${WORKTREE_MAP[$branch]:-}" ]; then
    echo "${WORKTREE_MAP[$branch]}"
    return 0
  fi
  local flat="${branch//\//-}"
  local target="$REPO_ROOT/.worktrees/$flat"
  if [ -e "$target" ]; then
    echo "target path exists but isn't a worktree: $target" >&2
    return 1
  fi
  if ! git -C "$REPO_ROOT" worktree add "$target" "$branch" >&2; then
    return 1
  fi
  local helper="$PRIMARY_ROOT/.setup/shared/symlink-settings.sh"
  if [ -x "$helper" ]; then
    "$helper" --target "$target" >&2 || true
  fi
  echo "$target"
}
```

The `|| true` ensures symlink failure doesn't block the cd — the worktree is still usable.

- [ ] **Step 4: Run tests**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 12 passed, 0 failed.

---

## Task 11: `--no-pr` flag works in a repo with no `gh`

**Files:**
- Modify: `~/.claude/scripts/wt-picker.test.sh`

The `--no-pr` flag is already parsed (Task 3) and the test seam (`--pick-by-branch`) never reaches PR logic. This task locks in that the flag does NOT cause an error in a no-gh environment.

- [ ] **Step 1: Add test**

In `wt-picker.test.sh` above `run_all_tests`, add:

```bash
test_no_pr_flag_runs_without_gh() {
  local repo out rc
  repo=$(new_repo)
  trap "rm -rf '$repo'" RETURN
  git -C "$repo" branch nogh
  out=$(cd "$repo" && PATH=/usr/bin:/bin "$SCRIPT_UNDER_TEST" --no-pr --pick-by-branch nogh) ; rc=$?
  assert_exit_code "$rc" 0 "no-pr rc"                             || return 1
  assert_eq "$out" "$repo/.worktrees/nogh" "no-pr path"           || return 1
}
```

- [ ] **Step 2: Run tests**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: 13 passed, 0 failed.

---

## Task 12: Branch enumeration

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`

The fzf-driven path (no `--pick-by-branch`) needs real data. Start with branch enumeration. This task adds a `list_branches` function but doesn't yet hook it to fzf — we'll do that in Task 16.

- [ ] **Step 1: Add `list_branches` function**

In `wt-picker.sh`, insert this **before** the `resolve_target` function:

```bash
list_branches() {
  # Prints one line per local branch, newest-committerdate first:
  #   <branch>\t<age-relative>
  git for-each-ref \
    --sort=-committerdate \
    --format='%(refname:short)%09%(committerdate:relative)' \
    refs/heads/
}
```

- [ ] **Step 2: Smoke-test via the shell**

Run:
```bash
cd /home/zknowles/repos/BrandCrowd.Net
bash -c 'source <(sed -n "/^list_branches/,/^}/p" ~/.claude/scripts/wt-picker.sh); list_branches | head'
```
Expected: branch names with relative ages, newest first.

(No automated test for this step — it's a pure git wrapper. Tasks 13–15 build on it.)

---

## Task 13: Worktree marker + current-branch detection

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`

- [ ] **Step 1: Add `current_branch` resolver**

In `wt-picker.sh`, just after the worktree-map builder, add:

```bash
CURRENT_BRANCH=""
if git -C "$PRIMARY_ROOT" symbolic-ref --quiet --short HEAD >/dev/null 2>&1; then
  CURRENT_BRANCH=$(git -C "$PRIMARY_ROOT" symbolic-ref --short HEAD)
fi
```

- [ ] **Step 2: Verify the underlying git command behaves as expected**

Run:
```bash
cd /home/zknowles/repos/BrandCrowd.Net
git symbolic-ref --quiet --short HEAD
```
Expected: prints the current branch name (e.g. `prep/typegen-manually-typed-pages`), exits 0.

In a detached-HEAD state (rare but possible), the command exits 1 and prints nothing — that's why `wt-picker.sh` guards the call with `if ... >/dev/null 2>&1; then`, and leaves `CURRENT_BRANCH` empty otherwise.

(No automated test for this step — the value is consumed by Task 15's row composer, and that's where the visible behavior shows up.)

---

## Task 14: Build PR map (one `gh` call)

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`

- [ ] **Step 1: Add `build_pr_map` function**

In `wt-picker.sh`, just after `list_branches`, add:

```bash
build_pr_map() {
  # Populates the global PR_MAP associative array.
  # Skipped if --no-pr is set or gh is missing/unauthenticated.
  declare -gA PR_MAP=()
  if [ "$NO_PR" -eq 1 ]; then return 0; fi
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
```

- [ ] **Step 2: Smoke-test in BrandCrowd.Net**

Run:
```bash
cd /home/zknowles/repos/BrandCrowd.Net
bash -c '
  source ~/.claude/scripts/wt-picker.sh --help >/dev/null 2>&1 || true
  # The script exits on --help, so dot-source by extracting just the function:
  eval "$(sed -n "/^build_pr_map()/,/^}/p" ~/.claude/scripts/wt-picker.sh)"
  NO_PR=0
  build_pr_map 2>&1 | head -3
'
```
Expected: silent (gh is installed + authenticated), or a one-line warning if gh isn't authenticated.

(No automated test — gh is a soft dep and integration testing it is fragile.)

---

## Task 15: Row composition

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`

- [ ] **Step 1: Add `compose_rows` function**

In `wt-picker.sh`, just after `build_pr_map`, add:

```bash
compose_rows() {
  # Reads "<branch>\t<age>" lines from list_branches and prints
  # "<display>\t<hidden_path>" rows.
  local branch age wt_marker pr_cell display path star branch_for_display
  while IFS=$'\t' read -r branch age; do
    path="${WORKTREE_MAP[$branch]:-}"
    if [ -n "$path" ]; then wt_marker="●"; else wt_marker=" "; fi
    pr_cell="${PR_MAP[$branch]:--}"
    if [ "$branch" = "$CURRENT_BRANCH" ]; then star="* "; else star="  "; fi
    branch_for_display="${star}${branch}"
    if [ ${#branch_for_display} -gt 50 ]; then
      branch_for_display="${branch_for_display:0:49}…"
    fi
    display=$(printf '%-50s  %-14s  %-3s  %-16s' \
      "$branch_for_display" "$age" "$wt_marker" "$pr_cell")
    printf '%s\t%s\n' "$display" "$path"
  done < <(list_branches)
}
```

- [ ] **Step 2: Smoke-test in BrandCrowd.Net**

Run:
```bash
cd /home/zknowles/repos/BrandCrowd.Net
~/.claude/scripts/wt-picker.sh --no-pr --pick-by-branch develop 2>&1 | head
```

You won't see the rows yet (script returns early via `--pick-by-branch`), but it should exit 0 with the develop worktree path or `develop` checked-out-in-primary path. Tasks 16 will wire the rows to fzf.

(No automated test — visual verification at Task 16.)

---

## Task 16: Wire fzf for interactive selection

**Files:**
- Modify: `~/.claude/scripts/wt-picker.sh`

- [ ] **Step 1: Replace the `fzf path not implemented yet` stub with the fzf invocation**

In `wt-picker.sh`, find the block:

```bash
if [ -n "$PICK_BY_BRANCH" ]; then
  resolve_target "$PICK_BY_BRANCH"
  exit $?
fi

echo "fzf path not implemented yet" >&2
exit 1
```

Replace it with:

```bash
if [ -n "$PICK_BY_BRANCH" ]; then
  resolve_target "$PICK_BY_BRANCH"
  exit $?
fi

build_pr_map

ROWS=$(compose_rows)
if [ -z "$ROWS" ]; then
  echo "no branches" >&2
  exit 1
fi

PICKED=$(echo "$ROWS" | fzf \
  --ansi \
  --delimiter=$'\t' \
  --with-nth=1 \
  --nth=1 \
  --layout=reverse \
  --height=80% \
  --prompt='worktree › ' \
  --header='↑/↓ select · Enter open · Esc cancel') || exit $?

# PICKED is "<display>\t<hidden_path>". Recover the branch name from <display>:
#   <display> = "<star><branch>" padded to 50 then "  <age>  <wt>  <pr>".
# The branch text starts at column 0 after stripping "* " or "  " and trailing
# spaces/ellipsis. We need the original branch — re-extract from the row.
DISPLAY="${PICKED%$'\t'*}"
PATH_HINT="${PICKED##*$'\t'}"
if [ -n "$PATH_HINT" ]; then
  echo "$PATH_HINT"
  exit 0
fi

# No pre-existing worktree — derive branch from display column.
# Strip leading "* " or "  ", then strip trailing padding/ellipsis.
NAME_FIELD="${DISPLAY:0:50}"            # first 50 chars (the branch column)
NAME_FIELD="${NAME_FIELD#"${NAME_FIELD%%[![:space:]]*}"}"  # ltrim
NAME_FIELD="${NAME_FIELD%"${NAME_FIELD##*[![:space:]]}"}"  # rtrim
NAME_FIELD="${NAME_FIELD#\* }"          # drop current-branch marker if present
if [[ "$NAME_FIELD" == *"…" ]]; then
  echo "branch name was truncated in display; cannot resolve. (this is a wt-picker.sh bug)" >&2
  exit 1
fi
resolve_target "$NAME_FIELD"
```

The truncation guard means a branch name >49 chars would be unrecoverable. If you hit that in practice, a follow-up is to stash the un-truncated branch as a *second* hidden column. For now: explicit error, not silent corruption.

- [ ] **Step 2: Smoke-test interactively**

Run:
```bash
cd /home/zknowles/repos/BrandCrowd.Net
~/.claude/scripts/wt-picker.sh --no-pr
```

Expected: fzf opens, branches listed newest-first with `●` marker on rows that have worktrees, `* ` marker on current branch. Arrow down, press Enter on a row with a `●` — script prints that worktree's path and exits 0.

Press Esc — script exits 130, no stdout.

- [ ] **Step 3: Verify automated tests still pass**

Run: `bash ~/.claude/scripts/wt-picker.test.sh`
Expected: all 13 tests still pass.

---

## Task 17: Add `wt` shell function

**Files:**
- Modify: `~/.bash_aliases`

- [ ] **Step 1: Inspect current `~/.bash_aliases`**

Run: `cat ~/.bash_aliases 2>/dev/null || echo "(file does not exist)"`

If the file doesn't exist, create it with the content from Step 2. If it does, append the function.

- [ ] **Step 2: Append the `wt` function**

Run:
```bash
cat >> ~/.bash_aliases <<'EOF'

# wt — interactive worktree picker (see ~/.claude/scripts/wt-picker.sh).
wt() {
  local target
  target=$(~/.claude/scripts/wt-picker.sh "$@") || return $?
  cd "$target"
}
EOF
```

- [ ] **Step 3: Reload the shell and smoke-test**

Run in a fresh terminal (or `source ~/.bash_aliases`):
```bash
cd /home/zknowles/repos/BrandCrowd.Net
wt --no-pr
```

Expected: fzf opens. Arrow down, press Enter on any row — terminal `cd`s into either the existing worktree or a freshly-created one.

Run `pwd` — confirm you're in the target dir.

- [ ] **Step 4: Esc-cancel test**

Run `wt --no-pr`, press Esc. Confirm `pwd` is unchanged (no cd happened).

---

## Task 18: End-to-end smoke test in BrandCrowd.Net

**Files:** none — manual verification.

- [ ] **Step 1: Pick a branch that already has a worktree**

```bash
cd /home/zknowles/repos/BrandCrowd.Net
wt --no-pr
# Arrow onto a row with a ● marker (one of your existing worktrees).
# Press Enter.
pwd
```
Expected: `pwd` matches the worktree's existing path (from `git worktree list`).

- [ ] **Step 2: Pick a branch that does NOT have a worktree**

Find one first:
```bash
cd /home/zknowles/repos/BrandCrowd.Net
git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads/ \
  | while read b; do
      if ! git worktree list --porcelain | grep -q "branch refs/heads/$b\$"; then
        echo "$b"; break
      fi
    done
# Pick whatever branch name that prints.
```

Now run `wt --no-pr`, arrow onto that branch (no `●` marker), press Enter.

Expected:
- Terminal `cd`s into `.worktrees/<slash-flattened-name>`.
- `git worktree list` now shows the new worktree.
- `.claude/settings.local.json` exists as a symlink in the new dir (verify with `ls -la .claude/settings.local.json`).

- [ ] **Step 3: Pick the current branch**

Run `wt --no-pr`, arrow onto the row with the `* ` marker, press Enter.
Expected: `pwd` is the primary repo root (`/home/zknowles/repos/BrandCrowd.Net`).

- [ ] **Step 4: Run with PR data (default mode)**

```bash
cd /home/zknowles/repos/BrandCrowd.Net
wt
```
Expected: ~1-2s pause for `gh` call, then fzf opens with PR cells populated (`#13286 Open`, `Merged`, etc.).

- [ ] **Step 5: Outside any git repo**

```bash
cd /tmp
wt
```
Expected: stderr says "not inside a git repo", function returns 1, no cd.

---

## Spec coverage check

| Spec section / requirement | Covered by |
|---|---|
| Goal: arrow-select branch, cd or create+cd | Tasks 16, 17, 18 |
| Non-goal: destructive ops | Not implemented — explicitly out of scope |
| Architecture: thin function + thick script | Tasks 1, 17 |
| Two new files + one edit | Tasks 1, 2 (new), 17 (edit) |
| Branch enumeration newest-first | Task 12 |
| Worktree map authoritative | Task 6 |
| Single `gh` call, soft-fail | Task 14 |
| Row composition fixed-width display + hidden path | Task 15 |
| fzf flags (`--with-nth`, `--nth`, `--layout=reverse`) | Task 16 |
| Slash-flatten naming rule | Task 8 |
| Resolve table — all 6 states | Tasks 6, 7, 8, 9 (states 1-4 and "fzf cancel" via Task 16's `\|\| exit $?`) |
| Symlink propagation via `.setup/shared/symlink-settings.sh` | Task 10 |
| `fzf` required, `jq` required, `gh` soft | Tasks 4, 14 |
| `--no-pr`, `--no-color`, `--pick-by-branch`, `-h/--help` flags | Tasks 3, 4 (deps), 6 (test seam), 11 |
| Test scenarios 1-7 from spec | Tasks 6, 7, 8, 9, 10, 11, 4 |
| Test scenario 8 (manual smoke) | Task 18 |
| Phase 2 seam (`"$@"` passthrough in function) | Task 17 |

No gaps found.
