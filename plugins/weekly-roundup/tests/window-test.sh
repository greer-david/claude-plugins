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
# DST (US Central ends Sun 2026-11-01, starts Sun 2026-03-08): each day uses its own offset.
want "DST end: week starts at CDT midnight" "$(TZ=America/Chicago N=2026-11-06T18:00:00Z win dst1)" "2026-11-01T05:00:00Z 2026-11-06T18:00:00Z 2026-11-01"
want "DST end: --week ends at CST midnight" "$(TZ=America/Chicago N=2026-11-10T18:00:00Z win dst2 --week 2026-11-04)" "2026-11-01T05:00:00Z 2026-11-08T06:00:00Z 2026-11-01"
want "DST end: Saturday 23:30 CST is still that week" "$(TZ=America/Chicago N=2026-11-08T05:30:00Z win dst3)" "2026-11-01T05:00:00Z 2026-11-08T05:30:00Z 2026-11-01"
want "DST start: March week" "$(TZ=America/Chicago win dst4 --week 2026-03-10)" "2026-03-08T06:00:00Z 2026-03-15T05:00:00Z 2026-03-08"
want "DST: zone-less --since uses that day's offset" "$(TZ=America/Chicago N=2026-11-06T18:00:00Z win dst5 --since 2026-11-03T09:00)" "2026-11-03T15:00:00Z 2026-11-06T18:00:00Z 2026-11-01"
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

# Dry runs: recorded in the run, and their logs don't move where the next run starts.
log 2026-10-18.md $'week_end: 2026-10-24\nrun_at: 2026-10-23T13:00:00Z\nwindow_end: 2026-10-23T13:00:00Z\n'
log 2026-10-25.md $'week_end: 2026-10-31\nrun_at: 2026-10-30T13:00:00Z\nwindow_end: 2026-10-30T13:00:00Z\ndry_run: true\n'
want "dry-run log ignored: from the last real run" "$(win dr1)" "2026-10-23T13:00:00Z 2026-10-30T14:00:00Z 2026-10-25"
out=$(WEEKLY_ROUNDUP_RUN=dr2 WEEKLY_ROUNDUP_NOW=$NOW bash scripts/start-run.sh --dry-run 2>/dev/null)
[ "$(jq -r .dry_run <<<"$out")" = true ] && [ "$(jq -r .window_start <<<"$out")" = 2026-10-23T13:00:00Z ] && ok "--dry-run recorded" || bad "--dry-run recorded" "$out"
want "--dry-run with --week" "$(win dr3 --week 2026-10-21 --dry-run)" "2026-10-18T00:00:00Z 2026-10-25T00:00:00Z 2026-10-18"
[ "$(WEEKLY_ROUNDUP_RUN=dr1 WEEKLY_ROUNDUP_NOW=$NOW bash scripts/start-run.sh 2>/dev/null | jq -r '.dry_run // false')" = false ] && ok "real run: no dry_run" || bad "real run: no dry_run"
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
log w.md "$good"$'dry_run: true\n'
WEEKLY_ROUNDUP_RUN=a bash scripts/check-log.sh "$tmp/logs/w.md" >/dev/null && bad "check-log: dry_run in a real run's log" || ok "check-log: dry_run in a real run's log"
dgood=$(WEEKLY_ROUNDUP_RUN=dr2 bash scripts/start-run.sh 2>/dev/null | jq -r '"week_start: \(.week_start)\nrun_at: \(.run_at)\nwindow_start: \(.window_start)\nwindow_end: \(.window_end)"')
log w.md "$dgood"$'\n'
WEEKLY_ROUNDUP_RUN=dr2 bash scripts/check-log.sh "$tmp/logs/w.md" >/dev/null && bad "check-log: dry run's log without dry_run" || ok "check-log: dry run's log without dry_run"
log w.md "$dgood"$'\ndry_run: true\n'
WEEKLY_ROUNDUP_RUN=dr2 bash scripts/check-log.sh "$tmp/logs/w.md" >/dev/null && ok "check-log: dry run's log with dry_run" || bad "check-log: dry run's log with dry_run" "$(WEEKLY_ROUNDUP_RUN=dr2 bash scripts/check-log.sh "$tmp/logs/w.md")"
# Possibly missed (#11): source tags, and email items must be opened messages with the user in To.
echo "{\"log_dir\":\"$tmp/logs\",\"rules_file\":\"/tmp/r.md\",\"m365\":{\"my_addresses\":[\"Me@Example.com\"]}}" >"$tmp/c.json"
opened() { # id to-address
  jq -nc --arg id "$1" --arg to "$2" '{tool_name:"mcp__claude_ai_Microsoft_365__read_resource", tool_input:{uri:("mail:///messages/" + $id)},
    tool_response:{content:[{type:"text",text:({id:$id, conversationId:"c1", toRecipients:[{name:"X", address:$to}], ccRecipients:[]} | tojson)}]}}' \
  | WEEKLY_ROUNDUP_RUN=a bash hooks/record.sh >/dev/null; }
opened AAA me@example.com; opened BBB someone@example.com
pm() { log w.md "$good"$'---\n## Possibly fell through the cracks\n\n'"$1"$'\n\n## Jira proposals\n- not a missed item\n'; WEEKLY_ROUNDUP_RUN=a bash scripts/check-log.sh "$tmp/logs/w.md" 2>&1; }
pm '- [ ] Ann · Oct 27 · asked for the deck · email AAA' >/dev/null && ok "check-log: email to the user passes" || bad "check-log: email to the user" "$(pm '- [ ] Ann · Oct 27 · asked for the deck · email AAA')"
pm '- [ ] Ann · Oct 27 · asked · email mail:///messages/AAA' >/dev/null && ok "check-log: message uri accepted" || bad "check-log: uri"
pm $'- [ ] Bo · Oct 28 · ping · teams [chat](https://x)\n- [ ] PR #7 review · github https://x/7' >/dev/null && ok "check-log: other sources pass" || bad "check-log: other sources"
grep -q "isn't in To" <<<"$(pm '- [ ] Cy · Oct 27 · fyi · email BBB')" && ok "check-log: cc'd/other-To email fails" || bad "check-log: not-To email"
grep -q "wasn't opened" <<<"$(pm '- [ ] Di · Oct 27 · ask · email ZZZ')" && ok "check-log: unopened email fails" || bad "check-log: unopened email"
grep -q "no source tag" <<<"$(pm '- [ ] Ed · Oct 27 · ask (email)')" && ok "check-log: untagged item fails" || bad "check-log: untagged"
grep -q "without a message id" <<<"$(pm '- [ ] Fa · Oct 27 · ask · email')" && ok "check-log: email without id fails" || bad "check-log: email without id"
echo "{\"log_dir\":\"$tmp/logs\",\"rules_file\":\"/tmp/r.md\"}" >"$tmp/c.json"; opened CCC me@example.com
grep -q "set m365.my_addresses" <<<"$(pm '- [ ] Gi · Oct 27 · ask · email CCC')" && ok "check-log: no my_addresses fails loudly" || bad "check-log: no my_addresses"
exit $fail
