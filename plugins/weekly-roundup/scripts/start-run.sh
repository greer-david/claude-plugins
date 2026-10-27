#!/bin/bash
# Fix a roundup run's window, once. Usage: start-run.sh [--week YYYY-MM-DD | --since DATE-OR-ISO]
# The first call in a run records run_at (now, UTC) and the window in
# ~/.local/state/weekly-roundup/$WEEKLY_ROUNDUP_RUN/window.json; later calls print the saved one.
#   default:  previous log's run_at -> now. No previous log, or one older than gap_days: this week's start.
#   --since:  that date (local midnight) or ISO instant -> now.
#   --week:   the whole week containing that date (backfill, calibration); ends now if the week isn't over.
#   --dry-run: records dry_run: true; logs with dry_run: true never count as the previous run.
# Prints the window as JSON. Without WEEKLY_ROUNDUP_RUN it prints but saves nothing.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/tz.sh"
mode=default; arg=; dry=false
usage="usage: start-run.sh [--week YYYY-MM-DD | --since DATE-OR-ISO] [--dry-run]"
while [ $# -gt 0 ]; do
  case "$1" in
    --week|--since) [ "$mode" = default ] || { echo "$usage" >&2; exit 1; }
                    mode=${1#--}; arg=${2:-}; [ -n "$arg" ] || { echo "start-run: $1 needs a value" >&2; exit 1; }; shift ;;
    --dry-run) dry=true ;;
    *) echo "$usage" >&2; exit 1 ;;
  esac
  shift
done
run=${WEEKLY_ROUNDUP_RUN:-}
state="$HOME/.local/state/weekly-roundup/$run"
if [ -n "$run" ] && [ -f "$state/window.json" ]; then
  [ "$(jq -r '.dry_run // false' "$state/window.json")" = "$dry" ] \
    || { echo "start-run: this run's window is already fixed as a $( [ "$dry" = true ] && echo real || echo dry) run; start a new run (new WEEKLY_ROUNDUP_RUN) for a $( [ "$dry" = true ] && echo dry || echo real) run." >&2; exit 1; }
  [ "$mode" = default ] || echo "start-run: this run's window is already fixed; ignoring --$mode." >&2
  cat "$state/window.json"; exit 0
fi
# A --since time without a zone is local time at that instant (date knows the offset; jq doesn't).
[ "$mode" = since ] && { arg=$(local_to_utc "$arg") || { echo "start-run: can't read the local UTC offset from date." >&2; exit 1; }; }
cfg=$("$here/config-json") || { echo "start-run: config failed to load." >&2; exit 1; }
log_dir=$(jq -r '.log_dir' <<<"$cfg")

# Where each existing weekly log's window ended: frontmatter window_end, or for older logs the
# earlier of run_at and the end of week_end (a backfill or calibration run is stamped after its week).
logs=$(for f in "$log_dir"/*.md; do
  [ -f "$f" ] || continue
  awk 'NR==1 && !/^---/{exit} NR>1 && /^---/{exit} /^(run_at|window_end|week_end|dry_run):/{k=$1; sub(":","",k); v=$0; sub(/^[a-z_]+:[[:space:]]*/,"",v); gsub(/["\047]/,"",v); print k "\t" v}' "$f" |
    jq -Rn --arg f "$(basename "$f")" '[inputs | split("\t") | {(.[0]): .[1]}] | add + {file: $f}'
done 2>/dev/null | jq -s 'map(select((.run_at or .window_end) and .dry_run != "true"))')
now=${WEEKLY_ROUNDUP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
# Local midnight of every day the window rules can touch: around now and the argument (a week either
# side), and around each previous log's dates.
mid=$(midnights $(jq -rn --arg now "$now" --arg arg "$arg" --argjson logs "${logs:-[]}" '
  def near($n): .[0:10] | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | (try (strptime("%Y-%m-%d") | mktime) catch empty) as $t
    | range(-$n; $n + 1) | $t + 86400 * . | strftime("%Y-%m-%d");
  ($now | near(9)), ($arg | near(9)), ($logs[] | (.run_at, .window_end, .week_end) | strings | near(1))')) \
  || { echo "start-run: can't read the local UTC offset from date." >&2; exit 1; }

out=$(jq -n --arg mode "$mode" --arg arg "$arg" --argjson logs "${logs:-[]}" \
  --arg wsd "$(jq -r '.week_start_day' <<<"$cfg")" --argjson gap "$(jq '.gap_days // 14' <<<"$cfg")" \
  --arg now "$now" --argjson mid "$mid" --argjson dry "$dry" '
  def iso: strftime("%Y-%m-%dT%H:%M:%SZ");
  def utcday: strptime("%Y-%m-%d") | mktime;
  def addday($n): utcday + 86400 * $n | strftime("%Y-%m-%d");
  # Local midnight of YYYY-MM-DD as epoch seconds, with the UTC offset in effect that day (from $mid).
  def midnight: . as $d | $mid[$d] // error("no local midnight for \($d)");
  # A zone-less time uses the offset at its local midnight (wrong only in the hours after a change).
  def instant: if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then midnight
                 else . as $in | (capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})(?<s>:[0-9]{2})?([.][0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})?$") // error("not an ISO date or instant: \($in)"))
                   | ((.b + (.s // ":00")) | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
                     - (if .z == null then (.b[0:10] | utcday - midnight) elif .z == "Z" then 0
                        else (.z[0:1] + "1" | tonumber) * ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) end) end;
    # Round-trip check: strptime accepts impossible dates (Feb 30), so reject any that change.
    def valid: . as $s | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}") and ($s[0:10] | strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) != $s[0:10] then error("bad date \($s)") else . end;
    # The local day of an instant: the latest nearby day whose midnight is at or before it.
    def localday: . as $t | [($t - 86400, $t, $t + 86400) | strftime("%Y-%m-%d") | select($mid[.] != null and $mid[.] <= $t)] | max
      // error("no local day for \($t | iso)");
    def weekstart: (strptime("%Y-%m-%d") | mktime) as $t
      | (["sunday","monday","tuesday","wednesday","thursday","friday","saturday"] | index($wsd)) as $w
      | ($t | gmtime | .[6]) as $dow | $t - 86400 * ((($dow - $w) % 7 + 7) % 7) | strftime("%Y-%m-%d");
  ($now | instant) as $n
  | ($logs | map(.file as $f | try (if .window_end then .window_end | instant
        elif .week_end and .run_at then [(.run_at | instant), (.week_end | addday(1) | midnight)] | min
        else .run_at | instant end) catch error("\($f): run_at or window_end isn'"'"'t a valid ISO date or instant")) | max) as $p
  | ($p // 0 | iso) as $prev
  | ($n | localday | weekstart) as $this_week
  | if $mode == "week" then
      ($arg | valid | weekstart) as $ws | ($ws | midnight) as $s | ([($ws | addday(7) | midnight), $n] | min) as $e
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
  | {run_at: ($n | iso)} + . + (if $dry then {dry_run: true} else {} end)
  | if (.window_start | fromdateiso8601) >= (.window_end | fromdateiso8601) then error("empty window: \(.window_start) to \(.window_end)") else . end
') && [ -n "$out" ] || { echo "start-run: couldn't fix the window." >&2; exit 1; }
if [ -n "$run" ]; then
  mkdir -p "$state" && printf '%s\n' "$out" >"$state/window.json" || { echo "start-run: can't write $state/window.json" >&2; exit 1; }
else
  echo "start-run: WEEKLY_ROUNDUP_RUN isn't set, so this window isn't saved and the guard won't enforce it." >&2
fi
printf '%s\n' "$out"
