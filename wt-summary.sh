#!/usr/bin/env bash
# wt-summary.sh — print a Haiku-generated summary of the most recent Claude Code
# conversation for the current working directory. Silent if no prior conversation
# exists or `claude` isn't on PATH. Never errors — always exits 0 on the silent
# paths so it can be invoked unconditionally after `cd`.
set -u

# Claude encodes the cwd by replacing every non-[a-zA-Z0-9_-] character with `-`.
# That covers `/` *and* `.` (e.g. /home/u/repos/Foo.Bar/.worktrees/x → -home-u-repos-Foo-Bar--worktrees-x).
project_dir="$HOME/.claude/projects/${PWD//[^a-zA-Z0-9_-]/-}"
[ -d "$project_dir" ] || exit 0

latest=$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1)
[ -n "$latest" ] || exit 0

command -v claude >/dev/null 2>&1 || exit 0

extract_messages() {
  jq -r '
    select(.type == "user" or .type == "assistant")
    | select((.isMeta // false) | not)
    | select((.isSidechain // false) | not)
    | (
        if (.message.content | type) == "string" then
          .message.content
        else
          .message.content | map(select(.type == "text") | .text) | join(" ")
        end
      ) as $text
    | select($text != "" and $text != null)
    | "\(.type | ascii_upcase): \($text[0:1500])"
  ' "$1"
}

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wt-summary"
mkdir -p "$cache_dir"
key=$(printf '%s %s' "$latest" "$(stat -c %Y "$latest")" | sha256sum | cut -d' ' -f1)
cache_file="$cache_dir/$key"

if [ -s "$cache_file" ]; then
  cat "$cache_file"
  exit 0
fi

# Extract first; bail out if there's nothing summarizable. This avoids burning a
# Haiku call on JSONLs that are old-schema, empty, or contain only tool-call
# turns (in which case the model has nothing useful to summarize anyway).
messages=$(extract_messages "$latest" | tail -10)
[ -n "$messages" ] || exit 0

# Show a "thinking" indicator on stderr so the user knows we're waiting on Haiku
# rather than hanging. Cache hits skip this (they exit earlier and are instant).
printf '… summarizing prior Claude session\n' >&2

result=$(
  printf '%s\n' "$messages" | timeout 30s claude -p \
    --model haiku \
    --no-session-persistence \
    --output-format text \
    --append-system-prompt 'The user message you receive is a transcript of a prior Claude Code session, each line prefixed "USER:" or "ASSISTANT:" indicating speaker. The user has just returned to that working directory and wants a quick recap to decide whether to resume the session or start fresh. Output exactly 3 short bullets covering: (1) what was being worked on, (2) where the session left off / what was about to happen next, and (3) any unresolved threads, blockers, or open questions. The transcript may be partial or truncated — do not point that out; infer what you can and move on. After the third bullet, stop. Do not add a preamble, a closing question, an offer of further help, or any text whatsoever outside the three bullets.' \
    2>/dev/null
) || true

if [ -n "$result" ]; then
  printf '%s\n' "$result" > "$cache_file"
  printf '%s\n' "$result"
fi
exit 0

