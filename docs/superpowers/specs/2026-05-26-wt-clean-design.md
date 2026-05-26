# `wt --clean` design

Date: 2026-05-26
Branch: `feat/wt-clean`

## Goal

Add a cleanup mode to the `wt` tool that lets a developer multi-select
worktrees in `.worktrees/` and delete them in a single pass, reclaiming
disk space. Existing `wt` (the branch picker) is unchanged.

## User-facing CLI

```
wt              # existing: pick a branch, cd into its worktree
wt --clean      # new: pick worktrees to delete
wt -c           # alias for --clean
wt --cleanup    # alias for --clean
```

No other user-facing flags. Both `--help` paths still work:
`wt --help` shows picker help; `wt --clean --help` shows cleaner help.

## Architecture

Adds one new runtime script (`wt-cleaner.sh`) and its test file
(`wt-cleaner.test.sh`). The original three-script runtime pipeline
(`wt.bash` → `wt-picker.sh`) gains a sibling branch:

```
wt.bash  ──sources──►  wt() shell function
                          │
                          ├─ if $1 in (-c, --clean, --cleanup):
                          │     "$_WT_CLEANER" "$@"  ──prints target path──┐
                          │                                                 │
                          └─ else:                                          │
                                "$_WT_PICKER"  "$@"  ──prints target path──┤
                                                                            ▼
                                                                       cd "$target"
```

Both scripts share the same parent-shell contract: print a path on stdout,
the `wt()` function `cd`s into it. The cleaner prints either `$PRIMARY_ROOT`
(if the cwd was just deleted) or the original `$PWD` (if it wasn't).

### Why a separate script

`wt-picker.sh` stays focused. The cleanup path has its own
concerns — multi-select, status detection, size accounting,
confirmation prompt, partial-failure reporting — that don't belong in
the picker. About ten lines overlap between the two scripts (bash 4
check, `need fzf`/`need jq`, `PRIMARY_ROOT` resolution); these are
duplicated rather than factored into a third shared file. If a third
script ever lands, extract then.

## `wt-cleaner.sh` behavior

### Eligible worktrees

The picker lists every worktree under `git worktree list --porcelain`,
**except** the primary worktree (cannot be removed). The current worktree
**is** listed; if the user selects it, the cleaner cds itself to
`PRIMARY_ROOT` before running `git worktree remove`, and prints
`PRIMARY_ROOT` so the parent shell follows it.

Sort: newest committerdate **last** (oldest at top — that's what you're
most likely cleaning).

### Columns

```
BRANCH                                          AGE             STATUS              PR
gt-1234-old-investigation                       3 months ago    ↑2 +5               #4471 MERGED
feat/bar/baz                                    2 weeks ago     clean               #4502 OPEN
chore/typo-fix                                  4 days ago      clean               -
```

- `BRANCH` — 50-char fixed width, same `* ` current-branch marker as picker.
- `AGE` — relative committerdate, 14 chars.
- `STATUS` — composed of:
  - `↑N` — N commits ahead of upstream (only if an upstream is set).
  - `↓N` — N commits behind upstream.
  - `+M` — M files reported by `git status --porcelain` (any working-tree change).
  - Empty / `clean` — no upstream divergence and a clean working tree.
- `PR` — same column as the picker (`#1234 OPEN`, `#1234 MERGED`, `#1234 Draft`, `-`).

A row with any `↑`, `↓`, or `+` is treated as **dirty**; the cleaner will use
`git worktree remove --force` for it.

### Selection

`fzf -m` (multi-select via Tab). Header:

```
BRANCH                                          AGE             STATUS              PR
Tab select · Enter confirm · Esc cancel
```

Esc / Ctrl-C → exit 130, nothing deleted.

### Confirmation

After selection, the cleaner runs `du -sb` over the picked paths,
sums to bytes, and human-formats to MB/GB. Prompt to stderr:

```
Delete 4 worktrees (412 MB)? [Y/n]
```

- Empty input → proceed (default Yes).
- `y` / `Y` / `yes` → proceed.
- Anything else → exit 130, nothing deleted.

### Deletion

1. If `$PWD` is one of the picked paths, the cleaner `cd`s itself to
   `PRIMARY_ROOT` so its own cwd doesn't block the remove.
2. For each picked path, in order:
   - `git worktree remove --force --force <path>` — first `--force` covers
     dirty trees (uncommitted changes, untracked files); the second
     `--force` breaks locks. If the user selected a row, they want it gone.
   - On success: track the path and the byte count we measured earlier.
   - On failure: print `failed: <branch> — <git's stderr>` to stderr and
     continue to the next path.
3. Branch refs are never deleted. A branch whose worktree was removed
   stays in `git branch -a` and can be re-`wt`'d to recreate the worktree.

### Output

- **stdout**: a single line — the path the parent shell should `cd` to.
  - `PRIMARY_ROOT` if the original `$PWD` was one of the deleted paths.
  - Original `$PWD` otherwise (no-op `cd` from the user's perspective).
- **stderr**: prompt, per-failure lines, and the final summary.

### Final summary

```
freed 412 MB across 4 worktrees                          # all succeeded
freed 312 MB across 3 worktrees · 1 failed (see above)   # partial
nothing freed · 4 failed                                  # total failure
no worktrees to clean                                     # nothing eligible
```

### Exit codes

- `0` — at least one worktree was removed.
- `130` — user cancelled (Esc in fzf, "n" at the prompt, or non-y answer).
- `1` — nothing eligible to clean, or all deletions failed.
- `2` — bad flag combination.

## Test seam

Two flags are added for testing only. They appear in `--help` under a
clearly-labeled "Test seam" section so they're not confused with normal
options. They are not documented in `README.md`.

```
Test seam (not for normal use):
  --pick-branches <a,b,c>  Skip fzf; treat <a>,<b>,<c> as the selected rows.
  --yes                    Skip the size/confirm prompt.
```

Each test-seam branch in `--pick-branches` must resolve to an eligible
worktree (per the rules above) or the cleaner exits 1 with a clear
message before deleting anything.

## `wt.bash` changes

```bash
_WT_CLEANER="$_WT_DIR/wt-cleaner.sh"

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
```

A cleaner exit of 130 (cancel) returns 130 without changing the shell's cwd,
matching how picker cancel already works.

## Tests (`wt-cleaner.test.sh`)

Mirrors `wt-picker.test.sh` — same `new_repo`, `assert_*` helpers, same
`run_all_tests` discovery loop. Helpers duplicated rather than shared.

Coverage:

- `test_help_exits_zero_and_prints_usage` — `--help` works.
- `test_unknown_flag_exits_two` — `--bogus` is rejected.
- `test_outside_git_repo_exits_one` — clear error outside a repo.
- `test_nothing_to_clean_exits_one` — repo with only the primary worktree.
- `test_deletes_selected_worktree` — single-pick, clean tree, succeeds.
- `test_deletes_multiple_selected_worktrees` — multi-pick, all clean.
- `test_force_removes_dirty_worktree` — picked row has uncommitted changes;
  cleaner uses `--force`, succeeds.
- `test_partial_failure_continues_and_reports` — two picks, one is removed
  out-of-band before the cleaner gets to it (simulated failure); summary
  reports 1 freed, 1 failed; exit 0.
- `test_all_failures_exit_one` — every pick fails; nothing freed; exit 1.
- `test_picking_current_worktree_redirects_to_primary` — picker invoked
  from inside worktree X with X selected; stdout = primary root; X is gone.
- `test_picking_non_current_worktree_keeps_pwd` — picker invoked from
  inside worktree X with worktree Y selected; stdout = X's path; X survives.
- `test_primary_excluded_from_selection` — `--pick-branches main` (where
  main is the primary's branch) errors out with a clear message.
- `test_unknown_branch_in_pick_branches_errors` — `--pick-branches no-such`
  exits 1 with a clear message, deletes nothing.

The existing `wt-picker.test.sh` is **not** modified by this change.

## README + CLAUDE.md updates

- `README.md` gets a short "Cleaning up worktrees" section that documents
  `wt --clean`, the multi-select / confirm flow, and the fact that branches
  are not deleted.
- `CLAUDE.md` gets:
  - The architecture diagram updated to four files.
  - A new invariant section for `wt-cleaner.sh` covering:
    1. The cleaner never removes the primary worktree.
    2. The cleaner never deletes branches.
    3. If `$PWD` is picked for deletion, the cleaner cds itself to primary
       first and prints primary on stdout.
    4. Failures are isolated: one failed remove never aborts the batch.
    5. Test seam flags `--pick-branches` and `--yes` are off the normal
       user path.

## Out of scope (will not be added)

- Branch deletion (`git branch -D`) — explicit decision, keeps cleanup
  reversible.
- Per-row disk-size column — sized via post-confirm `du` over selections
  only, not per row in the picker (kept the picker fast).
- `--dry-run` — the confirmation prompt with total-bytes covers the
  preview need.
- `git worktree prune` — `git worktree remove` already handles its own
  administrative cleanup.
- A backup / trash directory — removed worktrees can be recreated via
  `wt <branch>` since the branch ref is still there.
- A shared `wt-common.sh` — overlap between picker and cleaner is too
  small to justify; extract if a third script appears.
