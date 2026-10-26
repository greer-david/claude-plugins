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
# Error detection (#5): flags inside JSON text, "error" members, HTTP error text; not item text that mentions an error.
errof() { jq -s '[.[] | select(.phase == "post")] | last | .error' "$HOME/.local/state/weekly-roundup/$1/calls.jsonl"; }
erris() { # name run want(true|false)
  [ "$(errof "$2")" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: want error=$3"; fail=1; }; }
page x1 teams_list_chats '{}' '{"isError":true,"message":"denied"}'; erris "isError inside JSON text" x1 true
page x2 teams_list_chats '{}' '{"error":{"code":429,"message":"throttled"}}'; erris "error member inside JSON text" x2 true
page x3 teams_list_chats '{}' 'HTTP 503 Service Unavailable'; erris "HTTP error text" x3 true
page x4 teams_list_chats '{}' 'Request failed with status 403 Forbidden'; erris "status code in short text" x4 true
page x5 outlook_email_search "$q}" '{"subject":"500 error on prod","summary":"we saw a 500 error"}'; erris "item mentioning an error isn't an error" x5 false
page x6 teams_list_chats '{}' '[{"id":1}]'; erris "plain result isn't an error" x6 false
# One classification for guard and recorder (#3): aliases and odd names are recorded under the guard's key.
rec al "$(jq -nc '{tool_name:"mcp__M365__Teams_List_Chats", tool_input:{}, tool_response:{content:[{type:"text",text:"[]"}]}}')"
rec al "$(jq -nc '{tool_name:"mcp__microsoft_365__a__b", tool_input:{}, tool_response:"x"}')"
[ "$(jq -sr 'map(.key) | join(",")' "$HOME/.local/state/weekly-roundup/al/calls.jsonl")" = "m365:teams_list_chats,m365:__invalid__" ] \
  && echo "ok   recorder keys match the guard's classification" || { echo "FAIL recorder keys"; cat "$HOME/.local/state/weekly-roundup/al/calls.jsonl"; fail=1; }
# Omitted days (#15): every local day of the window needs successful email and chat searches covering it.
mkdir -p "$HOME/.local/state/weekly-roundup/od"
echo '{"run_at":"2026-10-28T12:00:00Z","week_start":"2026-10-25","window_start":"2026-10-25T00:00:00Z","window_end":"2026-10-28T12:00:00Z"}' >"$HOME/.local/state/weekly-roundup/od/window.json"
dq() { echo "{\"afterDateTime\":\"$1\",\"beforeDateTime\":\"$2\",\"offset\":0}"; }
page od outlook_email_search "$(dq 2026-10-25 2026-10-26)" '[{"id":1}]'
page od outlook_email_search "$(dq 2026-10-26T00:00:00Z 2026-10-26T12:00:00Z)" '[{"id":1}]'
page od outlook_email_search "$(dq 2026-10-26T12:00Z 2026-10-27)" '[{"id":1}]'
page od outlook_email_search "$(dq 2026-10-27 2026-10-28)" 'Error 502' true
page od outlook_email_search "$(dq 2026-10-28 2026-10-28T12:00:00Z)" '[{"id":1}]'
page od chat_message_search "$(dq 2026-10-26 2026-10-27)" '[{"id":1}]'
out=$(TZ=UTC bash scripts/run-stats.sh od)
grep -qx -- "- outlook_email_search: 2026-10-27" <<<"$out" && echo "ok   failed day reported, split day covered" || { echo "FAIL omitted email day"; echo "$out"; fail=1; }
grep -qx -- "- chat_message_search: 2026-10-25, 2026-10-27, 2026-10-28" <<<"$out" && echo "ok   unsearched chat days reported" || { echo "FAIL omitted chat days"; echo "$out"; fail=1; }
page od2 outlook_email_search "$(dq 2026-10-25 2026-10-29)" '[{"id":1}]'; page od2 chat_message_search "$(dq 2026-10-24 2026-10-29)" '[{"id":1}]'
cp "$HOME/.local/state/weekly-roundup/od/window.json" "$HOME/.local/state/weekly-roundup/od2/"
TZ=UTC bash scripts/run-stats.sh od2 | grep -q "Omitted days" && { echo "FAIL fully covered window"; fail=1; } || echo "ok   fully covered window: no omitted days"
exit $fail
