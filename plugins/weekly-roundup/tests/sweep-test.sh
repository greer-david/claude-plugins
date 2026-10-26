#!/bin/bash
# Self-test for scripts/sweep-local.sh GitHub sections, with gh stubbed (no network).
cd "$(dirname "$0")/.." || exit 1
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
exit $fail
