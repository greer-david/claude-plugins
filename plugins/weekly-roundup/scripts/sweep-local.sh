#!/bin/bash
# Deterministic local sweep for /weekly-roundup.
# Usage: sweep-local.sh [SINCE UNTIL]
#   SINCE, UNTIL: ISO instants, or YYYY-MM-DD dates (SINCE from local midnight, UNTIL through the end
#   of that day). Without them it sweeps this run's window from scripts/start-run.sh.
# Items dated before the window's week_start are marked [late]. Prints capped raw material per
# source, then a STATS block. Same inputs give the same output.
set -u
# Portable date math (no GNU/BSD date differences): ISO dates compare as strings.
addday() { jq -rn --arg d "$1" --argjson n "${2:-1}" '$d|strptime("%Y-%m-%d")|mktime + 86400*$n|strftime("%Y-%m-%d")'; }
here=$(cd "$(dirname "$0")" && pwd)
win="$HOME/.local/state/weekly-roundup/${WEEKLY_ROUNDUP_RUN:-}/window.json"
if [ $# -ge 2 ]; then since=$1; until=$2; week_start=${3:-}
elif [ -n "${WEEKLY_ROUNDUP_RUN:-}" ] && [ -f "$win" ]; then
  since=$(jq -r .window_start "$win"); until=$(jq -r .window_end "$win"); week_start=$(jq -r .week_start "$win")
else echo "usage: sweep-local.sh SINCE UNTIL (or run scripts/start-run.sh first in a roundup run)" >&2; exit 1; fi
# Normalize to UTC instants plus the local days they span. touch -t wants local YYYYMMDDhhmm.SS.
w=$(jq -n --arg s "$since" --arg u "$until" --arg off "$(date +%z)" '
  (($off[0:1] + "1" | tonumber) * (($off[1:3] | tonumber) * 3600 + ($off[3:5] | tonumber) * 60)) as $offs
  | def day: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
    def t($end): if day then (strptime("%Y-%m-%d") | mktime) - $offs + (if $end then 86400 else 0 end)
      else . as $in | (capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})(?<s>:[0-9]{2})?([.][0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})?$")
             // error("not an ISO date or instant: \($in)"))
        | ((.b + (.s // ":00")) | strptime("%Y-%m-%dT%H:%M:%S") | mktime)
          - (if .z == null then $offs elif .z == "Z" then 0
             else (.z[0:1] + "1" | tonumber) * ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) end) end;
  ($s | t(false)) as $a | ($u | t(true)) as $b
  | if $a >= $b then error("empty window") else . end
  | {a: $a, b: $b, since: ($a | todate), until: ($b | todate),
     first: ($a + $offs | strftime("%Y-%m-%d")), last: ($b - 1 + $offs | strftime("%Y-%m-%d")), offs: $offs}') \
  || { echo "sweep-local: bad window $since .. $until" >&2; exit 1; }
wv() { jq -r ".$1" <<<"$w"; }
since=$(wv since); until=$(wv until); start=$(wv first); end=$(wv last)
stamp() { jq -rn --argjson t "$1" --argjson o "$(wv offs)" '$t + $o | strftime("%Y%m%d%H%M.%S")'; }
late() { [ -n "$week_start" ] && [[ "$1" < "$week_start" ]] && printf '[late] '; }
cfg=$("$here/config-json") || { echo "sweep-local: config failed to load; nothing swept." >&2; exit 1; }
c() { jq -r "$1" <<<"$cfg"; }
cap_commits=$(c '.caps.commits_per_repo'); cap_tkb=$(c '.caps.transcript_kb'); cap_ckb=$(c '.caps.clerk_kb')
gh_user=$(c '.github_user // empty')
if [ -n "$gh_user" ]; then GH_TOKEN=$(gh auth token --user "$gh_user" 2>/dev/null); export GH_TOKEN; fi
stats=()
tmp=$(mktemp -d) || exit 1

echo "## GIT"
seen="$tmp/seen"; : >"$seen"; trap 'rm -rf "$tmp"' EXIT
while IFS= read -r repo; do
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { stats+=("git|$(basename "$repo")|missing|0|-"); continue; }
  email=$(git -C "$repo" config user.email)
  out=$(git -C "$repo" log --all --author="$email" --since="$since" --until="$until" \
        --format='%h %ad %s' --date=short 2>/dev/null \
        | awk -v f="$seen" -v ws="$week_start" 'BEGIN{while((getline l<f)>0)s[l]=1} !s[$1]{print $0 (ws != "" && $2 < ws ? " [late]" : ""); print $1>>f}')
  # worktrees of the same repo share commits; each hash is printed once
  n=$(grep -c . <<<"$out"); hit=no; [ "$n" -gt "$cap_commits" ] && hit=yes
  [ "$n" -gt 0 ] && { echo "### $(basename "$repo")"; head -n "$cap_commits" <<<"$out"; }
  stats+=("git|$(basename "$repo")|ok|$n|$hit")
done < <(c '.repos[]')

echo "## GITHUB"
while IFS= read -r gr; do
  out=$(gh pr list -R "$gr" --author @me --state all --search "updated:$since..$until" --limit 100 \
        --json number,title,state,mergedAt,url,headRefName,updatedAt \
        --jq '.[] | "#\(.number) [\(.state)\(if .mergedAt then " "+.mergedAt[0:10] else "" end)] \(.title) \(.url)\(if "'"$week_start"'" != "" and .updatedAt[0:10] < "'"$week_start"'" then " [late]" else "" end)"' 2>&1); rc=$?
  n=$(grep -c '^#' <<<"$out")
  [ "$n" -gt 0 ] && { echo "### $gr (authored)"; echo "$out"; }
  st=ok; [ "$rc" -eq 0 ] || { st="error: $(head -1 <<<"$out")"; n=0; }
  stats+=("github|$gr|$st|$n|$([ "$n" -ge 100 ] && echo yes || echo no)")
done < <(c '.github_repos[]?')
rev=$(gh search prs --reviewed-by @me --updated "$since..$until" --limit 100 \
      --json number,title,repository,url,updatedAt --jq '.[] | "#\(.number) \(.repository.nameWithOwner) \(.title) \(.url)\(if "'"$week_start"'" != "" and .updatedAt[0:10] < "'"$week_start"'" then " [late]" else "" end)"' 2>&1); rc=$?
nrev=$(grep -c '^#' <<<"$rev")
[ "$nrev" -gt 0 ] && { echo "### reviewed by me"; echo "$rev"; }
rst=ok; [ "$rc" -eq 0 ] || { rst="error: $(head -1 <<<"$rev")"; nrev=0; }
stats+=("github|reviews|$rst|$nrev|$([ "$nrev" -ge 100 ] && echo yes || echo no)")

# Open review requests still waiting on the user (GitHub's notification emails can't be told apart by subject).
req=$(gh search prs --review-requested=@me --state open --limit 100 \
      --json number,title,repository,url,updatedAt --jq '.[] | "#\(.number) \(.repository.nameWithOwner) \(.title) \(.url) (updated \(.updatedAt[0:10]))"' 2>&1); rc=$?
nreq=$(grep -c '^#' <<<"$req")
[ "$nreq" -gt 0 ] && { echo "### review requested, not done (possibly missed)"; echo "$req"; }
qst=ok; [ "$rc" -eq 0 ] || { qst="error: $(head -1 <<<"$req")"; nreq=0; }
stats+=("github|review requests|$qst|$nreq|$([ "$nreq" -ge 100 ] && echo yes || echo no)")

echo "## SESSIONS"
clerk=$(c '.clerk_dir // empty'); tdir=$(c '.transcripts_dir'); skips=$(c '.skip_projects // [] | join("|")')
# Allow-list: a session counts only if its cwd is a session_dirs entry or inside one. Others are
# counted in STATS, never named, so personal projects don't leak into a work log.
sdirs=$(c '.session_dirs[]'); nskip=0
inside() { local d; [ -n "$1" ] || return 1; while IFS= read -r d; do d=${d%/}; [ -n "$d" ] || continue; case "$1" in "$d"|"$d"/*) return 0;; esac; done <<<"$sdirs"; return 1; }
# clerk keeps slug/<slug>.json = {"cwd": ...}; map each cwd to its slug so a transcript
# is read only when clerk has no summary for that session's project on that day.
cwdmap=$( [ -n "$clerk" ] && for j in "$clerk"/slug/*.json; do jq -r --arg s "$(basename "$j" .json)" '"\(.cwd)\t\($s)"' "$j" 2>/dev/null; done )
d=$start
while [[ ! "$d" > "$end" ]]; do
  dd=${d//-/}
  if [ -n "$clerk" ] && [ -d "$clerk/summary/$dd" ]; then
    for f in "$clerk/summary/$dd"/*.md; do
      [ -n "$skips" ] && grep -qE "$skips" <<<"$(basename "$f")" && continue
      scwd=$(awk -F'\t' -v s="$(basename "$f" .md)" '$2==s{print $1; exit}' <<<"$cwdmap")
      inside "$scwd" || { nskip=$((nskip+1)); continue; }
      bytes=$(wc -c <"$f"); hit=no; [ "$bytes" -gt $((cap_ckb*1024)) ] && hit=yes
      echo "### $(late "$d")clerk $d $(basename "$f" .md)"; head -c $((cap_ckb*1024)) "$f"; echo
      stats+=("clerk|$d $(basename "$f" .md)|ok|$bytes B|$hit")
    done
  fi
  # Transcripts touched that day (worktree sessions included: each has its own project dir).
  # Portable day filter: reference files stamped at local midnight, then find -newer (POSIX).
  # Clipped to the window: from max(local midnight, window start) to min(next midnight, window end).
  t0=$(jq -rn --arg d "$d" --argjson w "$w" '($d | strptime("%Y-%m-%d") | mktime) - $w.offs | [([., $w.a] | max), ([. + 86400, $w.b] | min)] | @tsv')
  touch -t "$(stamp "${t0%%$'\t'*}")" "$tmp/from" && touch -t "$(stamp "${t0#*$'\t'}")" "$tmp/to" || { stats+=("transcript|$d|error: can't stamp reference files|0|-"); d=$(addday "$d"); continue; }
  while IFS= read -r -d '' t; do
    [ -n "$skips" ] && grep -qE "$skips" <<<"$(basename "$(dirname "$t")")" && continue
    tcwd=$(jq -r 'select(.cwd) | .cwd' "$t" 2>/dev/null | head -1)
    inside "$tcwd" || { nskip=$((nskip+1)); continue; }
    slug=$(awk -F'\t' -v c="$tcwd" '$1==c{print $2; exit}' <<<"$cwdmap")
    [ -n "$slug" ] && [ -f "$clerk/summary/$dd/$slug.md" ] && continue
    txt=$( { jq -r 'select(.type=="user" and (.message.content|type)=="string") | "USER: " + .message.content' "$t" 2>/dev/null
             jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty | "FINAL: " + .' "$t" 2>/dev/null; } )
    [ -n "$txt" ] || continue
    name=${tcwd#"$HOME"/}
    bytes=${#txt}; hit=no; [ "$bytes" -gt $((cap_tkb*1024)) ] && hit=yes
    echo "### $(late "$d")transcript $d $name"; head -c $((cap_tkb*1024)) <<<"$txt"; echo
    stats+=("transcript|$d $name|no clerk summary|$bytes B|$hit")
  done < <(find "$tdir" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$tmp/from" ! -newer "$tmp/to" -print0)
  d=$(addday "$d")
done

[ "$nskip" -gt 0 ] && stats+=("sessions|outside session_dirs|skipped|$nskip|-")
echo "## STATS"
echo "source|item|status|size|cap hit"
printf '%s\n' "${stats[@]}"
