# Sourced by every script, hook and test. Git Bash on Windows needs two fixes:
# jq writes CRLF there (-b keeps LF), and ln -s copies instead of linking, which breaks the run lock.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    jq() { command jq -b "$@"; }
    export MSYS="${MSYS:+$MSYS }winsymlinks:sys" CYGWIN="${CYGWIN:+$CYGWIN }winsymlinks:sys" ;;
esac
