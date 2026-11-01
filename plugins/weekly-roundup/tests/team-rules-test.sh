#!/bin/bash
# Self-test for scripts/team-rules.sh: reads team rules from a git ref (fetched first) or a plain file.
cd "$(dirname "$0")/.." || exit 1
. scripts/platform.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; echo "$out"; fail=1; }
export HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/c.json" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
cfg() { echo '{"log_dir":"/tmp/x","rules_file":"/tmp/r.md"'"$1"'}' >"$tmp/c.json"; }
tr_() { bash scripts/team-rules.sh 2>&1; }

# A team repo with rules on dev, and a clone with a feature branch checked out.
git init -q "$tmp/team" && cd "$tmp/team" && git commit -q --allow-empty -m init && git switch -q -c dev \
  && mkdir -p docs && echo '- **E1** [team] rule v1' >docs/rules.md && git add . && git commit -q -m v1 && git switch -q main
cd - >/dev/null
git clone -q "$tmp/team" "$tmp/clone" && git -C "$tmp/clone" switch -q -c feature
cfg ',"team_rules":{"repo":"'"$tmp"'/clone","ref":"origin/dev","path":"docs/rules.md"}'
out=$(tr_)
grep -q '^STATUS: ok ' <<<"$out" && grep -q 'rule v1' <<<"$out" && ok "reads the ref with another branch checked out" || bad "reads ref"
[ "$(git -C "$tmp/clone" branch --show-current)" = feature ] && ok "checkout untouched" || bad "checkout untouched"

# A new rule merged upstream is picked up without a pull.
cd "$tmp/team" && git switch -q dev && echo '- **E1** [team] rule v2' >docs/rules.md && git commit -qam v2 && git switch -q main; cd - >/dev/null
out=$(tr_)
grep -q 'rule v2' <<<"$out" && ! grep -q 'rule v1' <<<"$out" && ok "fetches before reading" || bad "fetches before reading"

# Fetch fails: the last fetched copy is used, and the status says so with its commit.
git -C "$tmp/clone" remote set-url origin "$tmp/gone"
out=$(tr_)
grep -q '^STATUS: stale ' <<<"$out" && grep -q 'rule v2' <<<"$out" && ok "fetch failure falls back, marked stale" || bad "fetch failure stale"
git -C "$tmp/clone" remote set-url origin "$tmp/team"

# Path not on the ref: missing, not an error exit.
cfg ',"team_rules":{"repo":"'"$tmp"'/clone","ref":"origin/dev","path":"docs/nope.md"}'
out=$(tr_); rc=$?
grep -q '^STATUS: missing ' <<<"$out" && [ $rc = 0 ] && ok "missing path reported" || bad "missing path"

# Repo that isn't a git repo: missing.
cfg ',"team_rules":{"repo":"'"$tmp"'/nowhere","ref":"origin/dev","path":"docs/rules.md"}'
out=$(tr_)
grep -q '^STATUS: missing ' <<<"$out" && ok "missing repo reported" || bad "missing repo"

# ref defaults to origin/HEAD (the remote's default branch).
git -C "$tmp/clone" remote set-head origin -a >/dev/null 2>&1
cd "$tmp/team" && mkdir -p docs && echo 'main rule' >docs/main.md && git add . && git commit -q -m m; cd - >/dev/null
cfg ',"team_rules":{"repo":"'"$tmp"'/clone","path":"docs/main.md"}'
out=$(tr_)
grep -q 'main rule' <<<"$out" && ok "ref defaults to origin/HEAD" || bad "default ref"

# Plain file mode, present and missing.
echo 'file rule' >"$tmp/f.md"
cfg ',"team_rules_file":"'"$tmp"'/f.md"'; out=$(tr_)
grep -q '^STATUS: ok ' <<<"$out" && grep -q 'file rule' <<<"$out" && ok "team_rules_file read" || bad "team_rules_file read"
cfg ',"team_rules_file":"'"$tmp"'/none.md"'; out=$(tr_)
grep -q '^STATUS: missing ' <<<"$out" && ok "team_rules_file missing reported" || bad "team_rules_file missing"

# Neither set.
cfg ''; out=$(tr_)
grep -q '^STATUS: none' <<<"$out" && ok "no team rules configured" || bad "none"

# With github_user, the fetch uses that account's gh token (GH_TOKEN for gh's credential helper),
# not whichever account is active.
mkdir -p "$tmp/bin"; printf '#!/bin/bash\n[ "$*" = "auth token --user u1" ] && echo tok-u1\n' >"$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
printf '#!/bin/bash\n[ "$1 $2" = "-C %s" ] && [ "$3" = fetch ] && echo "${GH_TOKEN:-none}" >"%s/seen"\nexec %s "$@"\n' "$tmp/clone" "$tmp" "$(command -v git)" >"$tmp/bin/git"; chmod +x "$tmp/bin/git"
cfg ',"github_user":"u1","team_rules":{"repo":"'"$tmp"'/clone","ref":"origin/dev","path":"docs/rules.md"}'
PATH="$tmp/bin:$PATH" bash scripts/team-rules.sh >/dev/null 2>&1
out=$(cat "$tmp/seen" 2>&1); [ "$out" = tok-u1 ] && ok "fetch uses github_user's token" || bad "github_user token"

# Config validation.
cfg ',"team_rules_file":"/x","team_rules":{"repo":"/r","path":"p"}'
out=$(bash scripts/config-json 2>&1) && bad "both keys rejected" || ok "both keys rejected"
cfg ',"team_rules":{"path":"p"}'
out=$(bash scripts/config-json 2>&1) && bad "team_rules without repo rejected" || ok "team_rules without repo rejected"
cfg ',"team_rules":{"repo":"~/r","path":"p"}'
out=$(bash scripts/config-json 2>&1) && { [ "$(jq -r .team_rules.repo <<<"$out")" = "$tmp/r" ] || [ "$(jq -r .team_rules.repo <<<"$out")" = "$(cygpath -m "$tmp/r" 2>/dev/null)" ]; } && [ "$(jq -r .team_rules.ref <<<"$out")" = origin/HEAD ] \
  && ok "team_rules repo ~ expanded, ref defaulted" || bad "team_rules defaults"
exit $fail
