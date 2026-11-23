#!/bin/bash
# Self-test for approval binding: hooks/approve.sh ("post N") + the Atlassian write check in hooks/guard.sh.
cd "$(dirname "$0")/.." || exit 1
. scripts/platform.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fail=0
export HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/c.json" WEEKLY_ROUNDUP_RUN=r
A=mcp__atlassian__
echo "{\"log_dir\":\"$tmp/logs\",\"rules_file\":\"/tmp/r.md\"}" >"$tmp/c.json"
st="$tmp/.local/state/weekly-roundup/r"; mkdir -p "$st" "$tmp/logs"
echo '{"run_at":"2026-10-30T14:00:00Z","week_start":"2026-10-25","window_start":"2026-10-25T00:00:00Z","window_end":"2026-10-30T14:00:00Z"}' >"$st/window.json"
cat >"$tmp/logs/2026-10-25.md" <<'L'
---
week_start: 2026-10-25
---
## Jira proposals

### Review closely

**1. ABC-12 · comment** · confidence: high · sources: #42
> Merged the login fix.
> Deployed to test on Tuesday.

**2. ABC-13 · comment** · confidence: med

> Second comment.

### Quick skim

**3. ABC-14 · comment**

### Needs explicit approval

**4. ABC-12 · status → Done (transition 31)** · confidence: high

**5. ABC-12 · link Blocks → ABC-40**

**6. ABC · new Task**
> Rotate the gateway key
> Expires 2026-11-15.

**7. ABC-15 · reassign to Sam**
L
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2"; fail=1; }
say() { jq -nc --arg p "$1" '{prompt:$p}' | bash hooks/approve.sh | jq -r '.hookSpecificOutput.additionalContext // empty'; }
# expect NAME WANT TOOL INPUT-JSON   WANT: ask | deny | block
expect() {
  out=$(jq -nc --arg t "$A$3" --argjson i "$4" '{tool_name:$t, tool_input:$i}' | bash hooks/guard.sh 2>/dev/null); rc=$?
  if [ $rc -eq 2 ]; then got=block; elif [ -z "$out" ]; then got=allow
  else got=$(jq -r .hookSpecificOutput.permissionDecision <<<"$out"); fi
  [ "$got" = "$2" ] && ok "$1" || bad "$1" "want $2, got $got: $out"
}
c1='{"cloudId":"x","issueIdOrKey":"ABC-12","commentBody":"Merged the login fix.\nDeployed to test on Tuesday."}'

C=addOrEditJiraIssueComment  # v2; the v1 names are checked at the end
expect "write before any approval" deny $C "$c1"
[ -z "$(say 'post 1 and also edit the summary')" ] && ok "not exactly 'post N': ignored" || bad "loose prompt ignored"
[ ! -f "$st/approvals.jsonl" ] && ok "nothing stored for a loose prompt" || bad "loose prompt stored"
msg=$(say 'post 1-7')
grep -q "approved for one write each: 1 (comment), 2 (comment)" <<<"$msg" && ok "range approves comments" || bad "range approves comments" "$msg"
grep -q "proposal 3 has no quoted comment text" <<<"$msg" && ok "comment without text refused" || bad "empty comment" "$msg"
grep -q "proposal 4 (status) needs its own approval" <<<"$msg" && ok "status in a range refused" || bad "status in range" "$msg"
grep -q "proposal 7 heading .* is not a recognised format" <<<"$msg" && ok "unknown heading refused" || bad "unknown heading" "$msg"

expect "approved comment, exact text"      ask  $C "$c1"
expect "same comment again (used up)"      deny $C "$c1"
c2='{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment."}'
w() { jq -c "$1" <<<"$2"; }  # w FILTER JSON: a variant of a call
expect "comment with changed text"         deny $C "$(w '.commentBody = "Second comment, edited."' "$c2")"
expect "comment on another ticket"         deny $C "$(w '.issueIdOrKey = "ABC-99"' "$c2")"
expect "comment as HTML"                   deny $C "$(w '.contentFormat = "html"' "$c2")"
expect "edit an existing comment"          deny $C "$(w '.commentId = "1"' "$c2")"
expect "comment with visibility"           deny $C "$(w '.commentVisibility = {type: "role", value: "Developers"}' "$c2")"
expect "comment as a JSM internal note"    deny $C "$(w '.jsmCommentType = "internalNote"' "$c2")"
expect "comment with an inline file"       deny $C "$(w '.inlineFileId = ["f"] | .inlineFileCollection = ["c"]' "$c2")"
expect "comment, unknown new option"       deny $C "$(w '.somethingNew = true' "$c2")"
expect "approved comment, whitespace/case" ask  $C '{"cloudId":"x","issueIdOrKey":"abc-13","commentBody":"  Second comment.  \r\n","contentFormat":"markdown","responseContentFormat":"markdown"}'

say 'post 4, 5, 6' >/dev/null
s4='{"cloudId":"x","issueIdOrKey":"ABC-12","transitionId":"31"}'
expect "status with other transition"      deny transitionJiraIssue "$(w '.transitionId = "41"' "$s4")"
expect "status by transitionName"          deny transitionJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","transitionName":"Done"}'
expect "status by ID and name"             deny transitionJiraIssue "$(w '.transitionName = "Done"' "$s4")"
expect "status setting fields too"         deny transitionJiraIssue "$(w '.fields = {resolution: {name: "Done"}}' "$s4")"
expect "status plus a sprint move"         deny transitionJiraIssue "$(w '.sprintId = 7' "$s4")"
expect "status plus a backlog move"        deny transitionJiraIssue "$(w '.assignToBacklog = true | .boardId = 2' "$s4")"
expect "status with history metadata"      deny transitionJiraIssue "$(w '.historyMetadata = {}' "$s4")"
expect "status with v1 and v2 IDs"         deny transitionJiraIssue "$(w '.transition = {id: "31"}' "$s4")"
expect "approved status"                   ask  transitionJiraIssue "$s4"
L='{"name":"createJiraIssueLink","cloudId":"x","inputs":{"linkType":"Blocks","inwardIssue":"ABC-12","outwardIssue":"ABC-40"}}'
expect "link reversed"                     deny executeWrite "$(w '.inputs.inwardIssue = "ABC-40" | .inputs.outwardIssue = "ABC-12"' "$L")"
expect "link with a comment"               deny executeWrite "$(w '.inputs.comment = "x"' "$L")"
expect "link, inputs not an object"        deny executeWrite "$(w '.inputs = "x"' "$L")"
expect "other executeWrite operation"      deny executeWrite '{"name":"createJiraIssueRemoteIssueLink","cloudId":"x","inputs":{"issueIdOrKey":"ABC-12","url":"https://x"}}'
expect "approved link"                     ask  executeWrite "$(w '.inputs.linkType = "blocks" | .responseFields = ["id"]' "$L")"
n6='{"cloudId":"x","projectKey":"ABC","issueType":"Task","summary":"Rotate the gateway key","description":"Expires 2026-11-15."}'
expect "new ticket with additional fields" deny createJiraIssue "$(w '.additional_fields = {"Story Points": 3}' "$n6")"
expect "new ticket with an assignee"       deny createJiraIssue "$(w '.assignee = "abc123"' "$n6")"
expect "new ticket with labels"            deny createJiraIssue "$(w '.labels = ["x"]' "$n6")"
expect "new ticket with a priority"        deny createJiraIssue "$(w '.priority = "High"' "$n6")"
expect "new ticket into a sprint"          deny createJiraIssue "$(w '.assignToSprint = "active"' "$n6")"
expect "new ticket with a parent"          deny createJiraIssue "$(w '.parent = "ABC-1"' "$n6")"
expect "new ticket as HTML"                deny createJiraIssue "$(w '.contentFormat = "html"' "$n6")"
expect "new ticket, both type keys"        deny createJiraIssue "$(w '.issueTypeName = "Task"' "$n6")"
expect "new ticket, other summary"         deny createJiraIssue "$(w '.summary = "Rotate keys"' "$n6")"
expect "approved new ticket"               ask  createJiraIssue "$(w '.issueType = "task"' "$n6")"
expect "unbound write in a run"            deny editJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","fields":{}}'
expect "Confluence write in a run"         deny createConfluenceContent '{"cloudId":"x"}'
expect "destructive operation in a run"    deny executeDestructive '{"name":"deleteJiraIssue","cloudId":"x","inputs":{}}'
expect "read still allowed"                allow getJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12"}'
expect "v2 read (comments) allowed"        allow listJiraIssueComments '{"cloudId":"x","issueIdOrKey":"ABC-12"}'

# Edited after approval: the stored text is what counts.
say 'post 2' >/dev/null
perl -pi -e 's/^> Second comment\.$/> Second comment, reworded./' "$tmp/logs/2026-10-25.md"
expect "edited after approval: new text denied" deny $C '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment, reworded."}'
say 'post 2' >/dev/null
expect "re-approved after edit"            ask  $C '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment, reworded."}'
expect "old text after re-approval denied" deny $C '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment."}'

# v1 server names and shapes (e.g. claude.ai Rovo v1 connectors, until 2027-03-01) bind to the same approvals.
say 'post 1' >/dev/null; say 'post 4' >/dev/null; say 'post 5' >/dev/null; say 'post 6' >/dev/null
expect "v1 comment with visibility"        deny addCommentToJiraIssue "$(w '.commentVisibility = {type: "role", value: "x"}' "$c1")"
expect "v1 approved comment"               ask  addCommentToJiraIssue "$c1"
expect "v1 status, transition not {id}"    deny transitionJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","transition":{"id":"31","looped":true}}'
expect "v1 approved status"                ask  transitionJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","transition":{"id":"31"}}'
expect "v1 link with a comment"            deny createIssueLink '{"cloudId":"x","inwardIssue":"ABC-12","outwardIssue":"ABC-40","type":"Blocks","comment":"x"}'
expect "v1 approved link"                  ask  createIssueLink '{"cloudId":"x","inwardIssue":"ABC-12","outwardIssue":"ABC-40","type":"blocks"}'
expect "v1 new ticket with an assignee"    deny createJiraIssue '{"cloudId":"x","projectKey":"ABC","issueTypeName":"Task","summary":"Rotate the gateway key","description":"Expires 2026-11-15.","assignee_account_id":"a"}'
expect "v1 approved new ticket"            ask  createJiraIssue '{"cloudId":"x","projectKey":"ABC","issueTypeName":"task","summary":"Rotate the gateway key","description":"Expires 2026-11-15."}'

out=$(WEEKLY_ROUNDUP_RUN= bash -c "jq -nc '{tool_name:\"${A}$C\",tool_input:{}}' | bash hooks/guard.sh" | jq -r .hookSpecificOutput.permissionDecision)
[ "$out" = ask ] && ok "outside a run: writes still just ask" || bad "outside a run" "$out"
printf 'garbage\n' >>"$st/approvals.jsonl"
expect "corrupt approvals file denies"     deny $C "$c1"
# mklock TARGET PATH: makes a test lock, failing loudly if PATH already exists or ln can't link.
mklock() { ln -s "$1" "$2" || { echo "FAIL setup: lock $2 -> $1 not made (existing: $(readlink "$2" 2>&1))"; ls -la "$(dirname "$2")"; fail=1; }; }
# A lock left by a killed hook is reclaimed; a live one is not taken (shared take_lock in hooks/lib.sh).
rm -f "$st/approvals.jsonl"; mklock "pid.$(bash -c 'echo $$').1" "$st/.run.lock"
msg=$(say 'post 1')
grep -q "approved for one write each: 1 (comment)" <<<"$msg" && ok "stale lock reclaimed for approvals" || bad "stale lock" "$msg"
# The holder outlives take_lock's retries, which pass 30 s on Git Bash.
sleep 300 & live=$!; mklock "pid.$live.1" "$st/.run.lock"
msg=$(say 'post 2')
grep -q "couldn't lock the approvals file" <<<"$msg" && [ "$(readlink "$st/.run.lock")" = "pid.$live.1" ] && ok "live lock not taken for approvals" || bad "live lock" "$msg"
kill $live 2>/dev/null; wait $live 2>/dev/null; rm -f "$st/.run.lock"
exit $fail
