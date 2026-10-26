#!/bin/bash
# Self-test for hooks/guard.sh. Run: tests/guard-test.sh   (exit 0 = all passed)
cd "$(dirname "$0")/.." || exit 1
g=hooks/guard.sh; M=mcp__claude_ai_Microsoft_365__; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME_REAL=$HOME
cat >"$tmp/config.json" <<'J'
{"budgets":{"outlook_email_search":2,"default":1},"max_window_days":8}
J
# expect NAME EXPECTED INPUT [ENV...]  EXPECTED: allow | deny | ask | block (exit 2)
expect() {
  local name=$1 want=$2 in=$3; shift 3
  out=$(printf '%s' "$in" | env "$@" bash "$g" 2>/dev/null); rc=$?
  if [ $rc -eq 2 ]; then got=block
  elif [ -z "$out" ]; then got=allow
  else got=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"); fi
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: want $want, got $got"; fail=1; fi
}
win='"afterDateTime":"2026-10-18","beforeDateTime":"2026-10-24T23:59"'
R=(HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/config.json" WEEKLY_ROUNDUP_RUN=t1)

expect "M365 read, outside a run"         allow "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{}}" HOME="$tmp"
expect "M365 send_mail"                    deny  "{\"tool_name\":\"${M}outlook_send_mail\"}" HOME="$tmp"
expect "M365 unknown new tool"             deny  "{\"tool_name\":\"${M}brand_new_tool\"}" HOME="$tmp"
expect "Jira comment"                      ask   '{"tool_name":"mcp__atlassian__addCommentToJiraIssue"}' HOME="$tmp"
expect "Atlassian executeWrite"            ask   '{"tool_name":"mcp__claude_ai_Atlassian_MCP__executeWrite"}' HOME="$tmp"
expect "Jira read"                         allow '{"tool_name":"mcp__atlassian__getJiraIssue"}' HOME="$tmp"
expect "other MCP tool"                    allow '{"tool_name":"mcp__clerk__clerk-resume"}' HOME="$tmp"
expect "run: search without dates"         deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"query\":\"*\"}}" "${R[@]}"
expect "run: natural-language dates"       deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"last week\",\"beforeDateTime\":\"today\"}}" "${R[@]}"
expect "run: 30-day window"                deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"2026-09-20\",\"beforeDateTime\":\"2026-10-20\"}}" "${R[@]}"
expect "run: in budget 1/2"                allow "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{$win}}" "${R[@]}"
expect "run: in budget 2/2"                allow "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{$win}}" "${R[@]}"
expect "run: over budget"                  deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{$win}}" "${R[@]}"
expect "run: default budget"               allow "{\"tool_name\":\"${M}get_me\"}" "${R[@]}"
expect "fail closed: missing config"       deny  "{\"tool_name\":\"${M}get_me\"}" HOME="$tmp" WEEKLY_ROUNDUP_CONFIG=/nonexistent WEEKLY_ROUNDUP_RUN=t2
expect "fail closed: garbage input"        block "not json Microsoft_365__x" HOME="$tmp"
# no jq on PATH: a bin dir with only the basics
mkdir -p "$tmp/bin"; for b in bash cat dirname env; do ln -sf "$(command -v $b)" "$tmp/bin/$b"; done
expect "fail closed: no jq, M365"          block "{\"tool_name\":\"${M}outlook_email_search\"}" PATH="$tmp/bin" HOME="$tmp"
expect "fail closed: no jq, Jira write"    block '{"tool_name":"mcp__atlassian__addCommentToJiraIssue"}' PATH="$tmp/bin" HOME="$tmp"
expect "no jq, other tool still allowed"   allow '{"tool_name":"mcp__clerk__clerk-resume"}' PATH="$tmp/bin" HOME="$tmp"
exit $fail
