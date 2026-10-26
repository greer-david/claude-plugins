#!/bin/bash
# PostToolUse recorder for roundup runs (Microsoft 365 tools): result size, error flag, and the
# continuation token the result returned (nextOffset/nextCursor), if any.
run=${WEEKLY_ROUNDUP_RUN:-}
[ -n "$run" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
state="$HOME/.local/state/weekly-roundup/$run"
mkdir -p "$state" || exit 0
jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  # MCP results often carry JSON inside text content; look inside strings that parse as JSON too.
  (.tool_response) as $r
  | ([$r] + [$r | .. | strings | (try fromjson catch empty)]) as $docs
  | {ts: $ts, phase: "post", tool: .tool_name,
     key: ((.tool_name | ascii_downcase | ltrimstr("mcp__") | split("__")) as $p | "m365:" + ($p[1:] | join("__"))),
     input: .tool_input,
     bytes: ($r | tostring | length),
     error: ([$r | .. | objects | (.isError?, .is_error?)] | any(. == true)),
     next: ([$docs[] | .. | objects | (.nextOffset?, .nextCursor?) | select(. != null and . != "")] | first // null)}
' >>"$state/calls.jsonl" 2>/dev/null
exit 0
