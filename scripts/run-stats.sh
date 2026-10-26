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
echo "| M365 tool | calls allowed | budget | denied | result KB | budget hit |"
echo "|---|---|---|---|---|---|"
jq -rs --argjson b "$(jq '.budgets' <<<"$cfg")" '
  group_by(.tool|sub(".*__";""))[] as $g
  | ($g[0].tool|sub(".*__";"")) as $t
  | ($b[$t] // $b.default) as $bud
  | ([$g[]|select(.phase=="pre" and .decision=="allow")]|length) as $ok
  | ([$g[]|select(.phase=="pre" and .decision=="deny")]|length) as $no
  | ([$g[]|select(.phase=="post")|.bytes]|add // 0) as $by
  | "| \($t) | \($ok) | \($bud) | \($no) | \(($by/1024*10|floor)/10) | \(if $ok>=$bud then "yes" else "no" end) |"' "$f"
echo
deny=$(jq -r 'select(.decision=="deny") | "- \(.tool|sub(".*__";"")): \(.reason)"' "$f" | sort | uniq -c)
[ -n "$deny" ] && { echo "Denied calls:"; echo "$deny"; }
