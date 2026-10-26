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
st="$tmp/home/.local/state/weekly-roundup"; mkdir -p "$st/r1" "$st/w1"
wj() { printf '{"run_at":"%s","week_start":"2026-10-18","window_start":"%s","window_end":"%s"}\n' "$2" "$1" "$2"; }
wj 2026-10-18T05:00:00Z 2026-10-25T05:00:00Z >"$st/r1/window.json"
wj 2026-10-23T14:00:00Z 2026-10-30T14:00:00Z >"$st/w1/window.json"
search() { echo "{\"tool_name\":\"${M}chat_message_search\",\"tool_input\":{\"afterDateTime\":\"$1\",\"beforeDateTime\":\"$2\"}}"; }
expect "no window for the run"                deny  "$(search 2026-10-18 2026-10-19)" "${R[@]}" WEEKLY_ROUNDUP_RUN=nowin
expect "search inside the window"             allow "$(search 2026-10-26 2026-10-27)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
expect "local day before start (slack)"       allow "$(search 2026-10-23T00:00:00-05:00 2026-10-24T00:00:00-05:00)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
expect "day after end (slack)"                allow "$(search 2026-10-30 2026-10-31)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
expect "search before the window"             deny  "$(search 2026-10-20 2026-10-21)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
expect "search after the window"              deny  "$(search 2026-11-02 2026-11-03)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
printf 'garbage\n' >"$st/w1/window.json"
expect "corrupt window denies"                deny  "$(search 2026-10-26 2026-10-27)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
wj 2026-10-23T14:00:00Z 2026-10-30T14:00:00Z >"$st/w1/window.json"
expect "search without dates"                 deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"query\":\"*\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "natural-language dates"               deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"last week\",\"beforeDateTime\":\"today\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "malformed date suffix"                deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"2026-10-18junk\",\"beforeDateTime\":\"2026-10-20\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "8 days 23 hours (max 8)"              deny  "{\"tool_name\":\"${M}outlook_email_search\",\"tool_input\":{\"afterDateTime\":\"2026-10-10T00:00:00Z\",\"beforeDateTime\":\"2026-10-18T23:00:00Z\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "offset times, 1 day"                  allow "{\"tool_name\":\"${M}chat_message_search\",\"tool_input\":{\"afterDateTime\":\"2026-10-18T00:00:00-05:00\",\"beforeDateTime\":\"2026-10-19T00:00:00-05:00\"}}" "${R[@]}" WEEKLY_ROUNDUP_RUN=r1
expect "Oct 32 is not a date"                 deny  "$(search 2026-10-26 2026-10-32)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
expect "hour 99 is not a time"                deny  "$(search 2026-10-26T99:00:00Z 2026-10-27)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
expect "minute 60 is not a time"              deny  "$(search 2026-10-26T10:60Z 2026-10-27)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
expect "offset +99:99 is not an offset"       deny  "$(search 2026-10-26T10:00:00+99:99 2026-10-27)" "${R[@]}" WEEKLY_ROUNDUP_RUN=w1
mkdir -p "$st/fr"; cp "$st/r1/window.json" "$st/fr/"
expect "fraction kept: 8 days + 0.5 s denied" deny  "$(search 2026-10-17T05:00:00Z 2026-10-25T05:00:00.5Z)" "${R[@]}" WEEKLY_ROUNDUP_RUN=fr
expect "fraction kept: exactly 8 days allowed" allow "$(search 2026-10-17T05:00:00.5Z 2026-10-25T05:00:00.5Z)" "${R[@]}" WEEKLY_ROUNDUP_RUN=fr
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

echo "-- size ceiling (total_kb 2)"
jq '.budgets.total_kb = 2 | .budgets.default = 50' <<<"$cfgbase" >"$tmp/ceil.json"
C=(HOME="$tmp/home" WEEKLY_ROUNDUP_CONFIG="$tmp/ceil.json")
mkdir -p "$st/ce"; wj 2026-10-23T14:00:00Z 2026-10-30T14:00:00Z >"$st/ce/window.json"
expect "under the ceiling: M365 read"         allow "{\"tool_name\":\"${M}teams_list_chats\"}" "${C[@]}" WEEKLY_ROUNDUP_RUN=ce
expect "under the ceiling: Atlassian read"    allow "{\"tool_name\":\"${A}getJiraIssue\"}" "${C[@]}" WEEKLY_ROUNDUP_RUN=ce
printf '{"phase":"post","key":"m365:teams_list_chats","bytes":1500}\n{"phase":"post","key":"atlassian:getjiraissue","bytes":700}\n' >>"$st/ce/calls.jsonl"
expect "over the ceiling: M365 read"          deny  "{\"tool_name\":\"${M}teams_list_chats\"}" "${C[@]}" WEEKLY_ROUNDUP_RUN=ce
expect "over the ceiling: Atlassian read"     deny  "{\"tool_name\":\"${A}getJiraIssue\"}" "${C[@]}" WEEKLY_ROUNDUP_RUN=ce
expect "over the ceiling: get_me exempt"      allow "{\"tool_name\":\"${M}get_me\"}" "${C[@]}" WEEKLY_ROUNDUP_RUN=ce
expect "Atlassian read outside a run"         allow "{\"tool_name\":\"${A}getJiraIssue\"}" "${H[@]}"
expect "Atlassian read, bad config in a run"  deny  "{\"tool_name\":\"${A}getJiraIssue\"}" HOME="$tmp/home" WEEKLY_ROUNDUP_CONFIG="$tmp/bad.json" WEEKLY_ROUNDUP_RUN=ce
jq '.budgets.total_kb = 0' <<<"$cfgbase" >"$tmp/zero.json"
expect "total_kb 0 is invalid config"         deny  "{\"tool_name\":\"${M}get_me\"}" HOME="$tmp/home" WEEKLY_ROUNDUP_CONFIG="$tmp/zero.json" WEEKLY_ROUNDUP_RUN=ce

echo "-- parallel budget (get_me budget 3, 12 at once)"
for i in $(seq 1 12); do (run_guard "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=par >"$tmp/par.$i"; echo $? >"$tmp/par.$i.rc") & done; wait
allowed=0; for i in $(seq 1 12); do [ "$(cat "$tmp/par.$i.rc")" = 0 ] && [ ! -s "$tmp/par.$i" ] && allowed=$((allowed+1)); done
if [ "$allowed" -eq 3 ]; then echo "ok   exactly 3 of 12 parallel calls allowed"; else echo "FAIL parallel: $allowed of 12 allowed (want 3)"; fail=1; fi

echo "-- config validation"
for bad in '"caps":[]' '"budgets":[]' '"transcripts_dir":5' '"clerk_dir":{}' '"m365":[]' '"m365":{"my_addresses":"me@x.com"}' '"budgets":{"default":"3"}'; do
  jq ". + {$bad}" <<<"$cfgbase" >"$tmp/badcfg.json"
  expect "config $bad denies"                 deny  "{\"tool_name\":\"${M}get_me\"}" HOME="$tmp/home" WEEKLY_ROUNDUP_CONFIG="$tmp/badcfg.json" WEEKLY_ROUNDUP_RUN=cf
done

echo "-- run lock"
lk="$st/lk/.run.lock"; mkdir -p "$st/lk"
dead() { bash -c 'echo $$'; }
ln -s "pid.$(dead).1" "$lk"
expect "lock of a dead hook is reclaimed"     allow "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=lk
[ ! -e "$lk" ] && [ ! -L "$lk" ] && echo "ok   lock released after the call" || { echo "FAIL lock left behind"; fail=1; }
ln -s "garbage" "$lk"
expect "malformed lock is reclaimed"          allow "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=lk
sleep 30 & live=$!
ln -s "pid.$live.1" "$lk"
expect "live lock is never taken"             block "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=lk
[ "$(readlink "$lk")" = "pid.$live.1" ] && echo "ok   live lock left in place" || { echo "FAIL live lock removed"; fail=1; }
kill $live 2>/dev/null; wait $live 2>/dev/null; rm -f "$lk"
# A hook killed while reclaiming leaves a reclaim lock naming a dead process: it is recovered too.
ln -s "pid.$(dead).1" "$lk"; ln -s "pid.$(dead)" "$st/lk/.run.lock.reclaim"
expect "dead reclaim lock is recovered"       allow "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=lk
[ ! -L "$st/lk/.run.lock.reclaim" ] && echo "ok   dead reclaim lock removed" || { echo "FAIL reclaim lock left"; fail=1; }
# A dead holder's lock and 12 hooks racing to reclaim it: the budget still holds, so no hook removed a live lock.
ln -s "pid.$(dead).1" "$st/par2/.run.lock" 2>/dev/null || { mkdir -p "$st/par2"; ln -s "pid.$(dead).1" "$st/par2/.run.lock"; }
for i in $(seq 1 12); do (run_guard "{\"tool_name\":\"${M}get_me\"}" "${R[@]}" WEEKLY_ROUNDUP_RUN=par2 >"$tmp/p2.$i"; echo $? >"$tmp/p2.$i.rc") & done; wait
allowed=0; for i in $(seq 1 12); do [ "$(cat "$tmp/p2.$i.rc")" = 0 ] && [ ! -s "$tmp/p2.$i" ] && allowed=$((allowed+1)); done
if [ "$allowed" -eq 3 ]; then echo "ok   racing reclaim of a stale lock: exactly 3 of 12 allowed"; else echo "FAIL racing reclaim: $allowed of 12 allowed (want 3)"; fail=1; fi
[ "$(grep -c '"decision":"allow"' "$st/par2/calls.jsonl")" = 3 ] && echo "ok   racing reclaim: 3 allows recorded" || { echo "FAIL racing reclaim record"; fail=1; }

exit $fail
