#!/bin/bash
# Self-test for approval binding: hooks/approve.sh ("post N") + the Atlassian write check in hooks/guard.sh.
cd "$(dirname "$0")/.." || exit 1
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

expect "write before any approval" deny addCommentToJiraIssue "$c1"
[ -z "$(say 'post 1 and also edit the summary')" ] && ok "not exactly 'post N': ignored" || bad "loose prompt ignored"
[ ! -f "$st/approvals.jsonl" ] && ok "nothing stored for a loose prompt" || bad "loose prompt stored"
msg=$(say 'post 1-7')
grep -q "approved for one write each: 1 (comment), 2 (comment)" <<<"$msg" && ok "range approves comments" || bad "range approves comments" "$msg"
grep -q "proposal 3 has no quoted comment text" <<<"$msg" && ok "comment without text refused" || bad "empty comment" "$msg"
grep -q "proposal 4 (status) needs its own approval" <<<"$msg" && ok "status in a range refused" || bad "status in range" "$msg"
grep -q "proposal 7 heading .* is not a recognised format" <<<"$msg" && ok "unknown heading refused" || bad "unknown heading" "$msg"

expect "approved comment, exact text"      ask  addCommentToJiraIssue "$c1"
expect "same comment again (used up)"      deny addCommentToJiraIssue "$c1"
expect "comment with changed text"         deny addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment, edited."}'
expect "comment on another ticket"         deny addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-99","commentBody":"Second comment."}'
expect "comment as ADF"                    deny addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment.","contentFormat":"adf"}'
expect "update an existing comment"        deny addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment.","commentId":"1"}'
expect "approved comment, whitespace/case" ask  addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"abc-13","commentBody":"  Second comment.  \r\n"}'

say 'post 4, 5, 6' >/dev/null
expect "status with other transition"      deny transitionJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","transition":{"id":"41"}}'
expect "status setting fields too"         deny transitionJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","transition":{"id":"31"},"fields":{"resolution":{"name":"Done"}}}'
expect "approved status"                   ask  transitionJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","transition":{"id":"31"}}'
expect "link reversed"                     deny createIssueLink '{"cloudId":"x","inwardIssue":"ABC-40","outwardIssue":"ABC-12","type":"Blocks"}'
expect "link with a comment"               deny createIssueLink '{"cloudId":"x","inwardIssue":"ABC-12","outwardIssue":"ABC-40","type":"Blocks","comment":"x"}'
expect "approved link"                     ask  createIssueLink '{"cloudId":"x","inwardIssue":"ABC-12","outwardIssue":"ABC-40","type":"blocks"}'
expect "new ticket with extra fields"      deny createJiraIssue '{"cloudId":"x","projectKey":"ABC","issueTypeName":"Task","summary":"Rotate the gateway key","description":"Expires 2026-11-15.","additional_fields":{"priority":{"name":"High"}}}'
expect "new ticket, other summary"         deny createJiraIssue '{"cloudId":"x","projectKey":"ABC","issueTypeName":"Task","summary":"Rotate keys","description":"Expires 2026-11-15."}'
expect "approved new ticket"               ask  createJiraIssue '{"cloudId":"x","projectKey":"ABC","issueTypeName":"task","summary":"Rotate the gateway key","description":"Expires 2026-11-15."}'
expect "unbound write in a run"            deny editJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12","fields":{}}'
expect "Confluence write in a run"         deny createConfluencePage '{"cloudId":"x"}'
expect "read still allowed"                allow getJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-12"}'

# Edited after approval: the stored text is what counts.
say 'post 2' >/dev/null
perl -pi -e 's/^> Second comment\.$/> Second comment, reworded./' "$tmp/logs/2026-10-25.md"
expect "edited after approval: new text denied" deny addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment, reworded."}'
say 'post 2' >/dev/null
expect "re-approved after edit"            ask  addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment, reworded."}'
expect "old text after re-approval denied" deny addCommentToJiraIssue '{"cloudId":"x","issueIdOrKey":"ABC-13","commentBody":"Second comment."}'

out=$(WEEKLY_ROUNDUP_RUN= bash -c "jq -nc '{tool_name:\"${A}addCommentToJiraIssue\",tool_input:{}}' | bash hooks/guard.sh" | jq -r .hookSpecificOutput.permissionDecision)
[ "$out" = ask ] && ok "outside a run: writes still just ask" || bad "outside a run" "$out"
printf 'garbage\n' >>"$st/approvals.jsonl"
expect "corrupt approvals file denies"     deny addCommentToJiraIssue "$c1"
exit $fail
