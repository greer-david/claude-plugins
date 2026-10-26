#!/bin/bash
# PostToolUse recorder for roundup runs: logs result size of every Microsoft 365 call.
run=${WEEKLY_ROUNDUP_RUN:-}
[ -n "$run" ] || exit 0
state=~/.local/state/weekly-roundup/$run
mkdir -p "$state"
jq -c --arg ts "$(date -u +%FT%TZ)" \
  '{ts:$ts, phase:"post", tool:.tool_name, bytes:(.tool_response|tostring|length), error:((.tool_response|tostring) as $r | ($r|test("\"(isError|is_error)\":true|\\b(401|403|404|429|5[0-9][0-9])\\b.{0,40}(Forbidden|Unauthorized|error|Error)")))}' >>"$state/calls.jsonl"
exit 0
