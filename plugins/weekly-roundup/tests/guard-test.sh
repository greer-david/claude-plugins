#!/bin/bash
# Self-test for hooks/guard.sh. Run: tests/guard-test.sh   (exit 0 = all passed)
cd "$(dirname "$0")/.." || exit 1
g=hooks/guard.sh; M=mcp__claude_ai_Microsoft_365__; A=mcp__atlassian__; fail=0
tmp=$(mktemp -d); trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
cfgbase='{"log_dir":"/tmp/x","rules_file":"/tmp/r.md","budgets":{"outlook_email_search":2,"get_me":3,"default":1},"max_window_days":8}'
echo "$cfgbase" >"$tmp/config.json"
jq '.max_window_days="unlimited"' <<<"$cfgbase" >"$tmp/bad.json"

# expect NAME WANT INPUT [ENV...]   WANT: allow (no output, exit 0) | deny | ask | block (exit 2)
run_guard() { printf '%s' "$1" | env "${@:2}" bash "$g" 2>/dev/null; }
expect() {
  local name=$1 want=$2 in=$3; shift 3
  out=$(run_guard "$in" "$@"); rc=$?
  if [ $rc -eq 2 ]; then got=block
  elif [ $rc -ne 0 ]; then got="exit $rc"
  elif [ -z "$out" ]; then got=allow
  else got=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null || echo "bad output"); fi
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: want $want, got $got"; fail=1; fi
}
win='"afterDateTime":"2026-10-18","beforeDateTime":"2026-10-24T23:59"'
H=(HOME="$tmp/home")
R=(HOME="$tmp/home" WEEKLY_ROUNDUP_CONFIG="$tmp/config.json")

echo "-- classification"
expect "M365 read outside a run"              allow "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{}}" "${H[@]}"
expect "M365 send_mail"                       deny  "{\"tool_name\":\"${M}outlook_send_mail\"}" "${H[@]}"
expect "M365 unknown new tool"                deny  "{\"tool_name\":\"${M}brand_new_tool\"}" "${H[@]}"
expect "M365 lowercase server name"           deny  '{"tool_name":"mcp__microsoft_365__outlook_send_mail"}' "${H[@]}"
expect "M365 other server prefix"             deny  '{"tool_name":"mcp__my-m365__outlook_send_mail"}' "${H[@]}"
expect "M365 name ending in an allowed name"  deny  "{\"tool_name\":\"${M}outlook_send_mail__get_me\"}" "${H[@]}"
expect "M365 JSON-escaped name"               deny  '{"tool_name":"mcp__claude_ai_Microsoft_365__outlook_send_mail"}' "${H[@]}"
expect "Jira comment"                         ask   "{\"tool_name\":\"${A}addCommentToJiraIssue\"}" "${H[@]}"
expect "Atlassian executeWrite"               ask   '{"tool_name":"mcp__claude_ai_Atlassian_MCP__executeWrite"}' "${H[@]}"
expect "Atlassian executeDestructive"         ask   '{"tool_name":"mcp__claude_ai_Atlassian_MCP__executeDestructive"}' "${H[@]}"
expect "Atlassian unlisted write (delete)"    ask   "{\"tool_name\":\"${A}deleteJiraIssue\"}" "${H[@]}"
expect "Atlassian attachment upload"          ask   '{"tool_name":"mcp__claude_ai_Atlassian_Rovo_2__addAttachmentToJiraIssue"}' "${H[@]}"
expect "Atlassian read"                       allow "{\"tool_name\":\"${A}getJiraIssue\"}" "${H[@]}"
expect "Atlassian discover / executeRead"     allow '{"tool_name":"mcp__claude_ai_Atlassian_MCP__executeRead"}' "${H[@]}"
expect "other MCP tool"                       allow '{"tool_name":"mcp__clerk__clerk-resume"}' "${H[@]}"

echo "-- parsing (fail closed)"
expect "garbage input"                        block 'not json Microsoft_365__x' "${H[@]}"
expect "valid object then garbage"            block "{\"tool_name\":\"${M}get_me\"} trailing" "${H[@]}"
expect "two objects"                          block "{\"tool_name\":\"${M}get_me\"}{\"tool_name\":\"x\"}" "${H[@]}"
expect "tool_name not a string"               block '{"tool_name":["mcp__x__y"]}' "${H[@]}"
mkdir -p "$tmp/bin"; for b in bash cat dirname env; do ln -sf "$(command -v $b)" "$tmp/bin/$b"; done
expect "no jq: M365 blocked"                  block "{\"tool_name\":\"${M}get_me\"}" PATH="$tmp/bin" "${H[@]}"
expect "no jq: escaped name blocked"          block '{"tool_name":"mcp__claude_ai_Microsoft_365__x"}' PATH="$tmp/bin" "${H[@]}"
expect "no jq: any MCP call blocked"          block '{"tool_name":"mcp__clerk__clerk-resume"}' PATH="$tmp/bin" "${H[@]}"

echo "-- roundup run"
expect "search without dates"                 deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"query\":\"*\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "natural-language dates"               deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"last week\",\"beforeDateTime\":\"today\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "malformed date suffix"                deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"2026-10-18junk\",\"beforeDateTime\":\"2026-10-20\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "8 days 23 hours (max 8)"              deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"2026-10-10T00:00:00Z\",\"beforeDateTime\":\"2026-10-18T23:00:00Z\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "offset times, 1 day"                  allow "{\"tool_name\":\"${M}chat_message_search\",\"tool_input\":{\"afterDateTime\":\"2026-10-18T00:00:00-05:00\",\"beforeDateTime\":\"2026-10-19T00:00:00-05:00\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "folder search needs dates too"        deny  "{\"tool_name\":\"${M}sharepoint_folder_search\",\"tool_input\":{\"query\":\"x\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "in budget 1/2"                        allow "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{$win}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "in budget 2/2 via other prefix"       allow "{\"tool_name\":\"mcp__microsoft_365__outlook_email_search\",\"tool_input\":{$win}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "over budget (shared across prefixes)" deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{$win}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "invalid config type blocks"           deny  "{\"tool_name\":\"${M}get_me\"}" HOME="$tmp/home" WEEKLY_ROUNDUP_CONFIG="$tmp/bad.json" WEEKLY_ROUNDUP_RUN=r2
expect "missing config blocks"                deny  "{\"tool_name\":\"${M}get_me\"}" HOME="$tmp/home" WEEKLY_ROUNDUP_CONFIG=/nonexistent WEEKLY_ROUNDUP_RUN=r3
printf 'not json\n' >"$tmp/home/.local/state/weekly-roundup/r1/calls.jsonl.tmp" 2>/dev/null
mkdir -p "$tmp/home/.local/state/weekly-roundup/r4"; printf 'garbage\n' >"$tmp/home/.local/state/weekly-roundup/r4/calls.jsonl"
expect "corrupt call record blocks"           deny  "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r4
mkdir -p "$tmp/ro/.local/state/weekly-roundup"; chmod a-w "$tmp/ro/.local/state/weekly-roundup"
expect "unwritable record: M365 blocked"      block "{\"tool_name\":\"${M}get_me\"}" HOME="$tmp/ro" WEEKLY_ROUNDUP_CONFIG="$tmp/config.json" WEEKLY_ROUNDUP_RUN=r5
expect "unwritable record: Jira write blocked" block "{\"tool_name\":\"${A}addCommentToJiraIssue\"}" HOME="$tmp/ro" WEEKLY_ROUNDUP_RUN=r5

echo "-- parallel budget (get_me budget 3, 12 at once)"
for i in $(seq 1 12); do (run_guard "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=par >"$tmp/par.$i"; echo $? >"$tmp/par.$i.rc") & done; wait
allowed=0; for i in $(seq 1 12); do [ "$(cat "$tmp/par.$i.rc")" = 0 ] && [ ! -s "$tmp/par.$i" ] && allowed=$((allowed+1)); done
if [ "$allowed" -eq 3 ]; then echo "ok   exactly 3 of 12 parallel calls allowed"; else echo "FAIL parallel: $allowed of 12 allowed (want 3)"; fail=1; fi

exit $fail
