#!/bin/bash
# Deterministic hard rules for weekly-roundup. PreToolUse on every MCP call.
#   Always:  Microsoft 365 read-only allow-list (everything else denied);
#            Jira/Confluence writes ask the user, even in auto mode.
#   In a roundup run (WEEKLY_ROUNDUP_RUN set): per-run call budgets for M365 tools,
#            and search tools must send an ISO date window no longer than max_window_days.
# Fails closed: if this script can't evaluate an M365 or Atlassian call, it blocks it.
# Every M365 decision in a run is appended to ~/.local/state/weekly-roundup/<run>/calls.jsonl.
input=$(cat)

# Without jq nothing below can run. Block M365 and Atlassian calls (exit 2 = block) and allow the rest.
if ! command -v jq >/dev/null 2>&1; then
  case "$input" in
    *Microsoft_365__*|*tlassian*__*) echo "weekly-roundup guard: jq is not installed, so Microsoft 365 and Atlassian calls are blocked. Install jq." >&2; exit 2 ;;
  esac
  exit 0
fi

here=$(cd "$(dirname "$0")" && pwd)
tool=$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)
case "$input" in
  *Microsoft_365__*|*tlassian*__*) [ -n "$tool" ] || { echo "weekly-roundup guard: couldn't read the tool call; blocked." >&2; exit 2; } ;;
esac
short=${tool##*__}
run=${WEEKLY_ROUNDUP_RUN:-}
state=$HOME/.local/state/weekly-roundup/$run

record() {  # decision reason
  [ -n "$run" ] || return 0
  mkdir -p "$state" &&
  jq -c --arg d "$1" --arg r "$2" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ts:$ts, phase:"pre", tool:.tool_name, decision:$d, reason:$r, input:.tool_input}' <<<"$input" >>"$state/calls.jsonl"
}
decide() {
  record "$1" "$2"
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}' \
    || { echo "$2" >&2; exit 2; }
  exit 0
}

case "$tool" in
  mcp__*Microsoft_365__*)
    case "$short" in
      get_me|get_granted_scopes|search_people|read_resource|\
      outlook_email_search|outlook_calendar_search|chat_message_search|\
      teams_list_teams|teams_list_channels|teams_list_channel_messages|teams_list_chats|\
      sharepoint_search|sharepoint_folder_search|find_meeting_availability|outlook_find_available_time) ;;
      *) decide deny "weekly-roundup guard: Microsoft 365 is read-only ($short is not on the read allow-list)" ;;
    esac
    [ -n "$run" ] || exit 0
    cfg=$("$here/../scripts/config-json") || decide deny "weekly-roundup guard: can't read the weekly-roundup config, so roundup M365 calls are blocked"

    # Date window check for search tools.
    case "$short" in
      outlook_email_search|outlook_calendar_search|chat_message_search|sharepoint_search)
        span=$(jq -r --argjson max "$(jq '.max_window_days' <<<"$cfg")" '
          def day: (. // "")[0:10] | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | strptime("%Y-%m-%d") | mktime;
          (.tool_input.afterDateTime | day) as $a | (.tool_input.beforeDateTime | day) as $b
          | (($b - $a) / 86400) as $s
          | if $s >= 0 and $s <= $max then "ok" else "\($s) days (max \($max))" end' <<<"$input" 2>/dev/null)
        [ -n "$span" ] || decide deny "weekly-roundup guard: $short needs ISO afterDateTime and beforeDateTime (YYYY-MM-DD) in a roundup run"
        [ "$span" = ok ] || decide deny "weekly-roundup guard: date window is $span"
        ;;
    esac

    # Per-run call budget.
    budget=$(jq -r --arg t "$short" '.budgets[$t] // .budgets.default' <<<"$cfg")
    [[ $budget =~ ^[0-9]+$ ]] || decide deny "weekly-roundup guard: no valid budget for $short"
    used=$(jq -r --arg t "$tool" 'select(.phase=="pre" and .tool==$t and .decision=="allow") | 1' "$state/calls.jsonl" 2>/dev/null | grep -c . || true)
    [ "$used" -lt "$budget" ] || decide deny "weekly-roundup guard: $short budget used ($used/$budget calls this run). Work with what you have and note it under Gaps."
    record allow "$((used+1))/$budget" || decide deny "weekly-roundup guard: can't write the call record, so the call is blocked"
    exit 0
    ;;
  mcp__*tlassian*__*)
    case "$short" in
      addCommentToJiraIssue|addOrEditJiraIssueComment|addWorklogToJiraIssue|\
      createJiraIssue|editJiraIssue|transitionJiraIssue|createIssueLink|\
      createConfluence*|updateConfluence*|executeWrite|executeDestructive)
        decide ask "weekly-roundup guard: Jira/Confluence write ($short) needs your approval" ;;
    esac ;;
esac
exit 0
