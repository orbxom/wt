# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single user-facing command, `wt`, with two modes. Default mode lists local git branches in the current repo and lets the user fzf-pick one; selecting a branch `cd`s into its worktree (creating one under `.worktrees/<flat-name>` if it doesn't exist yet). Cleanup mode (`wt --clean` or `wt -c`) lets the user multi-select existing worktrees to delete in one pass.

## Commands

```bash
bash wt-picker.test.sh                          # run the test suite (~13 tests, throwaway repos in mktemp)
bash wt-picker.sh --help                        # CLI usage
bash wt-picker.sh --pick-by-branch <name>       # non-interactive seam: bypass fzf, treat <name> as the picked branch
```

There is no build step, no linter, no package manager. Just bash.

Running a single test: tests are plain `test_*` shell functions in `wt-picker.test.sh`. The runner (`run_all_tests`) discovers them via `declare -F | grep ^test_`. To run one in isolation, source the helpers and call the function directly, or temporarily comment out the others — there is no `--filter` flag.

## Architecture

Four files form a pipeline:

```
wt.bash  ──sources──►  wt() shell function
                          │
                          ├─ if $1 in (-c, --clean, --cleanup): ──►  wt-cleaner.sh
                          │                                            (prints path; cleans worktrees)
                          │
                          └─ else: ──────────────────────────────►  wt-picker.sh
                                                                       (prints path; picks/creates worktree)
                                                                            │
                                                                            ▼
                                                                       cd $target
```

- `wt.bash` is sourced from `~/.bashrc` / `~/.zshrc`. It auto-detects bash vs zsh to resolve its own directory (`BASH_SOURCE` vs `(%):-%N`), then defines `wt()` to invoke the sibling `wt-picker.sh` and `cd` into whatever path it prints.
- `wt-picker.sh` does everything else. The function exists *only* because a child process can't change the parent shell's `cwd`.

### Invariants enforced by `wt-picker.sh`

These are load-bearing; don't break them without updating the tests:

1. **`PRIMARY_ROOT` anchors new worktrees.** Resolved via `git rev-parse --path-format=absolute --git-common-dir` then `dirname`, so running `wt` from inside an existing worktree still creates new worktrees as siblings under the primary repo's `.worktrees/`, never nested inside the current worktree. Covered by `test_pick_new_branch_from_inside_worktree_anchors_at_primary`.
2. **Worktree map is authoritative.** Branch→path lookup comes from `git worktree list --porcelain`. The script never guesses an existing worktree's path from its branch name — pre-existing inconsistently-named worktree directories are reused as-is. Only *new* worktrees follow the flat naming rule (slashes → hyphens).
3. **Target-path conflicts fail loudly.** If `.worktrees/<flat>` exists but isn't a registered worktree, the script exits 1 rather than clobbering. Covered by `test_pick_new_branch_refuses_when_target_occupied`.
4. **Symlink helper is opt-in.** After `git worktree add`, if `$PRIMARY_ROOT/.setup/shared/symlink-settings.sh` exists and is executable, it's invoked with `--target <new-worktree>`. Absent → silent skip (no warning). Failure inside the helper → stderr warning but stdout / exit 0 are still good (the worktree itself is usable).
5. **Exit codes are part of the contract.** `0` success, `130` user cancel (fzf Esc/Ctrl-C — propagated so the shell function returns cleanly), `1` error, `2` unknown flag. Tests assert these.
6. **Bash 4+ required** because of associative arrays (`WORKTREE_MAP`, `PR_MAP`). The version check at the top of `wt-picker.sh` prints platform-specific install hints. macOS's stock `/bin/bash` is 3.2; users need `brew install bash` and it must be first on `PATH`.

### Display column ↔ branch name recovery

The fzf row layout is `<display-column>\t<hidden-path>`. The display column is fixed-width: branch padded/truncated to 50, then age, WT marker, PR cell. When the picked row has a non-empty hidden path, the script just echoes it. When the hidden path is empty (no worktree yet), the branch name is *recovered* from the first 50 chars of the display column by trimming the `*` marker and surrounding whitespace. This recovery refuses truncated names (ending in `…`) — see the limitation about 49-character branch names in the README.

### `--pick-by-branch <name>` is the test seam

Tests never touch fzf or `gh`. They drive the resolver directly via this flag, which short-circuits `build_pr_map`, `compose_rows`, and the fzf invocation. When changing the picker, prefer extending the seam over adding a second one.

### Invariants enforced by `wt-cleaner.sh`

1. **Primary worktree is never deleted.** It's excluded from enumeration up front.
2. **Branch refs are never deleted.** Only worktree directories. `git worktree remove --force --force` is the only deletion call.
3. **Self-delete redirects to primary.** If `$PWD` is one of the picked paths, the cleaner cds itself to `PRIMARY_ROOT` before running git worktree remove, and prints `PRIMARY_ROOT` on stdout so the parent shell lands somewhere real. Covered by `test_picking_current_worktree_redirects_to_primary`.
4. **One row's failure does not abort the batch.** Each `git worktree remove` is per-iteration try/catch; failures are recorded for the final summary. Exit 0 if any row succeeded, exit 1 only if every row failed.
5. **Test seam flags (`--yes`, `--pick-branches`, `--debug-status`) are clearly labeled in `--help`.** They are not part of the user-facing CLI and not documented in `README.md`.

## When making changes

The README's "How it works" section mirrors the architecture above. Keep them in sync if you change the pipeline.
