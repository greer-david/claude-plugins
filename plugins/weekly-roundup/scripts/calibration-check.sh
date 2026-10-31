#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/platform.sh"
# Check a calibration report against its baseline list and write the totals into the report.
# Usage: calibration-check.sh REPORT BASELINE
#   BASELINE: one item per line, "- B<n> · <source> · <summary>" (written once, reviewed by the user).
#   REPORT:   a table row per baseline item, "| B<n> | found / missed / outside-overlap | <skill item> | <what hid it> |",
#             where a missed row names what hid it: cap, budget, ceiling, filter, omitted day, unread page,
#             judgement, not swept or off-plan; and noise rows "| N<n> | <skill item> | <why it's noise> |".
# Fails (exit 1) if a baseline item has no row, a row names an unknown or repeated item, or a value isn't
# allowed. Otherwise writes the totals and scripts/run-stats.sh output between the report's
# calibration-check markers (appended the first time), so the numbers come from code.
set -u
report=${1:?usage: calibration-check.sh REPORT BASELINE}; base=${2:?usage: calibration-check.sh REPORT BASELINE}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$report" ] || { echo "calibration-check: no report at $report" >&2; exit 1; }
[ -f "$base" ] || { echo "calibration-check: no baseline at $base" >&2; exit 1; }
res=$(jq -Rn --rawfile b "$base" --rawfile r "$report" '
  def cells: sub("^\\s*\\|"; "") | sub("\\|\\s*$"; "") | split("|") | map(gsub("^\\s+|\\s+$"; ""));
  [$b | split("\n")[] | capture("^\\s*- (?<id>B[0-9]+) ·").id] as $ids
  | [$r | split("\n")[] | select(test("^\\s*\\|\\s*B[0-9]+\\s*\\|")) | cells | {id: .[0], result: .[1], item: .[2], hid: (.[3] // "")}] as $rows
  | [$r | split("\n")[] | select(test("^\\s*\\|\\s*N[0-9]+\\s*\\|")) | cells | .[0]] as $noise
  | ["cap", "budget", "ceiling", "filter", "omitted day", "unread page", "judgement", "not swept", "off-plan"] as $hiders
  | [ ($ids | group_by(.)[] | select(length > 1) | "baseline lists \(.[0]) more than once"),
      ($ids[] as $i | select([$rows[] | select(.id == $i)] | length == 0) | "no row for baseline item \($i)"),
      ($rows | group_by(.id)[] | select(length > 1) | "more than one row for \(.[0].id)"),
      ($rows[] | select(.id | IN($ids[]) | not) | "row \(.id) isn'"'"'t in the baseline"),
      ($rows[] | select(.result | IN("found", "missed", "outside-overlap") | not) | "row \(.id): result must be found, missed or outside-overlap, not \"\(.result)\""),
      ($rows[] | select(.result == "missed" and (.hid | ascii_downcase | IN($hiders[]) | not))
       | "row \(.id): a missed item names what hid it (\($hiders | join(", "))), not \"\(.hid)\""),
      ($noise | group_by(.)[] | select(length > 1) | "noise row \(.[0]) appears more than once") ] as $errs
  | if $errs != [] then {errs: $errs}
    else ($rows | map(select(.result != "outside-overlap"))) as $in
    | ($in | map(select(.result == "found")) | length) as $f
    | {errs: [], text: ([
        "Baseline items: \($ids | length) (\($rows | map(select(.result == "outside-overlap")) | length) outside the overlap of the two windows, not counted).",
        "Recall: \($f) of \($in | length) found\(if ($in | length) > 0 then " (\($f * 100 / ($in | length) | floor)%)" else "" end).",
        "Missed by cause: \([$in[] | select(.result == "missed") | .hid | ascii_downcase] | group_by(.) | map("\(.[0]) \(length)") | if . == [] then "none" else join(", ") end).",
        "Noise items the skill added: \($noise | length)."] | join("\n"))} end' 2>&1) \
  || { echo "calibration-check: couldn't read the report or baseline: $res" >&2; exit 1; }
errs=$(jq -r '.errs[]' <<<"$res")
[ -z "$errs" ] || { echo "calibration-check: $report doesn't cover the baseline:"; echo "$errs"; exit 1; }
stats=$("$here/run-stats.sh" 2>&1)
block=$(printf '<!-- calibration-check:begin (written by scripts/calibration-check.sh; do not edit) -->\n## Totals (from code)\n\n%s\n\n## Sweep stats (from code)\n\n%s\n<!-- calibration-check:end -->' "$(jq -r .text <<<"$res")" "$stats")
if grep -q '^<!-- calibration-check:begin' "$report"; then
  printf '%s\n' "$block" >"$report.blk" &&
  awk -v f="$report.blk" '/^<!-- calibration-check:begin/{while ((getline l < f) > 0) print l; skip=1; next} /^<!-- calibration-check:end/{skip=0; next} !skip' "$report" >"$report.tmp"
  rm -f "$report.blk"
else
  { cat "$report"; printf '\n%s\n' "$block"; } >"$report.tmp"
fi && mv "$report.tmp" "$report" || { echo "calibration-check: can't write $report" >&2; exit 1; }
jq -r .text <<<"$res"
echo "calibration-check: ok"
