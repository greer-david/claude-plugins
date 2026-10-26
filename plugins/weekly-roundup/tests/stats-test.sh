#!/bin/bash
# Self-test for hooks/record.sh + scripts/run-stats.sh unread-page detection.
cd "$(dirname "$0")/.." || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fail=0
M=mcp__claude_ai_Microsoft_365__
export HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/c.json"
echo '{"log_dir":"/tmp/x","rules_file":"/tmp/r.md"}' >"$tmp/c.json"
rec() { WEEKLY_ROUNDUP_RUN=$1 bash hooks/record.sh <<<"$2"; }
page() { # run tool input-json response-text [isError]
  rec "$1" "$(jq -nc --arg t "$M$2" --argjson i "$3" --arg txt "$4" --argjson e "${5:-false}" \
    '{tool_name:$t, tool_input:$i, tool_response:{content:[{type:"text",text:$txt}], isError:$e}}')"; }
check() { # name run want-substring-or-NONE
  out=$(bash scripts/run-stats.sh "$2")
  if [ "$3" = NONE ]; then grep -q "never fetched" <<<"$out" && { echo "FAIL $1"; echo "$out"; fail=1; } || echo "ok   $1"
  else grep -q "$3" <<<"$out" && echo "ok   $1" || { echo "FAIL $1"; echo "$out"; fail=1; }; fi; }
q='{"afterDateTime":"2026-10-19","beforeDateTime":"2026-10-20"'
page a outlook_email_search "$q,\"offset\":0}" '[{"id":1},{"nextOffset":25}]'
page a outlook_email_search "$q,\"offset\":25}" '[{"id":2}]'
check "offset paging completed" a NONE
page b teams_list_chats '{}' '[{"id":1},{"nextCursor":"abc"}]'
check "cursor page never fetched" b "teams_list_chats: 1 page never fetched"
page c teams_list_chats '{}' '[{"id":1},{"nextCursor":"abc"}]'
page c teams_list_chats '{"cursor":"abc"}' '[{"id":2}]'
check "cursor page fetched" c NONE
page d outlook_email_search "$q,\"offset\":0}" '[{"id":1},{"nextOffset":null}]'
check "nextOffset null is not another page" d NONE
page e outlook_email_search "$q,\"offset\":0}" '[{"id":1},{"nextOffset":25}]'
page e outlook_email_search "$q,\"offset\":25}" 'Error 502' true
check "failed fetch doesn't count" e "outlook_email_search: 1 page never fetched"
page f outlook_email_search "$q,\"offset\":50}" '[{"id":1}]'
page f outlook_email_search "$q,\"offset\":0}" '[{"id":1},{"nextOffset":25}]'
check "earlier call doesn't count" f "outlook_email_search: 1 page never fetched"
page g outlook_email_search "$q,\"offset\":0}" 'mentions nextOffset in prose'
check "field name in prose isn't a page" g NONE
# Atlassian results are recorded under their own key, kept out of the M365 table, and counted in the total.
rec s "$(jq -nc '{tool_name:"mcp__atlassian__searchJiraIssuesUsingJql", tool_input:{}, tool_response:{content:[{type:"text",text:"x"}]}}')"
page s outlook_email_search "$q,\"offset\":0}" '[{"id":1}]'
rec s "$(jq -nc '{tool_name:"mcp__clerk__clerk-resume", tool_input:{}, tool_response:"y"}')"
out=$(bash scripts/run-stats.sh s)
grep -q "searchjira\|searchJira" <<<"$out" && { echo "FAIL Atlassian kept out of the M365 table"; echo "$out"; fail=1; } || echo "ok   Atlassian kept out of the M365 table"
grep -qE "Results read this run: .* KB of 1024 KB ceiling \\(M365 [0-9.]+ KB, Atlassian [0-9.]+ KB\\)" <<<"$out" && [ "$(jq -s '[.[] | select(.key == "atlassian:searchjiraissuesusingjql") | .bytes] | .[0] > 0' "$HOME/.local/state/weekly-roundup/s/calls.jsonl")" = true ] && echo "ok   total KB line with Atlassian" || { echo "FAIL total KB line"; echo "$out"; fail=1; }
[ "$(grep -c . "$HOME/.local/state/weekly-roundup/s/calls.jsonl")" = 2 ] && echo "ok   unguarded MCP tools aren't recorded" || { echo "FAIL unguarded tool recorded"; fail=1; }
exit $fail
