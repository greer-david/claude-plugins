#!/bin/bash
# Sweep stats for a roundup run, built only from the hook record (not from the model).
# Usage: run-stats.sh [RUN_ID]   (default: $WEEKLY_ROUNDUP_RUN, else the latest run)
here=$(cd "$(dirname "$0")" && pwd)
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
