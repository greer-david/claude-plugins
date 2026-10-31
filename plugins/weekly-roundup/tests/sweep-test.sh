#!/bin/bash
# Self-test for scripts/sweep-local.sh GitHub sections, with gh stubbed (no network).
cd "$(dirname "$0")/.." || exit 1
. scripts/platform.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fail=0
export HOME="$tmp" WEEKLY_ROUNDUP_CONFIG="$tmp/c.json"
echo '{"log_dir":"/tmp/x","rules_file":"/tmp/r.md","transcripts_dir":"'"$tmp"'/none"}' >"$tmp/c.json"
mkdir -p "$tmp/bin"
# Stub gh: answers review-requested searches with one PR (through --jq, like gh does), everything else empty.
cat >"$tmp/bin/gh" <<'G'
#!/bin/bash
args="$*"; jqf=; prev=
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
case "$args" in
  *--review-requested=@me*) [ "${GH_FAIL:-}" = 1 ] && { echo "HTTP 401: bad credentials" >&2; exit 1; }
    echo '[{"number":7,"title":"Add tests","repository":{"nameWithOwner":"org/repo"},"url":"https://x/7","updatedAt":"2026-10-20T10:00:00Z"}]' | jq -r "$jqf" ;;
  *) echo '[]' | jq -r "${jqf:-.}" ;;
esac
G
chmod +x "$tmp/bin/gh"
sw() { PATH="$tmp/bin:$PATH" bash scripts/sweep-local.sh 2026-10-18 2026-10-24 2>&1; }
out=$(sw)
grep -q '^### review requested, not done (possibly missed)$' <<<"$out" && grep -q '^#7 org/repo Add tests https://x/7 (updated 2026-10-20)$' <<<"$out" \
  && echo "ok   open review requests listed" || { echo "FAIL review requests listed"; echo "$out"; fail=1; }
grep -q 'github|review requests|ok|1|no' <<<"$out" && echo "ok   review requests in STATS" || { echo "FAIL review requests STATS"; echo "$out"; fail=1; }
out=$(GH_FAIL=1 sw)
grep -q 'github|review requests|error: HTTP 401' <<<"$out" && echo "ok   gh failure reported in STATS" || { echo "FAIL gh failure STATS"; echo "$out"; fail=1; }
# Sessions: only projects inside session_dirs (default: repos) are swept; the rest are counted, not named.
mkdir -p "$tmp/p/work" "$tmp/p/personal" "$tmp/repos/main/sub" "$tmp/home-diary"
printf '%s\n' '{"cwd":"'"$tmp"'/repos/main/sub","type":"user","message":{"content":"fix the work bug"}}' >"$tmp/p/work/a.jsonl"
printf '%s\n' '{"cwd":"'"$tmp"'/home-diary","type":"user","message":{"content":"my private diary"}}' >"$tmp/p/personal/b.jsonl"
touch -t 202610201200 "$tmp/p/work/a.jsonl" "$tmp/p/personal/b.jsonl"
cfg() { echo '{"log_dir":"/tmp/x","rules_file":"/tmp/r.md","transcripts_dir":"'"$tmp"'/p","repos":["'"$tmp"'/repos/main"]'"$1"'}' >"$tmp/c.json"; }
cfg ''; out=$(sw)
grep -q 'fix the work bug' <<<"$out" && echo "ok   session in a repo swept" || { echo "FAIL repo session swept"; echo "$out"; fail=1; }
grep -q 'private diary\|home-diary' <<<"$out" && { echo "FAIL session outside repos leaked"; echo "$out"; fail=1; } || echo "ok   session outside repos skipped"
grep -q 'sessions|outside session_dirs|skipped|1|-' <<<"$out" && echo "ok   skipped sessions counted" || { echo "FAIL skipped count"; echo "$out"; fail=1; }
cfg ',"repos":[],"session_dirs":["'"$tmp"'/home-diary"]'; out=$(sw)
grep -q 'private diary' <<<"$out" && ! grep -q 'work bug' <<<"$out" && echo "ok   explicit session_dirs" || { echo "FAIL explicit session_dirs"; echo "$out"; fail=1; }
cfg ',"session_dirs":["'"$tmp"'/repos/ma"]'; out=$(sw)
grep -q 'work bug' <<<"$out" && { echo "FAIL prefix match without path boundary"; fail=1; } || echo "ok   path-boundary match"
mkdir -p "$tmp/clerk/slug" "$tmp/clerk/summary/20261021"
echo '{"cwd":"'"$tmp"'/home-diary"}' >"$tmp/clerk/slug/diary.json"; echo '{"cwd":"'"$tmp"'/repos/main"}' >"$tmp/clerk/slug/main.json"
echo 'clerk diary note' >"$tmp/clerk/summary/20261021/diary.md"; echo 'clerk work note' >"$tmp/clerk/summary/20261021/main.md"; echo 'clerk orphan' >"$tmp/clerk/summary/20261021/unknown.md"
cfg ',"clerk_dir":"'"$tmp"'/clerk"'; out=$(sw)
grep -q 'clerk work note' <<<"$out" && ! grep -q 'clerk diary\|clerk orphan' <<<"$out" && echo "ok   clerk summaries allow-listed (unknown cwd skipped)" || { echo "FAIL clerk allow-list"; echo "$out"; fail=1; }
# DST: a day's transcripts run from that day's local midnight (US Central ends Sun 2026-11-01).
mkdir -p "$tmp/p/dst"; cfg ''
printf '%s\n' '{"cwd":"'"$tmp"'/repos/main","type":"user","message":{"content":"late sunday"}}' >"$tmp/p/dst/a.jsonl"
printf '%s\n' '{"cwd":"'"$tmp"'/repos/main","type":"user","message":{"content":"late monday"}}' >"$tmp/p/dst/b.jsonl"
if tz_names; then
TZ=America/Chicago touch -t 202611012330 "$tmp/p/dst/a.jsonl"; TZ=America/Chicago touch -t 202611022330 "$tmp/p/dst/b.jsonl"
out=$(TZ=America/Chicago PATH="$tmp/bin:$PATH" bash scripts/sweep-local.sh 2026-11-02 2026-11-02 2>&1)
grep -q 'late monday' <<<"$out" && ! grep -q 'late sunday' <<<"$out" && echo "ok   DST: transcript day from local midnight" || { echo "FAIL DST transcript day"; echo "$out"; fail=1; }
else echo "skip DST transcript day: no named time zones here"; fi
exit $fail
