#!/bin/bash
# Deterministic hard rules for weekly-roundup. PreToolUse on every MCP call (mcp__<server>__<tool>).
#   Microsoft 365 servers: read-only allow-list; everything else is denied.
#   Atlassian servers (Jira/Confluence): read allow-list; everything else asks the user.
#   In a roundup run (WEEKLY_ROUNDUP_RUN set): per-run M365 call budgets (locked, so parallel
#   subagents can't overrun them) and full ISO date windows of at most max_window_days on searches.
# Fails closed: anything it can't evaluate is blocked (exit 2) or denied.
# Every guarded decision in a run is appended to ~/.local/state/weekly-roundup/<run>/calls.jsonl.

block() { echo "weekly-roundup guard: $1" >&2; exit 2; }

input=$(cat)
command -v jq >/dev/null 2>&1 || block "jq is not installed, so MCP calls are blocked. Install jq."

# Exactly one JSON object with a string tool_name; anything else is blocked.
tool=$(jq -ser 'if length == 1 and (.[0] | type) == "object" and (.[0].tool_name | type) == "string"
                then .[0].tool_name else error("bad input") end' <<<"$input" 2>/dev/null) \
  || block "couldn't parse the tool call; blocked."

# mcp__<server>__<tool>. Classify by server; compare the whole tool part, case-insensitively.
lower=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')
case "$lower" in mcp__*__*) ;; *) exit 0 ;; esac
rest=${lower#mcp__}
server=${rest%%__*}
name=${rest#*__}
case "$server" in
  *microsoft*365*|*m365*)                 kind=m365 ;;
  *atlassian*|*jira*|*confluence*|*rovo*) kind=atlassian ;;
  *) exit 0 ;;
esac
# Guarded tool names never contain "__"; if one does, treat it as unknown.
case "$name" in *__*) name="__invalid__" ;; esac

here=$(cd "$(dirname "$0")" && pwd)
run=${WEEKLY_ROUNDUP_RUN:-}
state="$HOME/.local/state/weekly-roundup/$run"
key="$kind:$name"

record() {  # decision reason -> fails if the record can't be written
  [ -n "$run" ] || return 0
  mkdir -p "$state" &&
  jq -c --arg d "$1" --arg r "$2" --arg k "$key" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ts:$ts, phase:"pre", tool:.tool_name, key:$k, decision:$d, reason:$r, input:.tool_input}' \
    <<<"$input" >>"$state/calls.jsonl"
}
decide() {  # decision reason
  record "$1" "$2" || block "can't write the call record ($2); blocked."
  jq -nc --arg d "$1" --arg r "weekly-roundup guard: $2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}' \
    || block "$2"
  exit 0
}

if [ "$kind" = atlassian ]; then
  case "$name" in
    atlassianuserinfo|getaccessibleatlassianresources|discover|executeread|search|fetch|\
    getjiraissue|searchjiraissuesusingjql|getvisiblejiraprojects|getjiraprojectissuetypesmetadata|\
    getjiraissuetypemetawithfields|gettransitionsforjiraissue|getissuelinktypes|\
    getjiraissueremoteissuelinks|lookupjiraaccountid|getcontentformatguide|\
    getconfluencepage|getconfluencespaces|getpagesinconfluencespace|getconfluencepagedescendants|\
    getconfluencepagefootercomments|getconfluencepageinlinecomments|getconfluencecommentchildren|\
    searchconfluenceusingcql|searchconfluence|getconfluencecontent|\
    getteamworkgraphcontext|getteamworkgraphobject|getgraphcontext|getgraphobject)
      record allow "atlassian read" || block "can't write the call record; blocked."
      exit 0 ;;
    *) decide ask "Atlassian call $tool isn't on the read list, so it needs your approval" ;;
  esac
fi

# Microsoft 365
case "$name" in
  get_me|get_granted_scopes|search_people|read_resource|\
  outlook_email_search|outlook_calendar_search|chat_message_search|\
  teams_list_teams|teams_list_channels|teams_list_channel_messages|teams_list_chats|\
  sharepoint_search|sharepoint_folder_search|find_meeting_availability|outlook_find_available_time) ;;
  *) decide deny "Microsoft 365 is read-only ($tool is not on the read allow-list)" ;;
esac
[ -n "$run" ] || exit 0

cfg=$("$here/../scripts/config-json" 2>/dev/null) || decide deny "can't read a valid weekly-roundup config, so roundup M365 calls are blocked"

# Date window: full ISO values (date, or date + time with optional Z/offset), compared as instants.
case "$name" in
  outlook_email_search|outlook_calendar_search|chat_message_search|sharepoint_search|sharepoint_folder_search)
    span=$(jq -r --argjson max "$(jq '.max_window_days' <<<"$cfg")" '
      def inst:
        (. // "") | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})(T(?<t>[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?)(?<z>Z|[+-][0-9]{2}:[0-9]{2})?)?$")
        | (.d | strptime("%Y-%m-%d") | mktime)
          + (if .t then (.t | split(":") | map(tonumber) | .[0]*3600 + .[1]*60 + ((.[2] // 0) | floor)) else 0 end)
          - (if .z and .z != "Z" then ((.z[0:1] + "1") | tonumber) * ((.z[1:3]|tonumber)*3600 + (.z[4:6]|tonumber)*60) else 0 end);
      (.tool_input.afterDateTime | inst) as $a | (.tool_input.beforeDateTime | inst) as $b
      | ($b - $a) as $s
      | if $s >= 0 and $s <= $max * 86400 then "ok" else "\(($s / 3600) | floor) hours (max \($max) days)" end
    ' <<<"$input" 2>/dev/null)
    [ -n "$span" ] || decide deny "$name needs ISO afterDateTime and beforeDateTime (e.g. 2026-10-18 or 2026-10-18T00:00:00-05:00) in a roundup run"
    [ "$span" = ok ] || decide deny "date window is $span"
    ;;
esac

# Per-run budget, keyed on kind:tool. A mkdir lock makes count-and-record atomic across parallel hooks.
budget=$(jq -r --arg t "$name" '.budgets[$t] // .budgets.default' <<<"$cfg")
[[ $budget =~ ^[0-9]+$ ]] || decide deny "no valid budget for $name"
mkdir -p "$state" 2>/dev/null || block "can't create $state; blocked."
lock="$state/.lock"; got=
for _ in $(seq 1 100); do
  if mkdir "$lock" 2>/dev/null; then echo $$ >"$lock/pid"; got=1; break; fi
  # Recover a lock left by a hook that was killed.
  holder=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  sleep 0.05
done
[ -n "$got" ] || block "couldn't lock the call record; blocked."
trap 'rm -rf "$lock"' EXIT
if [ -f "$state/calls.jsonl" ]; then
  used=$(jq -s --arg k "$key" '[.[] | select(.phase == "pre" and .key == $k and .decision == "allow")] | length' "$state/calls.jsonl" 2>/dev/null) \
    || decide deny "the call record is unreadable, so the budget can't be checked"
else
  used=0
fi
[ "$used" -lt "$budget" ] || decide deny "$name budget used ($used/$budget calls this run). Work with what you have and note it under Gaps."
record allow "$((used + 1))/$budget" || block "can't write the call record; blocked."
exit 0
