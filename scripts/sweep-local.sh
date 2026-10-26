#!/bin/bash
# Deterministic local sweep for /weekly-roundup.
# Usage: sweep-local.sh START END   (YYYY-MM-DD, both inclusive)
# Prints capped raw material per source, then a STATS block. Same inputs give the same output.
set -u
start=$1; end=$2
here=$(cd "$(dirname "$0")" && pwd)
cfg=$("$here/config-json")
c() { jq -r "$1" <<<"$cfg"; }
cap_commits=$(c '.caps.commits_per_repo'); cap_tkb=$(c '.caps.transcript_kb'); cap_ckb=$(c '.caps.clerk_kb')
end_next=$(date -j -v+1d -f %F "$end" +%F)
stats=()

echo "## GIT"
seen=$(mktemp); trap 'rm -f "$seen"' EXIT
while IFS= read -r repo; do
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { stats+=("git|$(basename "$repo")|missing|0|-"); continue; }
  email=$(git -C "$repo" config user.email)
  out=$(git -C "$repo" log --all --author="$email" --since="$start 00:00" --until="$end_next 00:00" \
        --format='%h %ad %s' --date=short 2>/dev/null | awk -v f="$seen" 'BEGIN{while((getline l<f)>0)s[l]=1} !s[$1]{print; print $1>>f}')
  # worktrees of the same repo share commits; each hash is printed once
  n=$(grep -c . <<<"$out"); hit=no; [ "$n" -gt "$cap_commits" ] && hit=yes
  [ "$n" -gt 0 ] && { echo "### $(basename "$repo")"; head -n "$cap_commits" <<<"$out"; }
  stats+=("git|$(basename "$repo")|ok|$n|$hit")
done < <(c '.repos[]')

echo "## GITHUB"
while IFS= read -r gr; do
  out=$(gh pr list -R "$gr" --author @me --state all --search "updated:$start..$end" --limit 100 \
        --json number,title,state,mergedAt,url,headRefName \
        --jq '.[] | "#\(.number) [\(.state)\(if .mergedAt then " "+.mergedAt[0:10] else "" end)] \(.title) \(.url)"' 2>&1)
  n=$(grep -c '^#' <<<"$out")
  [ "$n" -gt 0 ] && { echo "### $gr (authored)"; echo "$out"; }
  st=ok; [ "$n" -eq 0 ] && grep -q . <<<"$out" && st="error: $(head -1 <<<"$out")"
  stats+=("github|$gr|$st|$n|$([ "$n" -ge 100 ] && echo yes || echo no)")
done < <(c '.github_repos[]?')
rev=$(gh search prs --reviewed-by @me --updated "$start..$end" --limit 100 \
      --json number,title,repository,url --jq '.[] | "#\(.number) \(.repository.nameWithOwner) \(.title) \(.url)"' 2>&1)
nrev=$(grep -c '^#' <<<"$rev")
[ "$nrev" -gt 0 ] && { echo "### reviewed by me"; echo "$rev"; }
stats+=("github|reviews|ok|$nrev|$([ "$nrev" -ge 100 ] && echo yes || echo no)")

echo "## SESSIONS"
clerk=$(c '.clerk_dir // empty'); glob=$(c '.transcripts_glob'); skips=$(c '.skip_projects // [] | join("|")')
d=$start
while [ "$(date -j -f %F "$d" +%s)" -le "$(date -j -f %F "$end" +%s)" ]; do
  dd=${d//-/}
  if [ -n "$clerk" ] && [ -d "$clerk/summary/$dd" ]; then
    for f in "$clerk/summary/$dd"/*.md; do
      [ -n "$skips" ] && grep -qE "$skips" <<<"$f" && continue
      bytes=$(wc -c <"$f"); hit=no; [ "$bytes" -gt $((cap_ckb*1024)) ] && hit=yes
      echo "### clerk $d $(basename "$f" .md)"; head -c $((cap_ckb*1024)) "$f"; echo
      stats+=("clerk|$d $(basename "$f" .md)|ok|$bytes B|$hit")
    done
  else
    # Fallback: transcripts touched that day. User turns + final assistant text only, capped.
    # shellcheck disable=SC2086
    for t in $(find $(dirname "$glob") -maxdepth 1 -name '*.jsonl' -newermt "$d 00:00" ! -newermt "$(date -j -v+1d -f %F "$d" +%F) 00:00" 2>/dev/null); do
      [ -n "$skips" ] && grep -qE "$skips" <<<"$t" && continue
      txt=$( { jq -r 'select(.type=="user" and (.message.content|type)=="string") | "USER: " + .message.content' "$t" 2>/dev/null
               jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty | "FINAL: " + .' "$t" 2>/dev/null; } )
      bytes=${#txt}; hit=no; [ "$bytes" -gt $((cap_tkb*1024)) ] && hit=yes
      echo "### transcript $d $(basename "$(dirname "$t")")"; head -c $((cap_tkb*1024)) <<<"$txt"; echo
      stats+=("transcript|$d $(basename "$(dirname "$t")" | sed "s/^-Users-[^-]*-//")|clerk missing|$bytes B|$hit")
    done
  fi
  d=$(date -j -v+1d -f %F "$d" +%F)
done

echo "## STATS"
echo "source|item|status|size|cap hit"
printf '%s\n' "${stats[@]}"
