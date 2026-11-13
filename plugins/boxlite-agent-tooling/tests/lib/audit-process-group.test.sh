#!/usr/bin/env bash
# Exercise the real controller in isolated shells; a watchdog bounds blocking opens.
set -uo pipefail
LIBRARY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.agents/lib" && pwd)/audit-process-group.sh"
case "$OSTYPE" in
  darwin*|linux*) ;;
  *) printf 'SKIP: POSIX controller is inactive on %s\n' "$OSTYPE"; exit 0 ;;
esac
# shellcheck source=assert.sh
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
results="$(mktemp)"
trap 'rm -f "$results"' EXIT
python3 - "$LIBRARY" > "$results" <<'PY'
import os
import shlex
import signal
import subprocess
import sys
import tempfile

library = shlex.quote(sys.argv[1])
passed = failed = 0


def check(name, body):
    global passed, failed
    with tempfile.TemporaryDirectory(prefix="audit-fd-test-") as directory:
        prefix = f'''set -uo pipefail
source {library}
cd {shlex.quote(directory)} || exit 90
mkdir control
printf 'stdin-marker\\n' > input
'''
        process = subprocess.Popen(
            ["/bin/bash", "-c", prefix + body], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            out, err = process.communicate(timeout=3)
            success = process.returncode == 0
            detail = f"rc={process.returncode} stdout={out!r} stderr={err!r}"
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            out, err = process.communicate()
            success = False
            detail = f"blocked after startup marker: stdout={out!r} stderr={err!r}"
        if success:
            passed += 1
            print(f"PASS\t{name}", flush=True)
        else:
            failed += 1
            print(f"FAIL\t{name} ({detail})", flush=True)


# Read after closing writers to prove EOF, not just a successful bootstrap open.
channels = r'''
printf 'entered\n'
audit_group_open_controller control || return 21
[[ ! -e control/group-request && ! -e control/group-lifetime ]] || return 22
[[ ! -e /dev/fd/16 && ! -e /dev/fd/17 ]] || return 23
printf 'request\n' >&13
read -r -t 1 request <&12 && [[ "$request" == request ]] || return 24
printf 'lifetime\n' >&15
read -r -t 1 lifetime <&14 && [[ "$lifetime" == lifetime ]] || return 25
exec 13>&- 15>&-
status=0
read -r -t 1 value <&12 || status=$?
[[ "$status" == 1 ]] || return 26
status=0
read -r -t 1 value <&14 || status=$?
[[ "$status" == 1 ]] || return 27
exec 12<&- 14<&-
'''
for depth in range(3):
    functions = 'probe() {\n' + channels + '\n}\n'
    previous = "probe"
    for level in range(depth):
        functions += f'wrap{level}() {{ {previous} < input; }}\n'
        previous = f"wrap{level}"
    check(f"depth{depth}: startup, channel transfer and EOF", functions + previous)

for depth in (3, 8):
    functions = r'''
probe() {
  printf 'entered\n'
  audit_group_open_controller control && return 31
  [[ ! -e control/group-request && ! -e control/group-lifetime ]] || return 32
}
'''
    previous = "probe"
    for level in range(depth):
        functions += f'''wrap{level}() {{
  {previous} < input || return
  read -r marker || return 33
  [[ "$marker" == stdin-marker ]] || return 34
}}
'''
        previous = f"wrap{level}"
    check(f"depth{depth}: reject shell backup without corrupting stdin",
          functions + previous + ' < input')

for fd in range(12, 18):
    for mode in ("read", "write", "rdwr", "deleted", "pipe"):
        setup = "printf 'foreign\\n' > foreign\n"
        verify = f'read -r marker <&{fd} && [[ "$marker" == foreign ]] || exit 44\n'
        if mode == "read":
            setup += f'exec {fd}<foreign\n'
        elif mode == "write":
            setup += f'exec {fd}>foreign\n'
            verify = f'printf "preserved\\n" >&{fd} || exit 44\n'
            verify += '[[ "$(cat foreign)" == preserved ]] || exit 45\n'
        elif mode == "pipe":
            setup += f'exec {fd}< <(printf "foreign\\n")\n'
        else:
            setup += f'exec {fd}<>foreign\n'
            if mode == "deleted":
                setup += 'rm foreign\n'
            verify += f'printf "preserved\\n" >&{fd} || exit 45\n'
        check(f"occupied fd{fd} {mode}: reject and preserve handle", setup + r'''
mkfifo() { printf 'called\n' > invoked; command mkfifo "$@"; }
printf 'entered\n'
audit_group_open_controller control && exit 41
[[ ! -e invoked ]] || exit 43
[[ ! -e control/group-request && ! -e control/group-lifetime ]] || exit 42
''' + verify)

# A third redirected stream occupies fd12 and must be rejected without corruption.
for stream_count in (2, 3):
    call = 'probe > out 2> err' + (' < input' if stream_count == 3 else '')
    action = ('audit_group_open_controller control && return 50'
              if stream_count == 3 else 'audit_group_open_controller control || return')
    check(f"{stream_count} redirected streams remain usable", '''
probe() {
  ''' + action + r'''
  printf 'inside-out\n'
  printf 'inside-err\n' >&2
}
''' + call + r''' || exit 51
printf 'outside-out\n'
printf 'outside-err\n' >&2
[[ "$(cat out)" == inside-out ]] || exit 52
[[ "$(tail -n 1 err)" == inside-err ]] || exit 53
''')

for failure in ("mkfifo", "bootstrap", "directional", "unlink"):
    injection = {
        "mkfifo": 'mkfifo() { command mkfifo "$1"; return 1; }',
        "bootstrap": '''mkfifo() {
  command mkfifo "$1" && ln -s "$PWD/missing/lifetime" "$2"
}''',
        "directional": r'''set -T
inject_limit() {
  case "$BASH_COMMAND" in
    'exec 12<'*) ulimit -n 15; trap - DEBUG ;;
  esac
}
trap inject_limit DEBUG''',
        "unlink": '''rm() {
  if [[ "$1" == -f && "$2" == control/group-request ]]; then return 1; fi
  command rm "$@"
}''',
    }[failure]
    check(f"{failure} failure releases acquired descriptors", injection + r'''
printf 'entered\n'
audit_group_open_controller control && exit 60
for fd in 12 13 14 15 16 17; do
  [[ ! -e /dev/fd/$fd && ! -L /dev/fd/$fd ]] || exit 61
done
''')

sys.exit(bool(failed))
PY
matrix_status=$?
while IFS=$'\t' read -r outcome description; do
  case "$outcome" in
    PASS) ok "$description" ;;
    FAIL) bad "$description" ;;
    *) bad 'unexpected matrix output' "$outcome $description" ;;
  esac
done < "$results"
if (( pass + fail == 0 || (matrix_status != 0 && fail == 0) )); then
  bad 'controller matrix completed' "rc=$matrix_status"
fi
assert_result
