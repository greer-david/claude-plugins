#!/bin/bash
# UserPromptSubmit hook for roundup runs: turns a prompt that is exactly "post <numbers>" (e.g.
# "post 1-6, 9") into approvals. For each named proposal it reads the run's log as it is now and
# stores the exact Jira write it shows in ~/.local/state/weekly-roundup/<run>/approvals.jsonl.
# hooks/guard.sh then denies any Atlassian write in the run that doesn't match an unused approval.
# Status changes, new tickets and links must be named singly; a range skips them.
# This is a consistency check, not proof a human typed it (the hook also fires on agent messages);
# the permission prompt on each Jira write stays the human approval. See docs/adr/0002.
run=${WEEKLY_ROUNDUP_RUN:-}
[ -n "$run" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
here=$(cd "$(dirname "$0")" && pwd)
state="$HOME/.local/state/weekly-roundup/$run"
input=$(cat)
prompt=$(jq -r '.prompt // empty' <<<"$input" 2>/dev/null)
shopt -s nocasematch
[[ $prompt =~ ^[[:space:]]*post[[:space:]]+([0-9][0-9[:space:],-]*)$ ]] || exit 0
list=${BASH_REMATCH[1]}
shopt -u nocasematch
say() { jq -nc --arg m "weekly-roundup approvals: $1" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}'; exit 0; }

cfg=$("$here/../scripts/config-json" 2>/dev/null) || say "config failed to load; nothing approved."
week=$(jq -r '.week_start // empty' "$state/window.json" 2>/dev/null)
[ -n "$week" ] || say "this run has no window (scripts/start-run.sh); nothing approved."
log="$(jq -r .log_dir <<<"$cfg")/$week.md"
[ -f "$log" ] || say "no log at $log; nothing approved."

res=$(jq -Rs --arg list "$list" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  def norm: gsub("\r"; "") | split("\n") | map(sub("[[:space:]]+$"; "")) | join("\n") | sub("^\\s+"; "") | sub("\\s+$"; "");
  def key: "[A-Z][A-Z0-9_]+-[0-9]+";
  # Requested numbers; ranges are marked so single-approval proposals can be skipped.
  ([$list | split(",")[] | split(" ")[] | select(. != "")
    | if test("^[0-9]+-[0-9]+$") then split("-") | map(tonumber) | range(.[0]; .[1] + 1) | {n: ., ranged: true}
      elif test("^[0-9]+$") then {n: tonumber, ranged: false}
      else error("bad number list") end]
   | group_by(.n) | map({n: .[0].n, ranged: all(.ranged)})) as $want
  # Proposals: a "**N. heading**" line, then the first quote block before the next heading.
  | split("\n") as $l
  | [range(0; $l | length) as $i | $l[$i] | capture("^\\*\\*(?<n>[0-9]+)\\. (?<h>[^*]+)\\*\\*") | .i = $i] as $heads
  # The quote block: the first ">" lines after the heading, unless a heading or section comes first.
  | def quote($i): $l[$i + 1:] as $rest
      | ([$rest | to_entries[] | select(.value | test("^>|^\\*\\*[0-9]+\\. |^#"))] | first) as $f
      | if $f == null or ($f.value | test("^>") | not) then []
        else $rest[$f.key:] | (map(test("^>") | not) | index(true)) as $e | if $e then .[:$e] else . end end;
  [$heads[] as $h
      | (quote($h.i) | map(sub("^> ?"; "")) | join("\n") | norm) as $body
      | ($h.h | sub("\\s+$"; "")) as $hd
      | {n: ($h.n | tonumber), heading: $hd} +
        ( if ($hd | test("^" + key + " · comment$")) then {action: "comment", key: ($hd | split(" ")[0]), body: $body}
          elif ($hd | test("^" + key + " · status → .+ \\(transition [0-9]+\\)$")) then
            ($hd | capture("^(?<k>\\S+) · status → (?<to>.+) \\(transition (?<id>[0-9]+)\\)$")) | {action: "status", key: .k, to: .to, transition: .id}
          elif ($hd | test("^" + key + " · link .+ → " + key + "$")) then
            ($hd | capture("^(?<a>\\S+) · link (?<t>.+) → (?<b>\\S+)$")) | {action: "link", inward: .a, type: .t, outward: .b}
          elif ($hd | test("^[A-Z][A-Z0-9_]+ · new .+$")) then
            ($hd | capture("^(?<p>\\S+) · new (?<t>.+)$")) as $c
            | ($body | split("\n")) as $b
            | {action: "new", project: $c.p, type: $c.t, summary: ($b[0] // "" | norm), description: ($b[1:] | join("\n") | norm)}
          else {action: null} end )
    ] as $props
  | [$want[] as $w | ($props | map(select(.n == $w.n))) as $m
      | if ($m | length) == 0 then {n: $w.n, problem: "no proposal \($w.n) in the log"}
        elif ($m | length) > 1 then {n: $w.n, problem: "proposal \($w.n) appears more than once"}
        elif $m[0].action == null then {n: $w.n, problem: "proposal \($w.n) heading \"\($m[0].heading)\" is not a recognised format"}
        elif ($m[0].action == "comment" and $m[0].body == "") then {n: $w.n, problem: "proposal \($w.n) has no quoted comment text"}
        elif ($m[0].action == "new" and $m[0].summary == "") then {n: $w.n, problem: "proposal \($w.n) has no quoted summary"}
        elif ($m[0].action != "comment" and $w.ranged) then {n: $w.n, problem: "proposal \($w.n) (\($m[0].action)) needs its own approval: name it singly, e.g. post \($w.n)"}
        else $m[0] + {approved_at: $ts, used: false} end]
  | {ok: map(select(.problem == null)), problems: map(select(.problem) | .problem)}
' "$log" 2>/dev/null) || say "couldn't read the proposals in $log; nothing approved."

# Same lock as the guard, so approvals and their use don't interleave.
mkdir -p "$state" || say "can't write $state; nothing approved."
lock="$state/.lock"; got=
for _ in $(seq 1 100); do
  if mkdir "$lock" 2>/dev/null; then echo $$ >"$lock/pid"; got=1; break; fi
  sleep 0.05
done
[ -n "$got" ] || say "couldn't lock the approvals file; nothing approved."
trap 'rm -rf "$lock"' EXIT
# A new approval of N replaces any earlier unused one (e.g. for text edited since).
if [ -s "$state/approvals.jsonl" ]; then
  jq -c --argjson new "$(jq -c '[.ok[].n]' <<<"$res")" 'if (.used | not) and (.n | IN($new[])) then .used = "superseded" else . end' \
    "$state/approvals.jsonl" >"$state/approvals.tmp" && mv "$state/approvals.tmp" "$state/approvals.jsonl" \
    || say "can't update the approvals file; nothing approved."
fi
jq -c '.ok[]' <<<"$res" >>"$state/approvals.jsonl" || say "can't write the approvals file; nothing approved."
say "$(jq -r '"approved for one write each: \(if (.ok | length) == 0 then "none" else (.ok | map("\(.n) (\(.action))") | join(", ")) end)"
              + (if (.problems | length) > 0 then ". Not approved: " + (.problems | join("; ")) else "" end)
              + ". Every Jira write must match its approved proposal exactly; anything else is denied."' <<<"$res")"
