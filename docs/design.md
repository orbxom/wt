# `wt` — interactive worktree picker

**Status:** Design approved (2026-05-11)
**Owner:** Zach Knowles
**Implementation target:** `~/.claude/scripts/wt-picker.sh` + `~/.bash_aliases` function

## Goal

Replace the manual workflow of `cd .worktrees/ && ls && cd <name>` with a single command, `wt`, that:

1. Lists every local branch in the current repo, sorted newest-commit-first.
2. Shows worktree presence and PR status alongside each branch.
3. Lets the user arrow-select a row and press Enter.
4. `cd`s into the existing worktree if one exists, or creates one and `cd`s into that.

Phase 2 (out of scope for this spec, but the design must leave a clean seam): auto-invoke `claude` after the `cd`.

## Non-goals

- Destructive operations (delete branch, remove worktree). Handled by `cleanup-branch.sh`.
- Remote branch operations. Local branches only.
- Multi-repo selection. Operates on the current repo only (resolved via `git rev-parse`).
- Concurrency safety. One `wt` invocation at a time.

## Architecture

Two new files, one edit:

| File | Purpose |
|---|---|
| `~/.claude/scripts/wt-picker.sh` | The whole picker — branch enumeration, fzf invocation, worktree resolve/create. Prints absolute target path to stdout, exits 0 on success. |
| `~/.claude/scripts/wt-picker.test.sh` | Bash test harness. Drives `wt-picker.sh --pick-by-branch <name>` in throwaway repos. |
| `~/.bash_aliases` (edit) | Append a 5-line `wt` shell function that captures the script's stdout and `cd`s into it. |

### The shell function

```bash
wt() {
  local target
  target=$(~/.claude/scripts/wt-picker.sh "$@") || return $?
  cd "$target"
}
```

`"$@"` passthrough is the Phase 2 seam — future flags flow without touching the function.

### The script — high-level flow

1. **Resolve roots.** `REPO_ROOT=$(git rev-parse --show-toplevel)`, `PRIMARY_ROOT=$(dirname $(git rev-parse --path-format=absolute --git-common-dir))`. Same idiom as `branch-survey.sh`. Survives running from inside a worktree.
2. **Enumerate branches** with `git for-each-ref --sort=-committerdate --format='%(refname:short)|%(committerdate:relative)' refs/heads/`.
3. **Build worktree map** from `git worktree list --porcelain` → associative array `branch → absolute_path`. Authoritative; never guess paths from branch names (existing worktree directory names are inconsistent).
4. **Build PR map** from a single `gh pr list --state all --limit 200 --json number,state,isDraft,headRefName` call, parsed with `jq`. Skipped under `--no-pr` or if `gh` is missing/unauthenticated.
5. **Compose rows** — for each branch, format a fixed-width display column followed by a tab-separated hidden machine column containing the resolved worktree path (empty if none).
6. **Invoke fzf** with `--with-nth=1 --nth=1 --delimiter=$'\t' --ansi --layout=reverse --height=80%`. Display column visible; hidden path travels through fzf untouched. Input is already newest-first from `for-each-ref --sort=-committerdate`, so `--layout=reverse` lands the cursor on the newest row without needing `--tac`.
7. **Resolve the picked row**:
   - Hidden path non-empty → echo it, exit 0.
   - Hidden path empty → compute `$REPO_ROOT/.worktrees/$(echo "$branch" | tr '/' '-')`, `git worktree add`, run symlink helper, echo path, exit 0.

## Data flow

```
git for-each-ref ──┐
git worktree list ─┼─► row composer ──► fzf ──► resolver ──► stdout
gh pr list ────────┘                                    │
                                                        └─► (if needed) git worktree add
                                                                       └─► .setup/shared/symlink-settings.sh
```

## Row format

Display column (single pre-formatted string, fzf shows this):

```
<branch padded to 50, truncated with …>  <age padded to 14>  <WT marker, 3 chars>  <PR cell padded to 16>
```

Hidden column (tab-separated, fzf carries it but doesn't show):

```
\t<absolute-worktree-path-or-empty>
```

Total visible width: ~83 chars. PR cell colored via ANSI (green=Open, yellow=Draft, dim=Merged/Closed) when `[[ -t 2 ]]` and `NO_COLOR` is unset.

### Sort & cursor

- `git for-each-ref --sort=-committerdate` returns newest-first.
- `fzf --layout=reverse` shows results top-down; cursor lands on the first input row (the newest).
- Current branch (primary worktree's `HEAD`) is rendered with a leading dim `*` glyph **inside** the 50-char branch column — the branch name pads to 48 chars when the glyph is present, so column alignment is preserved across rows.

## Worktree naming rule

Branch name → directory name via `tr '/' '-'`:

| Branch | Target directory |
|---|---|
| `gt-10142` | `.worktrees/gt-10142` |
| `feat/gt-9395/use-stripe-foo` | `.worktrees/feat-gt-9395-use-stripe-foo` |
| `chore/foo` | `.worktrees/chore-foo` |

Pre-existing inconsistent directory names (e.g., manually flattened differently in the past) are not renamed; the worktree map handles them via `git worktree list`, not by guessing.

## Resolve table

| State | Detection | Action |
|---|---|---|
| Branch already has a worktree (incl. primary) | Worktree map has entry | `echo "$path"`, exit 0 |
| No worktree, target path free | Map empty AND `[ ! -e "$target" ]` | `git worktree add "$target" "$branch"`, run symlink helper, `echo "$target"`, exit 0 |
| No worktree, target path occupied by non-worktree dir | Map empty AND `[ -e "$target" ]` | stderr: "target path exists but isn't a worktree", exit 1 |
| `git worktree add` fails | Non-zero exit from git | forward git's stderr, exit 1 |
| User cancels (Esc/Ctrl-C) | fzf exit 130 | exit 130, no stdout |
| Empty branch list | fzf exit 1 with no input | stderr: "no branches", exit 1 |

## Symlink propagation

After a successful `git worktree add`, the script calls:

```bash
"$PRIMARY_ROOT/.setup/shared/symlink-settings.sh" --target "$target"
```

This is the same script invoked by the existing `PostToolUse:EnterWorktree` hook in `.claude/settings.json` — keeps worktrees created by `wt` consistent with worktrees created via Claude Code.

Guarded with `[ -x ... ]`: if the script doesn't exist (other repos, future moves), the call is skipped silently. Failures within the script are logged to stderr but do not block stdout / exit 0 — the worktree is usable without the symlink.

## Dependencies

| Tool | Required? | Failure mode |
|---|---|---|
| `git` (≥ 2.5 for worktrees) | Yes | Assume present. |
| `fzf` | Yes | Detected at startup; missing → stderr `install fzf: sudo apt install fzf`, exit 1. |
| `jq` | Yes | Same handling as `branch-survey.sh`. |
| `gh` | Soft | Missing or unauthenticated → skip PR column (renders as `—`), warn once to stderr, continue. |

## CLI flags

| Flag | Effect |
|---|---|
| `--no-pr` | Skip the `gh` call; PR column is `—` for all rows. ~1-2s faster startup. |
| `--no-color` | Force-disable ANSI in PR column. |
| `--pick-by-branch <name>` | Skip fzf entirely; treat `<name>` as the user's selection. Test-only seam. |
| `-h`, `--help` | Print usage to stdout, exit 0. |

## Testing

`~/.claude/scripts/wt-picker.test.sh` runs each scenario in a fresh `mktemp -d` repo. Plain bash + small `assert_*` helpers, no bats dependency (consistent with `branch-survey.sh` / `cleanup-branch.sh`).

Scenarios:

| # | Setup | Expected |
|---|---|---|
| 1 | Branch `foo` checked out in primary repo | stdout = primary repo path, exit 0, no new worktree |
| 2 | Branch `foo` with pre-existing `.worktrees/foo` worktree | stdout = that path, exit 0, no new worktree, no symlink call |
| 3 | Branch `feat/bar/baz`, no worktree | stdout = `<repo>/.worktrees/feat-bar-baz`, worktree exists after run |
| 4 | Branch `foo/bar` + `mkdir .worktrees/foo-bar` (non-worktree dir) | exit 1, stderr mentions "target path exists but isn't a worktree", no clobber |
| 5 | `PATH=/empty` (no fzf) | exit 1, stderr mentions fzf install |
| 6 | `--no-pr` flag with no `gh` available | exit 0, PR column = `—` |
| 7 | Repo without `.setup/shared/symlink-settings.sh` | exit 0, worktree created, no symlink, no warning spam |
| 8 | Manual smoke test (not automated) | Run `wt` in BrandCrowd.Net, pick a branch with no worktree, confirm shell `cd`s into a new `.worktrees/<flat>` and `git worktree list` shows it. |

Cancellation (scenario 9) is documented as a manual smoke test — fzf's Esc behavior isn't worth automating.

## Out of scope for Phase 1

- `wt -c` auto-launching `claude` after `cd` — Phase 2. The script's `"$@"` passthrough and the function's `return $?` already accommodate this; only ~6 lines of additions across both files.
- Filtering merged-and-shipped branches out of the list. Branch-cleanup is a separate workflow.
- Multi-select. Single selection only.
- Search across all repos. Current repo only.

## Open questions

None — design fully approved across all 5 sections.
