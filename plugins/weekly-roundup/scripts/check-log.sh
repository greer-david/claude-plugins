#!/bin/bash
# Check a weekly log's window frontmatter against what scripts/start-run.sh recorded for this run.
# Usage: check-log.sh LOG   (exit 1 with the mismatches if run_at, week_start or the window differ)
set -u
log=${1:?usage: check-log.sh LOG}
win="$HOME/.local/state/weekly-roundup/${WEEKLY_ROUNDUP_RUN:-}/window.json"
[ -n "${WEEKLY_ROUNDUP_RUN:-}" ] && [ -f "$win" ] || { echo "check-log: no window recorded for this run; run scripts/start-run.sh first." >&2; exit 1; }
[ -f "$log" ] || { echo "check-log: no log at $log" >&2; exit 1; }
fm=$(awk 'NR==1 && !/^---/{exit} NR>1 && /^---/{exit} /^(run_at|week_start|window_start|window_end):/{k=$1; sub(":","",k); v=$0; sub(/^[a-z_]+:[[:space:]]*/,"",v); gsub(/["\047]/,"",v); print k "\t" v}' "$log" \
     | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')
bad=$(jq -rn --argjson fm "$fm" --slurpfile w "$win" '
  [("run_at", "week_start", "window_start", "window_end") as $k
   | select($fm[$k] != $w[0][$k]) | "\($k): log has \($fm[$k] // "nothing"), run has \($w[0][$k])"] | .[]')
[ -z "$bad" ] || { echo "check-log: $log doesn't match this run. Copy these from scripts/start-run.sh:"; echo "$bad"; exit 1; }
echo "check-log: ok"
