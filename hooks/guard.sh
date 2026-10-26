#!/bin/bash
# Deterministic hard rules for weekly-roundup. PreToolUse on every MCP call.
#   Always:  Microsoft 365 read-only allow-list (everything else denied);
#            Jira/Confluence writes ask the user, even in auto mode.
#   In a roundup run (WEEKLY_ROUNDUP_RUN set by the `roundup` alias):
#            per-run call budgets for M365 tools, and search tools must send an
#            ISO date window no longer than max_window_days.
# Every M365 decision in a run is appended to ~/.local/state/weekly-roundup/<run>/calls.jsonl.
here=$(cd "$(dirname "$0")" && pwd)
input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
short=${tool##*__}
run=${WEEKLY_ROUNDUP_RUN:-}
state=~/.local/state/weekly-roundup/$run

record() {  # decision reason
  [ -n "$run" ] || return 0
  mkdir -p "$state"
  jq -c --arg d "$1" --arg r "$2" --arg ts "$(date -u +%FT%TZ)" \
    '{ts:$ts, phase:"pre", tool:.tool_name, decision:$d, reason:$r, input:.tool_input}' <<<"$input" >>"$state/calls.jsonl"
}
decide() {
  record "$1" "$2"
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
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
    cfg=$("$here/../scripts/config-json")

    # Date window check for search tools.
    case "$short" in
      outlook_email_search|outlook_calendar_search|chat_message_search|sharepoint_search)
        a=$(jq -r '.tool_input.afterDateTime // empty' <<<"$input" | cut -c1-10)
        b=$(jq -r '.tool_input.beforeDateTime // empty' <<<"$input" | cut -c1-10)
        iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        [[ $a =~ $iso && $b =~ $iso ]] || decide deny "weekly-roundup guard: $short needs ISO afterDateTime and beforeDateTime (YYYY-MM-DD) in a roundup run"
        max=$(jq -r '.max_window_days' <<<"$cfg")
        span=$(( ( $(date -j -f %F "$b" +%s) - $(date -j -f %F "$a" +%s) ) / 86400 ))
        [ "$span" -ge 0 ] && [ "$span" -le "$max" ] || decide deny "weekly-roundup guard: date window $a..$b is $span days (max $max)"
        ;;
    esac

    # Per-run call budget.
    budget=$(jq -r --arg t "$short" '.budgets[$t] // .budgets.default' <<<"$cfg")
    used=$(jq -r --arg t "$tool" 'select(.phase=="pre" and .tool==$t and .decision=="allow") | 1' "$state/calls.jsonl" 2>/dev/null | grep -c .)
    [ "$used" -lt "$budget" ] || decide deny "weekly-roundup guard: $short budget used ($used/$budget calls this run). Work with what you have and note it under Gaps."
    record allow "$((used+1))/$budget"
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
