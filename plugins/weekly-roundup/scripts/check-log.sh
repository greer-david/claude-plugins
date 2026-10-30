#!/bin/bash
# Check a weekly log's window frontmatter against what scripts/start-run.sh recorded for this run.
# Usage: check-log.sh LOG   (exit 1 with the problems found)
# Checks: run_at, week_start, the window and dry_run match the run; every "Possibly fell through the cracks"
# bullet ends with a source tag (email <message id> | teams | github | jira | calendar | other), and
# every email one names a message this run opened (read_resource) with the user in To (hooks/record.sh).
# On ok, a real run's window goes into ~/.local/state/weekly-roundup/covered.jsonl (one line per run),
# which start-run.sh reads to find where the next run starts.
set -u
log=${1:?usage: check-log.sh LOG}
win="$HOME/.local/state/weekly-roundup/${WEEKLY_ROUNDUP_RUN:-}/window.json"
[ -n "${WEEKLY_ROUNDUP_RUN:-}" ] && [ -f "$win" ] || { echo "check-log: no window recorded for this run; run scripts/start-run.sh first." >&2; exit 1; }
[ -f "$log" ] || { echo "check-log: no log at $log" >&2; exit 1; }
fm=$(awk 'NR==1 && !/^---/{exit} NR>1 && /^---/{exit} /^(run_at|week_start|window_start|window_end|dry_run):/{k=$1; sub(":","",k); v=$0; sub(/^[a-z_]+:[[:space:]]*/,"",v); gsub(/["\047]/,"",v); print k "\t" v}' "$log" \
     | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')
bad=$(jq -rn --argjson fm "$fm" --slurpfile w "$win" '
  [("run_at", "week_start", "window_start", "window_end") as $k
   | select($fm[$k] != $w[0][$k]) | "\($k): log has \($fm[$k] // "nothing"), run has \($w[0][$k])"]
  + (if ($fm.dry_run == "true") != ($w[0].dry_run // false) then ["dry_run: the log must have dry_run: true exactly when the run is a dry run (start-run.sh --dry-run)"] else [] end) | .[]')
[ -z "$bad" ] || { echo "check-log: $log doesn't match this run. Copy these from scripts/start-run.sh:"; echo "$bad"; exit 1; }
calls="$HOME/.local/state/weekly-roundup/$WEEKLY_ROUNDUP_RUN/calls.jsonl"
reads=$( [ -f "$calls" ] && jq -sc '[.[] | select(.phase == "post" and .mail != null) | .mail]' "$calls" 2>/dev/null || echo '[]')
missed=$(jq -Rrs --argjson reads "${reads:-[]}" '
  split("\n") as $l
  | ($l | index("## Possibly fell through the cracks")) as $s
  | if $s == null then empty else
      ($l[$s + 1:] | (map(test("^## ")) | index(true)) as $e | if $e then .[:$e] else . end)
      | .[] | select(test("^\\s*- ")) | . as $b
      | (capture("· (?<src>email|teams|github|jira|calendar|other)\\b(?<rest>[^·]*)$") // null) as $t
      | if $t == null then "no source tag (end with · email <message id>, · teams, · github, · jira, · calendar or · other): \($b)"
        elif $t.src != "email" then empty
        else ($t.rest | gsub("^\\s+|[\\s)]+$"; "") | sub("^\\(";"")) as $id
          | ([$reads[] | select($id != "" and (.id == $id or .uri == $id))] | first) as $r
          | if $id == "" then "email item without a message id: \($b)"
            elif $r == null then "email \($id) wasn'"'"'t opened in this run (read_resource), so To can'"'"'t be checked: \($b)"
            elif $r.addressed == "unknown" then "set m365.my_addresses in the config so To can be checked: \($b)"
            elif $r.addressed != "to_me" then "the user isn'"'"'t in To on email \($id), so it isn'"'"'t possibly missed (context at most): \($b)"
            else empty end end end' "$log")
[ -z "$missed" ] || { echo "check-log: possibly-missed items in $log fail the rules:"; echo "$missed"; exit 1; }
if [ "$(jq -r '.dry_run // false' "$win")" != true ]; then
  cov="$HOME/.local/state/weekly-roundup/covered.jsonl"
  { [ ! -f "$cov" ] || jq -c --arg r "$WEEKLY_ROUNDUP_RUN" 'select(.run != $r)' "$cov"
    jq -c --arg r "$WEEKLY_ROUNDUP_RUN" --arg log "$log" '{run: $r, log: $log, run_at, week_start, window_start, window_end}' "$win"
  } >"$cov.tmp" && mv "$cov.tmp" "$cov" || { rm -f "$cov.tmp"; echo "check-log: can't record this run's window in $cov" >&2; exit 1; }
fi
echo "check-log: ok"
