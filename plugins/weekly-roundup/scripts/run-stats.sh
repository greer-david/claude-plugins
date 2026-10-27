#!/bin/bash
# Sweep stats for a roundup run, built only from the hook record (not from the model).
# Usage: run-stats.sh [RUN_ID]   (default: $WEEKLY_ROUNDUP_RUN, else the latest run)
here=$(cd "$(dirname "$0")" && pwd)
. "$here/tz.sh"
base=~/.local/state/weekly-roundup
run=${1:-${WEEKLY_ROUNDUP_RUN:-$(ls -1 "$base" 2>/dev/null | sort | tail -1)}}
f=$base/$run/calls.jsonl
[ -f "$f" ] || { echo "No M365 calls recorded for run '$run'."; exit 0; }
cfg=$("$here/config-json")
echo "Run $run"
echo
echo "| M365 tool | calls allowed | budget | denied | errors | result KB | budget hit |"
echo "|---|---|---|---|---|---|---|"
jq -rs --argjson b "$(jq '.budgets' <<<"$cfg")" '
  map(select(.key // "" | startswith("m365:"))) | group_by(.tool|sub(".*__";""))[] as $g
  | ($g[0].tool|sub(".*__";"")) as $t
  | ($b[$t] // $b.default) as $bud
  | ([$g[]|select(.phase=="pre" and .decision=="allow")]|length) as $ok
  | ([$g[]|select(.phase=="pre" and .decision=="deny")]|length) as $no
  | ([$g[]|select(.phase=="post" and .error==true)]|length) as $er
  | ([$g[]|select(.phase=="post")|.bytes]|add // 0) as $by
  | "| \($t) | \($ok) | \($bud) | \($no) | \($er) | \(($by/1024*10|floor)/10) | \(if $ok>=$bud then "yes" else "no" end) |"' "$f"
jq -rs --argjson cap "$(jq '.budgets.total_kb' <<<"$cfg")" '
  [.[] | select(.phase == "post")] as $p
  | def kb($k): [$p[] | select(.key | startswith($k)) | .bytes // 0] | add // 0 | . / 1024 * 10 | floor / 10;
  "\nResults read this run: \(kb("")) KB of \($cap) KB ceiling (M365 \(kb("m365:")) KB, Atlassian \(kb("atlassian:")) KB)\(if kb("") >= $cap then ", ceiling hit" else "" end)."' "$f"
echo
unread=$(jq -rs '
  # A page is unread when a successful result returned a continuation token and no later
  # successful call with the same query fetched exactly that token (as offset or cursor).
  def q: (.input // {}) | del(.offset, .cursor, .limit) | tostring;
  [.[] | select(.phase == "post")] as $p
  | [ range(0; $p | length) as $i | $p[$i] | select(.next != null and (.error | not))
      | select(any($p[$i+1:][]; .tool == $p[$i].tool and (q == ($p[$i] | q)) and (.error | not)
                   and ((.input.offset // null) == $p[$i].next or (.input.cursor // null) == $p[$i].next)) | not)
      | .tool ]
  | group_by(.)[] | "- \(.[0] | sub(".*__"; "")): \(length) page\(if length == 1 then "" else "s" end) never fetched"' "$f")
[ -n "$unread" ] && { echo "Unread pages (results said more exist; never fetched):"; echo "$unread"; echo; }
# Omitted days: the skill's fixed plan searches email and chat once per local day of the window.
# A day (clipped to the window) counts only if successful searches together cover all of it.
# Only the plan's broad searches count (query "*" or none, no other narrowing field such as folderName or sender); a time without a zone
# is UTC, as in the guard.
win="$base/$run/window.json"
if [ -f "$win" ] && mid=$(midnights $(day_range "$(jq -r '.window_start | fromdateiso8601 - 86400 | strftime("%Y-%m-%d")' "$win")" \
                                    "$(jq -r '.window_end | fromdateiso8601 + 86400 | strftime("%Y-%m-%d")' "$win")")); then
  omitted=$(jq -rs --slurpfile w "$win" --argjson mid "$mid" '
    def inst: (capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2})(?<t>T[0-9]{2}:[0-9]{2}(:[0-9]{2})?)?([.][0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})?$") // null)
        | if . == null then null
          else ((.b + ((.t // "T00:00:00") | if length == 6 then . + ":00" else . end)) | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
               - (if .z == null then  0 elif .z == "Z" then 0
                  else (.z[0:1] + "1" | tonumber) * ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) end) end;
      def day: . as $t | [($t - 86400, $t, $t + 86400) | strftime("%Y-%m-%d") | select($mid[.] != null and $mid[.] <= $t)] | max;
      def midnight: $mid[.];
      def next: strptime("%Y-%m-%d") | mktime + 86400 | strftime("%Y-%m-%d") | midnight;
    ($w[0].window_start | fromdateiso8601) as $ws | ($w[0].window_end | fromdateiso8601) as $we
    | [($ws | day) | recurse(next as $n | if $n < $we then $n | day else empty end) | {d: ., s: ([midnight, $ws] | max), e: ([next, $we] | min)}
       | select(.s < .e)] as $days
    | [.[] | select(.phase == "post" and (.error | not))] as $p
    | ["outlook_email_search", "chat_message_search"][] as $t
    | ([$p[] | select(.key == "m365:" + $t and (.input.query // "*") == "*"
                 and ((.input // {}) | keys - ["query", "afterDateTime", "beforeDateTime", "offset", "cursor", "limit"] == [])) | [(.input.afterDateTime // "" | tostring | inst), (.input.beforeDateTime // "" | tostring | inst)]
        | select(.[0] != null and .[1] != null)] | sort) as $iv
    | [$days[] | . as $d | (reduce $iv[] as $i ($d.s; if $i[0] <= . and $i[1] > . then $i[1] else . end)) as $reach
       | select($reach < $d.e) | $d.d] as $miss
    | select($miss | length > 0)
    | "- \($t): \($miss | join(", "))"' "$f")
  [ -n "$omitted" ] && { echo "Omitted days (no successful search covers them; the plan searches every day):"; echo "$omitted"; echo; }
elif [ -f "$win" ]; then
  echo "Omitted days: not checked (can't read the local UTC offset from date)."; echo
fi
dropped=$(jq -rs '
  [.[] | select(.phase == "post") | .dropped[]?] | group_by([.who, .reason])
  | map({who: .[0].who, reason: .[0].reason, count: (map(.count) | add)}) | sort_by(-.count)[]
  | "| \(.who) | \(.count) | \(.reason) |"' "$f")
unf=$(jq -s '[.[] | select(.phase == "post" and .filter == "unfiltered")] | length' "$f")
if [ -n "$dropped" ] || [ "$unf" -gt 0 ]; then
  echo "Dropped by the noise filter (from the hook record):"
  echo
  echo "| sender or chat | count | reason |"
  echo "|---|---|---|"
  [ -n "$dropped" ] && echo "$dropped"
  echo
  [ "$unf" -gt 0 ] && { echo "Incomplete: $unf result(s) couldn't be parsed and passed through unfiltered."; echo; }
fi
deny=$(jq -r 'select(.decision=="deny") | "- \(.tool|sub(".*__";"")): \(.reason)"' "$f" | sort | uniq -c)
[ -n "$deny" ] && { echo "Denied calls:"; echo "$deny"; }
exit 0
