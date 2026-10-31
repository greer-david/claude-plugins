# Shared by the hooks (sourced, not run). Bash and coreutils only.
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/platform.sh"

# classify TOOL_NAME: sets kind (m365 | atlassian | empty for any other tool) and name (the tool
# part, lowercase). Guarded tool names never contain "__"; if one does, name is "__invalid__".
classify() {
  local lower rest server
  kind=; name=
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in mcp__*__*) ;; *) return 0 ;; esac
  rest=${lower#mcp__}
  server=${rest%%__*}
  case "$server" in
    *microsoft*365*|*m365*)                 kind=m365 ;;
    *atlassian*|*jira*|*confluence*|*rovo*) kind=atlassian ;;
    *) return 0 ;;
  esac
  name=${rest#*__}
  case "$name" in *__*) name="__invalid__" ;; esac
}

# One lock per run ($state/.run.lock) for the call record and approvals. The lock is a symlink whose
# target names its holder ("pid.<pid>.<token>"), made in one step by ln -s, so it never exists
# without a holder. A lock whose holder is dead is removed under a second lock, and only if it still
# names that holder, so a live replacement is never removed. take_lock returns non-zero if it can't
# get the lock (the caller fails closed); the lock is released on exit.
take_lock() {
  mkdir -p "$state" 2>/dev/null || return 1
  lock="$state/.run.lock"
  lock_id="pid.$$.$RANDOM$RANDOM"
  local holder
  for _ in $(seq 1 100); do
    if ln -s "$lock_id" "$lock" 2>/dev/null; then trap release_lock EXIT; return 0; fi
    holder=$(readlink "$lock" 2>/dev/null) && lock_dead "$holder" && reclaim_lock "$holder" && continue
    sleep 0.05
  done
  return 1
}
release_lock() { [ "$(readlink "$lock" 2>/dev/null)" = "$lock_id" ] && rm -f "$lock"; }
lock_dead() {  # holder -> true if no live process holds it (a malformed holder counts as dead)
  local pid=${1#pid.}; pid=${pid%%.*}
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  ! kill -0 "$pid" 2>/dev/null
}
reclaim_lock() {  # dead holder -> removes the lock if it still names that holder
  local r="$state/.run.lock.reclaim"
  # A reclaimer killed mid-way leaves its reclaim lock; clear it if its holder is dead and unchanged.
  local rh; rh=$(readlink "$r" 2>/dev/null) && lock_dead "$rh" && [ "$(readlink "$r" 2>/dev/null)" = "$rh" ] && rm -f "$r"
  ln -s "pid.$$" "$r" 2>/dev/null || return 1
  [ "$(readlink "$lock" 2>/dev/null)" = "$1" ] && rm -f "$lock"
  rm -f "$r"
}
