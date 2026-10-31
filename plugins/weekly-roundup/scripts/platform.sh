# Sourced by every script, hook and test. Git Bash on Windows needs two fixes:
# jq writes CRLF there (-b keeps LF), and ln -s copies instead of linking, which breaks the run lock.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    jq() { command jq -b "$@"; }
    export MSYS="${MSYS:+$MSYS }winsymlinks:sys" CYGWIN="${CYGWIN:+$CYGWIN }winsymlinks:sys" ;;
esac
# For the tests: named time zones need a zone database, which Git Bash doesn't have.
tz_names() { [ "$( (TZ=America/Chicago date -d @1792022400 +%z || TZ=America/Chicago date -r 1792022400 +%z) 2>/dev/null)" = -0500 ]; }
