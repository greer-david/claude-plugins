. "$(dirname "${BASH_SOURCE[0]}")/platform.sh"
# Local-time helpers, sourced by the scripts. jq can't tell the UTC offset of a given instant
# (strflocaltime("%z") gives the current offset on macOS and +0000 on Linux), so ask date:
# GNU `date -d @T`, else BSD `date -r T` (docs/adr/0003).

# offset_at EPOCH -> the local UTC offset at that instant, in seconds (east positive).
offset_at() {
  local z
  z=$(date -d "@$1" +%z 2>/dev/null) || z=$(date -r "$1" +%z 2>/dev/null) || return 1
  [[ "$z" =~ ^[+-][0-9]{4}$ ]] || return 1
  echo $(( ${z:0:1}1 * (10#${z:1:2} * 3600 + 10#${z:3:2} * 60) ))
}

# local_stamp EPOCH -> local time as YYYYMMDDhhmm.SS (for touch -t).
local_stamp() { date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S; }

# midnights DATE... -> JSON {"YYYY-MM-DD": epoch of that day's local midnight}. Each day gets the
# offset in effect at its own midnight: guess with the offset at UTC midnight, then correct once.
midnights() {
  local d u o g out= days
  # Real dates only: strptime accepts Feb 30, so each must round-trip.
  days=$(printf '%s\n' "$@" | sort -u | jq -Rr 'select(length > 0) | . as $d | (strptime("%Y-%m-%d") | mktime) as $u
    | if ($u | strftime("%Y-%m-%d")) == $d then "\($d)\t\($u)" else error("bad date \($d)") end') || return 1
  while IFS=$'\t' read -r d u; do
    [ -n "$d" ] || continue
    o=$(offset_at "$u") && g=$((u - o)) && o=$(offset_at "$g") || return 1
    out+="\"$d\":$((u - o)),"
  done <<<"$days"
  echo "{${out%,}}"
}

# local_to_utc ISO -> a date-time without a zone, read as local time, as ...Z (the offset at that
# very instant, so right after a DST change too). Anything else is printed unchanged.
local_to_utc() {
  local n o t
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?([.][0-9]+)?$ ]] || { echo "$1"; return 0; }
  n=$(jq -rn --arg s "$1" '$s[0:16] + ($s[16:19] | if . == "" then ":00" else . end) | strptime("%Y-%m-%dT%H:%M:%S") | mktime') || return 1
  o=$(offset_at "$n") && t=$((n - o)) && o=$(offset_at "$t") || return 1
  jq -rn --argjson t "$((n - o))" '$t | todate'
}

# day_range FIRST LAST -> each YYYY-MM-DD from FIRST to LAST, one per line.
day_range() { jq -rn --arg a "$1" --arg b "$2" '($a | strptime("%Y-%m-%d") | mktime) as $s | ($b | strptime("%Y-%m-%d") | mktime) as $e
  | range($s; $e + 1; 86400) | strftime("%Y-%m-%d")'; }
