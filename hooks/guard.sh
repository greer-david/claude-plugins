#!/bin/bash
# Deterministic hard rules for weekly-roundup. Runs before every MCP tool call.
#   Microsoft 365: allow-list of read tools; everything else is denied.
#   Jira/Confluence writes: always ask the user, even in auto mode.
tool=$(jq -r '.tool_name // empty')

decide() {
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

case "$tool" in
  mcp__*Microsoft_365__*)
    case "${tool##*__}" in
      get_me|get_granted_scopes|search_people|read_resource|\
      outlook_email_search|outlook_calendar_search|chat_message_search|\
      teams_list_teams|teams_list_channels|teams_list_channel_messages|teams_list_chats|\
      sharepoint_search|sharepoint_folder_search|find_meeting_availability|outlook_find_available_time)
        exit 0 ;;
      *) decide deny "weekly-roundup guard: Microsoft 365 is read-only ($tool is not on the read allow-list)" ;;
    esac ;;
  mcp__*tlassian*__*)
    case "${tool##*__}" in
      addCommentToJiraIssue|addOrEditJiraIssueComment|addWorklogToJiraIssue|\
      createJiraIssue|editJiraIssue|transitionJiraIssue|createIssueLink|\
      createConfluence*|updateConfluence*|executeWrite|executeDestructive)
        decide ask "weekly-roundup guard: Jira/Confluence write ($tool) needs your approval" ;;
    esac ;;
esac
exit 0
