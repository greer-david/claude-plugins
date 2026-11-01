#!/bin/bash
# Self-test for scripts/calibration-check.sh (calibration report coverage and totals).
cd "$(dirname "$0")/.." || exit 1
. scripts/platform.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fail=0
export HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/c.json" WEEKLY_ROUNDUP_RUN=cal
echo '{"log_dir":"/tmp/x","rules_file":"/tmp/r.md"}' >"$tmp/c.json"
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2"; fail=1; }
cat >"$tmp/base.md" <<'B'
# Baseline items, week of 2026-10-18
- B1 · github · Merged the login fix (#42)
- B2 · email · Alex asked for app access
- B3 · jira · Commented on ABC-7
- B4 · teams · Oct 16 chat with Sam (before the skill's window)
B
rows=$'| baseline | result | skill item | what hid it |\n|---|---|---|---|\n| B1 | found | ABC-9 comment | |\n| B2 | missed | | filter |\n| B3 | found | ABC-7 comment | |\n| B4 | outside-overlap | | |\n\n| noise | skill item | why |\n|---|---|---|\n| N1 | newsletter | marketing |\n'
chk() { printf '# Calibration report\n\n%s' "$1" >"$tmp/rep.md"; bash scripts/calibration-check.sh "$tmp/rep.md" "$tmp/base.md" 2>&1; }
out=$(chk "$rows") && grep -q "Recall: 2 of 3 found (66%)" <<<"$out" && grep -q "Missed by cause: filter 1" <<<"$out" \
  && grep -q "Noise items the skill added: 1" <<<"$out" && grep -q "1 outside the overlap" <<<"$out" \
  && ok "complete report: totals" || bad "complete report" "$out"
grep -q '^## Totals (from code)' "$tmp/rep.md" && grep -q 'No M365 calls recorded' "$tmp/rep.md" && ok "totals and run-stats written into the report" || bad "block written" "$(cat "$tmp/rep.md")"
bash scripts/calibration-check.sh "$tmp/rep.md" "$tmp/base.md" >/dev/null && [ "$(grep -c '^## Totals' "$tmp/rep.md")" = 1 ] && ok "re-run replaces the block" || bad "re-run" "$(cat "$tmp/rep.md")"
grep -q "no row for baseline item B3" <<<"$(chk "$(grep -v '| B3 ' <<<"$rows")")" && ok "missing baseline item fails" || bad "missing item"
grep -q "isn't in the baseline" <<<"$(chk "$rows"$'| B9 | found | x | |\n')" && ok "unknown item fails" || bad "unknown item"
grep -q "more than one row for B1" <<<"$(chk "$rows"$'| B1 | missed | | cap |\n')" && ok "repeated item fails" || bad "repeated item"
grep -q "result must be" <<<"$(chk "${rows/| B1 | found/| B1 | partly}")" && ok "bad result fails" || bad "bad result"
grep -q "names what hid it" <<<"$(chk "${rows/| B2 | missed | | filter |/| B2 | missed | | |}")" && ok "missed without a cause fails" || bad "missed without cause"
out=$(chk "${rows/| B2 | missed | | filter |/| B2 | missed | found only by an extra search | off-plan |}") && grep -q "Missed by cause: off-plan 1" <<<"$out" && ok "off-plan is a miss cause" || bad "off-plan cause" "$out"
exit $fail
