# wt — interactive worktree picker

`wt` is a single command that lists every local branch in the current git repo, sorted newest-commit-first, and lets you arrow-select one. If a worktree already exists for that branch, your shell `cd`s into it. If not, `wt` creates `.worktrees/<flat-branch-name>` and cds into the new worktree.

```
worktree ›
BRANCH                                              AGE             WT  PR
● = worktree exists  ·  * = current branch  ·  ↑/↓ select  ·  Enter open  ·  Esc cancel
> * prep/typegen-manually-typed-pages               6 minutes ago   ●   #13286 Open
    feat/gt-10150/ai-search-prompt-parity           32 minutes ago  ●   #13201 Draft
    chore/just-status-http-probe                    2 hours ago     ●   —
    develop                                         5 hours ago         —
    feat/typegen-pilot-pages                        6 hours ago     ●   #13180 Merged
    ...
```

Use it for: fast worktree switching when you're juggling several branches at once, without `cd .worktrees/ && ls` plumbing.

## Requirements

| Tool | Required? | Why |
|---|---|---|
| `bash` ≥ 4 | yes | associative arrays |
| `git` ≥ 2.5 | yes | `git worktree` |
| `fzf` | yes | the interactive picker |
| `jq` | yes | parsing `gh` JSON output |
| `gh` | optional | populates the PR column; degrade silently if missing/unauthed |

On Debian/Ubuntu: `sudo apt install fzf jq`. On macOS with Homebrew: `brew install fzf jq`.

## Install

1. Clone this repo somewhere stable (it stays installed where you clone it):

   ```bash
   git clone <repo-url> ~/repos/wt
   ```

2. Source `wt.bash` from your shell init. The function uses `${BASH_SOURCE[0]}` to find `wt-picker.sh` next to it, so wherever you clone it is fine.

   For bash, add to `~/.bashrc` (or `~/.bash_aliases` if you have that pattern):

   ```bash
   source ~/repos/wt/wt.bash
   ```

   For zsh: `wt.bash` is bash-shaped but the `BASH_SOURCE` reference needs adjustment — see the comment at the top of `wt.bash`.

3. Restart your shell (or `source ~/.bashrc`).

4. `cd` into any git repo and run `wt`.

## Usage

```
wt              # full picker, with PR data from gh (~1-2s extra)
wt --no-pr      # skip the gh call; PR column shows '—' for all rows. Faster startup.
wt --no-color   # disable ANSI colors
wt --help       # usage
```

Inside the picker:

| Key | Action |
|---|---|
| `↑` / `↓` | move cursor |
| typing | fuzzy-filters the BRANCH column |
| `Enter` | open the selected branch — cd into existing worktree, or create one and cd |
| `Esc` / `Ctrl-C` | cancel; shell stays put |

## How it works

1. **Enumerate branches.** `git for-each-ref --sort=-committerdate refs/heads/` lists every local branch newest-first.
2. **Build worktree map.** `git worktree list --porcelain` is the authoritative branch→path map. The picker never guesses paths from branch names — existing inconsistent worktree directory names work fine.
3. **Optional PR map.** One `gh pr list --state all --limit 200` call (skipped under `--no-pr`).
4. **Compose rows.** Fixed-width display column for the eye + a hidden tab-delimited path column for fzf to carry through.
5. **fzf.** Interactive selection.
6. **Resolve.** Pre-existing worktree → echo its path. No worktree → compute `<repo>/.worktrees/<branch-with-slashes-replaced-by-hyphens>`, `git worktree add`, then echo.
7. **Symlink propagation.** If `<repo>/.setup/shared/symlink-settings.sh` exists, it's invoked with `--target <new-worktree>` to mirror any per-worktree setup. Skipped silently if absent.
8. **Shell function.** The function captures the script's stdout (the target path) and `cd`s into it.

## Files

| Path | Purpose |
|---|---|
| `wt-picker.sh` | The whole picker. Prints absolute target path on stdout, exits 0 on success, 130 on user cancel, 1 on error. |
| `wt-picker.test.sh` | Bash test harness for the picker. ~13 tests; runnable as `bash wt-picker.test.sh`. |
| `wt.bash` | The shell function. Sources cleanly into bash. |
| `docs/design.md` | The design spec (architecture, resolve table, row format, dependencies). |
| `docs/plan.md` | The implementation plan that built this. Useful as a TDD walkthrough. |

## Running the tests

```bash
bash wt-picker.test.sh
```

The tests use throwaway repos (`mktemp -d`) for isolation. fzf and gh are not exercised — the script is driven via `--pick-by-branch <name>` which bypasses the interactive path. Two tests SKIP gracefully if `fzf` or `jq` is installed in `/usr/bin` or `/bin` (the tests exist mainly to document expected behavior in their absence).

## Worktree naming

Branch `feat/gt-9395/use-stripe-foo` creates a worktree at `.worktrees/feat-gt-9395-use-stripe-foo`. Slashes → hyphens. The script never renames existing worktree directories; pre-existing inconsistently-named worktrees are detected via `git worktree list --porcelain` and reused as-is.

## Limitations

- One repo at a time. `wt` runs against whichever repo `git rev-parse --show-toplevel` finds from your current `pwd`.
- Single selection only. No multi-pick.
- `gh pr list --limit 200` caps PR data at 200 PRs — branches whose PRs are outside that window show `—`. Bump the limit in `wt-picker.sh` if your repo has more.
- Branch names longer than 49 characters are truncated in the picker display, and the script refuses to resolve them rather than guess. If you hit this, the fix is to add a second hidden column carrying the un-truncated name.
- zsh users: `${BASH_SOURCE[0]}` in `wt.bash` needs to be replaced with `${(%):-%N}` to work natively.

## License

MIT — see `LICENSE`.
