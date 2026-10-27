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
# Only the plan's broad searches (query "*" or none, no folderName) count as covering a day.
for r in od3 od4; do mkdir -p "$HOME/.local/state/weekly-roundup/$r"; cp "$HOME/.local/state/weekly-roundup/od/window.json" "$HOME/.local/state/weekly-roundup/$r/"; done
page od3 outlook_email_search '{"afterDateTime":"2026-10-25","beforeDateTime":"2026-10-29","query":"subject:foo"}' '[{"id":1}]'
page od3 chat_message_search '{"afterDateTime":"2026-10-25","beforeDateTime":"2026-10-29","query":"*","folderName":"Inbox"}' '[{"id":1}]'
out=$(TZ=UTC bash scripts/run-stats.sh od3)
grep -q -- "- outlook_email_search: 2026-10-25" <<<"$out" && grep -q -- "- chat_message_search: 2026-10-25" <<<"$out" \
  && echo "ok   restricted searches don't cover days" || { echo "FAIL restricted searches credited"; echo "$out"; fail=1; }
# A time without a zone is UTC, as in the guard, whatever the local zone.
page od4 outlook_email_search '{"afterDateTime":"2026-10-25T00:00:00","beforeDateTime":"2026-10-29T00:00:00","query":"*"}' '[{"id":1}]'
page od4 chat_message_search '{"afterDateTime":"2026-10-25T00:00:00","beforeDateTime":"2026-10-29T00:00:00"}' '[{"id":1}]'
TZ=America/Chicago bash scripts/run-stats.sh od4 | grep -q "Omitted days" && { echo "FAIL zone-less time read as local"; TZ=America/Chicago bash scripts/run-stats.sh od4; fail=1; } || echo "ok   zone-less time is UTC"
# Error text inside a structured result's fields is data, not an error.
rec se "$(jq -nc --arg t "${M}outlook_email_search" '{tool_name:$t, tool_input:{}, tool_response:{items:[{subject:"500 error on prod"}]}}')"
[ "$(jq -s '.[-1].error' "$HOME/.local/state/weekly-roundup/se/calls.jsonl")" = false ] && echo "ok   error words in a structured field aren't an error" || { echo "FAIL structured field read as error"; tail -1 "$HOME/.local/state/weekly-roundup/se/calls.jsonl"; fail=1; }
page se outlook_email_search '{}' 'HTTP 503 Service Unavailable'
[ "$(jq -s '.[-1].error' "$HOME/.local/state/weekly-roundup/se/calls.jsonl")" = true ] && echo "ok   HTTP error text still an error" || { echo "FAIL HTTP text error lost"; fail=1; }
# A sender-filtered search (or any other narrowing field) doesn't cover a day either.
mkdir -p "$HOME/.local/state/weekly-roundup/od5"; cp "$HOME/.local/state/weekly-roundup/od/window.json" "$HOME/.local/state/weekly-roundup/od5/"
page od5 chat_message_search '{"afterDateTime":"2026-10-25","beforeDateTime":"2026-10-29","query":"*","sender":"me@x.com"}' '[{"id":1}]'
TZ=UTC bash scripts/run-stats.sh od5 | grep -q -- "- chat_message_search: 2026-10-25" && echo "ok   sender-filtered search doesn't cover days" || { echo "FAIL sender search credited"; fail=1; }
exit $fail
