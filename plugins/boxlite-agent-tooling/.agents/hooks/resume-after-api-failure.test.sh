#!/usr/bin/env bash
# Behavioral tests at the hook's stdin/stderr/exit boundary.
# Run with: bash plugins/boxlite-agent-tooling/.agents/hooks/resume-after-api-failure.test.sh
#
# The host wakes the model only on exit 2, with this hook's stderr as the prompt, so
# every case asserts the exit code and what stderr carries. The budget and the wake
# nonce live in the state file, which the cases read back.
set -uo pipefail

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
subject="$hook_dir/resume-after-api-failure.sh"
[[ -r "$subject" ]] || { printf 'missing %s\n' "$subject" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/resume-after-api-failure-test.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
git init -q "$work/project" || exit 2
project="$(cd "$work/project" && pwd -P)"
export CLAUDE_PROJECT_DIR="$project"
scope="git-$(printf '%s' s1 | git -C "$project" hash-object --stdin)"
state="$project/.agents/state/api-resume.$scope"

pass=0
fail=0
# Increment pass counter and print a PASS line.  # $1 = test name
ok()  { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$1"; }
# Increment fail counter and print a FAIL line.  # $1 = test name
bad() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$1"; }
# Compare expected and actual values, calling ok or bad and printing details on mismatch.  # $1 = name, $2 = expected, $3 = actual
check() {  # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else
    bad "$1"; printf '        expected %s\n        actual   %s\n' "$2" "$3"
  fi
}

# Feed a payload to the hook on stdin.  # $1 = payload; sets rc, leaves stdout and stderr in $work
feed() {
  printf '%s' "$1" | bash "$subject" >"$work/stdout" 2>"$work/stderr"
  rc=$?
}
# Spend a wake the way cancel-verdict-audit.sh does.  # $1 = scope, $2 = nonce hash; sets rc
consume() {
  bash "$subject" consume-wake "$1" "$2" >"$work/stdout" 2>"$work/stderr"
  rc=$?
}
# A StopFailure payload for session s1.  # $1 = error kind
failure() {
  jq -nc --arg kind "$1" '{hook_event_name:"StopFailure",session_id:"s1",error:$kind,
    last_assistant_message:"API Error: Connection lost mid-response. The response above may be incomplete."}'
}
# The nonce in the last wake's marker, or nothing.
marker_nonce() { sed -n 's/.*\[api-resume-wake:\([0-9a-f]\{64\}\)\].*/\1/p' "$work/stderr"; }
# SHA-256 of a string, lowercase hex.  # $1 = text
sha() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
# How many resumes the state records.
recorded_resumes() { jq '.resumes | length' "$state" 2>/dev/null || echo MISSING; }
# Byte count of the captured stderr.
stderr_bytes() { wc -c < "$work/stderr" | tr -d ' '; }
# Presence of a path of any type.  # $1 = path
presence() { [[ -e "$1" || -L "$1" ]] && echo present || echo absent; }
# Rewrite the state file through jq.  # $1 = jq filter, $2.. = jq args
edit_state() {
  local filter="$1"; shift
  jq -c "$@" "$filter" "$state" > "$work/state.next" && mv "$work/state.next" "$state"
}

printf 'resume-after-api-failure\n'

# ── A dropped stream resumes with a one-time wake ────────────────────────────
rm -f "$state"
feed "$(failure server_error)"
check "server_error resumes with exit 2" "2" "$rc"
check "stdout stays empty" "" "$(cat "$work/stdout")"
check "the resume instruction is one stderr line" "1" "$(wc -l < "$work/stderr" | tr -d ' ')"
check "the instruction names the error and the count" "yes" \
  "$(grep -q 'cut off by an API error (server_error).*Auto-resume 1 of 3' "$work/stderr" && echo yes || echo no)"
nonce="$(marker_nonce)"
check "the wake carries a 64-hex nonce" "valid" \
  "$([[ "$nonce" =~ ^[0-9a-f]{64}$ ]] && echo valid || echo invalid)"
check "the state stores the nonce's hash" "$(sha "$nonce")" \
  "$(jq -r '.wakes[0].hash' "$state" 2>/dev/null || echo MISSING)"
check "the state never stores the nonce itself" "absent" \
  "$(grep -qF "$nonce" "$state" && echo present || echo absent)"
check "the resume is recorded before the hook exits" "1" "$(recorded_resumes)"

consume "$scope" "$(sha "$nonce")"
check "the matching wake is spent" "0" "$rc"
check "a spent wake leaves the state" "0" "$(jq '.wakes | length' "$state")"
consume "$scope" "$(sha "$nonce")"
check "a spent wake cannot be spent again" "1" "$rc"
consume "$scope" "$(sha forged)"
check "an unknown wake is refused" "1" "$rc"
consume "not-a-scope" "$(sha "$nonce")"
check "a malformed scope is refused" "1" "$rc"
consume "$scope" "not-a-hash"
check "a malformed hash is refused" "1" "$rc"

# ── Only transient kinds from the main thread resume ─────────────────────────
rm -f "$state"
feed "$(failure overloaded)"
check "overloaded resumes with exit 2" "2" "$rc"
for kind in rate_limit authentication_failed oauth_org_not_allowed account_on_hold \
            billing_error invalid_request model_not_found max_output_tokens unknown teapot; do
  rm -f "$state"
  feed "$(failure "$kind")"
  check "$kind leaves the turn ended, silently, with no state" "0:0:absent" \
    "$rc:$(stderr_bytes):$(presence "$state")"
done
rm -f "$state"
feed "$(failure server_error | jq -c '.agent_id = "a1"')"
check "a subagent's failure is its parent's to handle" "0:0:absent" \
  "$rc:$(stderr_bytes):$(presence "$state")"
for payload in '{"hook_event_name":"Stop","session_id":"s1","error":"server_error"}' \
               '{"hook_event_name":"StopFailure","error":"server_error"}' \
               '{"hook_event_name":"StopFailure","session_id":"s1"}' \
               'not json' ''; do
  feed "$payload"
  check "no resume for payload: ${payload:-<empty>}" "0:0" "$rc:$(stderr_bytes)"
done

# ── The budget: 3 resumes per session in any 10 minutes ──────────────────────
rm -f "$state"
for n in 1 2 3; do
  feed "$(failure server_error)"
  check "resume $n of 3 inside the window" "2:yes" \
    "$rc:$(grep -q "Auto-resume $n of 3" "$work/stderr" && echo yes || echo no)"
done
feed "$(failure server_error)"
check "a 4th resume inside the window is refused, silently" "0:0" "$rc:$(stderr_bytes)"
check "the refused resume is not recorded" "3" "$(recorded_resumes)"
# shellcheck disable=SC2016 # $old is a jq variable, bound by --argjson
edit_state '.resumes |= map($old)' --argjson old "$(( $(date +%s) - 601 ))"
feed "$(failure server_error)"
check "resumes older than the window no longer count" "2:yes" \
  "$rc:$(grep -q 'Auto-resume 1 of 3' "$work/stderr" && echo yes || echo no)"
check "expired resumes are pruned from the state" "1" "$(recorded_resumes)"

nonce="$(marker_nonce)"
# shellcheck disable=SC2016 # $past is a jq variable, bound by --argjson
edit_state '.wakes |= map(.expires = $past)' --argjson past "$(( $(date +%s) - 1 ))"
consume "$scope" "$(sha "$nonce")"
check "an expired wake is refused" "1" "$rc"
feed "$(failure server_error)"
nonce="$(marker_nonce)"
# shellcheck disable=SC2016 # $far is a jq variable, bound by --argjson
edit_state '.wakes |= map(.expires = $far)' --argjson far "$(( $(date +%s) + 86400 ))"
consume "$scope" "$(sha "$nonce")"
check "a wake expiring beyond its lifetime is refused" "1" "$rc"

# ── Unsafe or malformed state never resumes ──────────────────────────────────
rm -f "$state"
printf '{not json' > "$state"
feed "$(failure server_error)"
check "malformed state does not resume" "0:0" "$rc:$(stderr_bytes)"
check "malformed state is left as found" "{not json" "$(cat "$state")"
printf '{"resumes":["x"],"wakes":[]}\n' > "$state"
feed "$(failure server_error)"
check "a mistyped resume list does not resume" "0" "$rc"
rm -f "$state"
mkdir "$state"
feed "$(failure server_error)"
check "a directory at the state path does not resume" "0" "$rc"
rmdir "$state"
ln -s "$work/elsewhere" "$state"
feed "$(failure server_error)"
check "a symlink at the state path does not resume" "0" "$rc"
check "the symlink's target is never written" "absent" "$(presence "$work/elsewhere")"
rm -f "$state"
mkfifo "$state"
feed "$(failure server_error)"
check "a FIFO at the state path does not resume or hang" "0" "$rc"
rm -f "$state"
# A resume the hook cannot record is never announced: an unrecorded resume is an
# unbounded one, so an unwritable state directory must hold the loop at zero, not three.
mkdir -p "$(dirname "$state")"
chmod 500 "$(dirname "$state")"
silent_refusals=0
for _ in 1 2 3 4 5; do
  feed "$(failure server_error)"
  [[ "$rc" == 0 && "$(stderr_bytes)" == 0 ]] && silent_refusals=$(( silent_refusals + 1 ))
done
chmod 700 "$(dirname "$state")"
check "an unwritable state directory refuses every resume, silently" "5" "$silent_refusals"

# ── Outside a repository there is no session scope ───────────────────────────
mkdir -p "$work/plain"
printf '%s' "$(failure server_error)" \
  | CLAUDE_PROJECT_DIR="$work/plain" bash "$subject" >/dev/null 2>"$work/stderr"
check "outside a repository nothing resumes" "0:0" "$?:$(stderr_bytes)"
CLAUDE_PROJECT_DIR="$work/plain" bash "$subject" consume-wake "$scope" "$(sha x)" 2>/dev/null
check "outside a repository no wake is spent" "1" "$?"

# ── A broken installation says so and never resumes ─────────────────────────
mkdir -p "$work/bin"
for tool in bash perl shasum git awk; do ln -sf "$(command -v "$tool")" "$work/bin/$tool"; done
printf '%s' "$(failure server_error)" | PATH="$work/bin" bash "$subject" >/dev/null 2>"$work/stderr"
check "a missing jq exits 1, never 2" "1" "$?"
check "a missing jq is named on stderr" "yes" \
  "$(grep -q 'required dependency not found: jq' "$work/stderr" && echo yes || echo no)"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
