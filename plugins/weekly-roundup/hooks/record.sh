#!/bin/bash
# PostToolUse recorder for roundup runs (Microsoft 365 and Atlassian tools, classified like the guard): result size, error flag, and the
# continuation token the result returned (nextOffset/nextCursor), if any.
# Also the deterministic noise filter for outlook_email_search and chat_message_search: items whose
# sender matches m365.noise_senders (unless the subject matches m365.alert_patterns) or whose chat is
# in m365.mute_chats (chat IDs) are removed before the model sees the result, and counted as dropped.
# A result it can't parse passes through unchanged and is recorded as filter "unfiltered".
# For read_resource emails it records the message and conversation IDs and whether the user is in To.
run=${WEEKLY_ROUNDUP_RUN:-}
[ -n "$run" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
here=$(cd "$(dirname "$0")" && pwd)
state="$HOME/.local/state/weekly-roundup/$run"
mkdir -p "$state" || exit 0
input=$(cat)
. "$here/lib.sh" || exit 0
classify "$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)"
[ -n "$kind" ] || exit 0
cfg=$("$here/../scripts/config-json" 2>/dev/null) || cfg=null
out=$(jq -c --arg kind "$kind" --arg name "$name" --argjson cfg "$cfg" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  (.tool_response) as $r
  # MCP results often carry JSON inside text content; look inside strings that parse as JSON too.
  | ([$r] + [$r | .. | strings | (try fromjson catch empty)]) as $docs
  | {ts: $ts, phase: "post", tool: .tool_name, key: ($kind + ":" + $name), agent: .agent_id,
     input: .tool_input,
     # An error: an isError flag anywhere (also in JSON inside text), an "error" member of the result
     # or of a text block that is JSON, or a short text block that is not JSON and reads like an HTTP error.
     error: (([$docs[] | .. | objects | (.isError?, .is_error?)] | any(. == true))
            or any($docs[] | objects | .error? // null; . != null and . != false and . != "")
            or any($r | .. | strings | select(length < 500 and (try fromjson catch null) == null);
                   test("^\\s*(error\\b|http/?[0-9.]* [45][0-9]{2}\\b|[45][0-9]{2}\\b)"; "i")
                   or test("\\b(401|403|404|408|429|5[0-9]{2})\\b.{0,40}(forbidden|unauthorized|not found|timeout|too many requests|error|unavailable)"; "i"))),
     next: ([$docs[] | .. | objects | (.nextOffset?, .nextCursor?) | select(. != null and . != "")] | first // null)} as $rec
  # An opened email (read_resource): whether the user is in To (m365.my_addresses), and its IDs, so
  # scripts/check-log.sh can hold each possibly-missed email to a message addressed to the user.
  | ([$cfg.m365.my_addresses[]? | ascii_downcase]) as $mine
  | (if $kind != "m365" or $name != "read_resource" then $rec
     else ([$docs[] | objects | select(has("toRecipients"))] | first) as $msg
     | if $msg == null then $rec
       else $rec + {mail: {id: $msg.id, conversation: $msg.conversationId, uri: .tool_input.uri?,
                    addressed: (if $mine == [] then "unknown"
                                elif any($msg.toRecipients[]? | (.address? // .emailAddress?.address? // "") | ascii_downcase; IN($mine[]))
                                then "to_me" else "not_to_me" end)}} end end) as $rec

  # Noise filter. Each text block holds one item as JSON; the last block holds paging info.
  | ($cfg.m365 // {}) as $m
  | def lc: ascii_downcase;
    def hits($pats): . as $s | any($pats[]; (lc) as $p | ($s | lc | contains($p)));
    def why: if (.chatId? // null) != null and (.chatId | IN($m.mute_chats[]?)) then "muted chat"
             elif ((.sender? // .from?.email? // "") | tostring | hits($m.noise_senders // []))
                  and ((.subject? // "") | tostring | hits($m.alert_patterns // []) | not) then "noise sender"
             else null end;
    def who: .chatId? as $c | if why == "muted chat" then $c else (.sender? // .from?.email?) end;
  (if ($r | type) == "array" then $r else ($r.content? // null) end) as $blocks
  | if $kind != "m365" or ($name | IN("outlook_email_search", "chat_message_search") | not) then {rec: $rec, out: null}
    elif $cfg == null then {rec: ($rec + {filter: "no-config"}), out: null}
    elif $rec.error then {rec: ($rec + {filter: "error"}), out: null}
    elif ($blocks | type) != "array"
         or any($blocks[]; (.type != "text") or ((.text | try fromjson catch null) | type) != "object")
      then {rec: ($rec + {filter: "unfiltered"}), out: null}
    else
      [$blocks[] | {b: ., d: (.text | fromjson)} | .why = (.d | why) | .who = (.d | who)] as $items
      | [$items[] | select(.why == null) | .b] as $kept
      | [$items[] | select(.why != null)] as $gone
      | {rec: ($rec + {filter: "ok",
                       dropped: ($gone | group_by([.who, .why]) | map({who: .[0].who, reason: .[0].why, count: length}))}),
         out: (if ($gone | length) == 0 then null
               elif ($r | type) == "array" then $kept else ($r | .content = $kept) end)}
    end
  | .rec.bytes = ((.out // $r) | tostring | length)
' <<<"$input" 2>/dev/null) || exit 0
jq -c '.rec' <<<"$out" >>"$state/calls.jsonl" 2>/dev/null
jq -ce 'select(.out != null) | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedMCPToolOutput: .out}}' <<<"$out" 2>/dev/null
exit 0
