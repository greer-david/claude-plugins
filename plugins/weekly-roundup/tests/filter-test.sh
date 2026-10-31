#!/bin/bash
# Self-test for the noise filter in hooks/record.sh and the Dropped table in scripts/run-stats.sh.
# Results use the connector's shape: a list of text blocks, one JSON item each, paging info last.
cd "$(dirname "$0")/.." || exit 1
. scripts/platform.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fail=0
M=mcp__claude_ai_Microsoft_365__
export HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/c.json"
cat >"$tmp/c.json" <<'J'
{"log_dir":"/tmp/x","rules_file":"/tmp/r.md",
 "m365":{"noise_senders":["noreply","Atlassian.net"],"mute_chats":["19:muted@thread.v2"],"alert_patterns":["refresh failed"]}}
J
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2"; fail=1; }
# call run tool items-json -> prints hook stdout; items become text blocks, plus a paging block
call() { WEEKLY_ROUNDUP_RUN=$1 bash hooks/record.sh <<<"$(jq -nc --arg t "$M$2" --argjson it "$3" \
  '{tool_name:$t, tool_input:{query:"*"}, agent_id:"a1",
    tool_response: ([$it[] | {type:"text", text: tojson}] + [{type:"text", text: ({moreResults:false, nextOffset:null, note:""} | tojson)}])}')"; }
kept() { jq -c '[.hookSpecificOutput.updatedMCPToolOutput[].text | fromjson | .id // "page"]' <<<"$1"; }

out=$(call a outlook_email_search '[
  {"id":1,"sender":"person@corp.com","subject":"Question"},
  {"id":2,"sender":"noreply@corp.com","subject":"Digest"},
  {"id":3,"sender":"NoReply@corp.com","subject":"Weekly digest"},
  {"id":4,"sender":"jira@x.atlassian.net","subject":"Dataset refresh failed"}]')
[ "$(kept "$out")" = '[1,4,"page"]' ] && ok "email: noise dropped, alert kept, paging kept" || bad "email filter" "$out"

out=$(call b chat_message_search '[
  {"id":1,"chatId":"19:muted@thread.v2","from":{"email":"person@corp.com"}},
  {"id":2,"chatId":"19:other@thread.v2","from":{"email":"person@corp.com"}},
  {"id":3,"chatId":"19:other@thread.v2","from":{"email":"bot@atlassian.net"}}]')
[ "$(kept "$out")" = '[2,"page"]' ] && ok "chat: muted chat and noise sender dropped" || bad "chat filter" "$out"

out=$(call c outlook_email_search '[{"id":1,"sender":"person@corp.com","subject":"Hi"}]')
[ -z "$out" ] && ok "nothing dropped: output untouched" || bad "untouched output" "$out"

out=$(WEEKLY_ROUNDUP_RUN=d bash hooks/record.sh <<<"$(jq -nc --arg t "${M}outlook_email_search" \
  '{tool_name:$t, tool_input:{}, tool_response:[{type:"text",text:"not json"},{type:"text",text:"{\"id\":1,\"sender\":\"noreply@x\"}"}]}')")
[ -z "$out" ] && ok "unparseable result passes through" || bad "unparseable passthrough" "$out"
grep -q "Incomplete: 1 result" <<<"$(bash scripts/run-stats.sh d)" && ok "unfiltered flagged in stats" || bad "unfiltered flag" "$(bash scripts/run-stats.sh d)"

out=$(WEEKLY_ROUNDUP_RUN=e bash hooks/record.sh <<<"$(jq -nc --arg t "${M}outlook_email_search" \
  '{tool_name:$t, tool_input:{}, tool_response:{content:[{type:"text",text:"Error 502"}], isError:true}}')")
[ -z "$out" ] && ! grep -q Incomplete <<<"$(bash scripts/run-stats.sh e)" && ok "error result: untouched, not flagged unfiltered" || bad "error result"

out=$(call f outlook_calendar_search '[{"id":1,"sender":"noreply@corp.com"}]')
[ -z "$out" ] && ok "other tools aren't filtered" || bad "calendar untouched" "$out"

stats=$(bash scripts/run-stats.sh a)
grep -q "| noreply@corp.com | 1 | noise sender |" <<<"$stats" && grep -q "| NoReply@corp.com | 1 | noise sender |" <<<"$stats" \
  && ok "Dropped table from the record" || bad "Dropped table" "$stats"
grep -q "| 19:muted@thread.v2 | 1 | muted chat |" <<<"$(bash scripts/run-stats.sh b)" && ok "muted chat in Dropped table" || bad "muted chat row"
[ "$(jq -s '[.[] | select(.phase=="post")][0].agent' "$tmp/.local/state/weekly-roundup/a/calls.jsonl")" = '"a1"' ] && ok "agent recorded" || bad "agent recorded"

out=$(WEEKLY_ROUNDUP_RUN=g bash hooks/record.sh <<<"{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{},\"tool_response\":[{\"type\":\"text\",\"text\":\"{\\\"id\\\":1,\\\"sender\\\":\\\"noreply@x\\\"}\"}]}")
[ -n "$out" ] && ok "filters with no paging block" || bad "no paging block" "$out"

echo '{"log_dir":"/tmp/x","rules_file":"/tmp/r.md","m365":{"mute_chats":["Team Standup"]}}' >"$tmp/c.json"
bash scripts/config-json >/dev/null 2>&1 && bad "chat name rejected in mute_chats" || ok "chat name rejected in mute_chats"
out=$(call h outlook_email_search '[{"id":1,"sender":"noreply@corp.com"}]')
[ -z "$out" ] && grep -q '"filter":"no-config"' "$tmp/.local/state/weekly-roundup/h/calls.jsonl" && ok "invalid config: pass through, recorded" || bad "invalid config" "$out"
exit $fail
