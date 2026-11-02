# Sourced by every script, hook and test. Git Bash on Windows needs two fixes:
# jq writes CRLF there (-b keeps LF), and ln -s copies instead of linking, which breaks the run lock.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    jq() { command jq -b "$@"; }
    export MSYS="${MSYS:+$MSYS }winsymlinks:sys" CYGWIN="${CYGWIN:+$CYGWIN }winsymlinks:sys" ;;
esac

# posix_path PATH: a Windows path (C:\Users\x or C:/Users/x) as Git Bash writes it (/c/Users/x); others
# unchanged. Claude Code records transcript cwds the Windows way, and configs may use either form.
posix_path() {
  case "$1" in
    [A-Za-z]:[\\/]*) local p=${1//\\//}; printf '/%s%s\n' "$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')" "${p:2}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
