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
  local d u o g out=
  while IFS=$'\t' read -r d u; do
    o=$(offset_at "$u") && g=$((u - o)) && o=$(offset_at "$g") || return 1
    out+="\"$d\":$((u - o)),"
  done < <(printf '%s\n' "$@" | sort -u | jq -Rr 'select(length > 0) | "\(.)\t\(strptime("%Y-%m-%d") | mktime)"') || return 1
  echo "{${out%,}}"
}

# day_range FIRST LAST -> each YYYY-MM-DD from FIRST to LAST, one per line.
day_range() { jq -rn --arg a "$1" --arg b "$2" '($a | strptime("%Y-%m-%d") | mktime) as $s | ($b | strptime("%Y-%m-%d") | mktime) as $e
  | range($s; $e + 1; 86400) | strftime("%Y-%m-%d")'; }
