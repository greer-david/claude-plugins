#!/bin/bash
# Self-test for scripts/start-run.sh (run window) and scripts/check-log.sh.
cd "$(dirname "$0")/.." || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fail=0
export HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/c.json" TZ=UTC
mkdir -p "$tmp/logs"
echo "{\"log_dir\":\"$tmp/logs\",\"rules_file\":\"/tmp/r.md\"}" >"$tmp/c.json"
NOW=2026-10-30T14:00:00Z   # a Friday
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2"; fail=1; }
# win RUN [args] -> prints "window_start window_end week_start"
win() { local r=$1; shift; WEEKLY_ROUNDUP_RUN=$r WEEKLY_ROUNDUP_NOW=${N:-$NOW} bash scripts/start-run.sh "$@" 2>/dev/null \
        | jq -r '"\(.window_start) \(.window_end) \(.week_start)"'; }
want() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want $3, got $2"; }
log() { printf -- '---\n%s---\n\n# x\n' "$2" >"$tmp/logs/$1"; }

want "no logs: from this week's start" "$(win a)" "2026-10-25T00:00:00Z 2026-10-30T14:00:00Z 2026-10-25"
want "second call keeps the saved window" "$(N=2026-10-30T18:00:00Z win a --since 2026-10-01)" "2026-10-25T00:00:00Z 2026-10-30T14:00:00Z 2026-10-25"

log 2026-10-18.md $'week_end: 2026-10-24\nrun_at: 2026-10-23T13:00:00Z\nwindow_end: 2026-10-23T13:00:00Z\n'
want "from previous window_end" "$(win b)" "2026-10-23T13:00:00Z 2026-10-30T14:00:00Z 2026-10-25"

rm "$tmp/logs/"*
log 2026-10-18.md $'week_end: 2026-10-24\nrun_at: 2026-10-26T17:30:00Z\n'
want "calibration log without window_end: ends at its week" "$(win c)" "2026-10-25T00:00:00Z 2026-10-30T14:00:00Z 2026-10-25"

rm "$tmp/logs/"*
log 2026-10-04.md $'week_end: 2026-10-10\nrun_at: 2026-10-09T13:00:00Z\nwindow_end: 2026-10-09T13:00:00Z\n'
out=$(WEEKLY_ROUNDUP_RUN=d WEEKLY_ROUNDUP_NOW=$NOW bash scripts/start-run.sh 2>/dev/null)
want "old previous run: from this week's start" "$(jq -r .window_start <<<"$out")" "2026-10-25T00:00:00Z"
want "old previous run: gap recorded" "$(jq -r '"\(.gap.from) \(.gap.to)"' <<<"$out")" "2026-10-09T13:00:00Z 2026-10-25T00:00:00Z"

want "--since overrides" "$(win e --since 2026-10-01)" "2026-10-01T00:00:00Z 2026-10-30T14:00:00Z 2026-10-25"
want "--week: the whole past week" "$(win f --week 2026-10-21)" "2026-10-18T00:00:00Z 2026-10-25T00:00:00Z 2026-10-18"
want "--week: current week ends now" "$(win g --week 2026-10-27)" "2026-10-25T00:00:00Z 2026-10-30T14:00:00Z 2026-10-25"
want "local midnight in UTC-5" "$(TZ=Etc/GMT+5 win h --week 2026-10-21)" "2026-10-18T05:00:00Z 2026-10-25T05:00:00Z 2026-10-18"
want "offset instant" "$(win i --since 2026-10-28T09:00:00-05:00)" "2026-10-28T14:00:00Z 2026-10-30T14:00:00Z 2026-10-25"

for a in "--since 2026-02-30" "--since yesterday" "--week 2026-13-01" "--since 2026-11-01" "--bogus"; do
  WEEKLY_ROUNDUP_RUN=bad WEEKLY_ROUNDUP_NOW=$NOW bash scripts/start-run.sh $a >/dev/null 2>&1 \
    && bad "rejects $a" || ok "rejects $a"
done
[ ! -f "$tmp/.local/state/weekly-roundup/bad/window.json" ] && ok "nothing saved after a rejected window" || bad "rejected window saved"

log 2026-10-25.md $'week_end: 2026-10-31\nrun_at: 2027-01-01T00:00:00Z\nwindow_end: 2027-01-01T00:00:00Z\n'
WEEKLY_ROUNDUP_RUN=fut WEEKLY_ROUNDUP_NOW=$NOW bash scripts/start-run.sh >/dev/null 2>&1 && bad "previous window in the future rejected" || ok "previous window in the future rejected"
rm "$tmp/logs/"*
log 2026-10-18.md $'run_at: Friday morning\n'
WEEKLY_ROUNDUP_RUN=garb WEEKLY_ROUNDUP_NOW=$NOW bash scripts/start-run.sh >/dev/null 2>&1 && bad "unparseable run_at rejected" || ok "unparseable run_at rejected"
rm "$tmp/logs/"*

# check-log against run a (2026-10-25T00:00:00Z .. 2026-10-30T14:00:00Z, run_at 14:00)
good=$'week_start: 2026-10-25\nrun_at: 2026-10-30T14:00:00Z\nwindow_start: 2026-10-25T00:00:00Z\nwindow_end: 2026-10-30T14:00:00Z\n'
log w.md "$good"
WEEKLY_ROUNDUP_RUN=a bash scripts/check-log.sh "$tmp/logs/w.md" >/dev/null && ok "check-log: matching log" || bad "check-log: matching log"
log w.md "$(sed 's/^run_at: .*/run_at: 2026-10-30T17:30:00Z/' <<<"$good")"$'\n'
WEEKLY_ROUNDUP_RUN=a bash scripts/check-log.sh "$tmp/logs/w.md" >/dev/null && bad "check-log: edited run_at" || ok "check-log: edited run_at"
log w.md $'week_start: 2026-10-25\n'
WEEKLY_ROUNDUP_RUN=a bash scripts/check-log.sh "$tmp/logs/w.md" >/dev/null && bad "check-log: missing fields" || ok "check-log: missing fields"
WEEKLY_ROUNDUP_RUN=none bash scripts/check-log.sh "$tmp/logs/w.md" >/dev/null 2>&1 && bad "check-log: no run window" || ok "check-log: no run window"
exit $fail
