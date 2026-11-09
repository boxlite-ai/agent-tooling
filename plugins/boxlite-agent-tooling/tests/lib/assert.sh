# shellcheck shell=bash
# Shared assertions for *.test.sh suites. Source it once, before the first case;
# loading defines these functions and zeroes the `pass` and `fail` counters.
#
# Each case prints "  PASS  <name>" or "  FAIL  <name>  (<detail>)". assert_result
# prints "RESULT: <pass> passed, <fail> failed" and exits 1 when any case failed.

pass=0
fail=0

ok() {  # name
  pass=$((pass + 1))
  printf '  PASS  %s\n' "$1"
}

bad() {  # name [detail]
  fail=$((fail + 1))
  if (( $# > 1 )); then
    printf '  FAIL  %s  (%s)\n' "$1" "$2"
  else
    printf '  FAIL  %s\n' "$1"
  fi
}

badf() {  # name format [arg...]: the detail is printf FORMAT ARG...
  local name="$1" format="$2" detail
  shift 2
  # shellcheck disable=SC2059 # the caller supplies the detail format
  printf -v detail -- "$format" "$@"
  bad "$name" "$detail"
}

check_rc() {  # name status [detail]: passes when status is 0
  if [[ "$2" == 0 ]]; then ok "$1"; else bad "$1" "${@:3}"; fi
}

check_eq() {  # name got want
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got=$2 want=$3"; fi
}

check_contains() {  # name haystack needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing=$3 in=$2"; fi
}

assert_result() {  # prints the RESULT line, then exits nonzero on any failure
  printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
  exit $(( fail > 0 ? 1 : 0 ))
}
