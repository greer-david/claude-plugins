#!/bin/bash
# Print the team rules for a run. Usage: team-rules.sh
# The first line is a status, then the rules text:
#   STATUS: ok <source> @ <commit> (<date>)   read after a fresh fetch (or a plain file read)
#   STATUS: stale <source> ...; fetch failed   the last fetched copy follows; say so under Gaps
#   STATUS: missing <source> (<why>)           nothing to read; continue with personal rules only
#   STATUS: none                               no team rules configured
# team_rules {repo, ref, path} reads <ref>:<path> from the clone at repo after fetching the ref's remote,
# so any branch can be checked out and nobody has to pull. team_rules_file reads a plain file.
# Exits non-zero only if the config is invalid.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cfg=$("$here/config-json") || exit 1
file=$(jq -r '.team_rules_file // empty' <<<"$cfg")
if [ -n "$file" ]; then
  if [ -f "$file" ]; then echo "STATUS: ok $file"; cat "$file"; else echo "STATUS: missing $file (no such file)"; fi
  exit 0
fi
jq -e .team_rules <<<"$cfg" >/dev/null || { echo "STATUS: none"; exit 0; }
repo=$(jq -r .team_rules.repo <<<"$cfg"); ref=$(jq -r .team_rules.ref <<<"$cfg"); path=$(jq -r .team_rules.path <<<"$cfg")
src="$ref:$path in $repo"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "STATUS: missing $src (not a git repo)"; exit 0; }
status=ok note=
remote=${ref%%/*}
if git -C "$repo" remote | grep -qx -- "$remote"; then
  err=$(GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet "$remote" 2>&1) \
    || { status=stale; note="; fetch failed: $(printf '%s\n' "$err" | head -1)"; }
else
  note="; local ref, not fetched"
fi
sha=$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}") || { echo "STATUS: missing $src (no such ref$note)"; exit 0; }
text=$(git -C "$repo" show "$sha:$path" 2>/dev/null) || { echo "STATUS: missing $src (not on that ref$note)"; exit 0; }
when=$(git -C "$repo" log -1 --format=%cd --date=short "$sha")
echo "STATUS: $status $src @ ${sha:0:7} ($when)$note"
printf '%s\n' "$text"
