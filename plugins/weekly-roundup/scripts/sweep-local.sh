#!/bin/bash
# Deterministic local sweep for /weekly-roundup.
# Usage: sweep-local.sh START END   (YYYY-MM-DD, both inclusive)
# Prints capped raw material per source, then a STATS block. Same inputs give the same output.
set -u
# Portable date math (no GNU/BSD date differences): ISO dates compare as strings.
addday() { jq -rn --arg d "$1" --argjson n "${2:-1}" '$d|strptime("%Y-%m-%d")|mktime + 86400*$n|strftime("%Y-%m-%d")'; }
start=$1; end=$2
here=$(cd "$(dirname "$0")" && pwd)
cfg=$("$here/config-json") || { echo "sweep-local: config failed to load; nothing swept." >&2; exit 1; }
c() { jq -r "$1" <<<"$cfg"; }
cap_commits=$(c '.caps.commits_per_repo'); cap_tkb=$(c '.caps.transcript_kb'); cap_ckb=$(c '.caps.clerk_kb')
gh_user=$(c '.github_user // empty')
if [ -n "$gh_user" ]; then GH_TOKEN=$(gh auth token --user "$gh_user" 2>/dev/null); export GH_TOKEN; fi
end_next=$(addday "$end")
stats=()
tmp=$(mktemp -d) || exit 1

echo "## GIT"
seen="$tmp/seen"; : >"$seen"; trap 'rm -rf "$tmp"' EXIT
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
        --jq '.[] | "#\(.number) [\(.state)\(if .mergedAt then " "+.mergedAt[0:10] else "" end)] \(.title) \(.url)"' 2>&1); rc=$?
  n=$(grep -c '^#' <<<"$out")
  [ "$n" -gt 0 ] && { echo "### $gr (authored)"; echo "$out"; }
  st=ok; [ "$rc" -eq 0 ] || { st="error: $(head -1 <<<"$out")"; n=0; }
  stats+=("github|$gr|$st|$n|$([ "$n" -ge 100 ] && echo yes || echo no)")
done < <(c '.github_repos[]?')
rev=$(gh search prs --reviewed-by @me --updated "$start..$end" --limit 100 \
      --json number,title,repository,url --jq '.[] | "#\(.number) \(.repository.nameWithOwner) \(.title) \(.url)"' 2>&1); rc=$?
nrev=$(grep -c '^#' <<<"$rev")
[ "$nrev" -gt 0 ] && { echo "### reviewed by me"; echo "$rev"; }
rst=ok; [ "$rc" -eq 0 ] || { rst="error: $(head -1 <<<"$rev")"; nrev=0; }
stats+=("github|reviews|$rst|$nrev|$([ "$nrev" -ge 100 ] && echo yes || echo no)")

echo "## SESSIONS"
clerk=$(c '.clerk_dir // empty'); tdir=$(c '.transcripts_dir'); skips=$(c '.skip_projects // [] | join("|")')
# clerk keeps slug/<slug>.json = {"cwd": ...}; map each cwd to its slug so a transcript
# is read only when clerk has no summary for that session's project on that day.
cwdmap=$( [ -n "$clerk" ] && for j in "$clerk"/slug/*.json; do jq -r --arg s "$(basename "$j" .json)" '"\(.cwd)\t\($s)"' "$j" 2>/dev/null; done )
d=$start
while [[ ! "$d" > "$end" ]]; do
  dd=${d//-/}
  if [ -n "$clerk" ] && [ -d "$clerk/summary/$dd" ]; then
    for f in "$clerk/summary/$dd"/*.md; do
      [ -n "$skips" ] && grep -qE "$skips" <<<"$(basename "$f")" && continue
      bytes=$(wc -c <"$f"); hit=no; [ "$bytes" -gt $((cap_ckb*1024)) ] && hit=yes
      echo "### clerk $d $(basename "$f" .md)"; head -c $((cap_ckb*1024)) "$f"; echo
      stats+=("clerk|$d $(basename "$f" .md)|ok|$bytes B|$hit")
    done
  fi
  # Transcripts touched that day (worktree sessions included: each has its own project dir).
  # Portable day filter: reference files stamped at local midnight, then find -newer (POSIX).
  touch -t "${dd}0000" "$tmp/from" && touch -t "$(addday "$d" | tr -d -)0000" "$tmp/to" || { stats+=("transcript|$d|error: can't stamp reference files|0|-"); d=$(addday "$d"); continue; }
  while IFS= read -r -d '' t; do
    [ -n "$skips" ] && grep -qE "$skips" <<<"$(basename "$(dirname "$t")")" && continue
    tcwd=$(jq -r 'select(.cwd) | .cwd' "$t" 2>/dev/null | head -1)
    slug=$(awk -F'\t' -v c="$tcwd" '$1==c{print $2; exit}' <<<"$cwdmap")
    [ -n "$slug" ] && [ -f "$clerk/summary/$dd/$slug.md" ] && continue
    txt=$( { jq -r 'select(.type=="user" and (.message.content|type)=="string") | "USER: " + .message.content' "$t" 2>/dev/null
             jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty | "FINAL: " + .' "$t" 2>/dev/null; } )
    [ -n "$txt" ] || continue
    name=${tcwd#"$HOME"/}
    bytes=${#txt}; hit=no; [ "$bytes" -gt $((cap_tkb*1024)) ] && hit=yes
    echo "### transcript $d $name"; head -c $((cap_tkb*1024)) <<<"$txt"; echo
    stats+=("transcript|$d $name|no clerk summary|$bytes B|$hit")
  done < <(find "$tdir" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$tmp/from" ! -newer "$tmp/to" -print0)
  d=$(addday "$d")
done

echo "## STATS"
echo "source|item|status|size|cap hit"
printf '%s\n' "${stats[@]}"
