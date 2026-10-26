#!/bin/bash
# Fix a roundup run's window, once. Usage: start-run.sh [--week YYYY-MM-DD | --since DATE-OR-ISO]
# The first call in a run records run_at (now, UTC) and the window in
# ~/.local/state/weekly-roundup/$WEEKLY_ROUNDUP_RUN/window.json; later calls print the saved one.
#   default:  previous log's run_at -> now. No previous log, or one older than gap_days: this week's start.
#   --since:  that date (local midnight) or ISO instant -> now.
#   --week:   the whole week containing that date (backfill, calibration); ends now if the week isn't over.
# Prints the window as JSON. Without WEEKLY_ROUNDUP_RUN it prints but saves nothing.
set -u
here=$(cd "$(dirname "$0")" && pwd)
mode=default; arg=
case "${1:-}" in
  --week|--since) mode=${1#--}; arg=${2:-}; [ -n "$arg" ] || { echo "start-run: $1 needs a value" >&2; exit 1; } ;;
  "") ;;
  *) echo "usage: start-run.sh [--week YYYY-MM-DD | --since DATE-OR-ISO]" >&2; exit 1 ;;
esac
run=${WEEKLY_ROUNDUP_RUN:-}
state="$HOME/.local/state/weekly-roundup/$run"
if [ -n "$run" ] && [ -f "$state/window.json" ]; then
  [ "$mode" = default ] || echo "start-run: this run's window is already fixed; ignoring --$mode." >&2
  cat "$state/window.json"; exit 0
fi
cfg=$("$here/config-json") || { echo "start-run: config failed to load." >&2; exit 1; }
log_dir=$(jq -r '.log_dir' <<<"$cfg")

# Where each existing weekly log's window ended: frontmatter window_end, or for older logs the
# earlier of run_at and the end of week_end (a backfill or calibration run is stamped after its week).
logs=$(for f in "$log_dir"/*.md; do
  [ -f "$f" ] || continue
  awk 'NR==1 && !/^---/{exit} NR>1 && /^---/{exit} /^(run_at|window_end|week_end):/{k=$1; sub(":","",k); v=$0; sub(/^[a-z_]+:[[:space:]]*/,"",v); gsub(/["\047]/,"",v); print k "\t" v}' "$f" |
    jq -Rn --arg f "$(basename "$f")" '[inputs | split("\t") | {(.[0]): .[1]}] | add + {file: $f}'
done 2>/dev/null | jq -s 'map(select(.run_at or .window_end))')

out=$(jq -n --arg mode "$mode" --arg arg "$arg" --argjson logs "${logs:-[]}" \
  --arg wsd "$(jq -r '.week_start_day' <<<"$cfg")" --argjson gap "$(jq '.gap_days // 14' <<<"$cfg")" \
  --arg now "${WEEKLY_ROUNDUP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" --arg off "$(date +%z)" '
  def iso: strftime("%Y-%m-%dT%H:%M:%SZ");
  # Local midnight of YYYY-MM-DD as epoch seconds, using the current UTC offset (+HHMM).
  (($off[0:1] + "1" | tonumber) * (($off[1:3] | tonumber) * 3600 + ($off[3:5] | tonumber) * 60)) as $offs
  | def midnight: strptime("%Y-%m-%d") | mktime - $offs;
    def instant: if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then midnight
                 else . as $in | (capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})(?<s>:[0-9]{2})?([.][0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})?$") // error("not an ISO date or instant: \($in)"))
                   | ((.b + (.s // ":00")) | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
                     - (if .z == null then $offs elif .z == "Z" then 0
                        else (.z[0:1] + "1" | tonumber) * ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) end) end;
    # Round-trip check: strptime accepts impossible dates (Feb 30), so reject any that change.
    def valid: . as $s | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}") and ($s[0:10] | strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) != $s[0:10] then error("bad date \($s)") else . end;
    def localday: . + $offs | strftime("%Y-%m-%d");
    def weekstart: (strptime("%Y-%m-%d") | mktime) as $t
      | (["sunday","monday","tuesday","wednesday","thursday","friday","saturday"] | index($wsd)) as $w
      | ($t | gmtime | .[6]) as $dow | $t - 86400 * ((($dow - $w) % 7 + 7) % 7) | strftime("%Y-%m-%d");
  ($now | instant) as $n
  | ($logs | map(.file as $f | try (if .window_end then .window_end | instant
        elif .week_end and .run_at then [(.run_at | instant), (.week_end | midnight) + 86400] | min
        else .run_at | instant end) catch error("\($f): run_at or window_end isn'"'"'t a valid ISO date or instant")) | max) as $p
  | ($p // 0 | iso) as $prev
  | ($n | localday | weekstart) as $this_week
  | if $mode == "week" then
      ($arg | valid | weekstart) as $ws | ($ws | midnight) as $s | ([$s + 7 * 86400, $n] | min) as $e
      | {week_start: $ws, window_start: ($s | iso), window_end: ($e | iso), reason: "week \($ws)"}
    elif $mode == "since" then
      ($arg | valid | instant) as $s
      | {week_start: $this_week, window_start: ($s | iso), window_end: ($n | iso), reason: "--since \($arg)"}
    elif $p == null then
      {week_start: $this_week, window_start: ($this_week | midnight | iso), window_end: ($n | iso),
       reason: "no previous log; from this week'"'"'s start"}
    else
      if $n - $p > $gap * 86400 then
          {week_start: $this_week, window_start: ($this_week | midnight | iso), window_end: ($n | iso),
           reason: "previous log'"'"'s window ended \($prev), over \($gap) days old; from this week'"'"'s start",
           gap: {from: ($p | iso), to: ($this_week | midnight | iso)}}
        elif $p >= $n then error("the previous log'"'"'s window ends in the future (\($prev))")
        else {week_start: $this_week, window_start: ($p | iso), window_end: ($n | iso), reason: "from the end of the previous log'"'"'s window \($prev)"}
        end
    end
  | {run_at: ($n | iso)} + .
  | if (.window_start | fromdateiso8601) >= (.window_end | fromdateiso8601) then error("empty window: \(.window_start) to \(.window_end)") else . end
') && [ -n "$out" ] || { echo "start-run: couldn't fix the window." >&2; exit 1; }
if [ -n "$run" ]; then
  mkdir -p "$state" && printf '%s\n' "$out" >"$state/window.json" || { echo "start-run: can't write $state/window.json" >&2; exit 1; }
else
  echo "start-run: WEEKLY_ROUNDUP_RUN isn't set, so this window isn't saved and the guard won't enforce it." >&2
fi
printf '%s\n' "$out"
