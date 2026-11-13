#!/usr/bin/env bash
set -uo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/assert.sh
source "$plugin_root/tests/lib/assert.sh"
case "$OSTYPE" in
  darwin*|linux*) ;;
  *) printf 'SKIP: the process-group controller is POSIX-only\n'; exit 0 ;;
esac

temporary="$(mktemp -d)" || exit 2
trap 'rm -rf "$temporary"' EXIT
library="$plugin_root/.agents/lib/audit-process-group.sh"

cat > "$temporary/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
source "$1" || exit 2
directory=$2
mode=$3
trap 'exit 124' ALRM

closed() {
  local descriptor
  for descriptor in 12 13 14 15 16 17; do
    if ( : <&"$descriptor" ) 2>/dev/null; then
      return 1
    fi
  done
}

open_controller() {
  if ! audit_group_open_controller "$directory"; then
    return 21
  fi
}

printf 'entered\n' > "$directory/entered"
case "$mode" in
  bootstrap-failure)
    mkfifo() {
      command mkfifo "$@" || return
      command rm -f "$directory/group-lifetime"
      mkdir "$directory/group-lifetime"
    }
    status=0
    audit_group_open_controller "$directory" || status=$?
    [[ "$status" == 1 ]] || exit 31
    closed || exit 32
    [[ ! -e "$directory/group-request" && -d "$directory/group-lifetime" ]] || exit 33
    exit 0
    ;;
  unlink-failure)
    rm() { command rm "$@"; return 1; }
    status=0
    audit_group_open_controller "$directory" || status=$?
    [[ "$status" == 1 ]] || exit 34
    closed || exit 35
    [[ ! -e "$directory/group-request" && ! -e "$directory/group-lifetime" ]] || exit 36
    exit 0
    ;;
  plain) open_controller || exit "$?" ;;
  redirected) open_controller < /dev/null || exit "$?" ;;
  nested)
    nested() { open_controller < /dev/null; }
    nested < /dev/null || exit "$?"
    ;;
  *) exit 2 ;;
esac

IFS= read -r caller_input || exit 22
[[ "$caller_input" == caller-input ]] || exit 23
[[ ! -e "$directory/group-request" && ! -e "$directory/group-lifetime" ]] || exit 24

# A read/write bootstrap left on either reader would suppress cancellation EOF.
for descriptor in 12 14; do
  perl -MFcntl=:DEFAULT -e '
    my $flags = fcntl(STDIN, F_GETFL, 0);
    exit(!defined($flags) || ($flags & O_ACCMODE) != O_RDONLY);
  ' <&"$descriptor" || exit 25
done

printf 'request-marker\n' >&13 || exit 26
IFS= read -r request <&12 || exit 27
[[ "$request" == request-marker ]] || exit 28
printf 'lifetime-marker\n' >&15 || exit 29
IFS= read -r lifetime <&14 || exit 30
[[ "$lifetime" == lifetime-marker ]] || exit 37

exec 13>&- 15>&-
for descriptor in 12 14; do
  perl -e '
    alarm 2;
    my $count = sysread(STDIN, my $byte, 1);
    exit(!defined($count) || $count != 0);
  ' <&"$descriptor" || exit 38
done
exec 12<&- 14<&-
closed || exit 39
PROBE

for mode in plain redirected nested bootstrap-failure unlink-failure; do
  directory="$temporary/$mode"
  mkdir "$directory"
  status=0
  printf 'caller-input\n' |
    perl -e 'alarm shift; exec @ARGV' 5 "$BASH" "$temporary/probe.sh" \
      "$library" "$directory" "$mode" > "$directory/output" 2>&1 || status=$?
  entered=missing
  [[ ! -f "$directory/entered" ]] || entered="$(cat "$directory/entered")"
  check_eq "$mode reaches controller setup" "$entered" entered
  check_eq "$mode preserves setup, stream, EOF, and cleanup contracts" "$status" 0
  if [[ "$status" != 0 ]]; then cat "$directory/output"; fi
done

assert_result
